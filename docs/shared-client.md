# Shared PowerShell client

## Optional diagnostics (1.2.2)

`Send-LogCollectorData` and `Sync-LogCollectorSpool` accept an optional
`-DiagnosticSink` scriptblock with positional arguments `Event` (string) and
`Data` (hashtable). It receives explicitly selected metadata about certificate
selection, HTTP attempts/results/retries and spool operations, never the envelope,
HTTP response body, headers or exception message. Existing calls without the sink
do not create log files or change output.

The inventory package wires this callback to its protected rotating
`Inventory.Logging.psm1`. Other callers may supply their own trusted callback.
Callback output is suppressed; callback failures propagate rather than silently
losing diagnostics. A logging failure after an HTTP response does not undo a
request already accepted by the server. Do not use a callback that dumps caller
variables or arbitrary exceptions into a log.

`src\Client\LogCollector.Client.psd1` is the public module entry point for independent
inventory, diagnostic and remediation scripts. Version **1.2.2** supports Windows PowerShell
5.1 and PowerShell 7 on Windows. Import does not discover certificates, access Azure, install
tasks or run collection/remediation.

The original scripts under the customer's ACI folder have **not** been changed. Their migration
and the required backend schemas are tracked in [aci-migration-findings.md](aci-migration-findings.md).

## Package and distribute

From the repository:

```powershell
$package = .\scripts\Publish-ClientModule.ps1
$package | Format-List ModuleVersion, PackagePath, PackageSha256
```

The ZIP contains exactly six source/manifest files under `LogCollector.Client\1.2.2`.
It contains no customer scripts, private keys, CA files, credentials or device inventory.
The SHA-256 identifies the generated artifact; it is not a digital signature or proof of its source.

Distribute it through the customer's trusted management channel to an administrator-controlled
directory, for example:

```text
C:\Program Files\LogCollector\Modules\LogCollector.Client\1.2.2\
    LogCollector.Client.psd1
    LogCollector.Client.psm1
    DeviceIdentity.psm1
    RequestSigning.psm1
    InventoryClient.psm1
    InventorySpool.psm1
```

The helper only packages: it does not install or alter ACLs on a client. Keep code writable only
by administrators/SYSTEM. Replace the entire versioned module, not a single dependent PSM1.
Keep the import path valid for scheduled tasks, self-copies and post-upgrade hooks. Do not use
the current working directory to locate it.

```powershell
Import-Module 'C:\Program Files\LogCollector\Modules\LogCollector.Client\1.2.2\LogCollector.Client.psd1' -ErrorAction Stop
```

The high-level commands obtain their endpoint from an explicit parameter. No Function key,
workspace key, workspace ID or Graph token is distributed with the module.

## Public commands

| Command | Purpose |
|---|---|
| `Get-DeviceIdentitySnapshot` | Returns local `EntraDeviceId`, `DeviceName`, optional `IntuneDeviceId` |
| `Get-ClientCertificate` | Selects a valid-date certificate with private key and Client Authentication EKU |
| `New-SignedInventoryRequest` | Returns the exact UTF-8 `BodyBytes` and signature headers for advanced integration |
| `New-InventoryEnvelope` | Wraps existing records in `LOGCOLLECTOR-INVENTORY-V1` |
| `Get-LogCollectorSpoolPath` | Computes the endpoint-specific queue directory without creating it |
| `Send-LogCollectorData` | Discovers identity/certificate, wraps, signs and submits existing record objects |
| `Sync-LogCollectorSpool` | Retries queued data without re-running the originating scripts |

The first four commands reuse the existing modules. The high-level facade does not duplicate
cryptography, certificate selection or retry logic.

## Submit existing data

This example uses the **currently configured** `InventoryWindows_CL` destination. It does not
collect additional data or modify device settings:

```powershell
$endpoint = 'https://logcollector-intake.azurewebsites.net/api/inventory'
$record = [pscustomobject]@{
    RecordType = 'Hardware'
    Model = 'Example model'
}

$result = Send-LogCollectorData -FrontendUrl $endpoint `
    -TableName 'InventoryWindows_CL' -Records @($record) `
    -Source 'ExistingInventoryScript' -Properties @{ CollectorVersion = '1.2.2' }

$result | Select-Object Disposition, StatusCode, Attempts, Spooled, SpoolDirectory
```

Replace `$record` with the objects the existing script already builds. A single object still goes
inside `@(...)`. Pass objects, **not an already serialized JSON string**. Hardware and software
destinations need separate calls if separate tables are retained.

