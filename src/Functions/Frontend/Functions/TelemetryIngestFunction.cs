using System.Text.Json;
using LogCollector.Frontend.Services;
using LogCollector.Shared.Ingestion;
using LogCollector.Shared.Models;
using LogCollector.Shared.Security;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace LogCollector.Frontend.Functions;

/// <summary>
/// Purpose-independent submission intake, with an alias for existing inventory clients.
/// </summary>
/// <remarks>
/// <para>
/// The trigger is <see cref="AuthorizationLevel.Anonymous"/> <b>by design</b>.
/// A Function key is a bearer secret that has to be distributed to every managed
/// device, cannot be rotated per-device, and is trivially recoverable from a
/// scheduled task. Authentication here is entirely certificate-based:
/// App Service enforces mandatory client certificates at the edge, and this
/// function then re-validates the chain, verifies an IDA-SIGNATURE-V1 signature
/// over the exact body bytes, enforces timestamp/nonce anti-replay, and proves
/// that the certificate is bound to the Entra device id in the payload.
/// </para>
/// <para>
/// Removing <c>AuthorizationLevel.Anonymous</c> would not add security; it would
/// only reintroduce the shared secret this design exists to eliminate.
/// </para>
/// </remarks>
public sealed class TelemetryIngestFunction
{
    private static readonly JsonSerializerOptions EnvelopeJson = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly TelemetryRequestAuthenticator _authenticator;
    private readonly TelemetryPointerPublisher _publisher;
    private readonly IngestionStreamMap _streamMap;
    private readonly TelemetryIntakeOptions _options;
    private readonly GraphDeviceAuthorizer _deviceAuthorizer;
    private readonly ILogger<TelemetryIngestFunction> _log;

    public TelemetryIngestFunction(
        ClientCertValidator certValidator,
        RequestSignatureVerifier signatureVerifier,
        ReplayProtector replayProtector,
        TelemetryPointerPublisher publisher,
        IngestionStreamMap streamMap,
        TelemetryIntakeOptions options,
        GraphDeviceAuthorizer deviceAuthorizer,
        ILogger<TelemetryIngestFunction> log)
    {
        _authenticator = new TelemetryRequestAuthenticator(certValidator, signatureVerifier, replayProtector);
        _publisher = publisher;
        _streamMap = streamMap;
        _options = options;
        _deviceAuthorizer = deviceAuthorizer;
        _log = log;
    }

