BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1') -Force -ErrorAction Stop
    $script:Endpoint = 'https://example.invalid/api/inventory'

    function New-TestConfiguration {
        param([string] $Path, [string] $Body)
        $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
        Set-Content -LiteralPath $Path -Value $Body -Encoding UTF8
        return $Path
    }
}

Describe 'Resolve-LogCollectorTableName' {
    It 'appends _CL to a legacy Log-Type, as the Data Collector API did server-side' {
        InModuleScope LogCollector.Client { Resolve-LogCollectorTableName -LogType 'DeviceInventory' } |
            Should -Be 'DeviceInventory_CL'
    }

    It 'leaves an already-qualified table name alone' {
        InModuleScope LogCollector.Client { Resolve-LogCollectorTableName -LogType 'AppInventory_CL' } |
            Should -Be 'AppInventory_CL'
    }

    It 'trims surrounding whitespace rather than producing an invalid name' {
        InModuleScope LogCollector.Client { Resolve-LogCollectorTableName -LogType '  W11Upgrade  ' } |
            Should -Be 'W11Upgrade_CL'
    }

    It 'rejects a name that cannot be a custom table' {
        { InModuleScope LogCollector.Client { Resolve-LogCollectorTableName -LogType '9bad name' } } |
            Should -Throw '*does not map to a valid custom table name*'
    }
}

Describe 'ConvertTo-LogCollectorRecords' {
    It 'accepts the UTF-8 bytes of a JSON document, the shape Invoke-CustomInventory.ps1 passes' {
        $records = InModuleScope LogCollector.Client {
            $json = @([pscustomobject]@{ A = 1 }, [pscustomobject]@{ A = 2 }) | ConvertTo-Json
            @(ConvertTo-LogCollectorRecords -Body ([Text.Encoding]::UTF8.GetBytes($json)))
        }
        $records.Count | Should -Be 2
        $records[0].A | Should -Be 1
    }

    It 'accepts a JSON string, the shape PS-CopyW11FromWRK.ps1 passes' {
        $records = InModuleScope LogCollector.Client {
            @(ConvertTo-LogCollectorRecords -Body (@([pscustomobject]@{ Message = 'hi' }) | ConvertTo-Json))
        }
        $records.Count | Should -Be 1
        $records[0].Message | Should -Be 'hi'
    }

    It 'accepts objects directly, so new scripts need not serialise first' {
        $records = InModuleScope LogCollector.Client {
            @(ConvertTo-LogCollectorRecords -Body ([pscustomobject]@{ A = 1 }))
        }
        $records.Count | Should -Be 1
    }

    It 'keeps a single record as an array rather than unrolling it to a scalar' {
        InModuleScope LogCollector.Client {
            $records = @(ConvertTo-LogCollectorRecords -Body ([pscustomobject]@{ A = 1 }))
            $records[0] -is [array] | Should -BeFalse
        }
    }

    It 'rejects a body that is not JSON instead of sending it verbatim' {
        { InModuleScope LogCollector.Client { ConvertTo-LogCollectorRecords -Body 'not json {' } } |
            Should -Throw '*not valid JSON*'
    }

    It 'rejects an empty body' {
        { InModuleScope LogCollector.Client { ConvertTo-LogCollectorRecords -Body '   ' } } |
            Should -Throw '*is empty*'
    }
}

