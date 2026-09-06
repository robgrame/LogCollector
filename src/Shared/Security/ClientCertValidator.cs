using System.Formats.Asn1;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LogCollector.Shared.Security;

/// <summary>
/// Validates the mTLS client certificate presented to the frontend and extracts
/// the Entra device id the certificate is <i>bound</i> to.
///
/// Two independent trust tiers are supported:
/// <list type="number">
///   <item><b>Enterprise PKI</b> — chains to operator-supplied root anchors
///   (<c>ClientCert:TrustedRootCertificates</c>), optionally pinned further by CA
///   thumbprint or subject.</item>
///   <item><b>Intune enrollment</b> — chains to explicitly configured Intune MDM
///   device CA anchors and carries the Entra device id in OID
///   <c>1.2.840.113556.5.25</c>.</item>
/// </list>
/// The Intune tier is only consulted when the enterprise tier rejects the chain,
/// is explicitly enabled, has anchors configured, <b>and</b> the issuer is
/// allow-listed. Identity binding comes from a CA-asserted value in a verified chain.
/// An explicit Intune-only CRL/OCSP exception does not affect enterprise PKI;
/// the caller must still enforce tenant device authorization for the Intune tier.
/// </summary>
public sealed class ClientCertValidator
{
    private const string ClientAuthEku = "1.3.6.1.5.5.7.3.2";
    private const string IntuneEnrollmentDeviceIdOid = "1.2.840.113556.5.25";

    private static readonly string[] DefaultIntuneEnrollmentIssuerSubjects =
    [
        "CN=Microsoft Intune MDM Device CA",
        "CN=Microsoft Intune Device Management Device CA",
    ];

    public enum DeviceIdBinding
    {
        Disabled,
        SubjectCN,
        SanDns,
        SanUri,
        Thumbprint,
        IntuneEnrollmentOid,
        Auto,
    }

    /// <summary>Which trust tier accepted the certificate.</summary>
    public enum TrustTier
    {
        None,
        EnterprisePki,
        IntuneEnrollment,
    }

    public sealed record CertificateValidationResult(
        bool Ok,
        X509Certificate2? Certificate,
        TrustTier Tier,
        string? Reason);

    private readonly HashSet<string> _trustedCaThumbprints;
    private readonly HashSet<string> _trustedCaSubjects;
    private readonly HashSet<string> _pkiRootCaThumbprints;
    private readonly HashSet<string> _pkiRootCaSubjects;
    private readonly HashSet<string> _pkiIntermediateCaThumbprints;
    private readonly HashSet<string> _pkiIntermediateCaSubjects;
    private readonly HashSet<string> _allowedLeafThumbprints;
    private readonly List<X509Certificate2> _rootStore = [];
    private readonly List<X509Certificate2> _intermediateStore = [];
    private readonly List<X509Certificate2> _intuneRootStore = [];
    private readonly List<X509Certificate2> _intuneIntermediateStore = [];
    private readonly Dictionary<string, string> _thumbprintToDeviceMap;
    private readonly HashSet<string> _intuneEnrollmentIssuerSubjects;
    private readonly bool _checkRevocation;
    private readonly bool _skipIntuneRevocationCheck;
    private readonly X509RevocationMode _revocationMode;
    private readonly X509RevocationFlag _revocationFlag;
    private readonly bool _requireClientAuthEku;
    private readonly bool _required;
    private readonly bool _requireDeviceBinding;
    private readonly bool _trustForwardedHeader;
    private readonly bool _allowIntuneEnrollmentCertificateFallback;
    private readonly DeviceIdBinding _deviceBinding;
    private readonly ILogger<ClientCertValidator> _log;

