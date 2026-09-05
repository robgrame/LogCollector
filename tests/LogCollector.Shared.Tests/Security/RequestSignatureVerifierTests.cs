using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LogCollector.Shared.Security;
using Xunit;

namespace LogCollector.Shared.Tests.Security;

public sealed class RequestSignatureVerifierTests
{
    private static readonly Guid Nonce = Guid.Parse("11111111-2222-3333-4444-555555555555");
    private static readonly DateTimeOffset Timestamp =
        new(2026, 1, 2, 3, 4, 5, 678, TimeSpan.Zero);

    [Fact]
    public void BuildCanonicalRequest_ProducesTheDocumentedSixLineForm()
    {
        var body = Encoding.UTF8.GetBytes("{\"a\":1}");

        var canonical = RequestSignatureVerifier.BuildCanonicalRequest(
            "post", "api/inventory", Timestamp, Nonce, body);

        var lines = canonical.Split('\n');

        Assert.Equal(6, lines.Length);
        Assert.Equal("IDA-SIGNATURE-V1", lines[0]);
        Assert.Equal("POST", lines[1]);
        Assert.Equal("/api/inventory", lines[2]);
        Assert.Equal("2026-01-02T03:04:05.6780000+00:00", lines[3]);
        Assert.Equal("11111111-2222-3333-4444-555555555555", lines[4]);
        Assert.Equal(Convert.ToBase64String(SHA256.HashData(body)), lines[5]);
    }

    [Fact]
    public void BuildCanonicalRequest_NormalizesEmptyPathToRoot()
    {
        var canonical = RequestSignatureVerifier.BuildCanonicalRequest(
            "POST", "   ", Timestamp, Nonce, []);

        Assert.Equal("/", canonical.Split('\n')[2]);
    }

    [Fact]
    public void BuildCanonicalRequest_IsTimestampSensitive()
    {
        var a = RequestSignatureVerifier.BuildCanonicalRequest("POST", "/x", Timestamp, Nonce, []);
        var b = RequestSignatureVerifier.BuildCanonicalRequest("POST", "/x", Timestamp.AddSeconds(1), Nonce, []);

        Assert.NotEqual(a, b);
    }

    [Fact]
    public void Verify_AcceptsASignatureMadeWithTheCertificatePrivateKey()
    {
        using var ca = TestCertificates.CreateRootCa("LogCollector Test Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device");

        var body = Encoding.UTF8.GetBytes("{\"records\":[]}");
        var signature = Sign(leaf, "POST", "/api/inventory", Timestamp, Nonce, body);

        var verifier = new RequestSignatureVerifier(TestCertificates.Config());

        var result = verifier.Verify(
            TestCertificates.PublicOnly(leaf), "POST", "/api/inventory", Timestamp, Nonce, body,
            RequestSignatureVerifier.ProtocolVersion, RequestSignatureVerifier.RsaAlgorithm, signature);

        Assert.True(result.Ok);
        Assert.True(result.Signed);
        Assert.Equal(RequestSignatureVerifier.RsaAlgorithm, result.Algorithm);
    }

    [Fact]
    public void Verify_RejectsATamperedBody()
    {
        using var ca = TestCertificates.CreateRootCa("LogCollector Test Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device");

        var body = Encoding.UTF8.GetBytes("{\"records\":[{\"a\":1}]}");
        var signature = Sign(leaf, "POST", "/api/inventory", Timestamp, Nonce, body);

        var tampered = Encoding.UTF8.GetBytes("{\"records\":[{\"a\":2}]}");
        var verifier = new RequestSignatureVerifier(TestCertificates.Config());

        var result = verifier.Verify(
            TestCertificates.PublicOnly(leaf), "POST", "/api/inventory", Timestamp, Nonce, tampered,
            RequestSignatureVerifier.ProtocolVersion, RequestSignatureVerifier.RsaAlgorithm, signature);

        Assert.False(result.Ok);
        Assert.Equal("request signature verification failed", result.Reason);
    }

    [Fact]
    public void Verify_RejectsASignatureReplayedOntoADifferentNonce()
    {
        using var ca = TestCertificates.CreateRootCa("LogCollector Test Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device");

        var body = Encoding.UTF8.GetBytes("{}");
        var signature = Sign(leaf, "POST", "/api/inventory", Timestamp, Nonce, body);

        var verifier = new RequestSignatureVerifier(TestCertificates.Config());

        var result = verifier.Verify(
            TestCertificates.PublicOnly(leaf), "POST", "/api/inventory", Timestamp, Guid.NewGuid(), body,
            RequestSignatureVerifier.ProtocolVersion, RequestSignatureVerifier.RsaAlgorithm, signature);

        Assert.False(result.Ok);
    }

