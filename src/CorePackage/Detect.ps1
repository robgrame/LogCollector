#Requires -Version 5.1
<#
.SYNOPSIS
Intune detection script for the LogCollector core package.
.DESCRIPTION
Writes one line and exits 0 only when this exact version is installed, importable by name
and configured. Anything else exits 1 with no output, which Intune reads as not installed.

Detection deliberately imports the module rather than only checking that files exist: the
package's promise is that `Import-Module LogCollector.Client` works for any script, and a
present-but-unimportable module would otherwise be reported as a healthy install.
.NOTES
Version 1.6.0.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    $version = '1.6.0'
    $root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) "WindowsPowerShell\Modules\LogCollector.Client\$version"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { exit 1 }

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
        $owner = try { $acl.Owner.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { [string] $acl.Owner }
        return ($allowed -contains $owner)
    }
    # The parent is included: create/delete-child rights there allow the whole version
    # directory to be swapped for another, whatever the version directory's own ACL says.
    if (-not (Test-TrustedPath -Path (Split-Path $root -Parent))) { exit 1 }
    if (-not (Test-TrustedPath -Path $root)) { exit 1 }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        if (-not (Test-TrustedPath -Path $item.FullName)) { exit 1 }
    }

    $manifestPath = Join-Path $root 'LogCollector.Client.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { exit 1 }
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    if ($manifest.Version.ToString() -ne $version) { exit 1 }

    # Derived from the manifest rather than hard-coded, so adding a module file cannot leave
    # detection reporting a healthy install of an incomplete one.
    foreach ($file in $manifest.FileList) {
        if (-not (Test-Path -LiteralPath (Join-Path $root (Split-Path $file -Leaf)) -PathType Leaf)) { exit 1 }
    }

    $configuration = Join-Path $env:ProgramData 'LogCollector\Config\Endpoint.psd1'
    if (-not (Test-Path -LiteralPath $configuration -PathType Leaf)) { exit 1 }

    Import-Module $manifestPath -Force -ErrorAction Stop
    foreach ($command in @('Send-LogAnalyticsData', 'Send-LogCollectorData', 'Get-LogCollectorEndpointConfiguration')) {
        if (-not (Get-Command $command -Module LogCollector.Client -ErrorAction SilentlyContinue)) { exit 1 }
    }
    # Reads through the ACL check, so a configuration a user could have rewritten is not
    # reported as installed and Intune remediates it.
    $endpoint = (Get-LogCollectorEndpointConfiguration).FrontendUrl
    if (-not $endpoint) { exit 1 }

    Write-Output "LogCollector core $version installed; endpoint $endpoint."
    exit 0
}
catch {
    exit 1
}
