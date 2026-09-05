using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Core.Pipeline;
using Azure.Monitor.Ingestion;
using Azure.Storage.Blobs;
using LogCollector.Shared.Ingestion;
using LogCollector.Shared.Models;
using LogCollector.Worker.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

namespace LogCollector.Worker.Tests;

/// <summary>
/// Records every outbound request and answers it from a caller-supplied
/// responder, so ingestion and blob behaviour can be driven end to end without a
/// live service.
/// </summary>
internal sealed class RecordingHttpHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;
    private readonly List<(string Method, string Path)> _requests = [];

    public RecordingHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> responder)
        => _responder = responder;

    public IReadOnlyList<(string Method, string Path)> Requests
    {
        get { lock (_requests) { return [.. _requests]; } }
    }

    public int CountOf(string method, string pathFragment)
        => Requests.Count(r =>
            string.Equals(r.Method, method, StringComparison.OrdinalIgnoreCase)
            && r.Path.Contains(pathFragment, StringComparison.OrdinalIgnoreCase));

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        lock (_requests)
        {
            _requests.Add((request.Method.Method, request.RequestUri?.AbsolutePath ?? string.Empty));
        }

        var response = _responder(request);
        response.RequestMessage = request;
        return Task.FromResult(response);
    }
}

/// <summary>Shared fixtures for the worker tests.</summary>
internal static class WorkerTestHost
{
    public const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    public const string TableName = "InventoryWindows_CL";
    public const string StreamName = "Custom-InventoryWindows_CL";
    public const string StreamMap = $"{TableName}={StreamName}";

