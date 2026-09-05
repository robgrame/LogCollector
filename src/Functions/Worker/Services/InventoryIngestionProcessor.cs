using System.Text.Json;
using LogCollector.Shared.Ingestion;
using LogCollector.Shared.Models;
using Microsoft.Extensions.Logging;

namespace LogCollector.Worker.Services;

/// <summary>
/// Turns one pointer message into ingested rows.
/// </summary>
/// <remarks>
/// The processor separates <i>permanent</i> from <i>transient</i> failure, which
/// is the difference between a queue that drains and a queue that thrashes.
/// Permanent failures (malformed pointer, unmapped table, corrupt payload,
/// uningestible rows) are dead-lettered immediately with a reason; transient
/// failures throw so the Service Bus lock is abandoned and normal delivery-count
/// retry applies.
///
/// A permanent failure never deletes the payload blob. That is deliberate: the
/// dead-letter message plus the retained blob together are what make the sample
/// recoverable once the underlying defect is remediated.
/// </remarks>
public sealed class InventoryIngestionProcessor
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly PayloadBlobReader _blobReader;
    private readonly LogsIngestionPublisher _publisher;
    private readonly IngestionStreamMap _streamMap;
    private readonly WorkerIngestionOptions _options;
    private readonly ILogger<InventoryIngestionProcessor> _log;

    public InventoryIngestionProcessor(
        PayloadBlobReader blobReader,
        LogsIngestionPublisher publisher,
        IngestionStreamMap streamMap,
        WorkerIngestionOptions options,
        ILogger<InventoryIngestionProcessor> log)
    {
        _blobReader = blobReader;
        _publisher = publisher;
        _streamMap = streamMap;
        _options = options;
        _log = log;
    }

    public sealed record ProcessingOutcome(bool Ok, bool Permanent, string? Reason, int RowsIngested)
    {
        public static ProcessingOutcome Poison(string reason) => new(false, true, reason, 0);

        public static ProcessingOutcome Success(int rowsIngested) => new(true, false, null, rowsIngested);
    }

    /// <summary>Parses the raw Service Bus body. Never throws on malformed input.</summary>
    public static QueuedIngestionMessage? TryParsePointer(string body, out string? reason)
    {
        reason = null;
        try
        {
            var pointer = JsonSerializer.Deserialize<QueuedIngestionMessage>(body, Json);
            if (pointer is null)
            {
                reason = "pointer message deserialized to null";
                return null;
            }

            var validation = pointer.Validate();
            if (!validation.Ok)
            {
                reason = validation.Reason;
                return null;
            }

            return pointer;
        }
        catch (JsonException ex)
        {
            reason = $"pointer message is not valid JSON: {ex.Message}";
            return null;
        }
    }

    public async Task<ProcessingOutcome> ProcessAsync(QueuedIngestionMessage pointer, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(pointer);

        if (!_streamMap.TryGetStream(pointer.TableName, out var streamName))
            return ProcessingOutcome.Poison($"table '{pointer.TableName}' has no configured DCR stream");

        var read = await _blobReader.ReadAsync(pointer, ct).ConfigureAwait(false);
        if (!read.Ok)
        {
            return read.Permanent
                ? ProcessingOutcome.Poison(read.Reason!)
                : throw new InvalidOperationException(read.Reason);
        }

        InventoryEnvelope? envelope;
        try
        {
            envelope = JsonSerializer.Deserialize<InventoryEnvelope>(read.Content, Json);
        }
        catch (JsonException ex)
        {
            return ProcessingOutcome.Poison($"payload is not valid JSON: {ex.Message}");
        }

        if (envelope is null)
            return ProcessingOutcome.Poison("payload deserialized to null");

        var structural = envelope.Validate(_options.MaxRecordsPerEnvelope);
        if (!structural.Ok)
            return ProcessingOutcome.Poison($"payload envelope is invalid: {structural.Reason}");

        // The frontend already proved the certificate is bound to this device id.
        // Re-checking that the payload still agrees with the pointer catches a
        // blob that was swapped between intake and processing.
        if (!string.Equals(envelope.EntraDeviceId, pointer.EntraDeviceId, StringComparison.OrdinalIgnoreCase))
            return ProcessingOutcome.Poison("payload device id does not match the pointer device id");

        if (!string.Equals(envelope.TableName, pointer.TableName, StringComparison.Ordinal))
            return ProcessingOutcome.Poison("payload table name does not match the pointer table name");

        var rows = InventoryRowFactory.BuildRows(envelope, pointer.CorrelationId, DateTimeOffset.UtcNow);

        // Chunk and detect uningestible rows BEFORE any upload. A row larger than
        // the chunk budget can never be ingested, so this payload will never
        // succeed as-is. Uploading the rows that do fit and reporting success
        // would silently commit a partial sample and — with blob deletion enabled
        // — destroy the only copy of the rows that were dropped. Dead-lettering
        // the whole message instead keeps the payload intact and recoverable.
        var batch = _publisher.PrepareBatch(rows);
        if (batch.HasUningestibleRows)
        {
            _log.LogError(
                "Rejecting uningestible payload for correlationId={CorrelationId}: {Count} of {Total} record(s) exceed {Limit} bytes.",
                pointer.CorrelationId, batch.OversizedRows.Count, batch.TotalRows, batch.MaxChunkBytes);

            return ProcessingOutcome.Poison(batch.DescribeUningestibleRows());
        }

        LogsIngestionPublisher.UploadResult upload;
        try
        {
            upload = await _publisher
                .UploadAsync(streamName, batch, pointer.CorrelationId, ct)
                .ConfigureAwait(false);
        }
        catch (LogsIngestionException ex) when (ex.Permanent)
        {
            // A permanent ingestion rejection (schema mismatch, unknown stream,
            // malformed column type, ...) will fail identically on every redelivery.
            // Letting it propagate would burn the whole delivery budget and then
            // dead-letter with a generic "max delivery count exceeded" reason that
            // says nothing about the cause. Converting it to a poison outcome here
            // dead-letters immediately, with the status and chunk position, and
            // returns BEFORE the deletion block so the payload blob survives.
            _log.LogError(
                ex,
                "Permanent ingestion failure for correlationId={CorrelationId}: status={Status} chunksCommitted={Committed}/{Total}",
                pointer.CorrelationId, ex.StatusCode, ex.ChunksCommitted, ex.ChunkCount);

            return ProcessingOutcome.Poison(DescribePermanentIngestionFailure(ex));
        }

        // Reached only after every chunk committed, so deletion can never discard
        // a payload whose rows were not fully ingested.
        if (_options.DeleteBlobAfterIngestion)
            await _blobReader.TryDeleteAsync(pointer, read.ETag, ct).ConfigureAwait(false);

        _log.LogInformation(
            "Ingestion complete: correlationId={CorrelationId} table={Table} stream={Stream} chunks={Chunks} rows={Rows}",
            pointer.CorrelationId, pointer.TableName, streamName, upload.ChunksSent, upload.RowsSent);

        return ProcessingOutcome.Success(upload.RowsSent);
    }

    /// <summary>
    /// Operator-facing dead-letter reason for a permanent ingestion rejection.
    /// </summary>
    public static string DescribePermanentIngestionFailure(LogsIngestionException ex)
    {
        ArgumentNullException.ThrowIfNull(ex);

        var partial = ex.ChunksCommitted > 0
            ? $" WARNING: {ex.ChunksCommitted} of {ex.ChunkCount} chunk(s) had already committed, so a replay of this "
                + "payload will duplicate those rows."
            : " No chunks committed, so this payload can be replayed safely once the cause is fixed.";

        return $"Logs Ingestion permanently rejected this payload with status {ex.StatusCode}. "
            + $"{ex.Message}{partial} The payload blob is retained for remediation.";
    }
}
