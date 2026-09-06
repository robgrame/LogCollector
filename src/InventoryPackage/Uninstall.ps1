#Requires -Version 5.1
#Requires -RunAsAdministrator
# Version 1.0.0. Removes only the custom inventory tasks; retained data is never deleted.
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
$names = @('LogCollector-CustomInventory', 'LogCollector-CustomInventory-Spool')
$tasks = @(Get-ScheduledTask -ErrorAction Stop |
    Where-Object { $_.TaskPath -eq '\LogCollector\' -and $_.TaskName -in $names })
if (@($tasks | Where-Object State -eq 'Running').Count -gt 0) {
    throw 'Let the running inventory package task finish before uninstalling.'
}
foreach ($task in $tasks) {
    if ($PSCmdlet.ShouldProcess($task.TaskName, 'Remove inventory package task')) {
        Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
    }
}
Write-Output 'inventory package tasks removed or absent. Package files and shared spool are retained.'
