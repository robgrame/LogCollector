using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Json;
using LogCollector.Frontend.Functions;
using LogCollector.Frontend.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace LogCollector.Frontend.Tests;

public sealed class UserSessionRegistrationTests
{
    private static readonly Guid TenantId =
        Guid.Parse("11111111-2222-3333-4444-555555555555");
    private static readonly Guid UserId =
        Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    private const string ExpectedCorrelation =
        "106BDD9FC64C41084F52B4CD0D8C11AFCD0E40B04071E36ABA97B8B149FD95C6";

    [Fact]
    public void OptionsPreserveExistingCorrelationAlgorithm()
    {
        using var harness = new FrontendTestHarness();

        var result =
            new UserSessionOptions(harness.Config)
                .ComputeCorrelation(UserId);

        Assert.Equal(ExpectedCorrelation, result);
    }

    [Fact]
    public void OptionsDefaultRegistrationLifetimeToEightHours()
    {
        var configuration = SessionConfiguration();

        var options = new UserSessionOptions(configuration);

        Assert.Equal(TimeSpan.FromMinutes(480), options.RegistrationTtl);
    }

    [Fact]
    public void OptionsAllowDisabledConfigurationWithEmptyAppSettings()
    {
        var values = new Dictionary<string, string?>
        {
            ["UserSession:TenantId"] = string.Empty,
            ["UserSession:Audience"] = string.Empty,
            ["UserSession:RequiredScope"] = string.Empty,
            ["UserSession:MetadataAddress"] = string.Empty,
            ["UserSession:TableName"] = string.Empty,
            ["UserSession:HmacKeyBase64"] = string.Empty,
            ["UserSession:RegistrationTtlMinutes"] = string.Empty,
        };
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(values)
            .Build();

        var options = new UserSessionOptions(configuration);

        Assert.False(options.IsConfigured);
        Assert.Equal("UserSessions", options.TableName);
        Assert.Equal(TimeSpan.FromMinutes(480), options.RegistrationTtl);
    }

    [Fact]
    public void OptionsDeriveIssuerFromConfiguredAuthority()
    {
        var options = new UserSessionOptions(SessionConfiguration(
            metadataAddress:
                $"https://login.microsoftonline.us/common/v2.0/.well-known/openid-configuration"));

        Assert.Equal(
            $"https://login.microsoftonline.us/{TenantId:D}/v2.0",
            options.Issuer);
    }

    [Theory]
    [InlineData("1")]
    [InlineData("1440")]
    public void OptionsAcceptRegistrationLifetimeBounds(string minutes)
    {
        var configuration = SessionConfiguration(minutes);

        var options = new UserSessionOptions(configuration);

        Assert.Equal(
            TimeSpan.FromMinutes(int.Parse(minutes)),
            options.RegistrationTtl);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("1441")]
    public void OptionsRejectRegistrationLifetimeOutsideBounds(string minutes)
    {
        var configuration = SessionConfiguration(minutes);

        Assert.Throws<InvalidOperationException>(
            () => new UserSessionOptions(configuration));
    }

