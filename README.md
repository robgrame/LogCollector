# LogCollector

Purpose-independent, certificate-authenticated device telemetry ingestion into Azure Monitor.
Inventory, remediation results, health checks and other scripts share the same ingestion platform.

A script on each device produces records, signs them with the device's own certificate, and
posts it over mutual TLS to a frontend Azure Function. The frontend authenticates the device, parks
the payload in Blob storage, and enqueues a pointer on Service Bus. A worker Function drains the
queue and writes rows to a Log Analytics custom table through the Azure Monitor Logs Ingestion API.

**There is no Function key, no shared secret, and no Log Analytics workspace key anywhere in this
solution.** The device certificate is the only client credential, and every service-to-service hop
uses a user-assigned managed identity.

**Inventory is one producer, not a platform requirement.** The frontend `TelemetryIngestFunction`
(`SubmitTelemetry`, `POST /api/submit`) and worker `TelemetryIngestionFunction` (`IngestTelemetry`)
have no inventory schema or collection logic. `tableName` selects an operator-approved DCR stream;
`source` labels the producing script. Both accept arbitrary record objects without requiring
`RecordType`, hardware or software fields. A new purpose needs a table/schema and stream mapping,
not another Function or a platform code change. See the
[customer procedure for adding a telemetry collection](docs/customer-add-telemetry-collection.md)
and [Adding a purpose](docs/operations.md#adding-a-purpose).

Backend **1.2.2** accepts `LOGCOLLECTOR-TELEMETRY-V1` and the legacy
`LOGCOLLECTOR-INVENTORY-V1` wire format. `/api/inventory` is an explicit compatibility alias through
the **same** authentication and processing path. Existing inventory packages, table names, queues,
retained blobs and spool entries are not renamed or rewritten.

---

## Architecture

```text
 Windows device (Scheduled Task, SYSTEM, 2-hour RandomDelay)
   │  Windows PowerShell 5.1
   │  • resolve Entra device id (dsregcmd)
   │  • select certificate: enterprise PKI, else Intune enrollment cert
   │  • build LOGCOLLECTOR-TELEMETRY-V1 envelope
   │  • drain local spool, then submit
   │
   │  HTTPS 1.2+ / mTLS
   │  IDA-SIGNATURE-V1 signature over the exact body bytes
   │  X-Request-Timestamp + X-Request-Nonce
   ▼
 Frontend Function App  —  Linux, App Service B1, Always On, client certs REQUIRED
   │  • App Service terminates TLS, forwards the leaf in X-ARR-ClientCert
   │  • re-validate chain against enterprise PKI / Intune trust anchors
   │  • verify body signature with the certificate's public key
   │  • reserve (cert, nonce) atomically in Azure Table  → anti-replay
   │  • prove cert ↔ envelope Entra device id binding    → anti-IDOR
   │  • enforce the table → DCR stream allow-list
   │  • write payload blob, then enqueue a pointer
   ▼
 Azure Blob (payload)  +  Service Bus Standard queue (pointer only, ≤ 1 KB)
   ▼
 Worker Function App  —  .NET 10 isolated, Flex Consumption (FC1), scale-to-zero
   │  • resolve blob against its OWN account (no URI from the message)
   │  • re-verify the SHA-256 recorded at intake
   │  • project rows, stamp server-asserted identity columns
   │  • chunk to ≤ 850 KB, retry honouring Retry-After
   │  • complete / dead-letter explicitly
   ▼
 Azure Monitor Logs Ingestion API → DCE → DCR → Log Analytics custom table
```

### Why the split

| Decision | Reason |
|---|---|
| Frontend on **B1 App Service**, not Flex | Flex Consumption does not support `clientCertEnabled`. Mandatory client certificates *are* the authentication model, so the ingress must run where the platform can perform the mTLS handshake. Always On keeps that listener warm. |
| Worker on **Flex Consumption** | Purely event-driven with bursty load. Scale-to-zero and per-second billing suit it; it has no HTTP surface, so it needs nothing from the B1 tier. |
| **Pointer messages** on Service Bus | Inventory payloads routinely exceed the 256 KB Service Bus Standard limit. Only blob coordinates travel on the queue, so message size is constant regardless of fleet or payload growth. |
| **Two Function Apps**, two identities | Queue RBAC separates *send* from *receive*. The default shared host/deployment storage remains a common trust boundary, not strong isolation against a compromised application. |

---

## Repository layout

```text
LogCollector/
├── LogCollector.slnx
├── README.md
├── docs/
│   ├── security.md              Threat model and control-by-control rationale
│   ├── secure-ingestion.md      Wire protocol and ingestion design notes
│   └── operations.md            Deploy, verify, monitor, troubleshoot
├── infra/
│   ├── main.bicep               Complete deployment
│   ├── main.bicepparam          Sample parameters (public CA certs only)
│   ├── logcollector.bicepparam  Deployed Italy North configuration
│   └── certificates/           Public Intune CA chain
├── scripts/
│   ├── Invoke-CustomInventory.ps1        Collection + submission entry point
│   ├── Register-InventoryScheduledTask.ps1
│   ├── Publish-Function.ps1              Targeted application deployment
│   └── Grant-IntuneGraphPermission.ps1   Idempotent Graph permission grant
├── src/
│   ├── Client/                  Windows PowerShell 5.1 modules
│   │   ├── DeviceIdentity.psm1  Entra device id + dual-tier certificate selection
│   │   ├── RequestSigning.psm1  IDA-SIGNATURE-V1 canonicalisation and signing
│   │   ├── InventorySpool.psm1  Durable local spool
│   │   └── InventoryClient.psm1 Envelope, backoff, drain, submit
│   ├── Shared/                  LogCollector.Shared (net10.0 library)
│   │   ├── Models/              TelemetryEnvelope, QueuedIngestionMessage
│   │   ├── Security/            Cert validation, signing, replay, orchestration
│   │   └── Ingestion/           Chunker, Retry-After policy, row factory, stream map
│   └── Functions/
│       ├── Frontend/            Ingress Function App
│       └── Worker/              Ingestion Function App
└── tests/
    ├── LogCollector.Shared.Tests/   xUnit regression tests
    ├── Pester/                      Pester 5 + PS 5.1 smoke test
    └── Deployment/                  Live intake transport probe
```

---

## Security model

Six complementary controls run in a fixed, fail-closed order.

| # | Control | What it stops |
|---|---|---|
| 1 | **Timestamp freshness** (`X-Request-Timestamp`, ±5 min) | Long-delayed capture-and-resend. Checked first because it is free and sheds obvious junk before any expensive work. |
| 2 | **Client certificate chain** | Any caller without a certificate issued by the enterprise PKI *or* by an explicitly configured Intune Device CA. Validated by the app, not just by the edge. |
| 3 | **Body signature** (`IDA-SIGNATURE-V1`) | Body substitution under a legitimate certificate. TLS is terminated at the App Service edge, so the handshake alone does not bind the certificate to the body the function actually reads. |
| 4 | **Nonce reservation** (Azure Table, insert-only) | Replay of a byte-identical, still-fresh request. The insert is atomic, so the protection holds across scaled-out instances. Reserved *after* steps 2 and 3 so unauthenticated traffic cannot flood the table. |
| 5 | **Certificate ↔ device binding** | A valid device submitting inventory attributed to a *different* device (IDOR). The device id must be an exact GUID in the certificate; substrings are rejected. |
| 6 | **Table → DCR stream allow-list** | A client choosing an arbitrary ingestion destination. An unmapped table name fails closed. |

**Intune tenant authorization is mandatory before intake.** Microsoft Intune CA roots can be
shared across tenants. A valid enrollment certificate therefore is not sufficient authorization.
After signature and device binding, the frontend looks up the bound device in Microsoft Graph
using its own managed identity and requires an enabled device in that identity's tenant.
The frontend identity needs Graph **Device.Read.All (application)** permission with administrator
consent for the Intune fallback. Graph failures never bypass this check.

Then, at the data layer, `TelemetryRowFactory` writes the server-asserted identity columns **after**
copying client fields, so a record containing its own `EntraDeviceId` cannot spoof attribution.

### Dual trust: enterprise PKI and Intune enrollment

Devices are covered by one of two independent certificate tiers.

1. **Enterprise PKI** — chains to operator-supplied root anchors, optionally pinned further by CA
   thumbprint or subject. Preferred, because the enterprise controls issuance and revocation.
2. **Intune enrollment** — the MDM enrollment certificate, carrying the Entra device id in OID
   `1.2.840.113556.5.25`.

The Intune tier is consulted only when the enterprise tier rejects the chain, **and** the fallback is
enabled, **and** Intune anchors are configured, **and** the issuer DN is on the allow-list.
The binding comes from a CA-asserted value inside a verified chain. Revocation differs when an
Intune chain has no CRL/OCSP endpoints: the explicit `SkipIntuneRevocationCheck` option skips
only that tier's revocation check, never enterprise PKI's. Graph tenant authorization remains
mandatory; disabling or deleting the Entra device blocks subsequent Intune submissions.
This is not proof of current MDM enrollment or individual certificate revocation.

On the client side the same asymmetry appears deliberately: `-CertificateIssuerLike` narrows the
*PKI* tier only. That pin is normally set to the corporate CA, so applying it to the fallback would
filter out the very certificate the fallback exists to find, and a device with no PKI certificate
could never authenticate.

### Why the endpoint is `AuthorizationLevel.Anonymous`

A Function key is a bearer secret that would have to be distributed to every managed device, cannot
be rotated per device, and is trivially recoverable from a scheduled task's command line. It adds a
credential to steal without adding assurance. Adding one back would not strengthen this design — it
would reintroduce exactly the shared secret this design exists to eliminate.

Full rationale, threat model, and residual risks: **[docs/security.md](docs/security.md)**.

---

## The wire contract

### Request

```http
POST /api/submit HTTP/1.1
Content-Type: application/json
X-Request-Timestamp: 2026-01-02T03:04:05.6780000+00:00
X-Request-Nonce: 11111111-2222-3333-4444-555555555555
X-Request-Signature-Version: IDA-SIGNATURE-V1
X-Request-Signature-Algorithm: RSA-PKCS1-SHA256
X-Request-Signature: <base64>
```

### Canonical string (signed)

Six LF-separated lines. This is a cross-language contract between
`src/Client/RequestSigning.psm1` and `src/Shared/Security/RequestSignatureVerifier.cs`, pinned on
both sides by a golden-vector test.

```text
IDA-SIGNATURE-V1
POST
/api/submit
2026-01-02T03:04:05.6780000+00:00
11111111-2222-3333-4444-555555555555
<base64(SHA-256(exact body bytes))>
```

### Body

```json
{
  "envelopeVersion": "LOGCOLLECTOR-TELEMETRY-V1",
  "tableName": "RemediationResults_CL",
  "entraDeviceId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
  "deviceName": "WKS-001",
  "intuneDeviceId": "…",
  "correlationId": "…",
  "source": "DiskCleanup",
  "collectedAtUtc": "2026-04-01T06:00:00.0000000+00:00",
  "properties": { "CollectorVersion": "1.0.3" },
  "records": [ { "Result": "Succeeded", "FreedBytes": 1048576 } ]
}
```

### Responses

| Status | Meaning | Client behaviour |
|---|---|---|
| `202 Accepted` | Queued for ingestion | Done |
| `400 Bad Request` | Malformed envelope, stale timestamp, unmapped table | **Permanent** — quarantine, never replay |
| `401 Unauthorized` | Certificate or signature rejected | **AuthFailure** — keep spooled; renewal can repair it |
| `403 Forbidden` | Certificate not bound to the submitted device | **AuthFailure** |
| `409 Conflict` | Duplicate nonce (replay) | **Permanent** |
| `413 Payload Too Large` | Body over the configured limit | **Permanent** |
| `429` / `5xx` | Throttled or unavailable | **Transient** — back off, then spool |

---

## Client reliability

### Shared client for existing scripts

Import **`src\Client\LogCollector.Client.psd1`** to reuse identity discovery, certificate selection,
signing and delivery from independent scripts. `Send-LogCollectorData` accepts existing record
objects; `Sync-LogCollectorSpool` retries retained data without re-running collection/remediation.
`-QueueOnly` persists before a reboot without attempting HTTP. Certificate absence is retained
explicitly; a missing Entra identity or unexpected local error is not silently bypassed.

Package the six-file, versioned module with **`scripts\Publish-ClientModule.ps1`**.
See **[shared-client.md](docs/shared-client.md)** for installation, examples, return values,
endpoint-isolated spool and limits.

**Universal inventory package.** Build a self-contained folder for any deployment:

```powershell
.\scripts\Publish-InventoryPackage.ps1 `
    -FrontendUrl 'https://<your-intake>.azurewebsites.net/api/inventory' `
    -Environment 'MSLabs'
```

For a complete `.intunewin` release, use `scripts\Publish-IntuneWin32Package.ps1`
with a local Microsoft `IntuneWinAppUtil.exe`. See
[Intune Win32 deployment](docs/intune-win32-deployment.md) for the laboratory build
command, install/uninstall commands, detection settings and requirements.
The generated detection script pins the final configuration SHA256 and checks task
actions, SYSTEM identity and enablement. For configuration-only updates, replace
both the app content and its generated detection script in the same Required app;
Intune can reapply the desired configuration without uninstalling first.
Package **1.4.5** also writes protected, bounded JSONL lifecycle, inventory and
spool logs under `C:\ProgramData\LogCollector\Logs\CustomInventory`, using selected
metadata rather than a transcript of payloads or HTTP response bodies.

The current package source is **1.5.0** and includes shared client **1.5.0**, including schema-sample export.
Existing installed packages remain compatible with their configured inventory endpoints and tables.
The folder-only builder creates `out\Inventory\1.5.0`, ready for Intune Win32 packaging with `Install.ps1`
as setup file. Scripts, task names and install paths are customer-neutral. Endpoint,
environment and table names are supplied as configuration; `-DeviceTableName` and
`-AppTableName` default to **DeviceInventory_CL** and **AppInventory_CL** to retain existing
destinations and record contracts, not redirect queries to InventoryWindows_CL.
The folder includes collection, shared modules, configuration, install/uninstall/detection
and an independent spool task. See the [package guide](src/InventoryPackage/README.md).
No original customer scripts are modified. Live submission and installed tasks default to
disabled until the selected table schemas, DCR transforms and both app mappings are ready;
`Run-Inventory.ps1 -Preview` and `-QueueOnly` support local preparation.

Version **1.1.1** adds symmetric PKI Root CA/intermediate Subject and thumbprint
constraints to the shared client, inventory package and Intake. The new lists default
to empty, preserve the independent Intune profile and do not install trust anchors.
See [PKI CA policy](docs/pki-ca-policy.md) for the matching rules and client/Intake/Bicep settings.
Versions use **Major.Minor.Build**: increment Build with each modification/commit,
Minor for new functionality and Major for substantial changes.

**Large mTLS uploads.** The client enables `Expect: 100-continue` using the runtime-appropriate
transport API. App Service must use `clientCertMode: Required` with **no certificate exclusion
paths**: even excluding health enables TLS renegotiation and imposes a fixed 100 KB upload limit.
Health therefore requires a TLS client certificate too; see the runbook.

**Exponential backoff with full jitter.** The delay is uniform over `[0, min(base·2ⁿ, ceiling)]`, not
"backoff plus a little noise". Full jitter is what actually de-correlates thousands of devices that
all failed against the same outage; partial jitter leaves them clustered and the recovery re-triggers
the outage. A server-supplied `Retry-After` takes precedence over the computed delay, subject to
the documented retry safety limits.

**Durable spool** (`C:\ProgramData\LogCollector\Spool`):

- *Atomic writes* — content goes to `.tmp` and is then moved, so a crash never leaves a half-written
  entry that a later drain would parse as valid.
- *Bounded growth* — age (7 days), count (500) and total size (64 MB) quotas are enforced on every
  save and every drain. A device offline for a month must not fill its system drive.
- *Drain-before-submit* — the backlog gets the freshest connectivity instead of starving behind new
  data.
- *Oldest first, stop on first transient failure* — continuing against a service that just returned
  503 turns one outage into a fleet-wide self-inflicted DDoS.
- *Re-signed on every attempt* — signatures are timestamp- and nonce-bound, so a spooled entry is
  signed fresh at drain time. Storing the original signature would guarantee a replay rejection.
- *Quarantine, not infinite retry* — permanently rejected or corrupt entries move aside for operator
  inspection and age out under the same quota.
- *Single-writer lock* — two overlapping runs must not deliver the same entry twice.

### Scheduled task

The original **Wednesday/Saturday at 09:00** cadence is preserved. Registered as SYSTEM with a
**`PT2H` RandomDelay on the trigger**, and the script does not sleep.
Both would double the spread and make the effective window four hours wide. The delay belongs on the
trigger, not in the script: a `Start-Sleep` would hold a PowerShell process for up to two hours on
every endpoint, invisible to Task Scheduler and fighting the execution time limit.
`Register-InventoryScheduledTask.ps1` writes `RandomDelay` through the task object and then reads it
back and fails loudly if it did not stick — the API accepts a malformed value and silently disables
the spread.

### Inventory areas

The collector includes hardware, operating system, installed software from both registry views,
network adapters, TPM/Secure Boot, disks/volumes, and BitLocker status. BitLocker emits protector
**types**, never recovery passwords. Each requested area emits `CollectionStatus` diagnostics so
unavailable providers are distinguishable from absent hardware or empty results.

Use `-Collect Disk,BitLocker` interactively or when registering the task to select areas.
The registration helper transports this as `-CollectCsv "Disk,BitLocker"` because native
`powershell.exe -File` does not bind PowerShell array expressions.

---

## Worker ingestion

- **Chunking at 850 KB.** The documented API limit is 1 MB. The margin absorbs request framing and
  server-side normalisation, and stops a batch that sits on the boundary from oscillating between
  accepted and rejected.
- **An oversized row dead-letters the message before any rows are uploaded.** The payload is
  retained for operator remediation rather than reporting partial data as a successful inventory.
- **`Retry-After` is honoured exactly once.** The Azure SDK's own retry policy is disabled, so the
  backoff visible in telemetry is the backoff actually applied.
- **Explicit message disposition** (`autoCompleteMessages: false`): success completes; a permanent
  failure dead-letters immediately with a reason instead of burning ten deliveries and ten ingestion
  calls; a transient failure rethrows for normal redelivery.
- **No URI from the message.** The pointer carries container and blob *names*, resolved against the
  worker's own configured account, so a forged message cannot cause an SSRF fetch.
- **Safe deletion.** Payload deletion is off by default (retention is governed by the storage
  lifecycle rule, preserving a replay window). When enabled, deletion is conditional on the ETag read
  at ingestion time, so a concurrent overwrite is preserved rather than destroyed. A failed delete is
  logged and ignored — failing the message there would re-ingest already-committed rows.

### Delivery semantics

Delivery is **at least once**, not exactly once. The authenticated body determines a stable
SHA-256 `CorrelationId`, and each projected row receives a server-assigned `RecordIndex`.
Service Bus suppresses duplicate sends within its one-hour detection window. A worker crash
after ingestion, a partially successful multi-chunk upload, or a later client retry can still
produce duplicate Log Analytics rows. Use `(EntraDeviceId, CorrelationId, RecordIndex)` to
deduplicate analytical queries; the Logs Ingestion API does not offer an idempotent write token.

```kusto
InventoryWindows_CL
| summarize arg_max(TimeGenerated, *) by EntraDeviceId, CorrelationId, RecordIndex
```

`202` means the payload and pointer are durably accepted, not that the data is already queryable.
Monitor the DLQ and `DCRErrorLogs` for subsequent failures. Blob retention is finite; recover
dead-lettered payloads before the configured lifecycle expiration.

---

## Publish a sanitized public mirror

Keep the development repository private and treat it as the source of truth. Publish only a
history-free snapshot to a separate public repository:

```powershell
# Local-only file, ignored by Git: one customer-specific literal per line.
@('CustomerName', 'customer.example.com') |
    Set-Content .public-release-policy.local.txt

.\scripts\Publish-PublicSnapshot.ps1 `
    -Repository '<owner>/LogCollector-public'
```

The publisher exports only files tracked by the selected committed ref, scans them before any
GitHub change, and blocks unknown GUIDs, concrete Azure endpoints, real email addresses, public
IP addresses, common credential forms, customer OneDrive paths, and local deny-list matches.
It never transfers private Git history. Run with `-ScanOnly` to validate without creating or
updating the public repository. Do not merge from the private repository into the public mirror.

---

## Deploy

### Prerequisites

- .NET 10 SDK, Azure CLI with the Bicep CLI, Azure Functions Core Tools v4
- Base64 DER of your enterprise root/issuing CA certificates (public certificates only)
- Optionally, the Intune MDM Device CA certificate(s) to enable the second trust tier

### 1. Infrastructure

```powershell
$subscription = '00000000-0000-0000-0000-000000000000'
az group create --subscription $subscription --name LOGCOLLECTOR-RG --location italynorth

# Export a CA certificate to base64 DER:
#   [Convert]::ToBase64String((Get-Item Cert:\LocalMachine\Root\<thumbprint>).RawData)

az deployment group create `
  --subscription $subscription --resource-group LOGCOLLECTOR-RG --name LogCollector `
  --template-file infra\main.bicep `
  --parameters infra\logcollector.bicepparam
```

Record the outputs: `frontendIngestUrl`, `dataCollectionEndpoint`, `dataCollectionRuleImmutableId`.
For Intune fallback, complete the administrator-operated Graph `Device.Read.All` grant in
[the runbook](docs/operations.md#intune-fallback-grant-tenant-device-read-permission) before onboarding.

**Naming and collisions:** the storage account and Function app names are globally unique
across all of Azure. On a first-time deployment, set `customerPrefix` (e.g. `'aci'`) in the
parameter file to a short customer/company code to avoid colliding with a name already taken
by another tenant; leave it empty (default) only when redeploying an existing installation,
since changing it later renames rather than migrates the affected resources.

### 2. Applications

```powershell
.\scripts\Publish-Function.ps1 -Component Frontend -Deploy `
  -SubscriptionId $subscription -ResourceGroup LOGCOLLECTOR-RG -AppName LogCollector-intake
.\scripts\Publish-Function.ps1 -Component Worker -Deploy `
  -SubscriptionId $subscription -ResourceGroup LOGCOLLECTOR-RG -AppName LogCollector-worker
```

Omit `-Deploy` to build packages locally without touching Azure. Packaging includes the hidden
`.azurefunctions` directory; `Compress-Archive` can omit it and produce an unusable deployment.
B1 has no deployment slots: allow for a restart during frontend deployment.

### Client deployment package (no source, no .NET SDK required on target)

To hand off a self-contained package that deploys infrastructure and pre-built Function apps
with **no .pdb files**, using only the Azure CLI on the target machine:

```powershell
.\scripts\Publish-DeploymentPackage.ps1
```

This builds Frontend and Worker in Release, strips debug symbols, and produces
`out\Deploy\<version>\` containing `infra\` (Bicep template, parameter file, certificates),
`Functions\Frontend.zip` / `Functions\Worker.zip`, a generated `Deploy-LogCollector.ps1`
orchestrator, a `MANIFEST.json` with package hashes, and a `README.md` with usage instructions.
Deploy it with:

```powershell
.\Deploy-LogCollector.ps1 -SubscriptionId <sub-id> -ResourceGroup LOGCOLLECTOR-RG -Location italynorth
```

### 3. Devices

```powershell
.\scripts\Register-InventoryScheduledTask.ps1 `
    -FrontendUrl 'https://<your-intake>.azurewebsites.net/api/inventory' `
    -TableName 'InventoryWindows_CL' `
    -CertificateIssuerLike '*CONTOSO-ISSUING-CA*'
```

Full runbook, verification queries and troubleshooting: **[docs/operations.md](docs/operations.md)**.

---

## Configuration reference

### Frontend

| Setting | Default | Purpose |
|---|---|---|
| `ServiceBus__fullyQualifiedNamespace` | — | Namespace host name |
| `ServiceBus__QueueName` | `inventory-ingestion` | Shared pointer queue; deployed resource name is preserved |
| `Storage__AccountName` / `Storage__PayloadContainer` | — / `inventory-payloads` | Payload blobs |
| `Replay__StorageAccount` / `Replay__TableName` | — / `RequestNonces` | Nonce store |
| `Replay__MaxTimestampSkewSeconds` | `300` | Freshness window (clamped 30–3600) |
| `Replay__NonceRetentionSeconds` | `7200` | Raised automatically to ≥ 2× skew |
| `RequestSignature__Required` | `true` | Fail-closed body signing |
| `RequestSignature__MaxBodyBytes` | `4194304` | Request size ceiling |
| `ClientCert__RequireClientCert` / `__RequireDeviceBinding` / `__RequireClientAuthEku` | `true` | Fail-closed switches |
| `ClientCert__TrustedRootCertificates` / `__TrustedIntermediateCertificates` | — | Enterprise PKI tier |
| `ClientCert__PkiRootCaThumbprints` / `__PkiRootCaSubjects` | empty | Constraints on the terminal PKI Root CA; both lists must match the same CA |
| `ClientCert__PkiIntermediateCaThumbprints` / `__PkiIntermediateCaSubjects` | empty | Constraints on at least one non-root CA; additive to the Root requirement |
| `ClientCert__TrustedIntuneRootCertificates` / `__TrustedIntuneIntermediateCertificates` | — | Intune tier |
| `ClientCert__AllowIntuneEnrollmentCertificateFallback` | `true` | Enable tier 2 |
| `ClientCert__IntuneEnrollmentIssuerSubjects` | Microsoft Intune Device CAs | Issuer allow-list |
| `ClientCert__DeviceIdBindingClaim` | `Auto` | `SubjectCN`/`SanDns`/`SanUri`/`Thumbprint`/`IntuneEnrollmentOid` |
| `ClientCert__ThumbprintToDeviceMap` | — | `THUMB=guid|…` for templates without an embedded id |
| `ClientCert__CheckRevocation` | `true` | CRL/OCSP |
| `ClientCert__SkipIntuneRevocationCheck` | `false` | Explicit Intune-only exception for chains without CRL/OCSP; enabled in the deployed parameters |
| `Ingestion__StreamMap` | — | `Table_CL=Custom-Table_CL;…` allow-list |
| `Intake__MaxRecordsPerEnvelope` | `50000` | Record ceiling |

### Worker

| Setting | Default | Purpose |
|---|---|---|
| `Ingestion__DataCollectionEndpoint` | — | DCE logs-ingestion URI |
| `Ingestion__DataCollectionRuleId` | — | DCR **immutable** id |
| `Ingestion__StreamMap` | — | Same allow-list as the frontend |
| `Ingestion__MaxChunkBytes` | `870400` | ≤ 1 MB hard limit |
| `Ingestion__MaxAttempts` | `5` | Per-chunk attempts |
| `Ingestion__BaseRetryDelayMs` / `__MaxRetryDelaySeconds` | `1000` / `60` | Backoff curve |
| `Ingestion__DeleteBlobAfterIngestion` | `false` | Lifecycle governs retention by default |

---

## Build and test

```powershell
dotnet build LogCollector.slnx
dotnet test  LogCollector.slnx

Invoke-Pester -Path tests/Pester

az bicep build --file infra/main.bicep --stdout
```

Coverage focuses on the security and reliability surface rather than plumbing:

- **xUnit** — canonical-string stability and golden vector; signature accept/tamper/wrong-key/
  wrong-nonce/malformed-header cases; skew and nonce reservation including cross-certificate scoping;
  certificate chain, EKU, expiry, thumbprint allow-list, forwarded-header trust; strict-GUID binding
  extraction across all claim types; Intune tier accept/reject; full authenticator pipeline including
  proof that a failed signature never reserves a nonce; chunk-size bounds and oversized-row handling;
  `Retry-After` parsing and full-jitter backoff; identity-spoofing resistance in the row factory;
  stream-map and envelope/pointer validation.
- **Pester** — canonical form cross-checked against the same golden vector; signing headers and
  freshness; strict GUID and issuer-pattern rules; dual-tier certificate selection including the
  documented fallback asymmetry; spool atomicity, ordering, quotas, quarantine and locking; retry and
  disposition classification; drain and submit orchestration.
- **PS 5.1 smoke test** — `tests/Pester/Invoke-Ps51SmokeTest.ps1` exercises import, canonical form,
  envelope, spool, locking and a real sign/verify round trip on Windows PowerShell 5.1, the runtime
  the fleet actually runs.

---

## Operational rules

- Never log raw inventory payloads, certificates, signatures, or tokens.
- Never commit private keys, PFX files, workspace keys, or `local.settings.json`. Public CA
  certificates under `infra\certificates` are intentional trust configuration, not secrets.
- Payload blobs are business data: they stay in Azure with a lifecycle policy, never in source control.
- The client refuses a non-HTTPS `FrontendUrl` outright rather than sending signed inventory in clear text.
- The collection script exits non-zero when the submission is not delivered, so the task's Last Run
  Result is meaningful to whatever monitors it.

## Rollout boundary

The environment is deployed in **LOGCOLLECTOR-RG**, **Italy North**, subscription
`00000000-0000-0000-0000-000000000000`: **LogCollector-intake (B1)**,
**LogCollector-worker (Flex Consumption)**, **LogCollector-servicebus**, **LogCollector-law**,
**LogCollector-dce**, **LogCollector-dcr**, **LogCollector-appi**, and **logcollectordata**.
Resource names have no random suffixes; Azure-generated service DNS names can have managed suffixes.
The storage name uses only lowercase letters because Azure requires it; `logcollectorstorage`
was unavailable globally.

The intake endpoint is **https://<your-intake>.azurewebsites.net/api/inventory**.
Azure RBAC and Graph **Device.Read.All** are assigned to the appropriate managed identities.
`infra\logcollector.bicepparam` contains the deployed settings and public Intune CA chain;
enterprise PKI anchors are still empty until the customer's public CA certificates are supplied.
These settings authorize the tenant hosting the identities, not any arbitrary customer's tenant.

Client onboarding is still a pilot prerequisite. No positive end-to-end ingestion with a real
enrollment certificate has been demonstrated. Confirm the certificate's `.5.25` GUID matches
the Entra device and exercise representative hardware/software payloads through to Log Analytics.
Measure B1 latency and memory under the two-hour upload window before fleet-wide rollout.

Rotate the legacy workspace shared key in a coordinated migration: first remove it from scripts
and deployment packages, migrate remaining senders, then revoke the old credential. No legacy
credential is included in this repository.
