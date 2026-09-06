#Requires -Version 5.1
<#
.SYNOPSIS
Runs custom inventory using the destinations supplied in Config.psd1.
.NOTES
Version 1.1.1. Run in 64-bit Windows PowerShell as SYSTEM or elevated administrator.
#>
[CmdletBinding()]
param([switch] $Preview, [switch] $QueueOnly)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell so both registry views are collected.' }
Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
$failed = $false
Invoke-InventoryRun -ConfigPath (Join-Path $PSScriptRoot 'Config.psd1') -Preview:$Preview -QueueOnly:$QueueOnly |
    ForEach-Object {
        $_
        if ($_.Disposition -notin @('Delivered', 'Deferred', 'Preview')) { $failed = $true }
    }
if ($failed) { exit 1 }
