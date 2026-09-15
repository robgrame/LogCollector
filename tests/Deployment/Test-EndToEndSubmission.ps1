#Requires -Version 5.1
<#
.SYNOPSIS
Positive end-to-end probe: uses the real Core client to submit one operational event
through a deployed Frontend Function and, optionally, confirms it lands in Log Analytics.
.DESCRIPTION
Test-IntakeEndpoint.ps1 only exercises negative paths (missing/untrusted certificate) and
never establishes positive end-to-end ingestion. This script is the positive complement: it
imports the actual LogCollector.Client module from source (no installation required), sends
one real record to the shared LogCollectorOperations_CL table with this machine's own
certificate identity, and reports whether the intake accepted it.

Nothing here bypasses production logic: it calls Send-LogCollectorData with the exact record
shape Send-LogCollectorOperationalEvent builds internally, so a passing run proves device
identity, certificate selection, request signing, transport and server-side
authorization/authentication all work together, not just that the endpoint is reachable.

Add -WorkspaceId to also poll Log Analytics for the emitted row (via 'az monitor
log-analytics query'), which additionally proves the Worker's DCR-based ingestion path and
that the destination table/stream mapping is correct end-to-end. Log Analytics ingestion
lags by minutes, not seconds, so this polls with a bounded timeout rather than failing fast.
.PARAMETER FrontendUrl
Intake endpoint, e.g. https://<frontend>.azurewebsites.net/api/submit. Defaults to the
machine-wide configuration written by the core package when omitted.
.PARAMETER WorkspaceId
Log Analytics workspace ID (the GUID 'Workspace ID' from workspace overview, not the
resource ID) used to verify ingestion with 'az monitor log-analytics query'. Requires an
active 'az login' with at least Log Analytics Reader on the workspace. Skipped when omitted.
.PARAMETER CertificateThumbprint
.PARAMETER CertificateSubjectLike
.PARAMETER CertificateIssuerLike
.PARAMETER PkiRootCaThumbprints
.PARAMETER PkiRootCaSubjects
.PARAMETER PkiIntermediateCaThumbprints
.PARAMETER PkiIntermediateCaSubjects
Certificate-selection overrides, passed through unchanged to Send-LogCollectorData.
Leave unset to use the machine-wide configuration's own selection settings.
.PARAMETER VerificationTimeoutMinutes
Total time to keep polling Log Analytics for the emitted row before declaring the
verification step failed. Ignored when -WorkspaceId is not supplied.
.PARAMETER VerificationPollSeconds
Delay between successive Log Analytics queries while polling.
.EXAMPLE
.\tests\Deployment\Test-EndToEndSubmission.ps1 -FrontendUrl 'https://contoso-logcollector-frontend.azurewebsites.net/api/submit'
.EXAMPLE
.\tests\Deployment\Test-EndToEndSubmission.ps1 -WorkspaceId '11111111-2222-3333-4444-555555555555'
.NOTES
Version 1.0.0. Sends one real, small record (PackageName 'LogCollector-E2E-Test') to
LogCollectorOperations_CL. It does not create tasks, spool state or any local footprint.
#>
[CmdletBinding()]
param(
    [Uri] $FrontendUrl,
    [string] $WorkspaceId,
    [string] $CertificateThumbprint,
    [string] $CertificateSubjectLike,
    [string] $CertificateIssuerLike,
    [string[]] $PkiRootCaThumbprints = @(),
    [string[]] $PkiRootCaSubjects = @(),
    [string[]] $PkiIntermediateCaThumbprints = @(),
    [string[]] $PkiIntermediateCaSubjects = @(),
    [ValidateRange(1, 60)] [int] $VerificationTimeoutMinutes = 10,
    [ValidateRange(5, 300)] [int] $VerificationPollSeconds = 30
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'src\Client\LogCollector.Client.psd1') -Force -DisableNameChecking

$probeId = [guid]::NewGuid()
$startedUtc = [DateTimeOffset]::UtcNow
$message = "LogCollector end-to-end probe {0} at {1}." -f $probeId, $startedUtc.ToString('o')

Write-Output "Submitting probe $probeId ..."
$identity = Get-DeviceIdentitySnapshot
Write-Verbose "Device identity: EntraDeviceId=$($identity.EntraDeviceId) DeviceName=$($identity.DeviceName)"

$diagnostics = New-Object 'Collections.Generic.List[object]'
$diagnosticSink = { param($event, $data) $diagnostics.Add([pscustomobject]@{ Event = $event; Data = $data }) }

# Same record shape Send-LogCollectorOperationalEvent builds for LogCollectorOperations_CL.
# Calling Send-LogCollectorData directly (rather than that wrapper) is what lets this probe
# also accept the certificate-selection overrides below, which the wrapper does not expose.
$record = [pscustomobject]@{
    PackageName    = 'LogCollector-E2E-Test'
    PackageVersion = '1.0.0'
    ScriptName     = 'Test-EndToEndSubmission.ps1'
    EventName      = 'EndToEndProbe'
    Level          = 'Info'
    Message        = $message
    ExecutionId    = $probeId.ToString('D')
}

$arguments = @{
    TableName      = 'LogCollectorOperations_CL'
    Records        = @($record)
    Source         = 'Test-EndToEndSubmission.ps1'
    DiagnosticSink = $diagnosticSink
}

# Read the machine-wide configuration once, both for the FrontendUrl fallback and to reuse
# its certificate-selection settings as defaults, mirroring what Send-LogAnalyticsData does
# for callers that do not name a certificate explicitly.
$configuration = $null
if (-not $FrontendUrl) {
    $configuration = Get-LogCollectorEndpointConfiguration
    $arguments.FrontendUrl = $configuration.FrontendUrl
}
else {
    $arguments.FrontendUrl = $FrontendUrl
    if (Test-Path -LiteralPath (Get-LogCollectorConfigurationPath)) { $configuration = Get-LogCollectorEndpointConfiguration }
}
foreach ($setting in @('CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
        'PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
    if ($PSBoundParameters.ContainsKey($setting) -and @($PSBoundParameters[$setting]).Count -gt 0) {
        $arguments[$setting] = $PSBoundParameters[$setting]
    }
    elseif ($configuration -and $configuration.PSObject.Properties[$setting] -and $configuration.$setting) {
        $arguments[$setting] = $configuration.$setting
    }
}

$response = Send-LogCollectorData @arguments

foreach ($event in $diagnostics) { Write-Verbose "Transport: $($event.Event) $($event.Data | ConvertTo-Json -Compress -Depth 5)" }

if (-not $response -or $response.Disposition -ne 'Delivered') {
    $reason = if ($response) { "Disposition=$($response.Disposition), StatusCode=$($response.StatusCode), Message=$($response.Message)" } else { 'no response object was returned' }
    throw "Submission was not delivered: $reason"
}
Write-Output "Submission accepted by the intake (StatusCode=$($response.StatusCode), Attempts=$($response.Attempts))."

if (-not $WorkspaceId) {
    Write-Output 'No -WorkspaceId supplied; skipping Log Analytics ingestion verification.'
    return
}

Write-Output "Polling LogCollectorOperations_CL in workspace $WorkspaceId for up to $VerificationTimeoutMinutes minute(s) ..."
$deadline = [DateTime]::UtcNow.AddMinutes($VerificationTimeoutMinutes)
$query = "LogCollectorOperations_CL | where ExecutionId == '$probeId' | take 1"
$found = $false
do {
    $raw = az monitor log-analytics query --workspace $WorkspaceId --analytics-query $query -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $rows = $raw | ConvertFrom-Json
        if ($rows -and $rows.Count -gt 0) { $found = $true; break }
    }
    Write-Verbose "Not visible yet; retrying in $VerificationPollSeconds second(s) ..."
    Start-Sleep -Seconds $VerificationPollSeconds
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $found) {
    throw ("Probe $probeId was accepted by the intake but did not appear in " +
        "LogCollectorOperations_CL within $VerificationTimeoutMinutes minute(s). " +
        'Check the Worker function logs and the DCR/stream mapping.')
}
Write-Output "Confirmed: probe $probeId is queryable in Log Analytics. End-to-end ingestion verified."
