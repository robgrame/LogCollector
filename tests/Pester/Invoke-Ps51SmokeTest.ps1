[CmdletBinding()]
param([switch] $SkipSpool)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $SkipSpool) {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The spool smoke test requires an elevated shell. Use -SkipSpool only for the non-privileged signing test.'
    }
}

Import-Module (Join-Path $root 'src\Client\DeviceIdentity.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Client\RequestSigning.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Client\InventorySpool.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Client\InventoryClient.psm1') -Force -DisableNameChecking
Write-Host ('PSVersion = ' + $PSVersionTable.PSVersion)
Write-Host 'modules imported'

$ts = [DateTimeOffset]::new(2026, 1, 2, 3, 4, 5, 678, [TimeSpan]::Zero)
$n = [guid]'11111111-2222-3333-4444-555555555555'
$body = (New-Object System.Text.UTF8Encoding($false)).GetBytes('{"a":1}')
$c = Get-SignedRequestCanonicalText -Method 'post' -Path 'api/inventory' -Timestamp $ts -Nonce $n -BodyBytes $body
$lines = $c -split "`n"
Write-Host ('canonical lines = ' + $lines.Count)
Write-Host ('canonical[0] = ' + $lines[0])
Write-Host ('canonical[3] = ' + $lines[3])
if ($lines.Count -ne 6) { throw 'canonical form drifted' }
if ($lines[3] -ne '2026-01-02T03:04:05.6780000+00:00') { throw 'timestamp format drifted' }

$envelope = New-InventoryEnvelope -TableName 'InventoryWindows_CL' `
    -Records @(@{ RecordType = 'Hardware'; Model = 'X1' }) `
    -EntraDeviceId '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
$json = $envelope | ConvertTo-Json -Depth 24 -Compress
Write-Host ('envelope json length = ' + $json.Length)

if (-not $SkipSpool) {
$spool = Join-Path $env:ProgramData ('LogCollectorSmoke-' + [guid]::NewGuid().ToString('N'))
try {
$null = Save-SpoolEntry -Body $json -TableName 'InventoryWindows_CL' -SpoolDirectory $spool
$entries = @(Get-SpoolEntry -SpoolDirectory $spool)
Write-Host ('spool entries = ' + $entries.Count + ' bodyMatch = ' + ($entries[0].Body -eq $json))
if ($entries.Count -ne 1 -or $entries[0].Body -ne $json) { throw 'spool round trip failed' }

$lock = Enter-SpoolLock -SpoolDirectory $spool
$second = Enter-SpoolLock -SpoolDirectory $spool
Write-Host ('lock exclusive = ' + ($null -eq $second))
Exit-SpoolLock -LockStream $lock
if ($null -ne $second) {
    Exit-SpoolLock -LockStream $second
    throw 'Spool lock did not exclude a second writer.'
}
}
finally {
    if (Test-Path -LiteralPath $spool) {
        Remove-Item -LiteralPath $spool -Recurse -Force
    }
}
}

Write-Host ('retry delays = ' + ((1..4 | ForEach-Object {
    Get-RetryDelaySeconds -Attempt $_ -BaseDelaySeconds 5 -MaxDelaySeconds 300 -JitterFactor 1.0
}) -join ','))
Write-Host ('dispositions 202/429/401/400 = ' + ((202, 429, 401, 400 | ForEach-Object {
    Get-SubmissionDisposition -StatusCode $_
}) -join ','))

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
    (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName('CN=ps51-smoke')),
    $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))

$signed = New-SignedInventoryRequest -Uri ([Uri]'https://example.invalid/api/inventory') -Body $json -Certificate $cert
Write-Host ('signature headers = ' + (($signed.Headers.Keys | Sort-Object) -join ','))

$canonical = Get-SignedRequestCanonicalText -Method 'POST' -Path '/api/inventory' `
    -Timestamp ([DateTimeOffset]::Parse($signed.Headers['X-Request-Timestamp'])) `
    -Nonce ([guid]$signed.Headers['X-Request-Nonce']) `
    -BodyBytes $signed.BodyBytes
$pub = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
$ok = $pub.VerifyData(
    [System.Text.Encoding]::UTF8.GetBytes($canonical),
    [Convert]::FromBase64String($signed.Headers['X-Request-Signature']),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$pub.Dispose()
Write-Host ('signature verifies = ' + $ok)
if (-not $ok) { throw 'signature verification failed under PS 5.1' }

$cert.Dispose()
$rsa.Dispose()
if ($SkipSpool) {
    Write-Host 'PS 5.1 SIGNING SMOKE OK; privileged spool smoke explicitly skipped.'
}
else {
    Write-Host 'PS 5.1 SMOKE TEST OK'
}
