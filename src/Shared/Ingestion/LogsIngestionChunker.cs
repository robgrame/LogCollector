using System.Text.Json;

namespace LogCollector.Shared.Ingestion;

/// <summary>
/// Splits a batch of rows into chunks that stay under the Azure Monitor Logs
/// Ingestion API request-body limit.
/// </summary>
/// <remarks>
/// The documented hard limit is 1 MB of uncompressed request body. We default to
/// 850 KB so that (a) the safety margin absorbs the payload wrapper and any
/// server-side normalisation, and (b) a batch that sits right on the boundary
/// does not oscillate between accepted and rejected.
///
/// A single row that cannot fit inside the budget is <i>never</i> ingestible, so
/// it is reported separately rather than thrown: one poison row must not block
/// an otherwise valid batch, and retrying it forever would spin the queue.
/// </remarks>
public static class LogsIngestionChunker
{
    /// <summary>Azure Monitor hard limit for a Logs Ingestion request body.</summary>
    public const int HardLimitBytes = 1024 * 1024;

    /// <summary>Default working budget, deliberately below <see cref="HardLimitBytes"/>.</summary>
    public const int DefaultMaxChunkBytes = 850 * 1024;

    public sealed record ChunkingResult(
        IReadOnlyList<IReadOnlyList<JsonElement>> Chunks,
        IReadOnlyList<int> OversizedRowIndexes);

    /// <summary>
    /// Chunks <paramref name="rows"/> so that the serialised JSON array of every
    /// chunk is at most <paramref name="maxChunkBytes"/> UTF-8 bytes.
    /// </summary>
    public static ChunkingResult Chunk(
        IReadOnlyList<JsonElement> rows,
        int maxChunkBytes = DefaultMaxChunkBytes)
    {
        ArgumentNullException.ThrowIfNull(rows);
        if (maxChunkBytes < 1024)
            throw new ArgumentOutOfRangeException(nameof(maxChunkBytes), "chunk budget must be at least 1 KiB");
        if (maxChunkBytes > HardLimitBytes)
            throw new ArgumentOutOfRangeException(nameof(maxChunkBytes), "chunk budget must not exceed the 1 MB API limit");

        var chunks = new List<IReadOnlyList<JsonElement>>();
        var oversized = new List<int>();
        var current = new List<JsonElement>();

        // Array framing: '[' + ']' plus one ',' between consecutive elements.
        const int Brackets = 2;
        var currentBytes = Brackets;

        for (var i = 0; i < rows.Count; i++)
        {
            var rowBytes = MeasureUtf8(rows[i]);

            if (rowBytes + Brackets > maxChunkBytes)
            {
                oversized.Add(i);
                continue;
            }

            var separator = current.Count > 0 ? 1 : 0;
            if (currentBytes + separator + rowBytes > maxChunkBytes)
            {
                chunks.Add(current);
                current = [];
                currentBytes = Brackets;
                separator = 0;
            }

            current.Add(rows[i]);
            currentBytes += separator + rowBytes;
        }

        if (current.Count > 0) chunks.Add(current);

        return new ChunkingResult(chunks, oversized);
    }

    /// <summary>Exact UTF-8 byte length of the compact JSON form of <paramref name="element"/>.</summary>
    public static int MeasureUtf8(JsonElement element)
    {
        var buffer = new System.Buffers.ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false, SkipValidation = true }))
        {
            element.WriteTo(writer);
        }
        return buffer.WrittenCount;
    }

    /// <summary>Serialises a chunk to the compact JSON array the API expects.</summary>
    public static byte[] SerializeChunk(IReadOnlyList<JsonElement> chunk)
    {
        var buffer = new System.Buffers.ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false, SkipValidation = true }))
        {
            writer.WriteStartArray();
            foreach (var row in chunk) row.WriteTo(writer);
            writer.WriteEndArray();
        }
        return buffer.WrittenSpan.ToArray();
    }
}