Describe 'Send-LogAnalyticsData' {
    BeforeEach {
        Mock -ModuleName LogCollector.Client Send-LogCollectorData {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
        }
    }

    It 'binds the legacy call site from Invoke-CustomInventory.ps1 unchanged' {
        $json = @([pscustomobject]@{ A = 1 }) | ConvertTo-Json
        $response = Send-LogAnalyticsData -customerId 'ws-id' -sharedKey 'key' `
            -body ([Text.Encoding]::UTF8.GetBytes($json)) -logType 'DeviceInventory' `
            -FrontendUrl $script:Endpoint -WarningAction SilentlyContinue
        $response.TableName | Should -Be 'DeviceInventory_CL'
        $response.RecordCount | Should -Be 1
    }

    It 'preserves the legacy -match "200 :" success contract on delivery' {
        $response = Send-LogAnalyticsData -LogType 'W11Upgrade' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl $script:Endpoint
        ($response -match '200 :') | Should -BeTrue
        $response.ToString() | Should -BeLike '200 : Upload payload size is * Kb (Delivered)'
    }

    It 'binds the legacy SecureBoot call site, which named the same values WorkspaceId/WorkspaceKey' {
        $body = @([pscustomobject]@{ Phase = 'Enforce' }) | ConvertTo-Json -Depth 8
        $response = Send-LogAnalyticsData -WorkspaceId 'ws-id' -WorkspaceKey 'key' `
            -Body $body -LogType 'RegistrySecureBootEnforcement' `
            -FrontendUrl $script:Endpoint -WarningAction SilentlyContinue
        $response.TableName | Should -Be 'RegistrySecureBootEnforcement_CL'
        $response.RecordCount | Should -Be 1
    }

    It 'still warns about an ignored key when it arrives under the -WorkspaceKey name' {
        $warnings = @()
        $null = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -WorkspaceKey 'SUPERSECRETKEY==' -FrontendUrl $script:Endpoint `
            -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join ' ') | Should -Not -BeLike '*SUPERSECRET*'
        ($warnings -join ' ') | Should -BeLike '*-SharedKey is ignored*'
    }

    It 'exposes Delivered so a script that returned $true/$false does not silently invert' {
        # `if ($response)` is always true for an object, so a boolean-returning call site
        # migrating to this function needs a property that means what its boolean meant.
        $response = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl $script:Endpoint
        $response.Delivered | Should -BeTrue

        Mock -ModuleName LogCollector.Client Send-LogCollectorData {
            [pscustomobject]@{ Disposition = 'Deferred'; StatusCode = 0; Attempts = 1; Message = 'queued' }
        }
        $deferred = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl $script:Endpoint
        $deferred.Delivered | Should -BeFalse
        # The trap the property exists to avoid.
        [bool] $deferred | Should -BeTrue
    }

    It 'reports 202 rather than a false 200 when the batch could only be spooled' {
        Mock -ModuleName LogCollector.Client Send-LogCollectorData {
            [pscustomobject]@{ Disposition = 'Deferred'; StatusCode = 0; Attempts = 1; Message = 'queued' }
        }
        $response = Send-LogAnalyticsData -LogType 'W11Upgrade' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl $script:Endpoint
        $response.StatusCode | Should -Be 202
        ($response -match '200 :') | Should -BeFalse
        $response.Disposition | Should -Be 'Deferred'
    }

    It 'never transmits the workspace key and never echoes it in the warning' {
        $warnings = @()
        $null = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -sharedKey 'SUPERSECRETKEY==' -FrontendUrl $script:Endpoint `
            -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join ' ') | Should -Not -BeLike '*SUPERSECRET*'
        ($warnings -join ' ') | Should -BeLike '*-SharedKey is ignored*'
        Should -Invoke -ModuleName LogCollector.Client Send-LogCollectorData -Times 1 -ParameterFilter {
            -not $PSBoundParameters.ContainsKey('SharedKey')
        }
    }

    It 'does not warn when no key is supplied, so migrated scripts stay quiet' {
        $warnings = @()
        $null = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl $script:Endpoint -WarningVariable warnings
        $warnings.Count | Should -Be 0
    }

    It 'warns on an empty key too, because that is still an unmigrated call site' {
        $warnings = @()
        $null = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -sharedKey '' -FrontendUrl $script:Endpoint `
            -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join ' ') | Should -BeLike '*-SharedKey is ignored*'
    }

    It 'defaults Source to the calling script so one table can carry several producers' {
        $response = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl $script:Endpoint
        $response.Source | Should -Not -BeNullOrEmpty
    }

    It 'refuses a plaintext endpoint even when the caller insists' {
        { Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl 'http://example.invalid/api/inventory' } |
            Should -Throw '*must be an absolute HTTPS*'
    }

    It 'makes no submission under -WhatIf' {
        Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 }) `
            -FrontendUrl $script:Endpoint -WhatIf
        Should -Invoke -ModuleName LogCollector.Client Send-LogCollectorData -Times 0
    }

    It 'falls back to the machine-wide configuration when no endpoint is given' {
        Mock -ModuleName LogCollector.Client Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{ FrontendUrl = 'https://configured.invalid/api/submit'; CertificateThumbprint = 'AB' }
        }
        $null = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 })
        Should -Invoke -ModuleName LogCollector.Client Send-LogCollectorData -Times 1 -ParameterFilter {
            $FrontendUrl.AbsoluteUri -eq 'https://configured.invalid/api/submit' -and
            $CertificateThumbprint -eq 'AB'
        }
    }

    It 'spools instead of delivering when the configuration disables submission' {
        Mock -ModuleName LogCollector.Client Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{ FrontendUrl = 'https://configured.invalid/api/submit'; SubmissionEnabled = $false }
        }
        $null = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 })
        Should -Invoke -ModuleName LogCollector.Client Send-LogCollectorData -Times 1 -ParameterFilter {
            $QueueOnly -eq $true
        }
    }

    It 'delivers when the configuration enables submission' {
        Mock -ModuleName LogCollector.Client Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{ FrontendUrl = 'https://configured.invalid/api/submit'; SubmissionEnabled = $true }
        }
        $null = Send-LogAnalyticsData -LogType 'T' -Body ([pscustomobject]@{ A = 1 })
        Should -Invoke -ModuleName LogCollector.Client Send-LogCollectorData -Times 1 -ParameterFilter {
            -not $PSBoundParameters.ContainsKey('QueueOnly')
        }
    }
}

