using LogCollector.Shared.Ingestion;
using Microsoft.Extensions.Configuration;

namespace LogCollector.Worker.Services;

/// <summary>Worker-side ingestion tuning, resolved once at startup.</summary>
public sealed class WorkerIngestionOptions
{
    public WorkerIngestionOptions(IConfiguration cfg)
    {
        DataCollectionEndpoint = cfg["Ingestion:DataCollectionEndpoint"]
            ?? throw new InvalidOperationException("Required setting 'Ingestion:DataCollectionEndpoint' is not configured.");

        DataCollectionRuleId = cfg["Ingestion:DataCollectionRuleId"]
            ?? throw new InvalidOperationException("Required setting 'Ingestion:DataCollectionRuleId' is not configured.");

        StorageAccountName = cfg["Storage:AccountName"]
            ?? throw new InvalidOperationException("Required setting 'Storage:AccountName' is not configured.");

        PayloadContainer = cfg["Storage:PayloadContainer"] ?? "inventory-payloads";

        MaxChunkBytes = int.TryParse(cfg["Ingestion:MaxChunkBytes"], out var chunk)
            ? Math.Clamp(chunk, 64 * 1024, LogsIngestionChunker.HardLimitBytes)
            : LogsIngestionChunker.DefaultMaxChunkBytes;

        MaxAttempts = int.TryParse(cfg["Ingestion:MaxAttempts"], out var attempts)
            ? Math.Clamp(attempts, 1, 10)
            : 5;

        BaseRetryDelay = TimeSpan.FromMilliseconds(
            int.TryParse(cfg["Ingestion:BaseRetryDelayMs"], out var baseMs) ? Math.Clamp(baseMs, 100, 60_000) : 1_000);

        MaxRetryDelay = TimeSpan.FromSeconds(
            int.TryParse(cfg["Ingestion:MaxRetryDelaySeconds"], out var maxSec) ? Math.Clamp(maxSec, 1, 300) : 60);

        // Default off: retention is governed by the storage lifecycle policy, which
        // keeps a replay window for incident investigation. Turn on only when the
        // compliance posture requires the payload to disappear immediately.
        DeleteBlobAfterIngestion = bool.TryParse(cfg["Ingestion:DeleteBlobAfterIngestion"], out var del) && del;

        MaxRecordsPerEnvelope = int.TryParse(cfg["Intake:MaxRecordsPerEnvelope"], out var maxRecords)
            ? Math.Clamp(maxRecords, 1, 200_000)
            : 50_000;
    }

    public string DataCollectionEndpoint { get; }

    public string DataCollectionRuleId { get; }

    public string StorageAccountName { get; }

    public string PayloadContainer { get; }

    public int MaxChunkBytes { get; }

    public int MaxAttempts { get; }

    public TimeSpan BaseRetryDelay { get; }

    public TimeSpan MaxRetryDelay { get; }

    public bool DeleteBlobAfterIngestion { get; }

    public int MaxRecordsPerEnvelope { get; }
}
