using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LogCollector.Shared.Security;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LogCollector.Shared.Tests.Security;

/// <summary>
/// End-to-end coverage of the frontend trust pipeline: this is the test that
/// would fail if any single control were removed.
/// </summary>
public sealed class TelemetryRequestAuthenticatorTests
{
    private const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    private const string OtherDeviceId = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
    private const string Path = "/api/inventory";

    private sealed record Harness(
        TelemetryRequestAuthenticator Authenticator,
        X509Certificate2 Ca,
        X509Certificate2 Leaf,
        InMemoryReplayNonceStore Store);

    private static Harness CreateHarness(
        string? leafSanDeviceId = DeviceId,
        params (string, string)[] extraSettings)
    {
        var ca = TestCertificates.CreateRootCa("Contoso Issuing CA");
        var leaf = TestCertificates.CreateClientCertificate(ca, "device-01", sanUriDeviceId: leafSanDeviceId);

        var settings = new List<(string, string)>
        {
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "Auto"),
            ("ClientCert:RequireDeviceBinding", "true"),
        };
        settings.AddRange(extraSettings);

        var config = TestCertificates.Config([.. settings]);
        var store = new InMemoryReplayNonceStore();

        var authenticator = new TelemetryRequestAuthenticator(
            new ClientCertValidator(config, NullLogger<ClientCertValidator>.Instance),
            new RequestSignatureVerifier(config),
            new ReplayProtector(store, config));

