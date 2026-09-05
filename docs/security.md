# Security model

This document explains *why* each control exists, what it stops, and what it deliberately does not
stop. It is the reference for reviewing changes to the trust path.

## Trust boundaries

```text
 [ Windows device ]        untrusted until proven      [ Frontend ]
   private key in            ── mTLS + signature ──▶     validates everything
   LocalMachine\My                                       itself

 [ Frontend ]              trusted service identity    [ Blob + Service Bus ]
   UAMI, send-only                                       payload + pointer

 [ Service Bus message ]   UNTRUSTED input             [ Worker ]
   forgeable in principle    ── validate + resolve ──▶   never follows a URI
                                 against own account     from the message
```

The critical assumption: **the frontend treats the request body as attacker-controlled until step 5
completes**, and **the worker treats the queue message as attacker-controlled forever**.

## The ordered pipeline

Implemented by `InventoryRequestAuthenticator.AuthenticateAsync`, then the device-binding check in
`InventoryIngestFunction`. Order is a security property, not a style choice.

### 1. Timestamp freshness — `ReplayProtector.ValidateFreshness`

Rejects `X-Request-Timestamp` outside ±`Replay:MaxTimestampSkewSeconds` (default 300 s) in **either**
direction. A future-dated timestamp is as dangerous as a stale one: it would let an attacker
pre-compute a request that stays valid indefinitely.

First because it is a string comparison against the clock — the cheapest way to shed junk before any
cryptography or storage call.

### 2. Client certificate — `ClientCertValidator.Validate`

Checks, in order: validity window, Client Authentication EKU, optional leaf thumbprint allow-list,
then chain building against the configured trust anchors.

Two independent tiers:

| Tier | Anchors | Device id source |
|---|---|---|
| Enterprise PKI | `ClientCert:TrustedRootCertificates` (+ intermediates as path hints) | SAN URI / SAN DNS / Subject CN, or the operator thumbprint map |
| Intune enrollment | `ClientCert:TrustedIntuneRootCertificates` | OID `1.2.840.113556.5.25` |

Only roots become trust anchors. Intermediates go into `ExtraStore` as path hints, so a compromised
issuing CA certificate handed to the app cannot silently become a root of trust.

The Intune tier is reached only when **all** of the following hold: the enterprise tier rejected the
chain; the fallback is enabled; Intune anchors are configured; the certificate actually carries the
enrollment OID; and the issuer DN is on `ClientCert:IntuneEnrollmentIssuerSubjects`. The last
condition matters — without it, any CA that copies the OID could mint device identities.

**Fail-closed cases** (all return "denied", never "allowed"):

- No trust anchor configured at all.
- `RequireDeviceBinding` on while `DeviceIdBindingClaim` is `Disabled` — a contradictory
  configuration that would otherwise silently disable IDOR protection.
- Conflicting duplicate entries in `ThumbprintToDeviceMap`: the later mapping is refused rather than
  overwriting, because a silent rebind points a certificate at the wrong device.

#### The forwarded header

App Service terminates TLS and re-presents the leaf certificate in `X-ARR-ClientCert`. Trusting that
header is safe **only** because `clientCertEnabled: true` makes the platform strip any
client-supplied instance of it. `ClientCert:TrustForwardedHeader` therefore defaults to `true` — and
must be set to `false` if the app is ever fronted by something that does not provide that guarantee.

### 3. Body signature — `RequestSignatureVerifier.Verify`

TLS proves possession of the private key **to the App Service edge**. It does not prove anything to
the function, which receives a certificate in a header and a body in a stream, with no cryptographic
link between them. The IDA-SIGNATURE-V1 signature re-establishes that link end to end and pins the
method, path, timestamp, nonce and exact body bytes at the same time.

Concretely: without step 3, anything able to inject a request between the edge and the function could
swap the body under a legitimate certificate. `InventoryRequestAuthenticatorTests` includes exactly
that scenario — sign with one key, present another certificate — and asserts a 401.

The body is read as raw bytes and verified **before** deserialisation. Deserialising and
re-serialising first would change the bytes and break the binding; it would also mean parsing
untrusted input before authentication.

Canonical string (LF-separated, byte-identical on both sides):

```text
IDA-SIGNATURE-V1
<METHOD uppercased>
</normalised/path>
<timestamp, DateTimeOffset "O", UTC>
<nonce, lowercase "D">
<base64(SHA-256(body))>
```

