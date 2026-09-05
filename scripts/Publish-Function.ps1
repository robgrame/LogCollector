#Requires -Version 5.1
<#
.SYNOPSIS
Builds and packages one Function app, optionally deploying it with Azure CLI.
.NOTES
Version 1.0.0. No Azure resources are changed unless -Deploy is supplied.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Frontend', 'Worker')]
    [string] $Component,
    [switch] $Deploy,
    [string] $ResourceGroup,
    [string] $AppName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Deploy -and (-not $ResourceGroup -or -not $AppName)) {
    throw '-Deploy requires -ResourceGroup and -AppName.'
}
if (-not $PSCmdlet.ShouldProcess($Component, 'Publish and package Function app')) { return }

$root = Split-Path $PSScriptRoot -Parent
$run = Join-Path $root ('out\' + $Component + '-' + [guid]::NewGuid().ToString('N'))
$publish = Join-Path $run 'publish'
$zipPath = Join-Path $run ($Component + '.zip')
$project = Join-Path $root ('src\Functions\' + $Component)
& dotnet publish $project -c Release -o $publish --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

# Compress-Archive excludes hidden entries; .azurefunctions must be in the ZIP.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($publish, $zipPath)
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    foreach ($required in @('host.json', 'functions.metadata', 'worker.config.json')) {
        if ($entries -notcontains $required) { throw "Package is missing $required." }
    }
    if (-not ($entries | Where-Object { $_ -like '.azurefunctions/*' })) {
        throw 'Package is missing .azurefunctions extension dependencies.'
    }
}
finally { $archive.Dispose() }

if ($Deploy -and $PSCmdlet.ShouldProcess($AppName, "Deploy $Component to $ResourceGroup")) {
    & az functionapp deployment source config-zip --resource-group $ResourceGroup --name $AppName --src $zipPath --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure deployment failed with exit code $LASTEXITCODE." }
}
Write-Output $zipPath