    [Fact]
    public void Verify_RejectsASignatureMadeByADifferentCertificate()
    {
        using var ca = TestCertificates.CreateRootCa("LogCollector Test Root");
        using var attacker = TestCertificates.CreateClientCertificate(ca, "attacker");
        using var victim = TestCertificates.CreateClientCertificate(ca, "victim");

        var body = Encoding.UTF8.GetBytes("{}");
        var signature = Sign(attacker, "POST", "/api/inventory", Timestamp, Nonce, body);

        var verifier = new RequestSignatureVerifier(TestCertificates.Config());

        var result = verifier.Verify(
            TestCertificates.PublicOnly(victim), "POST", "/api/inventory", Timestamp, Nonce, body,
            RequestSignatureVerifier.ProtocolVersion, RequestSignatureVerifier.RsaAlgorithm, signature);

        Assert.False(result.Ok);
    }

    [Theory]
    [InlineData(null, RequestSignatureVerifier.RsaAlgorithm, "sig", "missing X-Request-Signature-Version header")]
    [InlineData("IDA-SIGNATURE-V0", RequestSignatureVerifier.RsaAlgorithm, "sig", "unsupported request signature version 'IDA-SIGNATURE-V0'")]
    [InlineData(RequestSignatureVerifier.ProtocolVersion, null, "sig", "missing X-Request-Signature-Algorithm header")]
    [InlineData(RequestSignatureVerifier.ProtocolVersion, RequestSignatureVerifier.RsaAlgorithm, null, "missing X-Request-Signature header")]
    [InlineData(RequestSignatureVerifier.ProtocolVersion, RequestSignatureVerifier.RsaAlgorithm, "not base64!!", "request signature is not valid Base64")]
    [InlineData(RequestSignatureVerifier.ProtocolVersion, "HMAC-SHA256", "AAAA", "unsupported request signature algorithm 'HMAC-SHA256'")]
    public void Verify_RejectsMalformedSignatureHeaders(string? version, string? algorithm, string? signature, string expectedReason)
    {
        using var ca = TestCertificates.CreateRootCa("LogCollector Test Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device");

        var verifier = new RequestSignatureVerifier(TestCertificates.Config());

        var result = verifier.Verify(
            TestCertificates.PublicOnly(leaf), "POST", "/api/inventory", Timestamp, Nonce, [],
            version, algorithm, signature);

        Assert.False(result.Ok);
        Assert.Equal(expectedReason, result.Reason);
    }

    [Fact]
    public void Verify_FailsClosedWhenAllSignatureHeadersAreAbsentAndSigningIsRequired()
    {
        using var ca = TestCertificates.CreateRootCa("LogCollector Test Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device");

        var verifier = new RequestSignatureVerifier(TestCertificates.Config());
        Assert.True(verifier.Required);

        var result = verifier.Verify(
            TestCertificates.PublicOnly(leaf), "POST", "/api/inventory", Timestamp, Nonce, [],
            null, null, null);

        Assert.False(result.Ok);
    }

    [Fact]
    public void Verify_AllowsUnsignedRequestsOnlyWhenExplicitlyDisabled()
    {
        using var ca = TestCertificates.CreateRootCa("LogCollector Test Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device");

        var verifier = new RequestSignatureVerifier(
            TestCertificates.Config(("RequestSignature:Required", "false")));

        var result = verifier.Verify(
            TestCertificates.PublicOnly(leaf), "POST", "/api/inventory", Timestamp, Nonce, [],
            null, null, null);

        Assert.True(result.Ok);
        Assert.False(result.Signed);
    }

    [Fact]
    public void MaxBodyBytes_IsClampedToASaneRange()
    {
        Assert.Equal(1024, new RequestSignatureVerifier(
            TestCertificates.Config(("RequestSignature:MaxBodyBytes", "1"))).MaxBodyBytes);

        Assert.Equal(16 * 1024 * 1024, new RequestSignatureVerifier(
            TestCertificates.Config(("RequestSignature:MaxBodyBytes", "999999999"))).MaxBodyBytes);
    }

    private static string Sign(
        X509Certificate2 certificate,
        string method,
        string path,
        DateTimeOffset timestamp,
        Guid nonce,
        byte[] body)
    {
        var canonical = Encoding.UTF8.GetBytes(
            RequestSignatureVerifier.BuildCanonicalRequest(method, path, timestamp, nonce, body));

        using var rsa = certificate.GetRSAPrivateKey()!;
        return Convert.ToBase64String(
            rsa.SignData(canonical, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
    }
}
