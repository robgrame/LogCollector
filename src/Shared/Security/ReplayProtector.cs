using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LogCollector.Shared.Security;

/// <summary>
/// Validates request freshness via <c>X-Request-Timestamp</c> and ensures the
/// <c>X-Request-Nonce</c> has not been seen recently. Nonces are reserved
/// atomically in a distributed store shared by every frontend instance, so the
/// protection holds when App Service scales out.
/// </summary>
public sealed class ReplayProtector
{
    private readonly IReplayNonceStore _nonceStore;
    private readonly TimeSpan _maxSkew;
    private readonly TimeSpan _nonceRetention;
    private readonly ILogger<ReplayProtector>? _log;

    public ReplayProtector(IReplayNonceStore nonceStore, IConfiguration cfg, ILogger<ReplayProtector>? log = null)
    {
        _nonceStore = nonceStore;
        var seconds = int.TryParse(cfg["Replay:MaxTimestampSkewSeconds"], out var s) ? s : 300;
        _maxSkew = TimeSpan.FromSeconds(Math.Clamp(seconds, 30, 3600));

        var retentionSeconds = int.TryParse(cfg["Replay:NonceRetentionSeconds"], out var retention)
            ? Math.Clamp(retention, 60, 86_400)
            : 7_200;

        // Retention must outlive the accept window in both directions, otherwise a
        // nonce could expire while its timestamp is still considered fresh.
        _nonceRetention = TimeSpan.FromSeconds(Math.Max(retentionSeconds, _maxSkew.TotalSeconds * 2));
        _log = log;
    }

    public TimeSpan MaxSkew => _maxSkew;

    public TimeSpan NonceRetention => _nonceRetention;

    public (bool Ok, string? Reason, DateTimeOffset Timestamp, Guid Nonce) ValidateFreshness(
        string? timestampHeader,
        string? nonceHeader)
        => ValidateFreshness(timestampHeader, nonceHeader, DateTimeOffset.UtcNow);

    /// <summary>Freshness check with an injectable clock (used by tests).</summary>
    public (bool Ok, string? Reason, DateTimeOffset Timestamp, Guid Nonce) ValidateFreshness(
        string? timestampHeader,
        string? nonceHeader,
        DateTimeOffset utcNow)
    {
        if (string.IsNullOrWhiteSpace(timestampHeader))
            return (false, $"missing {RequestSignatureVerifier.TimestampHeader} header", default, default);
        if (string.IsNullOrWhiteSpace(nonceHeader))
            return (false, $"missing {RequestSignatureVerifier.NonceHeader} header", default, default);

        if (!DateTimeOffset.TryParse(
                timestampHeader,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal,
                out var ts))
        {
            return (false, $"{RequestSignatureVerifier.TimestampHeader} is not a valid ISO-8601 datetime", default, default);
        }

        var delta = (utcNow - ts).Duration();
        if (delta > _maxSkew)
        {
            return (false,
                $"{RequestSignatureVerifier.TimestampHeader} skew {(int)delta.TotalSeconds}s exceeds {(int)_maxSkew.TotalSeconds}s",
                default, default);
        }

        if (!Guid.TryParse(nonceHeader, out var nonce))
            return (false, $"{RequestSignatureVerifier.NonceHeader} must be a GUID", default, default);
        if (nonce == Guid.Empty)
            return (false, $"{RequestSignatureVerifier.NonceHeader} must not be the empty GUID", default, default);

        return (true, null, ts, nonce);
    }

    /// <summary>
    /// Reserves the (certificate, nonce) pair. Call this only after the
    /// certificate and body signature have been verified so unauthenticated
    /// traffic cannot inflate the nonce table.
    /// </summary>
    public async Task<(bool Ok, string? Reason)> ReserveAsync(
        string certificateThumbprint,
        DateTimeOffset timestamp,
        Guid nonce,
        CancellationToken ct)
    {
        var expiresAt = timestamp.ToUniversalTime() + _nonceRetention;
        var reserved = await _nonceStore
            .TryReserveAsync(certificateThumbprint, timestamp, nonce, expiresAt, ct)
            .ConfigureAwait(false);

        if (!reserved)
        {
            _log?.LogWarning("Replay rejected for certificate {Thumbprint}", certificateThumbprint);
            return (false, $"duplicate {RequestSignatureVerifier.NonceHeader} (replay)");
        }

        return (true, null);
    }
}
