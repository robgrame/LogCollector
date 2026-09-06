using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Azure.Core;
using Azure.Core.Pipeline;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using LogCollector.Frontend.Functions;
using LogCollector.Frontend.Services;
using LogCollector.Shared.Ingestion;
using LogCollector.Shared.Security;
using LogCollector.Shared.Tests;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LogCollector.Frontend.Tests;

internal sealed class FrontendTestHarness : IDisposable
{
    public const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    public const string OtherDeviceId = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
    public const string ContainerName = "telemetry-test-payloads";
    public const string StreamMap =
        "RemediationResults_CL=Custom-RemediationResults_CL;HealthChecks_CL=Custom-HealthChecks_CL;"
        + "InventoryWindows_CL=Custom-InventoryWindows_CL";

    private readonly HttpClient _blobHttp;
    private readonly HttpClient _graphHttp;
    private readonly List<Stream> _requestBodies = [];

    public X509Certificate2 Root { get; }
    public X509Certificate2 Leaf { get; }
    public X509Certificate2 PresentedCertificate { get; }
    public InMemoryReplayNonceStore Nonces { get; } = new();
    public List<string> Events { get; } = [];
    public BlobHandler Blobs { get; }
    public RecordingServiceBusClient ServiceBus { get; }
    public GraphHandler Graph { get; }
    public TelemetryIngestFunction Function { get; }

    public FrontendTestHarness(
        bool intune = false,
        string? boundDeviceId = DeviceId,
        params (string Key, string Value)[] extraSettings)
    {
        Root = TestCertificates.CreateRootCa(intune ? "Microsoft Intune MDM Device CA" : "Frontend Test CA");
        Leaf = TestCertificates.CreateClientCertificate(
            Root, "device-01",
            sanUriDeviceId: intune ? null : boundDeviceId,
            intuneDeviceId: intune ? boundDeviceId : null);
        PresentedCertificate = TestCertificates.PublicOnly(Leaf);
        var settings = new List<(string, string)>
        {
            (intune ? "ClientCert:TrustedIntuneRootCertificates" : "ClientCert:TrustedRootCertificates",
                TestCertificates.ToBase64(Root)),
            ("ClientCert:DeviceIdBindingClaim", "Auto"),
            ("ClientCert:RequireDeviceBinding", "true"),
            ("ClientCert:CheckRevocation", "false"),
            ("ClientCert:RevocationMode", "NoCheck"),
            ("Ingestion:StreamMap", StreamMap),
            ("Storage:PayloadContainer", ContainerName),
        };
        settings.AddRange(extraSettings);
        var config = TestCertificates.Config([.. settings]);
        var options = new TelemetryIntakeOptions(config);
        Blobs = new BlobHandler(Events);
        _blobHttp = new HttpClient(Blobs);
        var blobOptions = new BlobClientOptions { Transport = new HttpClientTransport(_blobHttp) };
        blobOptions.Retry.MaxRetries = 0;
        var container = new BlobContainerClient(
            new Uri($"https://frontend-tests.invalid/{ContainerName}"), blobOptions);
        ServiceBus = new RecordingServiceBusClient(Events);
        Graph = new GraphHandler(intune);
        _graphHttp = new HttpClient(Graph);
        Function = new TelemetryIngestFunction(
            new ClientCertValidator(config, NullLogger<ClientCertValidator>.Instance),
            new RequestSignatureVerifier(config),
            new ReplayProtector(Nonces, config),
            new TelemetryPointerPublisher(container, ServiceBus, options,
                NullLogger<TelemetryPointerPublisher>.Instance),
            new IngestionStreamMap(config),
            options,
            new GraphDeviceAuthorizer(new TestCredential(intune), _graphHttp),
            NullLogger<TelemetryIngestFunction>.Instance);
    }

