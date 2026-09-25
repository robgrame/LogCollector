#Requires -Version 5.1
<#
.SYNOPSIS
Runs custom inventory using the destinations supplied in Config.psd1.
.NOTES
Version 1.8.0. Protected metadata-only diagnostics for each run.
#>
[CmdletBinding()]
param([switch] $Preview, [switch] $QueueOnly)
$ErrorActionPreference = 'Stop'
$packageVersion = '1.8.0'
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    $configPath = Join-Path $PSScriptRoot 'Config.psd1'
    $customerName = Get-InventoryLogCustomerName -ConfigPath $configPath
    if ($customerName) {
        $log = Initialize-InventoryLogContext -Component Inventory -PackageVersion $packageVersion `
            -CustomerName $customerName
    }
    $mode = if ($Preview) { 'Preview' } elseif ($QueueOnly) { 'QueueOnly' } else { 'Live' }
    if ($log) {
        $startData = @{ PackageVersion = $packageVersion; Mode = $mode }
        if ($log.FallbackUsed) {
            $startData.Stage = 'FallbackLog'
            $startData.ExceptionType = $log.PrimaryExceptionType
            $startData.HResult = $log.PrimaryHResult
        }
        Write-InventoryLog -Context $log -Event RunStarted -Data $startData
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell so both registry views are collected.' }
    $stage = 'ImportRuntime'
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
    $sink = if ($log) { New-InventoryDiagnosticSink -Context $log } else { $null }
    $stage = 'CollectAndSend'
    $results = @(Invoke-InventoryRun -ConfigPath $configPath `
            -Preview:$Preview -QueueOnly:$QueueOnly -DiagnosticSink $sink)
    $results | Write-Output
    $failed = @($results | Where-Object Disposition -NotIn @('Delivered', 'Deferred', 'Preview')).Count -gt 0
    if ($log) {
        Write-InventoryLog -Context $log -Event RunCompleted -Data @{
            Stopped = $failed; DurationMs = $timer.ElapsedMilliseconds
        }
    }
    if ($failed) { exit 1 }
}
catch {
    if ($log) { Write-InventoryLogFailure -Context $log -ErrorRecord $_ -Stage $stage }
    throw
}
finally { $timer.Stop() }
