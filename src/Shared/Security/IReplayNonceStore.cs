namespace LogCollector.Shared.Security;

/// <summary>
/// Atomically reserves request nonces in a store shared by every frontend instance.
/// </summary>
public interface IReplayNonceStore
{
    /// <returns>
    /// <see langword="true"/> when the nonce was reserved; <see langword="false"/>
    /// when the same certificate/nonce pair already exists (i.e. a replay).
    /// </returns>
    Task<bool> TryReserveAsync(
        string certificateThumbprint,
        DateTimeOffset requestTimestamp,
        Guid nonce,
        DateTimeOffset expiresAt,
        CancellationToken ct);

    /// <summary>Deletes up to <paramref name="maxEntities"/> expired nonce rows.</summary>
    Task<int> PurgeExpiredAsync(DateTimeOffset cutoff, int maxEntities, CancellationToken ct);
}
