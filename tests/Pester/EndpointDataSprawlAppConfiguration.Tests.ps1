BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:MainBicep = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'infra\main.bicep'))
    $script:Parameters = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'infra\logcollector.bicepparam'))
    $script:Workflow = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot '.github\workflows\deploy.yml'))
    $script:FrontendProgram = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Frontend\Program.cs'))
    $script:WorkerProgram = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Worker\Program.cs'))
    $script:FrontendProject = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Frontend\LogCollector.Frontend.csproj'))
    $script:WorkerProject = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Worker\LogCollector.Worker.csproj'))
}

Describe 'Endpoint Data Sprawl App Configuration' {
    It 'provisions a deterministic standalone store with a unified override' {
        $script:MainBicep | Should -Match (
            "param endpointDataSprawlAppConfigurationName string = ''")
        $script:MainBicep | Should -Match (
            "param endpointDataSprawlAppConfigurationLabel string = 'prod'")
        $script:MainBicep | Should -Match (
            "'appcs-edsr-\`$\{take\(uniqueString\(subscription\(\)\.id, resourceGroup\(\)\.id, customerPrefixSafe\), 13\)\}'")
        $script:MainBicep | Should -Match (
            'Microsoft\.AppConfiguration/configurationStores@2024-05-01')
        $script:MainBicep | Should -Match 'disableLocalAuth: true'
        $script:MainBicep | Should -Match "authenticationMode: 'Pass-through'"
        $script:MainBicep | Should -Match "name: 'standard'"
        $script:Workflow | Should -Match (
            'ENDPOINT_DATA_SPRAWL_APP_CONFIGURATION_NAME: appcs-mslabs-edsr-prod')
        $script:Workflow | Should -Match (
            'ENDPOINT_DATA_SPRAWL_APP_CONFIGURATION_LABEL: prod')
        $script:Parameters | Should -Match (
            "param endpointDataSprawlAppConfigurationName = ''")
        $script:Parameters | Should -Match (
            "param endpointDataSprawlAppConfigurationLabel = 'prod'")
        $script:MainBicep | Should -Match (
            'var endpointDataSprawlConfigurationEnabled = userSessionEnabled \|\| sqlPersistenceEnabled')
        $script:MainBicep | Should -Match (
            'resource endpointDataSprawlAppConfiguration[\s\S]*= if \(endpointDataSprawlConfigurationEnabled\)')
        $script:MainBicep | Should -Match (
            'resource endpointDataSprawlKeyVault[\s\S]*= if \(userSessionEnabled\)')
    }

    It 'creates the exact labeled non-secret key set' {
        $script:MainBicep | Should -Not -Match "format\('\{0\}\$\{1\}'"
        $script:MainBicep |
            Should -Match "var appConfigurationLabelSeparator = '\$'"
        @(
            'EndpointDataSprawl:UserSession:TenantId'
            'EndpointDataSprawl:UserSession:Audience'
            'EndpointDataSprawl:UserSession:RequiredScope'
            'EndpointDataSprawl:UserSession:MetadataAddress'
            'EndpointDataSprawl:UserSession:RegistrationTtlMinutes'
            'EndpointDataSprawl:UserSession:TableName'
            'EndpointDataSprawl:SqlPersistence:RetentionDays'
            'EndpointDataSprawl:SqlPersistence:PlacementRetentionDays'
        ) | ForEach-Object {
            $script:MainBicep | Should -Match ([Regex]::Escape($_))
        }

        ([Regex]::Matches(
            $script:MainBicep,
            [Regex]::Escape(
                '}${appConfigurationLabelSeparator}${endpointDataSprawlAppConfigurationLabel}'))).Count |
            Should -Be 8
        $script:MainBicep | Should -Not -Match 'appConfigurationKey.*Hmac'
        $script:MainBicep | Should -Not -Match 'appConfigurationKey.*ConnectionString'
    }

    It 'uses native references while retaining secret and invariant app settings' {
        ([Regex]::Matches(
            $script:MainBicep,
            '@Microsoft\.AppConfiguration\(Endpoint=')).Count |
            Should -Be 8
        $script:MainBicep | Should -Match (
            "name: 'UserSession__HmacKeyBase64'[\s\S]*@Microsoft\.KeyVault")
        $script:MainBicep | Should -Match (
            "name: 'SqlPersistence__ConnectionString'")
        $script:MainBicep | Should -Match (
            "name: 'SqlPersistence__Enabled', value: 'true'")
        $script:MainBicep | Should -Match (
            "name: 'SqlPersistence__TargetTableName', value: 'EndpointDataSprawlRemediator_CL'")
    }

    It 'grants data-reader access to apps and data-owner access to the deployment principal' {
        $script:MainBicep | Should -Match (
            "roleAppConfigurationDataReader[\s\S]*516239f1-63e1-4d78-a4de-a74fb236a071")
        $script:MainBicep | Should -Match (
            'resource raFrontendAppConfiguration[\s\S]*roleAppConfigurationDataReader')
        $script:MainBicep | Should -Match (
            'resource raWorkerAppConfiguration[\s\S]*roleAppConfigurationDataReader')
        $script:MainBicep | Should -Not -Match 'AppConfigurationDataOwner'
        $script:Workflow | Should -Match '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'
        $script:Workflow | Should -Match 'App Configuration Data Owner permission did not propagate'
    }

    It 'does not provision purpose-specific resources for a generic deployment' {
        $script:Parameters | Should -Not -Match 'EndpointDataSprawlRemediator_CL'
        $script:Parameters | Should -Match 'param includeEndpointDataSprawlTable = false'
        $script:MainBicep | Should -Match (
            'var endpointDataSprawlTelemetryEnabled = includeEndpointDataSprawlTable \|\| endpointDataSprawlConfigurationEnabled')
        $script:MainBicep | Should -Match (
            '!contains\(additionalTelemetryTableNames, endpointDataSprawlTelemetryTable\.name\)')
        $script:Workflow | Should -Match 'includeEndpointDataSprawlTable = \$true'
        $script:MainBicep | Should -Match (
            'resource userSessionTable[\s\S]*= if \(userSessionEnabled\)')
        $script:MainBicep | Should -Match (
            'resource raFrontendKeyVaultSecrets[\s\S]*= if \(userSessionEnabled\)')
        $script:MainBicep | Should -Match (
            'resource raFrontendAppConfiguration[\s\S]*= if \(userSessionEnabled\)')
        $script:MainBicep | Should -Match (
            'resource raWorkerAppConfiguration[\s\S]*= if \(sqlPersistenceEnabled\)')
        $script:MainBicep | Should -Match (
            "output endpointDataSprawlAppConfigurationName string = endpointDataSprawlConfigurationEnabled \?[\s\S]*: ''")
        $script:MainBicep | Should -Match (
            "output endpointDataSprawlKeyVaultName string = userSessionEnabled \?[\s\S]*: ''")
    }

    It 'publishes the exact store outputs' {
        $script:MainBicep | Should -Match (
            'output endpointDataSprawlAppConfigurationName string')
        $script:MainBicep | Should -Match (
            'output endpointDataSprawlAppConfigurationEndpoint string')
        $script:MainBicep | Should -Match (
            'output endpointDataSprawlAppConfigurationResourceId string')
        $script:Workflow | Should -Match (
            'outputs\.endpointDataSprawlAppConfigurationName\.value')
        $script:Workflow | Should -Match (
            'outputs\.endpointDataSprawlAppConfigurationEndpoint\.value')
        $script:Workflow | Should -Match (
            'outputs\.endpointDataSprawlAppConfigurationResourceId\.value')
    }

    It 'uses restart-based native references without an SDK refresh provider' {
        $script:FrontendProject | Should -Not -Match 'AzureAppConfiguration'
        $script:WorkerProject | Should -Not -Match 'AzureAppConfiguration'
        $script:FrontendProgram | Should -Not -Match 'AddAzureAppConfiguration'
        $script:WorkerProgram | Should -Not -Match 'AddAzureAppConfiguration'
        $script:FrontendProgram | Should -Not -Match 'UseAzureAppConfiguration'
        $script:WorkerProgram | Should -Not -Match 'UseAzureAppConfiguration'
    }
}