    [Function("SubmitTelemetry")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "submit")] HttpRequest req,
        CancellationToken ct)
        => await HandleAsync(req, ct).ConfigureAwait(false);

    [Function("SubmitLegacyInventory")]
    public async Task<IActionResult> RunLegacy(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "inventory")] HttpRequest req,
        CancellationToken ct)
        => await HandleAsync(req, ct).ConfigureAwait(false);

    private async Task<IActionResult> HandleAsync(
        HttpRequest req,
        CancellationToken ct)
    {
        var correlationId = Guid.NewGuid().ToString("N");
        using var scope = _log.BeginScope(new Dictionary<string, object> { ["CorrelationId"] = correlationId });

        // Read the exact bytes the client signed. Never deserialize-then-reserialize
        // before verification: a round-trip changes the bytes and breaks the binding.
        byte[] bodyBytes;
        try
        {
            bodyBytes = await ReadBodyAsync(req.Body, _authenticator.MaxBodyBytes, ct).ConfigureAwait(false);
        }
        catch (BodyTooLargeException)
        {
            _log.LogWarning("Rejected oversized submission (limit {Limit} bytes).", _authenticator.MaxBodyBytes);
            return Problem(StatusCodes.Status413PayloadTooLarge,
                $"request body exceeds {_authenticator.MaxBodyBytes} bytes", correlationId);
        }

        if (bodyBytes.Length == 0)
            return Problem(StatusCodes.Status400BadRequest, "request body is empty", correlationId);

        var context = new TelemetryRequestContext
        {
            Method = req.Method,
            Path = req.Path.Value ?? string.Empty,
            Body = bodyBytes,
            TimestampHeader = req.Headers[RequestSignatureVerifier.TimestampHeader].ToString(),
            NonceHeader = req.Headers[RequestSignatureVerifier.NonceHeader].ToString(),
            SignatureVersionHeader = req.Headers[RequestSignatureVerifier.VersionHeader].ToString(),
            SignatureAlgorithmHeader = req.Headers[RequestSignatureVerifier.AlgorithmHeader].ToString(),
            SignatureHeader = req.Headers[RequestSignatureVerifier.SignatureHeader].ToString(),
            ConnectionCertificate = req.HttpContext.Connection.ClientCertificate,
            ForwardedCertificateHeader = req.Headers["X-ARR-ClientCert"].ToString(),
        };

        var auth = await _authenticator.AuthenticateAsync(context, ct).ConfigureAwait(false);
        if (!auth.Ok)
        {
            _log.LogWarning(
                "Submission denied at status {Status}: {Reason} (thumb={Thumb})",
                auth.StatusCode, auth.Reason, auth.Certificate?.Thumbprint ?? "(none)");
            return Problem(auth.StatusCode, auth.Reason ?? "request denied", correlationId);
        }

        TelemetryEnvelope? envelope;
        try
        {
            envelope = JsonSerializer.Deserialize<TelemetryEnvelope>(bodyBytes, EnvelopeJson);
        }
        catch (JsonException ex)
        {
            _log.LogWarning(ex, "Submission body is not valid JSON.");
            return Problem(StatusCodes.Status400BadRequest, "request body is not valid JSON", correlationId);
        }

        if (envelope is null)
            return Problem(StatusCodes.Status400BadRequest, "request body is not a valid envelope", correlationId);

        var structural = envelope.Validate(_options.MaxRecordsPerEnvelope);
        if (!structural.Ok)
            return Problem(StatusCodes.Status400BadRequest, structural.Reason!, correlationId);

        // Destination allow-list: a client may only target a table that an
        // operator has explicitly mapped to a DCR stream.
        if (!_streamMap.IsAllowed(envelope.TableName))
        {
            _log.LogWarning("Submission targeted unmapped table {Table}.", envelope.TableName);
            return Problem(StatusCodes.Status400BadRequest,
                $"table '{envelope.TableName}' is not an accepted ingestion target", correlationId);
        }

        var binding = _authenticator.AuthorizeDeviceBinding(auth.Certificate!, envelope.EntraDeviceId);
        if (!binding.Ok)
        {
            _log.LogWarning(
                "Device binding denied: bound={Bound} claimed={Claimed} thumb={Thumb}",
                binding.BoundDeviceId ?? "(none)", envelope.EntraDeviceId, auth.Certificate!.Thumbprint);
            return Problem(binding.StatusCode, binding.Reason!, correlationId);
        }

        if (auth.Tier == ClientCertValidator.TrustTier.IntuneEnrollment
            && !await _deviceAuthorizer.IsEnabledTenantDeviceAsync(binding.BoundDeviceId!, ct))
        {
            _log.LogWarning("Intune device {DeviceId} is absent or disabled in the frontend identity's tenant.", binding.BoundDeviceId);
            return Problem(StatusCodes.Status403Forbidden, "device is not authorized in this tenant", correlationId);
        }

        var submissionId = SubmissionIdentity.FromBody(bodyBytes);
        var pointer = await _publisher
            .PublishAsync(envelope, bodyBytes, submissionId, auth.Certificate!.Thumbprint, ct)
            .ConfigureAwait(false);

        return new ObjectResult(new
        {
            status = "accepted",
            correlationId = submissionId,
            tableName = pointer.TableName,
            recordCount = envelope.Records!.Count,
            trustTier = auth.Tier.ToString(),
        })
        {
            StatusCode = StatusCodes.Status202Accepted,
        };
    }

    private static async Task<byte[]> ReadBodyAsync(Stream body, int maxBytes, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        var rented = new byte[81920];

        while (true)
        {
            var read = await body.ReadAsync(rented, ct).ConfigureAwait(false);
            if (read == 0) break;

            if (buffer.Length + read > maxBytes)
                throw new BodyTooLargeException();

            buffer.Write(rented, 0, read);
        }

        return buffer.ToArray();
    }

    private static ObjectResult Problem(int statusCode, string message, string correlationId)
        => new(new { status = statusCode >= 500 ? "error" : "denied", message, correlationId })
        {
            StatusCode = statusCode,
        };

    private sealed class BodyTooLargeException : Exception;
}
