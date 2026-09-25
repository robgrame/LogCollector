#Requires -Version 5.1
<#
.SYNOPSIS
Creates a customer-neutral inventory folder that consumes shared configuration from LogCollector Core.
.NOTES
Version 1.6.0. No customer source, device inventory, certificates or Azure credentials are read.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Settings')]
param(
    [Parameter(ParameterSetName = 'Settings')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $DeviceTableName = 'DeviceInventory_CL',
    [Parameter(ParameterSetName = 'Settings')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $AppTableName = 'AppInventory_CL',
    [Parameter(ParameterSetName = 'Settings')] [bool] $CollectDeviceInventory = $true,
    [Parameter(ParameterSetName = 'Settings')] [bool] $CollectAppInventory = $true,
    [Parameter(ParameterSetName = 'Settings')] [ValidateRange(1, 10)] [int] $MaxAttempts = 3,
    [Parameter(ParameterSetName = 'Settings')] [ValidateRange(1, 300)] [int] $TimeoutSeconds = 30,
    [Parameter(Mandatory, ParameterSetName = 'Configuration')] [string] $ConfigurationPath,
    [ValidateNotNullOrEmpty()] [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $repo 'out\Inventory' }
$source = Join-Path $repo 'src\InventoryPackage'
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $source 'Config.psd1')
$version = $config.PackageVersion
$versionFile = Join-Path $source 'Version'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf) -or
    [IO.File]::ReadAllText($versionFile).Trim() -ne $version) {
    throw "Inventory Version file must contain package version $version."
}
if ($PSCmdlet.ParameterSetName -eq 'Configuration') {
    $config = Import-PowerShellDataFile -LiteralPath $ConfigurationPath
    if ($config.PackageVersion -ne $version) { throw "Configuration must use package version $version." }
}
else {
    $config.DeviceTableName = $DeviceTableName
    $config.AppTableName = $AppTableName
    $config.CollectDeviceInventory = $CollectDeviceInventory
    $config.CollectAppInventory = $CollectAppInventory
    $config.MaxAttempts = $MaxAttempts
    $config.TimeoutSeconds = $TimeoutSeconds
}
$target = Join-Path $OutputRoot $config.PackageVersion
$files = @('Version', 'Config.psd1', 'Inventory.Collection.psm1', 'Inventory.Runtime.psm1', 'Inventory.Logging.psm1',
    'Run-Inventory.ps1', 'Sync-Spool.ps1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $file) -PathType Leaf)) { throw "Missing package source: $file" }
}
if (Test-Path -LiteralPath $target) { throw "Output already exists: $target. Use a new OutputRoot; existing packages are never overwritten." }
if ($PSCmdlet.ShouldProcess($target, 'Create ready-to-package universal inventory folder')) {
    $null = New-Item -ItemType Directory -Path $target -Force
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $target $file) }
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
    $configPath = Join-Path $target 'Config.psd1'
    if ($PSCmdlet.ParameterSetName -eq 'Configuration') {
        Copy-Item -LiteralPath $ConfigurationPath -Destination $configPath -ErrorAction Stop
    }
    else {
        [IO.File]::WriteAllText($configPath, ($configLines -join "`r`n"), [Text.UTF8Encoding]::new($false))
    }
    $runtime = Import-Module (Join-Path $target 'Inventory.Runtime.psm1') -PassThru -ErrorAction Stop
    $config = & $runtime { param($Path) Get-InventoryConfiguration -Path $Path -SkipCoreConfiguration } $configPath
    $configurationSha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $detection = [IO.File]::ReadAllText((Join-Path $source 'Detect.ps1'))
    if (-not $detection.Contains('__LOGCOLLECTOR_CONFIGURATION_SHA256__')) { throw 'Detection template is missing its configuration hash marker.' }
    $detection = $detection.Replace('__LOGCOLLECTOR_CONFIGURATION_SHA256__', $configurationSha256)
    [IO.File]::WriteAllText((Join-Path $target 'Detect.ps1'), $detection, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        PackageVersion = $config.PackageVersion; PackagePath = [IO.Path]::GetFullPath($target)
        SetupFile = 'Install.ps1'; FileCount = @(Get-ChildItem -LiteralPath $target -File -Recurse).Count
        ConfigurationSha256 = $configurationSha256
        MinimumCoreVersion = '1.11.0'
    }
}
