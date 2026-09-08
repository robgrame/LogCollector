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

    It 'refuses a configuration that an unprivileged user could rewrite' {
        $path = New-TestConfiguration -Path (Join-Path $TestDrive 'd\Endpoint.psd1') -Body "@{ FrontendUrl = 'https://x.invalid/api/inventory' }"
        $acl = Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]'S-1-5-32-545', 'Modify', 'Allow')))
        Set-Acl -LiteralPath $path -AclObject $acl
        { Get-LogCollectorEndpointConfiguration -Path $path } | Should -Throw '*cannot be trusted*'
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
}
