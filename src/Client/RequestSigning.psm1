<#
.SYNOPSIS
    IDA-SIGNATURE-V1 request signing for the LogCollector agent.

.DESCRIPTION
    Signs a canonical representation of the HTTP method, path, timestamp, nonce
    and SHA-256 hash of the exact UTF-8 body bytes, using the private key of the
    mTLS client certificate.

    Why a body signature on top of mTLS: App Service terminates TLS at the edge
    and re-presents the client certificate to the app as a header. The TLS
    handshake therefore proves possession only to the front end, not to the
    function. The signature re-establishes that binding end to end, and pins the
    body, timestamp and nonce along with it - which is what makes the anti-replay
    check meaningful.

    The canonical string below MUST stay byte-identical to
    RequestSignatureVerifier.BuildCanonicalRequest in src\Shared. Any change is a
    breaking protocol change and needs a new version token.

.NOTES
    Windows PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

$script:ProtocolVersion = 'IDA-SIGNATURE-V1'
$script:RsaAlgorithm = 'RSA-PKCS1-SHA256'
$script:EcdsaAlgorithm = 'ECDSA-SHA256'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

function Get-SignedRequestCanonicalText {
    <#
    .SYNOPSIS
        Builds the canonical string that is signed and verified.
    .OUTPUTS
        [string] Six LF-separated lines: version, method, path, timestamp, nonce,
        base64(SHA-256(body)).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [DateTimeOffset] $Timestamp,
        [Parameter(Mandatory)] [Guid] $Nonce,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $BodyBytes
    )

    $normalizedPath = $Path.Trim()
    if (-not $normalizedPath) { $normalizedPath = '/' }
    if (-not $normalizedPath.StartsWith('/')) { $normalizedPath = "/$normalizedPath" }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bodyHash = [Convert]::ToBase64String($sha.ComputeHash($BodyBytes))
    }
    finally {
        $sha.Dispose()
    }

    @(
        $script:ProtocolVersion
        $Method.Trim().ToUpperInvariant()
        $normalizedPath
        $Timestamp.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $Nonce.ToString('D').ToLowerInvariant()
        $bodyHash
    ) -join "`n"
}

function New-SignedInventoryRequest {
    <#
    .SYNOPSIS
        Produces the body bytes and headers for a signed submission.
    .DESCRIPTION
        A fresh timestamp and nonce are generated on every call. That is required,
        not incidental: a retry (or a spool drain hours later) must re-sign, since
        the server rejects both stale timestamps and repeated nonces.
    .OUTPUTS
        [pscustomobject] with BodyBytes and Headers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $Uri,
        [Parameter(Mandatory)] [string] $Body,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [string] $Method = 'POST'
    )

    if (-not $Certificate.HasPrivateKey) {
        throw 'The client certificate does not have an accessible private key.'
    }

    $timestamp = [DateTimeOffset]::UtcNow
    $nonce = [Guid]::NewGuid()
    $bodyBytes = $script:Utf8NoBom.GetBytes($Body)

    $canonical = Get-SignedRequestCanonicalText `
        -Method $Method `
        -Path $Uri.AbsolutePath `
        -Timestamp $timestamp `
        -Nonce $nonce `
        -BodyBytes $bodyBytes

    $canonicalBytes = $script:Utf8NoBom.GetBytes($canonical)

    $algorithm = $null
    $signature = $null

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if ($rsa) {
        try {
            $algorithm = $script:RsaAlgorithm
            $signature = $rsa.SignData(
                $canonicalBytes,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        }
        finally {
            $rsa.Dispose()
        }
    }
    else {
        $ecdsa = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Certificate)
        if (-not $ecdsa) {
            throw 'The client certificate uses an unsupported private-key algorithm.'
        }
        try {
            $algorithm = $script:EcdsaAlgorithm
            $signature = $ecdsa.SignData($canonicalBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        }
        finally {
            $ecdsa.Dispose()
        }
    }

    # No x-functions-key and no shared secret: the certificate is the credential.
    [pscustomobject]@{
        BodyBytes = $bodyBytes
        Headers   = @{
            'X-Request-Timestamp'           = $timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            'X-Request-Nonce'               = $nonce.ToString('D')
            'X-Request-Signature-Version'   = $script:ProtocolVersion
            'X-Request-Signature-Algorithm' = $algorithm
            'X-Request-Signature'           = [Convert]::ToBase64String($signature)
        }
    }
}

Export-ModuleMember -Function Get-SignedRequestCanonicalText, New-SignedInventoryRequest
