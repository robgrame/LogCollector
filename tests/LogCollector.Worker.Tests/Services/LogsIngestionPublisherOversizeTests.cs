using System.Text.Json;
using LogCollector.Shared.Ingestion;
using LogCollector.Worker.Services;
using Xunit;

namespace LogCollector.Worker.Tests.Services;

/// <summary>
/// Covers the rule that an inventory payload containing a row larger than the
/// chunk budget is rejected <b>whole</b>, before any upload, so the blob survives
/// for remediation and no partial sample is committed.
/// </summary>
public sealed class LogsIngestionPublisherOversizeTests
{
    private const int Budget = 64 * 1024;

    [Fact]
    public void Prepare_ReportsNoOversizedRowsForAnOrdinaryBatch()
    {
        var rows = Enumerable.Range(0, 50).Select(i => WorkerTestHost.Row(i, 128)).ToList();

        var batch = LogsIngestionPublisher.Prepare(rows, Budget);

        Assert.False(batch.HasUningestibleRows);
        Assert.Empty(batch.OversizedRows);
        Assert.Equal(50, batch.TotalRows);
        Assert.Equal(50, batch.RowsInChunks);
    }

    [Fact]
    public void Prepare_FlagsARowThatCanNeverFit()
    {
        var rows = new List<JsonElement>
        {
            WorkerTestHost.Row(0, 64),
            WorkerTestHost.Row(1, Budget * 2),
            WorkerTestHost.Row(2, 64),
        };

        var batch = LogsIngestionPublisher.Prepare(rows, Budget);

        Assert.True(batch.HasUningestibleRows);
        var oversized = Assert.Single(batch.OversizedRows);
        Assert.Equal(1, oversized.Index);
        Assert.True(oversized.Bytes > Budget, "the reported size must be the row's real serialized length");
        Assert.Equal(3, batch.TotalRows);
        Assert.Equal(Budget, batch.MaxChunkBytes);
    }

    [Fact]
    public void Prepare_DoesNotSilentlyDiscardTheRemainingRows()
    {
        // The valid rows stay in the batch. They are not uploaded — the caller
        // dead-letters the whole message — but losing them here would make the
        // dead-letter reason unable to report how much data was affected.
        var rows = new List<JsonElement>
        {
            WorkerTestHost.Row(0, 64),
            WorkerTestHost.Row(1, Budget * 2),
            WorkerTestHost.Row(2, 64),
        };

        var batch = LogsIngestionPublisher.Prepare(rows, Budget);

        Assert.Equal(3, batch.TotalRows);
        Assert.Equal(2, batch.RowsInChunks);
    }

    [Fact]
    public void DescribeUningestibleRows_NamesTheRecordsSizeAndBudgetForRemediation()
    {
        var rows = new List<JsonElement>
        {
            WorkerTestHost.Row(0, 64),
            WorkerTestHost.Row(1, Budget * 2),
        };

        var reason = LogsIngestionPublisher.Prepare(rows, Budget).DescribeUningestibleRows();

        Assert.Contains("#1", reason, StringComparison.Ordinal);
        Assert.Contains(Budget.ToString(), reason, StringComparison.Ordinal);
        Assert.Contains("can never be ingested", reason, StringComparison.Ordinal);
        Assert.Contains("No rows were uploaded", reason, StringComparison.Ordinal);
        Assert.Contains("retained for remediation", reason, StringComparison.Ordinal);
        Assert.Contains("total records in payload: 2", reason, StringComparison.Ordinal);
    }

    [Fact]
    public void DescribeUningestibleRows_CapsTheListedIndexes()
    {
        // Dead-letter descriptions are length-limited; a 5000-row payload must not
        // produce an unusable wall of indexes.
        var rows = Enumerable.Range(0, 30).Select(i => WorkerTestHost.Row(i, Budget * 2)).ToList();

        var reason = LogsIngestionPublisher.Prepare(rows, Budget).DescribeUningestibleRows();

        Assert.Contains("and 10 more", reason, StringComparison.Ordinal);
        Assert.True(reason.Length < 4000, "the reason must fit inside the dead-letter description limit");
    }

    [Fact]
    public async Task UploadAsync_RefusesAnUningestibleBatchWithoutContactingTheService()
    {
        var options = WorkerTestHost.Options(Budget);
        var publisher = WorkerTestHost.Publisher(options);

        var rows = new List<JsonElement>
        {
            WorkerTestHost.Row(0, 64),
            WorkerTestHost.Row(1, Budget * 2),
        };

        var batch = publisher.PrepareBatch(rows);

        // The endpoint is unroutable. An InvalidOperationException therefore proves
        // the guard fired before any network call; a partial upload would surface
        // as a request exception instead.
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => publisher.UploadAsync("Custom-InventoryWindows_CL", batch, "corr-1", CancellationToken.None));

        Assert.Contains("Refusing to upload", ex.Message, StringComparison.Ordinal);
        Assert.Contains("#1", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UploadAsync_AcceptsAnEmptyBatchWithoutContactingTheService()
    {
        var options = WorkerTestHost.Options(Budget);
        var publisher = WorkerTestHost.Publisher(options);

        var batch = publisher.PrepareBatch([]);

        var result = await publisher.UploadAsync("Custom-InventoryWindows_CL", batch, "corr-1", CancellationToken.None);

        Assert.Equal(0, result.ChunksSent);
        Assert.Equal(0, result.RowsSent);
    }

    [Fact]
    public void PrepareBatch_UsesTheConfiguredChunkBudget()
    {
        var options = WorkerTestHost.Options(128 * 1024);
        var publisher = WorkerTestHost.Publisher(options);

        var batch = publisher.PrepareBatch([WorkerTestHost.Row(0, 100 * 1024)]);

        // The same row is uningestible at 64 KiB and fine at 128 KiB.
        Assert.False(batch.HasUningestibleRows);
        Assert.Equal(128 * 1024, batch.MaxChunkBytes);
        Assert.True(LogsIngestionPublisher.Prepare([WorkerTestHost.Row(0, 100 * 1024)], 64 * 1024).HasUningestibleRows);
    }

    [Fact]
    public void Prepare_KeepsEveryChunkWithinTheBudget()
    {
        var rows = Enumerable.Range(0, 200).Select(i => WorkerTestHost.Row(i, 4096)).ToList();

        var batch = LogsIngestionPublisher.Prepare(rows, Budget);

        Assert.True(batch.Chunks.Count > 1, "the fixture must force multiple chunks");
        foreach (var chunk in batch.Chunks)
        {
            Assert.True(LogsIngestionChunker.SerializeChunk(chunk).Length <= Budget);
        }
        Assert.Equal(200, batch.RowsInChunks);
    }

    [Fact]
    public void Prepare_RejectsANullRowSet()
    {
        Assert.Throws<ArgumentNullException>(() => LogsIngestionPublisher.Prepare(null!, Budget));
    }
}
