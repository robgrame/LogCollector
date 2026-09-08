#Requires -Version 5.1
<#
.SYNOPSIS
Exercises the actual Windows client transport with an untrusted test certificate.
.NOTES
Version 1.0.1. Creates and removes one short-lived certificate in CurrentUser\My.
No inventory is accepted and no trust configuration is changed.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [Uri] $Endpoint)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'src\Client\InventoryClient.psm1') -Force -DisableNameChecking
Initialize-TlsDefaults
$certificate = New-SelfSignedCertificate -Subject 'CN=LogCollector-Untrusted-Smoke' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -Type Custom -KeyAlgorithm RSA -KeyLength 2048 `
    -KeyExportPolicy NonExportable -KeyUsage DigitalSignature `
    -TextExtension '2.5.29.37={text}1.3.6.1.5.5.7.3.2' `
    -NotBefore ([DateTime]::UtcNow.AddMinutes(-5)) -NotAfter ([DateTime]::UtcNow.AddHours(1))
$certificatePath = "Cert:\CurrentUser\My\$($certificate.Thumbprint)"
try {
    try {
        $missing = Invoke-WebRequest -Uri $Endpoint -Method Post -Body '{}' `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 60
        $missingStatus = [int]$missing.StatusCode
    }
    catch {
        if ($null -eq $_.Exception.Response) { throw }
        $missingStatus = [int]$_.Exception.Response.StatusCode
    }
    if ($missingStatus -ne 403) { throw "Expected edge rejection, received $missingStatus." }
    foreach ($size in @(10, 150000, 1000000)) {
        $body = '{"probe":"' + ('x' * $size) + '"}'
        $response = Invoke-InventoryHttpPost -Uri $Endpoint -Body $body `
            -Certificate $certificate -TimeoutSeconds 90
        if ([int]$response.StatusCode -ne 401) {
            throw "Untrusted certificate with $($body.Length) bytes received $($response.StatusCode), expected application 401. $($response.Message)"
        }
        Write-Output "Application rejected untrusted certificate: $($body.Length) bytes, HTTP 401."
    }
    $healthUri = [Uri]::new($Endpoint, '/api/health')
    $health = Invoke-RestMethod -Uri $healthUri -Certificate $certificate -TimeoutSec 60
    if ($health.status -ne 'ok') { throw 'Intake health is not OK.' }
    Write-Output 'Certificate-bearing health probe passed; no inventory was accepted.'
}
finally {
    $certificate.Dispose()
    Remove-Item -LiteralPath $certificatePath -DeleteKey
}
