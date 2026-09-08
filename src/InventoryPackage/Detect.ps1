#Requires -Version 5.1
# Version 1.5.0. Customer-neutral Intune detection: installed does not mean live ingestion is enabled.
$ErrorActionPreference = 'Stop'
$expectedConfigurationSha256 = '__LOGCOLLECTOR_CONFIGURATION_SHA256__'
if ($expectedConfigurationSha256 -notmatch '^[0-9A-F]{64}$') { exit 1 }
$target = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'LogCollector\CustomInventory\1.5.0'
$configPath = Join-Path $target 'Config.psd1'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { exit 1 }
if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $expectedConfigurationSha256) { exit 1 }
$config = Import-PowerShellDataFile -LiteralPath $configPath
if ($config.PackageVersion -ne '1.5.0') { exit 1 }
$names = @('LogCollector-CustomInventory', 'LogCollector-CustomInventory-Spool')
$tasks = @(Get-ScheduledTask -ErrorAction Stop |
    Where-Object { $_.TaskPath -eq '\LogCollector\' -and $_.TaskName -in $names })
if ($tasks.Count -ne 2) { exit 1 }
$scripts = @('Run-Inventory.ps1', 'Sync-Spool.ps1')
for ($i = 0; $i -lt $names.Count; $i++) {
    $task = @($tasks | Where-Object TaskName -eq $names[$i])
    if ($task.Count -ne 1) { exit 1 }
    $task = $task[0]
    if ($task.Settings.Enabled -ne $config.SubmissionEnabled) { exit 1 }
    if ($task.Principal.UserId -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18') -or
        $task.Principal.LogonType -ne 'ServiceAccount' -or $task.Principal.RunLevel -ne 'Highest') { exit 1 }
    $actions = @($task.Actions)
    if ($actions.Count -ne 1) { exit 1 }
    $expectedArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $target $scripts[$i])
    if ($actions[0].Execute -ne "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -or
        $actions[0].Arguments -ne $expectedArguments) { exit 1 }
}
foreach ($file in @('Run-Inventory.ps1', 'Sync-Spool.ps1', 'Inventory.Collection.psm1',
    'Inventory.Runtime.psm1', 'Inventory.Logging.psm1', 'Modules\LogCollector.Client.psd1', 'Modules\LogCollector.Client.psm1',
    'Modules\EndpointConfiguration.psm1', 'Modules\CMTraceLogging.psm1', 'Modules\DeviceIdentity.psm1', 'Modules\RequestSigning.psm1',
    'Modules\InventoryClient.psm1', 'Modules\InventorySpool.psm1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $target $file) -PathType Leaf)) { exit 1 }
}
Write-Output "Custom Inventory 1.5.0 installed; SubmissionEnabled=$($config.SubmissionEnabled)."
exit 0
