BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Installer = Join-Path $script:Repo 'src\CorePackage\Install.ps1'
    $script:Readme = Join-Path $script:Repo 'src\CorePackage\README.md'
    $script:Text = Get-Content -LiteralPath $script:Installer -Raw
}

Describe 'Core installer diagnostics' {
    It 'parses and imports the bundled CMTrace logger before installation work' {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile(
            $script:Installer, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $script:Text | Should -Match ([regex]::Escape(
                "Join-Path `$PSScriptRoot 'Modules\CMTraceLogging.psm1'"))
        $script:Text | Should -Match 'function Write-CoreInstallLog'
        $script:Text | Should -Match '\$logApplicationName\s*=\s*''LogCollector'''
        $script:Text | Should -Not -Match '\$logApplicationName\s*=\s*''LogCollectorCore'''
        $script:Text.IndexOf('Install started; PackageVersion=') |
            Should -BeLessThan $script:Text.IndexOf('Is64BitProcess')
    }

    It 'records phase, error location and stack before rethrowing failures' {
        $script:Text | Should -Match 'Install failed; Phase=\$installPhase'
        $script:Text | Should -Match '\$failure\.InvocationInfo\.PositionMessage'
        $script:Text | Should -Match '\$failure\.ScriptStackTrace'
        $script:Text | Should -Match 'throw \$failure'
        $script:Text | Should -Match 'Rollback completed; PreviousVersionRestored=True'
        $script:Text | Should -Match 'Rollback failed; '
        $script:Text | Should -Match 'Endpoint configuration rollback failed:'
        $script:Text | Should -Match 'Module rollback failed:'
    }

    It 'records start, configuration and successful completion without credentials' {
        $script:Text | Should -Match 'Install started; PackageVersion='
        $script:Text | Should -Match 'Configuration validated; Endpoint='
        $script:Text | Should -Match 'Install completed; PackageVersion='
        $script:Text | Should -Not -Match '(?i)clientsecret|sharedkey|workspacekey|authorization'
    }

    It 'documents the stable local log path' {
        $readme = Get-Content -LiteralPath $script:Readme -Raw
        $readme | Should -Match ([regex]::Escape(
                '%ProgramData%\<CustomerName>\LogCollector\Logs\LogCollector.log'))
    }
}
