using Azure;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace LogCollector.Frontend.Services;

public sealed class UserSessionCleanupService(
    IUserSessionStore store,
    TimeProvider timeProvider,
    ILogger<UserSessionCleanupService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(
        CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                var cutoff = timeProvider.GetUtcNow();
                try
                {
                    var removed = await store.PurgeExpiredAsync(
                        cutoff,
                        10_000,
                        stoppingToken);
                    logger.LogInformation(
                        "Expired user-session cleanup removed {Count} rows.",
                        removed);
                }
                catch (RequestFailedException exception)
                {
                    logger.LogError(
                        exception,
                        "User-session cleanup failed; rows will be retried next hour.");
                }
            }
        }
        catch (OperationCanceledException)
            when (stoppingToken.IsCancellationRequested)
        {
        }
    }
}
