<#
.SYNOPSIS
    Pester tests for device identity and certificate selection.

.DESCRIPTION
    The strict GUID extraction rules here are security controls, not formatting
    preferences: accepting a GUID-shaped substring would let a permissive
    certificate template bind a client to another device's identity.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $repoRoot 'src\Client\DeviceIdentity.psm1') -Force -DisableNameChecking

    $script:DeviceId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'

    function New-TestCertificate {
        param(
            [string] $Subject = 'CN=pester-device',
            [string] $SanUriDeviceId,
            [string] $IntuneDeviceId,
            [switch] $WithoutClientAuth,
            [switch] $CertificateAuthority,
            [int] $ValidYears = 1
        )

        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
            (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($Subject)),
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

        if (-not $WithoutClientAuth) {
            $oids = New-Object Security.Cryptography.OidCollection
            $null = $oids.Add((New-Object Security.Cryptography.Oid('1.3.6.1.5.5.7.3.2')))
            $request.CertificateExtensions.Add(
                (New-Object Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($oids, $false)))
        }
        if ($CertificateAuthority) {
            $request.CertificateExtensions.Add(
                (New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension(
                    $true, $false, 0, $true)))
        }
        if ($SanUriDeviceId) {
            $san = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
            $san.AddUri([Uri]("urn:uuid:$SanUriDeviceId"))
            $request.CertificateExtensions.Add($san.Build())
        }

        if ($IntuneDeviceId) {
            $guidBytes = ([guid]$IntuneDeviceId).ToByteArray()
            $raw = New-Object byte[] 18
            $raw[0] = 0x04
            $raw[1] = 0x10
            [Array]::Copy($guidBytes, 0, $raw, 2, 16)
            $request.CertificateExtensions.Add(
                (New-Object System.Security.Cryptography.X509Certificates.X509Extension(
                    (New-Object System.Security.Cryptography.Oid('1.2.840.113556.5.25')), $raw, $false)))
        }

        return $request.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears($ValidYears))
    }

    function Invoke-PkiCaRoleTest {
        param([hashtable] $Parameters)

        $module = Get-Module DeviceIdentity
        return & $module {
            param($Arguments)
            Test-PkiCaChainRoleConstraints @Arguments
        } $Parameters
    }
}

