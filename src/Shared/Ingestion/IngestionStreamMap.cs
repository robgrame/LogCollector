using LogCollector.Shared.Models;
using Microsoft.Extensions.Configuration;

namespace LogCollector.Shared.Ingestion;

/// <summary>
/// Maps a client-requested table name to the DCR stream that may receive it.
/// </summary>
/// <remarks>
/// This is an allow-list, and it is the reason a client cannot choose an
/// arbitrary ingestion destination. Configuration format
/// (<c>Ingestion:StreamMap</c>):
/// <c>InventoryWindows_CL=Custom-InventoryWindows_CL;InventorySoftware_CL=Custom-InventorySoftware_CL</c>.
/// An unknown table name fails closed.
/// </remarks>
public sealed class IngestionStreamMap
{
    private readonly Dictionary<string, string> _map;

    public IngestionStreamMap(IConfiguration cfg)
        : this(cfg["Ingestion:StreamMap"])
    {
    }

    public IngestionStreamMap(string? rawMap)
    {
        _map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (var entry in (rawMap ?? string.Empty)
            .Split([',', ';', '|'], StringSplitOptions.RemoveEmptyEntries))
        {
            var pair = entry.Trim();
            var eq = pair.IndexOf('=');
            if (eq <= 0 || eq == pair.Length - 1) continue;

            var table = pair[..eq].Trim();
            var stream = pair[(eq + 1)..].Trim();
            if (!TelemetryEnvelope.IsSafeTableName(table)) continue;
            if (!stream.StartsWith("Custom-", StringComparison.Ordinal)) continue;

            _map[table] = stream;
        }
    }

    public int Count => _map.Count;

    public IReadOnlyCollection<string> AllowedTables => _map.Keys;

    public bool TryGetStream(string? tableName, out string streamName)
    {
        streamName = string.Empty;
        if (string.IsNullOrWhiteSpace(tableName)) return false;
        return _map.TryGetValue(tableName.Trim(), out streamName!);
    }

    public bool IsAllowed(string? tableName) => TryGetStream(tableName, out _);
}
