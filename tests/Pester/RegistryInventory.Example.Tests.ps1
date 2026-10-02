Describe 'Registry inventory example' {
    BeforeAll {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $scriptPath = Join-Path $repoRoot 'scripts\Examples\RegistryInventory.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
    }

    It 'parses as valid PowerShell' {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref] $tokens,
            [ref] $errors)

        @($errors).Count | Should -Be 0
    }

    It 'uses LogCollector for inventory and both logging destinations' {
        $content | Should -Match 'Send-LogAnalyticsData'
        $content | Should -Match 'Write-CMTraceLog'
        $content | Should -Match 'Send-LogCollectorOperationalEvent'
    }

    It 'uses only valid parameters for the public LogCollector commands' {
        Import-Module (Join-Path $repoRoot 'src\Client\LogCollector.Client.psd1') -Force
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref] $null,
            [ref] $null)

        foreach ($commandName in @(
                'Write-CMTraceLog',
                'Send-LogCollectorOperationalEvent',
                'Send-LogAnalyticsData')) {
            $validParameters = (Get-Command $commandName).Parameters.Keys
            $commands = $ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $commandName
                }, $true)

            foreach ($command in $commands) {
                foreach ($parameter in @($command.CommandElements |
                        Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
                    $validParameters | Should -Contain $parameter.ParameterName
                }
            }
        }
    }

    It 'limits the default collection to named non-binary values' {
        $content | Should -Match ([regex]::Escape(
                "ValueName = @('ProductName', 'DisplayVersion')"))
        $content | Should -Match ([regex]::Escape(
                'foreach ($requestedValueName in $ValueName)'))
    }

    It 'logs a deferred submission as a centralized warning' {
        $key = [pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValueNames { @('ProductName') }
        $key | Add-Member ScriptMethod GetValueKind {
            [Microsoft.Win32.RegistryValueKind]::String
        }
        $key | Add-Member ScriptMethod GetValue { 'Windows 11 Pro' }

        Mock Get-Item { $key }
        Mock Import-Module {}
        Mock Write-CMTraceLog {}
        Mock Send-LogCollectorOperationalEvent {}
        Mock Send-LogAnalyticsData {
            [pscustomobject]@{
                Delivered = $false
                Disposition = 'Deferred'
                TableName = 'RegistryInventory_CL'
                RecordCount = 1
            }
        }

        $null = & $scriptPath -RegistryPath 'HKLM:\SOFTWARE\Example' -ValueName 'ProductName'

        Should -Invoke Send-LogCollectorOperationalEvent -Times 1 -ParameterFilter {
            $EventName -eq 'SubmissionDeferred' -and $Level -eq 'Warning'
        }
    }

    It 'does not submit when none of the requested values exists' {
        $key = [pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValueNames { @() }

        Mock Get-Item { $key }
        Mock Import-Module {}
        Mock Write-CMTraceLog {}
        Mock Send-LogCollectorOperationalEvent {}
        Mock Send-LogAnalyticsData {}

        $null = & $scriptPath -RegistryPath 'HKLM:\SOFTWARE\Example' -ValueName 'MissingValue'

        Should -Invoke Send-LogAnalyticsData -Times 0
        Should -Invoke Send-LogCollectorOperationalEvent -Times 1 -ParameterFilter {
            $EventName -eq 'RegistryValueMissing' -and $Level -eq 'Warning'
        }
        Should -Invoke Send-LogCollectorOperationalEvent -Times 1 -ParameterFilter {
            $EventName -eq 'CollectionCompleted' -and $Level -eq 'Warning'
        }
    }
}
