<#
.SYNOPSIS
    Device identity and client-certificate selection for the LogCollector agent.

.DESCRIPTION
    Resolves the Entra (Azure AD) device id for the local machine and selects the
    certificate used for mTLS and IDA-SIGNATURE-V1 body signing.

    Two independent certificate tiers are considered, in order:

      1. Enterprise PKI - certificates issued by the corporate CA(s), optionally
         narrowed by -IssuerLike. Preferred, because the enterprise controls
         issuance policy and revocation.

      2. Intune enrollment - the MDM enrollment certificate, identified by
         carrying the Entra device id in the MDM enrollment OID
         1.2.840.113556.5.25.

    The Intune tier is deliberately NOT narrowed by -IssuerLike. IssuerLike is
    normally pinned to the enterprise CA, so applying it to the fallback would
    filter out the very certificate the fallback exists to find, and a device
    with no PKI certificate could never authenticate. Nothing is weakened:
    the identity binding comes from the OID payload, and the frontend
    independently validates the presented chain against its own explicitly
    configured Intune trust anchors before honouring that binding.

    All store, registry and dsregcmd access goes through cmdlets that Pester can
    mock, so selection logic is unit-testable off-box.

.NOTES
    Windows PowerShell 5.1 compatible. No external dependencies.
#>

Set-StrictMode -Version Latest

$script:ClientAuthEku = '1.3.6.1.5.5.7.3.2'
$script:IntuneEnrollmentOid = '1.2.840.113556.5.25'

function Get-EntraDeviceId {
    <#
    .SYNOPSIS
        Returns the Entra device id GUID for the local machine.
    .OUTPUTS
        [string] GUID in registry form (36 chars, lowercase hex with dashes).
    .NOTES
        Throws when the device is not Entra joined or registered. The whole
        security model binds to this value, so guessing a fallback would be worse
        than failing loudly.
    #>
    [CmdletBinding()]
    param()

    $output = & dsregcmd.exe /status 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        throw 'dsregcmd /status failed; cannot determine the Entra device id.'
    }

    $line = $output | Where-Object { $_ -match '^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})' } | Select-Object -First 1
    if ($line -and $line -match '([0-9a-fA-F-]{36})') {
        return ([guid]$Matches[1]).ToString()
    }

    throw 'EntraDeviceId not found (device is not Entra joined or registered).'
}

function Get-MdmEnrollmentId {
    <#
    .SYNOPSIS
        Returns the MDM enrollment id from the registry, for diagnostics only.
    .DESCRIPTION
        This is NOT an authorization input. It travels in the envelope purely so
        operators can correlate a submission with an enrollment record.
    #>
    [CmdletBinding()]
    param()

    $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (-not (Test-Path $root)) { return $null }

    foreach ($enrollment in (Get-ChildItem $root -ErrorAction SilentlyContinue |
                             Where-Object { $_.PSChildName -match '^[0-9A-Fa-f-]{36}$' })) {
        $properties = Get-ItemProperty $enrollment.PSPath -ErrorAction SilentlyContinue
        if (-not $properties) { continue }

        $names = $properties.PSObject.Properties.Name
        $hasProvider = ($names -contains 'ProviderID')
        $hasUpn = ($names -contains 'UPN')

        if ($hasProvider -and $properties.ProviderID -eq 'MS DM Server' -and $hasUpn -and $properties.UPN) {
            if (($names -contains 'DeviceClientId') -and $properties.DeviceClientId) {
                return [string]$properties.DeviceClientId
            }
            return [string]$enrollment.PSChildName
        }
    }

    return $null
}

function ConvertTo-ExactGuid {
    <#
    .SYNOPSIS
        Returns the canonical GUID string when the whole value is a GUID, else $null.
    .DESCRIPTION
        Deliberately strict. Substring extraction would accept values such as
        "<victimGuid>.attacker.example" and bind the client to another device.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parsed = [guid]::Empty
    if ([guid]::TryParse($Value.Trim(), [ref]$parsed)) { return $parsed.ToString() }
    return $null
}

