BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Builder = Join-Path $script:Repo 'scripts\Publish-IntuneWin32Package.ps1'
    $script:Tool = Join-Path $TestDrive 'Microsoft tool\IntuneWinAppUtil.exe'
    $null = New-Item -ItemType Directory -Path (Split-Path $script:Tool -Parent)
    Set-Content -LiteralPath $script:Tool -Value 'Never executed: Start-Process is mocked.'
    $script:Version = (Import-PowerShellDataFile (Join-Path $script:Repo 'src\InventoryPackage\Config.psd1')).PackageVersion
}

AfterAll {
    foreach ($name in @('Inventory.Runtime', 'Inventory.Collection', 'Inventory.Logging', 'LogCollector.Client',
        'InventoryClient', 'InventorySpool', 'DeviceIdentity', 'RequestSigning')) {
        Get-Module -All -Name $name | Remove-Module -Force -ErrorAction Stop
    }
}

Describe 'Intune Win32 package generation' {
    BeforeEach {
        $script:Output = Join-Path $TestDrive ([guid]::NewGuid().ToString() + ' output with spaces')
        Mock Start-Process {
            param($FilePath, $ArgumentList)
            $destination = $ArgumentList[5].Trim('"')
            Set-Content -LiteralPath (Join-Path $destination 'Install.intunewin') -Value 'Mocked content prep output'
            [pscustomobject]@{ ExitCode = 0 }
        }
    }

    It 'packages all files using separated paths and exposes the matching detection and guide' {
        $result = & $script:Builder -IntuneWinAppUtilPath $script:Tool `
            -FrontendUrl 'https://example.invalid/api/inventory' -Environment 'TestLab' -OutputRoot $script:Output
        $result.PackageVersion | Should -BeExactly $script:Version
        $result.SubmissionEnabled | Should -BeFalse
        $result.PackageSha256 | Should -Match '^[0-9A-F]{64}$'
        $result.ConfigurationSha256 | Should -BeExactly (Get-FileHash (Join-Path $result.SourcePath 'Config.psd1')).Hash
        @(Get-ChildItem -LiteralPath $result.SourcePath -Recurse -File).Count | Should -Be 16
        (Get-FileHash $result.DetectionScript).Hash |
            Should -BeExactly (Get-FileHash (Join-Path $result.SourcePath 'Detect.ps1')).Hash
        Test-Path -LiteralPath $result.DeploymentGuide | Should -BeTrue
        $config = Import-PowerShellDataFile (Join-Path $result.SourcePath 'Config.psd1')
        $config.Environment | Should -BeExactly 'TestLab'
        $config.DeviceTableName | Should -BeExactly 'DeviceInventory_CL'
        $config.AppTableName | Should -BeExactly 'AppInventory_CL'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:Tool -and $Wait -and $PassThru -and $NoNewWindow -and
            $ArgumentList[0] -eq '-c' -and $ArgumentList[1].StartsWith('"') -and
            $ArgumentList[1].EndsWith('"') -and $ArgumentList[3] -eq 'Install.ps1' -and
            $ArgumentList[5].StartsWith('"') -and $ArgumentList[6] -eq '-qq'
        }
        { & $script:Builder -IntuneWinAppUtilPath $script:Tool `
            -FrontendUrl 'https://example.invalid/api/inventory' -OutputRoot $script:Output } |
            Should -Throw '*already exists*'
        Should -Invoke Start-Process -Times 1 -Exactly
    }

    It 'preserves a deliberately configured pilot without copying adjacent files' {
        $custom = Join-Path $TestDrive 'Custom.psd1'
        (Get-Content (Join-Path $script:Repo 'src\InventoryPackage\Config.psd1') -Raw).
            Replace("FrontendUrl = ''", "FrontendUrl = 'https://pilot.invalid/api/inventory'").
            Replace('SubmissionEnabled = $false', 'SubmissionEnabled = $true').
            Replace("CertificateThumbprint = ''", ("CertificateThumbprint = '" + ('A' * 40) + "'")) |
            Set-Content $custom
        $result = & $script:Builder -IntuneWinAppUtilPath $script:Tool -ConfigurationPath $custom -OutputRoot $script:Output
        $result.SubmissionEnabled | Should -BeTrue
        (Get-Content $result.DetectionScript -Raw) | Should -Match $result.ConfigurationSha256
        (Get-Content $result.DetectionScript -Raw) | Should -Not -Match '__LOGCOLLECTOR_CONFIGURATION_SHA256__'
        (Get-FileHash (Join-Path $result.SourcePath 'Config.psd1')).Hash | Should -BeExactly (Get-FileHash $custom).Hash
        @(Get-ChildItem -LiteralPath $result.SourcePath -File -Recurse).Count | Should -Be 16
    }

    It 'rejects mismatched configuration versions before writing output' {
        $custom = Join-Path $TestDrive 'Old.psd1'
        (Get-Content (Join-Path $script:Repo 'src\InventoryPackage\Config.psd1') -Raw).
            Replace($script:Version, '0.0.0') | Set-Content $custom
        { & $script:Builder -IntuneWinAppUtilPath $script:Tool -ConfigurationPath $custom -OutputRoot $script:Output } |
            Should -Throw '*Configuration must use package version*'
        Test-Path $script:Output | Should -BeFalse
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'validates configuration with the runtime before running the tool' {
        $custom = Join-Path $TestDrive 'Invalid.psd1'
        (Get-Content (Join-Path $script:Repo 'src\InventoryPackage\Config.psd1') -Raw).
            Replace("FrontendUrl = ''", "FrontendUrl = 'https://pilot.invalid/api/inventory'").
            Replace('SubmissionEnabled = $false', "SubmissionEnabled = 'false'") | Set-Content $custom
        { & $script:Builder -IntuneWinAppUtilPath $script:Tool -ConfigurationPath $custom -OutputRoot $script:Output } |
            Should -Throw '*Boolean*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'propagates tool failure rather than reporting successful packaging' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 9 } }
        { & $script:Builder -IntuneWinAppUtilPath $script:Tool `
            -FrontendUrl 'https://example.invalid/api/inventory' -OutputRoot $script:Output } |
            Should -Throw '*exit code 9*'
    }

    It 'rejects missing and empty artifacts even with native exit code zero' -ForEach @(
        @{ EmptyFile = $false }, @{ EmptyFile = $true }
    ) {
        Mock Start-Process {
            param($ArgumentList)
            if ($EmptyFile) {
                $null = New-Item -ItemType File -Path (Join-Path $ArgumentList[5].Trim('"') 'Install.intunewin')
            }
            [pscustomobject]@{ ExitCode = 0 }
        }
        { & $script:Builder -IntuneWinAppUtilPath $script:Tool `
            -FrontendUrl 'https://example.invalid/api/inventory' -OutputRoot $script:Output } |
            Should -Throw '*no nonempty Install.intunewin*'
    }

    It 'does not create folders or start a process under WhatIf' {
        & $script:Builder -IntuneWinAppUtilPath $script:Tool `
            -FrontendUrl 'https://example.invalid/api/inventory' -OutputRoot $script:Output -WhatIf
        Test-Path $script:Output | Should -BeFalse
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'requires an existing exe before producing output' {
        { & $script:Builder -IntuneWinAppUtilPath (Join-Path $TestDrive 'missing.exe') `
            -FrontendUrl 'https://example.invalid/api/inventory' -OutputRoot $script:Output } | Should -Throw
        Test-Path $script:Output | Should -BeFalse
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'resolves the default output relative to the script when launched with PowerShell 5.1 File' {
        $sandbox = Join-Path $TestDrive 'Native file invocation'
        $scripts = Join-Path $sandbox 'scripts'
        $configSource = Join-Path $sandbox 'src\InventoryPackage'
        $null = New-Item -ItemType Directory -Path $scripts, $configSource -Force
        Copy-Item -LiteralPath $script:Builder -Destination $scripts
        Copy-Item -LiteralPath (Join-Path $script:Repo 'src\InventoryPackage\Config.psd1') -Destination $configSource
        $result = & powershell.exe -NoProfile -File (Join-Path $scripts 'Publish-IntuneWin32Package.ps1') `
            -IntuneWinAppUtilPath $script:Tool -FrontendUrl 'https://example.invalid/api/inventory' -WhatIf
        $LASTEXITCODE | Should -Be 0
        ($result -join "`n") | Should -Match ([regex]::Escape((Join-Path $sandbox "out\IntuneWin32\$script:Version")))
        Test-Path (Join-Path $sandbox 'out') | Should -BeFalse
    }
}
