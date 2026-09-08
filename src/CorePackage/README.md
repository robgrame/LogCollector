# LogCollector Core — shared telemetry dependency

Version 1.6.0

This package installs **LogCollector.Client** machine-wide. It is a *dependency*: it
registers no scheduled task and collects nothing by itself. Install it on every device that
runs a script which needs to write to Log Analytics.

## What it gives a script

```powershell
Import-Module LogCollector.Client
Send-LogAnalyticsData -LogType 'W11Upgrade' -Body ($events | ConvertTo-Json)
```

No workspace ID, no workspace key, no endpoint URL and no install path in the script. The
device authenticates with its own Intune certificate; the endpoint comes from the
machine-wide configuration written by this installer.

The calling script must run **as SYSTEM or elevated**: the shared spool is writable only by
SYSTEM and Administrators, so that no unprivileged user can forge records attributed to the
device. Run such scripts from a scheduled task under `NT AUTHORITY\SYSTEM`, or from Intune.

## What it replaces

Scripts historically carried an inline `Send-LogAnalyticsData` built on the retired HTTP
Data Collector API, which required the workspace **SharedKey in plaintext** in the script.
That key is a bearer credential for the whole workspace: anyone who could read the script
could write arbitrary records, and rotating it meant editing every script.

The replacement keeps the **same function name and the same parameters**, so an existing
call site binds unchanged:

```powershell
$response = Send-LogAnalyticsData -customerId $WorkspaceId -sharedKey $Key `
    -body $Bytes -logType 'DeviceInventory'
if ($response -match "200 :") { 'delivered' }
```

* `-customerId` and `-sharedKey` are **accepted and ignored**. The key is never sent,
  never logged and never echoed in the warning that tells you to delete it.
* `-body` accepts what the old API accepted: a JSON string, the UTF-8 bytes of a JSON
  string, or objects.
* `-logType` accepts the bare legacy name; `_CL` is appended as the old API did server-side.
* The result stringifies to the legacy `'<status> : <detail>'` form, so `-match "200 :"`
  keeps working, while `.Disposition`, `.StatusCode`, `.TableName` and `.RecordCount` are
  available to new code.

`200` means the intake accepted the batch. Anything the intake did not accept reports
`202`, including a batch retained in the shared spool for a later retry — reporting `200`
for data that is not in Log Analytics yet would be a false success.

## Install

```powershell
.\Install.ps1
```

Requires elevation and 64-bit Windows PowerShell. It:

1. copies the module to `%ProgramFiles%\WindowsPowerShell\Modules\LogCollector.Client\1.6.0`,
   which is on `PSModulePath` for both Windows PowerShell 5.1 and PowerShell 7;
2. writes `%ProgramData%\LogCollector\Config\Endpoint.psd1`;
3. restricts write access on both — **and on their parent directories** — to SYSTEM and
   Administrators, removing any pre-existing explicit entry, then re-reads each security
   descriptor to confirm the DACL is protected, grants no untrusted principal write, delete
   or take-ownership rights, and is owned by an administrator;
4. verifies the result from a clean child session by importing the module *by name*.

Both paths are readable by all users and hold **no secret**.

The ACL is not cosmetic. The module directory is imported by SYSTEM-scheduled work, so a
user-writable copy would be code execution as SYSTEM; the configuration names the intake
endpoint, so a user-writable copy would redirect the fleet's telemetry. Parent directories
are hardened for the same reason: create- or delete-child rights on a parent let the whole
protected directory be renamed away and replaced, whatever the child's own ACL says.

A configuration that fails the check is refused at read time rather than trusted, and
`Detect.ps1` performs the same verification *before* importing anything, so a device whose
permissions have drifted is reported as not installed and remediated by Intune.

For a single-machine test, override the endpoint without rebuilding:

```powershell
.\Install.ps1 -FrontendUrl 'https://<intake-host>/api/inventory'
```

## Detection (Intune Win32 app)

Use `Detect.ps1` as a custom detection script. It exits `0` with one line of output only
when this exact version is installed, importable by name and configured; otherwise it exits
`1` with no output.

## Uninstall

```powershell
.\Uninstall.ps1                        # module only
.\Uninstall.ps1 -RemoveConfiguration   # also drop the endpoint, retiring the device
.\Uninstall.ps1 -RemoveSpool           # also discard records not yet delivered
```

The configuration and the shared spool survive by default: other scripts depend on the
former, and the latter may still hold records that have not reached Log Analytics.

## Ordering

Install this package **before** any package or script that submits telemetry. In Intune,
make it a dependency of those Win32 apps so the ordering is enforced rather than assumed.
