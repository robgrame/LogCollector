using System.Security.Cryptography.X509Certificates;

namespace LogCollector.Shared.Security;

/// <summary>
/// The transport-independent view of an inbound submission that the security
/// pipeline needs. Keeping this free of ASP.NET types is what makes the whole
/// authentication path unit-testable without a host.
/// </summary>
public sealed class InventoryRequestContext
{
    public required string Method { get; init; }

    public required string Path { get; init; }

    public required ReadOnlyMemory<byte> Body { get; init; }

    public string? TimestampHeader { get; init; }

    public string? NonceHeader { get; init; }

    public string? SignatureVersionHeader { get; init; }

    public string? SignatureAlgorithmHeader { get; init; }

    public string? SignatureHeader { get; init; }

    public X509Certificate2? ConnectionCertificate { get; init; }

    /// <summary>Base64/PEM value of <c>X-ARR-ClientCert</c> as forwarded by App Service.</summary>
    public string? ForwardedCertificateHeader { get; init; }
}

/// <summary>
/// Runs the full inbound trust pipeline in a fixed, fail-closed order:
/// freshness → certificate → signature → nonce reservation → device binding.
/// </summary>
/// <remarks>
/// The order is deliberate. Freshness is checked first because it is free and
/// sheds obvious junk. The nonce is reserved only <i>after</i> the certificate
/// and signature verify, so unauthenticated traffic cannot flood the nonce
/// table. Device binding is last because it needs the parsed body.
/// </remarks>
public sealed class InventoryRequestAuthenticator
{
    public sealed record AuthenticationOutcome(
        bool Ok,
        int StatusCode,
        string? Reason,
        X509Certificate2? Certificate,
        ClientCertValidator.TrustTier Tier,
        DateTimeOffset Timestamp,
        Guid Nonce,
        bool Signed);

    private readonly ClientCertValidator _certValidator;
    private readonly RequestSignatureVerifier _signatureVerifier;
    private readonly ReplayProtector _replayProtector;

    public InventoryRequestAuthenticator(
        ClientCertValidator certValidator,
        RequestSignatureVerifier signatureVerifier,
        ReplayProtector replayProtector)
    {
        _certValidator = certValidator;
        _signatureVerifier = signatureVerifier;
        _replayProtector = replayProtector;
    }

    public int MaxBodyBytes => _signatureVerifier.MaxBodyBytes;

    public async Task<AuthenticationOutcome> AuthenticateAsync(InventoryRequestContext context, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(context);

        // 1) Timestamp + nonce syntax and freshness.
        var freshness = _replayProtector.ValidateFreshness(context.TimestampHeader, context.NonceHeader);
        if (!freshness.Ok)
            return Deny(400, freshness.Reason);

        // 2) Client certificate: chain, validity window, EKU, trust tier.
        var certResult = _certValidator.Validate(context.ConnectionCertificate, context.ForwardedCertificateHeader);
        if (!certResult.Ok)
            return Deny(401, $"client cert: {certResult.Reason}", certResult.Certificate);

        var cert = certResult.Certificate;
        if (cert is null)
        {
            // Only reachable when RequireClientCert is off; signatures still need a
            // public key, so there is nothing left to verify against.
            return Deny(401, "client certificate is required for signed requests");
        }

        // 3) Body signature over the exact received bytes.
        var signature = _signatureVerifier.Verify(
            cert,
            context.Method,
            context.Path,
            freshness.Timestamp,
            freshness.Nonce,
            context.Body.Span,
            context.SignatureVersionHeader,
            context.SignatureAlgorithmHeader,
            context.SignatureHeader);

        if (!signature.Ok)
            return Deny(401, signature.Reason, cert);

        // 4) Atomically reserve the (certificate, nonce) pair.
        var replay = await _replayProtector
            .ReserveAsync(cert.Thumbprint ?? string.Empty, freshness.Timestamp, freshness.Nonce, ct)
            .ConfigureAwait(false);

        if (!replay.Ok)
            return Deny(409, replay.Reason, cert);

        return new AuthenticationOutcome(
            true, 202, null, cert, certResult.Tier, freshness.Timestamp, freshness.Nonce, signature.Signed);
    }

    /// <summary>
    /// Confirms the certificate is bound to the device id claimed in the body.
    /// This is the control that stops an authenticated device from submitting
    /// inventory on behalf of another device (IDOR).
    /// </summary>
    public (bool Ok, int StatusCode, string? Reason, string? BoundDeviceId) AuthorizeDeviceBinding(
        X509Certificate2 certificate,
        string? claimedEntraDeviceId)
    {
        ArgumentNullException.ThrowIfNull(certificate);

        if (!_certValidator.BindingEnabled)
            return (true, 202, null, null);

        var boundDeviceId = _certValidator.GetBoundDeviceId(certificate);
        if (string.IsNullOrEmpty(boundDeviceId))
        {
            return _certValidator.RequireDeviceBinding
                ? (false, 401, "client certificate is missing the configured device-id binding claim", null)
                : (true, 202, null, null);
        }

        if (!Guid.TryParse(claimedEntraDeviceId, out var claimed)
            || !string.Equals(boundDeviceId, claimed.ToString(), StringComparison.OrdinalIgnoreCase))
        {
            return (false, 403, "client certificate is not bound to the submitted device", boundDeviceId);
        }

        return (true, 202, null, boundDeviceId);
    }

    private static AuthenticationOutcome Deny(int statusCode, string? reason, X509Certificate2? cert = null)
        => new(false, statusCode, reason, cert, ClientCertValidator.TrustTier.None, default, default, false);
}
