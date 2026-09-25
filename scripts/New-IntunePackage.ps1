#Requires -Version 5.1
<#
.SYNOPSIS
Builds the shared LogCollector Core .intunewin package for deployment as an Intune Win32 app.
.DESCRIPTION
Runs directly from the LogCollector repository or from a generated customer deliverable.
The Core package installs LogCollector.Client and its protected endpoint configuration; it
does not collect inventory, create scheduled tasks or package any application script.
.PARAMETER IntuneWinAppUtilPath
Path to Microsoft's IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Optional: if
omitted, the script looks recursively under 'Tools' next to this script and, when running
from the repository, under 'tools\IntuneWinAppUtil', then on PATH.
The executable must carry a valid Authenticode signature issued to Microsoft Corporation.
Download: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
.PARAMETER FrontendUrl
Intake endpoint, e.g. https://<prefix>-logcollector-intake.azurewebsites.net/api/submit.
Printed by Deploy-LogCollector.ps1 as 'frontendIngestUrl'.
.PARAMETER Environment
Free-text environment tag recorded with every record (e.g. Production, Pilot).
.PARAMETER CustomerName
Customer folder used by Write-CMTraceLog, so every script on the device logs to
%ProgramData%\<CustomerName>\<ApplicationName>\Logs. Defaults to 'LogCollector'.
.EXAMPLE
.\scripts\New-IntunePackage.ps1 `
  -FrontendUrl https://example-logcollector-intake.azurewebsites.net/api/submit
Uses .\tools\IntuneWinAppUtil\IntuneWinAppUtil.exe and builds the Core package.
.EXAMPLE
.\New-IntunePackage.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe `
  -FrontendUrl https://example-logcollector-intake.azurewebsites.net/api/submit `
  -CustomerName ACIInformatica -Environment Production
.NOTES
Version 1.0.0. The generated package collects nothing and registers no scheduled task.
Existing output folders are never overwritten.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $IntuneWinAppUtilPath,
    [Parameter(Mandatory)] [Uri] $FrontendUrl,
    [string] $Environment = '',
    [ValidatePattern('^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])$')] [string] $CustomerName = 'LogCollector',
    [string[]] $PkiRootCaThumbprints = @(),
    [string[]] $PkiRootCaSubjects = @(),
    [string[]] $PkiIntermediateCaThumbprints = @(),
    [string[]] $PkiIntermediateCaSubjects = @(),
    [ValidateNotNullOrEmpty()] [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($FrontendUrl.Scheme -ne 'https') {
    throw "FrontendUrl must use https; '$($FrontendUrl.Scheme)' would send signed inventory in clear text."
}
if (($CustomerName -split '\.')[0].ToUpperInvariant() -in @('CON', 'PRN', 'AUX', 'NUL', 'CLOCK$',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')) {
    throw "CustomerName '$CustomerName' is a reserved Windows device name and cannot be a log folder."
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$deliveredCoreSource = Join-Path $PSScriptRoot 'CoreSource'
$repositoryCoreSource = Join-Path $repoRoot 'src\CorePackage'
if (Test-Path -LiteralPath $deliveredCoreSource -PathType Container) {
    $coreSource = $deliveredCoreSource
    $moduleSource = Join-Path $deliveredCoreSource 'Modules'
    $defaultOutputRoot = Join-Path $PSScriptRoot 'Output'
    $toolSearchRoots = @((Join-Path $PSScriptRoot 'Tools'))
}
elseif ((Test-Path -LiteralPath $repositoryCoreSource -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $repoRoot 'src\Client') -PathType Container)) {
    $coreSource = $repositoryCoreSource
    $moduleSource = Join-Path $repoRoot 'src\Client'
    $defaultOutputRoot = Join-Path $repoRoot 'out\Intune\Core'
    $toolSearchRoots = @(
        (Join-Path $PSScriptRoot 'Tools'),
        (Join-Path $repoRoot 'tools\IntuneWinAppUtil')
    )
}
else {
    throw ("Core package sources were not found. Run this script from the LogCollector repository " +
        "or copy the complete generated 2-Intune folder.")
}
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = $defaultOutputRoot }

$coreFiles = @('Config.psd1', 'Core.Provisioning.psm1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')
$moduleManifestPath = Join-Path $moduleSource 'LogCollector.Client.psd1'
if (-not (Test-Path -LiteralPath $moduleManifestPath -PathType Leaf)) {
    throw 'Missing core package source: Modules\LogCollector.Client.psd1'
}
$moduleManifestData = Import-PowerShellDataFile -LiteralPath $moduleManifestPath
$moduleManifest = Test-ModuleManifest -Path $moduleManifestPath -ErrorAction Stop
$moduleFiles = @($moduleManifestData.FileList)
foreach ($file in $coreFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $coreSource $file) -PathType Leaf)) {
        throw "Missing core package source: $file"
    }
}
foreach ($file in $moduleFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $moduleSource $file) -PathType Leaf)) {
        throw "Missing core package source: Modules\$file"
    }
}

$coreConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $coreSource 'Config.psd1')
$coreVersion = $coreConfig.PackageVersion
if ($coreVersion -ne $moduleManifest.Version.ToString()) {
    throw ("Core package version '$coreVersion' does not match the shared module version " +
        "'$($moduleManifest.Version)'. They ship together and must be bumped together.")
}
$coreConfig.FrontendUrl = $FrontendUrl.AbsoluteUri
$coreConfig.Environment = $Environment
$coreConfig.CustomerName = $CustomerName
$coreConfig.SubmissionEnabled = $true
$coreConfig.PkiRootCaThumbprints = $PkiRootCaThumbprints
$coreConfig.PkiRootCaSubjects = $PkiRootCaSubjects
$coreConfig.PkiIntermediateCaThumbprints = $PkiIntermediateCaThumbprints
$coreConfig.PkiIntermediateCaSubjects = $PkiIntermediateCaSubjects
foreach ($key in @('PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
    foreach ($entry in $coreConfig[$key]) {
        if ([string]::IsNullOrWhiteSpace($entry)) { throw "$key contains an empty entry." }
        if ($key -like '*Thumbprints' -and ($entry -replace '[\s:]', '') -notmatch '^[0-9a-fA-F]{40}$') {
            throw "$key entries must be SHA1 certificate thumbprints (40 hexadecimal digits)."
        }
    }
}

$release = [IO.Path]::GetFullPath((Join-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)) $coreVersion))
if ($release.Contains('"')) { throw 'Output paths must not contain double quotes.' }
if (Test-Path -LiteralPath $release) {
    throw "Output already exists: $release. Choose a new OutputRoot; releases are never overwritten."
}
if (-not $PSCmdlet.ShouldProcess($release, 'Build the LogCollector Core .intunewin package')) { return }

if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath') -and $IntuneWinAppUtilPath) {
    $tool = Get-Item -LiteralPath $IntuneWinAppUtilPath -ErrorAction Stop
}
else {
    $candidates = @(
        @(
            foreach ($toolsRoot in $toolSearchRoots) {
                if (Test-Path -LiteralPath $toolsRoot -PathType Container) {
                    Get-ChildItem -LiteralPath $toolsRoot -Filter 'IntuneWinAppUtil.exe' -Recurse -File -ErrorAction SilentlyContinue
                }
            }
        ) | Sort-Object -Property FullName -Unique
    )
    if ($candidates.Count -gt 1) {
        throw ("Found $($candidates.Count) copies of IntuneWinAppUtil.exe; keep only one or pass " +
            '-IntuneWinAppUtilPath explicitly. Candidates: ' +
            (($candidates | ForEach-Object { $_.FullName }) -join '; '))
    }
    $tool = if ($candidates.Count -eq 1) { $candidates[0] } else { $null }
    if (-not $tool) {
        $onPath = Get-Command 'IntuneWinAppUtil.exe' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($onPath) { $tool = Get-Item -LiteralPath $onPath.Source }
    }
    if (-not $tool) {
        throw ("IntuneWinAppUtil.exe was not found. Place it under '" +
            ($toolSearchRoots -join "' or '") + "', add it to PATH, or pass -IntuneWinAppUtilPath. " +
            'Download it from https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool')
    }
    Write-Verbose "Using content prep tool: $($tool.FullName)"
}
if ($tool.PSIsContainer -or $tool.Extension -ne '.exe') { throw 'Supply the official IntuneWinAppUtil.exe file.' }

$signature = Get-AuthenticodeSignature -LiteralPath $tool.FullName -ErrorAction Stop
if ($signature.Status -ne 'Valid') {
    throw ("'$($tool.FullName)' does not carry a valid Authenticode signature (status: " +
        "$($signature.Status)). Download the official tool from " +
        'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool')
}
$signer = $signature.SignerCertificate.Subject
if ($signer -notmatch '(?i)O=Microsoft Corporation') {
    throw "'$($tool.FullName)' is signed by '$signer', not by Microsoft Corporation; refusing to run it."
}
Write-Verbose "Content prep tool signature verified: $signer"