    public ClientCertValidator(IConfiguration cfg, ILogger<ClientCertValidator> log)
    {
        _log = log;

        _trustedCaThumbprints = ParseList(cfg["ClientCert:TrustedCaThumbprints"])
            .Select(NormalizeThumbprint)
            .Where(t => t.Length > 0)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        _trustedCaSubjects = ParseList(cfg["ClientCert:TrustedCaSubjects"], '|')
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        _pkiRootCaThumbprints = ParseStrictThumbprintList(
            cfg["ClientCert:PkiRootCaThumbprints"],
            "ClientCert:PkiRootCaThumbprints");
        _pkiRootCaSubjects = ParseStrictSubjectList(
            cfg["ClientCert:PkiRootCaSubjects"],
            "ClientCert:PkiRootCaSubjects");
        _pkiIntermediateCaThumbprints = ParseStrictThumbprintList(
            cfg["ClientCert:PkiIntermediateCaThumbprints"],
            "ClientCert:PkiIntermediateCaThumbprints");
        _pkiIntermediateCaSubjects = ParseStrictSubjectList(
            cfg["ClientCert:PkiIntermediateCaSubjects"],
            "ClientCert:PkiIntermediateCaSubjects");

        _allowedLeafThumbprints = ParseList(cfg["ClientCert:AllowedLeafThumbprints"])
            .Select(NormalizeThumbprint)
            .Where(t => t.Length > 0)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        LoadCerts(cfg["ClientCert:TrustedRootCertificates"], _rootStore, "root");
        LoadCerts(cfg["ClientCert:TrustedIntermediateCertificates"], _intermediateStore, "intermediate");
        LoadCerts(cfg["ClientCert:TrustedIntuneRootCertificates"], _intuneRootStore, "Intune root");
        LoadCerts(cfg["ClientCert:TrustedIntuneIntermediateCertificates"], _intuneIntermediateStore, "Intune intermediate");

        _checkRevocation = bool.TryParse(cfg["ClientCert:CheckRevocation"], out var cr) && cr;
        _skipIntuneRevocationCheck =
            bool.TryParse(cfg["ClientCert:SkipIntuneRevocationCheck"], out var skipIntune) && skipIntune;
        if (_skipIntuneRevocationCheck)
            _log.LogWarning("Intune certificate CRL/OCSP checks are disabled explicitly; tenant device authorization through Graph remains required.");
        _revocationMode = Enum.TryParse<X509RevocationMode>(cfg["ClientCert:RevocationMode"], true, out var rm)
            ? rm
            : (_checkRevocation ? X509RevocationMode.Online : X509RevocationMode.NoCheck);
        _revocationFlag = Enum.TryParse<X509RevocationFlag>(cfg["ClientCert:RevocationFlag"], true, out var rf)
            ? rf
            : X509RevocationFlag.ExcludeRoot;

        _requireClientAuthEku = !bool.TryParse(cfg["ClientCert:RequireClientAuthEku"], out var eku) || eku;
        _required = !bool.TryParse(cfg["ClientCert:RequireClientCert"], out var r) || r;
        _requireDeviceBinding = !bool.TryParse(cfg["ClientCert:RequireDeviceBinding"], out var rdb) || rdb;

        // App Service terminates TLS and re-presents the certificate in
        // X-ARR-ClientCert. The platform strips any client-supplied instance of
        // that header when clientCertEnabled is set, which is what makes trusting
        // it safe — and why it defaults to true here.
        _trustForwardedHeader = !bool.TryParse(cfg["ClientCert:TrustForwardedHeader"], out var th) || th;

        _allowIntuneEnrollmentCertificateFallback =
            !bool.TryParse(cfg["ClientCert:AllowIntuneEnrollmentCertificateFallback"], out var aief) || aief;

        _intuneEnrollmentIssuerSubjects = ParseList(
                cfg["ClientCert:IntuneEnrollmentIssuerSubjects"]
                    ?? string.Join('|', DefaultIntuneEnrollmentIssuerSubjects),
                '|')
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        _deviceBinding = Enum.TryParse<DeviceIdBinding>(cfg["ClientCert:DeviceIdBindingClaim"], true, out var db)
            ? db
            : DeviceIdBinding.Auto;

        // Operator-maintained escape hatch for PKI templates that do not embed the
        // device id: "THUMB1=guid1|THUMB2=guid2".
        _thumbprintToDeviceMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in ParseList(cfg["ClientCert:ThumbprintToDeviceMap"]))
        {
            var eq = pair.IndexOf('=');
            if (eq <= 0 || eq == pair.Length - 1) continue;

            var thumb = NormalizeThumbprint(pair[..eq]);
            var devId = pair[(eq + 1)..].Trim();
            if (thumb.Length == 0 || !Guid.TryParse(devId, out var g))
            {
                _log.LogWarning("ThumbprintToDeviceMap entry skipped (not a GUID) for thumbprint {Thumb}.", thumb);
                continue;
            }

            // Fail closed on a conflicting duplicate: silently rebinding a
            // certificate to a different device would be a privileged misconfiguration.
            if (_thumbprintToDeviceMap.TryGetValue(thumb, out var existing)
                && !string.Equals(existing, g.ToString(), StringComparison.OrdinalIgnoreCase))
            {
                _log.LogError("ThumbprintToDeviceMap CONFLICT for {Thumb}; duplicate mapping ignored.", thumb);
                continue;
            }

            _thumbprintToDeviceMap[thumb] = g.ToString();
        }
    }

    public bool BindingEnabled => _deviceBinding != DeviceIdBinding.Disabled;

    public bool RequireDeviceBinding => _requireDeviceBinding;

    public bool RequireClientCertificate => _required;

    /// <summary>
    /// Validates the certificate supplied by the connection or (on App Service)
    /// forwarded in <c>X-ARR-ClientCert</c>.
    /// </summary>
    public CertificateValidationResult Validate(X509Certificate2? connectionCertificate, string? forwardedCertificateHeader)
        => Validate(connectionCertificate, forwardedCertificateHeader, DateTime.UtcNow);

    /// <summary>Validation with an injectable clock (used by tests).</summary>
    public CertificateValidationResult Validate(
        X509Certificate2? connectionCertificate,
        string? forwardedCertificateHeader,
        DateTime utcNow)
    {
        if (_requireDeviceBinding && _deviceBinding == DeviceIdBinding.Disabled)
        {
            _log.LogError("ClientCertValidator misconfigured: binding Disabled while RequireDeviceBinding is on. Failing closed.");
            return Fail("client certificate device binding is required");
        }

        var hasEnterpriseAnchor = _trustedCaThumbprints.Count > 0
            || _trustedCaSubjects.Count > 0
            || _rootStore.Count > 0;
        var hasIntuneAnchor = _allowIntuneEnrollmentCertificateFallback && _intuneRootStore.Count > 0;

        if (!hasEnterpriseAnchor && !hasIntuneAnchor)
        {
            _log.LogError("ClientCertValidator misconfigured: no trust anchor configured. Failing closed.");
            return Fail("client certificate trust anchor not configured");
        }

        var cert = connectionCertificate;
        if (cert is null && _trustForwardedHeader && !string.IsNullOrWhiteSpace(forwardedCertificateHeader))
        {
            cert = TryLoadCert(forwardedCertificateHeader, "forwarded X-ARR-ClientCert");
        }

        if (cert is null)
        {
            return _required
                ? Fail("client certificate missing")
                : new CertificateValidationResult(true, null, TrustTier.None, null);
        }

        if (utcNow < cert.NotBefore.ToUniversalTime() || utcNow > cert.NotAfter.ToUniversalTime())
            return new CertificateValidationResult(false, cert, TrustTier.None, "certificate expired or not yet valid");

        if (_requireClientAuthEku && !HasClientAuthEku(cert))
            return new CertificateValidationResult(false, cert, TrustTier.None,
                $"certificate missing Client Authentication EKU ({ClientAuthEku})");

        if (_allowedLeafThumbprints.Count > 0
            && !_allowedLeafThumbprints.Contains(NormalizeThumbprint(cert.Thumbprint ?? string.Empty)))
        {
            return new CertificateValidationResult(false, cert, TrustTier.None, "leaf certificate thumbprint not in allow-list");
        }

        var enterprise = ValidateEnterpriseTrust(cert, utcNow);
        if (enterprise.Ok)
            return new CertificateValidationResult(true, cert, TrustTier.EnterprisePki, null);

        if (CanUseIntuneEnrollmentFallback(cert))
        {
            var intune = ValidateIntuneTrust(cert, utcNow);
            if (intune.Ok)
            {
                _log.LogInformation(
                    "Accepted Intune enrollment certificate (issuer={Issuer}, thumb={Thumb}).",
                    cert.Issuer, cert.Thumbprint);
                return new CertificateValidationResult(true, cert, TrustTier.IntuneEnrollment, null);
            }

            return new CertificateValidationResult(false, cert, TrustTier.None,
                $"Intune enrollment certificate trust failed ({intune.Reason})");
        }

        return new CertificateValidationResult(false, cert, TrustTier.None, enterprise.Reason);
    }

    /// <summary>
    /// Extracts the device identifier the certificate is bound to. Returns
    /// <see langword="null"/> when binding is disabled or the claim is absent.
    /// </summary>
    public string? GetBoundDeviceId(X509Certificate2 cert)
    {
        ArgumentNullException.ThrowIfNull(cert);

        return _deviceBinding switch
        {
            DeviceIdBinding.Disabled => null,
            DeviceIdBinding.SubjectCN => ExtractFromSubject(cert),
            DeviceIdBinding.SanDns => FirstSanValue(cert, X509NameType.DnsName),
            DeviceIdBinding.SanUri => FirstSanValue(cert, X509NameType.UrlName),
            DeviceIdBinding.Thumbprint => LookupByThumbprint(cert),
            DeviceIdBinding.IntuneEnrollmentOid => ExtractIntuneEnrollmentDeviceId(cert),

            // Auto: the operator map wins (explicit intent). For an explicitly
            // trusted Intune enrollment certificate the .5.25 OID is authoritative
            // and must precede the Subject CN, because Intune puts a *different*
            // GUID in the CN that is not the Entra device id.
            DeviceIdBinding.Auto => LookupByThumbprint(cert)
                ?? (CanUseIntuneEnrollmentFallback(cert) ? ExtractIntuneEnrollmentDeviceId(cert) : null)
                ?? FirstSanValue(cert, X509NameType.UrlName)
                ?? FirstSanValue(cert, X509NameType.DnsName)
                ?? ExtractFromSubject(cert),

            _ => null,
        };
    }

    private (bool Ok, string? Reason) ValidateEnterpriseTrust(X509Certificate2 cert, DateTime now)
    {
        if (_trustedCaThumbprints.Count == 0 && _trustedCaSubjects.Count == 0 && _rootStore.Count == 0)
            return (false, "enterprise PKI trust anchor not configured");

        using var chain = CreateChain(now);
        if (_rootStore.Count > 0)
        {
            chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            chain.ChainPolicy.CustomTrustStore.AddRange(_rootStore.ToArray());
            chain.ChainPolicy.ExtraStore.AddRange(_rootStore.ToArray());
        }
        if (_intermediateStore.Count > 0)
            chain.ChainPolicy.ExtraStore.AddRange(_intermediateStore.ToArray());

        if (!chain.Build(cert))
            return (false, FormatChainFailure(chain));

        var rolePolicy = ValidateEnterpriseCaRolePolicy(chain);
        if (!rolePolicy.Ok)
            return rolePolicy;

        if (_trustedCaThumbprints.Count > 0)
        {
            var chainThumbs = chain.ChainElements
                .Skip(1)
                .Select(e => NormalizeThumbprint(e.Certificate.Thumbprint ?? string.Empty))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            if (!_trustedCaThumbprints.Overlaps(chainThumbs))
                return (false, "no trusted CA thumbprint found in the certificate chain");
        }

        if (_trustedCaSubjects.Count > 0)
        {
            var chainSubjects = chain.ChainElements
                .Skip(1)
                .Select(e => e.Certificate.Subject ?? string.Empty)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            if (!_trustedCaSubjects.Overlaps(chainSubjects))
                return (false, "no trusted CA subject found in the certificate chain");
        }

        return (true, null);
    }

    private (bool Ok, string? Reason) ValidateEnterpriseCaRolePolicy(X509Chain chain)
    {
        var elements = chain.ChainElements;
        if (elements.Count == 0)
            return (false, "certificate chain contains no elements");

        if (_pkiRootCaThumbprints.Count > 0 || _pkiRootCaSubjects.Count > 0)
        {
            if (elements.Count < 2
                || !MatchesCaRole(
                    elements[^1].Certificate,
                    _pkiRootCaThumbprints,
                    _pkiRootCaSubjects))
            {
                return (false, "certificate chain root CA does not satisfy configured PKI root policy");
            }
        }

        if (_pkiIntermediateCaThumbprints.Count > 0 || _pkiIntermediateCaSubjects.Count > 0)
        {
            var permittedIntermediateFound = elements
                .Cast<X509ChainElement>()
                .Skip(1)
                .Take(Math.Max(0, elements.Count - 2))
                .Any(element => MatchesCaRole(
                    element.Certificate,
                    _pkiIntermediateCaThumbprints,
                    _pkiIntermediateCaSubjects));

            if (!permittedIntermediateFound)
            {
                return (false,
                    "certificate chain intermediate CA does not satisfy configured PKI intermediate policy");
            }
        }

        return (true, null);
    }

    private static bool MatchesCaRole(
        X509Certificate2 certificate,
        HashSet<string> permittedThumbprints,
        HashSet<string> permittedSubjects)
    {
        var isCa = certificate.Extensions
            .OfType<X509BasicConstraintsExtension>()
            .Any(extension => extension.CertificateAuthority);
        if (!isCa)
            return false;

        return (permittedThumbprints.Count == 0
                || permittedThumbprints.Contains(NormalizeThumbprint(certificate.Thumbprint ?? string.Empty)))
            && (permittedSubjects.Count == 0
                || permittedSubjects.Contains(certificate.Subject ?? string.Empty));
    }

    private (bool Ok, string? Reason) ValidateIntuneTrust(X509Certificate2 cert, DateTime now)
    {
        using var chain = CreateChain(now);
        // Some Intune CA chains publish no CRL/OCSP endpoints. Never apply this exception to enterprise PKI.
        if (_skipIntuneRevocationCheck)
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.AddRange(_intuneRootStore.ToArray());
        chain.ChainPolicy.ExtraStore.AddRange(_intuneRootStore.ToArray());
        if (_intuneIntermediateStore.Count > 0)
            chain.ChainPolicy.ExtraStore.AddRange(_intuneIntermediateStore.ToArray());

        return chain.Build(cert) ? (true, null) : (false, FormatChainFailure(chain));
    }

    private bool CanUseIntuneEnrollmentFallback(X509Certificate2 cert)
    {
        if (!_allowIntuneEnrollmentCertificateFallback
            || _intuneRootStore.Count == 0
            || (_deviceBinding != DeviceIdBinding.Auto && _deviceBinding != DeviceIdBinding.IntuneEnrollmentOid))
        {
            return false;
        }

        if (ExtractIntuneEnrollmentDeviceId(cert) is null)
            return false;

        if (!_intuneEnrollmentIssuerSubjects.Contains(cert.Issuer))
        {
            _log.LogWarning(
                "Certificate carries the Intune enrollment OID but issuer '{Issuer}' is not allow-listed.",
                cert.Issuer);
            return false;
        }

        return true;
    }

    private X509Chain CreateChain(DateTime now)
    {
        var chain = new X509Chain();
        chain.ChainPolicy.RevocationMode = _checkRevocation ? _revocationMode : X509RevocationMode.NoCheck;
        chain.ChainPolicy.RevocationFlag = _revocationFlag;
        chain.ChainPolicy.VerificationTime = now;
        chain.ChainPolicy.UrlRetrievalTimeout = TimeSpan.FromSeconds(15);
        return chain;
    }

    private string? LookupByThumbprint(X509Certificate2 cert)
    {
        var thumb = NormalizeThumbprint(cert.Thumbprint ?? string.Empty);
        return thumb.Length > 0 && _thumbprintToDeviceMap.TryGetValue(thumb, out var devId) ? devId : null;
    }

    private void LoadCerts(string? csv, List<X509Certificate2> target, string label)
    {
        if (string.IsNullOrWhiteSpace(csv)) return;

        foreach (var b64 in ParseList(csv))
        {
            var ca = TryLoadCert(b64, label);
            if (ca is null) continue;

            if (label.EndsWith("root", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(ca.Subject, ca.Issuer, StringComparison.OrdinalIgnoreCase))
            {
                _log.LogWarning(
                    "Certificate configured as a {Label} anchor is NOT self-signed (Subject='{Subject}', Issuer='{Issuer}').",
                    label, ca.Subject, ca.Issuer);
            }

            target.Add(ca);
            _log.LogInformation("Loaded {Label} CA: {Subject} (thumb={Thumb})", label, ca.Subject, ca.Thumbprint);
        }
    }

    private X509Certificate2? TryLoadCert(string b64, string label)
    {
        try
        {
            return X509CertificateLoader.LoadCertificate(Convert.FromBase64String(StripPem(b64)));
        }
        catch (Exception ex) when (ex is FormatException or System.Security.Cryptography.CryptographicException)
        {
            _log.LogError(ex, "Failed to load {Label} certificate (skipped).", label);
            return null;
        }
    }

    private static bool HasClientAuthEku(X509Certificate2 cert)
    {
        foreach (var ext in cert.Extensions.OfType<X509EnhancedKeyUsageExtension>())
        {
            foreach (var oid in ext.EnhancedKeyUsages)
            {
                if (oid.Value == ClientAuthEku) return true;
            }
        }
        return false;
    }

    // STRICT: the CN must EQUAL a GUID. Scanning the whole DN or accepting
    // GUID-shaped substrings would let a permissive certificate template bind an
    // attacker to a victim's device id.
    private static string? ExtractFromSubject(X509Certificate2 cert)
        => ExactGuid(cert.GetNameInfo(X509NameType.SimpleName, false));

    private static string? FirstSanValue(X509Certificate2 cert, X509NameType nameType)
    {
        var raw = cert.GetNameInfo(nameType, false);
        if (nameType == X509NameType.UrlName) raw = StripUrnUuidPrefix(raw);
        return ExactGuid(raw);
    }

    internal static string? ExtractIntuneEnrollmentDeviceId(X509Certificate2 cert)
    {
        var extensions = cert.Extensions
            .Where(e => e.Oid?.Value == IntuneEnrollmentDeviceIdOid)
            .ToList();

        // Exactly one: duplicated extensions are ambiguous, so fail closed.
        if (extensions.Count != 1) return null;

        try
        {
            var reader = new AsnReader(extensions[0].RawData, AsnEncodingRules.DER);
            var bytes = reader.ReadOctetString();
            reader.ThrowIfNotEmpty();
            return bytes.Length == 16 ? new Guid(bytes).ToString() : null;
        }
        catch (AsnContentException)
        {
            return null;
        }
    }

    private static string? StripUrnUuidPrefix(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return raw;
        var trimmed = raw.Trim();
        const string prefix = "urn:uuid:";
        return trimmed.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? trimmed[prefix.Length..]
            : trimmed;
    }

    private static string? ExactGuid(string? raw)
        => !string.IsNullOrWhiteSpace(raw) && Guid.TryParse(raw.Trim(), out var g) ? g.ToString() : null;

    private static CertificateValidationResult Fail(string reason)
        => new(false, null, TrustTier.None, reason);

    private static IEnumerable<string> ParseList(string? value)
        => (value ?? string.Empty)
            .Split([',', ';', '|'], StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .Where(s => s.Length > 0);

    private static IEnumerable<string> ParseList(string? value, char separator)
        => (value ?? string.Empty)
            .Split(separator, StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .Where(s => s.Length > 0);

    private HashSet<string> ParseStrictThumbprintList(string? value, string settingName)
    {
        if (string.IsNullOrEmpty(value))
            return new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in value.Split([',', ';', '|'], StringSplitOptions.None))
        {
            if (string.IsNullOrWhiteSpace(entry))
                throw InvalidPolicy(settingName, "contains an empty entry");

            var thumbprint = NormalizeThumbprint(entry);
            if (thumbprint.Length != 40 || !thumbprint.All(Uri.IsHexDigit))
            {
                throw InvalidPolicy(
                    settingName,
                    "entries must be exact 40-hex SHA1 thumbprints after removing whitespace and colons");
            }

            result.Add(thumbprint);
        }

        return result;
    }

    private HashSet<string> ParseStrictSubjectList(string? value, string settingName)
    {
        if (string.IsNullOrEmpty(value))
            return new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in value.Split('|', StringSplitOptions.None))
        {
            var subject = entry.Trim();
            if (subject.Length == 0)
                throw InvalidPolicy(settingName, "contains an empty entry");

            result.Add(subject);
        }

        return result;
    }

    private InvalidOperationException InvalidPolicy(string settingName, string detail)
    {
        var message = $"Invalid client certificate policy setting '{settingName}': {detail}.";
        _log.LogError("{Message} Failing closed.", message);
        return new InvalidOperationException(message);
    }

    private static string NormalizeThumbprint(string t)
        => new string([.. t.Where(c => !char.IsWhiteSpace(c) && c != ':')]).ToUpperInvariant();

    private static string StripPem(string s)
        => s.Replace("-----BEGIN CERTIFICATE-----", string.Empty, StringComparison.Ordinal)
            .Replace("-----END CERTIFICATE-----", string.Empty, StringComparison.Ordinal)
            .Replace("\r", string.Empty, StringComparison.Ordinal)
            .Replace("\n", string.Empty, StringComparison.Ordinal)
            .Trim();

    private static string FormatChainFailure(X509Chain chain)
        => "certificate chain build failed ("
            + string.Join("; ", chain.ChainStatus.Select(s => $"{s.Status}: {s.StatusInformation.Trim()}"))
            + ")";
}
