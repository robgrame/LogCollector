using System.Text.Json;
using LogCollector.Shared.Ingestion;
using LogCollector.Shared.Models;
using Xunit;

namespace LogCollector.Shared.Tests.Ingestion;

public sealed class InventoryRowFactoryTests
{
    private const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    private static readonly DateTimeOffset Ingested = new(2026, 4, 1, 8, 30, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Collected = new(2026, 4, 1, 6, 0, 0, TimeSpan.Zero);

    private static InventoryEnvelope Envelope(string recordJson, Dictionary<string, string>? properties = null)
        => new()
        {
            TableName = "InventoryWindows_CL",
            EntraDeviceId = DeviceId,
            DeviceName = "WKS-001",
            IntuneDeviceId = "intune-id",
            Source = "WindowsScheduledTask",
            CollectedAtUtc = Collected,
            Properties = properties,
            Records = [JsonDocument.Parse(recordJson).RootElement.Clone()],
        };

    [Fact]
    public void BuildRows_StampsTheServerAssertedColumns()
    {
        var rows = InventoryRowFactory.BuildRows(
            Envelope("{\"RecordType\":\"Hardware\",\"Model\":\"X1\"}"), "corr-1", Ingested);

        var row = Assert.Single(rows);

        Assert.Equal("Hardware", row.GetProperty("RecordType").GetString());
        Assert.Equal("X1", row.GetProperty("Model").GetString());
        Assert.Equal(DeviceId, row.GetProperty("EntraDeviceId").GetString());
        Assert.Equal("WKS-001", row.GetProperty("DeviceName").GetString());
        Assert.Equal("corr-1", row.GetProperty("CorrelationId").GetString());
        Assert.Equal("WindowsScheduledTask", row.GetProperty("Source").GetString());
        Assert.Equal(Ingested.UtcDateTime.ToString("O"), row.GetProperty("TimeGenerated").GetString());
        Assert.Equal(Collected.UtcDateTime.ToString("O"), row.GetProperty("CollectedAtUtc").GetString());
    }

    [Fact]
    public void BuildRows_IgnoresAClientAttemptToSpoofItsOwnIdentity()
    {
        // The single most important property of this factory: a device cannot
        // write inventory attributed to another device by putting EntraDeviceId
        // in its own record.
        var envelope = Envelope(
            "{\"RecordType\":\"Hardware\",\"EntraDeviceId\":\"00000000-0000-0000-0000-000000000000\",\"CorrelationId\":\"forged\"}");

        var row = Assert.Single(InventoryRowFactory.BuildRows(envelope, "corr-1", Ingested));

        Assert.Equal(DeviceId, row.GetProperty("EntraDeviceId").GetString());
        Assert.Equal("corr-1", row.GetProperty("CorrelationId").GetString());
    }

    [Fact]
    public void BuildRows_CopiesEnvelopePropertiesOntoEveryRow()
    {
        var envelope = Envelope(
            "{\"RecordType\":\"Software\"}",
            new Dictionary<string, string> { ["CollectorVersion"] = "1.0.0", ["CollectedAreas"] = "Software" });

        var row = Assert.Single(InventoryRowFactory.BuildRows(envelope, "corr-1", Ingested));

        Assert.Equal("1.0.0", row.GetProperty("CollectorVersion").GetString());
        Assert.Equal("Software", row.GetProperty("CollectedAreas").GetString());
    }

    [Fact]
    public void BuildRows_LetsRecordFieldsWinOverEnvelopeProperties()
    {
        var envelope = Envelope(
            "{\"RecordType\":\"Software\",\"CollectorVersion\":\"record-wins\"}",
            new Dictionary<string, string> { ["CollectorVersion"] = "envelope-loses" });

        var row = Assert.Single(InventoryRowFactory.BuildRows(envelope, "corr-1", Ingested));

        Assert.Equal("record-wins", row.GetProperty("CollectorVersion").GetString());
    }

    [Fact]
    public void BuildRows_DropsReservedColumnNamesFromEnvelopeProperties()
    {
        var envelope = Envelope(
            "{\"RecordType\":\"Software\"}",
            new Dictionary<string, string> { ["DeviceName"] = "spoofed" });

        var row = Assert.Single(InventoryRowFactory.BuildRows(envelope, "corr-1", Ingested));

        Assert.Equal("WKS-001", row.GetProperty("DeviceName").GetString());
    }

    [Fact]
    public void BuildRows_FallsBackToTheIngestionTimeWhenCollectionTimeIsAbsent()
    {
        var envelope = Envelope("{\"RecordType\":\"Hardware\"}");
        envelope.CollectedAtUtc = null;

        var row = Assert.Single(InventoryRowFactory.BuildRows(envelope, "corr-1", Ingested));

        Assert.Equal(Ingested.UtcDateTime.ToString("O"), row.GetProperty("CollectedAtUtc").GetString());
    }

    [Fact]
    public void BuildRows_PreservesNonStringTypes()
    {
        var envelope = Envelope("{\"LogicalProcessors\":8,\"TpmPresent\":true}");

        var row = Assert.Single(InventoryRowFactory.BuildRows(envelope, "corr-1", Ingested));

        Assert.Equal(8, row.GetProperty("LogicalProcessors").GetInt32());
        Assert.True(row.GetProperty("TpmPresent").GetBoolean());
    }

    [Fact]
    public void BuildRows_UsesStableIndexesAndRejectsSpoofedIndexes()
    {
        var envelope = Envelope("{\"RecordIndex\":99,\"Model\":\"A\"}");
        envelope.Records!.Add(envelope.Records[0].Clone());
        var first = InventoryRowFactory.BuildRows(envelope, "stable-id", Ingested);
        var retry = InventoryRowFactory.BuildRows(envelope, "stable-id", Ingested.AddMinutes(1));
        Assert.Equal(0, first[0].GetProperty("RecordIndex").GetInt32());
        Assert.Equal(1, first[1].GetProperty("RecordIndex").GetInt32());
        Assert.Equal(first[1].GetProperty("RecordIndex").GetInt32(), retry[1].GetProperty("RecordIndex").GetInt32());
    }

    [Fact]
    public void BuildRows_ReturnsAnEmptyListForAnEnvelopeWithNoRecords()
    {
        var envelope = Envelope("{}");
        envelope.Records = null;

        Assert.Empty(InventoryRowFactory.BuildRows(envelope, "corr-1", Ingested));
    }
}
