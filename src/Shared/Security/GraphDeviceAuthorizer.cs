using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Collections.Concurrent;
using Azure.Core;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace LogCollector.Shared.Security;

/// <summary>Checks tenant membership using the frontend identity's Microsoft Graph tenant.</summary>
public sealed class GraphDeviceAuthorizer
{
    private static readonly TimeSpan DefaultPositiveCacheDuration = TimeSpan.FromMinutes(240);
    private const int MaximumPositiveCacheEntries = 100_000;
    private readonly TokenCredential _credential;
    private readonly HttpClient _http;
    private readonly TimeSpan _positiveCacheDuration;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger<GraphDeviceAuthorizer> _log;
    private readonly ConcurrentDictionary<Guid, DateTimeOffset> _positiveCache = new();
    private readonly ConcurrentDictionary<Guid, Lazy<Task<bool>>> _inflight = new();
    private readonly object _positiveCacheGate = new();

    public GraphDeviceAuthorizer(
        TokenCredential credential,
        HttpClient http,
        TimeSpan? positiveCacheDuration = null,
        TimeProvider? timeProvider = null,
        ILogger<GraphDeviceAuthorizer>? log = null)
    {
        var cacheDuration = positiveCacheDuration ?? DefaultPositiveCacheDuration;
        if (cacheDuration < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(
                nameof(positiveCacheDuration), "Positive cache duration cannot be negative.");

        _credential = credential;
        _http = http;
        _positiveCacheDuration = cacheDuration;
        _timeProvider = timeProvider ?? TimeProvider.System;
        _log = log ?? NullLogger<GraphDeviceAuthorizer>.Instance;
    }

    public async Task<bool> IsEnabledTenantDeviceAsync(string boundDeviceId, CancellationToken ct)
    {
        if (!Guid.TryParse(boundDeviceId, out var deviceId))
            return false;

        if (_positiveCacheDuration == TimeSpan.Zero)
            return await QueryAndCacheAsync(deviceId).WaitAsync(ct).ConfigureAwait(false);

        if (IsPositivelyCached(deviceId))
        {
            _log.LogDebug("Entra device authorization cache hit for {DeviceId}.", deviceId);
            return true;
        }

        var lookup = _inflight.GetOrAdd(deviceId, CreateLookup);
        return await lookup.Value.WaitAsync(ct).ConfigureAwait(false);
    }

    private Lazy<Task<bool>> CreateLookup(Guid deviceId)
    {
        Lazy<Task<bool>>? lookup = null;
        lookup = new Lazy<Task<bool>>(() =>
        {
            var task = QueryOrGetCachedAsync(deviceId);
            _ = task.ContinueWith(completed =>
            {
                _ = completed.Exception;
                if (_inflight.TryGetValue(deviceId, out var current)
                    && ReferenceEquals(current, lookup))
                {
                    _inflight.TryRemove(deviceId, out _);
                }
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return task;
        }, LazyThreadSafetyMode.ExecutionAndPublication);
        return lookup;
    }

    private Task<bool> QueryOrGetCachedAsync(Guid deviceId)
        => IsPositivelyCached(deviceId)
            ? Task.FromResult(true)
            : QueryAndCacheAsync(deviceId);

    private bool IsPositivelyCached(Guid deviceId)
    {
        if (!_positiveCache.TryGetValue(deviceId, out var expiresAt))
            return false;

        if (expiresAt > _timeProvider.GetUtcNow())
            return true;

        _positiveCache.TryRemove(deviceId, out _);
        return false;
    }

    private async Task<bool> QueryAndCacheAsync(Guid deviceId)
    {
        var token = await _credential.GetTokenAsync(
            new TokenRequestContext(["https://graph.microsoft.com/.default"]), CancellationToken.None);
        using var request = new HttpRequestMessage(HttpMethod.Get,
            $"https://graph.microsoft.com/v1.0/devices(deviceId='{deviceId:D}')?$select=deviceId,accountEnabled");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        using var response = await _http.SendAsync(request, CancellationToken.None);
        if (response.StatusCode == HttpStatusCode.NotFound) return false;
        // Outages and missing application consent are not an authorization success.
        // Propagate these failures so intake fails and the client retains its spool.
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(
            await response.Content.ReadAsStringAsync(CancellationToken.None));
        var root = document.RootElement;
        var authorized = root.TryGetProperty("deviceId", out var actual)
            && actual.ValueKind == JsonValueKind.String
            && Guid.TryParse(actual.GetString(), out var actualId)
            && actualId == deviceId
            && root.TryGetProperty("accountEnabled", out var enabled)
            && enabled.ValueKind == JsonValueKind.True;

        if (authorized && _positiveCacheDuration > TimeSpan.Zero)
        {
            var expiresAt = _timeProvider.GetUtcNow().Add(_positiveCacheDuration);
            lock (_positiveCacheGate)
            {
                RemoveExpiredEntries();
                if (_positiveCache.Count >= MaximumPositiveCacheEntries
                    && !_positiveCache.ContainsKey(deviceId))
                {
                    _log.LogWarning(
                        "Skipped Entra authorization caching for {DeviceId}: cache reached its {Limit} entry limit.",
                        deviceId, MaximumPositiveCacheEntries);
                    return true;
                }

                _positiveCache[deviceId] = expiresAt;
            }

            _log.LogInformation(
                "Cached successful Entra device authorization for {DeviceId} until {ExpiresAt}.",
                deviceId, expiresAt);
        }

        return authorized;
    }

    private void RemoveExpiredEntries()
    {
        if (_positiveCache.Count < MaximumPositiveCacheEntries)
            return;

        var now = _timeProvider.GetUtcNow();
        foreach (var entry in _positiveCache)
        {
            if (entry.Value <= now)
                _positiveCache.TryRemove(entry.Key, out _);
        }
    }
}
