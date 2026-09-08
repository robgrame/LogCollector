#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Removes the machine-wide LogCollector core module.
.DESCRIPTION
Removes this version's module directory. The endpoint configuration and the shared spool
are kept by default: other packages and scripts on the device depend on them, and spooled
records that have not reached Log Analytics yet would otherwise be destroyed.
.PARAMETER RemoveConfiguration
Also remove the machine-wide endpoint configuration. Use only when retiring LogCollector
from the device entirely.
.PARAMETER RemoveSpool
Also remove the shared spool, discarding any records not yet delivered.
.NOTES
Version 1.7.0.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $RemoveConfiguration,
    [switch] $RemoveSpool
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packageVersion = '1.7.0'
Import-Module (Join-Path $PSScriptRoot 'Core.Provisioning.psm1') -Force -ErrorAction Stop
$target = Get-LogCollectorModuleRoot -Version $packageVersion

if (Test-Path -LiteralPath $target -PathType Container) {
    if ($PSCmdlet.ShouldProcess($target, 'Remove the LogCollector core module')) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        Write-Output "Removed LogCollector core $packageVersion from $target."
    }
}
else {
    Write-Output "LogCollector core $packageVersion is not installed at $target."
}

# Drop the now-empty parent so PSModulePath does not keep advertising an empty module.
$parent = Split-Path $target -Parent
if ((Test-Path -LiteralPath $parent -PathType Container) -and
    -not (Get-ChildItem -LiteralPath $parent -Force)) {
    if ($PSCmdlet.ShouldProcess($parent, 'Remove the empty module root')) {
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }
}

if ($RemoveConfiguration) {
    $configuration = Join-Path $env:ProgramData 'LogCollector\Config\Endpoint.psd1'
    if (Test-Path -LiteralPath $configuration -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($configuration, 'Remove the machine-wide endpoint configuration')) {
            Remove-Item -LiteralPath $configuration -Force -ErrorAction Stop
            Write-Output "Removed $configuration."
            Write-Warning 'Any other LogCollector script on this device now has no endpoint until the core package is reinstalled.'
        }
    }
}

if ($RemoveSpool) {
    $spool = Join-Path $env:ProgramData 'LogCollector\SharedSpool'
    if (Test-Path -LiteralPath $spool -PathType Container) {
        $pending = @(Get-ChildItem -LiteralPath $spool -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($PSCmdlet.ShouldProcess($spool, "Remove the shared spool, discarding $pending queued file(s)")) {
            Remove-Item -LiteralPath $spool -Recurse -Force -ErrorAction Stop
            Write-Warning "Removed $spool, discarding $pending file(s) that had not reached Log Analytics."
        }
    }
}
