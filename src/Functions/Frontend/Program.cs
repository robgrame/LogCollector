using Azure.Data.Tables;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using LogCollector.Frontend.Services;
using LogCollector.Shared.Ingestion;
using LogCollector.Shared.Security;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

builder.Services.Configure<LoggerFilterOptions>(options =>
{
    var defaultRule = options.Rules.FirstOrDefault(rule =>
        rule.ProviderName == "Microsoft.Extensions.Logging.ApplicationInsights.ApplicationInsightsLoggerProvider");
    if (defaultRule is not null) options.Rules.Remove(defaultRule);
});

// Every Azure data-plane call uses managed identity. There is no connection
// string, no Function key and no shared secret anywhere in this app.
builder.Services.AddSingleton<Azure.Core.TokenCredential>(_ =>
{
    var clientId = builder.Configuration["AZURE_CLIENT_ID"];
    return string.IsNullOrWhiteSpace(clientId)
        ? new DefaultAzureCredential()
        : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(clientId));
});

builder.Services.AddSingleton(sp =>
{
    var fqns = Require(builder.Configuration, "ServiceBus:FullyQualifiedNamespace");
    return new ServiceBusClient(fqns, sp.GetRequiredService<Azure.Core.TokenCredential>());
});

builder.Services.AddSingleton(sp =>
{
    var account = Require(builder.Configuration, "Storage:AccountName");
    var container = builder.Configuration["Storage:PayloadContainer"] ?? "inventory-payloads";
    var service = new BlobServiceClient(
        new Uri($"https://{account}.blob.core.windows.net"),
        sp.GetRequiredService<Azure.Core.TokenCredential>());
    return service.GetBlobContainerClient(container);
});

builder.Services.AddSingleton(sp =>
{
    var account = Require(builder.Configuration, "Replay:StorageAccount");
    var tableName = builder.Configuration["Replay:TableName"] ?? "RequestNonces";
    var service = new TableServiceClient(
        new Uri($"https://{account}.table.core.windows.net"),
        sp.GetRequiredService<Azure.Core.TokenCredential>());
    return service.GetTableClient(tableName);
});

builder.Services.AddSingleton<IReplayNonceStore>(sp => new AzureTableReplayNonceStore(
    sp.GetRequiredService<TableClient>(),
    sp.GetRequiredService<ILogger<AzureTableReplayNonceStore>>()));

builder.Services.AddSingleton<ReplayProtector>();
builder.Services.AddSingleton<RequestSignatureVerifier>();
builder.Services.AddSingleton<ClientCertValidator>();
builder.Services.AddSingleton<IngestionStreamMap>();
builder.Services.AddSingleton<InventoryIntakeOptions>();
builder.Services.AddSingleton<InventoryPointerPublisher>();
builder.Services.AddHostedService<NonceCleanupService>();
builder.Services.AddHttpClient<GraphDeviceAuthorizer>(client => client.Timeout = TimeSpan.FromSeconds(20));

builder.Build().Run();

static string Require(IConfiguration cfg, string key)
    => cfg[key] ?? throw new InvalidOperationException($"Required setting '{key}' is not configured.");
