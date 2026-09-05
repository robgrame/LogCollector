using System.Globalization;

namespace LogCollector.Shared.Ingestion;

/// <summary>
/// Retry timing for the Logs Ingestion API: exponential backoff with full jitter,
/// overridden by a server-supplied <c>Retry-After</c> whenever one is present.
/// </summary>
/// <remarks>
/// Honouring <c>Retry-After</c> is not optional politeness — Azure Monitor
/// throttles per DCR, and ignoring the hint turns a transient 429 into a
/// self-inflicted outage as every worker instance retries in lockstep.
/// </remarks>
public static class RetryAfterPolicy
{
    /// <summary>Upper bound applied to any server-supplied delay.</summary>
    public static readonly TimeSpan MaxHonoredRetryAfter = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Parses a <c>Retry-After</c> header value in either supported form:
    /// delta-seconds (RFC 9110 §10.2.3) or an HTTP-date.
    /// </summary>
    public static TimeSpan? ParseRetryAfter(string? value, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;

        var trimmed = value.Trim();

        if (long.TryParse(trimmed, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds))
        {
            if (seconds < 0) return null;
            var delta = TimeSpan.FromSeconds(seconds);
            return delta > MaxHonoredRetryAfter ? MaxHonoredRetryAfter : delta;
        }

        if (DateTimeOffset.TryParse(
                trimmed,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var when))
        {
            var delta = when - now;
            if (delta <= TimeSpan.Zero) return TimeSpan.Zero;
            return delta > MaxHonoredRetryAfter ? MaxHonoredRetryAfter : delta;
        }

        return null;
    }

    /// <summary>
    /// Computes the wait before <paramref name="attempt"/> (1-based). A parsed
    /// <paramref name="retryAfter"/> always wins; otherwise the delay is
    /// exponential with full jitter, which is what actually de-correlates a fleet
    /// of retrying workers.
    /// </summary>
    public static TimeSpan ComputeDelay(
        int attempt,
        TimeSpan? retryAfter,
        TimeSpan baseDelay,
        TimeSpan maxDelay,
        Func<double> nextDouble)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(attempt, 1);
        ArgumentNullException.ThrowIfNull(nextDouble);

        if (retryAfter.HasValue)
        {
            var honored = retryAfter.Value;
            if (honored < TimeSpan.Zero) honored = TimeSpan.Zero;
            return honored > MaxHonoredRetryAfter ? MaxHonoredRetryAfter : honored;
        }

        // Cap the exponent before multiplying so long backlogs cannot overflow.
        var exponent = Math.Min(attempt - 1, 16);
        var uncapped = baseDelay.TotalMilliseconds * Math.Pow(2, exponent);
        var ceiling = Math.Min(uncapped, maxDelay.TotalMilliseconds);
        var jittered = ceiling * Math.Clamp(nextDouble(), 0d, 1d);

        return TimeSpan.FromMilliseconds(Math.Max(jittered, 0d));
    }

    /// <summary>Status codes worth retrying. Everything else is a permanent failure.</summary>
    public static bool IsTransient(int statusCode)
        => statusCode is 408 or 429 or 500 or 502 or 503 or 504;
}
