using System.Data;
using System.Text.Json;
using LogCollector.Shared.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LogCollector.Worker.Services;

public interface IEndpointDataSprawlPersistence
{
    Task<PersistenceResult> PersistAsync(
        QueuedIngestionMessage pointer,
        IReadOnlyList<JsonElement> rows,
        CancellationToken cancellationToken);

    Task BeginLogAnalyticsPublishAsync(
        QueuedIngestionMessage pointer,
        CancellationToken cancellationToken);

    Task MarkLogAnalyticsPublishedAsync(
        QueuedIngestionMessage pointer,
        CancellationToken cancellationToken);

    Task ResetLogAnalyticsPublishAsync(
        QueuedIngestionMessage pointer,
        CancellationToken cancellationToken);

    Task<int> PurgeExpiredAsync(CancellationToken cancellationToken);
}

public enum LogAnalyticsDeliveryState : byte
{
    Pending = 0,
    OutcomeUnknown = 1,
    Published = 2,
}

public sealed record PersistenceResult(
    bool Applied,
    int Rows,
    LogAnalyticsDeliveryState LogAnalyticsState)
{
    public static PersistenceResult Skipped { get; } =
        new(false, 0, LogAnalyticsDeliveryState.Pending);
}

public sealed class EndpointDataSprawlPersistenceException(
    string message,
    bool permanent,
    Exception? innerException = null) : Exception(message, innerException)
{
    public bool Permanent { get; } = permanent;
}

public sealed class SqlPersistenceOptions
{
    public const string DefaultTargetTable = "EndpointDataSprawlRemediator_CL";

    public SqlPersistenceOptions(IConfiguration configuration)
    {
        Enabled = bool.TryParse(configuration["SqlPersistence:Enabled"], out var enabled) && enabled;
        ConnectionString = configuration["SqlPersistence:ConnectionString"] ?? string.Empty;
        TargetTableName = configuration["SqlPersistence:TargetTableName"] ?? DefaultTargetTable;
        RetentionDays = int.TryParse(configuration["SqlPersistence:RetentionDays"], out var retentionDays)
            ? Math.Clamp(retentionDays, 30, 3_650)
            : 2_555;
        PlacementRetentionDays = int.TryParse(
            configuration["SqlPersistence:PlacementRetentionDays"],
            out var placementRetentionDays)
            ? Math.Clamp(placementRetentionDays, 31, 36_500)
            : Math.Max(3_650, RetentionDays + 1);

        if (PlacementRetentionDays <= RetentionDays)
        {
            throw new InvalidOperationException(
                "SqlPersistence:PlacementRetentionDays must be greater than SqlPersistence:RetentionDays.");
        }

        if (Enabled && string.IsNullOrWhiteSpace(ConnectionString))
        {
            throw new InvalidOperationException(
                "SqlPersistence:ConnectionString is required when SQL persistence is enabled.");
        }

        if (!TelemetryEnvelope.IsSafeTableName(TargetTableName))
        {
            throw new InvalidOperationException(
                "SqlPersistence:TargetTableName must be a valid telemetry table name.");
        }

        if (Enabled &&
            !string.Equals(TargetTableName, DefaultTargetTable, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"SQL persistence currently supports only {DefaultTargetTable}.");
        }
    }

    public bool Enabled { get; }

    public string ConnectionString { get; }

    public string TargetTableName { get; }

    public int RetentionDays { get; }

    public int PlacementRetentionDays { get; }
}

