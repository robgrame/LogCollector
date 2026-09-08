BeforeAll {
    $script:FixtureModuleNames = @('Inventory.Runtime', 'Inventory.Collection', 'Inventory.Logging', 'LogCollector.Client',
        'InventoryClient', 'InventorySpool', 'DeviceIdentity', 'RequestSigning')
    # A packaged copy and a repository copy have the same module name. Isolate this
    # fixture so Pester can unambiguously mock private module functions in a combined run.
    foreach ($name in $script:FixtureModuleNames) {
        Get-Module -All -Name $name | Remove-Module -Force -ErrorAction Stop
    }
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Source = Join-Path $script:Repo 'src\InventoryPackage'
    $script:DefaultConfigText = (Get-Content (Join-Path $script:Source 'Config.psd1') -Raw).
        Replace("FrontendUrl = ''", "FrontendUrl = 'https://example.invalid/api/inventory'").
        Replace("Environment = ''", "Environment = 'TestLab'")
    $script:Fixture = Join-Path $TestDrive 'Package'
    $null = New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'Modules') -Force
    foreach ($file in @('Config.psd1', 'Inventory.Runtime.psm1', 'Inventory.Logging.psm1', 'Run-Inventory.ps1', 'Sync-Spool.ps1',
        'Uninstall.ps1', 'Detect.ps1', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $script:Source $file) -Destination (Join-Path $script:Fixture $file)
    }
    $manifest = Import-PowerShellDataFile (Join-Path $script:Repo 'src\Client\LogCollector.Client.psd1')
    foreach ($file in $manifest.FileList) {
        Copy-Item -LiteralPath (Join-Path $script:Repo "src\Client\$file") -Destination (Join-Path $script:Fixture "Modules\$file")
    }
    'function Get-Inventory { param($Identity, $CollectDeviceInventory, $CollectAppInventory, $DiagnosticSink) }; Export-ModuleMember -Function Get-Inventory' |
        Set-Content (Join-Path $script:Fixture 'Inventory.Collection.psm1')
    # A missed mock must fail rather than create real ProgramData logs on the test host.
    @'
function New-InventoryLogContext { param($Component); throw 'Logger must be mocked in lifecycle tests.' }
function Write-InventoryLog { param($Context, $Event, $Data, $Level); throw 'Logger must be mocked in lifecycle tests.' }
function Write-InventoryLogFailure { param($Context, $ErrorRecord, $Stage); throw 'Logger must be mocked in lifecycle tests.' }
function New-InventoryDiagnosticSink { param($Context); throw 'Logger must be mocked in lifecycle tests.' }
Export-ModuleMember -Function New-InventoryLogContext, Write-InventoryLog, Write-InventoryLogFailure, New-InventoryDiagnosticSink
'@ | Set-Content (Join-Path $script:Fixture 'Inventory.Logging.psm1')
    # Only the elevation directive is removed in this isolated fixture. All system mutations are mocked.
    (Get-Content (Join-Path $script:Source 'Install.ps1') -Raw).Replace('#Requires -RunAsAdministrator', '') |
        Set-Content (Join-Path $script:Fixture 'Install.ps1')
    Import-Module (Join-Path $script:Fixture 'Inventory.Runtime.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $script:Fixture 'Inventory.Logging.psm1') -Force -ErrorAction Stop
    $script:ConfigPath = Join-Path $script:Fixture 'Config.psd1'
}

