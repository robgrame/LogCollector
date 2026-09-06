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
            [switch] $WithoutClientAuth
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
            [DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
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

    It 'prefers an enterprise PKI certificate that carries the device id' {
        $pki = New-TestCertificate -Subject 'CN=pki-device' -SanUriDeviceId $script:DeviceId
        $intune = New-TestCertificate -Subject 'CN=enrollment' -IntuneDeviceId $script:DeviceId

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($intune, $pki) }

        $selected = Get-ClientCertificate -EntraDeviceId $script:DeviceId
        $selected.Thumbprint | Should -BeExactly $pki.Thumbprint
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

    It 'honours an explicit thumbprint pin regardless of the issuer filter' {
        $pinned = New-TestCertificate -Subject 'CN=pinned'
        $other = New-TestCertificate -Subject 'CN=other' -SanUriDeviceId $script:DeviceId

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($other, $pinned) }

        $selected = Get-ClientCertificate -Thumbprint $pinned.Thumbprint -IssuerLike '*NEVER-MATCHES*'
        $selected.Thumbprint | Should -BeExactly $pinned.Thumbprint
    }

    It 'selects by subject pattern when one is supplied' {
        $wanted = New-TestCertificate -Subject 'CN=wanted-device'
        $other = New-TestCertificate -Subject 'CN=other-device'

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($other, $wanted) }

        $selected = Get-ClientCertificate -SubjectLike '*wanted*'
        $selected.Thumbprint | Should -BeExactly $wanted.Thumbprint
    }

    It 'throws when no certificate carries the expected device id' {
        $unrelated = New-TestCertificate -Subject 'CN=unrelated'

        Mock -ModuleName DeviceIdentity Get-ChildItem { @($unrelated) }

        { Get-ClientCertificate -EntraDeviceId $script:DeviceId } |
            Should -Throw '*No usable client certificate found*'
    }
}