Describe 'Send-LogCollectorOperationalEvent' {
    BeforeEach {
        Mock -ModuleName LogCollector.Client Send-LogAnalyticsData {
            [pscustomobject]@{
                Delivered = $true
                TableName = 'LogCollectorOperations_CL'
                Disposition = 'Delivered'
            }
        }
    }

    It 'sends the uniform operational schema to the common table' {
        $executionId = [guid]'11111111-2222-3333-4444-555555555555'
        $result = Send-LogCollectorOperationalEvent `
            -PackageName 'W11 Upgrade' `
            -PackageVersion '1.0.0' `
            -ScriptName 'STEP1di2.ps1' `
            -EventName 'StageCompleted' `
            -Level Info `
            -Message 'Windows setup staged.' `
            -ExecutionId $executionId `
            -FrontendUrl $script:Endpoint

        $result.Delivered | Should -BeTrue
        Should -Invoke -ModuleName LogCollector.Client Send-LogAnalyticsData -Times 1 -Exactly -ParameterFilter {
            $LogType -eq 'LogCollectorOperations' -and
            $Source -eq 'STEP1di2.ps1' -and
            $Body.PackageName -eq 'W11 Upgrade' -and
            $Body.PackageVersion -eq '1.0.0' -and
            $Body.ScriptName -eq 'STEP1di2.ps1' -and
            $Body.EventName -eq 'StageCompleted' -and
            $Body.Level -eq 'Info' -and
            $Body.Message -eq 'Windows setup staged.' -and
            $Body.ExecutionId -eq $executionId.ToString('D') -and
            $FrontendUrl.AbsoluteUri -eq $script:Endpoint
        }
    }

    It 'generates an execution id when the caller does not provide one' {
        $null = Send-LogCollectorOperationalEvent `
            -PackageName 'CPU package' -PackageVersion '1.0.0' `
            -ScriptName 'cpu.ps1' -EventName 'Completed' -Level Info -Message 'Done' `
            -FrontendUrl $script:Endpoint

        Should -Invoke -ModuleName LogCollector.Client Send-LogAnalyticsData -Times 1 -ParameterFilter {
            [guid]::Parse($Body.ExecutionId) -ne [guid]::Empty
        }
    }

    It 'does not let clients supply server-owned device identity columns' {
        $null = Send-LogCollectorOperationalEvent `
            -PackageName 'Package' -PackageVersion '1.0.0' `
            -ScriptName 'script.ps1' -EventName 'Started' -Level Info -Message 'Starting' `
            -FrontendUrl $script:Endpoint

        Should -Invoke -ModuleName LogCollector.Client Send-LogAnalyticsData -Times 1 -ParameterFilter {
            -not $Body.PSObject.Properties['DeviceName'] -and
            -not $Body.PSObject.Properties['EntraDeviceId'] -and
            -not $Body.PSObject.Properties['IntuneDeviceId']
        }
    }

    It 'rejects whitespace-only or control-character fields' {
        { Send-LogCollectorOperationalEvent `
                -PackageName ' ' -PackageVersion '1.0.0' `
                -ScriptName 'script.ps1' -EventName 'Started' -Level Info -Message 'Starting' `
                -FrontendUrl $script:Endpoint } |
            Should -Throw '*non-empty*'

        { Send-LogCollectorOperationalEvent `
                -PackageName 'Package' -PackageVersion '1.0.0' `
                -ScriptName 'script.ps1' -EventName 'Started' -Level Info -Message "Bad$([char]1)" `
                -FrontendUrl $script:Endpoint } |
            Should -Throw '*control characters*'
    }

    It 'does not submit under WhatIf' {
        Send-LogCollectorOperationalEvent `
            -PackageName 'Package' -PackageVersion '1.0.0' `
            -ScriptName 'script.ps1' -EventName 'Started' -Level Info -Message 'Starting' `
            -FrontendUrl $script:Endpoint -WhatIf

        Should -Invoke -ModuleName LogCollector.Client Send-LogAnalyticsData -Times 0
    }
}

Describe 'Get-LogCollectorEndpointConfiguration' {    It 'names the expected path when the core package is not installed' {
        $missing = Join-Path $TestDrive 'absent\Endpoint.psd1'
        { Get-LogCollectorEndpointConfiguration -Path $missing -SkipTrustCheck } |
            Should -Throw '*is not configured on this machine*'
    }

    It 'reports a configuration that does not define an endpoint' {
        $path = New-TestConfiguration -Path (Join-Path $TestDrive 'a\Endpoint.psd1') -Body "@{ Environment = 'Test' }"
        { Get-LogCollectorEndpointConfiguration -Path $path -SkipTrustCheck } |
            Should -Throw '*does not define FrontendUrl*'
    }

    It 'rejects a configured endpoint that is not an intake route' {
        $path = New-TestConfiguration -Path (Join-Path $TestDrive 'b\Endpoint.psd1') -Body "@{ FrontendUrl = 'https://x.invalid/evil' }"
        { Get-LogCollectorEndpointConfiguration -Path $path -SkipTrustCheck } |
            Should -Throw '*must be an absolute HTTPS*'
    }

    It 'supplies defaults so a minimal configuration is enough' {
        $path = New-TestConfiguration -Path (Join-Path $TestDrive 'c\Endpoint.psd1') -Body "@{ FrontendUrl = 'https://x.invalid/api/inventory' }"
        $config = Get-LogCollectorEndpointConfiguration -Path $path -SkipTrustCheck
        $config.FrontendUrl | Should -Be 'https://x.invalid/api/inventory'
        $config.SubmissionEnabled | Should -BeTrue
        $config.PkiRootCaThumbprints | Should -BeNullOrEmpty
        $config.ConfigurationPath | Should -Be $path
    }

    It 'derives the canonical customer-scoped data and configuration paths' {
        $dataRoot = Get-LogCollectorDataRoot -CustomerName 'Contoso'
        $dataRoot | Should -Be (Join-Path (Join-Path $env:ProgramData 'Contoso') 'LogCollector')
        Get-LogCollectorConfigurationPath -CustomerName 'Contoso' |
            Should -Be (Join-Path $dataRoot 'Config\Endpoint.psd1')
    }

    It 'refuses a configuration that an unprivileged user could rewrite' {
        $path = New-TestConfiguration -Path (Join-Path $TestDrive 'd\Endpoint.psd1') -Body "@{ FrontendUrl = 'https://x.invalid/api/inventory' }"
        $acl = Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]'S-1-5-32-545', 'Modify', 'Allow')))
        Set-Acl -LiteralPath $path -AclObject $acl
        { Get-LogCollectorEndpointConfiguration -Path $path } | Should -Throw '*cannot be trusted*'
    }

    It 'refuses a configuration reached through a junction' {
        $target = Join-Path $TestDrive 'junction-target'
        $link = Join-Path $TestDrive 'junction-link'
        $path = New-TestConfiguration -Path (Join-Path $target 'Config\Endpoint.psd1') `
            -Body "@{ FrontendUrl = 'https://x.invalid/api/inventory' }"
        try { $null = New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop }
        catch {
            Set-ItResult -Skipped -Because "Directory junctions are unavailable: $($_.Exception.Message)"
            return
        }
        { Get-LogCollectorEndpointConfiguration -Path (Join-Path $link 'Config\Endpoint.psd1') } |
            Should -Throw '*reparse point*'
    }
}

