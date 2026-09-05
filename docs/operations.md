# Operations runbook

Deploy, verify, monitor and troubleshoot LogCollector.

## Prerequisites

| Tool | Version |
|---|---|
| .NET SDK | 10.0 |
| Azure CLI | current, with the Bicep CLI (`az bicep version`) |
| Azure Functions Core Tools | v4 |
| PowerShell | 7.x for build/test; **Windows PowerShell 5.1** on the fleet |
| Pester | 5.x |

Plus, from the enterprise PKI: base64 DER of the **public** root and issuing CA certificates.
Optionally the Intune MDM Device CA certificates to enable the second trust tier.

```powershell
# Export a CA certificate to base64 DER
[Convert]::ToBase64String((Get-Item Cert:\LocalMachine\Root\<thumbprint>).RawData)
```

Certificates are public data. Private keys, PFX files and passwords never belong in parameters,
source control, or app settings.

The public chain under `infra\certificates` comes from the `intune-wipe-api` reference
implementation. Confirm it matches the pilot device's chain before rollout:

| Certificate | SHA-1 thumbprint (identifier) | Expires |
|---|---|---|
| Microsoft Intune Root Certification Authority | `A197D6717352023B615F6ED444A6981ABC80F6C9` | 2030-09-15 |
| Microsoft Intune Device Management Device CA | `197E7F27389159E7D88FCB9062A92A7BFFF951F5` | 2028-09-15 |

## 1. Deploy infrastructure

```powershell
$subscription = 'b45c5b53-d8f3-4a4c-9fe5-5537818a9886'
az group create --subscription $subscription --name LOGCOLLECTOR-RG --location italynorth

# Deployed settings: public Intune CAs; enterprise PKI anchors are not configured.
# infra\main.bicepparam remains a separate sample for other environments.
az deployment group create `
  --subscription $subscription --resource-group LOGCOLLECTOR-RG --name LogCollector `
  --template-file infra\main.bicep `
  --parameters infra\logcollector.bicepparam
```

Capture the outputs:

```powershell
az deployment group show --subscription $subscription -g LOGCOLLECTOR-RG -n LogCollector `
  --query properties.outputs -o json
```

| Output | Used for |
|---|---|
| `frontendIngestUrl` | The `-FrontendUrl` given to devices |
| `frontendHealthUrl` | Liveness probe |
| `dataCollectionEndpoint`, `dataCollectionRuleImmutableId` | Already wired into worker settings |
| `frontendAppName`, `workerAppName` | Deployment targets |

### What gets created

Log Analytics workspace + `InventoryWindows_CL` custom table · Data Collection Endpoint + Rule ·
Application Insights · Storage (payload container, two deployment containers, nonce table, lifecycle
rule, shared-key access disabled) · Service Bus Standard namespace + queue (local auth disabled) ·
two user-assigned identities with least-privilege role assignments · Linux B1 plan + frontend
Function App with `clientCertMode: Required` · Flex Consumption FC1 plan + worker Function App.

### Role assignments

| Identity | Scope | Role | Why |
|---|---|---|---|
| Frontend | Storage account | Blob Data Owner | Payload writes plus the Functions host's own lease containers |
| Frontend | Storage account | Queue / Table Data Contributor | Host queues; nonce table |
| Frontend | Queue | Service Bus Data **Sender** | Send only — cannot read or delete messages |
| Worker | Storage account | Blob Data Owner | Payload read/delete plus host containers |
| Worker | Storage account | Queue / Table Data Contributor | Host state |
| Worker | Queue | Service Bus Data **Receiver** | Receive only — cannot inject messages |
| Worker | **DCR** | Monitoring Metrics Publisher | Scoped to the DCR, so only its declared streams are writable |
| Worker | DCE | Monitoring Reader | Endpoint resolution |

## 2. Deploy applications

### Intune fallback: grant tenant device-read permission

Deploy the frontend in the customer's Entra tenant. When Intune fallback is enabled, an Entra
administrator must grant **Microsoft Graph Device.Read.All (application)** to its user-assigned
managed identity. This is a Graph app-role assignment, not an Azure RBAC role; Bicep does not
silently grant tenant-wide directory permissions. Enterprise-PKI-only deployments do not need it.

The following idempotent helper resolves both the identity and Graph token in the specified
subscription's tenant. It does not change the caller's default Azure CLI subscription:

```powershell
.\scripts\Grant-IntuneGraphPermission.ps1 -SubscriptionId $subscription `
  -ResourceGroup LOGCOLLECTOR-RG -IdentityName LogCollector-intake-identity
