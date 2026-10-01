SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.SchemaVersions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SchemaVersions
    (
        VersionNumber int NOT NULL
            CONSTRAINT PK_SchemaVersions PRIMARY KEY,
        Description nvarchar(256) NOT NULL,
        AppliedAtUtc datetimeoffset(7) NOT NULL
            CONSTRAINT DF_SchemaVersions_AppliedAtUtc DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.IngestionSubmissions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.IngestionSubmissions
    (
        SubmissionId varchar(64) NOT NULL
            CONSTRAINT PK_IngestionSubmissions PRIMARY KEY,
        PayloadSha256 varchar(44) NOT NULL,
        TableName nvarchar(128) NOT NULL,
        EntraDeviceId uniqueidentifier NOT NULL,
        DeviceName nvarchar(256) NULL,
        CollectedAtUtc datetimeoffset(7) NOT NULL,
        AcceptedAtUtc datetimeoffset(7) NOT NULL,
        RecordCount int NOT NULL,
        FirstPersistedAtUtc datetimeoffset(7) NOT NULL
            CONSTRAINT DF_IngestionSubmissions_FirstPersistedAtUtc DEFAULT SYSUTCDATETIME(),
        LastPersistedAtUtc datetimeoffset(7) NOT NULL
            CONSTRAINT DF_IngestionSubmissions_LastPersistedAtUtc DEFAULT SYSUTCDATETIME(),
        LogAnalyticsState tinyint NOT NULL
            CONSTRAINT DF_IngestionSubmissions_LogAnalyticsState DEFAULT 0,
        LogAnalyticsAttemptedAtUtc datetimeoffset(7) NULL,
        LogAnalyticsPublishedAtUtc datetimeoffset(7) NULL,
        CONSTRAINT CK_IngestionSubmissions_LogAnalyticsState
            CHECK (LogAnalyticsState IN (0, 1, 2))
    );
END;

IF OBJECT_ID(N'dbo.FileEvents', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.FileEvents
    (
        EventId char(64) NOT NULL
            CONSTRAINT PK_FileEvents PRIMARY KEY,
        SubmissionId varchar(64) NOT NULL,
        RecordIndex int NOT NULL,
        EntraDeviceId uniqueidentifier NOT NULL,
        DeviceName nvarchar(256) NULL,
        UserCorrelationId char(64) NULL,
        ExecutionId nvarchar(128) NULL,
        RecordType nvarchar(64) NULL,
        Status nvarchar(64) NULL,
        DryRun bit NOT NULL,
        EventTimeUtc datetimeoffset(7) NOT NULL,
        CycleStartedAtUtc datetimeoffset(7) NULL,
        SourcePath nvarchar(2048) NULL,
        DestinationPath nvarchar(2048) NULL,
        Category nvarchar(256) NULL,
        CategoryProvider nvarchar(128) NULL,
        Bytes bigint NOT NULL,
        DurationMs bigint NOT NULL,
        ResultCode nvarchar(128) NULL,
        Detail nvarchar(2048) NULL,
        ClientVersion nvarchar(64) NULL,
        ClientType nvarchar(64) NULL,
        InsertedAtUtc datetimeoffset(7) NOT NULL
            CONSTRAINT DF_FileEvents_InsertedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_FileEvents_IngestionSubmissions
            FOREIGN KEY (SubmissionId) REFERENCES dbo.IngestionSubmissions(SubmissionId),
        CONSTRAINT UQ_FileEvents_SubmissionRecord UNIQUE (SubmissionId, RecordIndex)
    );

    CREATE INDEX IX_FileEvents_UserTime
        ON dbo.FileEvents(UserCorrelationId, EventTimeUtc DESC)
        INCLUDE (DestinationPath, Status, Category, DeviceName, Bytes, DryRun);

    CREATE INDEX IX_FileEvents_DeviceTime
        ON dbo.FileEvents(EntraDeviceId, EventTimeUtc DESC)
        INCLUDE (ExecutionId, RecordType, Status, DestinationPath, Bytes);
END;

IF OBJECT_ID(N'dbo.MigrationCycles', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MigrationCycles
    (
        EntraDeviceId uniqueidentifier NOT NULL,
        ExecutionId nvarchar(128) NOT NULL,
        SubmissionId varchar(64) NOT NULL,
        DeviceName nvarchar(256) NULL,
        UserCorrelationId char(64) NULL,
        EventTimeUtc datetimeoffset(7) NOT NULL,
        AcceptedAtUtc datetimeoffset(7) NOT NULL,
        CycleStartedAtUtc datetimeoffset(7) NULL,
        ClientVersion nvarchar(64) NULL,
        ClientType nvarchar(64) NULL,
        Status nvarchar(64) NULL,
        DryRun bit NOT NULL,
        Discovered int NOT NULL,
        Planned int NOT NULL,
        Moved int NOT NULL,
        Skipped int NOT NULL,
        Failed int NOT NULL,
        Deferred int NOT NULL,
        OmittedFileResults int NOT NULL,
        UpdatedAtUtc datetimeoffset(7) NOT NULL
            CONSTRAINT DF_MigrationCycles_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_MigrationCycles PRIMARY KEY (EntraDeviceId, ExecutionId),
        CONSTRAINT FK_MigrationCycles_IngestionSubmissions
            FOREIGN KEY (SubmissionId) REFERENCES dbo.IngestionSubmissions(SubmissionId)
    );

    CREATE INDEX IX_MigrationCycles_UserTime
        ON dbo.MigrationCycles(UserCorrelationId, EventTimeUtc DESC);
END;

IF OBJECT_ID(N'dbo.FilePlacements', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.FilePlacements
    (
        UserCorrelationId char(64) NOT NULL,
        DestinationPathHash binary(32) NOT NULL,
        DestinationPath nvarchar(2048) NOT NULL,
        EntraDeviceId uniqueidentifier NOT NULL,
        DeviceName nvarchar(256) NULL,
        ExecutionId nvarchar(128) NULL,
        Status nvarchar(64) NOT NULL,
        Category nvarchar(256) NULL,
        Bytes bigint NOT NULL,
        EventTimeUtc datetimeoffset(7) NOT NULL,
        AcceptedAtUtc datetimeoffset(7) NOT NULL,
        LatestEventId char(64) NOT NULL,
        UpdatedAtUtc datetimeoffset(7) NOT NULL
            CONSTRAINT DF_FilePlacements_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_FilePlacements PRIMARY KEY
            (UserCorrelationId, EntraDeviceId, DestinationPathHash),
        CONSTRAINT FK_FilePlacements_FileEvents
            FOREIGN KEY (LatestEventId) REFERENCES dbo.FileEvents(EventId)
    );

    CREATE INDEX IX_FilePlacements_UserTime
        ON dbo.FilePlacements(UserCorrelationId, UpdatedAtUtc DESC)
        INCLUDE (DestinationPath, Status, Category, DeviceName, Bytes);
END;
GO

CREATE OR ALTER PROCEDURE dbo.PersistEndpointDataSprawlBatch
    @SubmissionId varchar(64),
    @PayloadSha256 varchar(44),
    @TableName nvarchar(128),
    @EntraDeviceId uniqueidentifier,
    @DeviceName nvarchar(256) = NULL,
    @CollectedAtUtc datetimeoffset(7),
    @AcceptedAtUtc datetimeoffset(7),
    @RowsJson nvarchar(max),
    @LogAnalyticsState tinyint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

    DECLARE @RecordCount int = (SELECT COUNT(*) FROM OPENJSON(@RowsJson));

    BEGIN TRANSACTION;

    SET @LogAnalyticsState = 0;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.IngestionSubmissions WITH (UPDLOCK, HOLDLOCK)
        WHERE SubmissionId = @SubmissionId
          AND PayloadSha256 <> @PayloadSha256
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 51001, 'Submission id already exists with a different payload digest.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.IngestionSubmissions WITH (UPDLOCK, HOLDLOCK)
        WHERE SubmissionId = @SubmissionId
    )
    BEGIN
        SELECT @LogAnalyticsState = LogAnalyticsState
        FROM dbo.IngestionSubmissions
        WHERE SubmissionId = @SubmissionId;

        COMMIT TRANSACTION;
        RETURN;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.IngestionSubmissions WITH (UPDLOCK, HOLDLOCK)
        WHERE SubmissionId = @SubmissionId
    )
    BEGIN
        INSERT dbo.IngestionSubmissions
        (
            SubmissionId,
            PayloadSha256,
            TableName,
            EntraDeviceId,
            DeviceName,
            CollectedAtUtc,
            AcceptedAtUtc,
            RecordCount
        )
        VALUES
        (
            @SubmissionId,
            @PayloadSha256,
            @TableName,
            @EntraDeviceId,
            @DeviceName,
            @CollectedAtUtc,
            @AcceptedAtUtc,
            @RecordCount
        );
    END;

    CREATE TABLE #Rows
    (
        RecordIndex int NOT NULL,
        EventId char(64) NOT NULL,
        UserCorrelationId char(64) NULL,
        ExecutionId nvarchar(128) NULL,
        RecordType nvarchar(64) NULL,
        Status nvarchar(64) NULL,
        DryRun bit NOT NULL,
        EventTimeUtc datetimeoffset(7) NOT NULL,
        CycleStartedAtUtc datetimeoffset(7) NULL,
        SourcePath nvarchar(2048) NULL,
        DestinationPath nvarchar(2048) NULL,
        Category nvarchar(256) NULL,
        CategoryProvider nvarchar(128) NULL,
        Bytes bigint NOT NULL,
        DurationMs bigint NOT NULL,
        ResultCode nvarchar(128) NULL,
        Detail nvarchar(2048) NULL,
        ClientVersion nvarchar(64) NULL,
        ClientType nvarchar(64) NULL,
        Discovered int NOT NULL,
        Planned int NOT NULL,
        Moved int NOT NULL,
        Skipped int NOT NULL,
        Failed int NOT NULL,
        Deferred int NOT NULL,
        OmittedFileResults int NOT NULL
    );

    INSERT #Rows
    SELECT
        source.RecordIndex,
        CONVERT(char(64), HASHBYTES(
            'SHA2_256',
            CONCAT(@SubmissionId, ':', CONVERT(varchar(12), source.RecordIndex))),
            2),
        CASE
            WHEN DATALENGTH(source.UserCorrelationId) = 128
                 AND UPPER(source.UserCorrelationId) COLLATE Latin1_General_100_BIN2
                     NOT LIKE '%[^0-9A-F]%'
                THEN source.UserCorrelationId
            ELSE NULL
        END,
        NULLIF(source.ExecutionId, N''),
        NULLIF(source.RecordType, N''),
        NULLIF(source.Status, N''),
        COALESCE(source.DryRun, 0),
        CASE
            WHEN COALESCE(source.EventTimeUtc, source.CycleStartedAtUtc, @CollectedAtUtc)
                BETWEEN DATEADD(day, -30, @AcceptedAtUtc) AND DATEADD(day, 1, @AcceptedAtUtc)
            THEN COALESCE(source.EventTimeUtc, source.CycleStartedAtUtc, @CollectedAtUtc)
            ELSE @AcceptedAtUtc
        END,
        CASE
            WHEN source.CycleStartedAtUtc
                BETWEEN DATEADD(day, -30, @AcceptedAtUtc) AND DATEADD(day, 1, @AcceptedAtUtc)
            THEN source.CycleStartedAtUtc
            ELSE NULL
        END,
        NULLIF(LEFT(source.SourcePath, 2048), N''),
        NULLIF(LEFT(source.DestinationPath, 2048), N''),
        NULLIF(source.Category, N''),
        NULLIF(source.CategoryProvider, N''),
        COALESCE(source.Bytes, 0),
        COALESCE(source.DurationMs, 0),
        NULLIF(source.ResultCode, N''),
        NULLIF(LEFT(source.Detail, 2048), N''),
        NULLIF(source.ClientVersion, N''),
        NULLIF(source.ClientType, N''),
        COALESCE(source.Discovered, 0),
        COALESCE(source.Planned, 0),
        COALESCE(source.Moved, 0),
        COALESCE(source.Skipped, 0),
        COALESCE(source.Failed, 0),
        COALESCE(source.Deferred, 0),
        COALESCE(source.OmittedFileResults, 0)
    FROM OPENJSON(@RowsJson)
    WITH
    (
        RecordIndex int '$.RecordIndex',
        UserCorrelationId nvarchar(128) '$.UserCorrelationId',
        ExecutionId nvarchar(128) '$.ExecutionId',
        RecordType nvarchar(64) '$.RecordType',
        Status nvarchar(64) '$.Status',
        DryRun bit '$.DryRun',
        EventTimeUtc datetimeoffset(7) '$.EventTimeUtc',
        CycleStartedAtUtc datetimeoffset(7) '$.CycleStartedAtUtc',
        SourcePath nvarchar(max) '$.SourcePath',
        DestinationPath nvarchar(max) '$.DestinationPath',
        Category nvarchar(256) '$.Category',
        CategoryProvider nvarchar(128) '$.CategoryProvider',
        Bytes bigint '$.Bytes',
        DurationMs bigint '$.DurationMs',
        ResultCode nvarchar(128) '$.ResultCode',
        Detail nvarchar(max) '$.Detail',
        ClientVersion nvarchar(64) '$.ClientVersion',
        ClientType nvarchar(64) '$.ClientType',
        Discovered int '$.Discovered',
        Planned int '$.Planned',
        Moved int '$.Moved',
        Skipped int '$.Skipped',
        Failed int '$.Failed',
        Deferred int '$.Deferred',
        OmittedFileResults int '$.OmittedFileResults'
    ) AS source;

    INSERT dbo.FileEvents
    (
        EventId,
        SubmissionId,
        RecordIndex,
        EntraDeviceId,
        DeviceName,
        UserCorrelationId,
        ExecutionId,
        RecordType,
        Status,
        DryRun,
        EventTimeUtc,
        CycleStartedAtUtc,
        SourcePath,
        DestinationPath,
        Category,
        CategoryProvider,
        Bytes,
        DurationMs,
        ResultCode,
        Detail,
        ClientVersion,
        ClientType
    )
    SELECT
        source.EventId,
        @SubmissionId,
        source.RecordIndex,
        @EntraDeviceId,
        @DeviceName,
        source.UserCorrelationId,
        source.ExecutionId,
        source.RecordType,
        source.Status,
        source.DryRun,
        source.EventTimeUtc,
        source.CycleStartedAtUtc,
        source.SourcePath,
        source.DestinationPath,
        source.Category,
        source.CategoryProvider,
        source.Bytes,
        source.DurationMs,
        source.ResultCode,
        source.Detail,
        source.ClientVersion,
        source.ClientType
    FROM #Rows AS source
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.FileEvents AS target WITH (UPDLOCK, HOLDLOCK)
        WHERE target.EventId = source.EventId
    );

    SELECT *
    INTO #LatestCycles
    FROM
    (
        SELECT
            source.*,
            ROW_NUMBER() OVER
            (
                PARTITION BY source.ExecutionId
                ORDER BY source.EventTimeUtc DESC, source.RecordIndex DESC
            ) AS RowNumber
        FROM #Rows AS source
        WHERE source.RecordType = N'CycleSummary'
          AND source.ExecutionId IS NOT NULL
    ) AS ranked
    WHERE ranked.RowNumber = 1;

    UPDATE target
    SET SubmissionId = @SubmissionId,
        DeviceName = @DeviceName,
        UserCorrelationId = source.UserCorrelationId,
        EventTimeUtc = source.EventTimeUtc,
        AcceptedAtUtc = @AcceptedAtUtc,
        CycleStartedAtUtc = source.CycleStartedAtUtc,
        ClientVersion = source.ClientVersion,
        ClientType = source.ClientType,
        Status = source.Status,
        DryRun = source.DryRun,
        Discovered = source.Discovered,
        Planned = source.Planned,
        Moved = source.Moved,
        Skipped = source.Skipped,
        Failed = source.Failed,
        Deferred = source.Deferred,
        OmittedFileResults = source.OmittedFileResults,
        UpdatedAtUtc = SYSUTCDATETIME()
    FROM dbo.MigrationCycles AS target
    INNER JOIN #LatestCycles AS source
        ON target.EntraDeviceId = @EntraDeviceId
       AND target.ExecutionId = source.ExecutionId
    WHERE @AcceptedAtUtc >= target.AcceptedAtUtc;

    INSERT dbo.MigrationCycles
    (
        EntraDeviceId,
        ExecutionId,
        SubmissionId,
        DeviceName,
        UserCorrelationId,
        EventTimeUtc,
        AcceptedAtUtc,
        CycleStartedAtUtc,
        ClientVersion,
        ClientType,
        Status,
        DryRun,
        Discovered,
        Planned,
        Moved,
        Skipped,
        Failed,
        Deferred,
        OmittedFileResults
    )
    SELECT
        @EntraDeviceId,
        source.ExecutionId,
        @SubmissionId,
        @DeviceName,
        source.UserCorrelationId,
        source.EventTimeUtc,
        @AcceptedAtUtc,
        source.CycleStartedAtUtc,
        source.ClientVersion,
        source.ClientType,
        source.Status,
        source.DryRun,
        source.Discovered,
        source.Planned,
        source.Moved,
        source.Skipped,
        source.Failed,
        source.Deferred,
        source.OmittedFileResults
    FROM #LatestCycles AS source
    WHERE NOT EXISTS
      (
          SELECT 1
          FROM dbo.MigrationCycles AS target WITH (UPDLOCK, HOLDLOCK)
          WHERE target.EntraDeviceId = @EntraDeviceId
            AND target.ExecutionId = source.ExecutionId
      );

    ;WITH ranked AS
    (
        SELECT
            source.*,
            path.DestinationPathHash,
            ROW_NUMBER() OVER
            (
                PARTITION BY source.UserCorrelationId, path.DestinationPathHash
                ORDER BY source.RecordIndex DESC
            ) AS RowNumber
        FROM #Rows AS source
        CROSS APPLY
        (
            SELECT HASHBYTES(
                'SHA2_256',
                CONVERT(varbinary(max), source.DestinationPath)) AS DestinationPathHash
        ) AS path
        WHERE source.RecordType = N'FileResult'
          AND source.Status IN (N'Moved', N'Planned', N'Failed')
          AND source.DryRun = 0
          AND source.UserCorrelationId IS NOT NULL
          AND source.DestinationPath IS NOT NULL
    )
    UPDATE target
    SET DestinationPath = source.DestinationPath,
        EntraDeviceId = @EntraDeviceId,
        DeviceName = @DeviceName,
        ExecutionId = source.ExecutionId,
        Status = source.Status,
        Category = source.Category,
        Bytes = source.Bytes,
        EventTimeUtc = source.EventTimeUtc,
        AcceptedAtUtc = @AcceptedAtUtc,
        LatestEventId = source.EventId,
        UpdatedAtUtc = SYSUTCDATETIME()
    FROM dbo.FilePlacements AS target
    INNER JOIN ranked AS source
        ON target.UserCorrelationId = source.UserCorrelationId
       AND target.EntraDeviceId = @EntraDeviceId
       AND target.DestinationPathHash = source.DestinationPathHash
    WHERE source.RowNumber = 1
      AND @AcceptedAtUtc >= target.AcceptedAtUtc;

    ;WITH ranked AS
    (
        SELECT
            source.*,
            path.DestinationPathHash,
            ROW_NUMBER() OVER
            (
                PARTITION BY source.UserCorrelationId, path.DestinationPathHash
                ORDER BY source.RecordIndex DESC
            ) AS RowNumber
        FROM #Rows AS source
        CROSS APPLY
        (
            SELECT HASHBYTES(
                'SHA2_256',
                CONVERT(varbinary(max), source.DestinationPath)) AS DestinationPathHash
        ) AS path
        WHERE source.RecordType = N'FileResult'
          AND source.Status IN (N'Moved', N'Planned', N'Failed')
          AND source.DryRun = 0
          AND source.UserCorrelationId IS NOT NULL
          AND source.DestinationPath IS NOT NULL
    )
    INSERT dbo.FilePlacements
    (
        UserCorrelationId,
        DestinationPathHash,
        DestinationPath,
        EntraDeviceId,
        DeviceName,
        ExecutionId,
        Status,
        Category,
        Bytes,
        EventTimeUtc,
        AcceptedAtUtc,
        LatestEventId
    )
    SELECT
        source.UserCorrelationId,
        source.DestinationPathHash,
        source.DestinationPath,
        @EntraDeviceId,
        @DeviceName,
        source.ExecutionId,
        source.Status,
        source.Category,
        source.Bytes,
        source.EventTimeUtc,
        @AcceptedAtUtc,
        source.EventId
    FROM ranked AS source
    WHERE source.RowNumber = 1
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.FilePlacements AS target WITH (UPDLOCK, HOLDLOCK)
          WHERE target.UserCorrelationId = source.UserCorrelationId
            AND target.EntraDeviceId = @EntraDeviceId
            AND target.DestinationPathHash = source.DestinationPathHash
      );

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.BeginEndpointDataSprawlLogAnalyticsPublish
    @SubmissionId varchar(64),
    @PayloadSha256 varchar(44)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE dbo.IngestionSubmissions
    SET LogAnalyticsState = 1,
        LogAnalyticsAttemptedAtUtc = SYSUTCDATETIME(),
        LastPersistedAtUtc = SYSUTCDATETIME()
    WHERE SubmissionId = @SubmissionId
      AND PayloadSha256 = @PayloadSha256
      AND LogAnalyticsState = 0;

    IF @@ROWCOUNT = 0
    BEGIN
        THROW 51002, 'Submission is not pending Log Analytics publication.', 1;
    END;
