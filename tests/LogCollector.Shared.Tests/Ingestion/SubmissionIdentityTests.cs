using System.Text;
using LogCollector.Shared.Ingestion;
using Xunit;

namespace LogCollector.Shared.Tests.Ingestion;

public sealed class SubmissionIdentityTests
{
    [Fact]
    public void ExactBodyRetriesShareAnIdentity()
    {
        var body = Encoding.UTF8.GetBytes("{\"entraDeviceId\":\"device-a\",\"sample\":1}");
        Assert.Equal(SubmissionIdentity.FromBody(body), SubmissionIdentity.FromBody(body.ToArray()));
        Assert.Equal(64, SubmissionIdentity.FromBody(body).Length);
    }

    [Fact]
    public void DeviceOrContentChangesProduceDifferentIdentities()
    {
        Assert.NotEqual(SubmissionIdentity.FromBody("device-a"u8), SubmissionIdentity.FromBody("device-b"u8));
        Assert.NotEqual(SubmissionIdentity.FromBody("sample-1"u8), SubmissionIdentity.FromBody("sample-2"u8));
    }
}
