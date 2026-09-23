# Intune deployment telemetry

`scripts\Intune-DeploymentTelemetry.ps1` is the source for Intune Platform
Script policy `91652293-8a62-4ed5-90ff-19baa07c249c`. It runs non-interactively
as `SYSTEM` in 64-bit Windows PowerShell 5.1 and collects Windows, MDM and Intune
Management Extension timing evidence.

Local evidence collection is the essential operation. Remote delivery is
optional and fail-open: missing or failed telemetry never blocks Autopilot,
ESP, or Intune provisioning.

## Configuration

| Setting | Requirement |
|---|---|
| `TelemetryMode = 'Disabled'` | Safe default. Collect locally and skip submission. |
| `TelemetryMode = 'Certificate'` | LogCollector Core 1.8.0 or later installed for the device. |
| `TelemetryEndpoint` | Leave empty to use the protected machine-wide LogCollector configuration. An override must be an absolute HTTPS `/api/submit` URI and cannot contain credentials, a query string, or a fragment. |
| `LogCollectorTableName` | Operator-approved custom table and DCR mapping. Default: `IntuneDeploymentTelemetry_CL`. |

Certificate mode reuses `LogCollector.Client`. The module selects the device
certificate from `LocalMachine`, signs the exact request body, sends through
the mTLS `/api/submit` endpoint, and retains temporary failures in the
SYSTEM/Administrators-only shared spool. No Function key, workspace key,
client secret, access token, or Authorization header is stored in the script.

An Entra-joined or Intune-enrolled Windows device does not receive an Azure
Managed Identity. Managed Identity is therefore intentionally not offered as a
device-side mode.

The script logs the selected mode, endpoint path, delivery category, HTTP
status, disposition, and spool location. A configured certificate thumbprint
is partially masked. Endpoint query strings are rejected and never logged.
Raw formatted DM-EDP event messages are not collected because policy event
text can contain configuration values; only event identifiers, timestamps,
levels, record IDs, and activity IDs are included. User UPN and interactive
user identity are not included. The device-stable collector correlation value
uses `DeviceCorrelationId` because `CorrelationId` is reserved and asserted by
the LogCollector ingestion service.

The protected LogCollector `SubmissionEnabled = $false` setting is a network
delivery kill switch. The script honors it and skips submission.

## Provisioning budgets

- IME evidence scanning is limited to 32 MB and 15 seconds by default.
- Remote submission uses one attempt with a 15-second HTTP request timeout.
  No retry delay applies.
- Reaching a scan limit marks the evidence as truncated and produces
  `InsufficientEvidence` rather than a potentially misleading classification.

## Exit codes

| Exit code | Meaning |
|---|---|
| `0` | Essential local collection completed. Telemetry may be sent, disabled, unavailable, or retained in the LogCollector spool. |
| `1` | The script is not elevated, or an essential collection setting is invalid. |

## Intune settings

- **Run this script using the logged on credentials:** No
- **Enforce script signature check:** preserve the existing policy setting
- **Run script in 64-bit PowerShell Host:** Yes
- **Assignment:** preserve the existing All Devices assignment

During OOBE/ESP, LogCollector Core may not yet be installed. This is a normal
`ConfigurationMissing` telemetry state: the script logs a warning and exits
successfully after local collection.

## Migration from the POC

1. Remove `DirectTenantId`, `DirectClientId`, `DirectClientSecret`, and the
   direct OAuth client-credentials flow from every copy of the script.
2. Revoke the POC App Registration credential if one was ever issued.
3. Deploy LogCollector Core and configure its protected endpoint/certificate
   trust settings.
4. Create and allow-list `IntuneDeploymentTelemetry_CL` and its DCR stream
   before changing `TelemetryMode` from `Disabled` to `Certificate`.
5. Upload this repository copy to the existing Platform Script policy.

The default remains `Disabled` until the table/DCR mapping exists, preventing
the policy fix from introducing a new provisioning dependency.
