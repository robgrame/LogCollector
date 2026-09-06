using System.Net;
using LogCollector.Worker.Services;
using Xunit;

namespace LogCollector.Worker.Tests.Services;

/// <summary>
/// End-to-end processor behaviour driven through a fake HTTP transport for both
/// blob storage and Logs Ingestion.
///
/// The rule under test: a permanent ingestion rejection must become a
/// <i>permanent</i> processing outcome so the function dead-letters immediately,
/// and it must return before the deletion step so the payload blob survives for
/// remediation. Before this fix the exception escaped the processor entirely, the
/// function had no catch, and the message was silently redelivered until the
/// broker dead-lettered it with a reason that named no cause.
/// </summary>
public sealed class TelemetryIngestionProcessorFailureTests
{
    [Fact]
    public async Task ProcessAsync_SucceedsWhenIngestionAccepts()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.NoContent);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(), handler);

        var outcome = await processor.ProcessAsync(WorkerTestHost.Pointer(payload), CancellationToken.None);

        Assert.True(outcome.Ok, outcome.Reason);
        Assert.False(outcome.Permanent);
        Assert.Equal(2, outcome.RowsIngested);
    }

    [Fact]
    public async Task ProcessAsync_TurnsAPermanentIngestionRejectionIntoAPoisonOutcome()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.BadRequest);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(), handler);

        var outcome = await processor.ProcessAsync(WorkerTestHost.Pointer(payload), CancellationToken.None);

        Assert.False(outcome.Ok);
        Assert.True(outcome.Permanent, "a 400 will fail identically on every redelivery");
        Assert.Contains("status 400", outcome.Reason!, StringComparison.Ordinal);
        Assert.Contains("retained for remediation", outcome.Reason!, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ProcessAsync_DoesNotThrowOnAPermanentIngestionRejection()
    {
        // Throwing would bypass the function's explicit dead-letter path, because
        // TelemetryIngestionFunction has no catch for it.
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.Forbidden);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(), handler);

        var outcome = await processor.ProcessAsync(WorkerTestHost.Pointer(payload), CancellationToken.None);

        Assert.True(outcome.Permanent);
        Assert.Equal(0, outcome.RowsIngested);
    }

    [Fact]
    public async Task ProcessAsync_NeverDeletesTheBlobAfterAPermanentIngestionRejection()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.BadRequest);

        // Deletion is explicitly ENABLED so the test proves the poison path skips
        // it, rather than passing because the feature happens to be off.
        var options = WorkerTestHost.Options(deleteBlobAfterIngestion: true);
        var processor = WorkerTestHost.Processor(options, handler);

        var outcome = await processor.ProcessAsync(WorkerTestHost.Pointer(payload), CancellationToken.None);

        Assert.True(outcome.Permanent);
        Assert.Equal(0, handler.CountOf("DELETE", "/inventory-payloads/"));
    }

    [Fact]
    public async Task ProcessAsync_DeletesTheBlobOnlyAfterEveryChunkCommitted()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.NoContent);
        var options = WorkerTestHost.Options(deleteBlobAfterIngestion: true);
        var processor = WorkerTestHost.Processor(options, handler);

        var outcome = await processor.ProcessAsync(WorkerTestHost.Pointer(payload), CancellationToken.None);

        Assert.True(outcome.Ok, outcome.Reason);
        Assert.Equal(1, handler.CountOf("DELETE", "/inventory-payloads/"));
    }

    [Fact]
    public async Task ProcessAsync_RethrowsATransientIngestionFailureSoTheMessageIsRedelivered()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.ServiceUnavailable);
        var options = WorkerTestHost.Options(maxAttempts: 2, deleteBlobAfterIngestion: true);
        var processor = WorkerTestHost.Processor(options, handler);

        // Transient failures must NOT be dead-lettered; abandoning the lock is what
        // gives the service time to recover.
        var ex = await Assert.ThrowsAsync<LogsIngestionException>(
            () => processor.ProcessAsync(WorkerTestHost.Pointer(payload), CancellationToken.None));

        Assert.False(ex.Permanent);
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal(0, handler.CountOf("DELETE", "/inventory-payloads/"));
    }

    [Fact]
    public async Task ProcessAsync_DeadLettersAPayloadWhoseDigestDoesNotMatch()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.NoContent);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(), handler);

        var pointer = WorkerTestHost.Pointer(payload);
        pointer.PayloadSha256 = Convert.ToBase64String(new byte[32]);

        var outcome = await processor.ProcessAsync(pointer, CancellationToken.None);

        Assert.True(outcome.Permanent);
        Assert.Contains("digest", outcome.Reason!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, handler.CountOf("POST", "/dataCollectionRules/"));
    }

    [Fact]
    public async Task ProcessAsync_DeadLettersAPayloadWhoseByteLengthDoesNotMatchIntake()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.NoContent);

        // Deletion enabled so the test proves the truncation guard, not the flag.
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(deleteBlobAfterIngestion: true), handler);

        var pointer = WorkerTestHost.Pointer(payload);
        pointer.PayloadBytes = payload.LongLength + 1;

        var outcome = await processor.ProcessAsync(pointer, CancellationToken.None);

        // A truncated or padded blob is not the payload the frontend authenticated,
        // so it must never be ingested and must never be deleted.
        Assert.False(outcome.Ok);
        Assert.True(outcome.Permanent);
        Assert.Contains("byte length", outcome.Reason!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, handler.CountOf("POST", "/dataCollectionRules/"));
        Assert.Equal(0, handler.CountOf("DELETE", "/inventory-payloads/"));
    }

    [Fact]
    public async Task ProcessAsync_DeadLettersAPointerCarryingNoDigest()
    {
        // Defence in depth: QueuedIngestionMessage.Validate already rejects an
        // empty digest at parse time, so this asserts the reader holds the line
        // independently of the parse layer.
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.NoContent);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(deleteBlobAfterIngestion: true), handler);

        var pointer = WorkerTestHost.Pointer(payload);
        pointer.PayloadSha256 = string.Empty;

        var outcome = await processor.ProcessAsync(pointer, CancellationToken.None);

        Assert.True(outcome.Permanent);
        Assert.Contains("digest is required", outcome.Reason!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, handler.CountOf("POST", "/dataCollectionRules/"));
        Assert.Equal(0, handler.CountOf("DELETE", "/inventory-payloads/"));
    }

    [Fact]
    public async Task ProcessAsync_DeadLettersAnUnmappedTableWithoutTouchingStorage()
    {
        var payload = WorkerTestHost.EnvelopePayload();
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.NoContent);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(), handler);

        var pointer = WorkerTestHost.Pointer(payload);
        pointer.TableName = "SomeOtherTable_CL";

        var outcome = await processor.ProcessAsync(pointer, CancellationToken.None);

        Assert.True(outcome.Permanent);
        Assert.Contains("no configured DCR stream", outcome.Reason!, StringComparison.Ordinal);
        Assert.Empty(handler.Requests);
    }
}
