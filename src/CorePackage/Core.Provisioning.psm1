<#
.SYNOPSIS
Provisioning helpers shared by the core package installer and uninstaller.
.DESCRIPTION
The core package puts a module on every machine's PSModulePath and a configuration file
under ProgramData. Both are read by SYSTEM-scheduled work, so both must be writable only
by administrators: a user-writable module directory is arbitrary code execution as SYSTEM,
and a user-writable configuration redirects the fleet's telemetry. The hardening is done
here once so the installer and the uninstaller cannot drift apart.
.NOTES
Version 1.6.0.
#>
Set-StrictMode -Version Latest

$script:SystemSid = [Security.Principal.SecurityIdentifier] 'S-1-5-18'
$script:AdministratorsSid = [Security.Principal.SecurityIdentifier] 'S-1-5-32-544'
$script:UsersSid = [Security.Principal.SecurityIdentifier] 'S-1-5-32-545'
$script:TrustedInstallerSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'

function Get-LogCollectorModuleRoot {
    <#
    .SYNOPSIS
    Returns the machine-wide module directory for a given core package version.
    .DESCRIPTION
    Windows PowerShell 5.1 and PowerShell 7 both carry this path in PSModulePath, so
    installing here is what makes `Import-Module LogCollector.Client` work from any script
    without the script knowing an install path. The version subfolder is the standard
    layout, which lets a new version be staged beside the old one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Version)

    $base = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsPowerShell\Modules\LogCollector.Client'
    return (Join-Path $base $Version)
}

function New-LogCollectorMachineAcl {
    <#
    .SYNOPSIS
    Builds a protected DACL granting write access to administrators only.
    .DESCRIPTION
    The existing security descriptor is modified rather than replaced with a fresh one:
    a newly constructed DirectorySecurity marks every section dirty, including the SACL,
    so applying it demands SeSecurityPrivilege that the installer has no reason to need.

    Inheritance is disabled and every pre-existing explicit ACE is removed. Disabling
    inheritance alone is not enough, because it leaves explicit entries in place, so a
    directory that already granted users write access would keep granting it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Directory
    )

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    # $false: drop the inherited entries rather than converting them into explicit ones.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        if (-not $rule.IsInherited) { $null = $acl.RemoveAccessRuleSpecific($rule) }
    }
    $acl.SetOwner($script:AdministratorsSid)

    $inheritance = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    $rules = @(
        @{ Sid = $script:SystemSid; Rights = 'FullControl' }
        @{ Sid = $script:AdministratorsSid; Rights = 'FullControl' }
        # Every user must be able to read the module and the endpoint; neither holds a secret.
        @{ Sid = $script:UsersSid; Rights = 'ReadAndExecute' }
    )
    foreach ($rule in $rules) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $rule.Sid, $rule.Rights, $inheritance, 'None', 'Allow')))
    }
    return $acl
}

function Set-LogCollectorMachineAcl {
    <#
    .SYNOPSIS
    Applies the administrators-only DACL to a file or directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Path)

    $isDirectory = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    if (-not $PSCmdlet.ShouldProcess($Path, 'Restrict write access to administrators')) { return }
    Set-Acl -LiteralPath $Path -AclObject (New-LogCollectorMachineAcl -Path $Path -Directory:$isDirectory) -ErrorAction Stop
}

function Assert-LogCollectorMachineAcl {
    <#
    .SYNOPSIS
    Verifies that no non-administrator can write to, replace or take over a path.
    .DESCRIPTION
    Applying an ACL and assuming it took effect is not verification. This re-reads the
    security descriptor, so a failure to harden is an install failure rather than a silent
    weakness.

    Three things are checked, because any one of them alone can be defeated:
    the DACL must be protected, or an inherited allow ACE added later widens it silently;
    no non-administrator may hold a write, delete or take-ownership right, including a
    directory's DeleteSubdirectoriesAndFiles, which deletes children regardless of their
    own ACLs; and the owner must be trusted, because an owner can always rewrite the DACL.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $allowed = @($script:SystemSid.Value, $script:AdministratorsSid.Value, $script:TrustedInstallerSid)
    $writeRights = [Security.AccessControl.FileSystemRights] ('WriteData, AppendData, WriteAttributes, ' +
        'WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop

    if (-not $acl.AreAccessRulesProtected) {
        throw "'$Path' still inherits access rules after hardening, so its permissions are not self-contained."
    }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($rule.FileSystemRights -band $writeRights) -eq 0) { continue }
        $sid = try { $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { $rule.IdentityReference.Value }
        if ($allowed -notcontains $sid) {
            throw "'$Path' still grants write access to '$($rule.IdentityReference)' after hardening."
        }
    }
    $owner = try { $acl.Owner.Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { [string] $acl.Owner }
    if ($allowed -notcontains $owner) {
        throw "'$Path' is owned by '$($acl.Owner)', who can rewrite its permissions at will."
    }
}

function Write-LogCollectorEndpointConfiguration {
    <#
    .SYNOPSIS
    Writes the machine-wide endpoint configuration and hardens it.
    .DESCRIPTION
    Written to a temporary file in the same directory and moved into place, so a reader
    never observes a half-written configuration and a failed install never leaves a
    truncated file that would be parsed as a valid but wrong endpoint.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [hashtable] $Configuration
    )

    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    # Both levels, not just the leaf: create/delete-child rights on either directory let an
    # unprivileged user replace Endpoint.psd1 outright, whatever the file's own ACL says,
    # and the endpoint decides where every script on the machine sends its telemetry.
    foreach ($level in @((Split-Path $directory -Parent), $directory)) {
        Set-LogCollectorMachineAcl -Path $level
        if (-not $WhatIfPreference) { Assert-LogCollectorMachineAcl -Path $level }
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Generated by the LogCollector core package installer. Do not edit by hand.')
    $lines.Add('# Contains no secret: this device authenticates with its own certificate.')
    $lines.Add('@{')
    foreach ($key in ($Configuration.Keys | Sort-Object)) {
        $value = $Configuration[$key]
        $rendered = if ($value -is [bool]) { if ($value) { '$true' } else { '$false' } }
        elseif ($value -is [array]) {
            if ($value.Count -eq 0) { '@()' }
            else { '@(' + (($value | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ')' }
        }
        else { "'" + ([string]$value).Replace("'", "''") + "'" }
        $lines.Add(("    {0} = {1}" -f $key, $rendered))
    }
    $lines.Add('}')

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write endpoint configuration')) { return }
    $temporary = Join-Path $directory ('Endpoint.{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -LiteralPath $temporary -Value $lines -Encoding UTF8 -ErrorAction Stop
        Set-LogCollectorMachineAcl -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    Set-LogCollectorMachineAcl -Path $Path
    Assert-LogCollectorMachineAcl -Path $Path
}

Export-ModuleMember -Function Get-LogCollectorModuleRoot, Set-LogCollectorMachineAcl, `
    Assert-LogCollectorMachineAcl, Write-LogCollectorEndpointConfiguration
