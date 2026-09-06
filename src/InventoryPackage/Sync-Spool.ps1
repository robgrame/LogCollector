#Requires -Version 5.1
# Version 1.0.0. Customer-neutral delivery: never re-runs inventory or device operations.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Inventory.Runtime.psm1') -ErrorAction Stop
$result = Invoke-InventoryDrain -ConfigPath (Join-Path $PSScriptRoot 'Config.psd1')
$result
if ($result.Stopped -or $result.Quarantined -gt 0) { exit 1 }
