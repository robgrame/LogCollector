#Requires -Version 5.1
<#
.SYNOPSIS
Builds a complete inventory Win32 package using Microsoft's local content prep tool.
.NOTES
Version 1.4.5. Does not install tasks, collect inventory, upload content or change Azure.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Endpoint')]
param(
    [Parameter(Mandatory)] [string] $IntuneWinAppUtilPath,
    [Parameter(Mandatory, ParameterSetName = 'Endpoint')] [Uri] $FrontendUrl,
    [Parameter(ParameterSetName = 'Endpoint')] [string] $Environment = '',
    [Parameter(Mandatory, ParameterSetName = 'Configuration')] [string] $ConfigurationPath,
    [ValidateNotNullOrEmpty()] [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $repo 'out\IntuneWin32' }
$tool = Get-Item -LiteralPath $IntuneWinAppUtilPath -ErrorAction Stop
if ($tool.PSIsContainer -or $tool.Extension -ne '.exe') { throw 'Supply the official IntuneWinAppUtil.exe file.' }
$defaults = Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'src\InventoryPackage\Config.psd1')
$version = $defaults.PackageVersion
$configurationFile = $null
if ($PSCmdlet.ParameterSetName -eq 'Configuration') {
    $configurationFile = (Get-Item -LiteralPath $ConfigurationPath -ErrorAction Stop).FullName
    $configuration = Import-PowerShellDataFile -LiteralPath $configurationFile
    if ($configuration.PackageVersion -ne $version) { throw "Configuration must use package version $version." }
}
$release = [IO.Path]::GetFullPath((Join-Path $OutputRoot $version))
if ($release.Contains('"')) { throw 'Output paths must not contain double quotes.' }
if (Test-Path -LiteralPath $release) { throw "Output already exists: $release. Choose a new OutputRoot; releases are never overwritten." }
if (-not $PSCmdlet.ShouldProcess($release, 'Build the complete inventory .intunewin package')) { return }

$buildParameters = @{ OutputRoot = Join-Path $release 'Source' }
if ($configurationFile) {
    $buildParameters.ConfigurationPath = $configurationFile
}
else {
    $buildParameters.FrontendUrl = $FrontendUrl
    $buildParameters.Environment = $Environment
}
$package = & (Join-Path $PSScriptRoot 'Publish-InventoryPackage.ps1') @buildParameters
$output = Join-Path $release 'Output'
$null = New-Item -ItemType Directory -Path $output -ErrorAction Stop
$arguments = @('-c', ('"{0}"' -f $package.PackagePath), '-s', 'Install.ps1',
    '-o', ('"{0}"' -f $output), '-qq')
$process = Start-Process -FilePath $tool.FullName -ArgumentList $arguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
if ($process.ExitCode -ne 0) { throw "IntuneWinAppUtil failed with exit code $($process.ExitCode). Output retained at $release." }
$artifact = Join-Path $output 'Install.intunewin'
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or (Get-Item -LiteralPath $artifact).Length -eq 0) {
    throw "IntuneWinAppUtil produced no nonempty Install.intunewin. Output retained at $release."
}
Copy-Item -LiteralPath (Join-Path $package.PackagePath 'Detect.ps1') -Destination (Join-Path $release 'Detect.ps1')
Copy-Item -LiteralPath (Join-Path $repo 'docs\intune-win32-deployment.md') -Destination (Join-Path $release 'Intune-Deployment.md')
[pscustomobject]@{
    PackageVersion = $version
    PackagePath = $artifact
    PackageSha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
    SourcePath = $package.PackagePath
    DetectionScript = Join-Path $release 'Detect.ps1'
    DeploymentGuide = Join-Path $release 'Intune-Deployment.md'
    SubmissionEnabled = $package.SubmissionEnabled
    ConfigurationSha256 = $package.ConfigurationSha256
}
