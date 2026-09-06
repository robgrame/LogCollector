#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs the complete custom inventory package and its two SYSTEM tasks without touching legacy tasks.
.NOTES
Version 1.4.5. Protected lifecycle diagnostics; tasks follow SubmissionEnabled.
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    if (-not $WhatIfPreference) {
        $log = New-InventoryLogContext -Component Install
        Write-InventoryLog -Context $log -Event RunStarted -Data @{ PackageVersion = '1.4.5'; Mode = 'Install' }
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Run this installer with 64-bit Windows PowerShell.' }
    $stage = 'LoadConfiguration'
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
    $configPath = Join-Path $PSScriptRoot 'Config.psd1'
    $config = Get-InventoryConfiguration -Path $configPath
    if ($config.PackageVersion -ne '1.4.5') { throw 'Config.psd1 must match package version 1.4.5; do not mix files from older packages.' }
    if ($log) {
        Write-InventoryLog -Context $log -Event ConfigurationLoaded -Data @{
            PackageVersion = $config.PackageVersion; ConfigurationSha256 = (Get-FileHash -LiteralPath $configPath).Hash
            SubmissionEnabled = $config.SubmissionEnabled; Endpoint = $config.FrontendUrl
        }
    }
    $target = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'LogCollector\CustomInventory\1.4.5'
    $taskPath = '\LogCollector\'
    $names = @('LogCollector-CustomInventory', 'LogCollector-CustomInventory-Spool')
    $files = @('Config.psd1', 'Inventory.Collection.psm1', 'Inventory.Runtime.psm1', 'Inventory.Logging.psm1',
        'Run-Inventory.ps1', 'Sync-Spool.ps1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')
    $manifestPath = Join-Path $PSScriptRoot 'Modules\LogCollector.Client.psd1'
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    foreach ($file in $manifest.FileList) { $files += 'Modules\' + (Split-Path $file -Leaf) }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) { throw "Incomplete package: $file" }
    }
    if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -eq $target.TrimEnd('\')) {
        throw 'Run Install.ps1 from the distribution folder, not the installed directory.'
    }
    if ($PSCmdlet.ShouldProcess($target, 'Install inventory package and register its SYSTEM tasks')) {
        $stage = 'CheckExistingTasks'
        $existing = @(Get-ScheduledTask -ErrorAction Stop |
            Where-Object { $_.TaskPath -eq $taskPath -and $_.TaskName -in $names })
        if (@($existing | Where-Object State -eq 'Running').Count -gt 0) {
            throw 'An inventory package task is running. Let it finish before updating the package.'
        }
        foreach ($task in $existing) {
            $null = Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $taskPath -ErrorAction Stop
        }
        $stage = 'CopyFiles'
        # Use the pinned bundled module's filesystem hardening, not a permissive Copy-Item tree.
        $filesystem = Import-Module (Join-Path $PSScriptRoot 'Modules\InventorySpool.psm1') -PassThru -ErrorAction Stop
        & $filesystem {
            param($Directory, $Files)
            $null = Assert-SpoolHierarchy -Path $Directory -Directory -Create
            $null = Assert-SpoolHierarchy -Path (Join-Path $Directory 'Modules') -Directory -Create
            foreach ($file in $Files) {
                $null = Assert-SpoolHierarchy -Path (Join-Path $Directory $file) -AllowMissing
            }
        } $target $files
        foreach ($file in $files) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $target $file) -Force -ErrorAction Stop
        }
        & $filesystem {
            param($Directory, $Files)
            foreach ($file in $Files) { $null = Assert-SpoolHierarchy -Path (Join-Path $Directory $file) }
        } $target $files
        $stage = 'RegisterTasks'
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        $weekly = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday,Saturday -At '09:00' -RandomDelay (New-TimeSpan -Hours 2)
        $drain = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Hours 1)
        $triggers = @($weekly, $drain)
        $scripts = @('Run-Inventory.ps1', 'Sync-Spool.ps1')
        for ($i = 0; $i -lt $names.Count; $i++) {
            $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $target $scripts[$i])
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
            $definition = New-ScheduledTask -Action $action -Trigger $triggers[$i] -Principal $principal -Settings $settings
            $definition.Settings.Enabled = $config.SubmissionEnabled
            $null = Register-ScheduledTask -TaskName $names[$i] -TaskPath $taskPath -InputObject $definition -Force -ErrorAction Stop
            if ($log) { Write-InventoryLog -Context $log -Event TasksRegistered -Data @{ TaskName = $names[$i]; Enabled = $config.SubmissionEnabled } }
        }
        $stage = 'VerifyTasks'
        $verify = Get-ScheduledTask -TaskPath $taskPath -TaskName $names[0] -ErrorAction Stop
        if ($verify.Triggers[0].RandomDelay -ne 'PT2H') { throw 'Installed inventory task does not retain its two-hour RandomDelay.' }
        foreach ($name in $names) {
            $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction Stop
            if ($task.Settings.Enabled -ne $config.SubmissionEnabled) { throw "Task enablement differs from configuration: $name" }
        }
        Write-Output "Installed Custom Inventory 1.4.5 at $target; SubmissionEnabled=$($config.SubmissionEnabled)."
        if (-not $config.SubmissionEnabled) { Write-Warning 'Tasks are disabled until the original Azure table schemas and DCR mappings are ready.' }
    }
    if ($log) { Write-InventoryLog -Context $log -Event RunCompleted -Data @{ Mode = 'Install'; DurationMs = $timer.ElapsedMilliseconds } }
}
catch {
    if ($log) { Write-InventoryLogFailure -Context $log -ErrorRecord $_ -Stage $stage }
    throw
}
finally { $timer.Stop() }
