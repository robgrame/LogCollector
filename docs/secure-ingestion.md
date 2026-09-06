# Secure ingestion design notes

Protocol-level reference for the wire formats and the ingestion path. For the threat model see
[security.md](security.md); for runbooks see [operations.md](operations.md).

## Submission protocol

### Endpoint

```text
POST https://<frontend>.azurewebsites.net/api/submit
```

`AuthorizationLevel.Anonymous` at the trigger, mandatory client certificates at the platform,
certificate/signature/replay/device controls in the function and tenant authorization for Intune
fallback. No Function key, no API key, no shared secret.

`/api/inventory` remains a compatibility alias. Both routes use the same handler and controls,
and both accept current and legacy envelopes. Sign the actual path used in the request:
a signature for `/api/inventory` is not valid for `/api/submit`. Nonce reservation is shared
across routes, not scoped to the alias.

### Headers

| Header | Required | Notes |
|---|---|---|
| `Content-Type: application/json` | yes | |
| `X-Request-Timestamp` | yes | ISO-8601, `DateTimeOffset` round-trip ("O") format |
| `X-Request-Nonce` | yes | GUID, "D" format; the empty GUID is rejected |
| `X-Request-Signature-Version` | yes | `IDA-SIGNATURE-V1` |
| `X-Request-Signature-Algorithm` | yes | `RSA-PKCS1-SHA256` or `ECDSA-SHA256` |
| `X-Request-Signature` | yes | Base64 |
| `X-ARR-ClientCert` | platform | Injected by App Service; client-supplied copies are stripped |

### Canonical string

Six lines joined with `\n` (never `\r\n`):

```text
IDA-SIGNATURE-V1
<HTTP method, trimmed, uppercase invariant>
<path, trimmed, leading '/' ensured, '/' when empty>
<timestamp.ToUniversalTime().ToString("O")>
<nonce.ToString("D").ToLowerInvariant()>
<Base64(SHA-256(exact UTF-8 body bytes))>
```

Golden vector, asserted identically by xUnit and Pester:

```text
IDA-SIGNATURE-V1
POST
/api/inventory
2026-01-02T03:04:05.6780000+00:00
11111111-2222-3333-4444-555555555555
<Base64(SHA-256('{"a":1}'))>
```

Changing any line is a breaking protocol change and requires a new version token on both sides.