Describe 'ConvertTo-ExactGuid' {

    It 'accepts a bare GUID and returns canonical form' {
        ConvertTo-ExactGuid -Value $script:DeviceId.ToUpper() | Should -BeExactly $script:DeviceId
    }

    It 'tolerates surrounding whitespace' {
        ConvertTo-ExactGuid -Value "  $script:DeviceId  " | Should -BeExactly $script:DeviceId
    }

    It 'rejects a GUID embedded in a larger string' {
        # "<victim>.attacker.example" must never resolve to the victim device id.
        ConvertTo-ExactGuid -Value "$script:DeviceId.attacker.example" | Should -BeNullOrEmpty
    }

    It 'rejects empty and non-GUID input' {
        ConvertTo-ExactGuid -Value '' | Should -BeNullOrEmpty
        ConvertTo-ExactGuid -Value '   ' | Should -BeNullOrEmpty
        ConvertTo-ExactGuid -Value 'not-a-guid' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-IssuerPatternList' {

    It 'splits on semicolons and trims each pattern' {
        $patterns = @(ConvertTo-IssuerPatternList -Value ' *CA-A* ; *CA-B* ')

        $patterns.Count | Should -Be 2
        $patterns[0] | Should -BeExactly '*CA-A*'
        $patterns[1] | Should -BeExactly '*CA-B*'
    }

    It 'returns an empty list for empty input' {
        @(ConvertTo-IssuerPatternList -Value '').Count | Should -Be 0
        @(ConvertTo-IssuerPatternList -Value $null).Count | Should -Be 0
    }

    It 'rejects issuer patterns that contain only wildcard operators' -TestCases @(
        @{ Pattern = '*' }
        @{ Pattern = '**' }
        @{ Pattern = '?*?' }
    ) {
        param($Pattern)
        { ConvertTo-IssuerPatternList -Value $Pattern } | Should -Throw '*no constraining literal character*'
    }
}

Describe 'Test-IssuerMatch' {

    It 'matches when any pattern matches' {
        Test-IssuerMatch -Issuer 'CN=CONTOSO-ISSUING-CA, DC=contoso' -Patterns @('*ROOT*', '*ISSUING*') | Should -BeTrue
    }

    It 'does not match when no pattern matches' {
        Test-IssuerMatch -Issuer 'CN=OTHER-CA' -Patterns @('*CONTOSO*') | Should -BeFalse
    }

    It 'matches nothing when the pattern list is empty' {
        # An empty pin list must not silently become "trust everything".
        Test-IssuerMatch -Issuer 'CN=ANY' -Patterns @() | Should -BeFalse
    }
}

Describe 'Get-CertificatePkiDeviceId' {

    It 'reads an exact GUID from a urn:uuid SAN URI' {
        $cert = New-TestCertificate -SanUriDeviceId $script:DeviceId

        Get-CertificatePkiDeviceId -Certificate $cert | Should -BeExactly $script:DeviceId
    }

    It 'reads an exact GUID from the subject common name' {
        $cert = New-TestCertificate -Subject "CN=$script:DeviceId"

        Get-CertificatePkiDeviceId -Certificate $cert | Should -BeExactly $script:DeviceId
    }

    It 'returns nothing when the common name only contains a GUID substring' {
        $cert = New-TestCertificate -Subject "CN=device-$script:DeviceId-01"

        Get-CertificatePkiDeviceId -Certificate $cert | Should -BeNullOrEmpty
    }

    It 'returns nothing when the certificate carries no device id at all' {
        $cert = New-TestCertificate -Subject 'CN=plain-device'

        Get-CertificatePkiDeviceId -Certificate $cert | Should -BeNullOrEmpty
    }
}

Describe 'Get-IntuneEnrollmentDeviceId' {

    It 'decodes the device id from the MDM enrollment OID' {
        $cert = New-TestCertificate -Subject 'CN=some-enrollment-guid' -IntuneDeviceId $script:DeviceId

        Get-IntuneEnrollmentDeviceId -Certificate $cert | Should -BeExactly $script:DeviceId
    }

    It 'returns nothing when the extension is absent' {
        $cert = New-TestCertificate -Subject 'CN=plain-device'

        Get-IntuneEnrollmentDeviceId -Certificate $cert | Should -BeNullOrEmpty
    }

    It 'is independent of the subject, which Intune populates with a different GUID' {
        $otherGuid = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'
        $cert = New-TestCertificate -Subject "CN=$otherGuid" -IntuneDeviceId $script:DeviceId

        Get-IntuneEnrollmentDeviceId -Certificate $cert | Should -BeExactly $script:DeviceId
    }
}

Describe 'PKI CA role policy' {
    BeforeAll {
        $script:PolicyLeaf = New-TestCertificate -Subject 'CN=leaf'
        $script:PolicyIntermediateOne = New-TestCertificate -Subject 'CN=Issuing CA One, O=Contoso' -CertificateAuthority
        $script:PolicyIntermediateTwo = New-TestCertificate -Subject 'CN=Issuing CA Two, O=Contoso' -CertificateAuthority
        $script:PolicyRoot = New-TestCertificate -Subject 'CN=Root CA, O=Contoso' -CertificateAuthority
        $script:PolicyChain = @(
            $script:PolicyLeaf,
            $script:PolicyIntermediateOne,
            $script:PolicyIntermediateTwo,
            $script:PolicyRoot
        )
    }

    It 'matches root and intermediate constraints in their correct chain roles' {
        $result = Invoke-PkiCaRoleTest @{
            ChainCertificates = $script:PolicyChain
            RootThumbprints = @($script:PolicyRoot.Thumbprint)
            RootSubjects = @($script:PolicyRoot.Subject.ToLowerInvariant())
            IntermediateThumbprints = @($script:PolicyIntermediateOne.Thumbprint)
            IntermediateSubjects = @($script:PolicyIntermediateOne.Subject.ToUpperInvariant())
        }

        $result.IsMatch | Should -BeTrue
    }

    It 'rejects a wrong root or intermediate CA' -TestCases @(
        @{ Root = @('0000000000000000000000000000000000000000'); Intermediate = @() }
        @{ Root = @(); Intermediate = @('0000000000000000000000000000000000000000') }
    ) {
        param($Root, $Intermediate)

        $result = Invoke-PkiCaRoleTest @{
            ChainCertificates = $script:PolicyChain
            RootThumbprints = $Root
            IntermediateThumbprints = $Intermediate
        }

        $result.IsMatch | Should -BeFalse
    }

    It 'does not treat a sole self-signed CA credential as its own root role' {
        $selfSignedCaLeaf = New-TestCertificate -Subject 'CN=Self-Signed Credential' -CertificateAuthority
        $result = Invoke-PkiCaRoleTest @{
            ChainCertificates = @($selfSignedCaLeaf)
            RootThumbprints = @($selfSignedCaLeaf.Thumbprint)
            RootSubjects = @($selfSignedCaLeaf.Subject)
        }

        $result.IsMatch | Should -BeFalse
    }

    It 'requires thumbprint and subject constraints for a role to match the same CA' {
        $result = Invoke-PkiCaRoleTest @{
            ChainCertificates = $script:PolicyChain
            IntermediateThumbprints = @($script:PolicyIntermediateOne.Thumbprint)
            IntermediateSubjects = @($script:PolicyIntermediateTwo.Subject)
        }

        $result.IsMatch | Should -BeFalse
    }

    It 'does not satisfy a root constraint with the leaf or a subordinate CA' -TestCases @(
        @{ Thumbprint = $script:PolicyLeaf.Thumbprint }
        @{ Thumbprint = $script:PolicyIntermediateOne.Thumbprint }
    ) {
        param($Thumbprint)

        $result = Invoke-PkiCaRoleTest @{
            ChainCertificates = $script:PolicyChain
            RootThumbprints = @($Thumbprint)
        }

        $result.IsMatch | Should -BeFalse
    }

    It 'rejects a direct-root chain when an intermediate CA is required' {
        $result = Invoke-PkiCaRoleTest @{
            ChainCertificates = @($script:PolicyLeaf, $script:PolicyRoot)
            IntermediateThumbprints = @($script:PolicyIntermediateOne.Thumbprint)
        }

        $result.IsMatch | Should -BeFalse
    }

    It 'requires BasicConstraints CA=true for a matching chain role' {
        $notACa = New-TestCertificate -Subject $script:PolicyRoot.Subject
        $result = Invoke-PkiCaRoleTest @{
            ChainCertificates = @($script:PolicyLeaf, $notACa)
            RootSubjects = @($notACa.Subject)
        }

        $result.IsMatch | Should -BeFalse
    }

    It 'uses Windows trust without unknown-authority overrides and bounds AIA retrieval' {
        $module = Get-Module DeviceIdentity
        $chain = & $module { New-ClientCertificateChain }
        try {
            $chain.ChainPolicy.RevocationMode | Should -Be ([Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck)
            $chain.ChainPolicy.VerificationFlags | Should -Be ([Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag)
            $chain.ChainPolicy.UrlRetrievalTimeout.TotalSeconds | Should -Be 5
        }
        finally {
            $chain.Dispose()
        }
    }
}

Describe 'Get-ClientCertificate' {

    It 'returns a stable error identifier for expected certificate absence' {
        Mock -ModuleName DeviceIdentity Get-ChildItem { @() }
        try {
            Get-ClientCertificate -EntraDeviceId $script:DeviceId
            throw 'Expected certificate selection to fail.'
        }
        catch {
            $_.FullyQualifiedErrorId | Should -BeLike 'LogCollector.ClientCertificateNotFound*'
        }
    }

    It 'does not select a certificate without the EKU required by intake' {
        $cert = New-TestCertificate -SanUriDeviceId $script:DeviceId -WithoutClientAuth
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($cert) }
        { Get-ClientCertificate -EntraDeviceId $script:DeviceId } |
            Should -Throw '*No usable client certificate found*'
    }

    It 'throws a clear error when no usable certificate exists' {
        Mock -ModuleName DeviceIdentity Get-ChildItem { @() }

        { Get-ClientCertificate -EntraDeviceId $script:DeviceId } |
            Should -Throw '*No usable client certificate found*'
    }

    It 'prefers an enterprise PKI certificate that carries the device id when a PKI CA policy is configured' {
        $pki = New-TestCertificate -Subject 'CN=pki-device' -SanUriDeviceId $script:DeviceId
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($intune, $pki) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy { $true }

        $selected = Get-ClientCertificate -EntraDeviceId $script:DeviceId -PkiRootCaSubjects @('CN=Enterprise Root')
        $selected.Thumbprint | Should -BeExactly $pki.Thumbprint
    }

    It 'ignores an unauthenticated CN/SAN device-id match and uses the Intune certificate when no enterprise PKI trust signal is configured' {
        # Without IssuerLike or a PKI CA role policy, a bare CN/SAN device-id match
        # proves nothing - any certificate (including the Entra device-join
        # certificate) can be issued with that name. This is the exact scenario
        # that misdirected a real device's submission to the wrong certificate.
        $pki = New-TestCertificate -Subject 'CN=pki-device' -SanUriDeviceId $script:DeviceId
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($intune, $pki) }

        $selected = Get-ClientCertificate -EntraDeviceId $script:DeviceId
        $selected.Thumbprint | Should -BeExactly $intune.Thumbprint
    }

    It 'falls back to the Intune enrollment certificate when no PKI certificate matches' {
        $unrelated = New-TestCertificate -Subject 'CN=unrelated'
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($unrelated, $intune) }

        $selected = Get-ClientCertificate -EntraDeviceId $script:DeviceId
        $selected.Thumbprint | Should -BeExactly $intune.Thumbprint
    }

    It 'does not apply the issuer pin to the Intune fallback tier' {
        # IssuerLike is normally pinned to the enterprise CA. Applying it to the
        # fallback would filter out the very certificate the fallback exists for.
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($intune) }

        $selected = Get-ClientCertificate -EntraDeviceId $script:DeviceId -IssuerLike '*CONTOSO-ISSUING-CA*'
        $selected.Thumbprint | Should -BeExactly $intune.Thumbprint
    }

    It 'keeps the Intune fallback independent when PKI CA constraints reject the enterprise candidate' {
        $pki = New-TestCertificate -Subject 'CN=pki-device' -SanUriDeviceId $script:DeviceId
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($pki, $intune) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy { $false }

        $selected = Get-ClientCertificate -EntraDeviceId $script:DeviceId `
            -PkiRootCaSubjects @('CN=Required Root')

        $selected.Thumbprint | Should -BeExactly $intune.Thumbprint
    }

    It 'honours an explicit thumbprint pin regardless of the issuer filter' {
        $pinned = New-TestCertificate -Subject 'CN=pinned'
        $other = New-TestCertificate -Subject 'CN=other' -SanUriDeviceId $script:DeviceId

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($other, $pinned) }

        $selected = Get-ClientCertificate -Thumbprint $pinned.Thumbprint -IssuerLike '*NEVER-MATCHES*'
        $selected.Thumbprint | Should -BeExactly $pinned.Thumbprint
    }

    It 'does not let an explicit leaf thumbprint bypass the PKI CA policy' {
        $pinned = New-TestCertificate -Subject 'CN=pinned'
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($pinned) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy { $false }

        { Get-ClientCertificate -Thumbprint $pinned.Thumbprint -PkiRootCaSubjects @('CN=Required Root') } |
            Should -Throw '*No usable client certificate found*'
    }

    It 'keeps an explicitly selected Intune candidate independent of PKI CA policy' -TestCases @(
        @{ Selector = 'Thumbprint' }
        @{ Selector = 'SubjectLike' }
    ) {
        param($Selector)
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($intune) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy { throw 'Intune trust is authorized by Intake, not enterprise CA filters' }
        $arguments = @{ EntraDeviceId = $script:DeviceId; PkiRootCaSubjects = @('CN=Enterprise Root') }
        $arguments[$Selector] = if ($Selector -eq 'Thumbprint') { $intune.Thumbprint } else { '*enrollment*' }

        $selected = Get-ClientCertificate @arguments

        $selected.Thumbprint | Should -BeExactly $intune.Thumbprint
        Should -Invoke -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy -Times 0 -Exactly
    }

    It 'does not exempt an explicit candidate whose Intune OID names another device' {
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId '00000000-0000-0000-0000-000000000001'
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($intune) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy { $false }

        { Get-ClientCertificate -Thumbprint $intune.Thumbprint -EntraDeviceId $script:DeviceId `
            -PkiRootCaSubjects @('CN=Enterprise Root') } | Should -Throw '*No usable client certificate found*'
    }

    It 'selects by subject pattern when one is supplied' {
        $wanted = New-TestCertificate -Subject 'CN=wanted-device'
        $other = New-TestCertificate -Subject 'CN=other-device'

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($other, $wanted) }

        $selected = Get-ClientCertificate -SubjectLike '*wanted*'
        $selected.Thumbprint | Should -BeExactly $wanted.Thumbprint
    }

    It 'does not let an explicit leaf subject selector bypass the PKI CA policy' {
        $wanted = New-TestCertificate -Subject 'CN=wanted-device'
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($wanted) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy { $false }

        { Get-ClientCertificate -SubjectLike '*wanted*' -PkiRootCaSubjects @('CN=Required Root') } |
            Should -Throw '*No usable client certificate found*'
    }

    It 'rejects an ineligible subject candidate and keeps searching eligible candidates' {
        $newer = New-TestCertificate -Subject 'CN=wanted-device' -ValidYears 2
        $older = New-TestCertificate -Subject 'CN=wanted-device' -ValidYears 1
        $script:EligibleThumbprint = $older.Thumbprint
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($newer, $older) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy {
            param($Certificate)
            $Certificate.Thumbprint -eq $script:EligibleThumbprint
        }

        $selected = Get-ClientCertificate -SubjectLike '*wanted*' -PkiRootCaSubjects @('CN=Required Root')

        $selected.Thumbprint | Should -BeExactly $older.Thumbprint
    }

    It 'never invokes the PKI CA policy check when no PKI CA policy is configured' {
        $pki = New-TestCertificate -Subject 'CN=pki-device' -SanUriDeviceId $script:DeviceId
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($pki, $intune) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy { throw 'Policy should not run' }

        $selected = Get-ClientCertificate -EntraDeviceId $script:DeviceId `
            -PkiRootCaThumbprints @() -PkiRootCaSubjects @() `
            -PkiIntermediateCaThumbprints @() -PkiIntermediateCaSubjects @()

        $selected.Thumbprint | Should -BeExactly $intune.Thumbprint
        Should -Invoke -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy -Times 0 -Exactly
    }

    It 'normalizes spaces and colons in CA thumbprints before policy evaluation' {
        $pki = New-TestCertificate -Subject 'CN=pki-device' -SanUriDeviceId $script:DeviceId
        $script:NormalizedRootPin = $null
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($pki) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy {
            param($RootThumbprints)
            $script:NormalizedRootPin = $RootThumbprints[0]
            $true
        }
        $formatted = ($script:PolicyRoot.Thumbprint -replace '(..)', '$1: ').TrimEnd(':', ' ')

        $null = Get-ClientCertificate -EntraDeviceId $script:DeviceId -PkiRootCaThumbprints @($formatted)

        $script:NormalizedRootPin | Should -BeExactly $script:PolicyRoot.Thumbprint
    }

    It 'trims CA subject names before exact case-insensitive policy matching' {
        $pki = New-TestCertificate -Subject 'CN=pki-device' -SanUriDeviceId $script:DeviceId
        $script:NormalizedRootSubject = $null
        Mock -ModuleName DeviceIdentity Get-ChildItem { @($pki) }
        Mock -ModuleName DeviceIdentity Test-CertificatePkiCaPolicy {
            param($RootSubjects)
            $script:NormalizedRootSubject = $RootSubjects[0]
            $true
        }

        $null = Get-ClientCertificate -EntraDeviceId $script:DeviceId `
            -PkiRootCaSubjects @('  cn=Root CA, O=Contoso  ')

        $script:NormalizedRootSubject | Should -BeExactly 'cn=Root CA, O=Contoso'
    }

    It 'fails closed on malformed CA policy entries before store discovery' -TestCases @(
        @{ Parameter = 'PkiRootCaThumbprints'; Value = @('ABC') }
        @{ Parameter = 'PkiIntermediateCaThumbprints'; Value = @('GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG') }
        @{ Parameter = 'PkiRootCaSubjects'; Value = @(' ') }
        @{ Parameter = 'PkiIntermediateCaSubjects'; Value = @('') }
    ) {
        param($Parameter, $Value)
        Mock -ModuleName DeviceIdentity Get-ChildItem { throw 'Certificate discovery must not run' }
        $arguments = @{ EntraDeviceId = $script:DeviceId }
        $arguments[$Parameter] = $Value

        { Get-ClientCertificate @arguments } | Should -Throw
        Should -Invoke -ModuleName DeviceIdentity Get-ChildItem -Times 0 -Exactly
    }

    It 'throws when no certificate carries the expected device id' {
        $unrelated = New-TestCertificate -Subject 'CN=unrelated'

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($unrelated) }

        { Get-ClientCertificate -EntraDeviceId $script:DeviceId } |
            Should -Throw '*No usable client certificate found*'
    }
}
