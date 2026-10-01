using LogCollector.Worker.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace LogCollector.Worker.Functions;

public sealed class EndpointDataSprawlRetentionFunction(
    IEndpointDataSprawlPersistence persistence,
    ILogger<EndpointDataSprawlRetentionFunction> logger)
{
    [Function("EndpointDataSprawlRetention")]
    public async Task RunAsync(
        [TimerTrigger("0 30 2 * * *")] TimerInfo timer,
        CancellationToken cancellationToken)
    {
        var deletedRows = await persistence
            .PurgeExpiredAsync(cancellationToken)
            .ConfigureAwait(false);

        if (deletedRows > 0)
        {
            logger.LogInformation(
                "Endpoint Data Sprawl retention removed {DeletedRows} expired SQL row(s).",
                deletedRows);
        }
    }
}
