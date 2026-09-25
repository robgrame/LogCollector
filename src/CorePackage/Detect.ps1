#Requires -Version 5.1
<#
.SYNOPSIS
Intune detection script for the LogCollector core package.
.DESCRIPTION
Writes one line and exits 0 only when this exact version is installed, importable by name
and configured. Anything else writes a non-sensitive reason code and exits 1, which Intune
reads as not installed.

Detection deliberately imports the module rather than only checking that files exist: the
package's promise is that `Import-Module LogCollector.Client` works for any script, and a
present-but-unimportable module would otherwise be reported as a healthy install.
.NOTES
Version 1.10.2.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedConfigurationBase64 = '__LOGCOLLECTOR_CORE_EXPECTED_CONFIGURATION_BASE64__'

function Write-CoreDetectionFailure {
    param([Parameter(Mandatory)] [string] $Reason)
    Write-Output "LogCollector core not detected: $Reason"
    exit 1
}

function Test-ExpectedLogCollectorConfiguration {
    param(
        [Parameter(Mandatory)] [object] $Actual,
        [Parameter(Mandatory)] [object] $Expected
    )

    foreach ($key in @('FrontendUrl', 'Environment', 'CustomerName', 'PackageVersion',
            'CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike')) {
        $actualProperty = $Actual.PSObject.Properties[$key]
        $expectedProperty = $Expected.PSObject.Properties[$key]
        if (-not $actualProperty -or -not $expectedProperty) { return $false }
        if ([string] $actualProperty.Value -cne [string] $expectedProperty.Value) { return $false }
    }

    $actualSubmission = $Actual.PSObject.Properties['SubmissionEnabled']
    $expectedSubmission = $Expected.PSObject.Properties['SubmissionEnabled']
    if (-not $actualSubmission -or -not $expectedSubmission) { return $false }
    if ([bool] $actualSubmission.Value -ne [bool] $expectedSubmission.Value) { return $false }

    foreach ($key in @('PkiRootCaThumbprints', 'PkiRootCaSubjects',
            'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
        $actualProperty = $Actual.PSObject.Properties[$key]
        $expectedProperty = $Expected.PSObject.Properties[$key]
        if (-not $actualProperty -or -not $expectedProperty) { return $false }

        $isThumbprint = $key -like '*Thumbprints'
        $actualValues = @($actualProperty.Value | ForEach-Object {
                $value = [string] $_
                if ($isThumbprint) { ($value -replace '[\s:]', '').ToUpperInvariant() }
                else { $value.Trim() }
            } | Sort-Object)
        $expectedValues = @($expectedProperty.Value | ForEach-Object {
                $value = [string] $_
                if ($isThumbprint) { ($value -replace '[\s:]', '').ToUpperInvariant() }
                else { $value.Trim() }
            } | Sort-Object)
        if (($actualValues -join "`0") -cne ($expectedValues -join "`0")) { return $false }
    }

    return $true
}

try {
    $version = '1.10.2'
    $root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) "WindowsPowerShell\Modules\LogCollector.Client\$version"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-CoreDetectionFailure -Reason 'ModuleDirectoryMissing'
    }

    # Detection runs as SYSTEM and is about to import this code, so it must establish that
    # only administrators can have written it BEFORE loading anything. The check is inlined
    # rather than imported from the directory under scrutiny, which would defeat the point.
    function Test-TrustedPath {
        param([string] $Path)
        $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        $writeRights = [Security.AccessControl.FileSystemRights] ('WriteData, AppendData, WriteAttributes, ' +
            'WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        # The installer protects every path it creates, and Assert-LogCollectorMachineAcl
        # rejects anything unprotected. Detection must agree, otherwise it reports healthy a
        # path that currently inherits safe rights but can silently gain a writable ACE.
        if (-not $acl.AreAccessRulesProtected) { return $false }
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if (($rule.FileSystemRights -band $writeRights) -eq 0) { continue }
            $sid = try { $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $rule.IdentityReference.Value }
            if ($allowed -notcontains $sid) { return $false }
        }
        # GetOwner, not $acl.Owner: the latter is already a localised account-name string,
        # so Translate on it fails and the check would compare a name against SIDs.
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        return ($allowed -contains $owner)
    }
    # The parent is included: create/delete-child rights there allow the whole version
    # directory to be swapped for another, whatever the version directory's own ACL says.
    if (-not (Test-TrustedPath -Path (Split-Path $root -Parent))) {
        Write-CoreDetectionFailure -Reason 'ModuleParentAclMismatch'
    }
    if (-not (Test-TrustedPath -Path $root)) {
        Write-CoreDetectionFailure -Reason 'ModuleDirectoryAclMismatch'
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        if (-not (Test-TrustedPath -Path $item.FullName)) {
            Write-CoreDetectionFailure -Reason 'ModuleContentAclMismatch'
        }
    }

    $manifestPath = Join-Path $root 'LogCollector.Client.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-CoreDetectionFailure -Reason 'ModuleManifestMissing'
    }
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    if ($manifest.Version.ToString() -ne $version) {
        Write-CoreDetectionFailure -Reason 'ModuleVersionMismatch'
    }

    # Derived from the manifest rather than hard-coded, so adding a module file cannot leave
    # detection reporting a healthy install of an incomplete one.
    foreach ($file in $manifest.FileList) {
        if (-not (Test-Path -LiteralPath (Join-Path $root (Split-Path $file -Leaf)) -PathType Leaf)) {
            Write-CoreDetectionFailure -Reason 'ModuleFileMissing'
        }
    }

    Import-Module $manifestPath -Force -ErrorAction Stop
    foreach ($command in @('Send-LogAnalyticsData', 'Send-LogCollectorData', 'Get-LogCollectorEndpointConfiguration',
            'Get-LogCollectorDataRoot', 'Write-CMTraceLog', 'Get-CMTraceLogPath', 'Get-CMTraceCustomerName')) {
        if (-not (Get-Command $command -Module LogCollector.Client -ErrorAction SilentlyContinue)) {
            Write-CoreDetectionFailure -Reason 'ModuleCommandMissing'
        }
    }
    # Reads through the ACL check, so a configuration a user could have rewritten is not
    # reported as installed and Intune remediates it.
    $installedConfiguration = Get-LogCollectorEndpointConfiguration
    if (-not (Test-Path -LiteralPath $installedConfiguration.ConfigurationPath -PathType Leaf)) {
        Write-CoreDetectionFailure -Reason 'EndpointConfigurationMissing'
    }
    $expectedPath = Join-Path $installedConfiguration.DataRoot 'Config\Endpoint.psd1'
    if (-not [string]::Equals($installedConfiguration.ConfigurationPath, $expectedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        Write-CoreDetectionFailure -Reason 'EndpointConfigurationPathMismatch'
    }
    if ($expectedConfigurationBase64 -notlike '__LOGCOLLECTOR_*__') {
        $expectedJson = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($expectedConfigurationBase64))
        $expectedConfiguration = $expectedJson | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-ExpectedLogCollectorConfiguration -Actual $installedConfiguration `
                    -Expected $expectedConfiguration)) {
            Write-CoreDetectionFailure -Reason 'ConfigurationMismatch'
        }
    }

    $endpoint = $installedConfiguration.FrontendUrl
    if (-not $endpoint) { Write-CoreDetectionFailure -Reason 'EndpointMissing' }

    Write-Output "LogCollector core $version installed; endpoint $endpoint."
    exit 0
}
catch {
    Write-CoreDetectionFailure -Reason "DetectionError=$($_.Exception.GetType().Name)"
}
