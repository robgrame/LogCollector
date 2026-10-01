BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:MainBicepPath = Join-Path $script:RepoRoot 'infra\main.bicep'
    $script:ParameterPath = Join-Path $script:RepoRoot 'infra\logcollector.bicepparam'
    $script:SchemaPath = Join-Path $script:RepoRoot 'infra\sql\001-endpoint-data-sprawl.sql'
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github\workflows\deploy.yml'
    $script:InitializerScriptPath = Join-Path $script:RepoRoot 'scripts\Initialize-EndpointDataSprawlDatabase.ps1'
    $script:InitializerProjectPath = Join-Path $script:RepoRoot 'tools\LogCollector.DatabaseInitializer\Program.cs'

    $script:MainBicep = [IO.File]::ReadAllText($script:MainBicepPath)
    $script:Parameters = [IO.File]::ReadAllText($script:ParameterPath)
    $script:Schema = [IO.File]::ReadAllText($script:SchemaPath)
    $script:Workflow = [IO.File]::ReadAllText($script:WorkflowPath)
    $script:InitializerScript = [IO.File]::ReadAllText($script:InitializerScriptPath)
    $script:InitializerProject = [IO.File]::ReadAllText($script:InitializerProjectPath)
}

Describe 'Endpoint Data Sprawl Azure SQL persistence' {
    It 'provisions an Entra-only serverless database without SQL credentials' {
        $script:MainBicep | Should -Match "azureADOnlyAuthentication: true"
        $script:MainBicep | Should -Match "name: 'GP_S_Gen5'"
        $script:MainBicep | Should -Match "minCapacity: json\('0.5'\)"
        $script:MainBicep | Should -Not -Match 'administratorLogin'
        $script:MainBicep | Should -Not -Match 'administratorLoginPassword'
    }

    It 'configures the worker for managed-identity SQL authentication' {
        $script:MainBicep | Should -Match 'Authentication=Active Directory Managed Identity'
        $script:MainBicep | Should -Match 'User Id=\$\{workerIdentity\.properties\.clientId\}'
        $script:MainBicep | Should -Match "SqlPersistence__TargetTableName"
        $script:Parameters | Should -Match 'param sqlPersistenceEnabled = false'
        $script:Workflow | Should -Match 'sqlPersistenceEnabled = \$true'
    }

    It 'defines the idempotent ledger and durable read-model tables' {
        foreach ($table in @(
                'IngestionSubmissions',
                'FileEvents',
                'MigrationCycles',
                'FilePlacements')) {
            $script:Schema | Should -Match ([regex]::Escape("dbo.$table"))
        }

        $script:Schema | Should -Match 'UQ_FileEvents_SubmissionRecord'
        $script:Schema | Should -Match 'PayloadSha256 <> @PayloadSha256'
        $script:Schema | Should -Match "THROW 51001"
        $script:Schema | Should -Match 'LogAnalyticsState tinyint'
        $script:Schema | Should -Match 'LogAnalyticsState IN \(0, 1, 2\)'
        $script:Schema | Should -Match 'BeginEndpointDataSprawlLogAnalyticsPublish'
        $script:Schema | Should -Match 'ResetEndpointDataSprawlLogAnalyticsPublish'
        $script:Schema | Should -Match 'CONCAT\(@SubmissionId'
        $script:Schema | Should -Match 'COMMIT TRANSACTION;\s*RETURN;'
        $script:Schema | Should -Match "UserCorrelationId nvarchar\(128\) '\$\.UserCorrelationId'"
    }

    It 'scopes placements by device and uses server timestamps for precedence and retention' {
        $script:Schema | Should -Match 'PRIMARY KEY\s*\(UserCorrelationId, EntraDeviceId, DestinationPathHash\)'
        $script:Schema | Should -Match 'target\.EntraDeviceId = @EntraDeviceId'
        $script:Schema | Should -Match '@AcceptedAtUtc >= target\.AcceptedAtUtc'
        $script:Schema | Should -Match 'BETWEEN DATEADD\(day, -30, @AcceptedAtUtc\)'
        $script:Schema | Should -Match 'WHERE UpdatedAtUtc < @Cutoff'
        $script:Schema | Should -Match 'events\.InsertedAtUtc < @Cutoff'
        $script:Schema | Should -Match 'WHERE AcceptedAtUtc < @Cutoff'
        $script:Schema | Should -Not -Match 'WHERE EventTimeUtc < @Cutoff'
        $script:Schema | Should -Match 'DELETE TOP \(5000\)'
        $script:Schema | Should -Match 'Latin1_General_100_BIN2'
    }

    It 'grants the worker only stored-procedure execution through a database role' {
        $script:Schema | Should -Match 'CREATE ROLE endpoint_data_sprawl_ingestor'
        $script:Schema | Should -Match 'GRANT EXECUTE ON dbo.PersistEndpointDataSprawlBatch'
        $script:Schema | Should -Match 'GRANT EXECUTE ON dbo.BeginEndpointDataSprawlLogAnalyticsPublish'
        $script:Schema | Should -Match 'GRANT EXECUTE ON dbo.MarkEndpointDataSprawlLogAnalyticsPublished'
        $script:Schema | Should -Match 'GRANT EXECUTE ON dbo.ResetEndpointDataSprawlLogAnalyticsPublish'
        $script:Schema | Should -Match 'GRANT EXECUTE ON dbo.PurgeEndpointDataSprawlHistory'
        $script:Schema | Should -Not -Match 'db_owner'
        $script:Schema | Should -Not -Match 'db_datawriter'
        $script:Schema | Should -Not -Match 'FROM EXTERNAL PROVIDER'
        $script:Schema | Should -Match 'WITH SID = 0x__WORKER_IDENTITY_SID_HEX__, TYPE = E'
    }

    It 'initializes the schema after infrastructure deployment' {
        $script:Workflow | Should -Match 'Initialize Endpoint Data Sprawl database'
        $script:Workflow | Should -Match 'Initialize-EndpointDataSprawlDatabase.ps1'
        $script:Workflow | Should -Match 'sql_entra_admin_object_id'
        $script:InitializerScript | Should -Match 'firewall-rule create'
        $script:InitializerScript | Should -Match 'firewall-rule delete'
        $deleteBlock = [regex]::Match(
            $script:InitializerScript,
            '(?s)az sql server firewall-rule delete.*?if \(\$LASTEXITCODE -ne 0\)')
        $deleteBlock.Success | Should -BeTrue
        $deleteBlock.Value | Should -Not -Match '--yes'
        $script:InitializerScript | Should -Match 'Failed to remove temporary SQL firewall rule'
        $script:InitializerScript | Should -Match 'Database initialization and firewall cleanup both failed'
        $script:InitializerScript | Should -Not -Match 'az sql db query'
        $script:InitializerProject | Should -Match 'ActiveDirectoryDefault'
        $script:InitializerProject | Should -Match 'worker-identity-client-id'
        $script:InitializerProject | Should -Match 'Regex.Split'
        $script:Workflow | Should -Match 'worker_identity_client_id'
        $script:Workflow | Should -Not -Match 'worker_identity_principal_id'
        $script:Workflow | Should -Match 'secrets\.AZURE_DEPLOYMENT_OBJECT_ID'
        $script:Workflow | Should -Match 'secrets\.AZURE_DEPLOYMENT_NAME'
        $script:Workflow | Should -Not -Match 'inputs\.sql_entra_admin'
    }
}
