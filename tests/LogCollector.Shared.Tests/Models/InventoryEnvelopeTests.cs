using System.Text.Json;
using LogCollector.Shared.Models;
using Xunit;

namespace LogCollector.Shared.Tests.Models;

public sealed class InventoryEnvelopeTests
{
    private const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";

    private static InventoryEnvelope Valid() => new()
    {
        EnvelopeVersion = InventoryEnvelope.CurrentVersion,
        TableName = "InventoryWindows_CL",
        EntraDeviceId = DeviceId,
        CollectedAtUtc = DateTimeOffset.UtcNow,
        Records = [JsonDocument.Parse("{\"RecordType\":\"Hardware\"}").RootElement.Clone()],
    };

    [Fact]
    public void Validate_AcceptsAWellFormedEnvelope()
    {
        Assert.True(Valid().Validate(1000).Ok);
    }

    [Fact]
    public void Validate_RejectsAnUnsupportedVersion()
    {
        var envelope = Valid();
        envelope.EnvelopeVersion = "LOGCOLLECTOR-INVENTORY-V0";

        var result = envelope.Validate(1000);

        Assert.False(result.Ok);
        Assert.Contains("unsupported envelopeVersion", result.Reason);
    }

    [Fact]
    public void Validate_RequiresATableName()
    {
        var envelope = Valid();
        envelope.TableName = null;

        Assert.Equal("tableName is required", envelope.Validate(1000).Reason);
    }

    [Theory]
    [InlineData("../etc/passwd")]
    [InlineData("Table Name")]
    [InlineData("9Leading_CL")]
    [InlineData("Table-Name_CL")]
    public void Validate_RejectsAnUnsafeTableName(string tableName)
    {
        var envelope = Valid();
        envelope.TableName = tableName;

        Assert.Equal("tableName contains unsupported characters", envelope.Validate(1000).Reason);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-a-guid")]
    public void Validate_RequiresAGuidDeviceId(string? deviceId)
    {
        var envelope = Valid();
        envelope.EntraDeviceId = deviceId;

        Assert.Equal("entraDeviceId must be a GUID", envelope.Validate(1000).Reason);
    }

    [Fact]
    public void Validate_RejectsAnEmptyRecordSet()
    {
        var envelope = Valid();
        envelope.Records = [];

        Assert.Equal("records must contain at least one entry", envelope.Validate(1000).Reason);
    }

    [Fact]
    public void Validate_EnforcesTheRecordCountCeiling()
    {
        var envelope = Valid();
        envelope.Records =
        [
            .. Enumerable.Range(0, 5).Select(_ => JsonDocument.Parse("{}").RootElement.Clone())
        ];

        var result = envelope.Validate(3);

        Assert.False(result.Ok);
        Assert.Contains("maximum of 3", result.Reason);
    }

    [Fact]
    public void Validate_RejectsANonObjectRecord()
    {
        var envelope = Valid();
        envelope.Records = [JsonDocument.Parse("\"scalar\"").RootElement.Clone()];

        Assert.Equal("every records entry must be a JSON object", envelope.Validate(1000).Reason);
    }

    [Fact]
    public void Validate_RequiresACollectionTimestamp()
    {
        var envelope = Valid();
        envelope.CollectedAtUtc = null;

        Assert.Equal("collectedAtUtc is required", envelope.Validate(1000).Reason);
    }

    [Fact]
    public void Validate_BoundsThePropertyBag()
    {
        var envelope = Valid();
        envelope.Properties = Enumerable.Range(0, 40).ToDictionary(i => $"k{i}", i => $"v{i}");

        Assert.Contains("properties exceeds", envelope.Validate(1000).Reason);
    }

    [Fact]
    public void Deserialization_MapsTheWireContract()
    {
        const string json = """
        {
          "envelopeVersion": "LOGCOLLECTOR-INVENTORY-V1",
          "tableName": "InventoryWindows_CL",
          "entraDeviceId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
          "deviceName": "WKS-001",
          "correlationId": "abc",
          "source": "WindowsScheduledTask",
          "collectedAtUtc": "2026-04-01T06:00:00.0000000+00:00",
          "properties": { "CollectorVersion": "1.0.0" },
          "records": [ { "RecordType": "Hardware" } ]
        }
        """;

        var envelope = JsonSerializer.Deserialize<InventoryEnvelope>(
            json, new JsonSerializerOptions(JsonSerializerDefaults.Web));

        Assert.NotNull(envelope);
        Assert.Equal("InventoryWindows_CL", envelope!.TableName);
        Assert.Equal(DeviceId, envelope.EntraDeviceId);
        Assert.Equal("1.0.0", envelope.Properties!["CollectorVersion"]);
        Assert.Single(envelope.Records!);
        Assert.True(envelope.Validate(1000).Ok);
    }
}
