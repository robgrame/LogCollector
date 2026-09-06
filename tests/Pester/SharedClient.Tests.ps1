BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1') -Force -ErrorAction Stop
    $script:Endpoint = [Uri]'https://example.invalid/api/inventory'
    $script:DeviceId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
}

Describe 'Shared client facade' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName LogCollector.Client Get-DeviceIdentitySnapshot {
            [pscustomobject]@{
                EntraDeviceId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
                DeviceName = 'PesterDevice'
                IntuneDeviceId = $null
            }
        }
        Mock -ModuleName LogCollector.Client Get-ClientCertificate {
            New-Object Security.Cryptography.X509Certificates.X509Certificate2
        }
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; RetryAfterSeconds = $null; Message = 'ok' }
        }
        # Substitute the fixture owner, not the filesystem permission checks.
        Mock -ModuleName InventorySpool Test-SpoolTrustedIdentity {
            param($Sid, [switch] $Ancestor)
            return ($Sid -in @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -or
                ($Ancestor -and $Sid -eq 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'))
        }
        Mock -ModuleName InventorySpool New-SpoolSecurityDescriptor {
            param([switch] $Directory)
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ($Directory) {
                $acl = New-Object Security.AccessControl.DirectorySecurity
                $acl.SetSecurityDescriptorSddlForm("O:${sid}G:${sid}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;$sid)")
            }
            else {
                $acl = New-Object Security.AccessControl.FileSecurity
                $acl.SetSecurityDescriptorSddlForm("O:${sid}G:${sid}D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;$sid)")
            }
            return $acl
        }
    }

    It 'exports the documented public surface' {
        $commands = @(Get-Command -Module LogCollector.Client).Name | Sort-Object
        $expected = @('Get-DeviceIdentitySnapshot', 'Get-ClientCertificate', 'New-SignedInventoryRequest',
            'New-InventoryEnvelope', 'Get-LogCollectorSpoolPath', 'Send-LogCollectorData', 'Sync-LogCollectorSpool') | Sort-Object
        ($commands -join ',') | Should -BeExactly ($expected -join ',')
    }

    It 'reports certificate transport and spool metadata without payload or response text' {
        Mock -ModuleName LogCollector.Client Get-ClientCertificate {
            $rsa = [Security.Cryptography.RSA]::Create()
            try {
                $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest(
                    'CN=Private-Sentinel-Subject', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                return $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddHours(1))
            }
            finally { $rsa.Dispose() }
        }
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            [pscustomobject]@{ Disposition = 'AuthFailure'; StatusCode = 401; RetryAfterSeconds = $null; Message = 'Private-Sentinel-Response' }
        }
        $events = New-Object 'Collections.Generic.List[object]'
        $sink = { param($event, $data) $events.Add([pscustomobject]@{ Event = $event; Data = $data }) }.GetNewClosure()
        $result = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ Secret = 'Private-Sentinel-Payload' }) -Source 'Pester' -SpoolRoot $script:Root -SkipDrain -DiagnosticSink $sink
        $result.Spooled | Should -BeTrue
        $events.Event | Should -Contain 'CertificateSelectionStarted'
        $events.Event | Should -Contain 'CertificateSelected'
        $events.Event | Should -Contain 'HttpAttempt'
        $events.Event | Should -Contain 'HttpResult'
        $events.Event | Should -Contain 'SpoolQueued'
        ($events | Where-Object Event -eq 'CertificateSelected').Data.CertificateThumbprint | Should -Match '^[0-9A-F]{40}$'
        ($events | Where-Object Event -eq 'SpoolQueued').Data.SpoolPath | Should -BeExactly $result.SpoolPath
        (ConvertTo-Json -InputObject $events.ToArray() -Depth 5) | Should -Not -Match 'Private-Sentinel'
    }

    It 'records missing certificate selection and retains data without HTTP' {
        Mock -ModuleName LogCollector.Client Get-ClientCertificate { $null }
        $events = New-Object 'Collections.Generic.List[string]'
        $sink = { param($event, $data) $events.Add($event) }.GetNewClosure()
        $result = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ A = 1 }) -Source 'Pester' -SpoolRoot $script:Root -SkipDrain -DiagnosticSink $sink -WarningAction SilentlyContinue
        $result.Spooled | Should -BeTrue
        $events | Should -Contain 'CertificateUnavailable'
        $events | Should -Contain 'SpoolQueued'
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 0 -Exactly
    }

    It 'surfaces diagnostic sink failure rather than sending without diagnostics' {
        { Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ A = 1 }) -Source 'Pester' -SpoolRoot $script:Root -SkipDrain `
            -DiagnosticSink { throw 'Diagnostic sink unavailable' } } | Should -Throw '*Diagnostic sink unavailable*'
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 0 -Exactly
    }

    It 'rejects unsafe endpoints before identity or filesystem access' -TestCases @(
        @{ Url = 'http://example.invalid/api/inventory' }
        @{ Url = 'https://user:password@example.invalid/api/inventory' }
        @{ Url = 'https://example.invalid/api/inventory?code=placeholder' }
        @{ Url = 'https://example.invalid/api/inventory#fragment' }
        @{ Url = 'https://example.invalid/other' }
        @{ Url = '/api/inventory' }
    ) {
        param($Url)
        { Send-LogCollectorData -FrontendUrl $Url -TableName 'T_CL' -Records @(@{ A = 1 }) `
            -Source 'Pester' -SpoolRoot $script:Root } | Should -Throw
        Should -Invoke -ModuleName LogCollector.Client Get-DeviceIdentitySnapshot -Times 0 -Exactly
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'uses stable endpoint-specific queues' {
        $first = Get-LogCollectorSpoolPath -FrontendUrl $script:Endpoint -SpoolRoot $script:Root
        $same = Get-LogCollectorSpoolPath -FrontendUrl 'https://EXAMPLE.INVALID:443/api/inventory' -SpoolRoot $script:Root
        $other = Get-LogCollectorSpoolPath -FrontendUrl 'https://another.invalid/api/inventory' -SpoolRoot $script:Root
        $same | Should -BeExactly $first
        $other | Should -Not -Be $first
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'preserves nested record types and Unicode through the real submission pipeline' {
        $script:BodySeen = $null
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            param($Body, $TimeoutSeconds)
            $script:BodySeen = $Body
            $TimeoutSeconds | Should -Be 12
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; RetryAfterSeconds = $null; Message = 'ok' }
        }
        $unicode = 'Caf' + [char]0x00e8
        $record = @{ EventTimeUtc = '2026-09-06T07:00:00Z'; Enabled = $true; Count = 7; Nested = @(@{ Name = $unicode }) }
        $result = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @($record) -Source 'SecureBootReporter' -Properties @{ Version = 12 } `
            -SpoolRoot $script:Root -SkipDrain -TimeoutSeconds 12
        $body = $script:BodySeen | ConvertFrom-Json
        $body.envelopeVersion | Should -BeExactly 'LOGCOLLECTOR-INVENTORY-V1'
        $body.entraDeviceId | Should -BeExactly $script:DeviceId
        $body.source | Should -BeExactly 'SecureBootReporter'
        $body.records[0].Nested[0].Name | Should -BeExactly $unicode
        $body.records[0].Enabled | Should -BeOfType [bool]
        $body.records[0].Count | Should -Be 7
        $body.properties.Version | Should -BeExactly '12'
        $result.StatusCode | Should -Be 202
        $result.Spooled | Should -BeFalse
    }

    It 'passes certificate selectors and the local Entra identity to discovery' {
        $rootPins = @('1111111111111111111111111111111111111111')
        $rootNames = @('CN=Root CA, O=Contoso')
        $intermediatePins = @('2222222222222222222222222222222222222222')
        $intermediateNames = @('CN=Issuing CA, O=Contoso')
        $null = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' -Records @(@{ A = 1 }) `
            -Source 'Pester' -SpoolRoot $script:Root -SkipDrain `
            -CertificateThumbprint 'ABC' -CertificateSubjectLike '*device*' -CertificateIssuerLike '*PKI*' `
            -PkiRootCaThumbprints $rootPins -PkiRootCaSubjects $rootNames `
            -PkiIntermediateCaThumbprints $intermediatePins -PkiIntermediateCaSubjects $intermediateNames
        Should -Invoke -ModuleName LogCollector.Client Get-ClientCertificate -Times 1 -Exactly -ParameterFilter {
            $EntraDeviceId -eq '3f2504e0-4f89-11d3-9a0c-0305e82c3301' -and
            $Thumbprint -eq 'ABC' -and $SubjectLike -eq '*device*' -and $IssuerLike -eq '*PKI*' -and
            ($PkiRootCaThumbprints -join ',') -eq ($rootPins -join ',') -and
            ($PkiRootCaSubjects -join ',') -eq ($rootNames -join ',') -and
            ($PkiIntermediateCaThumbprints -join ',') -eq ($intermediatePins -join ',') -and
            ($PkiIntermediateCaSubjects -join ',') -eq ($intermediateNames -join ',')
        }
    }

    It 'passes PKI CA constraints through spool synchronization' {
        $rootPins = @('1111111111111111111111111111111111111111')
        $rootNames = @('CN=Root CA, O=Contoso')
        $intermediatePins = @('2222222222222222222222222222222222222222')
        $intermediateNames = @('CN=Issuing CA, O=Contoso')

        $null = Sync-LogCollectorSpool -FrontendUrl $script:Endpoint -SpoolRoot $script:Root `
            -PkiRootCaThumbprints $rootPins -PkiRootCaSubjects $rootNames `
            -PkiIntermediateCaThumbprints $intermediatePins -PkiIntermediateCaSubjects $intermediateNames

        Should -Invoke -ModuleName LogCollector.Client Get-ClientCertificate -Times 1 -Exactly -ParameterFilter {
            ($PkiRootCaThumbprints -join ',') -eq ($rootPins -join ',') -and
            ($PkiRootCaSubjects -join ',') -eq ($rootNames -join ',') -and
            ($PkiIntermediateCaThumbprints -join ',') -eq ($intermediatePins -join ',') -and
            ($PkiIntermediateCaSubjects -join ',') -eq ($intermediateNames -join ',')
        }
    }

    It 'queues without certificate lookup or network access' {
        $result = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ A = 1 }) -Source 'Pester' -SpoolRoot $script:Root -QueueOnly
        $result.Disposition | Should -BeExactly 'Deferred'
        $result.Spooled | Should -BeTrue
        Test-Path -LiteralPath $result.SpoolPath | Should -BeTrue
        Should -Invoke -ModuleName LogCollector.Client Get-ClientCertificate -Times 0 -Exactly
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 0 -Exactly
    }

    It 'retains certificate-unavailable telemetry and drains it after renewal' {
        Mock -ModuleName LogCollector.Client Get-ClientCertificate {
            $errorRecord = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('No usable client certificate found'),
                'LogCollector.ClientCertificateNotFound', [Management.Automation.ErrorCategory]::ObjectNotFound, $null)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
        $result = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ A = 1 }) -Source 'Pester' -SpoolRoot $script:Root -WarningAction SilentlyContinue
        $result.Disposition | Should -BeExactly 'AuthFailure'
        $result.Spooled | Should -BeTrue
        $stopped = Sync-LogCollectorSpool -FrontendUrl $script:Endpoint -SpoolRoot $script:Root -WarningAction SilentlyContinue
        $stopped.Stopped | Should -BeTrue
        $stopped.Remaining | Should -Be 1
        Mock -ModuleName LogCollector.Client Get-ClientCertificate {
            New-Object Security.Cryptography.X509Certificates.X509Certificate2
        }
        $drain = Sync-LogCollectorSpool -FrontendUrl $script:Endpoint -SpoolRoot $script:Root
        $drain.Delivered | Should -Be 1
        $drain.Remaining | Should -Be 0
    }

    It 'does not redirect old telemetry to a different endpoint' {
        $entry = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ A = 1 }) -Source 'Pester' -SpoolRoot $script:Root -QueueOnly
        $result = Sync-LogCollectorSpool -FrontendUrl 'https://another.invalid/api/inventory' -SpoolRoot $script:Root
        $result.Delivered | Should -Be 0
        Test-Path -LiteralPath $entry.SpoolPath | Should -BeTrue
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 0 -Exactly
    }

    It 'enforces retention during certificate-unavailable drains without sending data' {
        $entry = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ A = 1 }) -Source 'Pester' -SpoolRoot $script:Root -QueueOnly
        (Get-Item -LiteralPath $entry.SpoolPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
        Mock -ModuleName LogCollector.Client Get-ClientCertificate {
            $errorRecord = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('No usable client certificate found'),
                'LogCollector.ClientCertificateNotFound', [Management.Automation.ErrorCategory]::ObjectNotFound, $null)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
        $result = Sync-LogCollectorSpool -FrontendUrl $script:Endpoint -SpoolRoot $script:Root -WarningAction SilentlyContinue
        $result.Stopped | Should -BeTrue
        $result.Remaining | Should -Be 0
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 0 -Exactly
    }

    It 'drains retained data without executing a collector' {
        $null = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' `
            -Records @(@{ A = 1 }) -Source 'Pester' -SpoolRoot $script:Root -QueueOnly
        $result = Sync-LogCollectorSpool -FrontendUrl $script:Endpoint -SpoolRoot $script:Root
        $result.Delivered | Should -Be 1
        $result.Remaining | Should -Be 0
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 1 -Exactly
    }

    It 'propagates unexpected certificate-provider failures instead of pretending to queue them' {
        Mock -ModuleName LogCollector.Client Get-ClientCertificate { throw 'Unexpected provider failure' }
        { Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' -Records @(@{ A = 1 }) `
            -Source 'Pester' -SpoolRoot $script:Root } | Should -Throw '*Unexpected provider failure*'
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'never invents an identity when local device discovery fails' {
        Mock -ModuleName LogCollector.Client Get-DeviceIdentitySnapshot { throw 'Entra identity unavailable' }
        { Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' -Records @(@{ A = 1 }) `
            -Source 'Pester' -SpoolRoot $script:Root -QueueOnly } | Should -Throw '*Entra identity unavailable*'
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'keeps a transient failure and reports a permanent rejection without false success' -TestCases @(
        @{ Status = 503; Disposition = 'Transient'; Spooled = $true }
        @{ Status = 400; Disposition = 'Permanent'; Spooled = $false }
    ) {
        param($Status, $Disposition, $Spooled)
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            [pscustomobject]@{ Disposition = $Disposition; StatusCode = $Status; RetryAfterSeconds = $null; Message = 'rejected' }
        }
        $result = Send-LogCollectorData -FrontendUrl $script:Endpoint -TableName 'T_CL' -Records @(@{ A = 1 }) `
            -Source 'Pester' -SpoolRoot $script:Root -SkipDrain -MaxAttempts 1
        $result.Disposition | Should -BeExactly $Disposition
        $result.Spooled | Should -Be $Spooled
        $result.StatusCode | Should -Be $Status
    }
}

Describe 'Shared module packaging' {
    It 'packages exactly the manifest files under a versioned module directory' {
        $sourceManifest = Test-ModuleManifest (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1')
        $expectedVersion = $sourceManifest.Version.ToString()
        $result = & (Join-Path $script:RepoRoot 'scripts\Publish-ClientModule.ps1') -OutputDirectory $TestDrive
        $result.ModuleVersion | Should -BeExactly $expectedVersion
        $result.PackageSha256 | Should -Match '^[A-F0-9]{64}$'
        $manifest = Test-ModuleManifest (Join-Path $result.ModulePath 'LogCollector.Client.psd1')
        $manifest.ExportedFunctions.Count | Should -Be 7
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($result.PackagePath)
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            $names.Count | Should -Be 6
            foreach ($file in $manifest.FileList) {
                $names | Should -Contain ("LogCollector.Client/$expectedVersion/" + (Split-Path $file -Leaf))
            }
        }
        finally { $zip.Dispose() }
    }

    It 'does not create output when packaging is requested with WhatIf' {
        $output = Join-Path $TestDrive 'not-created'
        & (Join-Path $script:RepoRoot 'scripts\Publish-ClientModule.ps1') -OutputDirectory $output -WhatIf
        Test-Path -LiteralPath $output | Should -BeFalse
    }
}
