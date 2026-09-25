#Requires -Version 5.1
#Requires -RunAsAdministrator
# Version 1.9.0. Logs lifecycle; removes only tasks, never retained data or logs.
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
$packageVersion = '1.9.0'
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    $customerName = $null
    try {
        $coreManifest = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsPowerShell\Modules\LogCollector.Client\LogCollector.Client.psd1'
        Import-Module $coreManifest -MinimumVersion 1.11.0 -ErrorAction Stop
        $customerName = (Get-LogCollectorEndpointConfiguration).CustomerName
    }
    catch {
        if ((Split-Path $PSScriptRoot -Leaf) -eq 'CustomInventory') {
            $customerName = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf
        }
        Write-Verbose "Core configuration is unavailable; continuing task removal without it: $($_.Exception.Message)"
    }
    if (-not $WhatIfPreference -and $customerName) {
        $log = Initialize-InventoryLogContext -Component Install -PackageVersion $packageVersion `
            -CustomerName $customerName
        if ($log) {
            $startData = @{ PackageVersion = $packageVersion; Mode = 'Uninstall' }
            if ($log.FallbackUsed) {
                $startData.Stage = 'FallbackLog'
                $startData.ExceptionType = $log.PrimaryExceptionType
                $startData.HResult = $log.PrimaryHResult
            }
            Write-InventoryLog -Context $log -Event RunStarted -Data $startData
        }
    }
    $stage = 'RemoveTasks'
    $names = @('LogCollector-CustomInventory', 'LogCollector-CustomInventory-Spool')
    $tasks = @(Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskPath -eq '\LogCollector\' -and $_.TaskName -in $names })
    if (@($tasks | Where-Object State -eq 'Running').Count -gt 0) {
        throw 'Let the running inventory package task finish before uninstalling.'
    }
    foreach ($task in $tasks) {
        if ($PSCmdlet.ShouldProcess($task.TaskName, 'Remove inventory package task')) {
            Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
            if ($log) { Write-InventoryLog -Context $log -Event TasksRemoved -Data @{ TaskName = $task.TaskName } }
        }
    }
    Write-Output 'Inventory package tasks removed or absent. Package files, shared spool and logs are retained.'
    if ($log) { Write-InventoryLog -Context $log -Event RunCompleted -Data @{ Mode = 'Uninstall'; DurationMs = $timer.ElapsedMilliseconds } }
}
catch {
    if ($log) { Write-InventoryLogFailure -Context $log -ErrorRecord $_ -Stage $stage }
    throw
}
finally { $timer.Stop() }
