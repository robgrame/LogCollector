using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Monitor.Ingestion;
using LogCollector.Shared.Ingestion;
using Microsoft.Extensions.Logging;

namespace LogCollector.Worker.Services;

/// <summary>
/// Uploads rows to Azure Monitor via the Logs Ingestion API.
/// </summary>
/// <remarks>
/// The SDK's own retry policy is disabled in <c>Program.cs</c> so that this class
/// owns retry timing end to end. That matters because Azure Monitor throttles per
/// DCR and answers with <c>Retry-After</c>: a hidden retry layer would burn the
/// attempt budget before the server-supplied delay was ever honoured, and the
/// backoff seen in telemetry would not be the backoff actually applied.
/// </remarks>
public sealed class LogsIngestionPublisher
{
    private readonly LogsIngestionClient _client;
    private readonly WorkerIngestionOptions _options;
    private readonly ILogger<LogsIngestionPublisher> _log;
    private readonly Func<double> _jitter;

    public LogsIngestionPublisher(
        LogsIngestionClient client,
        WorkerIngestionOptions options,
        ILogger<LogsIngestionPublisher> log)
        : this(client, options, log, Random.Shared.NextDouble)
    {
    }

    internal LogsIngestionPublisher(
        LogsIngestionClient client,
        WorkerIngestionOptions options,
        ILogger<LogsIngestionPublisher> log,
        Func<double> jitter)
    {
        _client = client;
        _options = options;
        _log = log;
        _jitter = jitter;
    }

    /// <summary>One row that can never fit inside the chunk budget.</summary>
    public sealed record OversizedRow(int Index, int Bytes);

    /// <summary>
    /// A batch that has been chunked but not yet sent. Producing this before any
    /// network call is what lets the caller reject an uningestible payload
    /// <i>atomically</i> — nothing is uploaded, so nothing is half-ingested.
    /// </summary>
    public sealed record PreparedBatch(
        IReadOnlyList<IReadOnlyList<JsonElement>> Chunks,
        IReadOnlyList<OversizedRow> OversizedRows,
        int TotalRows,
        int MaxChunkBytes)
    {
        /// <summary>True when at least one row exceeds the budget at any batch size.</summary>
        public bool HasUningestibleRows => OversizedRows.Count > 0;

        public int RowsInChunks => Chunks.Sum(chunk => chunk.Count);

        /// <summary>
        /// Operator-facing explanation used as the dead-letter reason. It names the
        /// offending record indexes and sizes so the payload can be corrected and
        /// replayed from the retained blob.
        /// </summary>
        public string DescribeUningestibleRows()
        {
            const int MaxListed = 20;

            var listed = OversizedRows
                .Take(MaxListed)
                .Select(row => $"#{row.Index} ({row.Bytes} bytes)");

            var detail = string.Join(", ", listed);
            if (OversizedRows.Count > MaxListed)
                detail += $", … and {OversizedRows.Count - MaxListed} more";

            return $"payload contains {OversizedRows.Count} record(s) larger than the "
                + $"{MaxChunkBytes}-byte Logs Ingestion chunk budget and can never be ingested: {detail}. "
                + $"No rows were uploaded and the payload blob is retained for remediation "
                + $"(total records in payload: {TotalRows}).";
        }
    }

    public sealed record UploadResult(int ChunksSent, int RowsSent);

    /// <summary>Chunks <paramref name="rows"/> using the configured budget. No I/O.</summary>
    public PreparedBatch PrepareBatch(IReadOnlyList<JsonElement> rows)
        => Prepare(rows, _options.MaxChunkBytes);

    /// <summary>
    /// Pure chunking and oversize detection, separated from upload so the decision
    /// to reject a payload is made before a single byte is sent.
    /// </summary>
    public static PreparedBatch Prepare(IReadOnlyList<JsonElement> rows, int maxChunkBytes)
    {
        ArgumentNullException.ThrowIfNull(rows);

        var chunking = LogsIngestionChunker.Chunk(rows, maxChunkBytes);

        var oversized = chunking.OversizedRowIndexes
            .Select(index => new OversizedRow(index, LogsIngestionChunker.MeasureUtf8(rows[index])))
            .ToArray();

        return new PreparedBatch(chunking.Chunks, oversized, rows.Count, maxChunkBytes);
    }

    public async Task<UploadResult> UploadAsync(
        string streamName,
        PreparedBatch batch,
        string correlationId,
        CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(streamName);
        ArgumentNullException.ThrowIfNull(batch);

        // Defence in depth. An uningestible payload must be dead-lettered whole by
        // the caller; partially uploading the rows that happen to fit would commit
        // an incomplete inventory sample that no later replay could correct,
        // because the duplicate rows would then be ingested twice.
        if (batch.HasUningestibleRows)
        {
            throw new InvalidOperationException(
                "Refusing to upload a batch containing rows that exceed the chunk budget. "
                + batch.DescribeUningestibleRows());
        }

        var rowsSent = 0;

        for (var i = 0; i < batch.Chunks.Count; i++)
        {
            var chunk = batch.Chunks[i];
            await UploadChunkAsync(streamName, chunk, correlationId, i + 1, batch.Chunks.Count, ct).ConfigureAwait(false);
            rowsSent += chunk.Count;
        }

        return new UploadResult(batch.Chunks.Count, rowsSent);
    }