```

Missing consent or unavailable Graph produces a failed submission, never an authorization bypass.
For the pilot, confirm the enrollment certificate's `.5.25` GUID equals the device's `dsregcmd`
Entra device ID. Shared Microsoft Intune roots belong only in the Intune trust settings.

The supplied Intune intermediate has no CRL/OCSP distribution endpoints: online chain validation
returns `RevocationStatusUnknown`. The deployed parameters explicitly set
`skipIntuneRevocationCheck = true`, while `checkRevocation = true` continues to protect enterprise
PKI. Signature, expiry, EKU, configured roots/issuer, binding and Graph checks are unchanged.
To block an Intune device, disable/delete its Entra device record. Retiring an MDM enrollment
alone is not guaranteed to disable that record, and this design does not check current MDM
management status or individual certificate revocation. Re-evaluate this exception when replacing
the Intune CA chain.

### Publish a selected component

```powershell
.\scripts\Publish-Function.ps1 -Component Frontend -Deploy `
  -SubscriptionId $subscription -ResourceGroup LOGCOLLECTOR-RG -AppName LogCollector-intake
.\scripts\Publish-Function.ps1 -Component Worker -Deploy `
  -SubscriptionId $subscription -ResourceGroup LOGCOLLECTOR-RG -AppName LogCollector-worker
```

The helper includes hidden `.azurefunctions` dependencies and validates package contents.
Without `-Deploy` it only creates a local package. Deploy only the component changed.
Frontend B1 deployments have no slot swap and can briefly restart the listener; clients retain
their spool and retry. Do not temporarily change SKUs merely to obtain deployment slots.
After changing app settings, let the configuration-triggered restart finish before ZIP deployment.
Overlapping these operations can make Kudu stop finalization with `SCM container restart` even
when the new package is already running. In that case confirm restart completion, retry the same
package without another settings change, and require a completed, successful deployment status.

Verify the frontend using a TLS client certificate:

```powershell
$certificate = Get-Item 'Cert:\LocalMachine\My\<client-certificate-thumbprint>'
Invoke-RestMethod https://logcollector-intake.azurewebsites.net/api/health -Certificate $certificate
# { status = ok; component = logcollector-frontend; configuredIngestionTargets = 1 }
```

`configuredIngestionTargets` of `0` means `Ingestion__StreamMap` is missing or malformed — every
submission would be rejected with "not an accepted ingestion target".

Do **not** exclude `/api/health` from mTLS. App Service enables TLS renegotiation whenever
`clientCertExclusionPaths` is nonempty, imposing a fixed **100 KB** upload limit and incompatible
TLS 1.3/HTTP/2 behavior. The deployed app uses `Required`, no exclusions and no built-in
unauthenticated health-check path; use an external certificate-bearing probe instead.
Health reports liveness/configuration, not full client authorization or ingestion success.
See [Microsoft's mTLS guidance](https://learn.microsoft.com/en-us/azure/app-service/app-service-web-configure-tls-mutual-auth).

The real client enables `Expect: 100-continue` (a header in PowerShell 7; the endpoint's
`ServicePoint.Expect100Continue` in Windows PowerShell 5.1). This avoids sending a large body
before the endpoint is ready. Exercise both runtimes on Windows:

```powershell
pwsh -NoProfile -File .\tests\Deployment\Test-IntakeEndpoint.ps1
powershell.exe -NoProfile -File .\tests\Deployment\Test-IntakeEndpoint.ps1
```

The probe creates and removes one untrusted, short-lived certificate in `CurrentUser\My`.
It expects 403 without a certificate, application 401 for signed bodies up to 1 MB, and a healthy
certificate-bearing liveness response. It does **not** establish positive end-to-end ingestion.

## 3. Onboard devices

Confirm the device has a usable certificate:

```powershell
Import-Module .\src\Client\DeviceIdentity.psm1
$id = Get-DeviceIdentitySnapshot
$id
Get-ClientCertificate -EntraDeviceId $id.EntraDeviceId -IssuerLike '*CONTOSO-ISSUING-CA*' -Verbose |
    Format-List Subject, Issuer, Thumbprint, NotAfter
```

Dry-run the payload without submitting:

```powershell
.\scripts\Invoke-CustomInventory.ps1 `
    -FrontendUrl 'https://<frontend>.azurewebsites.net/api/inventory' `
    -WhatIfSubmission
```

Register the task (elevated):

```powershell
.\scripts\Register-InventoryScheduledTask.ps1 `
    -FrontendUrl 'https://<frontend>.azurewebsites.net/api/inventory' `
    -TableName 'InventoryWindows_CL' `
    -CertificateIssuerLike '*CONTOSO-ISSUING-CA*'
```

The script writes `RandomDelay`, reads it back, and throws if it did not stick — the API accepts a
malformed value and silently disables the spread. Confirm independently:

