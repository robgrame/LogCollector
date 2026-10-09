using System.Net;
using Azure.Core;
using LogCollector.Shared.Security;
using Xunit;

namespace LogCollector.Shared.Tests.Security;

public sealed class GraphDeviceAuthorizerTests
{
    private const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";

    [Theory]
    [InlineData(true, true)]
    [InlineData(false, false)]
    public async Task RequiresEnabledDeviceInTheCredentialTenant(bool enabled, bool expected)
    {
        var handler = new Handler(HttpStatusCode.OK,
            $$"""{"deviceId":"{{DeviceId}}","accountEnabled":{{enabled.ToString().ToLowerInvariant()}}}""");
        using var http = new HttpClient(handler);
        Assert.Equal(expected, await new GraphDeviceAuthorizer(new Credential(), http)
            .IsEnabledTenantDeviceAsync(DeviceId, default));
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task ForeignOrDeletedDeviceIsDenied()
    {
        using var http = new HttpClient(new Handler(HttpStatusCode.NotFound, "{}"));
        Assert.False(await new GraphDeviceAuthorizer(new Credential(), http).IsEnabledTenantDeviceAsync(DeviceId, default));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"deviceId\":\"3f2504e0-4f89-11d3-9a0c-0305e82c3302\",\"accountEnabled\":true}")]
    [InlineData("{\"deviceId\":\"3f2504e0-4f89-11d3-9a0c-0305e82c3301\"}")]
    public async Task MissingOrMismatchedClaimsFailClosed(string body)
    {
        using var http = new HttpClient(new Handler(HttpStatusCode.OK, body));
        Assert.False(await new GraphDeviceAuthorizer(new Credential(), http).IsEnabledTenantDeviceAsync(DeviceId, default));
    }

    [Theory]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    public async Task PermissionAndServiceFailuresPropagate(HttpStatusCode status)
    {
        using var http = new HttpClient(new Handler(status, "{}"));
        await Assert.ThrowsAsync<HttpRequestException>(() =>
            new GraphDeviceAuthorizer(new Credential(), http).IsEnabledTenantDeviceAsync(DeviceId, default));
    }

    [Fact]
    public async Task SuccessfulAuthorizationIsCachedUntilTtlExpires()
    {
        var handler = new Handler(HttpStatusCode.OK,
            $$"""{"deviceId":"{{DeviceId}}","accountEnabled":true}""");
        using var http = new HttpClient(handler);
        var clock = new TestTimeProvider();
        var authorizer = new GraphDeviceAuthorizer(
            new Credential(), http, TimeSpan.FromMinutes(10), clock);

        Assert.True(await authorizer.IsEnabledTenantDeviceAsync(DeviceId, default));
        Assert.True(await authorizer.IsEnabledTenantDeviceAsync(DeviceId, default));
        Assert.Equal(1, handler.Calls);

        clock.Advance(TimeSpan.FromMinutes(10));

        Assert.True(await authorizer.IsEnabledTenantDeviceAsync(DeviceId, default));
        Assert.Equal(2, handler.Calls);
    }

    [Fact]
    public async Task DeniedAuthorizationIsNeverCached()
    {
        var handler = new Handler(HttpStatusCode.NotFound, "{}");
        using var http = new HttpClient(handler);
        var authorizer = new GraphDeviceAuthorizer(
            new Credential(), http, TimeSpan.FromMinutes(10));

        Assert.False(await authorizer.IsEnabledTenantDeviceAsync(DeviceId, default));
        Assert.False(await authorizer.IsEnabledTenantDeviceAsync(DeviceId, default));
        Assert.Equal(2, handler.Calls);
    }

    [Fact]
    public async Task ZeroTtlDisablesPositiveCaching()
    {
        var handler = new Handler(HttpStatusCode.OK,
            $$"""{"deviceId":"{{DeviceId}}","accountEnabled":true}""",
            TimeSpan.FromMilliseconds(20));
        using var http = new HttpClient(handler);
        var authorizer = new GraphDeviceAuthorizer(
            new Credential(), http, TimeSpan.Zero);

        var results = await Task.WhenAll(Enumerable.Range(0, 20)
            .Select(_ => authorizer.IsEnabledTenantDeviceAsync(DeviceId, default)));

        Assert.All(results, Assert.True);
        Assert.Equal(20, handler.Calls);
    }

