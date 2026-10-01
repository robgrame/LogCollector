using System.Net;
using System.Text.Json;
using LogCollector.Shared.Models;
using LogCollector.Worker.Services;
using Xunit;

namespace LogCollector.Worker.Tests.Services;

public sealed class EndpointDataSprawlPointerCorrelationTests
{
    private const string TrustedCorrelation =
        "106BDD9FC64C41084F52B4CD0D8C11AFCD0E40B04071E36ABA97B8B149FD95C6";

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ProcessorUsesOnlyTrustedPointerCorrelation(bool registered)
    {
        var payload = Payload();
        var pointer = WorkerTestHost.Pointer(payload);
        pointer.TableName = SqlPersistenceOptions.DefaultTargetTable;
        pointer.BlobName =
            $"{pointer.TableName}/2026/04/01/corr-1.json";
        pointer.Source = "EndpointDataSprawlRemediator";
        pointer.UserCorrelationId =
            registered ? TrustedCorrelation : null;
        JsonElement persisted = default;
        var persistence = new WorkerTestHost.RecordingPersistence(
            (_, rows, _) =>
            {
                persisted = Assert.Single(rows);
                return Task.FromResult(
                    new PersistenceResult(
                        true,
                        rows.Count,
                        LogAnalyticsDeliveryState.Published));
            });
        var processor = WorkerTestHost.Processor(
            WorkerTestHost.Options(),
            WorkerTestHost.PipelineHandler(
                payload,
                HttpStatusCode.NoContent),
            $"{pointer.TableName}=Custom-{pointer.TableName}",
            persistence);

        var outcome = await processor.ProcessAsync(pointer, default);

        Assert.True(outcome.Ok, outcome.Reason);
        var correlation =
            persisted.GetProperty("UserCorrelationId");
        if (registered)
        {
            Assert.Equal(
                TrustedCorrelation,
                correlation.GetString());
        }
        else
        {
            Assert.Equal(JsonValueKind.Null, correlation.ValueKind);
        }
    }

    private static byte[] Payload() =>
        JsonSerializer.SerializeToUtf8Bytes(new TelemetryEnvelope
        {
            EnvelopeVersion = TelemetryEnvelope.CurrentVersion,
            TableName = SqlPersistenceOptions.DefaultTargetTable,
            EntraDeviceId = WorkerTestHost.DeviceId,
            DeviceName = "WKS-TEST",
            CorrelationId = "corr-1",
            Source = "EndpointDataSprawlRemediator",
            CollectedAtUtc = new DateTimeOffset(
                2026,
                4,
                1,
                6,
                0,
                0,
                TimeSpan.Zero),
            Records =
            [
                JsonSerializer.SerializeToElement(new
                {
                    RecordType = "CycleSummary",
                    UserCorrelationId = "CLIENT-CONTROLLED",
                    Status = "Completed",
                }),
            ],
        });
}
