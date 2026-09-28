<#
.SYNOPSIS
    Pester tests for scripts\New-CustomerInventorySchema.ps1.

.DESCRIPTION
    Covers both input modes (sample JSON and live collector script capture), the type
    inference rules, the secret/PII name detector, and that no Azure/network/DCR state is
    ever touched by the tool.
#>

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Tool = Join-Path $script:Repo 'scripts\New-CustomerInventorySchema.ps1'
}

Describe 'New-CustomerInventorySchema' {
    It 'parses cleanly and does not embed any Azure endpoint or credential' {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $text = Get-Content -LiteralPath $script:Tool -Raw
        $text | Should -Not -Match 'azurewebsites\.net'
        $text | Should -Not -Match '(?i)sharedkey|workspacekey|az login|Connect-AzAccount'
    }

    Context 'FromSample mode' {
        BeforeAll {
            $script:SampleDir = Join-Path $TestDrive 'sample'
            $null = New-Item -ItemType Directory -Path $script:SampleDir -Force
            $script:SamplePath = Join-Path $script:SampleDir 'sample.json'
            @(
                [pscustomobject]@{
                    AssetTag        = 'A-0001'
                    UnitCount       = 3
                    SerialLarge     = 5000000000
                    Ratio           = 0.5
                    IsCompliant     = $true
                    ObservedAtUtc   = '2026-01-01T00:00:00.0000000Z'
                    Details         = @{ Foo = 'Bar' }
                }
            ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:SamplePath -Encoding utf8
        }

        It 'infers int, long, real, boolean, datetime and dynamic column types' {
            $outDir = Join-Path $TestDrive 'out1'
            $result = & $script:Tool -SchemaSampleJsonPath $script:SamplePath -TableName 'AssetTagInventory_CL' `
                -Source 'AssetTagCollector' -OutputDirectory $outDir

            $result.BicepEntryWritten | Should -BeTrue
            ($result.CustomColumns | Where-Object Name -eq 'AssetTag').Type | Should -Be 'string'
            ($result.CustomColumns | Where-Object Name -eq 'UnitCount').Type | Should -Be 'int'
            ($result.CustomColumns | Where-Object Name -eq 'SerialLarge').Type | Should -Be 'long'
            ($result.CustomColumns | Where-Object Name -eq 'Ratio').Type | Should -Be 'real'
            ($result.CustomColumns | Where-Object Name -eq 'IsCompliant').Type | Should -Be 'boolean'
            ($result.CustomColumns | Where-Object Name -eq 'ObservedAtUtc').Type | Should -Be 'datetime'
            ($result.CustomColumns | Where-Object Name -eq 'Details').Type | Should -Be 'dynamic'

            $bicepText = Get-Content -LiteralPath $result.BicepEntryPath -Raw
            $bicepText | Should -Match "name: 'AssetTagInventory_CL'"
            $bicepText | Should -Match "name: 'TimeGenerated', type: 'datetime'"
            $bicepText | Should -Match "name: 'UnitCount', type: 'int'"

            $reportText = Get-Content -LiteralPath $result.ReportPath -Raw
            $reportText | Should -Match 'AssetTagInventory_CL'
            $reportText | Should -Match 'additionalTelemetryTables'
        }

        It 'does not touch Azure, git or any file outside OutputDirectory' {
            $outDir = Join-Path $TestDrive 'out-isolated'
            $before = Get-ChildItem -Path $script:Repo -Recurse -File | Select-Object -ExpandProperty FullName
            & $script:Tool -SchemaSampleJsonPath $script:SamplePath -TableName 'AssetTagInventory_CL' `
                -Source 'AssetTagCollector' -OutputDirectory $outDir | Out-Null
            $after = Get-ChildItem -Path $script:Repo -Recurse -File | Select-Object -ExpandProperty FullName
            Compare-Object -ReferenceObject $before -DifferenceObject $after | Should -BeNullOrEmpty
        }
    }

    Context 'Secret/PII detection' {
        BeforeAll {
            $script:SecretSampleDir = Join-Path $TestDrive 'secret-sample'
            $null = New-Item -ItemType Directory -Path $script:SecretSampleDir -Force
            $script:SecretSamplePath = Join-Path $script:SecretSampleDir 'sample.json'
            @(
                [pscustomobject]@{ AssetTag = 'A-0001'; ApiToken = 'abc123' }
            ) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:SecretSamplePath -Encoding utf8
        }

        It 'withholds the bicep entry and warns when a likely-secret column name is present' {
            $outDir = Join-Path $TestDrive 'out-secret'
            $result = & $script:Tool -SchemaSampleJsonPath $script:SecretSamplePath -TableName 'AssetTagInventory_CL' `
                -Source 'AssetTagCollector' -OutputDirectory $outDir -WarningAction SilentlyContinue

            $result.SecretColumns | Should -Contain 'ApiToken'
            $result.BicepEntryWritten | Should -BeFalse
            $result.BicepEntryPath | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $outDir 'AssetTagInventory_CL-bicep-entry.txt') | Should -BeFalse
            $reportText = Get-Content -LiteralPath $result.ReportPath -Raw
            $reportText | Should -Match 'ApiToken'

            $sampleText = Get-Content -LiteralPath $result.SchemaSamplePath -Raw
            $sampleText | Should -Not -Match 'abc123'
            $sampleText | Should -Match 'redacted'
        }

        It 'still emits the bicep entry with -Force after a secret-name detection' {
            $outDir = Join-Path $TestDrive 'out-secret-force'
            $result = & $script:Tool -SchemaSampleJsonPath $script:SecretSamplePath -TableName 'AssetTagInventory_CL' `
                -Source 'AssetTagCollector' -OutputDirectory $outDir -Force -WarningAction SilentlyContinue

            $result.BicepEntryWritten | Should -BeTrue
            Test-Path -LiteralPath $result.BicepEntryPath | Should -BeTrue

            $sampleText = Get-Content -LiteralPath $result.SchemaSamplePath -Raw
            $sampleText | Should -Match 'abc123'
        }

        It 'redacts a secret-like key nested inside a dynamic (object) column, not just top-level column names' {
            $sampleDir = Join-Path $TestDrive 'nested-secret-sample'
            $null = New-Item -ItemType Directory -Path $sampleDir -Force
            $samplePath = Join-Path $sampleDir 'sample.json'
            @(
                [pscustomobject]@{
                    AssetTag = 'A-0001'
                    Metadata = [pscustomobject]@{ Region = 'eu'; Password = 'nested-secret-value' }
                }
            ) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $samplePath -Encoding utf8

            $outDir = Join-Path $TestDrive 'out-nested-secret'
            $result = & $script:Tool -SchemaSampleJsonPath $samplePath -TableName 'AssetTagInventory_CL' `
                -Source 'AssetTagCollector' -OutputDirectory $outDir -WarningAction SilentlyContinue

            $sampleText = Get-Content -LiteralPath $result.SchemaSamplePath -Raw
            $sampleText | Should -Not -Match 'nested-secret-value'
            $sampleText | Should -Match 'redacted'
            $sampleText | Should -Match 'eu'
        }
    }

    Context 'Unsafe column names' {
        It 'rejects a column name that is not a valid Bicep/DCR identifier instead of emitting broken or injected Bicep' {
            $sampleDir = Join-Path $TestDrive 'unsafe-name'
            $null = New-Item -ItemType Directory -Path $sampleDir -Force
            $samplePath = Join-Path $sampleDir 'sample.json'
            @(
                [pscustomobject]@{ "bad' } //injected" = 'x' }
            ) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $samplePath -Encoding utf8

            { & $script:Tool -SchemaSampleJsonPath $samplePath -TableName 'AssetTagInventory_CL' `
                -Source 'AssetTagCollector' -OutputDirectory (Join-Path $TestDrive 'unsafe-name-out') } |
                Should -Throw -ExpectedMessage '*valid Azure Monitor/Bicep identifier*'
        }
    }

    Context 'FromScript mode' {
        BeforeAll {
            $script:ScriptDir = Join-Path $TestDrive 'collector'
            $null = New-Item -ItemType Directory -Path $script:ScriptDir -Force
            $script:CollectorScriptPath = Join-Path $script:ScriptDir 'Collect-AssetTags.ps1'
            @'
[CmdletBinding()]
param(
    [switch] $ExportSchema,
    [Uri] $FrontendUrl
)

Import-Module 'C:\Program Files\LogCollector\Modules\LogCollector.Client\1.5.0\LogCollector.Client.psd1' -ErrorAction Stop

$records = @(
    [pscustomobject]@{
        AssetTag  = 'A-0001'
        UnitCount = 7
    }
)

if ($ExportSchema) {
    Export-LogCollectorSchema -TableName 'AssetTagInventory_CL' -Source 'AssetTagCollector' `
        -Records $records -OutputPath '.\schema.json' -Force
    return
}

Send-LogCollectorData -FrontendUrl $FrontendUrl -TableName 'AssetTagInventory_CL' `
    -Source 'AssetTagCollector' -Records $records
'@ | Set-Content -LiteralPath $script:CollectorScriptPath -Encoding utf8
        }

        It 'captures records from a real collector script without any Azure module installed' {
            $outDir = Join-Path $TestDrive 'out-from-script'
            $result = & $script:Tool -CollectorScriptPath $script:CollectorScriptPath -TableName 'AssetTagInventory_CL' `
                -Source 'AssetTagCollector' -OutputDirectory $outDir

            $result.RecordCount | Should -Be 1
            ($result.CustomColumns | Where-Object Name -eq 'AssetTag').Type | Should -Be 'string'
            ($result.CustomColumns | Where-Object Name -eq 'UnitCount').Type | Should -Be 'int'
            $result.BicepEntryWritten | Should -BeTrue
        }
    }
}
