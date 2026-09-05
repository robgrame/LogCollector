using System.Text.Json;
using LogCollector.Shared.Models;
using Xunit;

namespace LogCollector.Shared.Tests.Models;

public sealed class QueuedIngestionMessageTests
{
    private static QueuedIngestionMessage Valid() => new()
    {
        CorrelationId = "abc123",
        TableName = "InventoryWindows_CL",
        ContainerName = "inventory-payloads",
        BlobName = "InventoryWindows_CL/2026/04/01/abc123.json",
        PayloadSha256 = Convert.ToBase64String(new byte[32]),
        PayloadBytes = 128,
        EntraDeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
    };

    [Fact]
    public void Validate_AcceptsAWellFormedPointer()
    {
        Assert.True(Valid().Validate().Ok);
    }

    [Fact]
    public void Validate_RejectsAnUnsupportedVersion()
    {
        var pointer = Valid();
        pointer.Version = "LOGCOLLECTOR-POINTER-V0";

        Assert.Contains("unsupported pointer version", pointer.Validate().Reason);
    }

    [Theory]
    [InlineData("../../../secrets/key.json")]
    [InlineData("/absolute/path.json")]
    public void Validate_RejectsANonCanonicalBlobPath(string blobName)
    {
        // The pointer is untrusted input; a traversal-shaped blob name must never
        // reach the storage client.
        var pointer = Valid();
        pointer.BlobName = blobName;

        Assert.Equal("blobName is not a canonical relative blob path", pointer.Validate().Reason);
    }

    [Fact]
    public void Validate_RequiresAContainerName()
    {
        var pointer = Valid();
        pointer.ContainerName = "";

        Assert.Equal("containerName is required", pointer.Validate().Reason);
    }

    [Fact]
    public void Validate_RejectsAnUnsafeTableName()
    {
        var pointer = Valid();
        pointer.TableName = "bad table";

        Assert.Equal("tableName is missing or invalid", pointer.Validate().Reason);
    }

    [Fact]
    public void Validate_RequiresACorrelationId()
    {
        var pointer = Valid();
        pointer.CorrelationId = "";

        Assert.Equal("correlationId is required", pointer.Validate().Reason);
    }

    [Fact]
    public void Validate_RequiresIdentityAndPositivePayloadLength()
    {
        var pointer = Valid();
        pointer.EntraDeviceId = "not-a-guid";
        Assert.False(pointer.Validate().Ok);
        pointer = Valid();
        pointer.PayloadBytes = 0;
        Assert.False(pointer.Validate().Ok);
    }

    [Theory]
    [InlineData("")]
    [InlineData("hash")]
    [InlineData("AQID")]
    public void Validate_RejectsMissingOrMalformedDigest(string digest)
    {
        var pointer = Valid();
        pointer.PayloadSha256 = digest;
        Assert.False(pointer.Validate().Ok);
    }

    [Fact]
    public void Serialization_RoundTripsThroughTheWireFormat()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        var original = Valid();
        original.PayloadBytes = 4096;
        original.CollectedAtUtc = new DateTimeOffset(2026, 4, 1, 6, 0, 0, TimeSpan.Zero);

        var round = JsonSerializer.Deserialize<QueuedIngestionMessage>(
            JsonSerializer.Serialize(original, options), options);

        Assert.NotNull(round);
        Assert.Equal(original.BlobName, round!.BlobName);
        Assert.Equal(original.PayloadBytes, round.PayloadBytes);
        Assert.Equal(original.CollectedAtUtc, round.CollectedAtUtc);
        Assert.True(round.Validate().Ok);
    }
}
