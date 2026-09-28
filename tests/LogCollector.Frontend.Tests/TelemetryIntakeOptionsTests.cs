using LogCollector.Frontend.Services;
using LogCollector.Shared.Tests;
using Xunit;

namespace LogCollector.Frontend.Tests;

public sealed class TelemetryIntakeOptionsTests
{
    [Fact]
    public void EntraDeviceValidationDefaultsToEnabled()
    {
        var options = new EntraDeviceValidationOptions(TestCertificates.Config([]));

        Assert.True(options.Enabled);
        Assert.Equal(TimeSpan.FromMinutes(240), options.PositiveCacheDuration);
    }

    [Fact]
    public void InvalidEntraDeviceValidationValueFailsStartup()
    {
        var config = TestCertificates.Config([("EntraDeviceValidation:Enabled", "sometimes")]);

        var exception = Assert.Throws<InvalidOperationException>(
            () => new EntraDeviceValidationOptions(config));

        Assert.Contains("true", exception.Message);
        Assert.Contains("false", exception.Message);
    }

    [Theory]
    [InlineData("0", 0)]
    [InlineData("15", 15)]
    [InlineData("1440", 1440)]
    public void EntraPositiveCacheDurationIsConfigurable(string configured, int expectedMinutes)
    {
        var config = TestCertificates.Config(
            [("EntraDeviceValidation:PositiveCacheMinutes", configured)]);

        var options = new EntraDeviceValidationOptions(config);

        Assert.Equal(TimeSpan.FromMinutes(expectedMinutes), options.PositiveCacheDuration);
    }

    [Theory]
    [InlineData("-1")]
    [InlineData("1441")]
    [InlineData("10.5")]
    public void InvalidEntraPositiveCacheDurationFailsStartup(string configured)
    {
        var config = TestCertificates.Config(
            [("EntraDeviceValidation:PositiveCacheMinutes", configured)]);

        var exception = Assert.Throws<InvalidOperationException>(
            () => new EntraDeviceValidationOptions(config));

        Assert.Contains("0 to 1440", exception.Message);
    }

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
