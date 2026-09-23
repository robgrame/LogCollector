BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Detection = Join-Path $script:Repo 'scripts\Remediations\ApplicationLogging\Detect.ps1'
    $script:Remediation = Join-Path $script:Repo 'scripts\Remediations\ApplicationLogging\Remediate.ps1'
}

Describe 'Application logging remediation scripts' {
    It 'parses in Windows PowerShell and contains no embedded endpoint or credential' {
        foreach ($file in @($script:Detection, $script:Remediation)) {
            $tokens = $null
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref] $tokens, [ref] $errors)
            $errors.Count | Should -Be 0
            $text = Get-Content -LiteralPath $file -Raw
            $text | Should -Not -Match 'azurewebsites\.net'
            $text | Should -Not -Match '(?i)clientsecret|sharedkey|workspacekey|authorization'
        }
        (Get-Content -LiteralPath $script:Remediation -Raw) |
            Should -Match ([regex]::Escape("AbsolutePath -cne '/api/submit'"))
    }

    It 'reports a recent delivered probe as compliant' {
        $state = Join-Path $TestDrive 'recent.json'
        @{
            Delivered = $true
            LastSuccessUtc = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
            ExecutionId = [guid]::NewGuid().ToString('D')
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $state

        $output = & powershell.exe -NoProfile -File $script:Detection -StatePath $state -MaximumAgeHours 24
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'Application logging verified'
    }

    It 'reports a stale probe as noncompliant' {
        $state = Join-Path $TestDrive 'stale.json'
        @{
            Delivered = $true
            LastSuccessUtc = [DateTimeOffset]::UtcNow.AddHours(-25).ToString('o')
            ExecutionId = [guid]::NewGuid().ToString('D')
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $state

        $output = & powershell.exe -NoProfile -File $script:Detection -StatePath $state -MaximumAgeHours 24
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'stale'
    }

    It 'writes state only after the intake reports delivery' -ForEach @(
        @{ Disposition = 'Delivered'; Delivered = $true; ShouldSucceed = $true },
        @{ Disposition = 'Deferred'; Delivered = $false; ShouldSucceed = $false }
    ) {
        $moduleRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $versionRoot = Join-Path $moduleRoot '1.8.1'
        $null = New-Item -ItemType Directory -Path $versionRoot -Force
        @'
function Get-LogCollectorEndpointConfiguration {
    [pscustomobject]@{ SubmissionEnabled = $true }
}
function Get-LogCollectorConfigurationPath {
    Join-Path $env:TEMP 'missing-logcollector-test-config.psd1'
}
function Send-LogCollectorData {
    param($FrontendUrl, $TableName, $Records, $Source, $SpoolRoot, $SkipDrain)
    Add-Content -LiteralPath $env:LOGCOLLECTOR_TEST_CALLS -Value (@($Records).Count)
    [pscustomobject]@{
        Disposition = $env:LOGCOLLECTOR_TEST_DISPOSITION
        StatusCode = 202
        Message = 'test'
    }
}
Export-ModuleMember -Function Get-LogCollectorEndpointConfiguration, Get-LogCollectorConfigurationPath, Send-LogCollectorData
'@ | Set-Content -LiteralPath (Join-Path $versionRoot 'LogCollector.Client.psm1')
        @'
function Assert-SpoolHierarchy {
    param($Path, [switch] $Directory, [switch] $AllowMissing, [switch] $Create)
    if ($Directory -and $Create) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
    return $true
}
function Write-SpoolFile {
    param($Path, $Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}
'@ | Set-Content -LiteralPath (Join-Path $versionRoot 'InventorySpool.psm1')
        @{
            RootModule = 'LogCollector.Client.psm1'
            ModuleVersion = '1.8.1'
            GUID = 'a0c19236-04bd-4dc5-8865-32dfa32d1637'
            FunctionsToExport = @('Get-LogCollectorEndpointConfiguration', 'Get-LogCollectorConfigurationPath',
                'Send-LogCollectorData')
        } | ForEach-Object {
            New-ModuleManifest -Path (Join-Path $versionRoot 'LogCollector.Client.psd1') @_
        }

        $state = Join-Path $TestDrive "$Disposition.json"
        $calls = Join-Path $TestDrive "$Disposition-calls.txt"
        $env:LOGCOLLECTOR_TEST_DISPOSITION = $Disposition
        $env:LOGCOLLECTOR_TEST_DELIVERED = $Delivered.ToString().ToLowerInvariant()
        $env:LOGCOLLECTOR_TEST_CALLS = $calls
        try {
            if ($ShouldSucceed) {
                $output = & $script:Remediation -ModuleRoot $moduleRoot -StatePath $state `
                    -FrontendUrl 'https://example.invalid/api/submit' -SpoolRoot (Join-Path $TestDrive 'spool') `
                    -EventCount 12 -BatchSize 5 -DelayMilliseconds 0
                Test-Path -LiteralPath $state -PathType Leaf | Should -BeTrue
                $saved = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
                $saved.Delivered | Should -BeTrue
                $saved.EventCount | Should -Be 12
                $saved.BatchCount | Should -Be 3
                @(Get-Content -LiteralPath $calls) | Should -Be @('5', '5', '2')
                ($output -join "`n") | Should -Match 'Events=12; Batches=3'
            }
            else {
                { & $script:Remediation -ModuleRoot $moduleRoot -StatePath $state `
                        -FrontendUrl 'https://example.invalid/api/submit' -SpoolRoot (Join-Path $TestDrive 'spool') `
                        -EventCount 12 -BatchSize 5 -DelayMilliseconds 0 } |
                    Should -Throw '*batch 1 of 3 was not accepted*'
                Test-Path -LiteralPath $state | Should -BeFalse
            }
        }
        finally {
            Remove-Item Env:\LOGCOLLECTOR_TEST_DISPOSITION -ErrorAction SilentlyContinue
            Remove-Item Env:\LOGCOLLECTOR_TEST_DELIVERED -ErrorAction SilentlyContinue
            Remove-Item Env:\LOGCOLLECTOR_TEST_CALLS -ErrorAction SilentlyContinue
            Get-Module LogCollector.Client -All | Remove-Module -Force -ErrorAction SilentlyContinue
        }
    }
}
