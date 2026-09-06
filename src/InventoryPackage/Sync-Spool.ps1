#Requires -Version 5.1
# Version 1.4.5. Protected metadata-only spool diagnostics; no new collection.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    $log = New-InventoryLogContext -Component Spool
    Write-InventoryLog -Context $log -Event RunStarted -Data @{ PackageVersion = '1.4.5'; Mode = 'Drain' }
    $stage = 'ImportRuntime'
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
    $stage = 'Drain'
    $result = Invoke-InventoryDrain -ConfigPath (Join-Path $PSScriptRoot 'Config.psd1') -DiagnosticSink (New-InventoryDiagnosticSink -Context $log)
    $result
    Write-InventoryLog -Context $log -Event RunCompleted -Data @{
        Delivered = $result.Delivered; Quarantined = $result.Quarantined; Remaining = $result.Remaining
        Stopped = $result.Stopped; DurationMs = $timer.ElapsedMilliseconds
    }
    if ($result.Stopped -or $result.Quarantined -gt 0) { exit 1 }
}
catch {
    if ($log) { Write-InventoryLogFailure -Context $log -ErrorRecord $_ -Stage $stage }
    throw
}
finally { $timer.Stop() }
