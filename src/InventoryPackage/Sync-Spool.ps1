#Requires -Version 5.1
# Version 1.7.0. Protected metadata-only spool diagnostics; no new collection.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$packageVersion = '1.7.0'
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    $configPath = Join-Path $PSScriptRoot 'Config.psd1'
    $customerName = Get-InventoryLogCustomerName -ConfigPath $configPath
    if ($customerName) {
        $log = Initialize-InventoryLogContext -Component Spool -PackageVersion $packageVersion `
            -CustomerName $customerName
    }
    if ($log) {
        $startData = @{ PackageVersion = $packageVersion; Mode = 'Drain' }
        if ($log.FallbackUsed) {
            $startData.Stage = 'FallbackLog'
            $startData.ExceptionType = $log.PrimaryExceptionType
            $startData.HResult = $log.PrimaryHResult
        }
        Write-InventoryLog -Context $log -Event RunStarted -Data $startData
    }
    $stage = 'ImportRuntime'
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
    $stage = 'Drain'
    $sink = if ($log) { New-InventoryDiagnosticSink -Context $log } else { $null }
    $result = Invoke-InventoryDrain -ConfigPath $configPath -DiagnosticSink $sink
    $result
    if ($log) {
        Write-InventoryLog -Context $log -Event RunCompleted -Data @{
            Delivered = $result.Delivered; Quarantined = $result.Quarantined; Remaining = $result.Remaining
            Stopped = $result.Stopped; DurationMs = $timer.ElapsedMilliseconds
        }
    }
    if ($result.Stopped -or $result.Quarantined -gt 0) { exit 1 }
}
catch {
    if ($log) { Write-InventoryLogFailure -Context $log -ErrorRecord $_ -Stage $stage }
    throw
}
finally { $timer.Stop() }