Describe 'Universal inventory package runtime' {
    BeforeEach {
        $script:DefaultConfigText | Set-Content $script:ConfigPath
        Mock -ModuleName Inventory.Runtime Get-DeviceIdentitySnapshot {
            [pscustomobject]@{ EntraDeviceId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'; DeviceName = 'LabDevice'; IntuneDeviceId = $null }
        }
        Mock -ModuleName Inventory.Runtime Get-Inventory {
            [pscustomobject]@{
                DeviceRecords = @([pscustomobject]@{ ComputerName = 'LabDevice'; NetworkAdapters = @(@{ MacAddress = 'test' }) })
                AppRecords = @([pscustomobject]@{ AppName = 'Example app'; AppVersion = '1.0'; AppInstallDate = '' })
            }
        }
        Mock -ModuleName Inventory.Runtime Send-LogCollectorData {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Spooled = $false; Message = 'ok' }
        }
        Mock -ModuleName Inventory.Runtime Sync-LogCollectorSpool {
            [pscustomobject]@{ Delivered = 1; Quarantined = 0; Remaining = 0; Stopped = $false }
        }
    }

    It 'blocks live sends before identity or collection until original mappings are enabled' {
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath } | Should -Throw '*Submission is disabled*'
        Should -Invoke -ModuleName Inventory.Runtime Get-DeviceIdentitySnapshot -Times 0 -Exactly
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 0 -Exactly
    }

    It 'forwards diagnostics through collection and transport without including inventory records' {
        $script:DefaultConfigText.Replace('SubmissionEnabled = $false', 'SubmissionEnabled = $true') | Set-Content $script:ConfigPath
        $events = New-Object 'Collections.Generic.List[object]'
        $sink = { param($event, $data) $events.Add([pscustomobject]@{ Event = $event; Data = $data }) }.GetNewClosure()
        $result = @(Invoke-InventoryRun -ConfigPath $script:ConfigPath -DiagnosticSink $sink)
        $result.Count | Should -Be 2
        $events.Event | Should -Contain 'ConfigurationLoaded'
        $events.Event | Should -Contain 'CollectionCompleted'
        ($events | Where-Object Event -eq 'CollectionCompleted').Data.BatchCount | Should -Be 2
        Should -Invoke -ModuleName Inventory.Runtime Get-Inventory -Times 1 -Exactly -ParameterFilter { $null -ne $DiagnosticSink }
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 2 -Exactly -ParameterFilter { $null -ne $DiagnosticSink }
        (ConvertTo-Json -InputObject $events.ToArray() -Depth 5) | Should -Not -Match 'Example app|LabDevice|NetworkAdapters'
    }

    It 'previews counts without sending or draining' {
        $result = Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview
        $result.Disposition | Should -Be 'Preview'
        $result.DeviceRecords | Should -Be 1
        $result.AppRecords | Should -Be 1
        $result.Batches | Should -Be 2
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 0 -Exactly
        Should -Invoke -ModuleName Inventory.Runtime Sync-LogCollectorSpool -Times 0 -Exactly
    }

    It 'retains both original destinations and preserves records through QueueOnly' {
        $result = @(Invoke-InventoryRun -ConfigPath $script:ConfigPath -QueueOnly -WarningAction SilentlyContinue)
        $result.TableName | Should -Be @('DeviceInventory_CL', 'AppInventory_CL')
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'DeviceInventory_CL' -and $QueueOnly -and $SkipDrain -and $Records[0].NetworkAdapters[0].MacAddress -eq 'test'
        }
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'AppInventory_CL' -and $Records[0].AppName -eq 'Example app'
        }
    }

    It 'splits software inventories at the bounded record count' {
        Mock -ModuleName Inventory.Runtime Get-Inventory {
            [pscustomobject]@{ DeviceRecords = @(); AppRecords = @(1..1001 | ForEach-Object { @{ AppName = "App $_" } }) }
        }
        $result = @(Invoke-InventoryRun -ConfigPath $script:ConfigPath -QueueOnly -WarningAction SilentlyContinue)
        $result.Records | Should -Be @(500, 500, 1)
        ($result | Measure-Object -Property Records -Sum).Sum | Should -Be 1001
    }

    It 'splits on UTF8 bytes rather than characters' {
        Mock -ModuleName Inventory.Runtime Get-Inventory {
            $large = ([string][char]0x00e8) * 300000
            [pscustomobject]@{ DeviceRecords = @(); AppRecords = @(1..10 | ForEach-Object { @{ AppName = $large } }) }
        }
        $result = @(Invoke-InventoryRun -ConfigPath $script:ConfigPath -QueueOnly -WarningAction SilentlyContinue)
        $result.Count | Should -BeGreaterThan 1
        ($result | Measure-Object -Property Records -Sum).Sum | Should -Be 10
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 0 -Exactly -ParameterFilter { $Records.Count -gt 5 }
    }

    It 'rejects a single oversized row before sending either stream' {
        Mock -ModuleName Inventory.Runtime Get-Inventory {
            [pscustomobject]@{ DeviceRecords = @(@{ ComputerName = 'Test' }); AppRecords = @(@{ AppName = ('x' * 768001) }) }
        }
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -QueueOnly } | Should -Throw '*750 KiB*'
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 0 -Exactly
    }

    It 'never sends an empty records array' {
        Mock -ModuleName Inventory.Runtime Get-Inventory { [pscustomobject]@{ DeviceRecords = @(); AppRecords = @() } }
        @(Invoke-InventoryRun -ConfigPath $script:ConfigPath -QueueOnly -WarningAction SilentlyContinue).Count | Should -Be 0
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 0 -Exactly
    }

    It 'only drains after explicit activation, without collecting' {
        { Invoke-InventoryDrain -ConfigPath $script:ConfigPath } | Should -Throw '*disabled*'
        (Get-Content $script:ConfigPath -Raw).Replace('SubmissionEnabled = $false', 'SubmissionEnabled = $true') | Set-Content $script:ConfigPath
        $result = Invoke-InventoryDrain -ConfigPath $script:ConfigPath
        $result.Delivered | Should -Be 1
        Should -Invoke -ModuleName Inventory.Runtime Get-Inventory -Times 0 -Exactly
    }

    It 'does not treat string false as a Boolean enable switch' {
        (Get-Content $script:ConfigPath -Raw).Replace('SubmissionEnabled = $false', "SubmissionEnabled = 'false'") | Set-Content $script:ConfigPath
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath } | Should -Throw '*Boolean*'
    }

    It 'propagates provider failures rather than reporting successful empty inventory' {
        Mock -ModuleName Inventory.Runtime Get-Inventory { throw 'Core inventory unavailable' }
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview } | Should -Throw '*Core inventory unavailable*'
    }

    It 'passes bounded live transport settings after explicit activation' {
        (Get-Content $script:ConfigPath -Raw).Replace('SubmissionEnabled = $false', 'SubmissionEnabled = $true') | Set-Content $script:ConfigPath
        $result = @(Invoke-InventoryRun -ConfigPath $script:ConfigPath)
        $result.Count | Should -Be 2
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 2 -Exactly -ParameterFilter {
            -not $QueueOnly -and $SkipDrain -and $MaxAttempts -eq 3 -and $TimeoutSeconds -eq 30 -and
            $Properties.Environment -eq 'TestLab' -and $Source -eq 'WindowsCustomInventory'
        }
    }

    It 'uses configurable table names without modifying the collector' {
        $script:DefaultConfigText.Replace('DeviceInventory_CL', 'HardwareLab_CL').Replace('AppInventory_CL', 'SoftwareLab_CL') |
            Set-Content $script:ConfigPath
        $result = @(Invoke-InventoryRun -ConfigPath $script:ConfigPath -QueueOnly -WarningAction SilentlyContinue)
        $result.TableName | Should -Be @('HardwareLab_CL', 'SoftwareLab_CL')
    }

    It 'rejects unconfigured endpoints and invalid destinations before collection' {
        $script:DefaultConfigText.Replace('https://example.invalid/api/inventory', '') | Set-Content $script:ConfigPath
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview } | Should -Throw '*Configure FrontendUrl*'
        $script:DefaultConfigText.Replace('DeviceInventory_CL', 'bad/table') | Set-Content $script:ConfigPath
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview } | Should -Throw '*custom table name*'
        Should -Invoke -ModuleName Inventory.Runtime Get-Inventory -Times 0 -Exactly
    }

    It 'forwards the same root and intermediate policy to submission and spool drain' {
        $text = $script:DefaultConfigText.Replace('SubmissionEnabled = $false', 'SubmissionEnabled = $true').
            Replace('PkiRootCaThumbprints = @()', "PkiRootCaThumbprints = @('$('A' * 40)')").
            Replace('PkiRootCaSubjects = @()', "PkiRootCaSubjects = @('CN=Root, O=Example')").
            Replace('PkiIntermediateCaThumbprints = @()', "PkiIntermediateCaThumbprints = @('$('B' * 40)')").
            Replace('PkiIntermediateCaSubjects = @()', "PkiIntermediateCaSubjects = @('CN=Issuing, O=Example')")
        $text | Set-Content $script:ConfigPath
        $null = Invoke-InventoryRun -ConfigPath $script:ConfigPath
        $null = Invoke-InventoryDrain -ConfigPath $script:ConfigPath
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 2 -Exactly -ParameterFilter {
            $PkiRootCaThumbprints[0] -eq ('A' * 40) -and $PkiRootCaSubjects[0] -eq 'CN=Root, O=Example' -and
            $PkiIntermediateCaThumbprints[0] -eq ('B' * 40) -and $PkiIntermediateCaSubjects[0] -eq 'CN=Issuing, O=Example'
        }
        Should -Invoke -ModuleName Inventory.Runtime Sync-LogCollectorSpool -Times 1 -Exactly -ParameterFilter {
            $PkiRootCaThumbprints[0] -eq ('A' * 40) -and $PkiIntermediateCaSubjects[0] -eq 'CN=Issuing, O=Example'
        }
    }

    It 'rejects malformed policy data before identity or collection' -TestCases @(
        @{ Value = "'not-a-thumbprint'" }
        @{ Value = "'   '" }
        @{ Value = '$null' }
    ) {
        param($Value)
        $script:DefaultConfigText.Replace('PkiRootCaThumbprints = @()', "PkiRootCaThumbprints = @($Value)") |
            Set-Content $script:ConfigPath
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview } | Should -Throw '*PkiRootCaThumbprints*'
        Should -Invoke -ModuleName Inventory.Runtime Get-DeviceIdentitySnapshot -Times 0 -Exactly
    }
}