For legacy JSON-producing code, deserialize into objects before calling the facade; do not
double-encode the body. Dates should be explicit UTC/ISO values and nested fields must match the
eventual DCR schema. The module preserves arrays, booleans, numbers and nested objects; it does not
rename legacy fields, change JSON-string columns to dynamic columns or make their schema choices.

**No client call creates or authorizes a table.** ACI destinations such as `DeviceInventory_CL`,
`AppInventory_CL`, `DSK_SMBv1Status_CL` and the SecureBoot tables are not enabled in the current
deployment. Create/map their schemas and DCR streams on the backend first, or intake returns 400.

## Outcomes and caller behavior

| `Disposition` | Meaning | `Spooled` |
|---|---|---|
| `Delivered` | Intake returned HTTP 202 and accepted the request for asynchronous processing | false |
| `Deferred` | `-QueueOnly` stored locally; no HTTP request or certificate lookup occurred | true |
| `AuthFailure` | Certificate unavailable or intake returned 401/403 | true |
| `Transient` | Network/5xx/429 failure or unexpected non-202 2xx response remained after bounded retries | true |
| `Permanent` | Server rejected the request permanently, such as an unconfigured table | false |

`StatusCode = 0` means no HTTP response, not success. HTTP 202 is not confirmation that rows have
already reached Log Analytics. The module never calls `exit` or decides whether a remediation,
copy operation or reboot succeeded. Existing scripts must keep those outcomes separate from
telemetry delivery. Use local logging for transport errors; do not recursively send the logger's
own delivery failures back through the same remote logger.

Unexpected local/provider errors, invalid envelopes and unsafe/unwritable spool paths are
terminating errors. They are not converted into successful-looking results. In particular, if
the Entra identity cannot be resolved, no invented identity is used and no envelope is queued.

## Certificate discovery and signing

The high-level commands obtain the actual local Entra device ID, then select a suitable
certificate. Optional selectors are `-CertificateThumbprint`, `-CertificateSubjectLike` and
`-CertificateIssuerLike`; they have the same semantics as `Get-ClientCertificate`.

Selection prefers the appropriate enterprise certificate, falling back to an Intune enrollment
certificate when identity-aware selection permits it. An explicit thumbprint is not a replacement
for server trust or identity checks. The certificate must be usable by the executing account;
SYSTEM tasks normally need the private key accessible in `LocalMachine\My`.

Expected absence has the stable error ID `LogCollector.ClientCertificateNotFound`. The facade
handles only this condition by retaining the envelope and reporting `AuthFailure`; unexpected
provider failures still propagate. A warning identifies certificate-unavailable deferral.
High-level commands dispose the certificate they obtain. If using `Get-ClientCertificate`
directly, the caller owns and must dispose the returned certificate.

### Optional PKI chain-role constraints

`Get-ClientCertificate`, `Send-LogCollectorData` and `Sync-LogCollectorSpool` accept
`PkiRootCaThumbprints`, `PkiRootCaSubjects`, `PkiIntermediateCaThumbprints` and
`PkiIntermediateCaSubjects` as string arrays. Empty arrays preserve existing behavior.
When enabled, selection validates the PKI chain against Windows trust before matching
the terminal Root CA and a non-root intermediate CA in their proper roles.
CA certificates must have Basic Constraints CA=true. Leaf thumbprint selection does
not waive the applicable PKI constraints.

Names are exact Subject DNs, not friendly names or wildcards. Pins are 40-hex SHA1
certificate thumbprints (whitespace/colon formatting is normalized). Each configured
role must match; when both name and thumbprint lists exist, the same CA must match both.
Malformed policy entries throw rather than silently disabling the policy.

Provision CA certificates through the normal Windows management channel, not this module.
Local selection skips revocation only; the Intake remains authoritative for revocation,
trust, device binding and authorization. Intune fallback remains independent of these PKI
constraints. See [pki-ca-policy.md](pki-ca-policy.md) for the matching server configuration.

Advanced signature-only usage:

```powershell
$identity = Get-DeviceIdentitySnapshot
$certificate = Get-ClientCertificate -EntraDeviceId $identity.EntraDeviceId
try {
    $envelope = New-InventoryEnvelope -TableName 'InventoryWindows_CL' `
        -Records @($record) -EntraDeviceId $identity.EntraDeviceId `
        -DeviceName $identity.DeviceName -IntuneDeviceId $identity.IntuneDeviceId
    $body = $envelope | ConvertTo-Json -Depth 24 -Compress
    $signed = New-SignedInventoryRequest -Uri $endpoint -Body $body -Certificate $certificate
    # $signed.BodyBytes and $signed.Headers belong to this exact request.
    # Do not print, persist or serialize the signature headers into the spool.
}
finally { $certificate.Dispose() }
```

