using LogCollector.Shared.Security;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LogCollector.Shared.Tests.Security;

public sealed class ClientCertValidatorTests
{
    private const string DeviceId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    private const string OtherDeviceId = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
    private const string IntuneIssuerSubject = "CN=Intune Test Device CA";

    private static ClientCertValidator Create(params (string, string)[] settings)
        => new(TestCertificates.Config(settings), NullLogger<ClientCertValidator>.Instance);

    [Fact]
    public void Validate_FailsClosedWhenNoTrustAnchorIsConfigured()
    {
        using var ca = TestCertificates.CreateRootCa("Unconfigured Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create();

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal("client certificate trust anchor not configured", result.Reason);
    }

    [Fact]
    public void Validate_FailsClosedWhenBindingIsDisabledButRequired()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "Disabled"),
            ("ClientCert:RequireDeviceBinding", "true"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal("client certificate device binding is required", result.Reason);
    }

    [Fact]
    public void Validate_RejectsAMissingCertificateWhenOneIsRequired()
    {
        using var ca = TestCertificates.CreateRootCa("Root");

        var validator = Create(("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)));

        var result = validator.Validate(null, null);

        Assert.False(result.Ok);
        Assert.Equal("client certificate missing", result.Reason);
    }

    [Fact]
    public void Validate_AcceptsALeafChainingToTheEnterpriseRoot()
    {
        using var ca = TestCertificates.CreateRootCa("Contoso Issuing CA");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.True(result.Ok, result.Reason);
        Assert.Equal(ClientCertValidator.TrustTier.EnterprisePki, result.Tier);
    }

    [Fact]
    public void Validate_RejectsALeafFromAnUntrustedRoot()
    {
        using var trustedCa = TestCertificates.CreateRootCa("Trusted Root");
        using var rogueCa = TestCertificates.CreateRootCa("Rogue Root");
        using var leaf = TestCertificates.CreateClientCertificate(rogueCa, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(trustedCa)));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
    }

    [Fact]
    public void Validate_RejectsACertificateWithoutTheClientAuthEku()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(
            ca, DeviceId, sanUriDeviceId: DeviceId, includeClientAuthEku: false);

        var validator = Create(("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Contains("Client Authentication EKU", result.Reason);
    }

    [Fact]
    public void Validate_RejectsAnExpiredCertificate()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(
            ca, DeviceId,
            sanUriDeviceId: DeviceId,
            notBefore: DateTimeOffset.UtcNow.AddDays(-10),
            notAfter: DateTimeOffset.UtcNow.AddDays(-1));

        var validator = Create(("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal("certificate expired or not yet valid", result.Reason);
    }

    [Fact]
    public void Validate_RejectsALeafOutsideTheThumbprintAllowList()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:AllowedLeafThumbprints", "0000000000000000000000000000000000000000"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
        Assert.Equal("leaf certificate thumbprint not in allow-list", result.Reason);
    }

    [Fact]
    public void Validate_ReadsTheForwardedAppServiceHeaderWhenTheConnectionHasNoCertificate()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)));

        var result = validator.Validate(null, TestCertificates.ToBase64(leaf));

        Assert.True(result.Ok, result.Reason);
    }

    [Fact]
    public void Validate_IgnoresTheForwardedHeaderWhenItIsNotTrusted()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:TrustForwardedHeader", "false"));

        var result = validator.Validate(null, TestCertificates.ToBase64(leaf));

        Assert.False(result.Ok);
        Assert.Equal("client certificate missing", result.Reason);
    }

    // --- Device binding -----------------------------------------------------

    [Fact]
    public void GetBoundDeviceId_ReadsAnExactGuidFromTheSanUri()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device-01", sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "SanUri"));

        Assert.Equal(DeviceId, validator.GetBoundDeviceId(TestCertificates.PublicOnly(leaf)));
    }

    [Fact]
    public void GetBoundDeviceId_ReadsAnExactGuidFromTheSubjectCommonName()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "SubjectCN"));

        Assert.Equal(DeviceId, validator.GetBoundDeviceId(TestCertificates.PublicOnly(leaf)));
    }

    [Fact]
    public void GetBoundDeviceId_RejectsAGuidThatIsOnlyASubstringOfTheCommonName()
    {
        // A permissive certificate template that appends anything to the device id
        // must not be usable to impersonate that device.
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, $"{DeviceId}.attacker.example");

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "SubjectCN"));

        Assert.Null(validator.GetBoundDeviceId(TestCertificates.PublicOnly(leaf)));
    }

    [Fact]
    public void GetBoundDeviceId_ReadsTheIntuneEnrollmentOid()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "someOtherGuid", intuneDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "IntuneEnrollmentOid"));

        Assert.Equal(DeviceId, validator.GetBoundDeviceId(TestCertificates.PublicOnly(leaf)));
    }

    [Fact]
    public void GetBoundDeviceId_PrefersTheOperatorThumbprintMapInAutoMode()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device-01", sanUriDeviceId: OtherDeviceId);
        var publicLeaf = TestCertificates.PublicOnly(leaf);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "Auto"),
            ("ClientCert:ThumbprintToDeviceMap", $"{publicLeaf.Thumbprint}={DeviceId}"));

        Assert.Equal(DeviceId, validator.GetBoundDeviceId(publicLeaf));
    }

    [Fact]
    public void GetBoundDeviceId_IgnoresAConflictingDuplicateThumbprintMapping()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "device-01");
        var publicLeaf = TestCertificates.PublicOnly(leaf);

        // The first mapping wins; a conflicting rebind is refused rather than
        // silently overwriting and pointing the certificate at another device.
        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "Thumbprint"),
            ("ClientCert:ThumbprintToDeviceMap", $"{publicLeaf.Thumbprint}={DeviceId}|{publicLeaf.Thumbprint}={OtherDeviceId}"));

        Assert.Equal(DeviceId, validator.GetBoundDeviceId(publicLeaf));
    }

    [Fact]
    public void GetBoundDeviceId_ReturnsNullWhenBindingIsDisabled()
    {
        using var ca = TestCertificates.CreateRootCa("Root");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:DeviceIdBindingClaim", "Disabled"),
            ("ClientCert:RequireDeviceBinding", "false"));

        Assert.False(validator.BindingEnabled);
        Assert.Null(validator.GetBoundDeviceId(TestCertificates.PublicOnly(leaf)));
    }

    // --- Intune enrollment tier ---------------------------------------------

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, true)]
    public void Validate_IntuneRevocationExceptionRequiresExplicitOptIn(bool skip, bool accepted)
    {
        using var ca = TestCertificates.CreateRootCa("Intune Test Device CA");
        using var leaf = TestCertificates.CreateClientCertificate(ca, "enrollment-guid", intuneDeviceId: DeviceId);
        var validator = Create(
            ("ClientCert:TrustedIntuneRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:IntuneEnrollmentIssuerSubjects", IntuneIssuerSubject),
            ("ClientCert:CheckRevocation", "true"),
            ("ClientCert:SkipIntuneRevocationCheck", skip.ToString()));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.Equal(accepted, result.Ok);
        if (accepted)
            Assert.Equal(ClientCertValidator.TrustTier.IntuneEnrollment, result.Tier);
    }

    [Fact]
    public void Validate_IntuneRevocationExceptionDoesNotDisableEnterpriseRevocation()
    {
        using var ca = TestCertificates.CreateRootCa("Enterprise Root Without CRL");
        using var leaf = TestCertificates.CreateClientCertificate(ca, DeviceId, sanUriDeviceId: DeviceId);
        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(ca)),
            ("ClientCert:CheckRevocation", "true"),
            ("ClientCert:SkipIntuneRevocationCheck", "true"));

        Assert.False(validator.Validate(TestCertificates.PublicOnly(leaf), null).Ok);
    }

    [Fact]
    public void Validate_AcceptsAnIntuneEnrollmentCertificateWhenItsAnchorAndIssuerAreConfigured()
    {
        using var intuneCa = TestCertificates.CreateRootCa("Intune Test Device CA");
        using var leaf = TestCertificates.CreateClientCertificate(intuneCa, "enrollment-guid", intuneDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(TestCertificates.CreateRootCa("Unrelated Enterprise Root"))),
            ("ClientCert:TrustedIntuneRootCertificates", TestCertificates.ToBase64(intuneCa)),
            ("ClientCert:IntuneEnrollmentIssuerSubjects", IntuneIssuerSubject),
            ("ClientCert:AllowIntuneEnrollmentCertificateFallback", "true"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.True(result.Ok, result.Reason);
        Assert.Equal(ClientCertValidator.TrustTier.IntuneEnrollment, result.Tier);
    }

    [Fact]
    public void Validate_RejectsAnIntuneEnrollmentCertificateWhoseIssuerIsNotAllowListed()
    {
        using var intuneCa = TestCertificates.CreateRootCa("Impostor Device CA");
        using var leaf = TestCertificates.CreateClientCertificate(intuneCa, "enrollment-guid", intuneDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedIntuneRootCertificates", TestCertificates.ToBase64(intuneCa)),
            ("ClientCert:IntuneEnrollmentIssuerSubjects", IntuneIssuerSubject),
            ("ClientCert:AllowIntuneEnrollmentCertificateFallback", "true"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
    }

    [Fact]
    public void Validate_RejectsTheIntuneTierWhenTheFallbackIsTurnedOff()
    {
        using var intuneCa = TestCertificates.CreateRootCa("Intune Test Device CA");
        using var enterpriseCa = TestCertificates.CreateRootCa("Enterprise Root");
        using var leaf = TestCertificates.CreateClientCertificate(intuneCa, "enrollment-guid", intuneDeviceId: DeviceId);

        var validator = Create(
            ("ClientCert:TrustedRootCertificates", TestCertificates.ToBase64(enterpriseCa)),
            ("ClientCert:TrustedIntuneRootCertificates", TestCertificates.ToBase64(intuneCa)),
            ("ClientCert:IntuneEnrollmentIssuerSubjects", IntuneIssuerSubject),
            ("ClientCert:AllowIntuneEnrollmentCertificateFallback", "false"));

        var result = validator.Validate(TestCertificates.PublicOnly(leaf), null);

        Assert.False(result.Ok);
    }
}