### 4. Nonce reservation — `ReplayProtector.ReserveAsync`

An insert-only `AddEntity` into Azure Table. A 409 means the pair was already claimed, i.e. a replay.
Insert-only is the point: it is atomic and therefore correct across scaled-out instances, where a
read-then-write check would race.

- Partition key derives from the **signed** timestamp, so every replay of the same request maps to
  the same entity — including across a UTC hour boundary.
- Row key is `SHA-256(thumbprint:nonce)`, so the raw certificate identity is never stored while
  uniqueness stays certificate-scoped. A nonce used by device A does not block device B.
- Retention is forced to at least twice the skew window. A nonce that expired while its timestamp was
  still considered fresh would reopen the replay window.

Reserved **after** steps 2 and 3 so unauthenticated traffic cannot inflate the table. This is
asserted by tests: a stale timestamp or an invalid signature must leave the store empty.

### 5. Certificate ↔ device binding

The envelope's `entraDeviceId` must equal the device id the certificate is bound to. Without this, any
device holding a valid certificate could submit inventory attributed to any other device — a
classic IDOR, and the one that most directly corrupts the data set.

Extraction is **strict**: the claim value must parse as a bare GUID in its entirety.

```text
SAN URI  "urn:uuid:<guid>"                → accepted
SAN DNS  "<guid>"                         → accepted
CN       "<guid>"                         → accepted
CN       "<guid>.attacker.example"        → REJECTED
CN       "device-<guid>-01"               → REJECTED
```

Substring extraction would let a permissive certificate template — one that lets a requester
influence any DN component or SAN entry — bind an attacker to a victim's device id.

In `Auto` mode the order is: operator thumbprint map (explicit intent wins), then the Intune OID
*when the certificate was accepted through the Intune tier*, then SAN URI, SAN DNS, Subject CN. The
OID must precede the CN because Intune puts a **different** GUID in the CN that is not the Entra
device id; reading the CN first would bind to the wrong identity.

### 6. Destination allow-list — `IngestionStreamMap`

`tableName` selects an ingestion destination, so it is validated twice: against a strict grammar
(ASCII letter first, then letters/digits/underscore, ≤ 100 chars) and against an operator-configured
table → `Custom-*` stream map. An unmapped name is rejected. The same map is enforced again in the
worker, so a forged pointer cannot reach an unintended stream either.

### 7. Tenant authorization for Intune enrollment certificates

Shared Microsoft Intune roots do not establish membership in the customer's tenant.
For the Intune trust tier, `GraphDeviceAuthorizer` looks up the certificate-bound device ID at
`https://graph.microsoft.com/v1.0/devices(deviceId='<guid>')` with the frontend managed identity.
Only an existing, enabled device with the exact same device ID is accepted. A foreign-tenant
certificate alone cannot satisfy this lookup. Missing devices and disabled devices return 403;
Graph outages or missing application consent fail intake and leave the client's spool intact.
There is no cache or bypass switch.

The intended customer tenant must be the tenant hosting the frontend identity. Grant that identity
Microsoft Graph `Device.Read.All` application permission when using Intune fallback. Keep shared
Intune roots in the **Intune** trust configuration, never the enterprise PKI root list.
Enterprise PKI roots must be customer-controlled with CA-enforced device identity templates.

The `.5.25` extension mapping is inherited from the reference implementation, not a universal
certificate-profile guarantee. During the pilot compare it with `dsregcmd` and the Entra device
record. If it does not match, onboarding fails closed; do not substitute a guessed CN.

## Data-layer integrity

`InventoryRowFactory` writes the server-asserted columns — `TimeGenerated`, `CollectedAtUtc`,
`EntraDeviceId`, `DeviceName`, `IntuneDeviceId`, `CorrelationId`, `Source` — **after** copying the
client's fields, and drops any client value using those names. A record containing its own
`EntraDeviceId` therefore cannot change the attribution of the row it produces.

## Worker-side controls

The Service Bus message is untrusted input. Even though only the frontend's identity can send to the
queue, the worker does not rely on that:

- The pointer carries **container and blob names**, never a URI. The blob is resolved against the
  worker's own configured account and the container name is compared to the configured one. There is
  no code path where message content selects a host to fetch from, which removes the SSRF class
  entirely rather than filtering for it.