Describe 'inventory package installer' {
    BeforeEach {
        $script:DefaultConfigText | Set-Content $script:ConfigPath
        $global:InventoryPackageTestTasks = @{}
        Mock Get-ScheduledTask {
            param($TaskName)
            if ($TaskName) { return $global:InventoryPackageTestTasks[$TaskName] }
        }
        Mock Register-ScheduledTask {
            param($TaskName, $TaskPath, $InputObject)
            $global:InventoryPackageTestTasks[$TaskName] = $InputObject
        }
        Mock Disable-ScheduledTask {}
        Mock Copy-Item {}
        Mock -ModuleName InventorySpool Assert-SpoolHierarchy { $true }
        Mock New-InventoryLogContext { [pscustomobject]@{ RunId = 'test-run' } }
        Mock Write-InventoryLog {}
        Mock Write-InventoryLogFailure {}
    }

    It 'registers disabled SYSTEM tasks with two-hour spread and hourly independent drain' {
        & (Join-Path $script:Fixture 'Install.ps1') -WarningAction SilentlyContinue
        $global:InventoryPackageTestTasks.Count | Should -Be 2
        $inventory = $global:InventoryPackageTestTasks['LogCollector-CustomInventory']
        $inventory.Settings.Enabled | Should -BeFalse
        $inventory.Principal.UserId | Should -BeIn @('SYSTEM', 'S-1-5-18')
        $inventory.Triggers[0].RandomDelay | Should -Be 'PT2H'
        $inventory.Triggers[0].DaysOfWeek | Should -Be 72
        $global:InventoryPackageTestTasks['LogCollector-CustomInventory-Spool'].Triggers[0].Repetition.Interval | Should -Be 'PT1H'
        $global:InventoryPackageTestTasks['LogCollector-CustomInventory-Spool'].Actions[0].Arguments | Should -Match 'Sync-Spool.ps1'
        Should -Invoke Copy-Item -Times 18 -Exactly
        Should -Invoke Write-InventoryLog -Times 2 -Exactly -ParameterFilter { $Event -eq 'TasksRegistered' -and -not $Data.Enabled }
    }

    AfterAll {
        Remove-Variable -Name InventoryPackageTestTasks -Scope Global -ErrorAction SilentlyContinue
        foreach ($name in $script:FixtureModuleNames) {
            Get-Module -All -Name $name | Remove-Module -Force -ErrorAction Stop
        }
    }

    It 'supports WhatIf without mutating tasks or installed files' {
        & (Join-Path $script:Fixture 'Install.ps1') -WhatIf
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke Copy-Item -Times 0 -Exactly
        Should -Invoke New-InventoryLogContext -Times 0 -Exactly
    }

    It 'rejects an old configuration version before installation' {
        $script:DefaultConfigText.Replace("PackageVersion = '1.5.0'", "PackageVersion = '1.0.0'") |
            Set-Content $script:ConfigPath
        { & (Join-Path $script:Fixture 'Install.ps1') } | Should -Throw '*must match package version*'
        Should -Invoke Write-InventoryLogFailure -Times 1 -Exactly -ParameterFilter { $Stage -eq 'LoadConfiguration' }
        Should -Invoke Copy-Item -Times 0 -Exactly
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'enables both tasks only when explicitly configured' {
        (Get-Content $script:ConfigPath -Raw).Replace('SubmissionEnabled = $false', 'SubmissionEnabled = $true') | Set-Content $script:ConfigPath
        & (Join-Path $script:Fixture 'Install.ps1')
        $global:InventoryPackageTestTasks['LogCollector-CustomInventory'].Settings.Enabled | Should -BeTrue
        $global:InventoryPackageTestTasks['LogCollector-CustomInventory-Spool'].Settings.Enabled | Should -BeTrue
    }

    It 'does not register tasks if package copying fails' {
        Mock Copy-Item { throw 'Disk write failed' }
        { & (Join-Path $script:Fixture 'Install.ps1') } | Should -Throw '*Disk write failed*'
        Should -Invoke Write-InventoryLogFailure -Times 1 -Exactly -ParameterFilter { $Stage -eq 'CopyFiles' }
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'rejects update while a package task is running' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskName = 'LogCollector-CustomInventory'; TaskPath = '\LogCollector\'; State = 'Running' }
        }
        { & (Join-Path $script:Fixture 'Install.ps1') } | Should -Throw '*running*'
        Should -Invoke Copy-Item -Times 0 -Exactly
    }

    It 'uses only supported ScheduledTasks cmdlet parameters' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Source 'Install.ps1'), [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        foreach ($command in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if ($name -notlike '*ScheduledTask*') { continue }
            $metadata = Get-Command $name -ErrorAction Stop
            foreach ($parameter in @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
                $metadata.Parameters.Keys | Should -Contain $parameter.ParameterName
            }
        }
    }
}

