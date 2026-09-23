# Application logging remediation

This Intune Remediations package verifies that a device can submit application events
through LogCollector Core to `LogCollectorOperations_CL`.

By default it sends 200 synthetic events in eight batches of 25, with a 100 ms pause between
batches. This exercises repeated authenticated requests without opening one HTTP connection
per event. The remediation parameters allow bounded manual tests of 1-1000 events and batches
of 1-100 records.

The records contain only the remediation name, version, sequence, severity and a generated
execution ID. Device identity is added by the LogCollector service. No username, email
address, application data, credential or arbitrary Windows event message is collected.

For a controlled manual load test, the remediation also accepts `-EventCount`, `-BatchSize`,
`-DelayMilliseconds`, `-FrontendUrl`, `-ModuleRoot`, `-SpoolRoot` and `-StatePath`. Intune
uses the secure defaults and does not pass these arguments.

## Prerequisite

Deploy **MSLabs - LogCollector Core** 1.8.2 or later first. Its protected configuration must
have `SubmissionEnabled = $true` and the Frontend endpoint must end in `/api/submit`.

## Intune configuration

Create an Intune **Remediations** script package:

| Setting | Value |
| --- | --- |
| Name | `MSLabs - Test LogCollector Application Logging` |
| Detection script | `Detect.ps1` |
| Remediation script | `Remediate.ps1` |
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No, unless the final scripts are signed |
| Run script in 64-bit PowerShell | Yes |
| Suggested schedule | Daily |

The detection is compliant for 24 hours after the last accepted probe. When stale or absent,
the remediation sends the complete bounded batch set and updates:

```text
%ProgramData%\LogCollector\State\ApplicationLoggingRemediation.json
```

An HTTP acceptance is not treated as complete Log Analytics verification. Confirm the row:

```kusto
LogCollectorOperations_CL
| where TimeGenerated > ago(2d)
| where PackageName == "LogCollector-ApplicationLogging-Remediation"
| summarize Events=count(), FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated),
    Levels=make_set(Level) by DeviceName, EntraDeviceId, ExecutionId
| order by LastSeen desc
```

A successful default run must show `Events == 200` for its `ExecutionId`. A lower count means
the intake accepted all batches but downstream ingestion is incomplete or delayed.

If remediation fails, inspect its Intune output and the local Core configuration:

```powershell
Import-Module LogCollector.Client -MinimumVersion 1.8.2
Get-LogCollectorEndpointConfiguration
```