### Envelope — `LOGCOLLECTOR-TELEMETRY-V1`

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
  "properties": { "ScriptVersion": "1.0.3" },
  "records": [ { "Result": "Succeeded", "FreedBytes": 1048576 } ]
}
```

The legacy `LOGCOLLECTOR-INVENTORY-V1` version retains the same wire shape and is accepted by
both intake and worker, including previously queued blobs. There is no payload rewrite.
`source` is a diagnostic label, not an authorization claim or a code/plugin selector. Purposes
share the device authentication policy; the global table allow-list is not per-purpose RBAC.

Structural rules (`TelemetryEnvelope.Validate`):

| Field | Rule |
|---|---|
| `envelopeVersion` | Current or legacy token (ordinal match after trimming) |
| `tableName` | ASCII letter first, then letters/digits/underscore, ≤ 100 chars, **and** present in the stream map |
| `entraDeviceId` | Parseable GUID, and equal to the certificate-bound device id |
| `records` | 1 … `Intake:MaxRecordsPerEnvelope` (default 50 000), each a JSON object |
| `properties` | ≤ 32 string-valued entries |
| `collectedAtUtc` | Required |

`deviceName` and `intuneDeviceId` are diagnostic only and are never used for authorization.
Records do not require inventory fields. `TelemetryRowFactory` preserves arbitrary fields and
adds the same protected platform columns for every purpose. Log Analytics/DCR schemas remain
operator-managed; accepting JSON objects does not provision destinations or guarantee schema acceptance.

## Pointer protocol — `LOGCOLLECTOR-POINTER-V1`

Inventory payloads routinely exceed the Service Bus Standard 256 KB limit, so the queue carries only
coordinates. Message size is therefore constant regardless of payload size.

```json
{
  "version": "LOGCOLLECTOR-POINTER-V1",
  "correlationId": "…",
  "tableName": "InventoryWindows_CL",
  "containerName": "inventory-payloads",
  "blobName": "InventoryWindows_CL/<sha256-correlationId>.json",
  "payloadSha256": "<base64>",
  "payloadBytes": 20480,
  "entraDeviceId": "…",
  "deviceName": "WKS-001",
  "source": "WindowsScheduledTask",
  "collectedAtUtc": "…",
  "acceptedAtUtc": "…",
  "certificateThumbprint": "…"
}
```

Two deliberate choices:

- **Names, not a URI.** The worker resolves the blob against its own configured account. There is no
  code path where the message chooses the host, so SSRF is designed out rather than filtered.
- **A digest and byte length.** Both are mandatory. The worker verifies them before ingestion.

The server derives `CorrelationId` from SHA-256 of the authenticated body. It supplies `MessageId`,
and the queue suppresses repeated sends within a one-hour window. Delivery remains at least once:
worker redelivery and retries outside that window can duplicate rows. Deduplicate by
`EntraDeviceId`, `CorrelationId` and server-assigned `RecordIndex` in analytical queries.

## Write ordering

The frontend writes the blob **before** enqueuing the pointer. A crash between the two leaves an
orphan blob that the lifecycle rule reclaims. The reverse order would produce a pointer to a blob
that never existed, and a message that dead-letters only after exhausting every delivery attempt.

## Logs Ingestion

### Chunking

- Hard API limit: **1 MB** uncompressed request body.
- Working budget: **850 KB** (`Ingestion:MaxChunkBytes`, default 870 400 bytes).

The margin absorbs request framing and server-side normalisation, and stops a batch sitting exactly
on the boundary from oscillating between accepted and rejected.

`LogsIngestionChunker` accounts for array framing precisely — two brackets plus one comma per
additional element — and measures each row's exact UTF-8 length. Row order is preserved across
chunks.

A row over the configured budget **dead-letters the message before any upload**, preserving the
payload for remediation. It is not silently dropped or acknowledged as complete. An operator can
split/adjust the data or increase the budget within the API limit before resubmission.

### Retry

`RetryAfterPolicy` parses both `Retry-After` forms (delta-seconds and HTTP-date), clamps to five
minutes, and otherwise applies exponential backoff with **full jitter**:

```text
delay = uniform(0, min(base · 2^(attempt-1), ceiling))
```

Retryable: 408, 429, 500, 502, 503, 504. Everything else is permanent.

The Azure SDK's own retry policy is disabled (`Retry.MaxRetries = 0`) so `Retry-After` is honoured
exactly once and the backoff visible in telemetry is the backoff actually applied. A hidden retry
layer would burn the attempt budget before the server-supplied delay was ever respected.

### Row projection

`TelemetryRowFactory` emits, per record: the client's fields, then the envelope properties (record
fields win on conflict), then the server-asserted columns last. Names in `ReservedColumns` are
stripped from client input, so a device cannot spoof its own attribution.

### Schema

Column names must be unique **across record types**. `InventoryWindows_CL` uses `OsInstallDate`
(datetime) and `SoftwareInstallDate` (string) rather than one `InstallDate`: reusing a name with two
types makes the column unqueryable.

The DCR declares the same column set as the table and uses `transformKql: 'source'` — projection has
already happened in the worker, so a transform would only add a second place to keep in sync.

## Message disposition

`autoCompleteMessages` is `false`; the worker decides each message's fate:

| Outcome | Action | Why |
|---|---|---|
| Ingested | `CompleteMessageAsync` | |
| Malformed pointer | `DeadLetterMessageAsync("MalformedPointer")` | Never parseable; retrying wastes ten deliveries |
| Unmapped table, digest mismatch, missing blob, invalid envelope, device/table mismatch, oversized row, permanent ingestion rejection | `DeadLetterMessageAsync("UnprocessablePayload")` | Deterministically unprocessable |
| Transient (throttling, storage error, ingestion 5xx) | rethrow → abandon | Normal redelivery, then dead-letter at `maxDeliveryCount` |

A missing blob is treated as **permanent**: it means the payload was already reclaimed by retention
or already processed and deleted. Retrying cannot make it reappear.

## Retention and deletion

- `Ingestion:DeleteBlobAfterIngestion` defaults to **false**. Retention is governed by the storage
  lifecycle rule (`payloadRetentionDays`, default 14), preserving a replay window for incident
  investigation.
- When enabled, deletion is conditional on the ETag captured at download. A concurrent overwrite is
  preserved rather than silently destroyed.
- A failed deletion is logged and ignored. Failing the message there would re-ingest rows that were
  already committed.
- The lifecycle rule is the backstop either way, so an ingestion outage cannot grow the account
  without bound.

## Client spool format — `LOGCOLLECTOR-SPOOL-V1`

```json
{
  "spoolVersion": "LOGCOLLECTOR-SPOOL-V1",
  "createdUtc": "2026-04-01T06:00:00.0000000+00:00",
  "tableName": "InventoryWindows_CL",
  "attempts": 0,
  "body": "<the exact envelope JSON>"
}
```

File name: `yyyyMMddTHHmmssfff-<guid>.json`. The sortable UTC prefix means drain order does not depend
on file-system metadata, which copy and restore operations happily rewrite.

Signatures are **not** stored. They are timestamp- and nonce-bound, so a stored signature would be
guaranteed to fail on drain; every attempt re-signs with a fresh timestamp and nonce.

Quotas enforced on every save and drain: 7 days, 500 entries, 64 MB. Quarantined entries age out
under the same age quota, so quarantine cannot grow without bound either.
