using LogCollector.Shared.Ingestion;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace LogCollector.Frontend.Functions;

/// <summary>
/// Liveness probe for App Service Always On and deployment gates.
/// </summary>
/// <remarks>
/// This route is listed in <c>clientCertExclusionPaths</c> so the platform's own
/// warm-up pings — which carry no client certificate — do not fail. It therefore
/// must never disclose anything an unauthenticated caller should not see: only a
/// static status and the count of configured ingestion targets.
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
