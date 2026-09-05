using LogCollector.Shared.Ingestion;
using Xunit;

namespace LogCollector.Shared.Tests.Ingestion;

public sealed class RetryAfterPolicyTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 1, 10, 0, 0, TimeSpan.Zero);

    [Fact]
    public void ParseRetryAfter_ReadsDeltaSeconds()
    {
        Assert.Equal(TimeSpan.FromSeconds(30), RetryAfterPolicy.ParseRetryAfter("30", Now));
    }

    [Fact]
    public void ParseRetryAfter_ReadsAnHttpDate()
    {
        var value = Now.AddSeconds(45).ToString("R");

        var parsed = RetryAfterPolicy.ParseRetryAfter(value, Now);

        Assert.NotNull(parsed);
        Assert.InRange(parsed!.Value.TotalSeconds, 44, 46);
    }

    [Fact]
    public void ParseRetryAfter_TreatsAPastDateAsNoWait()
    {
        var value = Now.AddSeconds(-60).ToString("R");

        Assert.Equal(TimeSpan.Zero, RetryAfterPolicy.ParseRetryAfter(value, Now));
    }

    [Fact]
    public void ParseRetryAfter_ClampsAnAbsurdlyLongDelay()
    {
        // A server that asks for an hour must not park a worker for an hour.
        Assert.Equal(RetryAfterPolicy.MaxHonoredRetryAfter, RetryAfterPolicy.ParseRetryAfter("3600", Now));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("soon")]
    [InlineData("-5")]
    public void ParseRetryAfter_ReturnsNullForUnusableValues(string? value)
    {
        Assert.Null(RetryAfterPolicy.ParseRetryAfter(value, Now));
    }

    [Fact]
    public void ComputeDelay_HonoursRetryAfterOverTheBackoffCurve()
    {
        var delay = RetryAfterPolicy.ComputeDelay(
            attempt: 5,
            retryAfter: TimeSpan.FromSeconds(7),
            baseDelay: TimeSpan.FromSeconds(1),
            maxDelay: TimeSpan.FromSeconds(60),
            nextDouble: () => 1.0);

        Assert.Equal(TimeSpan.FromSeconds(7), delay);
    }

    [Fact]
    public void ComputeDelay_GrowsExponentiallyUpToTheCeiling()
    {
        TimeSpan For(int attempt) => RetryAfterPolicy.ComputeDelay(
            attempt, null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(60), () => 1.0);

        Assert.Equal(TimeSpan.FromSeconds(1), For(1));
        Assert.Equal(TimeSpan.FromSeconds(2), For(2));
        Assert.Equal(TimeSpan.FromSeconds(4), For(3));
        Assert.Equal(TimeSpan.FromSeconds(60), For(20));
    }

    [Fact]
    public void ComputeDelay_AppliesFullJitterSoTheDelayIsNeverFixed()
    {
        var zero = RetryAfterPolicy.ComputeDelay(4, null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(60), () => 0.0);
        var half = RetryAfterPolicy.ComputeDelay(4, null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(60), () => 0.5);
        var full = RetryAfterPolicy.ComputeDelay(4, null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(60), () => 1.0);

        Assert.Equal(TimeSpan.Zero, zero);
        Assert.Equal(TimeSpan.FromSeconds(4), half);
        Assert.Equal(TimeSpan.FromSeconds(8), full);
    }

    [Fact]
    public void ComputeDelay_DoesNotOverflowOnLongBacklogs()
    {
        var delay = RetryAfterPolicy.ComputeDelay(
            attempt: 64, retryAfter: null,
            baseDelay: TimeSpan.FromSeconds(30), maxDelay: TimeSpan.FromSeconds(120),
            nextDouble: () => 1.0);

        Assert.Equal(TimeSpan.FromSeconds(120), delay);
    }

    [Fact]
    public void ComputeDelay_RejectsANonPositiveAttemptNumber()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => RetryAfterPolicy.ComputeDelay(
            0, null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1), () => 0.5));
    }

    [Theory]
    [InlineData(408, true)]
    [InlineData(429, true)]
    [InlineData(500, true)]
    [InlineData(503, true)]
    [InlineData(504, true)]
    [InlineData(400, false)]
    [InlineData(401, false)]
    [InlineData(403, false)]
    [InlineData(404, false)]
    [InlineData(413, false)]
    public void IsTransient_ClassifiesStatusCodesCorrectly(int status, bool expected)
    {
        Assert.Equal(expected, RetryAfterPolicy.IsTransient(status));
    }
}
