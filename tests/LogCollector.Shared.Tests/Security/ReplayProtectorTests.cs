using System.Collections.Concurrent;
using LogCollector.Shared.Security;
using Xunit;

namespace LogCollector.Shared.Tests.Security;

/// <summary>
/// In-memory nonce store with the same atomic "first writer wins" contract as
/// the Azure Table implementation.
/// </summary>
internal sealed class InMemoryReplayNonceStore : IReplayNonceStore
{
    private readonly ConcurrentDictionary<string, DateTimeOffset> _entries = new();

    public int Count => _entries.Count;

    public Task<bool> TryReserveAsync(
        string certificateThumbprint,
        DateTimeOffset requestTimestamp,
        Guid nonce,
        DateTimeOffset expiresAt,
        CancellationToken ct)
        => Task.FromResult(_entries.TryAdd($"{certificateThumbprint}:{nonce:N}", expiresAt));

    public Task<int> PurgeExpiredAsync(DateTimeOffset cutoff, int maxEntities, CancellationToken ct)
    {
        var removed = 0;
        foreach (var kvp in _entries)
        {
            if (removed >= maxEntities) break;
            if (kvp.Value < cutoff && _entries.TryRemove(kvp.Key, out _)) removed++;
        }
        return Task.FromResult(removed);
    }
}

public sealed class ReplayProtectorTests
{
    private static readonly DateTimeOffset Now = new(2026, 5, 5, 12, 0, 0, TimeSpan.Zero);

    private static ReplayProtector Create(InMemoryReplayNonceStore store, params (string, string)[] settings)
        => new(store, TestCertificates.Config(settings));

    [Fact]
    public void ValidateFreshness_AcceptsATimestampInsideTheSkewWindow()
    {
        var protector = Create(new InMemoryReplayNonceStore());

        var result = protector.ValidateFreshness(
            Now.AddSeconds(-60).ToString("O"), Guid.NewGuid().ToString("D"), Now);

        Assert.True(result.Ok);
        Assert.Null(result.Reason);
    }

    [Theory]
    [InlineData(-3600)]
    [InlineData(3600)]
    public void ValidateFreshness_RejectsTimestampsOutsideTheSkewWindowInBothDirections(int offsetSeconds)
    {
        var protector = Create(new InMemoryReplayNonceStore());

        var result = protector.ValidateFreshness(
            Now.AddSeconds(offsetSeconds).ToString("O"), Guid.NewGuid().ToString("D"), Now);

        Assert.False(result.Ok);
        Assert.Contains("skew", result.Reason);
    }

    [Fact]
    public void ValidateFreshness_RejectsAMissingTimestamp()
    {
        var protector = Create(new InMemoryReplayNonceStore());

        var result = protector.ValidateFreshness(null, Guid.NewGuid().ToString("D"), Now);

        Assert.False(result.Ok);
        Assert.Equal("missing X-Request-Timestamp header", result.Reason);
    }

    [Fact]
    public void ValidateFreshness_RejectsAMissingNonce()
    {
        var protector = Create(new InMemoryReplayNonceStore());

        var result = protector.ValidateFreshness(Now.ToString("O"), "   ", Now);

        Assert.False(result.Ok);
        Assert.Equal("missing X-Request-Nonce header", result.Reason);
    }

    [Fact]
    public void ValidateFreshness_RejectsANonGuidNonce()
    {
        var protector = Create(new InMemoryReplayNonceStore());

        var result = protector.ValidateFreshness(Now.ToString("O"), "not-a-guid", Now);

        Assert.False(result.Ok);
        Assert.Equal("X-Request-Nonce must be a GUID", result.Reason);
    }

    [Fact]
    public void ValidateFreshness_RejectsTheEmptyGuidNonce()
    {
        var protector = Create(new InMemoryReplayNonceStore());

        var result = protector.ValidateFreshness(Now.ToString("O"), Guid.Empty.ToString("D"), Now);

        Assert.False(result.Ok);
        Assert.Contains("empty GUID", result.Reason);
    }

    [Fact]
    public void ValidateFreshness_RejectsAnUnparseableTimestamp()
    {
        var protector = Create(new InMemoryReplayNonceStore());

        var result = protector.ValidateFreshness("yesterday", Guid.NewGuid().ToString("D"), Now);

        Assert.False(result.Ok);
        Assert.Contains("ISO-8601", result.Reason);
    }

    [Fact]
    public async Task ReserveAsync_AcceptsTheFirstUseAndRejectsTheReplay()
    {
        var store = new InMemoryReplayNonceStore();
        var protector = Create(store);
        var nonce = Guid.NewGuid();

        var first = await protector.ReserveAsync("ABC123", Now, nonce, CancellationToken.None);
        var second = await protector.ReserveAsync("ABC123", Now, nonce, CancellationToken.None);

        Assert.True(first.Ok);
        Assert.False(second.Ok);
        Assert.Equal("duplicate X-Request-Nonce (replay)", second.Reason);
        Assert.Equal(1, store.Count);
    }

    [Fact]
    public async Task ReserveAsync_ScopesNoncesPerCertificate()
    {
        var protector = Create(new InMemoryReplayNonceStore());
        var nonce = Guid.NewGuid();

        Assert.True((await protector.ReserveAsync("CERT-A", Now, nonce, CancellationToken.None)).Ok);

        // Different certificate, same nonce: not a replay of the same principal.
        Assert.True((await protector.ReserveAsync("CERT-B", Now, nonce, CancellationToken.None)).Ok);
    }

    [Fact]
    public void MaxSkew_IsClampedIntoTheSupportedRange()
    {
        Assert.Equal(TimeSpan.FromSeconds(30),
            Create(new InMemoryReplayNonceStore(), ("Replay:MaxTimestampSkewSeconds", "1")).MaxSkew);

        Assert.Equal(TimeSpan.FromSeconds(3600),
            Create(new InMemoryReplayNonceStore(), ("Replay:MaxTimestampSkewSeconds", "99999")).MaxSkew);
    }

    [Fact]
    public void NonceRetention_NeverExpiresBeforeTheAcceptWindowCloses()
    {
        // A nonce that expires while its timestamp is still fresh would reopen the
        // replay window, so retention must always be at least twice the skew.
        var protector = Create(
            new InMemoryReplayNonceStore(),
            ("Replay:MaxTimestampSkewSeconds", "3000"),
            ("Replay:NonceRetentionSeconds", "60"));

        Assert.True(protector.NonceRetention >= protector.MaxSkew * 2);
    }
}
