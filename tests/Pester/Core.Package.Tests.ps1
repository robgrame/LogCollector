BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Builder = Join-Path $script:Repo 'scripts\New-IntunePackage.ps1'
    $script:Version = (Import-PowerShellDataFile (Join-Path $script:Repo 'src\CorePackage\Config.psd1')).PackageVersion
    $script:ModuleFiles = @((Import-PowerShellDataFile (
                Join-Path $script:Repo 'src\Client\LogCollector.Client.psd1')).FileList)
    $script:Tool = Join-Path $TestDrive 'IntuneWinAppUtil.exe'
    Set-Content -LiteralPath $script:Tool -Value 'Never executed: Start-Process is mocked.'
}

Describe 'Core Intune Win32 package generation' {
    BeforeEach {
        $script:Output = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' }
            }
        }
        Mock Start-Process {
            param($ArgumentList)
            $destination = $ArgumentList[5].Trim('"')
            Set-Content -LiteralPath (Join-Path $destination 'Install.intunewin') -Value 'Mocked package'
            [pscustomobject]@{ ExitCode = 0 }
        }
    }

    It 'builds directly from repository sources and binds detection to the configured endpoint' {
        $result = & $script:Builder -IntuneWinAppUtilPath $script:Tool `
            -FrontendUrl 'https://example.invalid/api/submit' -Environment 'Pilot' `
            -CustomerName 'Example' -OutputRoot $script:Output

        $result.PackageVersion | Should -BeExactly $script:Version
        $result.PackageSha256 | Should -Match '^[0-9A-F]{64}$'
        Test-Path -LiteralPath $result.IntuneWinPackage -PathType Leaf | Should -BeTrue
        $config = Import-PowerShellDataFile (Join-Path $script:Output "$script:Version\Source\Config.psd1")
        $config.FrontendUrl | Should -BeExactly 'https://example.invalid/api/submit'
        $config.Environment | Should -BeExactly 'Pilot'
        $config.CustomerName | Should -BeExactly 'Example'
        $config.SubmissionEnabled | Should -BeTrue
        (Get-Content -LiteralPath $result.DetectionScript -Raw) |
            Should -Not -Match '__LOGCOLLECTOR_CORE_EXPECTED_CONFIGURATION_BASE64__'
        Should -Invoke Start-Process -Times 1 -Exactly
    }

    It 'does not require or execute the utility under WhatIf' {
        & $script:Builder -IntuneWinAppUtilPath (Join-Path $TestDrive 'missing.exe') `
            -FrontendUrl 'https://example.invalid/api/submit' -OutputRoot $script:Output -WhatIf

        Test-Path -LiteralPath $script:Output | Should -BeFalse
        Should -Invoke Get-AuthenticodeSignature -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'rejects a tool not signed by Microsoft' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example, O=Example Corp, C=US' }
            }
        }

        { & $script:Builder -IntuneWinAppUtilPath $script:Tool `
                -FrontendUrl 'https://example.invalid/api/submit' -OutputRoot $script:Output } |
            Should -Throw '*not by Microsoft Corporation*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'runs unchanged from a self-contained customer deliverable' {
        $delivery = Join-Path $TestDrive '2-Intune'
        $coreSource = Join-Path $delivery 'CoreSource'
        $null = New-Item -ItemType Directory -Path (Join-Path $coreSource 'Modules') -Force
        Copy-Item -LiteralPath $script:Builder -Destination (Join-Path $delivery 'New-IntunePackage.ps1')
        foreach ($file in @('Config.psd1', 'Core.Provisioning.psm1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $script:Repo "src\CorePackage\$file") -Destination $coreSource
        }
        foreach ($file in $script:ModuleFiles) {
            $destination = Join-Path $coreSource "Modules\$file"
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item -LiteralPath (Join-Path $script:Repo "src\Client\$file") -Destination $destination
        }
        $tools = Join-Path $delivery 'Tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item -LiteralPath $script:Tool -Destination (Join-Path $tools 'IntuneWinAppUtil.exe')

        $result = & (Join-Path $delivery 'New-IntunePackage.ps1') `
            -FrontendUrl 'https://example.invalid/api/submit' -OutputRoot $script:Output

        $result.ContentPrepTool | Should -BeExactly (Join-Path $tools 'IntuneWinAppUtil.exe')
        Test-Path -LiteralPath $result.IntuneWinPackage -PathType Leaf | Should -BeTrue
    }

    It 'rejects ambiguous automatic utility discovery' {
        $delivery = Join-Path $TestDrive 'Ambiguous\2-Intune'
        $coreSource = Join-Path $delivery 'CoreSource'
        $null = New-Item -ItemType Directory -Path (Join-Path $coreSource 'Modules') -Force
        Copy-Item -LiteralPath $script:Builder -Destination (Join-Path $delivery 'New-IntunePackage.ps1')
        foreach ($file in @('Config.psd1', 'Core.Provisioning.psm1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $script:Repo "src\CorePackage\$file") -Destination $coreSource
        }
        foreach ($file in $script:ModuleFiles) {
            $destination = Join-Path $coreSource "Modules\$file"
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item -LiteralPath (Join-Path $script:Repo "src\Client\$file") -Destination $destination
        }
        foreach ($version in @('1.8', '1.9')) {
            $tools = Join-Path $delivery "Tools\$version"
            $null = New-Item -ItemType Directory -Path $tools -Force
            Copy-Item -LiteralPath $script:Tool -Destination (Join-Path $tools 'IntuneWinAppUtil.exe')
        }

        { & (Join-Path $delivery 'New-IntunePackage.ps1') `
                -FrontendUrl 'https://example.invalid/api/submit' -OutputRoot $script:Output } |
            Should -Throw '*Found 2 copies*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'rejects a Core and module version mismatch before checking the utility' {
        $delivery = Join-Path $TestDrive 'Mismatch\2-Intune'
        $coreSource = Join-Path $delivery 'CoreSource'
        $null = New-Item -ItemType Directory -Path (Join-Path $coreSource 'Modules') -Force
        Copy-Item -LiteralPath $script:Builder -Destination (Join-Path $delivery 'New-IntunePackage.ps1')
        foreach ($file in @('Config.psd1', 'Core.Provisioning.psm1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $script:Repo "src\CorePackage\$file") -Destination $coreSource
        }
        foreach ($file in $script:ModuleFiles) {
            $destination = Join-Path $coreSource "Modules\$file"
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item -LiteralPath (Join-Path $script:Repo "src\Client\$file") -Destination $destination
        }
        $configPath = Join-Path $coreSource 'Config.psd1'
        (Get-Content -LiteralPath $configPath -Raw).Replace(
            "PackageVersion = '$script:Version'", "PackageVersion = '9.9.9'") |
            Set-Content -LiteralPath $configPath

        { & (Join-Path $delivery 'New-IntunePackage.ps1') -IntuneWinAppUtilPath $script:Tool `
                -FrontendUrl 'https://example.invalid/api/submit' -OutputRoot $script:Output } |
            Should -Throw '*does not match the shared module version*'
        Should -Invoke Get-AuthenticodeSignature -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}
