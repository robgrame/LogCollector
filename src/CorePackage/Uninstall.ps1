#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Removes the machine-wide LogCollector core module.
.DESCRIPTION
Removes the stable module directory. The endpoint configuration and the shared spool
are kept by default: other packages and scripts on the device depend on them, and spooled
records that have not reached Log Analytics yet would otherwise be destroyed.
.PARAMETER RemoveConfiguration
Also remove the machine-wide endpoint configuration. Use only when retiring LogCollector
from the device entirely.
.PARAMETER RemoveSpool
Also remove the shared spool, discarding any records not yet delivered.
.PARAMETER ExpectedVersion
Removes the module only when its manifest still has this version. Intune supplies the
version from the app being removed, so an obsolete uninstall command cannot remove a newer
Core release that has already replaced it at the stable path.
.NOTES
Version 1.11.0.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $RemoveConfiguration,
    [switch] $RemoveSpool,
    [version] $ExpectedVersion = '1.11.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Core.Provisioning.psm1') -Force -ErrorAction Stop
$target = Get-LogCollectorModuleRoot
$installedManifestPath = Join-Path $target 'LogCollector.Client.psd1'
if (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) {
    try {
        $installedVersion = [version] (Import-PowerShellDataFile -LiteralPath $installedManifestPath -ErrorAction Stop).ModuleVersion
        if ($installedVersion -ne $ExpectedVersion) {
            Write-Output ("LogCollector core {0} is installed at {1}; requested removal of {2} is already satisfied." -f
                $installedVersion, $target, $ExpectedVersion)
            return
        }
    }
    catch {
        Write-Warning "The installed module manifest is unreadable; removing the damaged Core installation: $($_.Exception.Message)"
    }
}
$endpointModulePath = @(
    (Join-Path $PSScriptRoot 'EndpointConfiguration.psm1'),
    (Join-Path $PSScriptRoot 'Modules\EndpointConfiguration.psm1')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
$endpointModule = if ($endpointModulePath) {
    Import-Module $endpointModulePath -PassThru -Force -ErrorAction Stop
} else { $null }
$configuration = $null
$dataRoot = $null
try {
    if (-not $endpointModule) { throw 'EndpointConfiguration.psm1 was not found beside the uninstaller or under Modules.' }
    $configuration = & $endpointModule { Get-LogCollectorEndpointConfiguration }
    $dataRoot = [string] $configuration.DataRoot
}
catch {
    Write-Warning "The installed endpoint configuration could not be resolved: $($_.Exception.Message)"
}

if (Test-Path -LiteralPath $target -PathType Container) {
    if ($PSCmdlet.ShouldProcess($target, 'Remove the LogCollector core module')) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        Write-Output "Removed LogCollector core $ExpectedVersion from $target."
    }
}
else {
    Write-Output "LogCollector core $ExpectedVersion is not installed at $target."
}

if ($RemoveConfiguration) {
    $configurationPath = if ($configuration) { [string] $configuration.ConfigurationPath } else {
        Join-Path $env:ProgramData 'LogCollector\Config\Endpoint.psd1'
    }
    if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($configurationPath, 'Remove the machine-wide endpoint configuration')) {
            Remove-Item -LiteralPath $configurationPath -Force -ErrorAction Stop
            Write-Output "Removed $configurationPath."
            Write-Warning 'Any other LogCollector script on this device now has no endpoint until the core package is reinstalled.'
        }
    }
}

if ($RemoveSpool) {
    $spool = if ($dataRoot) { Join-Path $dataRoot 'SharedSpool' } else {
        Join-Path $env:ProgramData 'LogCollector\SharedSpool'
    }
    if (Test-Path -LiteralPath $spool -PathType Container) {
        $pending = @(Get-ChildItem -LiteralPath $spool -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($PSCmdlet.ShouldProcess($spool, "Remove the shared spool, discarding $pending queued file(s)")) {
            Remove-Item -LiteralPath $spool -Recurse -Force -ErrorAction Stop
            Write-Warning "Removed $spool, discarding $pending file(s) that had not reached Log Analytics."
        }
    }
}
