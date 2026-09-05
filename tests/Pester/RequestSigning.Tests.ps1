<#
.SYNOPSIS
    Pester tests for the IDA-SIGNATURE-V1 canonical form and client signing.

.DESCRIPTION
    The canonical string is a cross-language contract between
    src\Client\RequestSigning.psm1 and
    src\Shared\Security\RequestSignatureVerifier.cs. These tests pin the exact
    six-line layout with a fixed golden vector, so a drift on either side is
    caught here rather than as an opaque 401 in production.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $repoRoot 'src\Client\RequestSigning.psm1') -Force -DisableNameChecking

    $script:Nonce = [guid]'11111111-2222-3333-4444-555555555555'
    $script:Timestamp = [DateTimeOffset]::new(2026, 1, 2, 3, 4, 5, 678, [TimeSpan]::Zero)
    $script:Utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
}

Describe 'Get-SignedRequestCanonicalText' {

    It 'produces exactly six LF-separated lines' {
        $canonical = Get-SignedRequestCanonicalText -Method 'POST' -Path '/api/inventory' `
            -Timestamp $script:Timestamp -Nonce $script:Nonce -BodyBytes $script:Utf8.GetBytes('{"a":1}')

        ($canonical -split "`n").Count | Should -Be 6
        $canonical | Should -Not -Match "`r"
    }

    It 'matches the golden vector shared with the C# verifier' {
        $body = $script:Utf8.GetBytes('{"a":1}')

        $canonical = Get-SignedRequestCanonicalText -Method 'post' -Path 'api/inventory' `
            -Timestamp $script:Timestamp -Nonce $script:Nonce -BodyBytes $body

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $expectedHash = [Convert]::ToBase64String($sha.ComputeHash($body)) } finally { $sha.Dispose() }

        $expected = @(
            'IDA-SIGNATURE-V1'
            'POST'
            '/api/inventory'
            '2026-01-02T03:04:05.6780000+00:00'
            '11111111-2222-3333-4444-555555555555'
            $expectedHash
        ) -join "`n"

        $canonical | Should -BeExactly $expected
    }

    It 'upper-cases the method and prefixes a missing leading slash' {
        $canonical = Get-SignedRequestCanonicalText -Method '  post ' -Path 'api/inventory' `
            -Timestamp $script:Timestamp -Nonce $script:Nonce -BodyBytes @()

        $lines = $canonical -split "`n"
        $lines[1] | Should -BeExactly 'POST'
        $lines[2] | Should -BeExactly '/api/inventory'
    }

    It 'normalizes an empty path to /' {
        $canonical = Get-SignedRequestCanonicalText -Method 'POST' -Path '   ' `
            -Timestamp $script:Timestamp -Nonce $script:Nonce -BodyBytes @()

        ($canonical -split "`n")[2] | Should -BeExactly '/'
    }

    It 'lower-cases the nonce so casing cannot fork the signature' {
        $canonical = Get-SignedRequestCanonicalText -Method 'POST' -Path '/x' `
            -Timestamp $script:Timestamp -Nonce ([guid]'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE') -BodyBytes @()

        ($canonical -split "`n")[4] | Should -BeExactly 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    }

    It 'changes when a single body byte changes' {
        $a = Get-SignedRequestCanonicalText -Method 'POST' -Path '/x' -Timestamp $script:Timestamp `
            -Nonce $script:Nonce -BodyBytes $script:Utf8.GetBytes('{"a":1}')
        $b = Get-SignedRequestCanonicalText -Method 'POST' -Path '/x' -Timestamp $script:Timestamp `
            -Nonce $script:Nonce -BodyBytes $script:Utf8.GetBytes('{"a":2}')

        $a | Should -Not -Be $b
    }

    It 'always converts the timestamp to UTC' {
        $local = [DateTimeOffset]::new(2026, 1, 2, 5, 4, 5, 678, [TimeSpan]::FromHours(2))

        $canonical = Get-SignedRequestCanonicalText -Method 'POST' -Path '/x' `
            -Timestamp $local -Nonce $script:Nonce -BodyBytes @()

        ($canonical -split "`n")[3] | Should -BeExactly '2026-01-02T03:04:05.6780000+00:00'
    }
}

Describe 'New-SignedInventoryRequest' {

    BeforeAll {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
            (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName('CN=pester-device')),
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

        $script:Certificate = $request.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddDays(-1),
            [DateTimeOffset]::UtcNow.AddYears(1))
    }

    It 'emits every header the frontend requires' {
        $signed = New-SignedInventoryRequest -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{"records":[]}' -Certificate $script:Certificate

        $signed.Headers.Keys | Should -Contain 'X-Request-Timestamp'
        $signed.Headers.Keys | Should -Contain 'X-Request-Nonce'
        $signed.Headers.Keys | Should -Contain 'X-Request-Signature-Version'
        $signed.Headers.Keys | Should -Contain 'X-Request-Signature-Algorithm'
        $signed.Headers.Keys | Should -Contain 'X-Request-Signature'
        $signed.Headers['X-Request-Signature-Version'] | Should -BeExactly 'IDA-SIGNATURE-V1'
        $signed.Headers['X-Request-Signature-Algorithm'] | Should -BeExactly 'RSA-PKCS1-SHA256'
    }

    It 'never emits a function key or any other shared secret' {
        $signed = New-SignedInventoryRequest -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate

        $signed.Headers.Keys | Should -Not -Contain 'x-functions-key'
        $signed.Headers.Keys | Should -Not -Contain 'Authorization'
    }

    It 'produces UTF-8 body bytes without a BOM' {
        $signed = New-SignedInventoryRequest -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{"a":1}' -Certificate $script:Certificate

        $signed.BodyBytes[0] | Should -Be 0x7B  # '{'
        [System.Text.Encoding]::UTF8.GetString($signed.BodyBytes) | Should -BeExactly '{"a":1}'
    }

    It 'produces a signature the corresponding public key verifies' {
        $body = '{"records":[{"RecordType":"Hardware"}]}'
        $uri = [Uri]'https://example.invalid/api/inventory'

        $signed = New-SignedInventoryRequest -Uri $uri -Body $body -Certificate $script:Certificate

        $canonical = Get-SignedRequestCanonicalText `
            -Method 'POST' `
            -Path $uri.AbsolutePath `
            -Timestamp ([DateTimeOffset]::Parse($signed.Headers['X-Request-Timestamp'])) `
            -Nonce ([guid]$signed.Headers['X-Request-Nonce']) `
            -BodyBytes $signed.BodyBytes

        $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:Certificate)
        try {
            $verified = $publicKey.VerifyData(
                ([System.Text.Encoding]::UTF8.GetBytes($canonical)),
                [Convert]::FromBase64String($signed.Headers['X-Request-Signature']),
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        }
        finally {
            $publicKey.Dispose()
        }

        $verified | Should -BeTrue
    }

    It 'generates a fresh nonce and timestamp on every call' {
        $first = New-SignedInventoryRequest -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate
        $second = New-SignedInventoryRequest -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate

        # Reusing either value would make a legitimate retry look like a replay.
        $first.Headers['X-Request-Nonce'] | Should -Not -Be $second.Headers['X-Request-Nonce']
        $first.Headers['X-Request-Signature'] | Should -Not -Be $second.Headers['X-Request-Signature']
    }

    It 'refuses a certificate with no private key' {
        $publicOnly = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            , $script:Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

        { New-SignedInventoryRequest -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $publicOnly } |
            Should -Throw '*does not have an accessible private key*'
    }
}