        return new Harness(authenticator, ca, leaf, store);
    }

    private static TelemetryRequestContext BuildRequest(
        X509Certificate2 signingCertificate,
        byte[] body,
        DateTimeOffset? timestamp = null,
        Guid? nonce = null,
        X509Certificate2? presentedCertificate = null,
        byte[]? signedBodyOverride = null)
    {
        var ts = timestamp ?? DateTimeOffset.UtcNow;
        var n = nonce ?? Guid.NewGuid();

        var canonical = Encoding.UTF8.GetBytes(
            RequestSignatureVerifier.BuildCanonicalRequest("POST", Path, ts, n, signedBodyOverride ?? body));

        using var rsa = signingCertificate.GetRSAPrivateKey()!;
        var signature = Convert.ToBase64String(
            rsa.SignData(canonical, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));

        return new TelemetryRequestContext
        {
            Method = "POST",
            Path = Path,
            Body = body,
            TimestampHeader = ts.ToString("O"),
            NonceHeader = n.ToString("D"),
            SignatureVersionHeader = RequestSignatureVerifier.ProtocolVersion,
            SignatureAlgorithmHeader = RequestSignatureVerifier.RsaAlgorithm,
            SignatureHeader = signature,
            ConnectionCertificate = presentedCertificate
                ?? TestCertificates.PublicOnly(signingCertificate),
        };
    }

    [Fact]
    public async Task AuthenticateAsync_AcceptsAWellFormedSignedRequest()
    {
        var h = CreateHarness();
        var body = Encoding.UTF8.GetBytes("{\"records\":[]}");

        var outcome = await h.Authenticator.AuthenticateAsync(BuildRequest(h.Leaf, body), CancellationToken.None);

        Assert.True(outcome.Ok, outcome.Reason);
        Assert.True(outcome.Signed);
        Assert.Equal(ClientCertValidator.TrustTier.EnterprisePki, outcome.Tier);
    }

    [Fact]
    public async Task AuthenticateAsync_RejectsAReplayOfTheIdenticalRequest()
    {
        var h = CreateHarness();
        var body = Encoding.UTF8.GetBytes("{\"records\":[]}");
        var request = BuildRequest(h.Leaf, body);

        var first = await h.Authenticator.AuthenticateAsync(request, CancellationToken.None);
        var replay = await h.Authenticator.AuthenticateAsync(request, CancellationToken.None);

        Assert.True(first.Ok, first.Reason);
        Assert.False(replay.Ok);
        Assert.Equal(409, replay.StatusCode);
        Assert.Contains("replay", replay.Reason);
    }

    [Fact]
    public async Task AuthenticateAsync_RejectsAStaleTimestampBeforeReservingTheNonce()
    {
        var h = CreateHarness();
        var body = Encoding.UTF8.GetBytes("{}");

        var outcome = await h.Authenticator.AuthenticateAsync(
            BuildRequest(h.Leaf, body, timestamp: DateTimeOffset.UtcNow.AddHours(-2)),
            CancellationToken.None);

        Assert.False(outcome.Ok);
        Assert.Equal(400, outcome.StatusCode);

        // Unauthenticated traffic must never be able to fill the nonce store.
        Assert.Equal(0, h.Store.Count);
    }

    [Fact]
    public async Task AuthenticateAsync_DoesNotReserveANonceWhenTheSignatureIsInvalid()
    {
        var h = CreateHarness();
        var signedBody = Encoding.UTF8.GetBytes("{\"records\":[{\"a\":1}]}");
        var sentBody = Encoding.UTF8.GetBytes("{\"records\":[{\"a\":2}]}");

        var outcome = await h.Authenticator.AuthenticateAsync(
            BuildRequest(h.Leaf, sentBody, signedBodyOverride: signedBody),
            CancellationToken.None);

        Assert.False(outcome.Ok);
        Assert.Equal(401, outcome.StatusCode);
        Assert.Equal(0, h.Store.Count);
    }

    [Fact]
    public async Task AuthenticateAsync_RejectsARequestWithNoCertificate()
    {
        var h = CreateHarness();
        var body = Encoding.UTF8.GetBytes("{}");

        var request = BuildRequest(h.Leaf, body);
        var withoutCert = new TelemetryRequestContext
        {
            Method = request.Method,
            Path = request.Path,
            Body = request.Body,
            TimestampHeader = request.TimestampHeader,
            NonceHeader = request.NonceHeader,
            SignatureVersionHeader = request.SignatureVersionHeader,
            SignatureAlgorithmHeader = request.SignatureAlgorithmHeader,
            SignatureHeader = request.SignatureHeader,
            ConnectionCertificate = null,
        };

        var outcome = await h.Authenticator.AuthenticateAsync(withoutCert, CancellationToken.None);

        Assert.False(outcome.Ok);
        Assert.Equal(401, outcome.StatusCode);
    }

    [Fact]
    public async Task AuthenticateAsync_RejectsASignatureFromAKeyOtherThanThePresentedCertificate()
    {
        var h = CreateHarness();
        using var attacker = TestCertificates.CreateClientCertificate(h.Ca, "attacker", sanUriDeviceId: OtherDeviceId);

        var body = Encoding.UTF8.GetBytes("{}");

        // Signed by the attacker but presenting the victim's certificate: this is
        // exactly the substitution mTLS alone cannot detect once TLS is terminated
        // at the edge.
        var outcome = await h.Authenticator.AuthenticateAsync(
            BuildRequest(attacker, body, presentedCertificate: TestCertificates.PublicOnly(h.Leaf)),
            CancellationToken.None);

        Assert.False(outcome.Ok);
        Assert.Equal(401, outcome.StatusCode);
    }

    [Fact]
    public void AuthorizeDeviceBinding_AcceptsTheDeviceTheCertificateIsBoundTo()
    {
        var h = CreateHarness();

        var (ok, _, reason, bound) = h.Authenticator.AuthorizeDeviceBinding(
            TestCertificates.PublicOnly(h.Leaf), DeviceId);

        Assert.True(ok, reason);
        Assert.Equal(DeviceId, bound);
    }

    [Fact]
    public void AuthorizeDeviceBinding_RejectsASubmissionForAnotherDevice()
    {
        var h = CreateHarness();

        var (ok, status, reason, _) = h.Authenticator.AuthorizeDeviceBinding(
            TestCertificates.PublicOnly(h.Leaf), OtherDeviceId);

        Assert.False(ok);
        Assert.Equal(403, status);
        Assert.Equal("client certificate is not bound to the submitted device", reason);
    }

    [Fact]
    public void AuthorizeDeviceBinding_RejectsAnUnparseableDeviceId()
    {
        var h = CreateHarness();

        var (ok, status, _, _) = h.Authenticator.AuthorizeDeviceBinding(
            TestCertificates.PublicOnly(h.Leaf), "not-a-guid");

        Assert.False(ok);
        Assert.Equal(403, status);
    }

    [Fact]
    public void AuthorizeDeviceBinding_RejectsACertificateCarryingNoBindingClaim()
    {
        var h = CreateHarness(leafSanDeviceId: null);

        var (ok, status, reason, _) = h.Authenticator.AuthorizeDeviceBinding(
            TestCertificates.PublicOnly(h.Leaf), DeviceId);

        Assert.False(ok);
        Assert.Equal(401, status);
        Assert.Equal("client certificate is missing the configured device-id binding claim", reason);
    }
}
