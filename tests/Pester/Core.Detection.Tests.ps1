BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:DetectionPath = Join-Path $script:RepoRoot 'src\CorePackage\Detect.ps1'
    $script:PublisherPath = Join-Path $script:RepoRoot 'scripts\Publish-CustomerDeliverable.ps1'
    $script:DeploymentPublisherPath = Join-Path $script:RepoRoot 'scripts\Publish-DeploymentPackage.ps1'
    $script:GraphPermissionPath = Join-Path $script:RepoRoot 'scripts\Grant-IntuneGraphPermission.ps1'
    $script:GeneratorPath = Join-Path $script:RepoRoot 'scripts\New-IntunePackage.ps1'

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
    . ([scriptblock]::Create($comparisonFunction.Extent.Text))

    $generatorText = [IO.File]::ReadAllText($script:GeneratorPath)
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
    . ([scriptblock]::Create($payloadFunction.Extent.Text))

    $script:Configuration = @{
        FrontendUrl                   = 'https://example.invalid/api/submit'
        Environment                   = 'Production'
        CustomerName                  = 'Example'
        SubmissionEnabled             = $true
        PackageVersion                = '1.10.2'
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

    It 'copies the canonical generator instead of embedding a second implementation' {
        $publisherText = [IO.File]::ReadAllText($script:PublisherPath)
        $publisherText | Should -Match ([regex]::Escape(
                "Copy-Item -LiteralPath `$generatorSource -Destination (Join-Path `$intune 'New-IntunePackage.ps1')"))
        $publisherText | Should -Not -Match '\$intuneGenerator\s*='
    }

    It 'documents optional Graph consent without bundling the administrative helper' {
        $publisherText = [IO.File]::ReadAllText($script:PublisherPath)
        $deploymentPublisherText = [IO.File]::ReadAllText($script:DeploymentPublisherPath)
        $mainBicep = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'infra\main.bicep'))
        $deploymentParameters = [IO.File]::ReadAllText(
            (Join-Path $script:RepoRoot 'infra\logcollector.bicepparam'))
        Test-Path -LiteralPath $script:GraphPermissionPath -PathType Leaf | Should -BeTrue
        $helperText = [IO.File]::ReadAllText($script:GraphPermissionPath)

        $deploymentPublisherText | Should -Not -Match ([regex]::Escape(
                "Copy-Item -LiteralPath `$graphPermissionSource"))
        $deploymentPublisherText | Should -Match 'Grant-IntuneGraphPermission\.ps1'
        $deploymentPublisherText | Should -Match 'Device\.Read\.All'
        $deploymentPublisherText | Should -Match 'intentionally \*\*not bundled\*\*'
        $deploymentPublisherText | Should -Match 'frontendIdentityName'
        $helperText | Should -Match 'Device\.Read\.All'
        $helperText | Should -Match 'appRoleAssignments'
        $publisherText | Should -Match 'Device\.Read\.All'
        $publisherText | Should -Match 'entraDeviceValidationEnabled = false'
        $mainBicep | Should -Match 'param entraDeviceValidationEnabled bool = true'
        $deploymentParameters | Should -Match 'param entraDeviceValidationEnabled = true'
        $mainBicep | Should -Match "healthCheckPath:\s*'/api/health'"
        $mainBicep | Should -Match "clientCertExclusionPaths:\s*''"
    }

    It 'generates detailed deployment logging without exposing subscription ids or tokens' {
        $deploymentPublisherText = [IO.File]::ReadAllText($script:DeploymentPublisherPath)
        foreach ($expected in @(
                'function Write-DeploymentLog',
                'function Protect-DeploymentLogValue',
                'Deployment started; ScriptVersion=1.3.0',
                'Starting Bicep deployment',
                'Starting Frontend package deployment',
                'Starting Worker package deployment',
                'Detailed log: $LogPath')) {
            $deploymentPublisherText | Should -Match ([regex]::Escape($expected))
        }
        $deploymentPublisherText | Should -Match '\[Diagnostics\.Stopwatch\]::StartNew\(\)'
        $deploymentPublisherText | Should -Match 'ParameterFileSha256='
        $deploymentPublisherText | Should -Match 'Get-Command az -CommandType Application -ErrorAction Stop \| Select-Object -First 1'
        $deploymentPublisherText | Should -Match '& \$azCommand\.Source deployment group create'
        $deploymentPublisherText | Should -Match '& \$azCommand\.Source functionapp stop'
        $deploymentPublisherText | Should -Match '& \$azCommand\.Source functionapp start'
        $deploymentPublisherText | Should -Match 'webapp config access-restriction add'
        $deploymentPublisherText | Should -Match 'webapp config access-restriction remove'
        $deploymentPublisherText | Should -Match '\$frontendDeploymentFailure\s*=\s*\$_'
        $deploymentPublisherText | Should -Match 'PrimaryErrorType='
        $deploymentPublisherText | Should -Match 'CleanupErrors='
        ([regex]::Matches($deploymentPublisherText,
                '(?s)finally\s*\{.*?try\s*\{.*?clientCertEnabled=true.*?\}\s*catch\s*\{')).Count |
            Should -BeGreaterThan 0
        $deploymentPublisherText.IndexOf('access-restriction add') |
            Should -BeLessThan $deploymentPublisherText.IndexOf('clientCertEnabled=false')
        $deploymentPublisherText.IndexOf('clientCertEnabled=true') |
            Should -BeLessThan $deploymentPublisherText.LastIndexOf('access-restriction remove')
        $deploymentPublisherText | Should -Match 'Protect-DeploymentLogValue \$SubscriptionId'
        $deploymentPublisherText | Should -Not -Match 'accessToken\s*='
        $deploymentPublisherText | Should -Not -Match 'Subscription=\$SubscriptionId'
    }

    It 'preserves relative module paths when creating the customer deliverable' {
        $publisherText = [IO.File]::ReadAllText($script:PublisherPath)
        $publisherText | Should -Match '\$moduleManifestData\s*=\s*Import-PowerShellDataFile'
        $publisherText | Should -Match 'foreach\s*\(\$file in \$moduleManifestData\.FileList\)'
        $publisherText | Should -Not -Match 'Split-Path \$file -Leaf'
    }

    It 'wires the generated payload into the staged Core detection script' {
        $script:GeneratorText | Should -Match ([regex]::Escape(
                '$coreDetectionPayload = ConvertTo-CoreDetectionPayload -Configuration $coreConfig'))
        $script:GeneratorText | Should -Match ([regex]::Escape(
                '$coreDetection = $coreDetection.Replace($coreDetectionMarker, $coreDetectionPayload)'))
        $script:GeneratorText | Should -Match 'Core detection template is missing its expected-configuration marker'
    }

    It 'emits non-sensitive reason codes when detection fails' {
        $text = Get-Content -LiteralPath $script:DetectionPath -Raw
        $text | Should -Match 'function Write-CoreDetectionFailure'
        $text | Should -Match "Write-CoreDetectionFailure -Reason 'ConfigurationMismatch'"
        $text | Should -Match "Write-CoreDetectionFailure -Reason 'ModuleDirectoryAclMismatch'"
        $text | Should -Not -Match 'Write-CoreDetectionFailure -Reason .*(FrontendUrl|CertificateThumbprint)'
    }

    It 'verifies the new installation before migrating legacy data' {
        $install = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\CorePackage\Install.ps1') -Raw
        $install.IndexOf("`$installPhase = 'VerifyInstallation'") |
            Should -BeLessThan $install.LastIndexOf("`$installPhase = 'MigrateLegacyData'")
        $install | Should -Match 'Assert-LogCollectorConfigurationTrust -Path \$Path'
        $install | Should -Match ([regex]::Escape("Get-LogCollectorEndpointConfiguration -Path '`$endpointPath'"))
        $install | Should -Match 'configurationBackup'
        $install | Should -Match 'configurationCreated'
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
