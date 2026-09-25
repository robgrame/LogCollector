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
    $script:OriginalModulePath = $env:PSModulePath
    $moduleRoot = Join-Path $TestDrive 'PowerShellModules\LogCollector.Client'
    $null = New-Item -ItemType Directory -Path $moduleRoot -Force
    $manifest = Import-PowerShellDataFile (Join-Path $script:Repo 'src\Client\LogCollector.Client.psd1')
    foreach ($file in $manifest.FileList) {
        Copy-Item -LiteralPath (Join-Path $script:Repo "src\Client\$file") -Destination (Join-Path $moduleRoot $file)
    }
    $env:PSModulePath = (Split-Path $moduleRoot -Parent) +
        [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module LogCollector.Client -RequiredVersion 1.11.0 -Force -ErrorAction Stop
    $script:DefaultConfigText = Get-Content (Join-Path $script:Source 'Config.psd1') -Raw
    $script:Fixture = Join-Path $TestDrive 'Package'
    $null = New-Item -ItemType Directory -Path $script:Fixture -Force
    foreach ($file in @('Version', 'Config.psd1', 'Inventory.Runtime.psm1', 'Inventory.Logging.psm1', 'Run-Inventory.ps1', 'Sync-Spool.ps1',
        'Uninstall.ps1', 'Detect.ps1', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $script:Source $file) -Destination (Join-Path $script:Fixture $file)
    }
    $coreManifestAssignment = '$coreManifest = Join-Path ([Environment]::GetFolderPath(''ProgramFiles'')) ''WindowsPowerShell\Modules\LogCollector.Client\LogCollector.Client.psd1'''
    $fixtureManifestAssignment = '$coreManifest = ''' + (Join-Path $moduleRoot 'LogCollector.Client.psd1').Replace("'", "''") + ''''
    foreach ($file in @('Inventory.Runtime.psm1', 'Run-Inventory.ps1', 'Sync-Spool.ps1', 'Uninstall.ps1', 'Detect.ps1')) {
        $path = Join-Path $script:Fixture $file
        (Get-Content -LiteralPath $path -Raw).Replace($coreManifestAssignment, $fixtureManifestAssignment) |
            Set-Content -LiteralPath $path
    }
    'function Get-Inventory { param($Identity, $CollectDeviceInventory, $CollectAppInventory, $DiagnosticSink) }; Export-ModuleMember -Function Get-Inventory' |
        Set-Content (Join-Path $script:Fixture 'Inventory.Collection.psm1')
    # A missed mock must fail rather than create real ProgramData logs on the test host.
    @'
function New-InventoryLogContext { param($Component); throw 'Logger must be mocked in lifecycle tests.' }
function Get-InventoryLogCustomerName { param($ConfigPath); throw 'Logger configuration must be mocked in lifecycle tests.' }
function Initialize-InventoryLogContext { param($Component, $PackageVersion, $CustomerName); throw 'Logger bootstrap must be mocked in lifecycle tests.' }
function Write-InventoryLog { param($Context, $Event, $Data, $Level); throw 'Logger must be mocked in lifecycle tests.' }
function Write-InventoryLogFailure { param($Context, $ErrorRecord, $Stage); throw 'Logger must be mocked in lifecycle tests.' }
function New-InventoryDiagnosticSink { param($Context); throw 'Logger must be mocked in lifecycle tests.' }
Export-ModuleMember -Function Get-InventoryLogCustomerName, Initialize-InventoryLogContext, New-InventoryLogContext, Write-InventoryLog, `
    Write-InventoryLogFailure, New-InventoryDiagnosticSink
'@ | Set-Content (Join-Path $script:Fixture 'Inventory.Logging.psm1')
    # Only the elevation directive is removed in this isolated fixture. All system mutations are mocked.
    $script:Installed = Join-Path $TestDrive 'Installed'
    (Get-Content (Join-Path $script:Source 'Install.ps1') -Raw).
        Replace('#Requires -RunAsAdministrator', '').
        Replace($coreManifestAssignment, $fixtureManifestAssignment).
        Replace(
            '$target = Join-Path (Join-Path ([Environment]::GetFolderPath(''ProgramFiles'')) $config.CustomerName) ''CustomInventory''',
            ('$target = ''' + $script:Installed.Replace("'", "''") + '''')) |
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
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'
                Environment = 'TestLab'
                CustomerName = 'LogCollector'
                SubmissionEnabled = $false
                CertificateThumbprint = ''
                CertificateSubjectLike = ''
                CertificateIssuerLike = ''
                PkiRootCaThumbprints = @()
                PkiRootCaSubjects = @()
                PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @()
                DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
    }

    It 'blocks live sends before identity or collection until original mappings are enabled' {
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath } | Should -Throw '*Submission is disabled*'
        Should -Invoke -ModuleName Inventory.Runtime Get-DeviceIdentitySnapshot -Times 0 -Exactly
        Should -Invoke -ModuleName Inventory.Runtime Send-LogCollectorData -Times 0 -Exactly
    }

    It 'forwards diagnostics through collection and transport without including inventory records' {
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $true; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
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
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $true; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
        $result = Invoke-InventoryDrain -ConfigPath $script:ConfigPath
        $result.Delivered | Should -Be 1
        Should -Invoke -ModuleName Inventory.Runtime Get-Inventory -Times 0 -Exactly
    }

    It 'does not treat a Core string false as a Boolean enable switch' {
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = 'false'; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath } | Should -Throw '*Boolean*'
    }

    It 'propagates provider failures rather than reporting successful empty inventory' {
        Mock -ModuleName Inventory.Runtime Get-Inventory { throw 'Core inventory unavailable' }
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview } | Should -Throw '*Core inventory unavailable*'
    }

    It 'passes bounded live transport settings after explicit activation' {
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $true; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
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

    It 'requires the protected Core configuration and rejects invalid destinations before collection' {
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration { throw 'Core configuration missing' }
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview } | Should -Throw '*Core configuration missing*'
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = ''; CustomerName = 'LogCollector'
                SubmissionEnabled = $true; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
        $script:DefaultConfigText.Replace('DeviceInventory_CL', 'bad/table') | Set-Content $script:ConfigPath
        { Invoke-InventoryRun -ConfigPath $script:ConfigPath -Preview } | Should -Throw '*custom table name*'
        Should -Invoke -ModuleName Inventory.Runtime Get-Inventory -Times 0 -Exactly
    }

    It 'forwards the same Core root and intermediate policy to submission and spool drain' {
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $true; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @('A' * 40); PkiRootCaSubjects = @('CN=Root, O=Example')
                PkiIntermediateCaThumbprints = @('B' * 40); PkiIntermediateCaSubjects = @('CN=Issuing, O=Example')
                DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
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
        Mock Assert-LogCollectorApplicationFiles {
            param($Directory, $FileName, $CreateDirectory, $AllowMissing)
            if ($CreateDirectory) { $null = New-Item -ItemType Directory -Path $Directory -Force }
        }
        Mock New-InventoryLogContext { [pscustomobject]@{ RunId = 'test-run' } }
        Mock Get-InventoryLogCustomerName { 'LogCollector' }
        Mock Initialize-InventoryLogContext {
            [pscustomobject]@{ RunId = 'test-run'; FallbackUsed = $false }
        }
        Mock Write-InventoryLog {}
        Mock Write-InventoryLogFailure {}
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $false; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $false; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
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
        Should -Invoke Copy-Item -Times 11 -Exactly
        Should -Invoke Write-InventoryLog -Times 2 -Exactly -ParameterFilter { $Event -eq 'TasksRegistered' -and -not $Data.Enabled }
        Should -Invoke Initialize-InventoryLogContext -Times 1 -Exactly -ParameterFilter {
            $CustomerName -eq 'LogCollector'
        }
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
        Should -Invoke Initialize-InventoryLogContext -Times 0 -Exactly
    }

    It 'rejects an old configuration version before installation' {
        $script:DefaultConfigText.Replace("PackageVersion = '1.9.0'", "PackageVersion = '1.0.0'") |
            Set-Content $script:ConfigPath
        { & (Join-Path $script:Fixture 'Install.ps1') } | Should -Throw '*must match package version*'
        Should -Invoke Write-InventoryLogFailure -Times 1 -Exactly -ParameterFilter { $Stage -eq 'LoadConfiguration' }
        Should -Invoke Copy-Item -Times 0 -Exactly
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'enables both tasks only when explicitly configured' {
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $true; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
        Mock -ModuleName Inventory.Runtime Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://example.invalid/api/inventory'; Environment = 'TestLab'; CustomerName = 'LogCollector'
                SubmissionEnabled = $true; CertificateThumbprint = ''; CertificateSubjectLike = ''; CertificateIssuerLike = ''
                PkiRootCaThumbprints = @(); PkiRootCaSubjects = @(); PkiIntermediateCaThumbprints = @()
                PkiIntermediateCaSubjects = @(); DataRoot = Join-Path $TestDrive 'ProgramData\LogCollector'
            }
        }
        & (Join-Path $script:Fixture 'Install.ps1')
        $global:InventoryPackageTestTasks['LogCollector-CustomInventory'].Settings.Enabled | Should -BeTrue
        $global:InventoryPackageTestTasks['LogCollector-CustomInventory-Spool'].Settings.Enabled | Should -BeTrue
    }

    It 'continues installation when lifecycle logging is unavailable' {
        Mock Initialize-InventoryLogContext { $null }
        & (Join-Path $script:Fixture 'Install.ps1') -WarningAction SilentlyContinue
        $global:InventoryPackageTestTasks.Count | Should -Be 2
        Should -Invoke Initialize-InventoryLogContext -Times 1 -Exactly
        Should -Invoke Write-InventoryLog -Times 0 -Exactly
        Should -Invoke Write-InventoryLogFailure -Times 0 -Exactly
    }

    It 'records fallback metadata without changing the install mode' {
        Mock Initialize-InventoryLogContext {
            [pscustomobject]@{
                RunId = 'fallback-run'; FallbackUsed = $true
                PrimaryExceptionType = 'System.UnauthorizedAccessException'; PrimaryHResult = -2147024891
            }
        }
        & (Join-Path $script:Fixture 'Install.ps1') -WarningAction SilentlyContinue
        Should -Invoke Write-InventoryLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'RunStarted' -and $Data.Mode -eq 'Install' -and
            $Data.Stage -eq 'FallbackLog' -and
            $Data.ExceptionType -eq 'System.UnauthorizedAccessException' -and
            $Data.HResult -eq -2147024891
        }
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
    It 'keeps the minimum Core dependency consistent across every entry point' {
        $minimum = '1.11.0'
        foreach ($file in @('Install.ps1', 'Detect.ps1', 'Inventory.Runtime.psm1',
                'Run-Inventory.ps1', 'Sync-Spool.ps1', 'Uninstall.ps1')) {
            Get-Content -LiteralPath (Join-Path $script:Source $file) -Raw |
                Should -Match ("-MinimumVersion\s+{0}\b" -f [regex]::Escape($minimum))
        }
        Get-Content -LiteralPath (Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1') -Raw |
            Should -Match ("MinimumCoreVersion\s*=\s*'{0}'" -f [regex]::Escape($minimum))
    }

    It 'creates the Core-dependent portable file set and refuses overwrites' {
        $builder = Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1'
        $output = Join-Path $TestDrive 'Distribution'
        $result = & $builder -OutputRoot $output
        $result.FileCount | Should -Be 11
        $result.PackageVersion | Should -BeExactly '1.9.0'
        $result.MinimumCoreVersion | Should -BeExactly '1.11.0'
        (Get-Content (Join-Path $result.PackagePath 'Version') -Raw).Trim() | Should -BeExactly '1.9.0'
        $result.ConfigurationSha256 | Should -BeExactly (Get-FileHash (Join-Path $result.PackagePath 'Config.psd1')).Hash
        (Get-Content (Join-Path $result.PackagePath 'Detect.ps1') -Raw) | Should -Match $result.ConfigurationSha256
        Test-Path (Join-Path $result.PackagePath 'Modules') | Should -BeFalse
        { & $builder -OutputRoot $output } | Should -Throw '*already exists*'
        $copied = Import-PowerShellDataFile (Join-Path $result.PackagePath 'Config.psd1')
        $copied.DeviceTableName | Should -BeExactly 'DeviceInventory_CL'
        $copied.AppTableName | Should -BeExactly 'AppInventory_CL'
        $copied.ContainsKey('FrontendUrl') | Should -BeFalse
        $copied.ContainsKey('CustomerName') | Should -BeFalse
        $copied.ContainsKey('PkiRootCaThumbprints') | Should -BeFalse
    }

    It 'supports alternative collector-specific settings' {
        $builder = Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1'
        $result = & $builder -OutputRoot (Join-Path $TestDrive 'OtherDeployment') `
            -DeviceTableName 'HardwareLab_CL' -AppTableName 'SoftwareLab_CL' `
            -CollectAppInventory:$false -MaxAttempts 5 -TimeoutSeconds 45
        $copied = Import-PowerShellDataFile (Join-Path $result.PackagePath 'Config.psd1')
        $copied.DeviceTableName | Should -BeExactly 'HardwareLab_CL'
        $copied.AppTableName | Should -BeExactly 'SoftwareLab_CL'
        $copied.CollectAppInventory | Should -BeFalse
        $copied.MaxAttempts | Should -Be 5
        $copied.TimeoutSeconds | Should -Be 45
        $detection = Get-Content (Join-Path $result.PackagePath 'Detect.ps1') -Raw
        $detection | Should -Not -Match '__LOGCOLLECTOR_CONFIGURATION_SHA256__'
    }
}

AfterAll {
    foreach ($name in $script:FixtureModuleNames) {
        Get-Module -All -Name $name | Remove-Module -Force -ErrorAction SilentlyContinue
    }
    $env:PSModulePath = $script:OriginalModulePath
}
