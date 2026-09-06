#Requires -Version 5.1
<#
.SYNOPSIS
Runs custom inventory using the destinations supplied in Config.psd1.
.NOTES
Version 1.4.5. Protected metadata-only diagnostics for each run.
#>
[CmdletBinding()]
param([switch] $Preview, [switch] $QueueOnly)
$ErrorActionPreference = 'Stop'
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    $log = New-InventoryLogContext -Component Inventory
    $mode = if ($Preview) { 'Preview' } elseif ($QueueOnly) { 'QueueOnly' } else { 'Live' }
    Write-InventoryLog -Context $log -Event RunStarted -Data @{ PackageVersion = '1.4.5'; Mode = $mode }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell so both registry views are collected.' }
    $stage = 'ImportRuntime'
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
    $sink = New-InventoryDiagnosticSink -Context $log
    $stage = 'CollectAndSend'
    $failed = $false
    Invoke-InventoryRun -ConfigPath (Join-Path $PSScriptRoot 'Config.psd1') -Preview:$Preview -QueueOnly:$QueueOnly -DiagnosticSink $sink |
        ForEach-Object {
            $_
            if ($_.Disposition -notin @('Delivered', 'Deferred', 'Preview')) { $failed = $true }
        }
    Write-InventoryLog -Context $log -Event RunCompleted -Data @{ Stopped = $failed; DurationMs = $timer.ElapsedMilliseconds }
    if ($failed) { exit 1 }
}
catch {
    if ($log) { Write-InventoryLogFailure -Context $log -ErrorRecord $_ -Stage $stage }
    throw
}
finally { $timer.Stop() }