    /// <summary>
    /// A credential that never contacts an identity endpoint. Constructing the
    /// clients performs no I/O, so a stub is enough to exercise the publisher's
    /// guards and error handling without a network dependency.
    /// </summary>
    private sealed class StubTokenCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new("stub-token", DateTimeOffset.UtcNow.AddHours(1));

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new(GetToken(requestContext, cancellationToken));
    }

    public static WorkerIngestionOptions Options(
        int maxChunkBytes = 64 * 1024,
        int maxAttempts = 3,
        bool deleteBlobAfterIngestion = false)
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Ingestion:DataCollectionEndpoint"] = "https://dce.example.invalid",
                ["Ingestion:DataCollectionRuleId"] = "dcr-0000000000000000000000000000000",
                ["Storage:AccountName"] = "teststorage",
                ["Storage:PayloadContainer"] = "inventory-payloads",
                ["Ingestion:MaxChunkBytes"] = maxChunkBytes.ToString(),
                ["Ingestion:MaxAttempts"] = maxAttempts.ToString(),
                ["Ingestion:BaseRetryDelayMs"] = "100",
                ["Ingestion:MaxRetryDelaySeconds"] = "1",
                ["Ingestion:DeleteBlobAfterIngestion"] = deleteBlobAfterIngestion.ToString(),
            })
            .Build();

        return new WorkerIngestionOptions(config);
    }

    public static LogsIngestionPublisher Publisher(WorkerIngestionOptions options, HttpMessageHandler? handler = null)
    {
        var clientOptions = new LogsIngestionClientOptions();
        clientOptions.Retry.MaxRetries = 0;
        if (handler is not null)
            clientOptions.Transport = new HttpClientTransport(new HttpClient(handler));

        var client = new LogsIngestionClient(
            new Uri(options.DataCollectionEndpoint),
            new StubTokenCredential(),
            clientOptions);

        // Retry delays stay tiny because Options() sets a 100 ms base and a 1 s
        // ceiling, so the real backoff path runs without slowing the suite.
        return new LogsIngestionPublisher(client, options, NullLogger<LogsIngestionPublisher>.Instance);
    }

    public static InventoryIngestionProcessor Processor(WorkerIngestionOptions options, HttpMessageHandler handler)
    {
        var blobOptions = new BlobClientOptions();
        blobOptions.Retry.MaxRetries = 0;
        blobOptions.Transport = new HttpClientTransport(new HttpClient(handler));

        var blobService = new BlobServiceClient(
            new Uri($"https://{options.StorageAccountName}.blob.core.windows.net"),
            new StubTokenCredential(),
            blobOptions);

        return new InventoryIngestionProcessor(
            new PayloadBlobReader(blobService, options, NullLogger<PayloadBlobReader>.Instance),
            Publisher(options, handler),
            new IngestionStreamMap(StreamMap),
            options,
            NullLogger<InventoryIngestionProcessor>.Instance);
    }

    /// <summary>Builds a row of roughly <paramref name="padBytes"/> payload bytes.</summary>
    public static JsonElement Row(int index, int padBytes = 0)
    {
        var padding = padBytes > 0 ? new string('x', padBytes) : string.Empty;
        return JsonDocument.Parse($"{{\"i\":{index},\"pad\":\"{padding}\"}}").RootElement.Clone();
    }

    /// <summary>A valid inventory payload as it would sit in the blob.</summary>
    public static byte[] EnvelopePayload(int recordCount = 2)
    {
        var records = string.Join(",", Enumerable.Range(0, recordCount)
            .Select(i => $"{{\"RecordType\":\"Hardware\",\"Index\":{i}}}"));

        var json = $$"""
        {
          "envelopeVersion": "LOGCOLLECTOR-INVENTORY-V1",
          "tableName": "{{TableName}}",
          "entraDeviceId": "{{DeviceId}}",
          "deviceName": "WKS-TEST",
          "correlationId": "corr-1",
          "source": "WindowsScheduledTask",
          "collectedAtUtc": "2026-04-01T06:00:00.0000000+00:00",
          "properties": { "CollectorVersion": "1.0.1" },
          "records": [ {{records}} ]
        }
        """;

        return Encoding.UTF8.GetBytes(json);
    }

    public static QueuedIngestionMessage Pointer(byte[] payload) => new()
    {
        CorrelationId = "corr-1",
        TableName = TableName,
        ContainerName = "inventory-payloads",
        BlobName = $"{TableName}/2026/04/01/corr-1.json",
        PayloadSha256 = Convert.ToBase64String(SHA256.HashData(payload)),
        PayloadBytes = payload.LongLength,
        EntraDeviceId = DeviceId,
        DeviceName = "WKS-TEST",
        Source = "WindowsScheduledTask",
        CollectedAtUtc = new DateTimeOffset(2026, 4, 1, 6, 0, 0, TimeSpan.Zero),
        AcceptedAtUtc = new DateTimeOffset(2026, 4, 1, 6, 5, 0, TimeSpan.Zero),
    };

    /// <summary>
    /// Routes blob GETs to the payload and ingestion POSTs to
    /// <paramref name="ingestionStatus"/>, so one handler serves the whole
    /// processor pipeline.
    /// </summary>
    public static RecordingHttpHandler PipelineHandler(
        byte[] payload,
        HttpStatusCode ingestionStatus,
        string? retryAfter = null)
        => new(request =>
        {
            var path = request.RequestUri?.AbsolutePath ?? string.Empty;

            if (path.Contains("/dataCollectionRules/", StringComparison.OrdinalIgnoreCase))
            {
                var response = new HttpResponseMessage(ingestionStatus)
                {
                    Content = new ByteArrayContent(
                        ingestionStatus == HttpStatusCode.NoContent
                            ? []
                            : Encoding.UTF8.GetBytes("{\"error\":{\"code\":\"InvalidStream\",\"message\":\"stub rejection\"}}")),
                };

                if (retryAfter is not null) response.Headers.TryAddWithoutValidation("Retry-After", retryAfter);
                return response;
            }

            if (request.Method == HttpMethod.Delete)
                return new HttpResponseMessage(HttpStatusCode.Accepted);

            // Blob download.
            var blob = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(payload),
            };
            blob.Content.Headers.TryAddWithoutValidation("Content-Type", "application/json");
            blob.Headers.TryAddWithoutValidation("ETag", "\"0x8DTESTETAG\"");
            blob.Headers.TryAddWithoutValidation("Last-Modified", "Wed, 01 Apr 2026 06:05:00 GMT");
            blob.Headers.TryAddWithoutValidation("x-ms-blob-type", "BlockBlob");
            blob.Headers.TryAddWithoutValidation("x-ms-request-id", "stub-request-id");
            blob.Headers.TryAddWithoutValidation("x-ms-version", "2023-11-03");
            blob.Headers.TryAddWithoutValidation("Accept-Ranges", "bytes");
            blob.Headers.Date = DateTimeOffset.UtcNow;
            return blob;
        });
}
