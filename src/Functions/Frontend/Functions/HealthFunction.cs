using LogCollector.Shared.Ingestion;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace LogCollector.Frontend.Functions;

/// <summary>
/// Liveness probe for App Service Always On and deployment gates.
/// </summary>
/// <remarks>
/// The route is anonymous at the function level, but the platform still enforces
/// mTLS in front of it: <c>clientCertExclusionPaths</c> is empty in infra/main.bicep,
/// so a caller with no client certificate is rejected by App Service with 403
/// "Client Certificate Required" and never reaches this code. It must nevertheless
/// never disclose anything an unauthenticated caller should not see: only a static
/// status and the count of configured ingestion targets.
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