public sealed class EndpointDataSprawlSqlPersistence(
    SqlPersistenceOptions options,
    ILogger<EndpointDataSprawlSqlPersistence> logger) : IEndpointDataSprawlPersistence
{
    private const int PayloadConflictErrorNumber = 51001;
    private static readonly HashSet<int> PermanentPayloadErrorNumbers =
    [
        241, 245, 515, 547, 2_601, 2_627, 2_628, 8_114, 8_115, 8_152, 13_609,
    ];

    public async Task<PersistenceResult> PersistAsync(
        QueuedIngestionMessage pointer,
        IReadOnlyList<JsonElement> rows,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(pointer);
        ArgumentNullException.ThrowIfNull(rows);

        if (!options.Enabled ||
            !string.Equals(pointer.TableName, options.TargetTableName, StringComparison.Ordinal))
        {
            return PersistenceResult.Skipped;
        }

        var rowsJson = JsonSerializer.Serialize(rows);

        try
        {
            await using var connection = new SqlConnection(options.ConnectionString);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);

            await using var command = new SqlCommand(
                "dbo.PersistEndpointDataSprawlBatch",
                connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 60,
            };

            command.Parameters.Add("@SubmissionId", SqlDbType.VarChar, 64).Value = pointer.CorrelationId;
            command.Parameters.Add("@PayloadSha256", SqlDbType.VarChar, 44).Value = pointer.PayloadSha256;
            command.Parameters.Add("@TableName", SqlDbType.NVarChar, 128).Value = pointer.TableName;
            command.Parameters.Add("@EntraDeviceId", SqlDbType.UniqueIdentifier).Value =
                Guid.Parse(pointer.EntraDeviceId);
            command.Parameters.Add("@DeviceName", SqlDbType.NVarChar, 256).Value =
                (object?)pointer.DeviceName ?? DBNull.Value;
            command.Parameters.Add("@CollectedAtUtc", SqlDbType.DateTimeOffset).Value =
                pointer.CollectedAtUtc;
            command.Parameters.Add("@AcceptedAtUtc", SqlDbType.DateTimeOffset).Value =
                pointer.AcceptedAtUtc;
            command.Parameters.Add("@RowsJson", SqlDbType.NVarChar, -1).Value = rowsJson;
            var stateParameter = command.Parameters.Add("@LogAnalyticsState", SqlDbType.TinyInt);
            stateParameter.Direction = ParameterDirection.Output;

            await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            var state = stateParameter.Value is byte stateValue
                ? (LogAnalyticsDeliveryState)stateValue
                : LogAnalyticsDeliveryState.Pending;

            logger.LogInformation(
                "Persisted Endpoint Data Sprawl submission {SubmissionId} with {RowCount} row(s) to Azure SQL.",
                pointer.CorrelationId,
                rows.Count);

            return new PersistenceResult(true, rows.Count, state);
        }
        catch (SqlException exception) when (exception.Number == PayloadConflictErrorNumber)
        {
            throw new EndpointDataSprawlPersistenceException(
                "Azure SQL rejected a replay whose submission id has a different payload digest.",
                permanent: true,
                exception);
        }
        catch (SqlException exception) when (
            PermanentPayloadErrorNumbers.Contains(exception.Number))
        {
            throw new EndpointDataSprawlPersistenceException(
                $"Azure SQL rejected the persisted payload with deterministic data error {exception.Number}.",
                permanent: true,
                exception);
        }
        catch (SqlException exception)
        {
            throw new EndpointDataSprawlPersistenceException(
                $"Azure SQL persistence failed with error {exception.Number}.",
                permanent: false,
                exception);
        }
    }

    public Task BeginLogAnalyticsPublishAsync(
        QueuedIngestionMessage pointer,
        CancellationToken cancellationToken) =>
        ExecuteLedgerProcedureAsync(
            pointer,
            "dbo.BeginEndpointDataSprawlLogAnalyticsPublish",
            cancellationToken);

    public async Task MarkLogAnalyticsPublishedAsync(
        QueuedIngestionMessage pointer,
        CancellationToken cancellationToken) =>
        await ExecuteLedgerProcedureAsync(
            pointer,
            "dbo.MarkEndpointDataSprawlLogAnalyticsPublished",
            cancellationToken).ConfigureAwait(false);

    public Task ResetLogAnalyticsPublishAsync(
        QueuedIngestionMessage pointer,
        CancellationToken cancellationToken) =>
        ExecuteLedgerProcedureAsync(
            pointer,
            "dbo.ResetEndpointDataSprawlLogAnalyticsPublish",
            cancellationToken);

    private async Task ExecuteLedgerProcedureAsync(
        QueuedIngestionMessage pointer,
        string procedureName,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(pointer);

        if (!options.Enabled ||
            !string.Equals(pointer.TableName, options.TargetTableName, StringComparison.Ordinal))
        {
            return;
        }

        try
        {
            await using var connection = new SqlConnection(options.ConnectionString);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);

            await using var command = new SqlCommand(
                procedureName,
                connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 30,
            };
            command.Parameters.Add("@SubmissionId", SqlDbType.VarChar, 64).Value =
                pointer.CorrelationId;
            command.Parameters.Add("@PayloadSha256", SqlDbType.VarChar, 44).Value =
                pointer.PayloadSha256;

            await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (SqlException exception)
        {
            throw new EndpointDataSprawlPersistenceException(
                $"Failed to update Log Analytics delivery state in Azure SQL with error {exception.Number}.",
                permanent: false,
                exception);
        }
    }

    public async Task<int> PurgeExpiredAsync(CancellationToken cancellationToken)
    {
        if (!options.Enabled)
        {
            return 0;
        }

        try
        {
            await using var connection = new SqlConnection(options.ConnectionString);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);

            await using var command = new SqlCommand(
                "dbo.PurgeEndpointDataSprawlHistory",
                connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            command.Parameters.Add("@RetentionDays", SqlDbType.Int).Value = options.RetentionDays;
            command.Parameters.Add("@PlacementRetentionDays", SqlDbType.Int).Value =
                options.PlacementRetentionDays;
            var deletedParameter = command.Parameters.Add("@DeletedRows", SqlDbType.Int);
            deletedParameter.Direction = ParameterDirection.Output;

            await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            return deletedParameter.Value is int deletedRows ? deletedRows : 0;
        }
        catch (SqlException exception)
        {
            throw new EndpointDataSprawlPersistenceException(
                $"Azure SQL retention failed with error {exception.Number}.",
                permanent: false,
                exception);
        }
    }
}