```powershell
(Get-ScheduledTask -TaskName 'LogCollector-Inventory' -TaskPath '\LogCollector\').Triggers[0].RandomDelay
# PT2H
```

### Intune deployment

Package `scripts\` and `src\Client\` as a Win32 app or a platform script and run
`Register-InventoryScheduledTask.ps1` in SYSTEM context. Keep the relative layout: the collection
script resolves modules via `..\src\Client`.

## 4. Verify the pipeline

Force one run and inspect the result:

```powershell
Start-ScheduledTask -TaskName 'LogCollector-Inventory' -TaskPath '\LogCollector\'
(Get-ScheduledTaskInfo -TaskName 'LogCollector-Inventory' -TaskPath '\LogCollector\').LastTaskResult
# 0 = delivered; 1 = not delivered (spooled or rejected)
```

Or run it directly for a readable result object:

```powershell
.\scripts\Invoke-CustomInventory.ps1 -FrontendUrl 'https://…/api/inventory' -Verbose
# TableName Records Disposition StatusCode Spooled Drained
```

Then in Log Analytics (allow 10–15 minutes for first-time DCR propagation):

```kusto
InventoryWindows_CL
| where TimeGenerated > ago(1h)
| summarize Rows = count(), Devices = dcount(EntraDeviceId) by RecordType
| order by Rows desc
```

```kusto
// Fleet coverage over the last day
InventoryWindows_CL
| where TimeGenerated > ago(1d)
| summarize LastSeen = max(TimeGenerated), Areas = make_set(RecordType) by DeviceName, EntraDeviceId
| order by LastSeen asc
```

```kusto
// End-to-end latency: collected on the device vs. ingested
InventoryWindows_CL
| where TimeGenerated > ago(1d)
| extend LagMinutes = datetime_diff('minute', TimeGenerated, CollectedAtUtc)
| summarize p50 = percentile(LagMinutes, 50), p95 = percentile(LagMinutes, 95), max(LagMinutes)
```

## 5. Monitor

The DCR diagnostic setting sends ingestion transformation errors to `DCRErrorLogs`:

```kusto
DCRErrorLogs
| where TimeGenerated > ago(1d)
| order by TimeGenerated desc
```

HTTP 202 is intake acknowledgement only. Service Bus delivery and Logs Ingestion retries are
at-least-once; use `arg_max(TimeGenerated, *) by EntraDeviceId, CorrelationId, RecordIndex`
when duplicate rows would distort counts.

```kusto
// Rejections by reason
AppTraces
| where TimeGenerated > ago(1d)
| where AppRoleName startswith "logcollector" and Message startswith "Submission denied"
| summarize Count = count() by Message
| order by Count desc
```

```kusto
// Oversized rows are dead-lettered with their payload retained
AppTraces
| where TimeGenerated > ago(7d)
| where Message contains "oversized"
| project TimeGenerated, Message
```

```kusto
// Ingestion throttling
AppTraces
| where TimeGenerated > ago(1d)
| where Message contains "Logs Ingestion returned 429"
| summarize count() by bin(TimeGenerated, 15m)
```

Alert-worthy signals:

| Signal | Threshold | Meaning |
|---|---|---|
| Dead-letter message count | `> 0` | Poison payloads; inspect the DLQ reason |
| Active queue message count | rising for > 30 min | Check trigger synchronization, RBAC, runtime and worker errors |
| `Submission denied` 401/403 rate | sudden spike | Certificate rollout or expiry problem |
| Distinct devices per day | sudden drop | Task, certificate or network regression |
| Sustained 429 from ingestion | any | DCR throughput limit reached |

Inspect the dead-letter queue:

```powershell
az servicebus queue show --subscription $subscription -g LOGCOLLECTOR-RG `
  --namespace-name LogCollector-servicebus --name inventory-ingestion `
  --query countDetails
```

Dead-letter reasons are `MalformedPointer` or `UnprocessablePayload`, with the specific cause in the
description.

## 6. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Client: `403` from App Service before reaching the function | No client certificate presented | Confirm the certificate has a private key and Client Authentication EKU; SYSTEM context can read `LocalMachine\My` |
| Large upload resets, while small requests work | mTLS exclusions/renegotiation, or body sent too early | Remove **all** certificate exclusion paths; deploy the client with `Expect: 100-continue` |
| `401 client cert: certificate chain build failed` | Wrong or missing trust anchors | Check `ClientCert__TrustedRootCertificates`; roots must be self-signed, intermediates go in the intermediate setting |
| `401 client cert: trust anchor not configured` | No anchors at all | Fail-closed by design; supply at least one tier |
| `401 request signature verification failed` | Body altered in transit, or a proxy re-encoded it | Ensure nothing rewrites the body; the client signs raw bytes |
| `401 missing the configured device-id binding claim` | Certificate template has no device id | Add a SAN URI `urn:uuid:<guid>`, or use `ClientCert__ThumbprintToDeviceMap` |
| `403 not bound to the submitted device` | Certificate belongs to another device | Re-issue for the correct device; do **not** relax the binding |
| `400 skew … exceeds …` | Device clock drift | Fix time sync; do not widen the window as a workaround |
| `409 duplicate nonce` | Genuine replay, or a client resending an identical signed request | Expected on replay; the client re-signs per attempt, so it should not occur normally |
| `400 not an accepted ingestion target` | `Ingestion__StreamMap` missing the table | Add `Table_CL=Custom-Table_CL` on **both** apps |
| Queue grows, worker idle | Trigger deployment/synchronization or identity permissions | Check functions metadata, deployment status and Service Bus Data Receiver role |
| Ingestion 403 | Missing DCR role | Assign Monitoring Metrics Publisher on the DCR to the worker identity |
| Rows accepted but not queryable | DCR still propagating, or a stream/table column mismatch | Wait 15 min; then compare DCR `streamDeclarations` with the table schema |
| Spool grows on a device | Endpoint unreachable or auth failing | Check `quarantine\` for the HTTP status suffix in the file names |

### Reading a device's spool

The spool requires SYSTEM or an elevated administrator. New paths are created with protected
SYSTEM/Administrators ACLs. User-owned, writable or reparse-point paths are rejected, including
unsafe ancestors. Do not use a user's TEMP directory for production spooling.

**Unsafe legacy spools must not be repaired and replayed.** Stop the scheduled task, isolate the
old spool for incident inspection, discard untrusted entries, and provision a new protected path.
Changing only the ACL would legitimize inventory an ordinary user may already have planted.
Install `scripts\` and `src\Client\` in an administrator-controlled location as well; protecting
the data directory alone cannot protect a SYSTEM task whose executable scripts are user-writable.

```powershell
Import-Module .\src\Client\InventorySpool.psm1
Get-SpoolEntry -SpoolDirectory 'C:\ProgramData\LogCollector\Spool' |
    Select-Object CreatedUtc, TableName, Attempts, Path

# Permanently rejected entries, with the reason in the file name
Get-ChildItem 'C:\ProgramData\LogCollector\Spool\quarantine'
```

### Certificate rotation

Rotation needs no client change: `Get-ClientCertificate` selects the certificate whose device id
matches, preferring the longest-lived, so a renewed certificate is picked up on the next run.

Adding a new issuing CA: append its base64 DER to `ClientCert__TrustedIntermediateCertificates` (or
`__TrustedRootCertificates` for a new root) **before** issuance begins. Both old and new can be
trusted simultaneously, so rollout does not need a cutover.

Emergency containment: configure `ClientCert__AllowedLeafThumbprints` as an explicit list of
known-good leaves, excluding the compromised certificate. This is an **allow-list**, not a
deny-list; an empty value removes the restriction. Apply the app setting and allow the app to
restart. For an Intune device, disable/delete its Entra device record to deny subsequent requests.

## 7. Validation before a release

```powershell
dotnet build LogCollector.slnx
dotnet test  LogCollector.slnx

Invoke-Pester -Path tests/Pester

# Run elevated: spool smoke creates protected paths under ProgramData.
# A non-elevated -SkipSpool run exercises signing only, not privileged spooling.
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
    -ExecutionPolicy Bypass -File tests/Pester/Invoke-Ps51SmokeTest.ps1

az bicep build --file infra/main.bicep --stdout
az bicep build-params --file infra/main.bicepparam --stdout
```

A what-if against a live resource group before applying infrastructure changes:

```powershell
az deployment group what-if --subscription $subscription -g LOGCOLLECTOR-RG `
  --template-file infra\main.bicep --parameters infra\logcollector.bicepparam
```

## 8. Capacity notes

- **Frontend B1, one instance.** Ten thousand devices submitting during a two-hour window average
  roughly 1.4 requests/second. This is not a capacity guarantee: certificate-chain checks, payload
  size and burst distribution require a representative load test. B1 has manual scale-out only.
- **Worker Flex** defaults to on-demand scaling with no always-ready instances. Always-ready
  capacity is an optional paid latency optimization, not a requirement for managed identity.
- **Service Bus Standard** is sized for pointer messages (< 1 KB each), not payloads. Payload growth
  does not change queue load.
- **Ingestion** is bounded per DCR. Sustained 429s mean the DCR limit is reached; add a second DCR
  and split tables across them rather than raising client concurrency.
- **Storage** grows at `payload size × devices × runs/day × payloadRetentionDays`. The lifecycle rule
  bounds it; enabling `Ingestion__DeleteBlobAfterIngestion` bounds it further at the cost of the
  replay window.
