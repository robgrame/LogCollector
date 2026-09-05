using Microsoft.Extensions.Configuration;

namespace LogCollector.Frontend.Services;

/// <summary>Frontend intake limits, resolved once at startup.</summary>
public sealed class InventoryIntakeOptions
{
    public InventoryIntakeOptions(IConfiguration cfg)
    {
        QueueName = cfg["ServiceBus:InventoryQueue"] ?? "inventory-ingestion";
        ContainerName = cfg["Storage:PayloadContainer"] ?? "inventory-payloads";
        MaxRecordsPerEnvelope = int.TryParse(cfg["Intake:MaxRecordsPerEnvelope"], out var maxRecords)
            ? Math.Clamp(maxRecords, 1, 200_000)
            : 50_000;
    }

    public string QueueName { get; }

    public string ContainerName { get; }

    public int MaxRecordsPerEnvelope { get; }
}
