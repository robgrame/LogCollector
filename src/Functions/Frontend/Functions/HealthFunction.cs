using LogCollector.Shared.Ingestion;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace LogCollector.Frontend.Functions;

/// <summary>
/// Liveness probe for App Service Always On and deployment gates.
/// </summary>
/// <remarks>
/// The route is anonymous at the function level so App Service Health Check can invoke it.
/// External traffic still traverses the platform mTLS policy because
/// <c>clientCertExclusionPaths</c> is empty in infra/main.bicep. The response nevertheless
/// contains only a static status and the count of configured ingestion targets.
/// </remarks>
public sealed class HealthFunction
{
    private readonly IngestionStreamMap _streamMap;

    public HealthFunction(IngestionStreamMap streamMap) => _streamMap = streamMap;

    [Function("Health")]
    public IActionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")] HttpRequest req)
        => new OkObjectResult(new
        {
            status = "ok",
            component = "logcollector-frontend",
            configuredIngestionTargets = _streamMap.Count,
        });
}
