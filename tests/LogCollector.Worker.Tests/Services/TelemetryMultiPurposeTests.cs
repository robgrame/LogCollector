using System.Net;
using System.Text.Json;
using LogCollector.Shared.Models;
using Xunit;

namespace LogCollector.Worker.Tests.Services;

public sealed class TelemetryMultiPurposeTests
{
    private const string StreamMap =
        "RemediationResults_CL=Custom-RemediationResults_CL;HealthChecks_CL=Custom-HealthChecks_CL";

    [Theory]
    [InlineData(TelemetryEnvelope.CurrentVersion, "RemediationResults_CL", "DiskCleanup")]
    [InlineData(TelemetryEnvelope.CurrentVersion, "HealthChecks_CL", "ServiceHealth")]
    [InlineData(TelemetryEnvelope.LegacyVersion, "RemediationResults_CL", "DiskCleanup")]
    public async Task ProcessAsync_RoutesUnrelatedSchemasThroughTheSamePipeline(
        string version, string table, string source)
    {
        var record = table == "HealthChecks_CL"
            ? JsonSerializer.SerializeToElement(new { Service = "Spooler", Running = true })
            : JsonSerializer.SerializeToElement(new { Result = "Succeeded", FreedBytes = 123L });
        var payload = JsonSerializer.SerializeToUtf8Bytes(new TelemetryEnvelope
        {
            EnvelopeVersion = version,
            TableName = table,
            EntraDeviceId = WorkerTestHost.DeviceId,
            CollectedAtUtc = DateTimeOffset.UtcNow,
            Source = source,
            Records = [record],
        });
        var pointer = WorkerTestHost.Pointer(payload);
        pointer.TableName = table;
        pointer.BlobName = $"{table}/corr-1.json";
        pointer.Source = source;
        var handler = WorkerTestHost.PipelineHandler(payload, HttpStatusCode.NoContent);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(), handler, StreamMap);

        var outcome = await processor.ProcessAsync(pointer, CancellationToken.None);

        Assert.True(outcome.Ok, outcome.Reason);
        Assert.Equal(1, outcome.RowsIngested);
        Assert.Equal(1, handler.CountOf("POST", $"/streams/Custom-{table}"));
        Assert.Equal(0, handler.CountOf("POST", "Inventory"));
    }

    [Fact]
    public async Task ProcessAsync_RejectsUnconfiguredPurposeBeforeReadingBlob()
    {
        var handler = WorkerTestHost.PipelineHandler([], HttpStatusCode.NoContent);
        var processor = WorkerTestHost.Processor(WorkerTestHost.Options(), handler, StreamMap);
        var pointer = WorkerTestHost.Pointer(WorkerTestHost.EnvelopePayload());
        pointer.TableName = "UnapprovedPurpose_CL";

        var outcome = await processor.ProcessAsync(pointer, CancellationToken.None);

        Assert.False(outcome.Ok);
        Assert.True(outcome.Permanent);
        Assert.Empty(handler.Requests);
    }
}