function ConvertTo-IssuerPatternList {
    <#
    .SYNOPSIS
        Splits a semicolon-separated wildcard list into trimmed, non-empty patterns.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-IssuerMatch {
    <#
    .SYNOPSIS
        True when the issuer DN matches at least one wildcard pattern.
        An empty pattern list matches nothing; callers decide what that means.
    #>
    param([string]$Issuer, [string[]]$Patterns)

    if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
    foreach ($pattern in $Patterns) {
        if ($Issuer -like $pattern) { return $true }
    }
    return $false
}

function Get-CertificatePkiDeviceId {
    <#
    .SYNOPSIS
        Extracts an exact device-id GUID from SAN URI, SAN DNS or Subject CN.
    #>
    param($Certificate)

    $nameTypes = @(
        [System.Security.Cryptography.X509Certificates.X509NameType]::UrlName,
        [System.Security.Cryptography.X509Certificates.X509NameType]::DnsName,
        [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName
    )

    foreach ($nameType in $nameTypes) {
        $raw = $Certificate.GetNameInfo($nameType, $false)
        if ($nameType -eq [System.Security.Cryptography.X509Certificates.X509NameType]::UrlName `
            -and $raw -and $raw.StartsWith('urn:uuid:', [System.StringComparison]::OrdinalIgnoreCase)) {
            $raw = $raw.Substring(9)
        }

        $deviceId = ConvertTo-ExactGuid -Value $raw
        if ($deviceId) { return $deviceId }
    }

    return $null
}

function Get-IntuneEnrollmentDeviceId {
    <#
    .SYNOPSIS
        Extracts the Entra device id from the Intune MDM enrollment OID extension.
    .DESCRIPTION
        The extension is a DER OCTET STRING wrapping the 16 raw GUID bytes, i.e.
        0x04 0x10 followed by 16 bytes. Exactly one matching extension must be
        present; duplicates are ambiguous and are rejected.
    #>
    param($Certificate)

    $extensions = @($Certificate.Extensions | Where-Object { $_.Oid.Value -eq $script:IntuneEnrollmentOid })
    if ($extensions.Count -ne 1) { return $null }

    $raw = [byte[]]$extensions[0].RawData
    if ($raw.Length -ne 18 -or $raw[0] -ne 0x04 -or $raw[1] -ne 0x10) { return $null }

    $guidBytes = New-Object byte[] 16
    [Array]::Copy($raw, 2, $guidBytes, 0, 16)
    return (New-Object Guid (, $guidBytes)).ToString()
}

function Get-ClientCertificate {
    <#
    .SYNOPSIS
        Selects the certificate used for mTLS and request signing.
    .PARAMETER Thumbprint
        Exact SHA-1 thumbprint. An explicit thumbprint is itself the strongest
        pin, so it is matched against every candidate regardless of -IssuerLike.
    .PARAMETER SubjectLike
        Wildcard pattern matched against the Subject DN (enterprise tier only).
    .PARAMETER IssuerLike
        Semicolon-separated wildcard list matched against the Issuer DN.
    .PARAMETER EntraDeviceId
        Expected local Entra device id. Enables deterministic identity-aware
        selection and the Intune enrollment certificate fallback.
    .OUTPUTS
        [System.Security.Cryptography.X509Certificates.X509Certificate2]
    #>
    [CmdletBinding()]
    param(
        [string]$Thumbprint,
        [string]$SubjectLike,
        [string]$IssuerLike,
        [string]$EntraDeviceId
    )

    # @(...) at the call site: a function returning an empty array unrolls it to
    # $null, which then explodes on .Count under StrictMode.
    $issuerPatterns = @(ConvertTo-IssuerPatternList -Value $IssuerLike)
    $now = Get-Date

    foreach ($store in @('Cert:\LocalMachine\My', 'Cert:\CurrentUser\My')) {
        $all = @(Get-ChildItem $store -ErrorAction SilentlyContinue |
                 Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt $now -and $_.NotBefore -le $now })

        $all = @($all | Where-Object {
            $ekus = $_.EnhancedKeyUsageList
            (-not $ekus) -or ($ekus | Where-Object { $_.ObjectId -eq $script:ClientAuthEku })
        })

        Write-Verbose ("Get-ClientCertificate: store={0} usable={1}" -f $store, $all.Count)
        if ($all.Count -eq 0) { continue }

        $pkiCerts = if ($issuerPatterns.Count -gt 0) {
            , @($all | Where-Object { Test-IssuerMatch -Issuer $_.Issuer -Patterns $issuerPatterns })
        } else {
            , @($all)
        }

        $selected = $null

        if ($Thumbprint) {
            $selected = $all | Where-Object { $_.Thumbprint -eq $Thumbprint.ToUpper() } | Select-Object -First 1
        }
        elseif ($SubjectLike) {
            $selected = $pkiCerts | Where-Object { $_.Subject -like $SubjectLike } |
                        Sort-Object NotAfter -Descending | Select-Object -First 1
        }
        elseif ($EntraDeviceId) {
            $expected = ([guid]$EntraDeviceId).ToString()

            $selected = $pkiCerts |
                        Where-Object { (Get-CertificatePkiDeviceId -Certificate $_) -eq $expected } |
                        Sort-Object NotAfter -Descending | Select-Object -First 1

            if ($selected) {
                Write-Verbose ("Get-ClientCertificate: enterprise PKI certificate carries device id {0} (thumb={1})" -f $expected, $selected.Thumbprint)
            }
            else {
                Write-Verbose ("Get-ClientCertificate: no PKI certificate carries device id {0}; trying the Intune enrollment certificate" -f $expected)
                $selected = $all |
                            Where-Object { (Get-IntuneEnrollmentDeviceId -Certificate $_) -eq $expected } |
                            Sort-Object NotAfter -Descending | Select-Object -First 1
                if ($selected) {
                    Write-Verbose ("Get-ClientCertificate: Intune enrollment certificate matched (thumb={0})" -f $selected.Thumbprint)
                }
            }
        }
        else {
            # No identity selector at all: IssuerLike is the only trust signal we
            # have, so it stays authoritative - no unfiltered fallback here.
            $selected = $pkiCerts | Sort-Object NotAfter -Descending | Select-Object -First 1
        }

        if ($selected) { return $selected }
    }

    throw 'No usable client certificate found (needs a private key, Client Authentication EKU, and a device-id binding).'
}

function Get-DeviceIdentitySnapshot {
    <#
    .SYNOPSIS
        Resolves the identity fields carried in every inventory envelope.
    .OUTPUTS
        [pscustomobject] with EntraDeviceId, DeviceName, IntuneDeviceId.
    #>
    [CmdletBinding()]
    param()

    $intuneId = $null
    try { $intuneId = Get-MdmEnrollmentId } catch { $intuneId = $null }

    [pscustomobject]@{
        EntraDeviceId  = Get-EntraDeviceId
        DeviceName     = [System.Environment]::MachineName
        IntuneDeviceId = $intuneId
    }
}

Export-ModuleMember -Function `
    Get-EntraDeviceId, `
    Get-MdmEnrollmentId, `
    Get-ClientCertificate, `
    Get-CertificatePkiDeviceId, `
    Get-IntuneEnrollmentDeviceId, `
    Get-DeviceIdentitySnapshot, `
    ConvertTo-ExactGuid, `
    ConvertTo-IssuerPatternList, `
    Test-IssuerMatch