    [Fact]
    public async Task ValidRegistrationBindsUserToCertificateDevice()
    {
        using var harness = new FrontendTestHarness();
        var token = new StubTokenValidator(new DelegatedUserToken(
            TenantId,
            UserId,
            Guid.Parse(FrontendTestHarness.DeviceId),
            DateTimeOffset.UtcNow.AddMinutes(30)));
        var logger = new RecordingLogger<UserSessionRegistrationFunction>();
        var function = new UserSessionRegistrationFunction(
            harness.CertificateValidator,
            token,
            harness.UserSessions,
            new UserSessionOptions(harness.Config),
            logger);
        var request = RegistrationRequest(harness, "sensitive-access-token");

        var result = await function.Register(request, default);

        var response = Assert.IsType<ObjectResult>(result);
        Assert.Equal(StatusCodes.Status201Created, response.StatusCode);
        var body = JsonSerializer.SerializeToElement(response.Value);
        var registrationId = body.GetProperty("registrationId").GetString()!;
        Assert.Matches("^[A-Za-z0-9_-]{43}$", registrationId);
        var resolved = await harness.UserSessions.ResolveAsync(
            registrationId,
            Guid.Parse(FrontendTestHarness.DeviceId),
            default);
        Assert.True(resolved.Resolved);
        Assert.Equal(ExpectedCorrelation, resolved.UserCorrelationId);
        Assert.DoesNotContain(
            "sensitive-access-token",
            string.Join("\n", logger.Messages),
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task RegistrationRejectsTokenForDifferentDevice()
    {
        using var harness = new FrontendTestHarness();
        var function = new UserSessionRegistrationFunction(
            harness.CertificateValidator,
            new StubTokenValidator(new DelegatedUserToken(
                TenantId,
                UserId,
                Guid.Parse(FrontendTestHarness.OtherDeviceId),
                DateTimeOffset.UtcNow.AddMinutes(30))),
            harness.UserSessions,
            new UserSessionOptions(harness.Config),
            new RecordingLogger<UserSessionRegistrationFunction>());

        var result = await function.Register(
            RegistrationRequest(harness, "token"),
            default);

        AssertDenied(result, 403, "does not match");
    }

    [Fact]
    public async Task RevokeClearsCorrelationForCertificateBoundRegistration()
    {
        using var harness = new FrontendTestHarness();
        var registrationId = harness.UserSessions.Add(
            Guid.Parse(FrontendTestHarness.DeviceId),
            ExpectedCorrelation);
        var function = new UserSessionRegistrationFunction(
            harness.CertificateValidator,
            new StubTokenValidator(new DelegatedUserToken(
                TenantId,
                UserId,
                Guid.Parse(FrontendTestHarness.DeviceId),
                DateTimeOffset.UtcNow.AddMinutes(30))),
            harness.UserSessions,
            new UserSessionOptions(harness.Config),
            new RecordingLogger<UserSessionRegistrationFunction>());
        var request = RegistrationRequest(harness, "unused");
        request.Path = "/api/user-sessions/revoke";
        request.Headers[UserSessionOptions.RegistrationHeaderName] =
            registrationId;

        var result = await function.Revoke(request, default);

        var response = Assert.IsType<StatusCodeResult>(result);
        Assert.Equal(StatusCodes.Status204NoContent, response.StatusCode);
        Assert.Null(harness.UserSessions.GetCorrelation(registrationId));
    }

    [Fact]
    public async Task RevokeCannotClearRegistrationBoundToAnotherDevice()
    {
        using var harness = new FrontendTestHarness();
        var registrationId = harness.UserSessions.Add(
            Guid.Parse(FrontendTestHarness.OtherDeviceId),
            ExpectedCorrelation);
        var function = new UserSessionRegistrationFunction(
            harness.CertificateValidator,
            new StubTokenValidator(new DelegatedUserToken(
                TenantId,
                UserId,
                Guid.Parse(FrontendTestHarness.DeviceId),
                DateTimeOffset.UtcNow.AddMinutes(30))),
            harness.UserSessions,
            new UserSessionOptions(harness.Config),
            new RecordingLogger<UserSessionRegistrationFunction>());
        var request = RegistrationRequest(harness, "unused");
        request.Path = "/api/user-sessions/revoke";
        request.Headers[UserSessionOptions.RegistrationHeaderName] =
            registrationId;

        var result = await function.Revoke(request, default);

        AssertDenied(result, 404, "not found for this device");
        Assert.Equal(
            ExpectedCorrelation,
            harness.UserSessions.GetCorrelation(registrationId));
    }

    [Fact]
    public async Task InvalidTokenValueIsNeverWrittenToLogs()
    {
        const string sensitiveToken =
            "DO-NOT-LOG-DELEGATED-ACCESS-TOKEN";
        using var harness = new FrontendTestHarness();
        var logger = new RecordingLogger<UserSessionRegistrationFunction>();
        var function = new UserSessionRegistrationFunction(
            harness.CertificateValidator,
            new ThrowingTokenValidator(),
            harness.UserSessions,
            new UserSessionOptions(harness.Config),
            logger);

        var result = await function.Register(
            RegistrationRequest(harness, sensitiveToken),
            default);

        AssertDenied(result, 401, "invalid");
        Assert.DoesNotContain(
            sensitiveToken,
            string.Join("\n", logger.Messages),
            StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("wrong-tenant")]
    [InlineData("wrong-audience")]
    [InlineData("wrong-scope")]
    [InlineData("wrong-algorithm")]
    public async Task TokenValidatorRejectsInvalidAuthorizationClaimsOrAlgorithm(
        string condition)
    {
        using var rsa = RSA.Create(2048);
        var key = new RsaSecurityKey(rsa) { KeyId = "test-key" };
        var configuration = new OpenIdConnectConfiguration
        {
            Issuer =
                $"https://login.microsoftonline.com/{TenantId:D}/v2.0",
        };
        configuration.SigningKeys.Add(key);
        using var harness = new FrontendTestHarness();
        var validator = new EntraDelegatedTokenValidator(
            new UserSessionOptions(harness.Config),
            new StaticConfigurationManager(configuration));
        var token = CreateToken(
            key,
            condition == "wrong-tenant"
                ? Guid.NewGuid()
                : TenantId,
            condition == "wrong-audience"
                ? "api://other"
                : "api://edsr-test",
            condition == "wrong-scope"
                ? "EndpointDataSprawl.Other"
                : "EndpointDataSprawl.Register",
            condition == "wrong-algorithm"
                ? SecurityAlgorithms.RsaSha512
                : SecurityAlgorithms.RsaSha256);

        await Assert.ThrowsAnyAsync<SecurityTokenException>(
            () => validator.ValidateAsync(token, default));
    }

    [Fact]
    public async Task TokenValidatorDoesNotAcceptApplicationRoleAsDelegatedScope()
    {
        using var rsa = RSA.Create(2048);
        var key = new RsaSecurityKey(rsa) { KeyId = "test-key" };
        var configuration = new OpenIdConnectConfiguration();
        configuration.SigningKeys.Add(key);
        using var harness = new FrontendTestHarness();
        var validator = new EntraDelegatedTokenValidator(
            new UserSessionOptions(harness.Config),
            new StaticConfigurationManager(configuration));
        var token = CreateToken(
            key,
            TenantId,
            "api://edsr-test",
            scope: null,
            algorithm: SecurityAlgorithms.RsaSha256,
            role: "EndpointDataSprawl.Register");

        await Assert.ThrowsAnyAsync<SecurityTokenException>(
            () => validator.ValidateAsync(token, default));
    }

    private static string CreateToken(
        SecurityKey key,
        Guid tenantId,
        string audience,
        string? scope = "EndpointDataSprawl.Register",
        string algorithm = SecurityAlgorithms.RsaSha256,
        string? role = null)
    {
        var now = DateTime.UtcNow;
        var claims = new List<Claim>
        {
            new("tid", tenantId.ToString("D")),
            new("oid", UserId.ToString("D")),
            new("deviceid", FrontendTestHarness.DeviceId),
        };
        if (scope is not null)
        {
            claims.Add(new Claim("scp", scope));
        }

        if (role is not null)
        {
            claims.Add(new Claim("roles", role));
        }

        var token = new JwtSecurityToken(
            issuer:
                $"https://login.microsoftonline.com/{tenantId:D}/v2.0",
            audience: audience,
            claims: claims,
            notBefore: now.AddMinutes(-1),
            expires: now.AddMinutes(30),
            signingCredentials:
                new SigningCredentials(key, algorithm));
        token.Header["kid"] = key.KeyId;
        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    private static HttpRequest RegistrationRequest(
        FrontendTestHarness harness,
        string accessToken)
    {
        var request = new DefaultHttpContext().Request;
        request.Method = "POST";
        request.Path = "/api/user-sessions/register";
        request.HttpContext.Connection.ClientCertificate =
            harness.PresentedCertificate;
        request.Headers.Authorization = $"Bearer {accessToken}";
        return request;
    }

    private static IConfiguration SessionConfiguration(
        string? ttl = null,
        string? metadataAddress = null)
    {
        var values = new Dictionary<string, string?>
        {
            ["UserSession:TenantId"] = TenantId.ToString("D"),
            ["UserSession:Audience"] = "api://edsr-test",
            ["UserSession:RequiredScope"] = "EndpointDataSprawl.Register",
            ["UserSession:MetadataAddress"] =
                metadataAddress ??
                $"https://login.microsoftonline.com/{TenantId:D}/v2.0/.well-known/openid-configuration",
            ["UserSession:TableName"] = "UserSessions",
            ["UserSession:HmacKeyBase64"] =
                "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        };
        if (ttl is not null)
        {
            values["UserSession:RegistrationTtlMinutes"] = ttl;
        }

        return new ConfigurationBuilder()
            .AddInMemoryCollection(values)
            .Build();
    }

    private static void AssertDenied(
        IActionResult result,
        int status,
        string reason)
    {
        var response = Assert.IsType<ObjectResult>(result);
        Assert.Equal(status, response.StatusCode);
        var body = JsonSerializer.SerializeToElement(response.Value);
        Assert.Contains(reason, body.GetProperty("message").GetString());
    }

    private sealed class StubTokenValidator(DelegatedUserToken result)
        : IDelegatedTokenValidator
    {
        public Task<DelegatedUserToken> ValidateAsync(
            string accessToken,
            CancellationToken cancellationToken) =>
            Task.FromResult(result);
    }

    private sealed class ThrowingTokenValidator : IDelegatedTokenValidator
    {
        public Task<DelegatedUserToken> ValidateAsync(
            string accessToken,
            CancellationToken cancellationToken) =>
            throw new SecurityTokenException(accessToken);
    }

    private sealed class StaticConfigurationManager(
        OpenIdConnectConfiguration configuration)
        : IConfigurationManager<OpenIdConnectConfiguration>
    {
        public Task<OpenIdConnectConfiguration> GetConfigurationAsync(
            CancellationToken cancel) =>
            Task.FromResult(configuration);

        public void RequestRefresh()
        {
        }
    }

    private sealed class RecordingLogger<T> : ILogger<T>
    {
        public List<string> Messages { get; } = [];

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter) =>
            Messages.Add(formatter(state, exception));
    }
}