Describe 'inventory distribution builder' {
    It 'creates exactly the complete portable file set and refuses overwrites' {
        $builder = Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1'
        $output = Join-Path $TestDrive 'Distribution'
        $result = & $builder -OutputRoot $output -FrontendUrl 'https://example.invalid/api/inventory'
        $result.FileCount | Should -Be 18
        $result.PackageVersion | Should -BeExactly '1.5.0'
        $result.SubmissionEnabled | Should -BeFalse
        $result.ConfigurationSha256 | Should -BeExactly (Get-FileHash (Join-Path $result.PackagePath 'Config.psd1')).Hash
        (Get-Content (Join-Path $result.PackagePath 'Detect.ps1') -Raw) | Should -Match $result.ConfigurationSha256
        Test-Path (Join-Path $result.PackagePath 'Modules\LogCollector.Client.psd1') | Should -BeTrue
        { & $builder -OutputRoot $output -FrontendUrl 'https://example.invalid/api/inventory' } | Should -Throw '*already exists*'
        $copied = Import-PowerShellDataFile (Join-Path $result.PackagePath 'Config.psd1')
        $copied.DeviceTableName | Should -BeExactly 'DeviceInventory_CL'
        $copied.AppTableName | Should -BeExactly 'AppInventory_CL'
        $copied.FrontendUrl | Should -BeExactly 'https://example.invalid/api/inventory'
        @($copied.PkiRootCaThumbprints).Count | Should -Be 0
        (Import-PowerShellDataFile (Join-Path $result.PackagePath 'Modules\LogCollector.Client.psd1')).ModuleVersion |
            Should -BeExactly '1.7.0'
    }

    It 'escapes deployment configuration as data and supports alternative tables' {
        $builder = Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1'
        $label = "Lab'; throw 'must remain data"
        $result = & $builder -OutputRoot (Join-Path $TestDrive 'OtherDeployment') `
            -FrontendUrl 'https://another.invalid/api/inventory' -Environment $label `
            -DeviceTableName 'HardwareLab_CL' -AppTableName 'SoftwareLab_CL'
        $copied = Import-PowerShellDataFile (Join-Path $result.PackagePath 'Config.psd1')
        $copied.Environment | Should -BeExactly $label
        $copied.DeviceTableName | Should -BeExactly 'HardwareLab_CL'
        $copied.AppTableName | Should -BeExactly 'SoftwareLab_CL'
    }

    It 'preserves CA arrays and quotes as literal data in the generated configuration' {
        $builder = Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1'
        $subject = "CN=Root, O=Example's PKI"
        $result = & $builder -OutputRoot (Join-Path $TestDrive 'PkiDeployment') `
            -FrontendUrl 'https://example.invalid/api/inventory' -PkiRootCaThumbprints ('a' * 40) `
            -PkiRootCaSubjects $subject -PkiIntermediateCaSubjects @('CN=Issuing A', 'CN=Issuing B')
        $copied = Import-PowerShellDataFile (Join-Path $result.PackagePath 'Config.psd1')
        $copied.PkiRootCaThumbprints | Should -Be @('a' * 40)
        $copied.PkiRootCaSubjects | Should -Be @($subject)
        $copied.PkiIntermediateCaSubjects | Should -Be @('CN=Issuing A', 'CN=Issuing B')
    }

    It 'rejects malformed CA pins before creating package output' {
        $output = Join-Path $TestDrive 'InvalidPki'
        { & (Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1') -OutputRoot $output `
            -FrontendUrl 'https://example.invalid/api/inventory' -PkiRootCaThumbprints 'bad-pin' } | Should -Throw '*40 hexadecimal*'
        Test-Path $output | Should -BeFalse
    }
}
