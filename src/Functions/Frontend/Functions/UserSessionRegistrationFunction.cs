using System.Net.Http.Headers;
using LogCollector.Frontend.Services;
using LogCollector.Shared.Security;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.IdentityModel.Tokens;
using Microsoft.Extensions.Logging;

namespace LogCollector.Frontend.Functions;

public sealed class UserSessionRegistrationFunction(
    ClientCertValidator certificateValidator,
    IDelegatedTokenValidator tokenValidator,
    IUserSessionStore sessionStore,
    UserSessionOptions options,
    ILogger<UserSessionRegistrationFunction> logger)
{
    [Function("RegisterEndpointDataSprawlUserSession")]
    public async Task<IActionResult> Register(
        [HttpTrigger(
            AuthorizationLevel.Anonymous,
            "post",
            Route = "user-sessions/register")] HttpRequest request,
        CancellationToken cancellationToken)
    {
        if (!options.IsConfigured)
        {
            return Problem(
                StatusCodes.Status503ServiceUnavailable,
                "user-session registration is not configured");
        }

        var certificate = certificateValidator.Validate(
            request.HttpContext.Connection.ClientCertificate,
            request.Headers["X-ARR-ClientCert"].ToString());
        if (!certificate.Ok || certificate.Certificate is null)
        {
            return Problem(
                StatusCodes.Status401Unauthorized,
                $"client cert: {certificate.Reason}");
        }

        var boundDeviceId =
            certificateValidator.GetBoundDeviceId(certificate.Certificate);
        if (!Guid.TryParse(boundDeviceId, out var trustedDeviceId))
        {
            return Problem(
                StatusCodes.Status401Unauthorized,
                "client certificate is missing a trusted device binding");
        }

        if (!AuthenticationHeaderValue.TryParse(
                request.Headers.Authorization.ToString(),
                out var authorization) ||
            !string.Equals(
                authorization.Scheme,
                "Bearer",
                StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(authorization.Parameter))
        {
            return Problem(
                StatusCodes.Status401Unauthorized,
                "a delegated bearer access token is required");
        }

        DelegatedUserToken token;
        try
        {
            token = await tokenValidator
                .ValidateAsync(
                    authorization.Parameter,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (SecurityTokenException)
        {
            logger.LogWarning(
                "Delegated user-session token validation failed.");
            return Problem(
                StatusCodes.Status401Unauthorized,
                "delegated access token is invalid");
        }

        if (token.DeviceId != trustedDeviceId)
        {
            return Problem(
                StatusCodes.Status403Forbidden,
                "delegated access token device does not match the client certificate");
        }

        var created = await sessionStore
            .CreateAsync(
                trustedDeviceId,
                options.ComputeCorrelation(token.UserObjectId),
                token.ExpiresAtUtc,
                cancellationToken)
            .ConfigureAwait(false);

        return new ObjectResult(new
        {
            registrationId = created.RegistrationId,
            expiresAtUtc = created.ExpiresAtUtc,
        })
        {
            StatusCode = StatusCodes.Status201Created,
        };
    }

    [Function("RevokeEndpointDataSprawlUserSession")]
    public async Task<IActionResult> Revoke(
        [HttpTrigger(
            AuthorizationLevel.Anonymous,
            "post",
            Route = "user-sessions/revoke")] HttpRequest request,
        CancellationToken cancellationToken)
    {
        if (!options.IsConfigured)
        {
            return Problem(
                StatusCodes.Status503ServiceUnavailable,
                "user-session revocation is not configured");
        }

        var certificate = certificateValidator.Validate(
            request.HttpContext.Connection.ClientCertificate,
            request.Headers["X-ARR-ClientCert"].ToString());
        if (!certificate.Ok || certificate.Certificate is null)
        {
            return Problem(
                StatusCodes.Status401Unauthorized,
                $"client cert: {certificate.Reason}");
        }

        var boundDeviceId =
            certificateValidator.GetBoundDeviceId(certificate.Certificate);
        if (!Guid.TryParse(boundDeviceId, out var trustedDeviceId))
        {
            return Problem(
                StatusCodes.Status401Unauthorized,
                "client certificate is missing a trusted device binding");
        }

        var registrationId =
            request.Headers[UserSessionOptions.RegistrationHeaderName]
                .ToString();
        if (string.IsNullOrWhiteSpace(registrationId))
        {
            return Problem(
                StatusCodes.Status400BadRequest,
                "a user-session registration id is required");
        }

        if (!await sessionStore
            .RevokeAsync(
                registrationId,
                trustedDeviceId,
                cancellationToken)
            .ConfigureAwait(false))
        {
            logger.LogWarning(
                "User-session revocation did not match the authenticated device.");
            return Problem(
                StatusCodes.Status404NotFound,
                "user-session registration was not found for this device");
        }

        logger.LogInformation(
            "User-session registration was revoked for the authenticated device.");
        return new StatusCodeResult(StatusCodes.Status204NoContent);
    }

    private static ObjectResult Problem(int statusCode, string message) =>
        new(new
        {
            status = statusCode >= 500 ? "error" : "denied",
            message,
        })
        {
            StatusCode = statusCode,
        };
}
