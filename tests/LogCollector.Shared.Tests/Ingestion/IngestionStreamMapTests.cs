using LogCollector.Shared.Ingestion;
using Xunit;

namespace LogCollector.Shared.Tests.Ingestion;

public sealed class IngestionStreamMapTests
{
    [Fact]
    public void TryGetStream_ResolvesAConfiguredTable()
    {
        var map = new IngestionStreamMap("InventoryWindows_CL=Custom-InventoryWindows_CL");

        Assert.True(map.TryGetStream("InventoryWindows_CL", out var stream));
        Assert.Equal("Custom-InventoryWindows_CL", stream);
    }

    [Fact]
    public void TryGetStream_IsCaseInsensitiveOnTheTableName()
    {
        var map = new IngestionStreamMap("InventoryWindows_CL=Custom-InventoryWindows_CL");

        Assert.True(map.TryGetStream("inventorywindows_cl", out _));
    }

    [Fact]
    public void TryGetStream_FailsClosedForAnUnmappedTable()
    {
        var map = new IngestionStreamMap("InventoryWindows_CL=Custom-InventoryWindows_CL");

        Assert.False(map.TryGetStream("AnythingElse_CL", out _));
        Assert.False(map.IsAllowed(null));
        Assert.False(map.IsAllowed("  "));
    }

    [Fact]
    public void Constructor_ParsesMultipleEntriesAcrossAllSeparators()
    {
        var map = new IngestionStreamMap(
            "A_CL=Custom-A_CL;B_CL=Custom-B_CL,C_CL=Custom-C_CL|D_CL=Custom-D_CL");

        Assert.Equal(4, map.Count);
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("garbage")]
    [InlineData("=Custom-X_CL")]
    [InlineData("X_CL=")]
    public void Constructor_IgnoresUnusableEntries(string? raw)
    {
        Assert.Equal(0, new IngestionStreamMap(raw).Count);
    }

    [Fact]
    public void Constructor_RejectsAStreamNameWithoutTheCustomPrefix()
    {
        // A stream that is not Custom-* cannot be a DCR custom stream, and letting
        // one through would send rows to an unintended destination.
        Assert.Equal(0, new IngestionStreamMap("X_CL=Microsoft-Syslog").Count);
    }

    [Fact]
    public void Constructor_RejectsATableNameOutsideTheSafeGrammar()
    {
        Assert.Equal(0, new IngestionStreamMap("../evil=Custom-Evil_CL").Count);
        Assert.Equal(0, new IngestionStreamMap("9Starts_CL=Custom-9Starts_CL").Count);
    }
}
