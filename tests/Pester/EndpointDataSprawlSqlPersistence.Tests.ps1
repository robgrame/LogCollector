BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:MainBicepPath = Join-Path $script:RepoRoot 'infra\main.bicep'
    $script:ParameterPath = Join-Path $script:RepoRoot 'infra\logcollector.bicepparam'
    $script:SchemaPath = Join-Path $script:RepoRoot 'infra\sql\001-endpoint-data-sprawl.sql'
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github\workflows\deploy.yml'
    $script:InitializerScriptPath = Join-Path $script:RepoRoot 'scripts\Initialize-EndpointDataSprawlDatabase.ps1'
    $script:InitializerProjectPath = Join-Path $script:RepoRoot 'tools\LogCollector.DatabaseInitializer\Program.cs'
    $script:InitializerOptionsPath = Join-Path $script:RepoRoot 'tools\LogCollector.DatabaseInitializer\DatabaseInitializationOptions.cs'

    $script:MainBicep = [IO.File]::ReadAllText($script:MainBicepPath)
    $script:Parameters = [IO.File]::ReadAllText($script:ParameterPath)
    $script:Schema = [IO.File]::ReadAllText($script:SchemaPath)
    $script:Workflow = [IO.File]::ReadAllText($script:WorkflowPath)
    $script:InitializerScript = [IO.File]::ReadAllText($script:InitializerScriptPath)
    $script:InitializerProject = (
        [IO.File]::ReadAllText($script:InitializerProjectPath) +
        [IO.File]::ReadAllText($script:InitializerOptionsPath))
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
        foreach ($column in @('FileName', 'Extension', 'SourceCreatedAtUtc', 'SourceModifiedAtUtc')) {
            $script:Schema | Should -Match ([regex]::Escape(
                "COL_LENGTH(N'dbo.FileEvents', N'$column')"))
            $script:Schema | Should -Match ([regex]::Escape(
                "COL_LENGTH(N'dbo.FilePlacements', N'$column')"))
            $script:Schema | Should -Match ([regex]::Escape("'`$.$column'"))
        }
        $script:Schema | Should -Match (
            'ALTER TABLE dbo\.FileEvents ALTER COLUMN Extension nvarchar\(64\) NULL')
        $script:Schema | Should -Match (
            'ALTER TABLE dbo\.FilePlacements ALTER COLUMN Extension nvarchar\(64\) NULL')
    }

    It 'scopes placements by device, preserves metadata, and retains placements longer than events' {
        $script:Schema | Should -Match 'PRIMARY KEY\s*\(UserCorrelationId, EntraDeviceId, DestinationPathHash\)'
        $script:Schema | Should -Match 'target\.EntraDeviceId = @EntraDeviceId'
        $script:Schema | Should -Match 'source\.UserCorrelationId IS NOT NULL'
        $script:Schema | Should -Match 'source\.DryRun = 0'
        $script:Schema | Should -Match '@AcceptedAtUtc >= target\.AcceptedAtUtc'
        $script:Schema | Should -Match 'BETWEEN DATEADD\(day, -30, @AcceptedAtUtc\)'
        $script:Schema | Should -Match '@PlacementRetentionDays int = 3650'
        $script:Schema | Should -Match '@PlacementRetentionDays <= @RetentionDays'
        $script:Schema | Should -Match (
            'DELETE TOP \(5000\) placements\s*FROM dbo\.FilePlacements')
        $script:Schema | Should -Match 'events\.InsertedAtUtc < @Cutoff'
        $script:Schema | Should -Match 'WHERE AcceptedAtUtc < @Cutoff'
        $script:Schema | Should -Not -Match 'WHERE EventTimeUtc < @Cutoff'
        $script:Schema | Should -Match 'DELETE TOP \(5000\)'
        $script:Schema | Should -Match 'Latin1_General_100_BIN2'
        foreach ($column in @(
                'FileName',
                'Extension',
                'SourceCreatedAtUtc',
                'SourceModifiedAtUtc')) {
            $script:Schema | Should -Match (
                "$column = COALESCE\(\s*source\.$column,\s*target\.$column\)")
        }
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

    It 'defines static dashboard procedures and an execute-only reader role' {
        $summaryProcedure = [regex]::Match(
            $script:Schema,
            '(?s)CREATE OR ALTER PROCEDURE dbo\.GetEndpointDataSprawlUserSummary.*?(?=\r?\nGO)').Value
        $deviceProcedure = [regex]::Match(
            $script:Schema,
            '(?s)CREATE OR ALTER PROCEDURE dbo\.GetEndpointDataSprawlUserDevices.*?(?=\r?\nGO)').Value
        $fileProcedure = [regex]::Match(
            $script:Schema,
            '(?s)CREATE OR ALTER PROCEDURE dbo\.GetEndpointDataSprawlUserDeviceFiles.*?(?=\r?\nGO)').Value

        $script:Schema | Should -Match 'GetEndpointDataSprawlUserSummary'
        $script:Schema | Should -Match 'GetEndpointDataSprawlUserDevices'
        $script:Schema | Should -Match 'GetEndpointDataSprawlUserDeviceFiles'
        $script:Schema | Should -Match (
            'CREATE OR ALTER PROCEDURE dbo\.GetEndpointDataSprawlUserSummary\s*' +
            '@UserCorrelationId char\(64\)')
        $script:Schema | Should -Match (
            'CREATE OR ALTER PROCEDURE dbo\.GetEndpointDataSprawlUserDevices\s*' +
            '@UserCorrelationId char\(64\)')
        $script:Schema | Should -Match (
            'CREATE OR ALTER PROCEDURE dbo\.GetEndpointDataSprawlUserDeviceFiles\s*' +
            '@UserCorrelationId char\(64\),\s*' +
            '@EntraDeviceId uniqueidentifier,\s*' +
            '@FileName nvarchar\(260\) = NULL,\s*' +
            '@Extension nvarchar\(64\) = NULL,\s*' +
            '@CreatedFromUtc datetimeoffset = NULL,\s*' +
            '@CreatedToUtc datetimeoffset = NULL,\s*' +
            '@ModifiedFromUtc datetimeoffset = NULL,\s*' +
            '@ModifiedToUtc datetimeoffset = NULL,\s*' +
            '@Offset int,\s*@PageSize int')
        $script:Schema | Should -Match '@UserCorrelationId char\(64\)'
        $script:Schema | Should -Match '@EntraDeviceId uniqueidentifier'
        $script:Schema | Should -Match '@FileName nvarchar\(260\) = NULL'
        $script:Schema | Should -Match '@Extension nvarchar\(64\) = NULL'
        $script:Schema | Should -Match '@CreatedFromUtc datetimeoffset = NULL'
        $script:Schema | Should -Match '@CreatedToUtc datetimeoffset = NULL'
        $script:Schema | Should -Match '@ModifiedFromUtc datetimeoffset = NULL'
        $script:Schema | Should -Match '@ModifiedToUtc datetimeoffset = NULL'
        $script:Schema | Should -Match '@Offset int,\s*@PageSize int'
        $script:Schema | Should -Match 'SELECT COUNT_BIG\(\*\) AS TotalRows'
        $script:Schema | Should -Match (
            '(?s)COUNT_BIG\(\*\) AS Total,\s*' +
            'COALESCE\(SUM\(CASE WHEN Status = N''Moved''.*?AS Moved,\s*' +
            'COALESCE\(SUM\(CASE WHEN Status = N''Planned''.*?AS Planned,\s*' +
            'COALESCE\(SUM\(CASE WHEN Status = N''Failed''.*?AS Failed,\s*' +
            'COALESCE\(SUM\(CASE WHEN Status = N''Moved'' THEN Bytes ELSE 0 END\), 0\)\s*' +
            'AS BytesMoved,\s*COUNT\(DISTINCT EntraDeviceId\) AS Devices,\s*' +
            'COUNT\(DISTINCT NULLIF\(Category, N''''\)\) AS Categories,\s*' +
            'MAX\(EventTimeUtc\) AS LatestActivity')
        $script:Schema | Should -Match (
            '(?s)COALESCE\(MAX\(DeviceName\), N''''\) AS DeviceName,\s*' +
            'EntraDeviceId,\s*COUNT_BIG\(\*\) AS Total,.*?' +
            'AS BytesMoved,\s*MAX\(EventTimeUtc\) AS LatestActivity')
        $script:Schema | Should -Match (
            'KPI semantics: FilePlacements is the durable latest-placement snapshot')
        $summaryProcedure | Should -Match 'FROM dbo\.FilePlacements'
        $summaryProcedure | Should -Not -Match 'MigrationCycles'
        $deviceProcedure | Should -Match 'FROM dbo\.FilePlacements'
        $deviceProcedure | Should -Not -Match 'MigrationCycles'
        $script:Schema | Should -Match (
            'SourceCreatedAtUtc < @CreatedToUtc')
        $script:Schema | Should -Match (
            'SourceModifiedAtUtc < @ModifiedToUtc')
        $script:Schema | Should -Not -Match (
            'SourceCreatedAtUtc <= @CreatedToUtc')
        $script:Schema | Should -Not -Match (
            'SourceModifiedAtUtc <= @ModifiedToUtc')
        $fileProcedure | Should -Not -Match 'FileEvents'
        $fileProcedure | Should -Not -Match 'DryRun'
        $script:Schema | Should -Match (
            'SELECT\s*placement\.DestinationPath,\s*placement\.FileName,\s*' +
            'placement\.Extension,\s*placement\.SourceCreatedAtUtc,\s*' +
            'placement\.SourceModifiedAtUtc,\s*placement\.DeviceName,\s*' +
            'placement\.EntraDeviceId,\s*placement\.Category,\s*' +
            'placement\.Bytes,\s*placement\.EventTimeUtc,\s*placement\.ExecutionId')
        $script:Schema | Should -Match (
            'ORDER BY\s*placement\.SourceModifiedAtUtc DESC,\s*' +
            'placement\.EventTimeUtc DESC,\s*placement\.DestinationPath ASC')
        $script:Schema | Should -Match "ESCAPE N'\\'"
        $script:Schema | Should -Not -Match 'sp_executesql'
        $script:Schema | Should -Match 'CREATE ROLE endpoint_data_sprawl_reader'
        $script:Schema | Should -Match (
            'GRANT EXECUTE ON dbo\.GetEndpointDataSprawlUserSummary ' +
            'TO endpoint_data_sprawl_reader')
        $script:Schema | Should -Match (
            'GRANT EXECUTE ON dbo\.GetEndpointDataSprawlUserDevices ' +
            'TO endpoint_data_sprawl_reader')
        $script:Schema | Should -Match (
            'GRANT EXECUTE ON dbo\.GetEndpointDataSprawlUserDeviceFiles ' +
            'TO endpoint_data_sprawl_reader')
        $script:Schema | Should -Not -Match 'GRANT SELECT'
        $script:Schema | Should -Not -Match 'db_datareader'
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
        $script:InitializerProject | Should -Match 'dashboard-identity-name'
        $script:InitializerProject | Should -Match 'dashboard-identity-client-id'
        $script:InitializerProject | Should -Match '__DASHBOARD_IDENTITY_ENABLED__'
        $script:InitializerProject | Should -Match 'Guid\.Empty'
        $script:InitializerProject | Should -Match 'Regex.Split'
        $script:InitializerScript | Should -Match 'DashboardIdentityName'
        $script:InitializerScript | Should -Match 'DashboardIdentityClientId'
        $script:Schema | Should -Match 'WITH SID = 0x__DASHBOARD_IDENTITY_SID_HEX__, TYPE = E'
        $script:Schema | Should -Match (
            'ALTER ROLE endpoint_data_sprawl_reader ADD MEMBER ' +
            '\[__DASHBOARD_IDENTITY_NAME__\]')
        $script:Schema | Should -Match (
            'Dashboard database principal exists with a different type or SID')
        $script:Workflow | Should -Match 'worker_identity_client_id'
        $script:Workflow | Should -Not -Match 'worker_identity_principal_id'
        $script:Workflow | Should -Match 'secrets\.AZURE_DEPLOYMENT_OBJECT_ID'
        $script:Workflow | Should -Match 'secrets\.AZURE_DEPLOYMENT_NAME'
        $script:Workflow | Should -Not -Match 'inputs\.sql_entra_admin'
        $script:MainBicep | Should -Match 'UserSession__TenantId'
        $script:MainBicep | Should -Match 'UserSession__Audience'
        $script:MainBicep | Should -Match 'UserSession__RequiredScope'
        $script:MainBicep | Should -Match 'UserSession__MetadataAddress'
        $script:MainBicep | Should -Match 'UserSession__HmacKeyBase64'
        $script:MainBicep | Should -Not -Match 'UserCorrelation__'
        $script:MainBicep | Should -Match '@secure\(\)\s*@description\('
        $script:Workflow | Should -Match (
            'ENDPOINT_DATA_SPRAWL_USER_CORRELATION_HMAC_KEY_BASE64')
    }

    It 'rejects a partial optional dashboard identity before external operations' {
        {
            & $script:InitializerScriptPath `
                -ServerName 'example' `
                -DatabaseName 'example' `
                -WorkerIdentityName 'worker' `
                -WorkerIdentityClientId '11111111-1111-1111-1111-111111111111' `
                -DashboardIdentityName 'dashboard' `
                -ResourceGroup 'example' `
                -SubscriptionId '22222222-2222-2222-2222-222222222222' `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*must both be supplied or both omitted*'
    }
}