    [Fact]
    public async Task ConcurrentRequestsShareOneGraphLookup()
    {
        var handler = new Handler(
            HttpStatusCode.OK,
            $$"""{"deviceId":"{{DeviceId}}","accountEnabled":true}""",
            TimeSpan.FromMilliseconds(50));
        using var http = new HttpClient(handler);
        var authorizer = new GraphDeviceAuthorizer(
            new Credential(), http, TimeSpan.FromMinutes(10));

        var results = await Task.WhenAll(Enumerable.Range(0, 20)
            .Select(_ => authorizer.IsEnabledTenantDeviceAsync(DeviceId, default)));

        Assert.All(results, Assert.True);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task CancelledWaiterDoesNotRetainNegativeLookup()
    {
        var handler = new ControlledNegativeHandler();
        using var http = new HttpClient(handler);
        var authorizer = new GraphDeviceAuthorizer(
            new Credential(), http, TimeSpan.FromMinutes(10));
        using var cancellation = new CancellationTokenSource();

        var cancelledWaiter = authorizer.IsEnabledTenantDeviceAsync(DeviceId, cancellation.Token);
        await handler.FirstRequestStarted.Task.WaitAsync(TimeSpan.FromSeconds(30));
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelledWaiter);
        handler.ReleaseFirstRequest.TrySetResult();
        await handler.FirstRequestReturned.Task.WaitAsync(TimeSpan.FromSeconds(30));

        for (var attempt = 0; attempt < 50 && handler.Calls < 2; attempt++)
        {
            Assert.False(await authorizer.IsEnabledTenantDeviceAsync(DeviceId, default));
            if (handler.Calls < 2)
                await Task.Delay(10);
        }
        Assert.Equal(2, handler.Calls);
    }

    private sealed class Handler(
        HttpStatusCode status,
        string body,
        TimeSpan? delay = null) : HttpMessageHandler
    {
        private int _calls;

        public int Calls => Volatile.Read(ref _calls);

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken ct)
        {
            Interlocked.Increment(ref _calls);
            Assert.Equal("graph.microsoft.com", request.RequestUri!.Host);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Contains($"devices(deviceId='{DeviceId}')", request.RequestUri.AbsoluteUri);
            if (delay is not null)
                await Task.Delay(delay.Value, ct);
            return new HttpResponseMessage(status) { Content = new StringContent(body) };
        }
    }

    private sealed class ControlledNegativeHandler : HttpMessageHandler
    {
        private int _calls;

        public int Calls => Volatile.Read(ref _calls);
        public TaskCompletionSource FirstRequestStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource ReleaseFirstRequest { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource FirstRequestReturned { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken ct)
        {
            var call = Interlocked.Increment(ref _calls);
            if (call == 1)
            {
                FirstRequestStarted.TrySetResult();
                await ReleaseFirstRequest.Task.WaitAsync(ct);
                FirstRequestReturned.TrySetResult();
            }
            return new HttpResponseMessage(HttpStatusCode.NotFound)
            {
                Content = new StringContent("{}")
            };
        }
    }

    private sealed class TestTimeProvider : TimeProvider
    {
        private DateTimeOffset _utcNow = DateTimeOffset.UtcNow;

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan duration) => _utcNow = _utcNow.Add(duration);
    }

    private sealed class Credential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext context, CancellationToken ct)
        {
            Assert.Equal("https://graph.microsoft.com/.default", Assert.Single(context.Scopes));
            return new AccessToken("unit-test-token", DateTimeOffset.UtcNow.AddMinutes(5));
        }
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext context, CancellationToken ct)
            => ValueTask.FromResult(GetToken(context, ct));
    }
}
