BeforeAll {
    foreach ($name in @('Inventory.Runtime', 'Inventory.Collection', 'Inventory.Logging', 'LogCollector.Client',
        'InventoryClient', 'InventorySpool', 'DeviceIdentity', 'RequestSigning')) {
        Get-Module -All -Name $name | Remove-Module -Force -ErrorAction Stop
    }
    $repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Fixture = Join-Path $TestDrive 'EntryPoints'
    $null = New-Item -ItemType Directory -Path $script:Fixture
    foreach ($name in @('Run-Inventory.ps1', 'Sync-Spool.ps1', 'Uninstall.ps1')) {
        (Get-Content (Join-Path $repo "src\InventoryPackage\$name") -Raw).Replace('#Requires -RunAsAdministrator', '') |
            Set-Content (Join-Path $script:Fixture $name)
    }
    @'
function New-InventoryLogContext { param($Component); throw 'Must mock logger' }
function Write-InventoryLog { param($Context, $Event, $Data, $Level); throw 'Must mock logger' }
function Write-InventoryLogFailure { param($Context, $ErrorRecord, $Stage); throw 'Must mock logger' }
function New-InventoryDiagnosticSink { param($Context); throw 'Must mock logger' }
Export-ModuleMember -Function *
'@ | Set-Content (Join-Path $script:Fixture 'Inventory.Logging.psm1')
    @'
function Invoke-InventoryRun { param($ConfigPath, [switch]$Preview, [switch]$QueueOnly, $DiagnosticSink); throw 'Must mock collection' }
function Invoke-InventoryDrain { param($ConfigPath, $DiagnosticSink); throw 'Must mock delivery' }
Export-ModuleMember -Function *
'@ | Set-Content (Join-Path $script:Fixture 'Inventory.Runtime.psm1')
    Import-Module (Join-Path $script:Fixture 'Inventory.Logging.psm1') -Force
    Import-Module (Join-Path $script:Fixture 'Inventory.Runtime.psm1') -Force
}

AfterAll {
    Get-Module -All -Name Inventory.Runtime, Inventory.Logging | Remove-Module -Force
}

Describe 'Logged inventory entry points' {
    BeforeEach {
        Mock Import-Module {}
        Mock New-InventoryLogContext { [pscustomobject]@{ RunId = 'fixture' } }
        Mock Write-InventoryLog {}
        Mock Write-InventoryLogFailure {}
        Mock New-InventoryDiagnosticSink { { param($Event, $Data) } }
        Mock Invoke-InventoryRun { [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202 } }
        Mock Invoke-InventoryDrain { [pscustomobject]@{ Delivered = 1; Quarantined = 0; Remaining = 0; Stopped = $false } }
        Mock Get-ScheduledTask { @() }
        Mock Unregister-ScheduledTask {}
    }

    It 'initializes logging and propagates preview and queue flags without changing output' {
        $result = & (Join-Path $script:Fixture 'Run-Inventory.ps1') -Preview
        $result.Disposition | Should -Be 'Delivered'
        Should -Invoke New-InventoryLogContext -Times 1 -Exactly -ParameterFilter { $Component -eq 'Inventory' }
        Should -Invoke Invoke-InventoryRun -Times 1 -Exactly -ParameterFilter { $Preview -and -not $QueueOnly -and $DiagnosticSink }
        Should -Invoke Write-InventoryLog -Times 1 -Exactly -ParameterFilter { $Event -eq 'RunStarted' -and $Data.Mode -eq 'Preview' }
        Should -Invoke Write-InventoryLog -Times 1 -Exactly -ParameterFilter { $Event -eq 'RunCompleted' -and -not $Data.Stopped }
    }

    It 'keeps failure exit codes for non-delivered inventory' {
        Mock Invoke-InventoryRun { [pscustomobject]@{ Disposition = 'AuthFailure'; StatusCode = 401; Message = 'PRIVATE-SENTINEL' } }
        $null = & (Join-Path $script:Fixture 'Run-Inventory.ps1')
        $LASTEXITCODE | Should -Be 1
        Should -Invoke Write-InventoryLog -Times 1 -Exactly -ParameterFilter { $Event -eq 'RunCompleted' -and $Data.Stopped }
        Should -Invoke Write-InventoryLog -Times 0 -Exactly -ParameterFilter { (ConvertTo-Json $Data) -match 'PRIVATE-SENTINEL' }
    }

    It 'logs early runtime import failure and preserves the original error' {
        Mock Import-Module { throw 'Runtime missing' } -ParameterFilter { $Name -like '*Inventory.Runtime.psm1' }
        { & (Join-Path $script:Fixture 'Run-Inventory.ps1') } | Should -Throw '*Runtime missing*'
        Should -Invoke Write-InventoryLogFailure -Times 1 -Exactly -ParameterFilter { $Stage -eq 'ImportRuntime' }
        Should -Invoke Invoke-InventoryRun -Times 0 -Exactly
    }

    It 'does not collect if the logger cannot initialize' {
        Mock New-InventoryLogContext { throw 'Log directory denied' }
        { & (Join-Path $script:Fixture 'Run-Inventory.ps1') } | Should -Throw '*Log directory denied*'
        Should -Invoke Invoke-InventoryRun -Times 0 -Exactly
        Should -Invoke Write-InventoryLogFailure -Times 0 -Exactly
    }

    It 'logs fatal collection failure and preserves the error' {
        Mock Invoke-InventoryRun { throw 'Collection failed' }
        { & (Join-Path $script:Fixture 'Run-Inventory.ps1') } | Should -Throw '*Collection failed*'
        Should -Invoke Write-InventoryLogFailure -Times 1 -Exactly -ParameterFilter { $Stage -eq 'CollectAndSend' }
    }

    It 'logs drain summaries and preserves stopped exit codes' {
        Mock Invoke-InventoryDrain { [pscustomobject]@{ Delivered = 0; Quarantined = 0; Remaining = 3; Stopped = $true } }
        $result = & (Join-Path $script:Fixture 'Sync-Spool.ps1')
        $LASTEXITCODE | Should -Be 1
        $result.Remaining | Should -Be 3
        Should -Invoke New-InventoryLogContext -Times 1 -Exactly -ParameterFilter { $Component -eq 'Spool' }
        Should -Invoke Write-InventoryLog -Times 1 -Exactly -ParameterFilter { $Event -eq 'RunCompleted' -and $Data.Remaining -eq 3 -and $Data.Stopped }
        Should -Invoke Invoke-InventoryRun -Times 0 -Exactly
    }

    It 'logs uninstall task removal in the installation log' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskPath = '\LogCollector\'; TaskName = 'LogCollector-CustomInventory'; State = 'Ready' } }
        $null = & (Join-Path $script:Fixture 'Uninstall.ps1')
        Should -Invoke New-InventoryLogContext -Times 1 -Exactly -ParameterFilter { $Component -eq 'Install' }
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        Should -Invoke Write-InventoryLog -Times 1 -Exactly -ParameterFilter { $Event -eq 'TasksRemoved' -and $Data.TaskName -eq 'LogCollector-CustomInventory' }
    }

    It 'does not create logs or remove tasks during uninstall WhatIf' {
        $null = & (Join-Path $script:Fixture 'Uninstall.ps1') -WhatIf
        Should -Invoke New-InventoryLogContext -Times 0 -Exactly
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }
}
