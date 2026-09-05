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
        using var http = new HttpClient(new Handler(HttpStatusCode.OK,
            $$"""{"deviceId":"{{DeviceId}}","accountEnabled":{{enabled.ToString().ToLowerInvariant()}}}"""));
        Assert.Equal(expected, await new GraphDeviceAuthorizer(new Credential(), http)
            .IsEnabledTenantDeviceAsync(DeviceId, default));
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

    private sealed class Handler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Assert.Equal("graph.microsoft.com", request.RequestUri!.Host);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Contains($"devices(deviceId='{DeviceId}')", request.RequestUri.AbsoluteUri);
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body) });
        }
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
