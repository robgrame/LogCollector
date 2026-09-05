using System.Text;
using System.Text.Json;
using LogCollector.Shared.Ingestion;
using Xunit;

namespace LogCollector.Shared.Tests.Ingestion;

public sealed class LogsIngestionChunkerTests
{
    private static JsonElement Row(int index, int padBytes = 0)
    {
        var padding = padBytes > 0 ? new string('x', padBytes) : string.Empty;
        var json = $"{{\"i\":{index},\"pad\":\"{padding}\"}}";
        return JsonDocument.Parse(json).RootElement.Clone();
    }

    [Fact]
    public void Chunk_KeepsASmallBatchInASingleChunk()
    {
        var rows = Enumerable.Range(0, 10).Select(i => Row(i)).ToList();

        var result = LogsIngestionChunker.Chunk(rows);

        Assert.Single(result.Chunks);
        Assert.Equal(10, result.Chunks[0].Count);
        Assert.Empty(result.OversizedRowIndexes);
    }

    [Fact]
    public void Chunk_PreservesEveryRowAndTheirOrder()
    {
        var rows = Enumerable.Range(0, 500).Select(i => Row(i, 4096)).ToList();

        var result = LogsIngestionChunker.Chunk(rows);

        var flattened = result.Chunks.SelectMany(c => c).Select(e => e.GetProperty("i").GetInt32()).ToList();

        Assert.Equal(500, flattened.Count);
        Assert.Equal(Enumerable.Range(0, 500), flattened);
    }

    [Fact]
    public void Chunk_KeepsEverySerializedChunkWithinTheBudget()
    {
        var rows = Enumerable.Range(0, 400).Select(i => Row(i, 8192)).ToList();

        var result = LogsIngestionChunker.Chunk(rows);

        Assert.True(result.Chunks.Count > 1, "the fixture must be large enough to force multiple chunks");

        foreach (var chunk in result.Chunks)
        {
            var bytes = LogsIngestionChunker.SerializeChunk(chunk);
            Assert.True(
                bytes.Length <= LogsIngestionChunker.DefaultMaxChunkBytes,
                $"chunk of {bytes.Length} bytes exceeds the {LogsIngestionChunker.DefaultMaxChunkBytes} byte budget");
        }
    }

    [Fact]
    public void DefaultBudget_StaysBelowTheHardApiLimit()
    {
        Assert.True(LogsIngestionChunker.DefaultMaxChunkBytes < LogsIngestionChunker.HardLimitBytes);
        Assert.Equal(850 * 1024, LogsIngestionChunker.DefaultMaxChunkBytes);
    }

    [Fact]
    public void Chunk_ReportsRowsThatCanNeverFitInsteadOfLoopingForever()
    {
        var rows = new List<JsonElement>
        {
            Row(0),
            Row(1, 200_000),
            Row(2),
        };

        var result = LogsIngestionChunker.Chunk(rows, 64 * 1024);

        Assert.Single(result.OversizedRowIndexes);
        Assert.Equal(1, result.OversizedRowIndexes[0]);

        var kept = result.Chunks.SelectMany(c => c).Select(e => e.GetProperty("i").GetInt32()).ToList();
        Assert.Equal([0, 2], kept);
    }

    [Fact]
    public void Chunk_ReturnsNoChunksForAnEmptyBatch()
    {
        var result = LogsIngestionChunker.Chunk([]);

        Assert.Empty(result.Chunks);
        Assert.Empty(result.OversizedRowIndexes);
    }

    [Theory]
    [InlineData(512)]
    [InlineData(LogsIngestionChunker.HardLimitBytes + 1)]
    public void Chunk_RejectsABudgetOutsideTheSupportedRange(int budget)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => LogsIngestionChunker.Chunk([Row(0)], budget));
    }

    [Fact]
    public void MeasureUtf8_MatchesTheActualSerializedLength()
    {
        var row = Row(42, 100);
        var expected = Encoding.UTF8.GetByteCount(row.GetRawText());

        Assert.Equal(expected, LogsIngestionChunker.MeasureUtf8(row));
    }

    [Fact]
    public void SerializeChunk_ProducesAValidJsonArray()
    {
        var rows = new List<JsonElement> { Row(1), Row(2) };

        var bytes = LogsIngestionChunker.SerializeChunk(rows);
        using var document = JsonDocument.Parse(bytes);

        Assert.Equal(JsonValueKind.Array, document.RootElement.ValueKind);
        Assert.Equal(2, document.RootElement.GetArrayLength());
    }
}
