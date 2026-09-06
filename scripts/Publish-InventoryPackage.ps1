#Requires -Version 5.1
<#
.SYNOPSIS
Creates a customer-neutral inventory folder with the shared client and deployment configuration.
.NOTES
Version 1.2.3. No customer source, device inventory, certificates or Azure credentials are read.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [Uri] $FrontendUrl,
    [string] $Environment = '',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $DeviceTableName = 'DeviceInventory_CL',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $AppTableName = 'AppInventory_CL',
    [string[]] $PkiRootCaThumbprints = @(),
    [string[]] $PkiRootCaSubjects = @(),
    [string[]] $PkiIntermediateCaThumbprints = @(),
    [string[]] $PkiIntermediateCaSubjects = @(),
    [ValidateNotNullOrEmpty()] [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $repo 'out\Inventory' }
$source = Join-Path $repo 'src\InventoryPackage'
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $source 'Config.psd1')
$config.FrontendUrl = $FrontendUrl.AbsoluteUri
$config.Environment = $Environment
$config.DeviceTableName = $DeviceTableName
$config.AppTableName = $AppTableName
$config.PkiRootCaThumbprints = $PkiRootCaThumbprints
$config.PkiRootCaSubjects = $PkiRootCaSubjects
$config.PkiIntermediateCaThumbprints = $PkiIntermediateCaThumbprints
$config.PkiIntermediateCaSubjects = $PkiIntermediateCaSubjects
foreach ($key in @('PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
    if ($null -eq $config[$key]) { throw "$key must be an array; use @() for no constraint." }
    foreach ($entry in $config[$key]) {
        if ([string]::IsNullOrWhiteSpace($entry)) { throw "$key contains an empty entry." }
        if ($key -like '*Thumbprints' -and ($entry -replace '[\s:]', '') -notmatch '^[0-9a-fA-F]{40}$') {
            throw "$key entries must be SHA1 certificate thumbprints (40 hexadecimal digits)."
        }
    }
}
$target = Join-Path $OutputRoot $config.PackageVersion
$files = @('Config.psd1', 'Inventory.Collection.psm1', 'Inventory.Runtime.psm1',
    'Run-Inventory.ps1', 'Sync-Spool.ps1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')
$client = Join-Path $repo 'src\Client'
Import-Module (Join-Path $client 'LogCollector.Client.psd1') -ErrorAction Stop
$null = Get-LogCollectorSpoolPath -FrontendUrl $FrontendUrl
$manifest = Test-ModuleManifest -Path (Join-Path $client 'LogCollector.Client.psd1') -ErrorAction Stop
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $file) -PathType Leaf)) { throw "Missing package source: $file" }
}
if (Test-Path -LiteralPath $target) { throw "Output already exists: $target. Use a new OutputRoot; existing packages are never overwritten." }
if ($PSCmdlet.ShouldProcess($target, 'Create ready-to-package universal inventory folder')) {
    $null = New-Item -ItemType Directory -Path (Join-Path $target 'Modules') -Force
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $target $file) }
    foreach ($file in $manifest.FileList) {
        $name = Split-Path $file -Leaf
        Copy-Item -LiteralPath (Join-Path $client $name) -Destination (Join-Path $target "Modules\$name")
    }
    $configLines = @('@{')
    foreach ($key in @($config.Keys | Sort-Object)) {
        $value = $config[$key]
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
        $configLines += "    $key = $literal"
    }
    $configLines += '}'
    [IO.File]::WriteAllText((Join-Path $target 'Config.psd1'), ($configLines -join "`r`n"), [Text.UTF8Encoding]::new($false))
    $null = Test-ModuleManifest -Path (Join-Path $target 'Modules\LogCollector.Client.psd1') -ErrorAction Stop
    [pscustomobject]@{
        PackageVersion = $config.PackageVersion; PackagePath = [IO.Path]::GetFullPath($target)
        SetupFile = 'Install.ps1'; FileCount = @(Get-ChildItem -LiteralPath $target -File -Recurse).Count
        SubmissionEnabled = $config.SubmissionEnabled
    }
}