Prefer `Send-LogCollectorData` for actual delivery. A manually built sender would still need
certificate TLS, exact byte transport, redirect protection, fresh signing on retries and spool.

Server authorization is unchanged: trusted certificate, signature, nonce, bound device ID and
allowed table are required. Intune additionally requires that exact Entra device to be enabled
in the intake managed identity's tenant. No client-side selector bypasses these controls.

## Offline, certificate renewal and post-reboot delivery

To record telemetry before a sensitive operation without waiting for the network:

```powershell
$queued = Send-LogCollectorData -FrontendUrl $endpoint `
    -TableName 'InventoryWindows_CL' -Records @($record) `
    -Source 'ExistingInventoryScript' -QueueOnly
```

To retry it later, without collecting inventory or repeating remediation:

```powershell
$drain = Sync-LogCollectorSpool -FrontendUrl $endpoint `
    -MaxEntriesPerRun 10 -MaxAttemptsPerEntry 2 -TimeoutSeconds 30
$drain | Select-Object Delivered, Quarantined, Remaining, Stopped, SpoolDirectory
```

Arrange this command in an existing periodic maintenance task or an explicitly provisioned
common drain task. The module does **not** install one. One-shot scripts cannot guarantee a later
drain by themselves. `-QueueOnly` before a reboot must finish successfully before data is considered
retained.

Each delivery attempt signs fresh with the currently selected certificate. Retained bodies,
including original identity and collection time, are unchanged. Certificate renewal for the same
device can repair an authentication failure; re-enrollment with a **different Entra device ID**
does not automatically make an old envelope valid, and the module never reattributes it.

## Spool isolation, bounds and operational limits

The default root is `C:\ProgramData\LogCollector\SharedSpool`. An SHA-256 directory derived from the
normalized endpoint URL isolates each destination. All scripts targeting the same endpoint/root
share that bucket; changing endpoints does not redirect old records.

The older collector's default `C:\ProgramData\LogCollector\Spool` is a separate legacy layout.
The facade does not import or drain it automatically. Do not move arbitrary old spool files into
the new queue or repair untrusted files' permissions and replay them.

Owner/DACL and reparse-point protections require SYSTEM or an elevated administrator. The package
does not weaken them. `SpoolRoot` must ultimately resolve to a protected, absolute local Windows
path on a fixed drive. User TEMP, network shares and user-writable code/spool locations are not
production installation paths.

| Parameter / bound | Default |
|---|---|
| `MaxAttempts` per new submission | 3 |
| `TimeoutSeconds` per HTTP attempt | 30 |
| `MaxDelaySeconds` maximum retry delay | 60 |
| `MaxDrainEntries` / `MaxDrainAttempts` before a new submission | 10 / 2 |
| `MaxSpoolAgeDays` | 7 |
| `MaxSpoolEntries` | 500 |
| `MaxSpoolTotalBytes` | 64 MiB, including serialized spool metadata |
| Envelope body limit | 4 MiB UTF-8 |
| Record count | 1 through 50,000 |
| Envelope annotations | At most 32 string values |
| JSON nesting | Up to depth 24; deeper values are rejected rather than truncated |

Limits are **per endpoint bucket**, not a reservation of disk space. Maintenance expires/evicts
entries according to the age/count/size policy; capacity is not unlimited. A new serialized entry
larger than the entire quota throws instead of claiming it was retained. Use consistent spool
policy across scripts sharing a bucket.

Retry delays use full jitter and honor Retry-After within configured bounds. Timeouts are **per
attempt**, not an overall operation deadline: drain, retries and certificate discovery can add
time. Use `-SkipDrain` for bounded new-send workflows and a separate drain task, or `-QueueOnly`
when an operation must not wait for HTTP.

The sender refuses HTTP redirects, and uses `Expect: 100-continue` for large mTLS bodies.
The facade requires an absolute HTTPS URL at `/api/inventory` with no user information, query
or fragment. Keep App Service certificate exclusions empty.

The module does not automatically split batches or transform schemas. An individual projected row
must also fit the worker's 850 KiB chunk limit. Per-event time should be a schema-approved field such
as `EventTimeUtc`; the server owns `TimeGenerated`, `CollectedAtUtc`, device identity, source,
correlation and record-index metadata.
