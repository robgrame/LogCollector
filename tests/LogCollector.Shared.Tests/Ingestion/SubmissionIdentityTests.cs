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

    [Fact]
    public void UncorrelatedSubmissionPreservesLegacyBodyIdentity()
    {
        var body = Encoding.UTF8.GetBytes(
            """{"records":[{"status":"Moved"}]}""");

        Assert.Equal(
            SubmissionIdentity.FromBody(body),
            SubmissionIdentity.FromBodyAndUserContext(body, null));
    }

    [Fact]
    public void CorrelatedSubmissionIdentityIsStableForTheSameTrustedUser()
    {
        var body = Encoding.UTF8.GetBytes(
            """{"records":[{"status":"Moved"}]}""");
        const string correlation =
            "106BDD9FC64C41084F52B4CD0D8C11AFCD0E40B04071E36ABA97B8B149FD95C6";

        var first = SubmissionIdentity.FromBodyAndUserContext(
            body,
            correlation);
        var replay = SubmissionIdentity.FromBodyAndUserContext(
            body,
            correlation.ToLowerInvariant());

        Assert.Equal(first, replay);
        Assert.NotEqual(SubmissionIdentity.FromBody(body), first);
    }
}
