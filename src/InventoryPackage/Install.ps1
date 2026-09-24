#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs the complete custom inventory package and its two SYSTEM tasks without touching legacy tasks.
.NOTES
Version 1.6.2. Protected lifecycle diagnostics; tasks follow SubmissionEnabled.
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$packageVersion = '1.6.2'
$log = $null
$stage = 'Initialize'
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Logging.psm1') -ErrorAction Stop
    if (-not $WhatIfPreference) {
        $log = Initialize-InventoryLogContext -Component Install -PackageVersion $packageVersion
        if ($log) {
            $startData = @{ PackageVersion = $packageVersion; Mode = 'Install' }
            if ($log.FallbackUsed) {
                $startData.Stage = 'FallbackLog'
                $startData.ExceptionType = $log.PrimaryExceptionType
                $startData.HResult = $log.PrimaryHResult
            }
            Write-InventoryLog -Context $log -Event RunStarted -Data $startData
        }
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Run this installer with 64-bit Windows PowerShell.' }
    $stage = 'LoadConfiguration'
    Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
    $configPath = Join-Path $PSScriptRoot 'Config.psd1'
    $config = Get-InventoryConfiguration -Path $configPath
    if ($config.PackageVersion -ne $packageVersion) { throw "Config.psd1 must match package version $packageVersion; do not mix files from older packages." }
    if ($log) {
        Write-InventoryLog -Context $log -Event ConfigurationLoaded -Data @{
            PackageVersion = $config.PackageVersion; ConfigurationSha256 = (Get-FileHash -LiteralPath $configPath).Hash
            SubmissionEnabled = $config.SubmissionEnabled; Endpoint = $config.FrontendUrl
        }
    }
    $target = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'CustomInventory'
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
        $stagedTarget = "$target.staging-$([guid]::NewGuid().ToString('N'))"
        $retiredTarget = $null
        $rejectedTarget = $null
        $existing = @()
        $tasksTouched = $false
        $filesActivated = $false
        $filesystem = Import-Module (Join-Path $PSScriptRoot 'Modules\InventorySpool.psm1') -PassThru -ErrorAction Stop
        try {
            $stage = 'CheckExistingTasks'
            $existing = @(Get-ScheduledTask -ErrorAction Stop |
                Where-Object { $_.TaskPath -eq $taskPath -and $_.TaskName -in $names })
            if (@($existing | Where-Object State -eq 'Running').Count -gt 0) {
                throw 'An inventory package task is running. Let it finish before updating the package.'
            }

            $stage = 'CopyFiles'
            # Use the pinned bundled module's filesystem hardening, not a permissive Copy-Item tree.
            & $filesystem {
                param($Directory, $Files)
                $null = Assert-SpoolHierarchy -Path $Directory -Directory -Create
                $null = Assert-SpoolHierarchy -Path (Join-Path $Directory 'Modules') -Directory -Create
                foreach ($file in $Files) {
                    $null = Assert-SpoolHierarchy -Path (Join-Path $Directory $file) -AllowMissing
                }
            } $stagedTarget $files
            foreach ($file in $files) {
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) `
                    -Destination (Join-Path $stagedTarget $file) -Force -ErrorAction Stop
            }
            & $filesystem {
                param($Directory, $Files)
                foreach ($file in $Files) {
                    $null = Assert-SpoolHierarchy -Path (Join-Path $Directory $file)
                }
            } $stagedTarget $files

            $tasksTouched = $true
            foreach ($task in $existing) {
                $null = Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $taskPath -ErrorAction Stop
            }
            $runningAfterDisable = @(Get-ScheduledTask -ErrorAction Stop |
                Where-Object {
                    $_.TaskPath -eq $taskPath -and $_.TaskName -in $names -and $_.State -eq 'Running'
                })
            if ($runningAfterDisable.Count -gt 0) {
                throw 'An inventory package task started during staging. Let it finish before updating the package.'
            }

            $stage = 'ActivateFiles'
            if (Test-Path -LiteralPath $target -PathType Container) {
                $retiredTarget = "$target.retired-$([guid]::NewGuid().ToString('N'))"
                Move-Item -LiteralPath $target -Destination $retiredTarget -ErrorAction Stop
            }
            Move-Item -LiteralPath $stagedTarget -Destination $target -ErrorAction Stop
            $filesActivated = $true

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
        }
        catch {
            $failure = $_
            $fileRollbackFailure = $null
            try {
                if ($filesActivated -and (Test-Path -LiteralPath $target -PathType Container)) {
                    $rejectedTarget = "$target.failed-$([guid]::NewGuid().ToString('N'))"
                    Move-Item -LiteralPath $target -Destination $rejectedTarget -ErrorAction Stop
                }
                if ($retiredTarget -and (Test-Path -LiteralPath $retiredTarget -PathType Container) -and
                    -not (Test-Path -LiteralPath $target)) {
                    Move-Item -LiteralPath $retiredTarget -Destination $target -ErrorAction Stop
                    $retiredTarget = $null
                }
            }
            catch { $fileRollbackFailure = $_ }
            $taskRollbackFailures = [Collections.Generic.List[string]]::new()
            if ($tasksTouched) {
                foreach ($name in $names) {
                    try {
                        $previous = @($existing | Where-Object TaskName -eq $name)
                        if ($previous.Count -eq 1) {
                            $null = Register-ScheduledTask -TaskName $name -TaskPath $taskPath `
                                -InputObject $previous[0] -Force -ErrorAction Stop
                        }
                        else {
                            $current = @(Get-ScheduledTask -ErrorAction Stop |
                                Where-Object { $_.TaskPath -eq $taskPath -and $_.TaskName -eq $name })
                            if ($current.Count -gt 1) {
                                throw "Found $($current.Count) scheduled tasks named '$name' at '$taskPath'."
                            }
                            if ($current.Count -eq 1) {
                                Unregister-ScheduledTask -TaskName $name -TaskPath $taskPath `
                                    -Confirm:$false -ErrorAction Stop
                            }
                        }
                    }
                    catch {
                        $taskRollbackFailures.Add("$name=$($_.Exception.Message)")
                    }
                }
            }
            if ($fileRollbackFailure -or $taskRollbackFailures.Count -gt 0) {
                $fileRollbackMessage = if ($fileRollbackFailure) {
                    $fileRollbackFailure.Exception.Message
                }
                else { 'None' }
                $taskRollbackMessage = if ($taskRollbackFailures.Count -gt 0) {
                    $taskRollbackFailures -join ' | '
                }
                else { 'None' }
                throw ("Inventory install failed and rollback was incomplete. OriginalError=$($failure.Exception.Message); " +
                    "FileRollbackError=$fileRollbackMessage; TaskRollbackError=$taskRollbackMessage")
            }
            throw $failure
        }
        finally {
            foreach ($path in @($stagedTarget, $rejectedTarget)) {
                if ($path -and (Test-Path -LiteralPath $path)) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if ($retiredTarget -and (Test-Path -LiteralPath $retiredTarget)) {
            Remove-Item -LiteralPath $retiredTarget -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Output "Installed Custom Inventory $packageVersion at $target; SubmissionEnabled=$($config.SubmissionEnabled)."
        if (-not $config.SubmissionEnabled) { Write-Warning 'Tasks are disabled until the original Azure table schemas and DCR mappings are ready.' }
    }
    if ($log) { Write-InventoryLog -Context $log -Event RunCompleted -Data @{ Mode = 'Install'; DurationMs = $timer.ElapsedMilliseconds } }
}
catch {
    if ($log) { Write-InventoryLogFailure -Context $log -ErrorRecord $_ -Stage $stage }
    throw
}
finally { $timer.Stop() }
