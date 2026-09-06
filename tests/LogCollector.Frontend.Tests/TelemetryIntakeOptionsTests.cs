using LogCollector.Frontend.Services;
using LogCollector.Shared.Tests;
using Xunit;

namespace LogCollector.Frontend.Tests;

public sealed class TelemetryIntakeOptionsTests
{
    [Theory]
    [InlineData("telemetry-ingestion", "legacy-ingestion", "telemetry-ingestion")]
    [InlineData("telemetry-ingestion", null, "telemetry-ingestion")]
    [InlineData(null, "legacy-ingestion", "legacy-ingestion")]
    [InlineData(null, null, "inventory-ingestion")]
    public async Task QueuePrecedenceAndLegacyFallbackAreUsedByActualPublisher(
        string? queue, string? legacyQueue, string expected)
    {
        var settings = new List<(string, string)>();
        if (queue is not null) settings.Add(("ServiceBus:QueueName", queue));
        if (legacyQueue is not null) settings.Add(("ServiceBus:InventoryQueue", legacyQueue));
        var options = new TelemetryIntakeOptions(TestCertificates.Config([.. settings]));
        Assert.Equal(expected, options.QueueName);
        using var h = new FrontendTestHarness(extraSettings: [.. settings]);
        var body = TelemetryIngestFunctionTests.Body();

        var result = await h.Invoke(false, h.Request(false, body));

        TelemetryIngestFunctionTests.AssertPublished(h, result, body, "HealthChecks_CL", "EnterprisePki");
        Assert.Equal(expected, Assert.Single(h.ServiceBus.Queues));
    }
}