    public HttpRequest Request(
        bool legacy,
        byte[] body,
        string? signedPath = null,
        Guid? nonce = null,
        byte[]? signedBody = null,
        X509Certificate2? signingCertificate = null)
    {
        var request = new DefaultHttpContext().Request;
        request.Method = "POST";
        request.Path = legacy ? "/api/inventory" : "/api/submit";
        request.ContentType = "application/json";
        request.Body = new MemoryStream(body, writable: false);
        _requestBodies.Add(request.Body);
        request.HttpContext.Connection.ClientCertificate = PresentedCertificate;
        var timestamp = DateTimeOffset.UtcNow;
        var actualNonce = nonce ?? Guid.NewGuid();
        var canonical = Encoding.UTF8.GetBytes(RequestSignatureVerifier.BuildCanonicalRequest(
            request.Method, signedPath ?? request.Path.Value!, timestamp, actualNonce, signedBody ?? body));
        using var key = (signingCertificate ?? Leaf).GetRSAPrivateKey()!;
        request.Headers[RequestSignatureVerifier.TimestampHeader] = timestamp.ToString("O");
        request.Headers[RequestSignatureVerifier.NonceHeader] = actualNonce.ToString("D");
        request.Headers[RequestSignatureVerifier.VersionHeader] = RequestSignatureVerifier.ProtocolVersion;
        request.Headers[RequestSignatureVerifier.AlgorithmHeader] = RequestSignatureVerifier.RsaAlgorithm;
        request.Headers[RequestSignatureVerifier.SignatureHeader] =
            Convert.ToBase64String(key.SignData(canonical, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
        return request;
    }

    public Task<IActionResult> Invoke(bool legacy, HttpRequest request)
        => legacy ? Function.RunLegacy(request, default) : Function.Run(request, default);

    public void AssertNoPublication()
    {
        Assert.Empty(Events);
        Assert.Empty(Blobs.Uploads);
        Assert.Empty(ServiceBus.Queues);
        Assert.Empty(ServiceBus.Messages);
    }

    public void Dispose()
    {
        foreach (var body in _requestBodies) body.Dispose();
        _blobHttp.Dispose();
        _graphHttp.Dispose();
        PresentedCertificate.Dispose();
        Leaf.Dispose();
        Root.Dispose();
    }

    internal sealed record Upload(Uri Uri, byte[] Body, IReadOnlyDictionary<string, string> Headers);

    internal sealed class InMemoryReplayNonceStore : IReplayNonceStore
    {
        private readonly ConcurrentDictionary<(string Thumbprint, Guid Nonce), DateTimeOffset> _entries = new();
        public int Count => _entries.Count;

        public Task<bool> TryReserveAsync(
            string certificateThumbprint, DateTimeOffset requestTimestamp, Guid nonce,
            DateTimeOffset expiresAt, CancellationToken ct)
            => Task.FromResult(_entries.TryAdd((certificateThumbprint, nonce), expiresAt));

        public Task<int> PurgeExpiredAsync(DateTimeOffset cutoff, int maxEntities, CancellationToken ct)
        {
            var removed = 0;
            foreach (var entry in _entries)
            {
                if (removed >= maxEntities) break;
                if (entry.Value < cutoff && _entries.TryRemove(entry.Key, out _)) removed++;
            }
            return Task.FromResult(removed);
        }
    }

    internal sealed class BlobHandler(List<string> events) : HttpMessageHandler
    {
        public List<Upload> Uploads { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Assert.Equal("frontend-tests.invalid", request.RequestUri!.Host);
            Assert.Equal(HttpMethod.Put, request.Method);
            if (request.RequestUri.Query.Contains("restype=container", StringComparison.Ordinal))
            {
                Assert.Equal($"/{ContainerName}", request.RequestUri.AbsolutePath);
                Assert.False(request.Headers.Contains("x-ms-blob-public-access"));
                events.Add("container");
            }
            else
            {
                Assert.NotNull(request.Content);
                events.Add("blob");
                var headers = request.Headers.Concat(request.Content.Headers)
                    .ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
                Uploads.Add(new Upload(request.RequestUri,
                    await request.Content.ReadAsByteArrayAsync(ct), headers));
            }

            var response = new HttpResponseMessage(HttpStatusCode.Created);
            response.Headers.TryAddWithoutValidation("ETag", "\"test-etag\"");
            response.Headers.TryAddWithoutValidation("Last-Modified", DateTimeOffset.UtcNow.ToString("R"));
            response.Headers.TryAddWithoutValidation("x-ms-request-id", Guid.NewGuid().ToString());
            return response;
        }
    }

    internal sealed class RecordingServiceBusClient(List<string> events) : ServiceBusClient
    {
        public List<string> Queues { get; } = [];
        public List<ServiceBusMessage> Messages { get; } = [];

        public override ServiceBusSender CreateSender(string queueOrTopicName)
        {
            Queues.Add(queueOrTopicName);
            return new RecordingSender(events, Messages);
        }
    }

    private sealed class RecordingSender(List<string> events, List<ServiceBusMessage> messages) : ServiceBusSender
    {
        public override Task SendMessageAsync(ServiceBusMessage message, CancellationToken cancellationToken = default)
        {
            Assert.Contains("blob", events);
            events.Add("send");
            messages.Add(message);
            return Task.CompletedTask;
        }

        public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    internal sealed class GraphHandler(bool allowed) : HttpMessageHandler
    {
        public int Calls { get; private set; }
        public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
        public string Body { get; set; } = $$"""{"deviceId":"{{DeviceId}}","accountEnabled":true}""";

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Assert.True(allowed, "Enterprise PKI requests must not call Graph.");
            Calls++;
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal("graph.microsoft.com", request.RequestUri!.Host);
            Assert.Contains($"devices(deviceId='{DeviceId}')", request.RequestUri.AbsoluteUri);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Equal("frontend-test-token", request.Headers.Authorization.Parameter);
            return Task.FromResult(new HttpResponseMessage(Status) { Content = new StringContent(Body) });
        }
    }

    private sealed class TestCredential(bool allowed) : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Assert.True(allowed, "Enterprise PKI requests must not request Graph credentials.");
            Assert.Equal("https://graph.microsoft.com/.default", Assert.Single(requestContext.Scopes));
            return new AccessToken("frontend-test-token", DateTimeOffset.UtcNow.AddMinutes(5));
        }

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext, CancellationToken cancellationToken)
            => ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }
}
