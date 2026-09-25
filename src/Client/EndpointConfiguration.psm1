<#
.SYNOPSIS
Machine-wide endpoint configuration for every script that submits telemetry.
.DESCRIPTION
A calling script must not have to know the intake endpoint, and must never carry a
credential. One protected machine-wide file supplies the endpoint and the certificate
selection hints, so a script only names the table it writes to.

The file is written by the core package installer and is readable by all users but
writable only by SYSTEM and Administrators. It intentionally holds no secret: the client
authenticates with the device's own certificate, which never leaves the machine store.
.NOTES
Version 1.7.0. No network call, no privilege escalation and no state change on import.
#>
Set-StrictMode -Version Latest

$script:LegacyConfigurationRoot = Join-Path $env:ProgramData 'LogCollector\Config'
$script:ConfigurationFileName = 'Endpoint.psd1'

function Assert-LogCollectorNoReparseHierarchy {
    param([Parameter(Mandatory)] [string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $programData = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    if ($fullPath.StartsWith($programData + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($fullPath, $programData, [StringComparison]::OrdinalIgnoreCase)) {
        $current = $programData
        $relative = $fullPath.Substring($programData.Length).TrimStart('\')
    }
    else {
        $current = [IO.Path]::GetPathRoot($fullPath)
        $relative = $fullPath.Substring($current.Length)
    }
    foreach ($segment in @($relative.Split([char[]]'\', [StringSplitOptions]::RemoveEmptyEntries))) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.LinkType) {
            throw "LogCollector does not trust symbolic links, junctions or other reparse points: '$current'."
        }
    }
}

function Assert-LogCollectorCustomerName {
    param([Parameter(Mandatory)] [string] $CustomerName)

    $reserved = @('CON', 'PRN', 'AUX', 'NUL', 'CLOCK$',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    if ($CustomerName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\z' -or
        $CustomerName -cmatch '[. ]\z' -or
        ($CustomerName -split '\.')[0].ToUpperInvariant() -in $reserved) {
        throw "CustomerName '$CustomerName' is not usable as a folder name under %ProgramData%."
    }
}

function Get-LogCollectorDataRoot {
    <#
    .SYNOPSIS
    Returns the customer-scoped ProgramData root without creating it.
    #>
    [CmdletBinding()]
    param([string] $CustomerName)

    if (-not $CustomerName) {
        $configuration = Get-LogCollectorEndpointConfiguration
        if ($configuration.PSObject.Properties['DataRoot'] -and $configuration.DataRoot) {
            return [string] $configuration.DataRoot
        }
        $CustomerName = [string] $configuration.CustomerName
    }
    Assert-LogCollectorCustomerName -CustomerName $CustomerName
    return (Join-Path (Join-Path $env:ProgramData $CustomerName) 'LogCollector')
}

function Assert-LogCollectorEndpoint {
    <#
    .SYNOPSIS
    Rejects any intake URL that is not an exact, credential-free HTTPS intake route.
    .DESCRIPTION
    Single source of truth for endpoint shape: the spool path, the machine-wide
    configuration and every submission helper validate through this one function, so an
    endpoint accepted in one place can never be refused, or worse allowed, in another.
    #>
    param([Uri] $FrontendUrl)

    if ($null -eq $FrontendUrl -or -not $FrontendUrl.IsAbsoluteUri -or
        $FrontendUrl.Scheme -ne 'https' -or $FrontendUrl.UserInfo -or
        $FrontendUrl.Query -or $FrontendUrl.Fragment -or
        @('/api/submit', '/api/inventory') -cnotcontains $FrontendUrl.AbsolutePath -or
        $FrontendUrl.OriginalString -cnotmatch '\A(?i:https)://[^/\\?#]+/api/(?:submit|inventory)\z') {
        throw 'FrontendUrl must be an absolute HTTPS /api/submit or /api/inventory URL without credentials, query or fragment.'
    }
}

function Get-LogCollectorConfigurationPath {
    <#
    .SYNOPSIS
    Returns the machine-wide configuration file path without creating or reading it.
    #>
    [CmdletBinding()]
    param(
        [string] $CustomerName,
        [string] $ConfigurationRoot
    )

    if ($ConfigurationRoot) {
        return (Join-Path $ConfigurationRoot $script:ConfigurationFileName)
    }
    if ($CustomerName) {
        return (Join-Path (Join-Path (Get-LogCollectorDataRoot -CustomerName $CustomerName) 'Config') `
                $script:ConfigurationFileName)
    }

    $trustFailures = New-Object Collections.Generic.List[object]
    $customerCandidates = @(
        foreach ($customerDirectory in @(Get-ChildItem -LiteralPath $env:ProgramData -Directory -Force -ErrorAction Stop)) {
            $candidate = Join-Path $customerDirectory.FullName 'LogCollector\Config\Endpoint.psd1'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                try {
                    Assert-LogCollectorConfigurationTrust -Path $candidate
                    $candidate
                }
                catch {
                    $trustFailures.Add($_)
                    Write-Verbose "Ignoring untrusted LogCollector configuration candidate '$candidate': $($_.Exception.Message)"
                }
            }
        }
    )
    if ($customerCandidates.Count -gt 1) {
        throw (("Multiple customer-scoped LogCollector configurations were found: {0}. " +
                'Pass -CustomerName explicitly or remove the obsolete configuration.') -f
            ($customerCandidates -join ', '))
    }
    if ($customerCandidates.Count -eq 1) { return $customerCandidates[0] }

    $legacy = Join-Path $script:LegacyConfigurationRoot $script:ConfigurationFileName
    if (Test-Path -LiteralPath $legacy -PathType Leaf) { return $legacy }
    if ($trustFailures.Count -gt 0) { throw $trustFailures[0] }

    return $legacy
}

function Assert-LogCollectorConfigurationTrust {
    <#
    .SYNOPSIS
    Refuses a configuration file that a non-administrator could have rewritten.
    .DESCRIPTION
    The file names the endpoint that telemetry is sent to. If an unprivileged user could
    edit it, they could redirect every script on the machine to a host they control, so a
    writable-by-users file is treated as absent rather than trusted.

    The containing directories are checked as well as the file. Checking only the file is
    insufficient: create/delete-child rights on a parent directory let a user delete the
    file and drop in their own, with whatever ACL they choose, so a file-only check would
    happily trust the replacement.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    Assert-LogCollectorNoReparseHierarchy -Path $Path
    # SIDs, not names: on a non-English Windows the well-known names are localised.
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $writeRights = [Security.AccessControl.FileSystemRights] ('WriteData, AppendData, WriteAttributes, ' +
        'WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')

    $configDirectory = Split-Path $Path -Parent
    $dataRoot = Split-Path $configDirectory -Parent
    $subjects = @($dataRoot, $configDirectory, $Path)
    $customerRoot = Split-Path $dataRoot -Parent
    if (-not [string]::Equals($dataRoot, (Split-Path $script:LegacyConfigurationRoot -Parent),
            [StringComparison]::OrdinalIgnoreCase)) {
        $subjects = @($customerRoot) + $subjects
    }
    foreach ($subject in $subjects) {
        $acl = Get-Acl -LiteralPath $subject -ErrorAction Stop
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if (($rule.FileSystemRights -band $writeRights) -eq 0) { continue }
            try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $sid = $rule.IdentityReference.Value }
            if ($allowed -notcontains $sid) {
                throw ("'$subject' grants write access to '$($rule.IdentityReference)', so the endpoint in " +
                    "'$Path' cannot be trusted. Reinstall the LogCollector core package.")
            }
        }
        # GetOwner, not $acl.Owner: the latter is already a localised account-name string,
        # so Translate on it throws and no configuration would ever be readable.
        if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) {
            throw "'$subject' is owned by '$($acl.Owner)', not by SYSTEM or Administrators, so '$Path' cannot be trusted."
        }
    }
    Assert-LogCollectorNoReparseHierarchy -Path $Path
}

function Get-LogCollectorEndpointConfiguration {
    <#
    .SYNOPSIS
    Reads the machine-wide endpoint configuration installed by the core package.
    .DESCRIPTION
    Returns the endpoint and certificate-selection settings that Send-LogAnalyticsData
    and Send-LogCollectorData use when the caller does not name them explicitly.
    Throws a message naming the expected path when the core package is not installed,
    so a calling script fails with a cause rather than a null reference.
    .PARAMETER Path
    Override the configuration file, for testing. Its ACL is still verified.
    .PARAMETER SkipTrustCheck
    Skip the ACL verification. Intended for tests only; never use it on a device.
    .EXAMPLE
    (Get-LogCollectorEndpointConfiguration).FrontendUrl
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $SkipTrustCheck
    )

    if (-not $Path) { $Path = Get-LogCollectorConfigurationPath }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("LogCollector is not configured on this machine: '$Path' does not exist. " +
            'Install the LogCollector core package, or pass -FrontendUrl explicitly.')
    }
    if (-not $SkipTrustCheck) { Assert-LogCollectorConfigurationTrust -Path $Path }

    $beforeHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    if (-not $SkipTrustCheck) {
        Assert-LogCollectorConfigurationTrust -Path $Path
        $afterHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($beforeHash -cne $afterHash) {
            throw "Configuration '$Path' changed while it was being validated and cannot be trusted."
        }
    }
    if (-not $data.ContainsKey('FrontendUrl') -or -not $data.FrontendUrl) {
        throw "Configuration '$Path' does not define FrontendUrl."
    }
    Assert-LogCollectorEndpoint -FrontendUrl ([Uri] $data.FrontendUrl)

    $defaults = @{
        CertificateThumbprint        = ''
        CertificateSubjectLike       = ''
        CertificateIssuerLike        = ''
        PkiRootCaThumbprints         = @()
        PkiRootCaSubjects            = @()
        PkiIntermediateCaThumbprints = @()
        PkiIntermediateCaSubjects    = @()
        SubmissionEnabled            = $true
        Environment                  = ''
        CustomerName                 = ''
    }
    foreach ($key in $defaults.Keys) {
        if (-not $data.ContainsKey($key)) { $data[$key] = $defaults[$key] }
    }
    if ($data.CustomerName) {
        Assert-LogCollectorCustomerName -CustomerName ([string] $data.CustomerName)
        $expectedPath = Get-LogCollectorConfigurationPath -CustomerName ([string] $data.CustomerName)
        $legacyPath = Join-Path $script:LegacyConfigurationRoot $script:ConfigurationFileName
        $fullPath = [IO.Path]::GetFullPath($Path)
        $programDataPrefix = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\') + '\'
        if ($fullPath.StartsWith($programDataPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($fullPath, [IO.Path]::GetFullPath($expectedPath),
                [StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($fullPath, [IO.Path]::GetFullPath($legacyPath),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Configuration '$Path' does not match CustomerName '$($data.CustomerName)'."
        }
    }
    $data['ConfigurationPath'] = $Path
    $data['DataRoot'] = if ($data.CustomerName) {
        Get-LogCollectorDataRoot -CustomerName ([string] $data.CustomerName)
    } else { Split-Path (Split-Path $Path -Parent) -Parent }
    return [pscustomobject] $data
}

Export-ModuleMember -Function Get-LogCollectorConfigurationPath, Get-LogCollectorEndpointConfiguration, `
    Get-LogCollectorDataRoot, Assert-LogCollectorEndpoint
