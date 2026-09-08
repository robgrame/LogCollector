# Migrating a script off the workspace SharedKey

Any Windows script that writes to Log Analytics can now do so through the LogCollector core
package instead of the retired HTTP Data Collector API. This removes the workspace
**SharedKey** from the script.

## Why this matters

The Data Collector pattern required each script to carry:

```powershell
$CustomerId = '<workspace guid>'
$SharedKey  = '<44-character base64 key>'   # a bearer credential for the whole workspace
```

Anyone who could read the script — from a share, from Intune, from a backup, from a support
bundle — could write arbitrary records into the workspace, and rotating the key meant
editing and redeploying every script that embedded it. The API itself is also retired.

With the core package the device authenticates with **its own Intune certificate**, which
never leaves the machine's certificate store and identifies the device rather than granting
workspace-wide write access.

## Prerequisite

Install the **LogCollector Core** Win32 app on the device (see `src/CorePackage/README.md`).
It puts `LogCollector.Client` on the machine `PSModulePath` and writes the endpoint to
`%ProgramData%\LogCollector\Config\Endpoint.psd1`.

The calling script must run **as SYSTEM or elevated**. The shared spool under
`%ProgramData%\LogCollector\SharedSpool` is writable only by SYSTEM and Administrators, by
design: a spool that an unprivileged user could write to would let that user forge records
attributed to the device. A script running in a normal user context fails when it tries to
retain a batch. Run migrated scripts from a scheduled task under `NT AUTHORITY\SYSTEM`, or
from Intune, exactly as the previous Data Collector scripts were run.

## The migration

The replacement keeps the same function name and the same parameters, so the change is a
deletion, not a rewrite.

### Before

```powershell
$CustomerId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$SharedKey  = 'REDACTED=='
$LogType    = 'W11Upgrade'

function Send-LogAnalyticsData {
    param($customerId, $sharedKey, $body, $logType)
    # ~40 lines: HMAC-SHA256 signature, x-ms-date, Invoke-WebRequest to
    # https://$customerId.ods.opinsights.azure.com/api/logs?api-version=2016-04-01
}

$response = Send-LogAnalyticsData -customerId $CustomerId -sharedKey $SharedKey `
    -body ([Text.Encoding]::UTF8.GetBytes($json)) -logType $LogType
if ($response -match "200 :") { Write-Host 'sent' }
```

### After

```powershell
Import-Module LogCollector.Client

$response = Send-LogAnalyticsData -Body $json -LogType 'W11Upgrade'
if ($response -match "200 :") { Write-Host 'sent' }
```

Concretely:

1. Delete the inline `Send-LogAnalyticsData` function.
2. Delete the `$CustomerId` and `$SharedKey` variables and every parameter that carried them.
3. Add `Import-Module LogCollector.Client` near the top.
4. Leave the call site alone if you prefer — see below.

**Rotate the workspace key** once the last script that embedded it has been migrated. Until
then, treat the key as exposed wherever those scripts have been stored.

## What still binds unchanged

A call site can be left exactly as it is during a staged migration:

```powershell
$response = Send-LogAnalyticsData -customerId $CustomerId -sharedKey $SharedKey `
    -body $bytes -logType 'DeviceInventory'
```

* `-customerId` and `-sharedKey` are **accepted and ignored**. Nothing is sent to
  `*.ods.opinsights.azure.com`. The key is never transmitted, never written to a log and
  never echoed in the warning that asks you to remove it.
* `-body` accepts a JSON string, the UTF-8 bytes of a JSON string, or plain objects.
* `-logType` accepts the bare legacy name; `_CL` is appended exactly as the old API appended
  it server-side. `'DeviceInventory'` and `'DeviceInventory_CL'` both reach
  `DeviceInventory_CL`.
* The result stringifies to the legacy `'<status> : <detail>'` form, so
  `if ($response -match "200 :")` keeps working.

Passing `-sharedKey` emits a warning telling you to remove it. That warning is the only
signal that a script has not finished migrating; a fully migrated script is silent.

## What changed in the response

The return value is now an object, not a string. It still stringifies to the legacy form,
but it also carries:

| Property | Meaning |
| --- | --- |
| `StatusCode` | `200` when the intake accepted the batch, `202` otherwise |
| `Disposition` | `Delivered`, or `Deferred` when the batch is held in the local spool |
| `TableName` | Resolved destination, e.g. `W11Upgrade_CL` |
| `RecordCount` | Records extracted from `-Body` |
| `PayloadBytes` | Size of the caller's payload |
| `Source` | Producing script, defaulted to the calling file name |

`200` deliberately does **not** cover a spooled batch. If the endpoint is unreachable the
records are retained on disk and retried later; reporting `200` for data that is not in Log
Analytics yet would turn a delivery failure into a silent one.

Records are not lost when submission fails. They are written to the shared spool under
`%ProgramData%\LogCollector\SharedSpool` and drained by a later run.

## Sending several kinds of record

`-LogType` is per call, so one script can write to several tables:

```powershell
Send-LogAnalyticsData -LogType 'W11Upgrade'   -Body $upgradeEvents
Send-LogAnalyticsData -LogType 'W11UpgradeErr' -Body $failures
```

Use `-Source` when several scripts share a table and you need to tell them apart:

```powershell
Send-LogAnalyticsData -LogType 'W11Upgrade' -Body $events -Source 'PS-CopyW11FromWRK'
```

## Testing a change

Against a single machine, without installing the core package:

```powershell
Import-Module 'C:\Path\To\LogCollector.Client.psd1'
Send-LogAnalyticsData -LogType 'W11Upgrade' -Body $events `
    -FrontendUrl 'https://<intake-host>/api/inventory' -Verbose -WhatIf
```

`-WhatIf` reports what would be sent and submits nothing. Drop it, and add `-QueueOnly`, to
exercise serialisation and the spool without contacting the endpoint.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `LogCollector is not configured on this machine` | The core package is not installed, or its configuration was removed. Install it, or pass `-FrontendUrl`. |
| `... cannot be trusted. Reinstall the LogCollector core package.` | The endpoint configuration is writable by a non-administrator, so it could have been redirected. Reinstall to restore the ACL. |
| `Disposition = Deferred` on every call | The endpoint is unreachable, or `SubmissionEnabled` is `$false` in the machine configuration. Records are spooled, not lost. |
| `401` from the intake | The device certificate failed chain, issuer or signature validation. |
| `403` from the intake | The certificate is not bound to the submitted device, or the device is absent or disabled in the tenant. |
