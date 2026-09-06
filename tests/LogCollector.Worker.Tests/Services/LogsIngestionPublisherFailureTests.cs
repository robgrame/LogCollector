using System.Net;
using LogCollector.Worker.Services;
using Xunit;

namespace LogCollector.Worker.Tests.Services;

/// <summary>
/// Covers the permanent-vs-transient classification of Logs Ingestion failures,
/// driven through a fake HTTP transport so the real retry loop, Retry-After
/// handling and exception construction all execute.
/// </summary>
public sealed class LogsIngestionPublisherFailureTests
{
    private const string Stream = WorkerTestHost.StreamName;

    private static LogsIngestionPublisher.PreparedBatch Batch(LogsIngestionPublisher publisher, int rows = 4)
        => publisher.PrepareBatch([.. Enumerable.Range(0, rows).Select(i => WorkerTestHost.Row(i, 64))]);

    [Fact]
    public async Task UploadAsync_SucceedsOn204()
    {
        var options = WorkerTestHost.Options();
        var handler = WorkerTestHost.PipelineHandler([], HttpStatusCode.NoContent);
        var publisher = WorkerTestHost.Publisher(options, handler);

        var result = await publisher.UploadAsync(Stream, Batch(publisher), "corr-1", CancellationToken.None);

        Assert.Equal(1, result.ChunksSent);
        Assert.Equal(4, result.RowsSent);
        Assert.Equal(1, handler.CountOf("POST", "/dataCollectionRules/"));
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest, 400)]
    [InlineData(HttpStatusCode.Forbidden, 403)]
    [InlineData(HttpStatusCode.NotFound, 404)]
    [InlineData(HttpStatusCode.RequestEntityTooLarge, 413)]
    public async Task UploadAsync_ClassifiesANonTransientStatusAsPermanentAndDoesNotRetry(HttpStatusCode status, int expected)
    {
        var options = WorkerTestHost.Options(maxAttempts: 5);
        var handler = WorkerTestHost.PipelineHandler([], status);
        var publisher = WorkerTestHost.Publisher(options, handler);

        var ex = await Assert.ThrowsAsync<LogsIngestionException>(
            () => publisher.UploadAsync(Stream, Batch(publisher), "corr-1", CancellationToken.None));

        Assert.True(ex.Permanent);
        Assert.Equal(expected, ex.StatusCode);

        // Retrying a deterministic rejection just multiplies the damage.
        Assert.Equal(1, handler.CountOf("POST", "/dataCollectionRules/"));
    }

    [Fact]
    public async Task UploadAsync_ClassifiesAnExhaustedTransientFailureAsNotPermanent()
    {
        var options = WorkerTestHost.Options(maxAttempts: 3);
        var handler = WorkerTestHost.PipelineHandler([], HttpStatusCode.ServiceUnavailable);
        var publisher = WorkerTestHost.Publisher(options, handler);

        var ex = await Assert.ThrowsAsync<LogsIngestionException>(
            () => publisher.UploadAsync(Stream, Batch(publisher), "corr-1", CancellationToken.None));

        // Not permanent: the message must go back on the queue, not to the
        // dead-letter queue, because the service may simply be having a bad minute.
        Assert.False(ex.Permanent);
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal(3, handler.CountOf("POST", "/dataCollectionRules/"));
    }

    [Fact]
    public async Task UploadAsync_HonoursRetryAfterOnATransientFailure()
    {
        var options = WorkerTestHost.Options(maxAttempts: 2);
        var handler = WorkerTestHost.PipelineHandler([], HttpStatusCode.TooManyRequests, retryAfter: "0");
        var publisher = WorkerTestHost.Publisher(options, handler);

        var ex = await Assert.ThrowsAsync<LogsIngestionException>(
            () => publisher.UploadAsync(Stream, Batch(publisher), "corr-1", CancellationToken.None));

        Assert.False(ex.Permanent);
        Assert.Equal(429, ex.StatusCode);
        Assert.Equal(2, handler.CountOf("POST", "/dataCollectionRules/"));
    }

    [Fact]
    public async Task UploadAsync_ReportsHowManyChunksCommittedBeforeAPermanentFailure()
    {
        // First chunk succeeds, second is rejected: a partial commit that a replay
        // would duplicate, so the count has to survive into the exception.
        var calls = 0;
        var handler = new RecordingHttpHandler(request =>
        {
            if ((request.RequestUri?.AbsolutePath ?? string.Empty).Contains("/dataCollectionRules/", StringComparison.OrdinalIgnoreCase))
            {
                calls++;
                return new HttpResponseMessage(calls == 1 ? HttpStatusCode.NoContent : HttpStatusCode.BadRequest)
                {
                    Content = new ByteArrayContent([]),
                };
            }
            return new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new ByteArrayContent([]) };
        });

        // WorkerIngestionOptions clamps the chunk budget to a 64 KiB floor, so the
        // rows have to be large enough to split at that size.
        var options = WorkerTestHost.Options();
        var publisher = WorkerTestHost.Publisher(options, handler);

        var batch = publisher.PrepareBatch([WorkerTestHost.Row(0, 40_000), WorkerTestHost.Row(1, 40_000)]);
        Assert.Equal(2, batch.Chunks.Count);

        var ex = await Assert.ThrowsAsync<LogsIngestionException>(
            () => publisher.UploadAsync(Stream, batch, "corr-1", CancellationToken.None));

        Assert.True(ex.Permanent);
        Assert.Equal(1, ex.ChunksCommitted);
        Assert.Equal(2, ex.ChunkCount);
    }

    [Fact]
    public void DescribePermanentIngestionFailure_WarnsWhenChunksAlreadyCommitted()
    {
        var ex = new LogsIngestionException("stub", 400, permanent: true, chunksCommitted: 2, chunkCount: 5);

        var reason = TelemetryIngestionProcessor.DescribePermanentIngestionFailure(ex);

        Assert.Contains("status 400", reason, StringComparison.Ordinal);
        Assert.Contains("2 of 5 chunk(s) had already committed", reason, StringComparison.Ordinal);
        Assert.Contains("duplicate", reason, StringComparison.Ordinal);
        Assert.Contains("retained for remediation", reason, StringComparison.Ordinal);
    }

    [Fact]
    public void DescribePermanentIngestionFailure_SaysReplayIsSafeWhenNothingCommitted()
    {
        var ex = new LogsIngestionException("stub", 400, permanent: true, chunksCommitted: 0, chunkCount: 3);

        var reason = TelemetryIngestionProcessor.DescribePermanentIngestionFailure(ex);

        Assert.Contains("No chunks committed", reason, StringComparison.Ordinal);
        Assert.Contains("replayed safely", reason, StringComparison.Ordinal);
    }
}
