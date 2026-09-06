#Requires -Version 5.1
# Version 1.2.3. Customer-neutral Intune detection: installed does not mean live ingestion is enabled.
$ErrorActionPreference = 'Stop'
$target = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'LogCollector\CustomInventory\1.2.3'
if (-not (Test-Path -LiteralPath (Join-Path $target 'Config.psd1'))) { exit 1 }
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $target 'Config.psd1')
if ($config.PackageVersion -ne '1.2.3') { exit 1 }
$names = @('LogCollector-CustomInventory', 'LogCollector-CustomInventory-Spool')
$tasks = @(Get-ScheduledTask -ErrorAction Stop |
    Where-Object { $_.TaskPath -eq '\LogCollector\' -and $_.TaskName -in $names })
if ($tasks.Count -ne 2) { exit 1 }
foreach ($file in @('Run-Inventory.ps1', 'Sync-Spool.ps1', 'Inventory.Collection.psm1',
    'Inventory.Runtime.psm1', 'Modules\LogCollector.Client.psd1', 'Modules\LogCollector.Client.psm1',
    'Modules\DeviceIdentity.psm1', 'Modules\RequestSigning.psm1', 'Modules\InventoryClient.psm1', 'Modules\InventorySpool.psm1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $target $file) -PathType Leaf)) { exit 1 }
}
Write-Output "Custom Inventory 1.2.3 installed; SubmissionEnabled=$($config.SubmissionEnabled)."
exit 0
