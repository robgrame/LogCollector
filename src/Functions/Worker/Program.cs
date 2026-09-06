using Azure.Identity;
using Azure.Monitor.Ingestion;
using Azure.Storage.Blobs;
using LogCollector.Shared.Ingestion;
using LogCollector.Worker.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// No HTTP surface here: the worker is purely Service Bus triggered, so the
// ASP.NET Core integration is deliberately absent.
var builder = FunctionsApplication.CreateBuilder(args);

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

builder.Services.Configure<LoggerFilterOptions>(options =>
{
    var defaultRule = options.Rules.FirstOrDefault(rule =>
        rule.ProviderName == "Microsoft.Extensions.Logging.ApplicationInsights.ApplicationInsightsLoggerProvider");
    if (defaultRule is not null) options.Rules.Remove(defaultRule);
});

builder.Services.AddSingleton<Azure.Core.TokenCredential>(_ =>
{
    var clientId = builder.Configuration["AZURE_CLIENT_ID"];
    return string.IsNullOrWhiteSpace(clientId)
        ? new DefaultAzureCredential()
        : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(clientId));
});

builder.Services.AddSingleton<WorkerIngestionOptions>();
builder.Services.AddSingleton<IngestionStreamMap>();

builder.Services.AddSingleton(sp =>
{
    var options = sp.GetRequiredService<WorkerIngestionOptions>();
    return new BlobServiceClient(
        new Uri($"https://{options.StorageAccountName}.blob.core.windows.net"),
        sp.GetRequiredService<Azure.Core.TokenCredential>());
});

builder.Services.AddSingleton(sp =>
{
    var options = sp.GetRequiredService<WorkerIngestionOptions>();

    // Retries are owned by LogsIngestionPublisher so that Retry-After is honoured
    // exactly once and the observed backoff is the real backoff.
    var clientOptions = new LogsIngestionClientOptions();
    clientOptions.Retry.MaxRetries = 0;

    return new LogsIngestionClient(
        new Uri(options.DataCollectionEndpoint),
        sp.GetRequiredService<Azure.Core.TokenCredential>(),
        clientOptions);
});

builder.Services.AddSingleton<PayloadBlobReader>();
builder.Services.AddSingleton<LogsIngestionPublisher>();
builder.Services.AddSingleton<TelemetryIngestionProcessor>();

builder.Build().Run();
