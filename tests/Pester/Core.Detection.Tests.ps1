BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:DetectionPath = Join-Path $script:RepoRoot 'src\CorePackage\Detect.ps1'
    $script:PublisherPath = Join-Path $script:RepoRoot 'scripts\Publish-CustomerDeliverable.ps1'

    $tokens = $null
    $errors = $null
    $detectionAst = [Management.Automation.Language.Parser]::ParseFile(
        $script:DetectionPath, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw ($errors.Message -join '; ') }
    $comparisonFunction = $detectionAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-ExpectedLogCollectorConfiguration'
        }, $true)
    Invoke-Expression $comparisonFunction.Extent.Text

    $publisherText = [IO.File]::ReadAllText($script:PublisherPath)
    $generatorMatch = [regex]::Match($publisherText,
        "(?s)\`$intuneGenerator = @'\r?\n(.*?)\r?\n'@\r?\n" +
        "\[IO\.File\]::WriteAllText\(\(Join-Path \`$intune 'New-IntunePackage\.ps1'\)")
    if (-not $generatorMatch.Success) { throw 'Could not extract the generated New-IntunePackage.ps1 template.' }
    $generatorText = $generatorMatch.Groups[1].Value
    $script:GeneratorText = $generatorText
    $tokens = $null
    $errors = $null
    $generatorAst = [Management.Automation.Language.Parser]::ParseInput(
        $generatorText, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw ($errors.Message -join '; ') }
    $payloadFunction = $generatorAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertTo-CoreDetectionPayload'
        }, $true)
    Invoke-Expression $payloadFunction.Extent.Text

    $script:Configuration = @{
        FrontendUrl                   = 'https://example.invalid/api/submit'
        Environment                   = 'Production'
        CustomerName                  = 'Example'
        SubmissionEnabled             = $true
        PackageVersion                = '1.7.1'
        CertificateThumbprint         = ''
        CertificateSubjectLike        = ''
        CertificateIssuerLike         = ''
        PkiRootCaThumbprints           = @((('A' * 40) -join ''))
        PkiRootCaSubjects              = @('CN=Example Root')
        PkiIntermediateCaThumbprints   = @()
        PkiIntermediateCaSubjects      = @('CN=Example Issuing CA')
    }
}

Describe 'Core package configuration-bound detection' {
    It 'keeps the generated builder Core-only' {
        foreach ($legacyToken in @(
                'ClientSource',
                'InventoryPackage',
                'DeviceTableName',
                'AppTableName',
                'EnableSubmission')) {
            $script:GeneratorText | Should -Not -Match ([regex]::Escape($legacyToken))
        }

        ([regex]::Matches($script:GeneratorText, '(?m)^\$coreProcess = Start-Process ')).Count |
            Should -Be 1
        ([regex]::Matches($script:GeneratorText, '(?m)^\[pscustomobject\]@\{')).Count |
            Should -Be 1
        $script:GeneratorText | Should -Match ([regex]::Escape(
                "`$coreStaging = Join-Path `$release 'Source'"))
        $script:GeneratorText | Should -Match ([regex]::Escape(
                "`$coreOutput = Join-Path `$release 'Package'"))
    }

    It 'publishes only the Core package version in the customer manifest' {
        $publisherText = [IO.File]::ReadAllText($script:PublisherPath)
        $publisherText | Should -Match 'CorePackageVersion\s*=\s*\$coreVersion'
        $publisherText | Should -Not -Match 'ClientPackageVersion'
        $publisherText | Should -Not -Match '\$clientVersion'
    }

    It 'wires the generated payload into the staged Core detection script' {
        $script:GeneratorText | Should -Match ([regex]::Escape(
                '$coreDetectionPayload = ConvertTo-CoreDetectionPayload -Configuration $coreConfig'))
        $script:GeneratorText | Should -Match ([regex]::Escape(
                '$coreDetection = $coreDetection.Replace($coreDetectionMarker, $coreDetectionPayload)'))
        $script:GeneratorText | Should -Match 'Core detection template is missing its expected-configuration marker'
    }

    It 'matches the exact generated configuration' {
        $payload = ConvertTo-CoreDetectionPayload -Configuration $script:Configuration
        $expected = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json
        $actual = [pscustomobject] $script:Configuration

        Test-ExpectedLogCollectorConfiguration -Actual $actual -Expected $expected |
            Should -BeTrue
    }

    It 'rejects scalar configuration drift' {
        foreach ($key in @('FrontendUrl', 'Environment', 'CustomerName', 'PackageVersion')) {
            $changed = @{} + $script:Configuration
            $changed[$key] = [string] $changed[$key] + '-changed'

            Test-ExpectedLogCollectorConfiguration -Actual ([pscustomobject] $changed) `
                -Expected ([pscustomobject] $script:Configuration) | Should -BeFalse
        }

        $changed = @{} + $script:Configuration
        $changed.SubmissionEnabled = $false
        Test-ExpectedLogCollectorConfiguration -Actual ([pscustomobject] $changed) `
            -Expected ([pscustomobject] $script:Configuration) | Should -BeFalse
    }

    It 'compares PKI lists semantically and rejects changed entries' {
        $equivalent = @{} + $script:Configuration
        $equivalent.PkiRootCaThumbprints = @(
            ($script:Configuration.PkiRootCaThumbprints[0] -replace '(.{2})(?=.)', '$1:').
                ToLowerInvariant())
        $equivalent.PkiIntermediateCaSubjects = @('CN=Example Issuing CA')

        Test-ExpectedLogCollectorConfiguration -Actual ([pscustomobject] $equivalent) `
            -Expected ([pscustomobject] $script:Configuration) | Should -BeTrue

        $changed = @{} + $script:Configuration
        $changed.PkiRootCaSubjects = @('CN=Different Root')
        Test-ExpectedLogCollectorConfiguration -Actual ([pscustomobject] $changed) `
            -Expected ([pscustomobject] $script:Configuration) | Should -BeFalse
    }

    It 'encodes untrusted configuration as data rather than PowerShell source' {
        $malicious = @{} + $script:Configuration
        $malicious.Environment = "'; throw 'injected'; #"
        $payload = ConvertTo-CoreDetectionPayload -Configuration $malicious
        $payload | Should -Match '^[A-Za-z0-9+/]+={0,2}$'

        $template = [IO.File]::ReadAllText($script:DetectionPath)
        $generated = $template.Replace(
            '__LOGCOLLECTOR_CORE_EXPECTED_CONFIGURATION_BASE64__', $payload)
        $generated | Should -Not -Match ([regex]::Escape($malicious.Environment))

        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput(
            $generated, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0

        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json
        $decoded.Environment | Should -BeExactly $malicious.Environment
    }

    It 'requires every value used by the generated detection' {
        $incomplete = @{} + $script:Configuration
        $incomplete.Remove('CustomerName')
        { ConvertTo-CoreDetectionPayload -Configuration $incomplete } |
            Should -Throw "*CustomerName*"
    }
}