    private async Task UploadChunkAsync(
        string streamName,
        IReadOnlyList<JsonElement> chunk,
        string correlationId,
        int chunkNumber,
        int chunkCount,
        CancellationToken ct)
    {
        var payload = LogsIngestionChunker.SerializeChunk(chunk);
        var chunksCommitted = chunkNumber - 1;

        for (var attempt = 1; ; attempt++)
        {
            Response response;
            try
            {
                response = await _client.UploadAsync(
                    _options.DataCollectionRuleId,
                    streamName,
                    RequestContent.Create(payload),
                    contentEncoding: null,
                    context: new RequestContext { ErrorOptions = ErrorOptions.NoThrow, CancellationToken = ct })
                    .ConfigureAwait(false);
            }
            catch (RequestFailedException ex)
            {
                // Normalise onto LogsIngestionException so callers classify one
                // exception type. A raw RequestFailedException escaping here would
                // be indistinguishable from a transient fault and would silently
                // fall through to delivery-count retry.
                if (!RetryAfterPolicy.IsTransient(ex.Status))
                {
                    throw new LogsIngestionException(
                        $"Logs Ingestion rejected chunk {chunkNumber}/{chunkCount} for stream '{streamName}' "
                        + $"with status {ex.Status}: {ex.Message}",
                        ex.Status, permanent: true, chunksCommitted, chunkCount);
                }

                if (attempt >= _options.MaxAttempts)
                {
                    throw new LogsIngestionException(
                        $"Logs Ingestion failed chunk {chunkNumber}/{chunkCount} for stream '{streamName}' "
                        + $"after {attempt} attempt(s) with status {ex.Status}: {ex.Message}",
                        ex.Status, permanent: false, chunksCommitted, chunkCount);
                }

                await DelayAsync(attempt, null, ct).ConfigureAwait(false);
                continue;
            }

            if (!response.IsError)
            {
                _log.LogInformation(
                    "Ingested chunk {Chunk}/{ChunkCount} ({Rows} rows, {Bytes} bytes) into {Stream} for correlationId={CorrelationId}",
                    chunkNumber, chunkCount, chunk.Count, payload.Length, streamName, correlationId);
                return;
            }

            var retryAfter = response.Headers.TryGetValue("Retry-After", out var retryAfterHeader)
                ? RetryAfterPolicy.ParseRetryAfter(retryAfterHeader, DateTimeOffset.UtcNow)
                : null;

            var transient = RetryAfterPolicy.IsTransient(response.Status);

            if (!transient || attempt >= _options.MaxAttempts)
            {
                throw new LogsIngestionException(
                    $"Logs Ingestion returned {response.Status} for stream '{streamName}' "
                    + $"(chunk {chunkNumber}/{chunkCount}, attempt {attempt}).",
                    response.Status,
                    permanent: !transient,
                    chunksCommitted,
                    chunkCount);
            }

            _log.LogWarning(
                "Logs Ingestion returned {Status} for chunk {Chunk}/{ChunkCount}; retrying (attempt {Attempt}/{Max}, retryAfter={RetryAfter}).",
                response.Status, chunkNumber, chunkCount, attempt, _options.MaxAttempts, retryAfter?.ToString() ?? "n/a");

            await DelayAsync(attempt, retryAfter, ct).ConfigureAwait(false);
        }
    }

    private Task DelayAsync(int attempt, TimeSpan? retryAfter, CancellationToken ct)
    {
        var delay = RetryAfterPolicy.ComputeDelay(
            attempt, retryAfter, _options.BaseRetryDelay, _options.MaxRetryDelay, _jitter);
        return delay > TimeSpan.Zero ? Task.Delay(delay, ct) : Task.CompletedTask;
    }
}

/// <summary>Raised when the Logs Ingestion API rejects a chunk.</summary>
public sealed class LogsIngestionException : Exception
{
    public LogsIngestionException(string message, int statusCode, bool permanent, int chunksCommitted, int chunkCount)
        : base(message)
    {
        StatusCode = statusCode;
        Permanent = permanent;
        ChunksCommitted = chunksCommitted;
        ChunkCount = chunkCount;
    }

    public int StatusCode { get; }

    /// <summary>When true the request will never succeed and must not be retried.</summary>
    public bool Permanent { get; }

    /// <summary>
    /// Chunks that committed before the failure. Non-zero means the sample landed
    /// partially, which a replay would duplicate — the operator has to know.
    /// </summary>
    public int ChunksCommitted { get; }

    public int ChunkCount { get; }
}
