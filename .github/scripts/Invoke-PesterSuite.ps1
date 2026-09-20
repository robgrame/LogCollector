#Requires -Version 7.2
<#
.SYNOPSIS
Runs every Pester test file in an isolated PowerShell process.
.NOTES
Version 1.0.1. Isolation prevents module-name collisions between suites.
#>
[CmdletBinding()]
param(
    [string] $TestRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests\Pester'),
    [string] $ResultRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'TestResults\Pester'),
    [string] $PesterVersion = '5.7.1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $TestRoot -PathType Container)) {
    throw "Pester test root not found: $TestRoot"
}

$null = New-Item -ItemType Directory -Path $ResultRoot -Force
$failures = New-Object 'Collections.Generic.List[string]'
$files = @(Get-ChildItem -LiteralPath $TestRoot -Filter '*.Tests.ps1' -File -Recurse | Sort-Object FullName)
if ($files.Count -eq 0) { throw "No Pester test files found under $TestRoot." }

foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($TestRoot.TrimEnd('\', '/').Length).TrimStart('\', '/')
    $resultName = (($relativePath -replace '[\\/]', '.') -replace '\.ps1$', '.xml')
    $resultPath = Join-Path $ResultRoot $resultName
    $testPathLiteral = $file.FullName.Replace("'", "''")
    $resultPathLiteral = $resultPath.Replace("'", "''")
    $versionLiteral = $PesterVersion.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion '$versionLiteral' -ErrorAction Stop
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = '$testPathLiteral'
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$configuration.TestResult.OutputPath = '$resultPathLiteral'
Invoke-Pester -Configuration `$configuration
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    Write-Output "Running $($file.Name) in an isolated pwsh process..."
    & pwsh -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedCommand
    if ($LASTEXITCODE -ne 0) { $failures.Add($file.Name) }
}

if ($failures.Count -gt 0) {
    throw "Pester failed in $($failures.Count) suite(s): $($failures -join ', ')"
}

Write-Output "All $($files.Count) isolated Pester suites passed."
