#Requires -Version 5.1
#Requires -RunAsAdministrator
# Version 1.4.5. Logs lifecycle; removes only tasks, never retained data or logs.
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    if (-not $WhatIfPreference) {
        $log = New-InventoryLogContext -Component Install
        Write-InventoryLog -Context $log -Event RunStarted -Data @{ PackageVersion = '1.4.5'; Mode = 'Uninstall' }
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
