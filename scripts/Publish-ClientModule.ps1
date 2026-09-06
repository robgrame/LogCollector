#Requires -Version 5.1
<#
.SYNOPSIS
Packages the shared client module without installing it or changing Azure.
.NOTES
Version 1.0.0. Output contains module source only, never certificates or credentials.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string] $OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out\Client'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Client'
$manifest = Test-ModuleManifest -Path (Join-Path $source 'LogCollector.Client.psd1') -ErrorAction Stop
$version = $manifest.Version.ToString()
if (-not $PSCmdlet.ShouldProcess($OutputDirectory, "Package LogCollector.Client $version")) { return }

$run = Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))
$staging = Join-Path $run 'package'
$modulePath = Join-Path $staging "LogCollector.Client\$version"
$null = New-Item -ItemType Directory -Path $modulePath -Force
foreach ($file in $manifest.FileList) {
    $name = Split-Path $file -Leaf
    if ($name -notmatch '\.ps(d|m)1$') { throw "Unexpected module package file: $name" }
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $modulePath $name) -ErrorAction Stop
}
$null = Test-ModuleManifest -Path (Join-Path $modulePath 'LogCollector.Client.psd1') -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $run "LogCollector.Client-$version.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
[pscustomobject]@{
    ModuleVersion = $version
    ModulePath = $modulePath
    PackagePath = $zip
    PackageSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
}