- `blobName` is rejected if it contains `..` or starts with `/`.
- The SHA-256 recorded at intake is re-verified, so a tampered or truncated blob never reaches
  ingestion.
- The payload's `entraDeviceId` and `tableName` are compared against the pointer's, catching a blob
  swapped between intake and processing.

## Identity and network posture

- Two user-assigned managed identities. The frontend holds **Service Bus Data Sender** on the queue;
  the worker holds **Service Bus Data Receiver**. These roles separate queue operations, but the
  default shared host/deployment storage is a common trust boundary: both identities require
  host-storage access. This is not containment of a fully compromised Function app. Deploy separate
  host/deployment accounts with container-scoped payload permissions if that isolation is required.
- The worker's **Monitoring Metrics Publisher** is scoped to the DCR, not to the workspace, so it can
  only write the streams that DCR declares.
- Storage has `allowSharedKeyAccess: false` and `defaultToOAuthAuthentication: true`. A connection
  string that does not work is a credential that cannot leak.
- Service Bus has `disableLocalAuth: true`; SAS keys cannot authenticate data-plane requests.
- `httpsOnly`, TLS 1.2 minimum, FTPS disabled on both apps.
- `clientCertMode: Required` with **no** `clientCertExclusionPaths`, including health. Any
  exclusion enables TLS renegotiation and App Service's fixed 100 KB upload limit.
  Use an external certificate-bearing health probe; liveness does not validate certificate trust
  at the application layer and is not proof of authorization.

## Client-side posture

- The private key never leaves the device. Only a signature crosses the wire.
- Certificate selection requires a private key, a valid date range, and the Client Authentication EKU.
- No PFX-plus-plaintext-password code path exists. Certificates come from the Windows certificate
  store; a password-protected PFX on disk beside a script that reads it is a credential at rest with
  no meaningful protection.
- The client refuses a non-HTTPS endpoint outright.
- Spooled entries store the envelope body only — never signatures, which are timestamp- and
  nonce-bound and are regenerated at drain time.
- Spool paths must be protected from non-administrator writes and must not contain reparse
  points. Unsafe pre-existing spools are rejected, not silently trusted after an ACL change.

## What this design does *not* claim

- **It does not protect against a fully compromised device.** An attacker with SYSTEM can use the
  device's own certificate to submit false inventory *for that device*. Binding limits the blast
  radius to one device; it cannot make a compromised endpoint honest.
- **It does not encrypt payloads at the application layer.** Confidentiality relies on TLS in transit
  and Storage Service Encryption at rest. Add client-side encryption if inventory content is
  classified beyond that.
- **It does not authenticate the *user*.** The identity asserted is the device.
- **PKI revocation is only as fresh as CRL/OCSP.** The deployment enables `CheckRevocation`;
  a leaf revoked moments ago may still validate until caches expire. `AllowedLeafThumbprints`
  can restrict acceptance to an explicit list of known-good certificates.
- **Intune CRL/OCSP can be unavailable.** `SkipIntuneRevocationCheck` defaults to false and only
  affects the Intune trust tier. The deployed public intermediate has no revocation endpoints,
  so this exception is explicitly enabled there; it never disables enterprise PKI revocation.
  Chain signatures, expiry, EKU, issuer/roots, proof of possession and device binding remain
  enforced. Graph must still find an enabled device in the identity's tenant on every submission.
  Disable/delete that Entra device to block access. This is not certificate-level revocation
  or proof of current MDM management: a retired enrollment may leave an enabled Entra record.

## Reviewing a change to the trust path

Ask these questions before approving:

1. Does it change the canonical string? If so, it is a breaking protocol change and needs a new
   version token in **both** `RequestSigning.psm1` and `RequestSignatureVerifier.cs`.
2. Does it move the nonce reservation earlier than signature verification? That would let
   unauthenticated traffic fill the nonce table.
3. Does it relax GUID extraction to a substring or regex match? That reopens the IDOR path.
4. Does it add a path to `clientCertExclusionPaths`? That path is unauthenticated by definition.
5. Does it introduce a URI taken from a queue message? That reintroduces SSRF.
6. Does it default a fail-closed switch to `false`? Every `ClientCert__Require*`,
   `RequestSignature__Required`, and the trust-anchor presence check are load-bearing.
