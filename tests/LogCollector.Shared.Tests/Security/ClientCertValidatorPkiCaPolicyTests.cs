using LogCollector.Shared.Security;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LogCollector.Shared.Tests.Security;

public sealed class ClientCertValidatorPkiCaPolicyTests
{
    private const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    private const string IntuneIssuerSubject = "CN=Intune Test Device CA";

    private static ClientCertValidator Create(params (string, string)[] settings)
        => new(TestCertificates.Config(settings), NullLogger<ClientCertValidator>.Instance);

    [Fact]
    public void Validate_AcceptsMatchingRootAndIntermediateRolePolicies()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var intermediate = TestCertificates.CreateIntermediateCa(root, "Issuing CA");
        using var leaf = TestCertificates.CreateClientCertificate(intermediate, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:TrustedIntermediateCertificates", TestCertificates.ToBase64(intermediate)),
            ("ClientCert:PkiRootCaThumbprints",
                $"{new string('0', 40)},{WithColonAndWhitespace(root.Thumbprint)}"),
            ("ClientCert:PkiRootCaSubjects", root.Subject.ToLowerInvariant()),
            ("ClientCert:PkiIntermediateCaThumbprints",
                $"{new string('0', 40)};{WithColonAndWhitespace(intermediate.Thumbprint)}|{new string('1', 40)}"),
            ("ClientCert:PkiIntermediateCaSubjects", intermediate.Subject.ToLowerInvariant()));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.True(result.Ok, result.Reason);
        Assert.Equal(ClientCertValidator.TrustTier.EnterprisePki, result.Tier);
    }

    [Fact]
    public void Validate_RejectsAnExactRootSubjectMismatch()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var intermediate = TestCertificates.CreateIntermediateCa(root, "Issuing CA");
        using var leaf = TestCertificates.CreateClientCertificate(intermediate, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:TrustedIntermediateCertificates", TestCertificates.ToBase64(intermediate)),
            ("ClientCert:PkiRootCaSubjects", "CN=Enterprise*"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal("certificate chain root CA does not satisfy configured PKI root policy", result.Reason);
    }

    [Fact]
    public void Validate_RejectsAnIntermediateThumbprintMismatch()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var intermediate = TestCertificates.CreateIntermediateCa(root, "Issuing CA");
        using var leaf = TestCertificates.CreateClientCertificate(intermediate, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:TrustedIntermediateCertificates", TestCertificates.ToBase64(intermediate)),
            ("ClientCert:PkiIntermediateCaThumbprints", new string('0', 40)));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal(
            "certificate chain intermediate CA does not satisfy configured PKI intermediate policy",
            result.Reason);
    }

    [Fact]
    public void Validate_RequiresSubjectAndThumbprintToMatchTheSameIntermediate()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var upperIntermediate = TestCertificates.CreateIntermediateCa(root, "Policy Subject CA");
        using var lowerIntermediate = TestCertificates.CreateIntermediateCa(upperIntermediate, "Policy Thumb CA");
        using var leaf = TestCertificates.CreateClientCertificate(lowerIntermediate, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:TrustedIntermediateCertificates",
                $"{TestCertificates.ToBase64(upperIntermediate)}|{TestCertificates.ToBase64(lowerIntermediate)}"),
            ("ClientCert:PkiIntermediateCaSubjects", upperIntermediate.Subject),
            ("ClientCert:PkiIntermediateCaThumbprints", lowerIntermediate.Thumbprint));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal(
            "certificate chain intermediate CA does not satisfy configured PKI intermediate policy",
            result.Reason);
    }

    [Fact]
    public void Validate_RejectsARootDirectChainWhenAnIntermediateIsRequired()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var leaf = TestCertificates.CreateClientCertificate(root, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:PkiIntermediateCaSubjects", $"{root.Subject}|{leaf.Subject}"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal(
            "certificate chain intermediate CA does not satisfy configured PKI intermediate policy",
            result.Reason);
    }

    [Fact]
    public void Validate_RejectsRootAndIntermediatePinsAssignedToTheWrongRoles()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var intermediate = TestCertificates.CreateIntermediateCa(root, "Issuing CA");
        using var leaf = TestCertificates.CreateClientCertificate(intermediate, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:TrustedIntermediateCertificates", TestCertificates.ToBase64(intermediate)),
            ("ClientCert:PkiRootCaSubjects", intermediate.Subject),
            ("ClientCert:PkiIntermediateCaSubjects", root.Subject));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal("certificate chain root CA does not satisfy configured PKI root policy", result.Reason);
    }

    [Fact]
    public void Validate_KeepsLegacyGenericPinsAdditive()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var intermediate = TestCertificates.CreateIntermediateCa(root, "Issuing CA");
        using var leaf = TestCertificates.CreateClientCertificate(intermediate, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:TrustedIntermediateCertificates", TestCertificates.ToBase64(intermediate)),
            ("ClientCert:PkiRootCaThumbprints", root.Thumbprint),
            ("ClientCert:PkiIntermediateCaThumbprints", intermediate.Thumbprint),
            ("ClientCert:TrustedCaThumbprints", new string('0', 40)));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal("no trusted CA thumbprint found in the certificate chain", result.Reason);
    }

    [Fact]
    public void Validate_EmptyRolePolicySettingsPreserveExistingBehavior()
    {
        using var root = TestCertificates.CreateRootCa("Enterprise Root");
        using var leaf = TestCertificates.CreateClientCertificate(root, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(root)),
            ("ClientCert:PkiRootCaThumbprints", ""),
            ("ClientCert:PkiRootCaSubjects", ""),
            ("ClientCert:PkiIntermediateCaThumbprints", ""),
            ("ClientCert:PkiIntermediateCaSubjects", ""));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.True(result.Ok, result.Reason);
    }

    [Theory]
    [InlineData("ClientCert:PkiRootCaThumbprints", "AA:BB")]
    [InlineData("ClientCert:PkiRootCaThumbprints", "   ")]
    [InlineData("ClientCert:PkiIntermediateCaThumbprints", "0000000000000000000000000000000000000000||1111111111111111111111111111111111111111")]
    [InlineData("ClientCert:PkiRootCaSubjects", "CN=Root||CN=Other")]
    [InlineData("ClientCert:PkiRootCaSubjects", "\t")]
    [InlineData("ClientCert:PkiIntermediateCaSubjects", "|CN=Issuing")]
    public void Constructor_RejectsMalformedRolePolicy(string settingName, string value)
    {
        var error = Assert.Throws<InvalidOperationException>(() => Create((settingName, value)));

        Assert.Contains(settingName, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Constructor_InvalidEnterpriseRolePolicyCannotFallBackToIntune()
    {
        using var intuneRoot = TestCertificates.CreateRootCa("Intune Test Device CA");

        var error = Assert.Throws<InvalidOperationException>(() => Create(
            ("ClientCert:TrustedIntuneRootCertificates", TestCertificates.ToBase64(intuneRoot)),
            ("ClientCert:IntuneEnrollmentIssuerSubjects", IntuneIssuerSubject),
            ("ClientCert:AllowIntuneEnrollmentCertificateFallback", "true"),
            ("ClientCert:PkiRootCaThumbprints", "not-a-thumbprint")));

        Assert.Contains("ClientCert:PkiRootCaThumbprints", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Validate_RootRolePolicyCannotBeSatisfiedByASingleElementCaCredential()
    {
        using var credential = TestCertificates.CreateRootCa("Self-Signed Client CA", includeClientAuthEku: true);
        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(credential)),
            ("ClientCert:PkiRootCaThumbprints", credential.Thumbprint));

        var result = validator.Validate(TestCertificates.PublicOnly(credential), null);

        Assert.False(result.Ok);
        Assert.Equal("certificate chain root CA does not satisfy configured PKI root policy", result.Reason);
    }

    [Fact]
    public void Validate_NoRolePolicyStillAcceptsASingleElementCaCredential()
    {
        using var credential = TestCertificates.CreateRootCa("Self-Signed Client CA", includeClientAuthEku: true);
        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(credential)));

        var result = validator.Validate(TestCertificates.PublicOnly(credential), null);

        Assert.True(result.Ok, result.Reason);
        Assert.Equal(ClientCertValidator.TrustTier.EnterprisePki, result.Tier);
    }

    [Fact]
    public void Validate_ValidEnterpriseRoleRejectionStillAllowsIndependentIntuneFallback()
    {
        using var enterpriseRoot = TestCertificates.CreateRootCa("Enterprise Root");
        using var intuneRoot = TestCertificates.CreateRootCa("Intune Test Device CA");
        using var leaf = TestCertificates.CreateClientCertificate(
            intuneRoot,
            "enrollment-guid",
            intuneDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates",
                $"{TestCertificates.ToBase64(enterpriseRoot)}|{TestCertificates.ToBase64(intuneRoot)}"),
            ("ClientCert:PkiRootCaThumbprints", enterpriseRoot.Thumbprint),
            ("ClientCert:TrustedIntuneRootCertificates", TestCertificates.ToBase64(intuneRoot)),
            ("ClientCert:IntuneEnrollmentIssuerSubjects", IntuneIssuerSubject),
            ("ClientCert:AllowIntuneEnrollmentCertificateFallback", "true"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.True(result.Ok, result.Reason);
        Assert.Equal(ClientCertValidator.TrustTier.IntuneEnrollment, result.Tier);
    }

    [Fact]
    public void Validate_IntuneOidAndMatchingIssuerNameCannotBypassIndependentTrust()
    {
        using var enterpriseRoot = TestCertificates.CreateRootCa("Intune Test Device CA");
        using var intuneRoot = TestCertificates.CreateRootCa("Intune Test Device CA");
        using var leaf = TestCertificates.CreateClientCertificate(
            enterpriseRoot, "enrollment-guid", intuneDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(enterpriseRoot)),
            ("ClientCert:PkiRootCaThumbprints", new string('0', 40)),
            ("ClientCert:TrustedIntuneRootCertificates", TestCertificates.ToBase64(intuneRoot)),
            ("ClientCert:IntuneEnrollmentIssuerSubjects", IntuneIssuerSubject),
            ("ClientCert:AllowIntuneEnrollmentCertificateFallback", "true"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal(ClientCertValidator.TrustTier.None, result.Tier);
    }

    private static string WithColonAndWhitespace(string thumbprint)
        => string.Join(" : ", Enumerable.Range(0, thumbprint.Length / 2)
            .Select(index => thumbprint.Substring(index * 2, 2).ToLowerInvariant()));
}
