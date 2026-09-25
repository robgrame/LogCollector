#Requires -Version 5.1
<#
.SYNOPSIS
Sends a synthetic application event through the installed LogCollector Core client.
.DESCRIPTION
Intended for Intune Remediations. The script imports LogCollector.Client only from the
machine-wide Program Files module tree, submits one non-sensitive operational event to
LogCollectorOperations_CL, and records local success only after the intake accepts it.
.NOTES
Version 1.1.0. Run as SYSTEM in 64-bit PowerShell.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()] [string] $ModuleRoot,
    [ValidateNotNullOrEmpty()] [string] $StatePath,
    [Uri] $FrontendUrl,
    [ValidateNotNullOrEmpty()] [string] $SpoolRoot,
    [ValidateRange(1, 1000)] [int] $EventCount = 200,
    [ValidateRange(1, 100)] [int] $BatchSize = 25,
    [ValidateRange(0, 5000)] [int] $DelayMilliseconds = 100
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$minimumModuleVersion = [version] '1.10.0'
$scriptVersion = '1.1.0'

if (-not [Environment]::Is64BitProcess) {
    throw 'Application logging remediation requires 64-bit PowerShell.'
}
if (-not $PSBoundParameters.ContainsKey('ModuleRoot')) {
    $ModuleRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) `
        'WindowsPowerShell\Modules\LogCollector.Client'
}
if (-not (Test-Path -LiteralPath $ModuleRoot -PathType Container)) {
    throw "LogCollector Core is not installed: module root not found at '$ModuleRoot'."
}

$candidates = @(
    foreach ($directory in Get-ChildItem -LiteralPath $ModuleRoot -Directory -ErrorAction Stop) {
        $version = $null
        if (-not [version]::TryParse($directory.Name, [ref] $version)) { continue }
        $manifest = Join-Path $directory.FullName 'LogCollector.Client.psd1'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            [pscustomobject]@{
                Version = $version
                Manifest = $manifest
            }
        }
    }
)
$selected = $candidates | Where-Object Version -GE $minimumModuleVersion |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $selected) {
    throw "LogCollector.Client $minimumModuleVersion or later is not installed under '$ModuleRoot'."
}

$manifest = Test-ModuleManifest -Path $selected.Manifest -ErrorAction Stop
if ($manifest.Version -ne $selected.Version) {
    throw ("Module folder version '$($selected.Version)' does not match manifest version " +
        "'$($manifest.Version)'.")
}
Import-Module -Name $selected.Manifest -Force -ErrorAction Stop

$configuration = $null
if (-not $FrontendUrl) {
    $configuration = Get-LogCollectorEndpointConfiguration
    $FrontendUrl = [Uri] $configuration.FrontendUrl
}
elseif (Test-Path -LiteralPath (Get-LogCollectorConfigurationPath) -PathType Leaf) {
    $configuration = Get-LogCollectorEndpointConfiguration
}
if (-not $PSBoundParameters.ContainsKey('StatePath')) {
    $StatePath = Join-Path (Get-LogCollectorDataRoot) 'State\ApplicationLoggingRemediation.json'
}
if (-not $PSBoundParameters.ContainsKey('SpoolRoot')) {
    $SpoolRoot = Join-Path (Get-LogCollectorDataRoot) 'SharedSpool'
}
if ($configuration -and -not $configuration.SubmissionEnabled) {
    throw 'LogCollector Core submission is disabled; enable the protected endpoint configuration before running this remediation.'
}
if ($FrontendUrl.Scheme -ne 'https' -or $FrontendUrl.AbsolutePath -cne '/api/submit' -or
    $FrontendUrl.UserInfo -or $FrontendUrl.Query -or $FrontendUrl.Fragment) {
    throw 'Application logging remediation requires an HTTPS LogCollector endpoint with exact path /api/submit and no user info, query or fragment.'
}

$executionId = [guid]::NewGuid()
$records = @(
    for ($sequence = 1; $sequence -le $EventCount; $sequence++) {
        [pscustomobject]@{
            PackageName = 'LogCollector-ApplicationLogging-Remediation'
            PackageVersion = $scriptVersion
            ScriptName = 'Remediate.ps1'
            EventName = 'ApplicationLoggingResilienceProbe'
            Level = if (($sequence % 20) -eq 0) { 'Warning' } else { 'Info' }
            Message = 'Synthetic resilience event {0:D4} of {1:D4}; RunId={2}.' -f `
                $sequence, $EventCount, $executionId
            ExecutionId = $executionId.ToString('D')
        }
    }
)

$accepted = 0
$batchCount = [int] [math]::Ceiling($EventCount / [double] $BatchSize)
for ($offset = 0; $offset -lt $records.Count; $offset += $BatchSize) {
    $last = [math]::Min($offset + $BatchSize - 1, $records.Count - 1)
    $batch = @($records[$offset..$last])
    $arguments = @{
        FrontendUrl = $FrontendUrl
        TableName = 'LogCollectorOperations_CL'
        Records = $batch
        Source = 'Remediate.ps1'
        SpoolRoot = $SpoolRoot
        SkipDrain = $true
    }
    foreach ($setting in @('CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
            'PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints',
            'PkiIntermediateCaSubjects')) {
        if ($configuration -and $configuration.PSObject.Properties[$setting] -and $configuration.$setting) {
            $arguments[$setting] = $configuration.$setting
        }
    }
    $result = Send-LogCollectorData @arguments

    if (-not $result -or $result.Disposition -ne 'Delivered') {
        $detail = if ($result) {
            "Disposition=$($result.Disposition); StatusCode=$($result.StatusCode); Message=$($result.Message)"
        }
        else {
            'No response object was returned.'
        }
        $batchNumber = [int] ($offset / $BatchSize) + 1
        throw ("Application logging batch $batchNumber of $batchCount was not accepted after " +
            "$accepted of $EventCount events. $detail")
    }
    $accepted += $batch.Count
    if ($DelayMilliseconds -gt 0 -and $accepted -lt $EventCount) {
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
}

$stateDirectory = Split-Path $StatePath -Parent
$stateTrust = Import-Module (Join-Path (Split-Path $selected.Manifest -Parent) 'InventorySpool.psm1') `
    -PassThru -Force -ErrorAction Stop
& $stateTrust {
    param($Directory)
    $null = Assert-SpoolHierarchy -Path $Directory -Directory -Create
} $stateDirectory
$state = [ordered]@{
    SchemaVersion = 1
    Delivered = $true
    LastSuccessUtc = [DateTimeOffset]::UtcNow.ToString('o')
    ExecutionId = $executionId.ToString('D')
    ModuleVersion = $manifest.Version.ToString()
    EventCount = $EventCount
    BatchCount = $batchCount
    BatchSize = $BatchSize
    IntakeStatusCode = $result.StatusCode
}
$temporaryPath = "$StatePath.$([guid]::NewGuid().ToString('N')).tmp"
try {
    & $stateTrust {
        param($Path, $Content)
        Write-SpoolFile -Path $Path -Content $Content
    } $temporaryPath ($state | ConvertTo-Json -Compress)
    Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force -ErrorAction Stop
    & $stateTrust {
        param($Path)
        $null = Assert-SpoolHierarchy -Path $Path
    } $StatePath
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Output (("Application logging resilience probe accepted; ExecutionId={0}; Events={1}; Batches={2}; " +
        "ModuleVersion={3}; StatusCode={4}.") -f
    $executionId, $accepted, $batchCount, $manifest.Version, $result.StatusCode)
