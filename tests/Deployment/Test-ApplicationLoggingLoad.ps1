#Requires -Version 5.1
<#
.SYNOPSIS
Sends a bounded multi-batch application-log load through the deployed LogCollector intake.
.DESCRIPTION
Uses the production identity, certificate, envelope, signing and HTTP implementations but
does not use the durable spool. This makes it suitable for an interactive non-elevated
deployment test while the Intune remediation continues to use the protected SYSTEM spool.
.NOTES
Version 1.0.0. Sends synthetic records only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [Uri] $FrontendUrl,
    [string] $WorkspaceId,
    [ValidateRange(1, 1000)] [int] $EventCount = 200,
    [ValidateRange(1, 100)] [int] $BatchSize = 25,
    [ValidateRange(0, 5000)] [int] $DelayMilliseconds = 100,
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
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$clientRoot = Join-Path $root 'src\Client'
Import-Module (Join-Path $clientRoot 'DeviceIdentity.psm1') -Force -DisableNameChecking
$transport = Import-Module (Join-Path $clientRoot 'InventoryClient.psm1') -Force -DisableNameChecking -PassThru
& $transport { Initialize-TlsDefaults }

$identity = Get-DeviceIdentitySnapshot
$certificateArguments = @{ EntraDeviceId = $identity.EntraDeviceId }
foreach ($setting in @('CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
        'PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints',
        'PkiIntermediateCaSubjects')) {
    if ($PSBoundParameters.ContainsKey($setting) -and @($PSBoundParameters[$setting]).Count -gt 0) {
        $certificateArguments[$setting -replace '^Certificate', '' -replace '^Pki', 'Pki'] =
            $PSBoundParameters[$setting]
    }
}

$certificate = Get-ClientCertificate @certificateArguments
if (-not $certificate) {
    throw 'No usable device certificate matched the configured selection criteria.'
}
$runId = [guid]::NewGuid()
$records = @(
    for ($sequence = 1; $sequence -le $EventCount; $sequence++) {
        [pscustomobject]@{
            PackageName = 'LogCollector-ApplicationLogging-LoadTest'
            PackageVersion = '1.0.0'
            ScriptName = 'Test-ApplicationLoggingLoad.ps1'
            EventName = 'ApplicationLoggingLoadTest'
            Level = if (($sequence % 20) -eq 0) { 'Warning' } else { 'Info' }
            Message = 'Synthetic load-test event {0:D4} of {1:D4}; RunId={2}.' -f `
                $sequence, $EventCount, $runId
            ExecutionId = $runId.ToString('D')
        }
    }
)

$batchCount = [int] [math]::Ceiling($EventCount / [double] $BatchSize)
$accepted = 0
try {
    for ($offset = 0; $offset -lt $records.Count; $offset += $BatchSize) {
        $last = [math]::Min($offset + $BatchSize - 1, $records.Count - 1)
        $batch = @($records[$offset..$last])
        $envelope = New-InventoryEnvelope `
            -TableName 'LogCollectorOperations_CL' `
            -Records $batch `
            -EntraDeviceId $identity.EntraDeviceId `
            -DeviceName $identity.DeviceName `
            -IntuneDeviceId $identity.IntuneDeviceId `
            -Source 'Test-ApplicationLoggingLoad.ps1' `
            -EnvelopeVersion 'LOGCOLLECTOR-TELEMETRY-V1'
        $body = & $transport { param($Value) ConvertTo-InventorySubmissionBody -Envelope $Value } $envelope
        $response = Invoke-InventoryHttpPost -Uri $FrontendUrl -Body $body -Certificate $certificate -TimeoutSeconds 60
        if ($response.Disposition -ne 'Delivered') {
            $number = [int] ($offset / $BatchSize) + 1
            throw "Batch $number of $batchCount failed: HTTP $($response.StatusCode), $($response.Message)"
        }
        $accepted += $batch.Count
        Write-Output "Accepted batch $([int]($offset / $BatchSize) + 1)/$batchCount ($accepted/$EventCount events)."
        if ($DelayMilliseconds -gt 0 -and $accepted -lt $EventCount) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}
finally {
    if ($certificate) { $certificate.Dispose() }
}

if ($WorkspaceId) {
    $deadline = [DateTime]::UtcNow.AddMinutes($VerificationTimeoutMinutes)
    $query = "LogCollectorOperations_CL | where ExecutionId == '$runId' | summarize Events=count()"
    $visible = 0
    do {
        $raw = az monitor log-analytics query --workspace $WorkspaceId --analytics-query $query -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $rows = @($raw | ConvertFrom-Json)
            if ($rows.Count -gt 0 -and $rows[0].Events) { $visible = [int] $rows[0].Events }
            if ($visible -ge $EventCount) { break }
        }
        Write-Verbose "$visible of $EventCount events visible; retrying in $VerificationPollSeconds second(s)."
        Start-Sleep -Seconds $VerificationPollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($visible -lt $EventCount) {
        throw "$accepted events were accepted, but only $visible appeared in Log Analytics before timeout."
    }
}

[pscustomobject]@{
    ExecutionId = $runId.ToString('D')
    EventsAccepted = $accepted
    BatchCount = $batchCount
    EventsVerified = $(if ($WorkspaceId) { $visible } else { $null })
    TableName = 'LogCollectorOperations_CL'
    FrontendUrl = $FrontendUrl.AbsoluteUri
}