END;
GO

CREATE OR ALTER PROCEDURE dbo.MarkEndpointDataSprawlLogAnalyticsPublished
    @SubmissionId varchar(64),
    @PayloadSha256 varchar(44)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE dbo.IngestionSubmissions
    SET LogAnalyticsState = 2,
        LogAnalyticsPublishedAtUtc = COALESCE(LogAnalyticsPublishedAtUtc, SYSUTCDATETIME()),
        LastPersistedAtUtc = SYSUTCDATETIME()
    WHERE SubmissionId = @SubmissionId
      AND PayloadSha256 = @PayloadSha256
      AND LogAnalyticsState = 1;

    IF @@ROWCOUNT = 0
    BEGIN
        THROW 51003, 'Submission does not have an unknown Log Analytics outcome.', 1;
    END;
END;
GO

CREATE OR ALTER PROCEDURE dbo.ResetEndpointDataSprawlLogAnalyticsPublish
    @SubmissionId varchar(64),
    @PayloadSha256 varchar(44)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE dbo.IngestionSubmissions
    SET LogAnalyticsState = 0,
        LogAnalyticsAttemptedAtUtc = NULL,
        LastPersistedAtUtc = SYSUTCDATETIME()
    WHERE SubmissionId = @SubmissionId
      AND PayloadSha256 = @PayloadSha256
      AND LogAnalyticsState = 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.PurgeEndpointDataSprawlHistory
    @RetentionDays int,
    @DeletedRows int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RetentionDays < 30 OR @RetentionDays > 3650
    BEGIN
        THROW 51004, 'Retention days must be between 30 and 3650.', 1;
    END;

    DECLARE @Cutoff datetimeoffset(7) = DATEADD(day, -@RetentionDays, SYSUTCDATETIME());
    DECLARE @Count int = 0;
    DECLARE @BatchCount int;

    WHILE 1 = 1
    BEGIN
        DELETE TOP (5000) FROM dbo.FilePlacements
        WHERE UpdatedAtUtc < @Cutoff;
        SET @BatchCount = @@ROWCOUNT;
        SET @Count += @BatchCount;
        IF @BatchCount = 0 BREAK;
    END;

    WHILE 1 = 1
    BEGIN
        DELETE TOP (5000) events
        FROM dbo.FileEvents AS events
        WHERE events.InsertedAtUtc < @Cutoff
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.FilePlacements AS placements
              WHERE placements.LatestEventId = events.EventId
          );
        SET @BatchCount = @@ROWCOUNT;
        SET @Count += @BatchCount;
        IF @BatchCount = 0 BREAK;
    END;

    WHILE 1 = 1
    BEGIN
        DELETE TOP (5000) FROM dbo.MigrationCycles
        WHERE AcceptedAtUtc < @Cutoff;
        SET @BatchCount = @@ROWCOUNT;
        SET @Count += @BatchCount;
        IF @BatchCount = 0 BREAK;
    END;

    WHILE 1 = 1
    BEGIN
        DELETE TOP (5000) submissions
        FROM dbo.IngestionSubmissions AS submissions
        WHERE submissions.AcceptedAtUtc < @Cutoff
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.FileEvents AS events
              WHERE events.SubmissionId = submissions.SubmissionId
          )
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.MigrationCycles AS cycles
              WHERE cycles.SubmissionId = submissions.SubmissionId
          );
        SET @BatchCount = @@ROWCOUNT;
        SET @Count += @BatchCount;
        IF @BatchCount = 0 BREAK;
    END;

    SET @DeletedRows = @Count;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'endpoint_data_sprawl_ingestor')
