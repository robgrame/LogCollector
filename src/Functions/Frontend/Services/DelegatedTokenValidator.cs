using System.Security.Claims;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;

namespace LogCollector.Frontend.Services;

public sealed record DelegatedUserToken(
    Guid TenantId,
    Guid UserObjectId,
    Guid DeviceId,
    DateTimeOffset ExpiresAtUtc);

public interface IDelegatedTokenValidator
{
    Task<DelegatedUserToken> ValidateAsync(
        string accessToken,
        CancellationToken cancellationToken);
}

public sealed class EntraDelegatedTokenValidator : IDelegatedTokenValidator
{
    private readonly UserSessionOptions _options;
    private readonly IConfigurationManager<OpenIdConnectConfiguration> _configuration;
    private readonly JwtSecurityTokenHandler _handler = new()
    {
        MapInboundClaims = false,
    };

    public EntraDelegatedTokenValidator(
        UserSessionOptions options,
        IConfigurationManager<OpenIdConnectConfiguration> configuration)
    {
        _options = options;
        _configuration = configuration;
    }

    public async Task<DelegatedUserToken> ValidateAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        if (!_options.IsConfigured)
        {
            throw new InvalidOperationException(
                "Endpoint Data Sprawl user sessions are not configured.");
        }

        if (string.IsNullOrWhiteSpace(accessToken))
        {
            throw new SecurityTokenException("Delegated access token is missing.");
        }

        var configuration = await _configuration
            .GetConfigurationAsync(cancellationToken)
            .ConfigureAwait(false);
        var parameters = new TokenValidationParameters
        {
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = configuration.SigningKeys,
            RequireSignedTokens = true,
            ValidateIssuer = true,
            ValidIssuer = _options.Issuer,
            ValidateAudience = true,
            ValidAudience = _options.Audience,
            ValidateLifetime = true,
            RequireExpirationTime = true,
            ClockSkew = TimeSpan.FromMinutes(2),
            ValidAlgorithms = [SecurityAlgorithms.RsaSha256],
            IncludeTokenOnFailedValidation = false,
        };

        var principal = _handler.ValidateToken(
            accessToken,
            parameters,
            out var validatedToken);
        if (validatedToken is not JwtSecurityToken jwt ||
            jwt.ValidTo == DateTime.MinValue)
        {
            throw new SecurityTokenException("Access token format is invalid.");
        }

        var tenantId = RequiredGuidClaim(principal, "tid");
        if (tenantId != _options.TenantId)
        {
            throw new SecurityTokenInvalidIssuerException(
                "Access token tenant does not match the configured tenant.");
        }

        var scopes = principal.FindFirstValue("scp")?
            .Split(' ', StringSplitOptions.RemoveEmptyEntries) ?? [];
        if (!scopes.Contains(_options.RequiredScope, StringComparer.Ordinal))
        {
            throw new SecurityTokenException(
                "Access token does not contain the required delegated scope.");
        }

        return new DelegatedUserToken(
            tenantId,
            RequiredGuidClaim(principal, "oid"),
            RequiredGuidClaim(principal, "deviceid"),
            new DateTimeOffset(DateTime.SpecifyKind(jwt.ValidTo, DateTimeKind.Utc)));
    }

    private static Guid RequiredGuidClaim(
        ClaimsPrincipal principal,
        string claimType)
    {
        var value = principal.FindFirstValue(claimType);
        return Guid.TryParse(value, out var parsed) && parsed != Guid.Empty
            ? parsed
            : throw new SecurityTokenException(
                $"Access token claim '{claimType}' must be a non-empty GUID.");
    }
}
