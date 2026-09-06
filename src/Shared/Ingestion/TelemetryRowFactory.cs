using System.Text.Json;
using LogCollector.Shared.Models;

namespace LogCollector.Shared.Ingestion;

/// <summary>
/// Projects an <see cref="TelemetryEnvelope"/> into the rows written to the
/// Log Analytics custom table.
/// </summary>
/// <remarks>
/// Server-asserted columns (device id, correlation id, ingestion time) are
/// written <b>after</b> the client-supplied properties are copied, so a
/// malicious client cannot spoof its own identity in the ingested data by
/// including a <c>EntraDeviceId</c> key in its record.
/// </remarks>
public static class TelemetryRowFactory
{
    /// <summary>Column names owned by the platform. Client values for these are dropped.</summary>
    public static readonly IReadOnlySet<string> ReservedColumns =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "TimeGenerated",
            "CollectedAtUtc",
            "EntraDeviceId",
            "DeviceName",
            "IntuneDeviceId",
            "CorrelationId",
            "Source",
            "RecordIndex",
        };

    public static IReadOnlyList<JsonElement> BuildRows(
        TelemetryEnvelope envelope,
        string correlationId,
        DateTimeOffset ingestedAtUtc)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        var records = envelope.Records ?? [];
        var rows = new List<JsonElement>(records.Count);
        var collectedAt = envelope.CollectedAtUtc ?? ingestedAtUtc;

        for (var recordIndex = 0; recordIndex < records.Count; recordIndex++)
        {
            var record = records[recordIndex];
            var buffer = new System.Buffers.ArrayBufferWriter<byte>();
            using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false, SkipValidation = true }))
            {
                writer.WriteStartObject();

                if (record.ValueKind == JsonValueKind.Object)
                {
                    foreach (var property in record.EnumerateObject())
                    {
                        if (ReservedColumns.Contains(property.Name)) continue;
                        property.WriteTo(writer);
                    }
                }

                if (envelope.Properties is not null)
                {
                    foreach (var kvp in envelope.Properties)
                    {
                        if (ReservedColumns.Contains(kvp.Key)) continue;
                        if (record.ValueKind == JsonValueKind.Object && record.TryGetProperty(kvp.Key, out _)) continue;
                        writer.WriteString(kvp.Key, kvp.Value);
                    }
                }

                writer.WriteString("TimeGenerated", ingestedAtUtc.UtcDateTime.ToString("O"));
                writer.WriteString("CollectedAtUtc", collectedAt.UtcDateTime.ToString("O"));
                writer.WriteString("EntraDeviceId", envelope.EntraDeviceId ?? string.Empty);
                writer.WriteString("DeviceName", envelope.DeviceName ?? string.Empty);
                writer.WriteString("IntuneDeviceId", envelope.IntuneDeviceId ?? string.Empty);
                writer.WriteString("CorrelationId", correlationId);
                writer.WriteNumber("RecordIndex", recordIndex);
                writer.WriteString("Source", envelope.Source ?? "Unknown");

                writer.WriteEndObject();
            }

            using var document = JsonDocument.Parse(buffer.WrittenMemory);
            rows.Add(document.RootElement.Clone());
        }

        return rows;
    }
}
