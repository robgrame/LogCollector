using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Configuration;

namespace LogCollector.Shared.Tests;

/// <summary>Helpers for building throwaway certificates and configuration.</summary>
internal static class TestCertificates
{
    private const string ClientAuthEku = "1.3.6.1.5.5.7.3.2";
    private const string IntuneEnrollmentDeviceIdOid = "1.2.840.113556.5.25";

    public static IConfiguration Config(params (string Key, string Value)[] settings)
        => new ConfigurationBuilder()
            .AddInMemoryCollection(settings.Select(s => new KeyValuePair<string, string?>(s.Key, s.Value)))
            .Build();

    /// <summary>Creates a self-signed CA suitable for use as a custom trust anchor.</summary>
    public static X509Certificate2 CreateRootCa(string commonName, bool includeClientAuthEku = false)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest(
            new X500DistinguishedName($"CN={commonName}"),
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);

        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        request.CertificateExtensions.Add(
            new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        if (includeClientAuthEku)
        {
            request.CertificateExtensions.Add(
                new X509EnhancedKeyUsageExtension([new Oid(ClientAuthEku)], false));
        }

        return request.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddDays(-30),
            DateTimeOffset.UtcNow.AddYears(5));
    }

    /// <summary>Creates a CA certificate issued by another CA.</summary>
    public static X509Certificate2 CreateIntermediateCa(X509Certificate2 issuer, string commonName)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest(
            new X500DistinguishedName($"CN={commonName}"),
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);

        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        request.CertificateExtensions.Add(
            new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));

        var serial = new byte[8];
        RandomNumberGenerator.Fill(serial);

        using var issued = request.Create(
            issuer,
            DateTimeOffset.UtcNow.AddDays(-1),
            DateTimeOffset.UtcNow.AddYears(3),
            serial);

        return issued.CopyWithPrivateKey(rsa);
    }

    /// <summary>
    /// Issues a leaf client certificate. <paramref name="sanUriDeviceId"/> and
    /// <paramref name="intuneDeviceId"/> control which binding strategy can find
    /// a device id.
    /// </summary>
    public static X509Certificate2 CreateClientCertificate(
        X509Certificate2 issuer,
        string subjectCommonName,
        string? sanUriDeviceId = null,
        string? intuneDeviceId = null,
        bool includeClientAuthEku = true,
        DateTimeOffset? notBefore = null,
        DateTimeOffset? notAfter = null)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest(
            new X500DistinguishedName($"CN={subjectCommonName}"),
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);

        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(
            new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));

        if (includeClientAuthEku)
        {
            request.CertificateExtensions.Add(
                new X509EnhancedKeyUsageExtension([new Oid(ClientAuthEku)], false));
        }

        if (sanUriDeviceId is not null)
        {
            var san = new SubjectAlternativeNameBuilder();
            san.AddUri(new Uri($"urn:uuid:{sanUriDeviceId}"));
            request.CertificateExtensions.Add(san.Build());
        }

        if (intuneDeviceId is not null)
        {
            // DER OCTET STRING (0x04) of length 16 (0x10) wrapping the raw GUID bytes.
            var guidBytes = Guid.Parse(intuneDeviceId).ToByteArray();
            var raw = new byte[18];
            raw[0] = 0x04;
            raw[1] = 0x10;
            Array.Copy(guidBytes, 0, raw, 2, 16);
            request.CertificateExtensions.Add(
                new X509Extension(new Oid(IntuneEnrollmentDeviceIdOid), raw, false));
        }

        var serial = new byte[8];
        RandomNumberGenerator.Fill(serial);

        using var issued = request.Create(
            issuer,
            notBefore ?? DateTimeOffset.UtcNow.AddHours(-1),
            notAfter ?? DateTimeOffset.UtcNow.AddYears(1),
            serial);

        // Reattach the private key: Create() returns a public-only certificate.
        return issued.CopyWithPrivateKey(rsa);
    }

    public static string ToBase64(X509Certificate2 certificate)
        => Convert.ToBase64String(certificate.Export(X509ContentType.Cert));

    /// <summary>Strips the private key, mirroring what arrives over the wire.</summary>
    public static X509Certificate2 PublicOnly(X509Certificate2 certificate)
        => X509CertificateLoader.LoadCertificate(certificate.Export(X509ContentType.Cert));
}
