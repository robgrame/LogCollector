using System.Text.Json;
using LogCollector.Shared.Models;
using LogCollector.Worker.Services;
using Xunit;

namespace LogCollector.Worker.Tests.Services;

/// <summary>
/// Covers the disposition contract the Service Bus function keys off. A payload
/// the worker can never ingest must be reported as <i>permanent</i>, because that
/// is what routes it to the dead-letter queue with the blob left intact instead of
/// being retried, completed, or silently deleted.
/// </summary>
public sealed class TelemetryIngestionProcessorOutcomeTests
{
    [Fact]
    public void Poison_IsPermanentAndNotSuccessful()
    {
        var outcome = TelemetryIngestionProcessor.ProcessingOutcome.Poison("uningestible");

        Assert.False(outcome.Ok);
        Assert.True(outcome.Permanent);
        Assert.Equal("uningestible", outcome.Reason);
        Assert.Equal(0, outcome.RowsIngested);
    }

    [Fact]
    public void Success_IsNotPermanentAndCarriesTheIngestedCount()
    {
        var outcome = TelemetryIngestionProcessor.ProcessingOutcome.Success(42);

        Assert.True(outcome.Ok);
        Assert.False(outcome.Permanent);
        Assert.Null(outcome.Reason);
        Assert.Equal(42, outcome.RowsIngested);
    }

    [Fact]
    public void OversizedPayload_ProducesAPermanentOutcomeCarryingTheRemediationDetail()
    {
        // Mirrors the processor's decision: prepare, detect, and convert straight
        // to a permanent outcome without an upload step in between.
        const int budget = 64 * 1024;
        var rows = new List<JsonElement>
        {
            WorkerTestHost.Row(0, 64),
            WorkerTestHost.Row(1, budget * 2),
        };

        var batch = LogsIngestionPublisher.Prepare(rows, budget);
        Assert.True(batch.HasUningestibleRows);

        var outcome = TelemetryIngestionProcessor.ProcessingOutcome.Poison(batch.DescribeUningestibleRows());

        Assert.True(outcome.Permanent);
        Assert.False(outcome.Ok);
        Assert.Contains("#1", outcome.Reason!, StringComparison.Ordinal);
        Assert.Contains("retained for remediation", outcome.Reason!, StringComparison.Ordinal);
    }

    [Fact]
    public void TryParsePointer_AcceptsAValidPointer()
    {
        // Digest and size are computed rather than transcribed: QueuedIngestionMessage
        // validates that payloadSha256 really decodes to 32 bytes.
        var digest = Convert.ToBase64String(new byte[32]);

        var body = $$"""
        {
          "version": "LOGCOLLECTOR-POINTER-V1",
          "correlationId": "abc123",
          "tableName": "InventoryWindows_CL",
          "containerName": "inventory-payloads",
          "blobName": "InventoryWindows_CL/2026/04/01/abc123.json",
          "payloadSha256": "{{digest}}",
          "payloadBytes": 4096,
          "entraDeviceId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        }
        """;

        var pointer = TelemetryIngestionProcessor.TryParsePointer(body, out var reason);

        Assert.True(pointer is not null, $"pointer was rejected: {reason}");
        Assert.Null(reason);
        Assert.Equal("InventoryWindows_CL", pointer!.TableName);
        Assert.Equal(4096, pointer.PayloadBytes);
    }

    [Theory]
    [InlineData("{ not json", "not valid JSON")]
    [InlineData("{\"version\":\"LOGCOLLECTOR-POINTER-V0\"}", "unsupported pointer version")]
    public void TryParsePointer_ReportsWhyAMessageIsUnusableInsteadOfThrowing(string body, string expectedFragment)
    {
        var pointer = TelemetryIngestionProcessor.TryParsePointer(body, out var reason);

        Assert.Null(pointer);
        Assert.NotNull(reason);
        Assert.Contains(expectedFragment, reason!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TryParsePointer_RejectsATraversalShapedBlobName()
    {
        // Every other field is valid, so the traversal rule is unambiguously the
        // one under test.
        var pointer = new QueuedIngestionMessage
        {
            CorrelationId = "abc",
            TableName = "InventoryWindows_CL",
            ContainerName = "inventory-payloads",
            BlobName = "../../secrets.json",
            PayloadSha256 = Convert.ToBase64String(new byte[32]),
            PayloadBytes = 4096,
            EntraDeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
        };

        var body = JsonSerializer.Serialize(pointer, new JsonSerializerOptions(JsonSerializerDefaults.Web));

        Assert.Null(TelemetryIngestionProcessor.TryParsePointer(body, out var reason));
        Assert.Contains("canonical relative blob path", reason!, StringComparison.Ordinal);
    }
}