Describe 'Core package provisioning' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'src\CorePackage\Core.Provisioning.psm1') -Force -ErrorAction Stop
    }

    BeforeEach {
        # Hardening needs elevation; the subject here is the file the installer emits.
        Mock -ModuleName Core.Provisioning Set-LogCollectorMachineAcl {}
        Mock -ModuleName Core.Provisioning Assert-LogCollectorMachineAcl {}
        Mock -ModuleName Core.Provisioning Set-LogCollectorPrivateDataAcl {}
    }

    It 'installs under a path that both PowerShell editions already search' {
        $root = Get-LogCollectorModuleRoot -Version '1.6.0'
        $root | Should -BeLike '*\WindowsPowerShell\Modules\LogCollector.Client\1.6.0'
    }

    It 'emits a configuration the client can read back' {
        $path = Join-Path $TestDrive 'roundtrip\Endpoint.psd1'
        Write-LogCollectorEndpointConfiguration -Path $path -Configuration @{
            FrontendUrl          = 'https://intake.invalid/api/inventory'
            SubmissionEnabled    = $false
            Environment          = 'Pilot'
            PkiRootCaThumbprints = @('AA11', 'BB22')
        }
        $configuration = Get-LogCollectorEndpointConfiguration -Path $path -SkipTrustCheck
        $configuration.FrontendUrl | Should -Be 'https://intake.invalid/api/inventory'
        $configuration.SubmissionEnabled | Should -BeFalse
        $configuration.Environment | Should -Be 'Pilot'
        $configuration.PkiRootCaThumbprints | Should -Be @('AA11', 'BB22')
    }

    It 'escapes a value that would otherwise break the data file' {
        $path = Join-Path $TestDrive 'escape\Endpoint.psd1'
        Write-LogCollectorEndpointConfiguration -Path $path -Configuration @{
            FrontendUrl            = 'https://intake.invalid/api/submit'
            CertificateSubjectLike = "CN=O'Brien*"
        }
        (Get-LogCollectorEndpointConfiguration -Path $path -SkipTrustCheck).CertificateSubjectLike |
            Should -Be "CN=O'Brien*"
    }

    It 'leaves no temporary file behind' {
        $path = Join-Path $TestDrive 'clean\Endpoint.psd1'
        Write-LogCollectorEndpointConfiguration -Path $path -Configuration @{ FrontendUrl = 'https://intake.invalid/api/submit' }
        @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '*.tmp').Count | Should -Be 0
    }

    It 'writes nothing under -WhatIf' {
        $path = Join-Path $TestDrive 'whatif\Endpoint.psd1'
        Write-LogCollectorEndpointConfiguration -Path $path -Configuration @{ FrontendUrl = 'https://intake.invalid/api/submit' } -WhatIf
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'migrates compatible legacy spool and state without losing files' {
        $legacy = Join-Path $TestDrive 'legacy'
        $destination = Join-Path $TestDrive 'customer\LogCollector'
        $null = New-Item -ItemType Directory -Path (Join-Path $legacy 'SharedSpool\bucket') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $legacy 'State') -Force
        $null = New-Item -ItemType Directory -Path $destination -Force
        Set-Content -LiteralPath (Join-Path $legacy 'SharedSpool\bucket\queued.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $legacy 'State\probe.json') -Value '{}'

        Move-LogCollectorLegacyData -LegacyRoot $legacy -DestinationRoot $destination

        Test-Path -LiteralPath (Join-Path $destination 'SharedSpool\bucket\queued.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'State\probe.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $legacy 'SharedSpool') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $legacy 'State') | Should -BeFalse
        Should -Invoke -ModuleName Core.Provisioning Set-LogCollectorPrivateDataAcl -Times 5
    }

    It 'refuses to overwrite an existing customer-scoped data file during migration' {
        $legacy = Join-Path $TestDrive 'legacy-collision'
        $destination = Join-Path $TestDrive 'customer-collision\LogCollector'
        $relative = 'SharedSpool\bucket\queued.json'
        $null = New-Item -ItemType Directory -Path (Split-Path (Join-Path $legacy $relative) -Parent) -Force
        $null = New-Item -ItemType Directory -Path (Split-Path (Join-Path $destination $relative) -Parent) -Force
        Set-Content -LiteralPath (Join-Path $legacy $relative) -Value '{"legacy":true}'
        Set-Content -LiteralPath (Join-Path $destination $relative) -Value '{"current":true}'

        { Move-LogCollectorLegacyData -LegacyRoot $legacy -DestinationRoot $destination } |
            Should -Throw '*would overwrite*'
        Get-Content -LiteralPath (Join-Path $legacy $relative) -Raw | Should -Match 'legacy'
        Get-Content -LiteralPath (Join-Path $destination $relative) -Raw | Should -Match 'current'
    }

    It 'refuses to migrate a legacy root reached through a junction' {
        $target = Join-Path $TestDrive 'migration-junction-target'
        $link = Join-Path $TestDrive 'migration-junction-link'
        $destination = Join-Path $TestDrive 'migration-junction-destination'
        $null = New-Item -ItemType Directory -Path (Join-Path $target 'SharedSpool') -Force
        $null = New-Item -ItemType Directory -Path $destination -Force
        try { $null = New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop }
        catch {
            Set-ItResult -Skipped -Because "Directory junctions are unavailable: $($_.Exception.Message)"
            return
        }
        { Move-LogCollectorLegacyData -LegacyRoot $link -DestinationRoot $destination } |
            Should -Throw '*reparse point*'
    }
}