BEGIN
    CREATE ROLE endpoint_data_sprawl_ingestor;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'__WORKER_IDENTITY_NAME__')
BEGIN
    CREATE USER [__WORKER_IDENTITY_NAME__]
        WITH SID = 0x__WORKER_IDENTITY_SID_HEX__, TYPE = E;
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS membership
    INNER JOIN sys.database_principals AS rolePrincipal
        ON rolePrincipal.principal_id = membership.role_principal_id
    INNER JOIN sys.database_principals AS memberPrincipal
        ON memberPrincipal.principal_id = membership.member_principal_id
    WHERE rolePrincipal.name = N'endpoint_data_sprawl_ingestor'
      AND memberPrincipal.name = N'__WORKER_IDENTITY_NAME__'
)
BEGIN
    ALTER ROLE endpoint_data_sprawl_ingestor ADD MEMBER [__WORKER_IDENTITY_NAME__];
END;
GO

GRANT EXECUTE ON dbo.PersistEndpointDataSprawlBatch TO endpoint_data_sprawl_ingestor;
GRANT EXECUTE ON dbo.BeginEndpointDataSprawlLogAnalyticsPublish TO endpoint_data_sprawl_ingestor;
GRANT EXECUTE ON dbo.MarkEndpointDataSprawlLogAnalyticsPublished TO endpoint_data_sprawl_ingestor;
GRANT EXECUTE ON dbo.ResetEndpointDataSprawlLogAnalyticsPublish TO endpoint_data_sprawl_ingestor;
GRANT EXECUTE ON dbo.PurgeEndpointDataSprawlHistory TO endpoint_data_sprawl_ingestor;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersions WHERE VersionNumber = 1)
BEGIN
    INSERT dbo.SchemaVersions(VersionNumber, Description)
    VALUES (1, N'Endpoint Data Sprawl durable ingestion and read model');
END;
GO