function ConvertTo-ConfigurationText {
    param([Parameter(Mandatory)] [hashtable] $Configuration)
    $lines = @('@{')
    foreach ($key in @($Configuration.Keys | Sort-Object)) {
        $value = $Configuration[$key]
        if ($value -is [bool]) { $literal = '$' + $value.ToString().ToLowerInvariant() }
        elseif ($value -is [int]) { $literal = $value.ToString([Globalization.CultureInfo]::InvariantCulture) }
        elseif ($value -is [string]) { $literal = "'" + $value.Replace("'", "''") + "'" }
        elseif ($value -is [array]) {
            $items = @($value | ForEach-Object {
                if ($_ -isnot [string]) { throw "Only strings are supported in configuration array $key." }
                "'" + $_.Replace("'", "''") + "'"
            })
            $literal = '@(' + ($items -join ', ') + ')'
        }
        else { throw "Unsupported configuration value type for $key." }
        $lines += "    $key = $literal"
    }
    $lines += '}'
    return ($lines -join "`r`n")
}

function ConvertTo-CoreDetectionPayload {
    param([Parameter(Mandatory)] [hashtable] $Configuration)
    $expected = [ordered] @{}
    foreach ($key in @('FrontendUrl', 'Environment', 'CustomerName', 'SubmissionEnabled', 'PackageVersion',
            'CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
            'PkiRootCaThumbprints', 'PkiRootCaSubjects',
            'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
        if (-not $Configuration.Contains($key)) {
            throw "Core configuration does not define required detection value '$key'."
        }
        $expected[$key] = $Configuration[$key]
    }
    $json = [pscustomobject] $expected | ConvertTo-Json -Depth 4 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

$coreStaging = Join-Path $release 'Source'
$null = New-Item -ItemType Directory -Path (Join-Path $coreStaging 'Modules') -Force
foreach ($file in $coreFiles) {
    Copy-Item -LiteralPath (Join-Path $coreSource $file) -Destination (Join-Path $coreStaging $file) -ErrorAction Stop
}
foreach ($file in $moduleFiles) {
    $moduleDestination = Join-Path $coreStaging "Modules\$file"
    $null = New-Item -ItemType Directory -Path (Split-Path $moduleDestination -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $moduleSource $file) -Destination $moduleDestination -ErrorAction Stop
}
$coreConfigPath = Join-Path $coreStaging 'Config.psd1'
[IO.File]::WriteAllText($coreConfigPath, (ConvertTo-ConfigurationText -Configuration $coreConfig), [Text.UTF8Encoding]::new($false))
$coreDetectionPath = Join-Path $coreStaging 'Detect.ps1'
$coreDetection = [IO.File]::ReadAllText($coreDetectionPath)
$coreDetectionMarker = '__LOGCOLLECTOR_CORE_EXPECTED_CONFIGURATION_BASE64__'
if (-not $coreDetection.Contains($coreDetectionMarker)) {
    throw 'Core detection template is missing its expected-configuration marker.'
}
$coreDetectionPayload = ConvertTo-CoreDetectionPayload -Configuration $coreConfig
$coreDetection = $coreDetection.Replace($coreDetectionMarker, $coreDetectionPayload)
[IO.File]::WriteAllText($coreDetectionPath, $coreDetection, [Text.UTF8Encoding]::new($false))
$null = Test-ModuleManifest -Path (Join-Path $coreStaging 'Modules\LogCollector.Client.psd1') -ErrorAction Stop

$coreOutput = Join-Path $release 'Package'
$null = New-Item -ItemType Directory -Path $coreOutput -Force
$coreArguments = @('-c', ('"{0}"' -f $coreStaging), '-s', 'Install.ps1', '-o', ('"{0}"' -f $coreOutput), '-qq')
$coreProcess = Start-Process -FilePath $tool.FullName -ArgumentList $coreArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
if ($coreProcess.ExitCode -ne 0) {
    throw "IntuneWinAppUtil failed for the core package with exit code $($coreProcess.ExitCode). Output retained at $release."
}
$coreArtifact = Join-Path $coreOutput 'Install.intunewin'
if (-not (Test-Path -LiteralPath $coreArtifact -PathType Leaf) -or (Get-Item -LiteralPath $coreArtifact).Length -eq 0) {
    throw "IntuneWinAppUtil produced no nonempty core Install.intunewin. Output retained at $release."
}
Copy-Item -LiteralPath (Join-Path $coreStaging 'Detect.ps1') -Destination (Join-Path $release 'Detect.ps1')
[pscustomobject]@{
    PackageVersion      = $coreVersion
    IntuneWinPackage    = $coreArtifact
    PackageSha256       = (Get-FileHash -LiteralPath $coreArtifact -Algorithm SHA256).Hash
    DetectionScript     = Join-Path $release 'Detect.ps1'
    ConfigurationSha256 = (Get-FileHash -LiteralPath $coreConfigPath -Algorithm SHA256).Hash
    InstallCommand      = '"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Install.ps1"'
    UninstallCommand    = ('"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        '"%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\Uninstall.ps1" -ExpectedVersion {0}') -f $coreVersion
    ContentPrepTool     = $tool.FullName
}
