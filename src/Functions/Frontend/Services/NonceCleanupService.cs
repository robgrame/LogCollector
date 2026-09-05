using Azure;
using LogCollector.Shared.Security;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace LogCollector.Frontend.Services;

public sealed class NonceCleanupService(
    IReplayNonceStore store,
    IConfiguration configuration,
    ILogger<NonceCleanupService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var skew = Math.Clamp(configuration.GetValue("Replay:MaxTimestampSkewSeconds", 300), 30, 3600);
        var retention = Math.Max(configuration.GetValue("Replay:NonceRetentionSeconds", 7200), 2 * skew);
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                // Partitions use the signed request time, which can precede receipt
                // by one skew window. Keep that extra margin before purging.
                var cutoff = DateTimeOffset.UtcNow.AddSeconds(-retention - skew);
                try
                {
                    var removed = await store.PurgeExpiredAsync(cutoff, 10000, stoppingToken);
                    logger.LogInformation("Expired nonce cleanup removed {Count} rows before {Cutoff}.", removed, cutoff);
                }
                catch (RequestFailedException ex)
                {
                    logger.LogError(ex, "Nonce cleanup failed; retained rows will be retried next hour.");
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
        }
    }
}
