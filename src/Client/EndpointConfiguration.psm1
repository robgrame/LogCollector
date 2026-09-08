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
Version 1.6.0. No network call, no privilege escalation and no state change on import.
#>
Set-StrictMode -Version Latest

$script:ConfigurationRoot = Join-Path $env:ProgramData 'LogCollector\Config'
$script:ConfigurationFileName = 'Endpoint.psd1'

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
    param([string] $ConfigurationRoot = $script:ConfigurationRoot)
    return (Join-Path $ConfigurationRoot $script:ConfigurationFileName)
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

    # SIDs, not names: on a non-English Windows the well-known names are localised.
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $writeRights = [Security.AccessControl.FileSystemRights] ('WriteData, AppendData, WriteAttributes, ' +
        'WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')

    $configDirectory = Split-Path $Path -Parent
    foreach ($subject in @((Split-Path $configDirectory -Parent), $configDirectory, $Path)) {
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
        if ($trusted -notcontains $acl.Owner.Translate([Security.Principal.SecurityIdentifier]).Value) {
            throw "'$subject' is owned by '$($acl.Owner)', not by SYSTEM or Administrators, so '$Path' cannot be trusted."
        }
    }
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

    $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
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
    }
    foreach ($key in $defaults.Keys) {
        if (-not $data.ContainsKey($key)) { $data[$key] = $defaults[$key] }
    }
    $data['ConfigurationPath'] = $Path
    return [pscustomobject] $data
}

Export-ModuleMember -Function Get-LogCollectorConfigurationPath, Get-LogCollectorEndpointConfiguration, `
    Assert-LogCollectorEndpoint
