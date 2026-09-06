using System.Globalization;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Microsoft.Extensions.Configuration;

namespace LogCollector.Shared.Security;

/// <summary>
/// Verifies the application-level signature attached to a telemetry submission.
///
/// The signature proves that the holder of the mTLS certificate's private key
/// authorised this exact (method, path, timestamp, nonce, body) tuple. TLS alone
/// only proves possession at connection time; App Service terminates TLS and
/// forwards the certificate as a header, so without this second, end-to-end
/// binding a compromised intermediary could swap the body under a legitimate
/// certificate.
/// </summary>
public sealed class RequestSignatureVerifier
{
    public sealed record VerificationResult(bool Ok, bool Signed, string? Algorithm, string? Reason);

    public const string ProtocolVersion = "IDA-SIGNATURE-V1";
    public const string SignatureHeader = "X-Request-Signature";
    public const string AlgorithmHeader = "X-Request-Signature-Algorithm";
    public const string VersionHeader = "X-Request-Signature-Version";
    public const string TimestampHeader = "X-Request-Timestamp";
    public const string NonceHeader = "X-Request-Nonce";
    public const string RsaAlgorithm = "RSA-PKCS1-SHA256";
    public const string EcdsaAlgorithm = "ECDSA-SHA256";

    private const int MaxSignatureChars = 16_384;

    public RequestSignatureVerifier(IConfiguration cfg)
    {
        // Fail closed: signature enforcement is on unless explicitly disabled.
        Required = !bool.TryParse(cfg["RequestSignature:Required"], out var required) || required;
        MaxBodyBytes = int.TryParse(cfg["RequestSignature:MaxBodyBytes"], out var maxBodyBytes)
            ? Math.Clamp(maxBodyBytes, 1_024, 16 * 1024 * 1024)
            : 4 * 1024 * 1024;
    }

    public bool Required { get; }

    public int MaxBodyBytes { get; }

    public VerificationResult Verify(
        X509Certificate2 certificate,
        string method,
        string path,
        DateTimeOffset timestamp,
        Guid nonce,
        ReadOnlySpan<byte> body,
        string? version,
        string? algorithm,
        string? signatureBase64)
    {
        ArgumentNullException.ThrowIfNull(certificate);

        var signatureMissing = string.IsNullOrWhiteSpace(version)
            && string.IsNullOrWhiteSpace(algorithm)
            && string.IsNullOrWhiteSpace(signatureBase64);

        if (signatureMissing && !Required)
            return new VerificationResult(true, false, null, null);

        if (string.IsNullOrWhiteSpace(version))
            return Denied($"missing {VersionHeader} header");
        if (!string.Equals(version.Trim(), ProtocolVersion, StringComparison.Ordinal))
            return Denied($"unsupported request signature version '{version.Trim()}'");
        if (string.IsNullOrWhiteSpace(algorithm))
            return Denied($"missing {AlgorithmHeader} header");
        if (string.IsNullOrWhiteSpace(signatureBase64))
            return Denied($"missing {SignatureHeader} header");
        if (signatureBase64.Length > MaxSignatureChars)
            return Denied("request signature is too large");

        byte[] signature;
        try
        {
            signature = Convert.FromBase64String(signatureBase64.Trim());
        }
        catch (FormatException)
        {
            return Denied("request signature is not valid Base64");
        }

        var canonicalBytes = Encoding.UTF8.GetBytes(
            BuildCanonicalRequest(method, path, timestamp, nonce, body));

        try
        {
            switch (algorithm.Trim())
            {
                case RsaAlgorithm:
                    using (var rsa = certificate.GetRSAPublicKey())
                    {
                        if (rsa is null)
                            return Denied("request signature algorithm does not match certificate key type");
                        return rsa.VerifyData(canonicalBytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
                            ? Accepted(RsaAlgorithm)
                            : Denied("request signature verification failed");
                    }

                case EcdsaAlgorithm:
                    using (var ecdsa = certificate.GetECDsaPublicKey())
                    {
                        if (ecdsa is null)
                            return Denied("request signature algorithm does not match certificate key type");
                        return ecdsa.VerifyData(canonicalBytes, signature, HashAlgorithmName.SHA256)
                            ? Accepted(EcdsaAlgorithm)
                            : Denied("request signature verification failed");
                    }

                default:
                    return Denied($"unsupported request signature algorithm '{algorithm.Trim()}'");
            }
        }
        catch (CryptographicException)
        {
            return Denied("request signature verification failed");
        }
    }

    /// <summary>
    /// Builds the canonical string that both the PowerShell client and this
    /// verifier hash. Any change here is a breaking protocol change and must be
    /// accompanied by a new <see cref="ProtocolVersion"/>.
    /// </summary>
    public static string BuildCanonicalRequest(
        string method,
        string path,
        DateTimeOffset timestamp,
        Guid nonce,
        ReadOnlySpan<byte> body)
    {
        var bodyHash = Convert.ToBase64String(SHA256.HashData(body));
        return string.Join('\n',
            ProtocolVersion,
            method.Trim().ToUpperInvariant(),
            NormalizePath(path),
            timestamp.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            nonce.ToString("D").ToLowerInvariant(),
            bodyHash);
    }

    private static string NormalizePath(string path)
    {
        var trimmed = path.Trim();
        if (trimmed.Length == 0) return "/";
        return trimmed[0] == '/' ? trimmed : $"/{trimmed}";
    }

    private static VerificationResult Accepted(string algorithm) => new(true, true, algorithm, null);

    private static VerificationResult Denied(string reason) => new(false, false, null, reason);
}
