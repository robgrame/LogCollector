<#
.SYNOPSIS
Shared CMTrace-format file logging for every script on a managed endpoint.
.DESCRIPTION
Scripts deployed to a fleet each tended to invent their own log file, format and
location, which made a support request start with "where does this one write?".
This module gives every script one call, one format and one predictable path:

    %ProgramData%\<CustomerName>\<ApplicationName>\Logs\<ApplicationName>.log

Only the application name varies between the scripts of one customer, so an
engineer who knows the customer knows where to look for anything.

The format is CMTrace/OneTrace, so the log opens in the tool support engineers
already use on a managed Windows estate, with severity colouring and the
component, thread and source-line columns populated.

Design rules that make this safe rather than a liability:

  * Protected directories. %ProgramData% lets any user create a folder and own
    it, so an unprivileged user could pre-create the customer folder and then
    rewrite the logs an auditor later relies on. Directories are created with a
    protected DACL, and an existing tree that a non-administrator could write to
    is refused rather than trusted or silently "repaired".

  * No injection. A CMTrace record is one line delimited by a fixed terminator.
    Newlines, control characters and the terminator itself are neutralised in
    the message, so no caller can forge extra records or corrupt the file.

  * Bounded growth. Size-based rotation with a fixed number of numbered slots.
    A chatty script running every five minutes must not fill the system drive.

  * One writer at a time, across processes. Rotation and the append are one
    transaction held under an exclusive lock file, so two scheduled tasks
    logging at the same moment can neither interleave half-written lines nor
    rotate the same numbered slots on top of each other.
.NOTES
Version 1.7.1. No network call and no state change on import.
Windows PowerShell 5.1 compatible.
#>
Set-StrictMode -Version Latest

# Get-LogCollectorEndpointConfiguration lives in a sibling module. Importing it here rather
# than relying on the root module's import order means this module works when imported on
# its own, and a genuine wiring mistake surfaces at import instead of being mistaken at
# runtime for an unconfigured machine.
Import-Module (Join-Path $PSScriptRoot 'EndpointConfiguration.psm1') -Scope Local -DisableNameChecking

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$script:LockTimeoutMilliseconds = 10000
$script:MaxMessageLength = 8192

# SIDs, not names: on a non-English Windows the well-known names are localised.
$script:TrustedSids = @(
    'S-1-5-18',                                                             # SYSTEM
    'S-1-5-32-544',                                                         # Administrators
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'        # TrustedInstaller
)

# Reserved DOS device names remain reserved as path segments, with or without an
# extension: creating "...\CON\Logs" does not fail, it talks to a device.
$script:ReservedNames = @(
    'CON', 'PRN', 'AUX', 'NUL', 'CLOCK$',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)

$script:LevelTypes = @{ Verbose = 1; Debug = 1; Info = 1; Warning = 2; Error = 3 }

$script:AclExtensionsResolved = $false
$script:AclExtensions = $null

function Get-CMTraceAclExtensionType {
    <#
    .SYNOPSIS
    Resolves the .NET Core helper that applies a security descriptor while creating.
    .DESCRIPTION
    On PowerShell 7 the type lives in an assembly that is not necessarily loaded yet, so the
    plain name does not resolve until something forces the load. The assembly-qualified name
    is tried first for that reason. Windows PowerShell 5.1 has no such type and does not need
    it, so a null result there is expected rather than an error.
    #>
    if ($script:AclExtensionsResolved) { return $script:AclExtensions }
    foreach ($name in @('System.IO.FileSystemAclExtensions, System.IO.FileSystem.AccessControl',
            'System.IO.FileSystemAclExtensions')) {
        $type = [Type]::GetType($name, $false)
        if ($type) { $script:AclExtensions = $type; break }
    }
    $script:AclExtensionsResolved = $true
    return $script:AclExtensions
}

function Assert-CMTraceNameSegment {
    <#
    .SYNOPSIS
    Rejects a customer or application name that is not a safe single path segment.
    .DESCRIPTION
    Both names come from a caller and become directory names. Without this, a name
    of '..\..\Windows\System32' would place the log outside the intended tree, and a
    trailing dot or space would produce a path that Win32 silently normalises to a
    different one than the ACL was applied to.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Name,
        [Parameter(Mandatory)] [string] $Purpose
    )

    if ($Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\z') {
        throw ("$Purpose '$Name' is not usable as a folder name: use 1-64 characters, starting with a " +
            'letter or digit, containing only letters, digits, space, dot, underscore or hyphen.')
    }
    if ($Name -cmatch '[. ]\z') {
        throw "$Purpose '$Name' must not end with a dot or a space: Windows would silently resolve a different path."
    }
    if (($Name -split '\.')[0].ToUpperInvariant() -in $script:ReservedNames) {
        throw "$Purpose '$Name' is a reserved Windows device name."
    }
}

function ConvertTo-CMTraceNameSegment {
    <#
    .SYNOPSIS
    Normalises a derived name into a segment Assert-CMTraceNameSegment accepts.
    .DESCRIPTION
    Only used for names the module derives itself, such as a calling script's file
    name. A caller-supplied name is validated and rejected rather than rewritten, so
    that nobody silently logs somewhere other than where they asked to.

    A truncated name keeps a short hash of the original, so two long script names
    that share a prefix do not quietly end up sharing one log.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Name)

    # -creplace, not -replace: the default is case-insensitive and applies Unicode case
    # equivalence, so a character such as the Kelvin sign matches the ASCII class and
    # survives into a name the case-sensitive validator then rejects.
    $candidate = ($Name -creplace '[^A-Za-z0-9 ._-]', '-').Trim()
    $candidate = $candidate -creplace '\A[^A-Za-z0-9]+', ''
    $candidate = $candidate.TrimEnd('. ')
    if (-not $candidate) { return 'PowerShell' }
    # A reserved device name is still reserved as a folder, so it is prefixed rather
    # than dropped: 'PRN.ps1' must remain distinguishable from any other script.
    # Prefixed before the length cap, or the prefix could push the result back over it.
    if (($candidate -split '\.')[0].ToUpperInvariant() -in $script:ReservedNames) { $candidate = 'Script-' + $candidate }
    if ($candidate.Length -gt 64) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($script:Utf8NoBom.GetBytes($Name))) }
        finally { $sha.Dispose() }
        $candidate = $candidate.Substring(0, 55).TrimEnd('. ') + '-' + $hash.Replace('-', '').Substring(0, 8)
    }
    # Total by construction: a name that would still be refused becomes the generic one
    # rather than failing the caller's write, which is the whole point of a derived name.
    try { Assert-CMTraceNameSegment -Name $candidate -Purpose 'ApplicationName' }
    catch { return 'PowerShell' }
    return $candidate
}

function New-CMTraceSecurityDescriptor {
    param(
        [switch] $Directory,
        [switch] $Lock
    )

    # SYSTEM and Administrators write; Users read so support can collect a log
    # without elevation. Protected (P), so nothing is inherited from ProgramData.
    if ($Directory) {
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)')
    }
    elseif ($Lock) {
        # No Users ACE at all. The lock is opened denying all sharing, so a standard user
        # holding it open with any share mode would deny every elevated writer for the full
        # timeout and silently stop the whole device from logging. Nothing needs to read it:
        # it carries no content, only the right to rotate and append.
        $security = New-Object System.Security.AccessControl.FileSecurity
        $security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
    }
    else {
        $security = New-Object System.Security.AccessControl.FileSecurity
        $security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)')
    }
    return $security
}

function New-CMTraceDirectoryWithSecurity {
    <#
    .SYNOPSIS
    Creates a directory with its descriptor applied atomically, on both PowerShell editions.
    .DESCRIPTION
    Creating and then hardening leaves a window in which the new directory is writable by
    users. Windows PowerShell 5.1 (.NET Framework) exposes DirectoryInfo.Create(security);
    PowerShell 7 (.NET Core) moved it to the FileSystemAclExtensions helper. The module is
    on PSModulePath for both, so both are handled rather than assuming one.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [Security.AccessControl.DirectorySecurity] $Security
    )

    $info = New-Object IO.DirectoryInfo -ArgumentList $Path
    if ($info.GetType().GetMethod('Create', [type[]] @([Security.AccessControl.DirectorySecurity]))) {
        $info.Create($Security)
        return
    }
    $extensions = Get-CMTraceAclExtensionType
    if (-not $extensions) { throw 'This PowerShell edition cannot create a directory with an explicit security descriptor.' }
    $null = $extensions::Create($info, $Security)
}

function New-CMTraceFileWithSecurity {
    <#
    .SYNOPSIS
    Creates a new file with its descriptor applied atomically and returns the open stream.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [Security.AccessControl.FileSecurity] $Security,
        [switch] $Exclusive
    )

    $rights = [Security.AccessControl.FileSystemRights]::Write
    $share = if ($Exclusive) { [IO.FileShare]::None } else { [IO.FileShare]::Read }
    $ctor = [IO.FileStream].GetConstructor([type[]] @(
            [string], [IO.FileMode], [Security.AccessControl.FileSystemRights],
            [IO.FileShare], [int], [IO.FileOptions], [Security.AccessControl.FileSecurity]))
    if ($ctor) {
        return $ctor.Invoke(@(
                $Path, [IO.FileMode]::CreateNew, $rights, $share, 4096,
                [IO.FileOptions]::None, $Security))
    }
    $extensions = Get-CMTraceAclExtensionType
    if (-not $extensions) { throw 'This PowerShell edition cannot create a file with an explicit security descriptor.' }
    return $extensions::Create((New-Object IO.FileInfo -ArgumentList $Path), [IO.FileMode]::CreateNew,
        $rights, $share, 4096, [IO.FileOptions]::None, $Security)
}

function Assert-CMTraceTrustedPath {
    <#
    .SYNOPSIS
    Refuses a log path that a non-administrator could write to or has taken ownership of.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $writeRights = [Security.AccessControl.FileSystemRights] ('WriteData, AppendData, WriteAttributes, ' +
        'WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')

    # A junction or symlink planted by a user redirects the whole tree, and the ACL checked
    # below would be the target's, not the link's. Refuse rather than follow.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "'$Path' is a reparse point, so it can redirect the log elsewhere. Remove it and let the logger recreate it."
    }

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) {
        throw ("'$Path' inherits its permissions, so a change on a parent directory can grant a user " +
            'write access to the log. Remove it and let the logger recreate it.')
    }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($rule.FileSystemRights -band $writeRights) -eq 0) { continue }
        try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { $sid = $rule.IdentityReference.Value }
        if ($script:TrustedSids -notcontains $sid) {
            throw ("'$Path' grants write access to '$($rule.IdentityReference)', so its log cannot be " +
                'trusted. Remove it and let the logger recreate it.')
        }
    }
    # GetOwner, not $acl.Owner: the latter is already a localised account-name string, so
    # Translate on it throws and every correctly hardened directory would be rejected.
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($script:TrustedSids -notcontains $owner) {
        throw ("'$Path' is owned by '$($acl.Owner)', not by SYSTEM or Administrators, so its log cannot " +
            'be trusted. Remove it and let the logger recreate it.')
    }
}

function Test-CMTraceElevated {
    <#
    .SYNOPSIS
    Reports whether this session can own and harden the log tree.
    #>
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function New-CMTraceDirectory {
    <#
    .SYNOPSIS
    Creates each level of the log tree with a protected DACL, or verifies an existing one.
    .DESCRIPTION
    Creation applies the descriptor atomically rather than creating and then hardening:
    between those two steps a squatter could open a handle that survives the ACL change.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $SkipTrustCheck
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        if (-not $SkipTrustCheck) { Assert-CMTraceTrustedPath -Path $Path }
        return
    }
    if (Test-Path -LiteralPath $Path) {
        throw "'$Path' exists but is not a directory, so the log tree cannot be created."
    }
    if ($SkipTrustCheck) {
        $null = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop
        return
    }
    try {
        New-CMTraceDirectoryWithSecurity -Path $Path -Security (New-CMTraceSecurityDescriptor -Directory)
    }
    catch {
        # A competing process creating the same directory surfaces as an IOException, and so
        # does an owner assignment refused for lack of privilege, so the two are told apart by
        # the resulting state rather than by exception type.
        if (Test-Path -LiteralPath $Path -PathType Container) {
            # Created by someone else in the meantime. Whatever they put there has to earn
            # trust below exactly like any pre-existing directory.
        }
        elseif (-not (Test-CMTraceElevated)) {
            # Assigning Administrators as owner needs an elevated or SYSTEM token. Say so:
            # the raw "This security ID may not be assigned as the owner" is unactionable.
            throw ("Creating the protected log directory '$Path' requires an elevated session or SYSTEM. " +
                "Run the script as administrator, or as a scheduled task running as SYSTEM. " +
                "Underlying error: $($_.Exception.Message)")
        }
        else { throw }
    }
    Assert-CMTraceTrustedPath -Path $Path
}

function Get-CMTraceProgramDataPath {
    <#
    .SYNOPSIS
    Resolves the system ProgramData directory without trusting the environment.
    .DESCRIPTION
    %ProgramData% is an ordinary environment variable, so a caller that controls the
    process environment could point the whole log tree at a directory it owns. The
    shell folder is asked instead, and the variable is only a last resort for a host
    that does not expose it.
    #>
    $path = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not $path) { $path = $env:ProgramData }
    return $path
}

$script:FinalPathResolver = $null

function Get-CMTraceFinalPathResolver {
    <#
    .SYNOPSIS
    Returns the compiled helper that asks the filesystem for a directory's real path.
    .DESCRIPTION
    Compiled on first use and cached, because Add-Type is slow and the module is
    imported by every script on the machine.
    #>
    if ($null -ne $script:FinalPathResolver) { return $script:FinalPathResolver }
    if (-not ('LogCollectorFinalPath' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class LogCollectorFinalPath
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(IntPtr hFile, StringBuilder lpszFilePath,
        uint cchFilePath, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    public static string Resolve(string path)
    {
        // OPEN_EXISTING with FILE_FLAG_BACKUP_SEMANTICS is what lets a directory be opened,
        // and no access rights are requested because only the handle's identity is needed.
        IntPtr handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle == new IntPtr(-1)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        try
        {
            StringBuilder buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length >= buffer.Capacity)
            {
                buffer = new StringBuilder((int)length + 1);
                length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            }
            if (length == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            return buffer.ToString();
        }
        finally { CloseHandle(handle); }
    }
}
'@
    }
    $script:FinalPathResolver = [LogCollectorFinalPath]
    return $script:FinalPathResolver
}

function Get-CMTraceFinalPath {
    <#
    .SYNOPSIS
    Returns the path the filesystem itself reports for an existing directory.
    .DESCRIPTION
    Comparing names cannot tell whether two paths reach one directory: a SUBST drive,
    a mapped drive, a junction and an 8.3 short name all name a target under a
    different spelling, and only SUBST and mapped drives are invisible to a reparse
    point check because they are DOS device mappings rather than filesystem links.
    Opening a handle and asking the kernel where it landed collapses every one of
    those aliases to the same answer. Failure is an error rather than a fallback,
    so an unresolvable path is refused instead of trusted.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $resolver = Get-CMTraceFinalPathResolver
    try { $final = $resolver::Resolve($Path) }
    catch {
        throw "Unable to determine the real location of '$Path': $($_.Exception.Message)"
    }
    if ($final.StartsWith('\\?\UNC\', [StringComparison]::Ordinal) -or
        $final.StartsWith('\\.\UNC\', [StringComparison]::Ordinal)) {
        throw "Path '$Path' resolves to the network location '$final'. A custom log root must be a local directory."
    }
    if ($final.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $final.StartsWith('\\.\', [StringComparison]::Ordinal)) {
        $final = $final.Substring(4)
    }
    if ($final -notmatch '^[A-Za-z]:[\\/]') {
        throw "Path '$Path' resolves to '$final', which is not a local drive path."
    }
    return $final
}

function Assert-CMTraceNoReparsePoint {
    <#
    .SYNOPSIS
    Refuses a path any of whose existing components is a junction or symlink.
    .DESCRIPTION
    Two paths that look unrelated can name one directory when a component redirects,
    so a comparison of resolved names is only meaningful once neither side redirects.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Because
    )

    $probe = $Path
    while ($probe) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Because passes through the reparse point '$probe', which can redirect it into the shared log tree."
            }
        }
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
}

function Resolve-CMTraceCustomRoot {
    <#
    .SYNOPSIS
    Resolves a caller-supplied log root to a real local path, or refuses it.
    .DESCRIPTION
    A custom root exists only so tests can write outside the shared location. Paired
    with -SkipTrustCheck it provisions an unprotected tree, so it must not be able to
    name the canonical ProgramData tree by any alias: a lexical comparison alone is
    fooled by an 8.3 short name such as C:\PROGRA~3, by a junction pointing at
    ProgramData, and by a UNC alias such as \\localhost\c$\ProgramData.

    The path is therefore required to be a plain local rooted path, every existing
    component is required not to be a reparse point, and the deepest existing
    component is resolved through a filesystem handle, which collapses short names
    and DOS device mappings alike, before the comparison.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ProgramData
    )

    if ($Path -match '^[\\/][\\/]') {
        throw "LogRoot '$Path' is a UNC or device path. A custom log root must be a plain local directory."
    }
    if ($Path -match '^[A-Za-z]:[^\\/]') {
        throw ("LogRoot '$Path' is drive-relative, so it resolves against the current directory. " +
            'A custom log root must be an absolute local path.')
    }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw "LogRoot '$Path' is not rooted. A custom log root must be an absolute local path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:[\\/]') {
        throw "LogRoot '$Path' does not resolve to a local drive. A custom log root must be a plain local directory."
    }

    # Walk down from the drive so the deepest existing component can be resolved through
    # the filesystem, and so a junction anywhere along the way is refused rather than
    # silently followed into the shared tree.
    $existing = $full
    while ($existing -and -not (Test-Path -LiteralPath $existing)) { $existing = Split-Path $existing -Parent }
    if (-not $existing) { throw "LogRoot '$Path' has no existing parent directory." }
    Assert-CMTraceNoReparsePoint -Path $existing -Because "LogRoot '$Path'"
    # Asks the filesystem where the deepest existing component really is, which collapses
    # an 8.3 alias such as C:\PROGRA~3 and a DOS device mapping such as a SUBST drive.
    $resolvedExisting = Get-CMTraceFinalPath -Path $existing
    $resolved = $resolvedExisting + $full.Substring($existing.Length)

    $separators = @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $resolved = $resolved.TrimEnd($separators)
    # Fail closed if the shared location is itself reached through a junction: comparing
    # lexical paths could not then tell 'D:\ProgramData' from a 'C:\ProgramData' that
    # redirects to it, and the custom root would land in the shared tree after all.
    Assert-CMTraceNoReparsePoint -Path $ProgramData -Because "The shared log location '$ProgramData'"
    $canonical = (Get-CMTraceFinalPath -Path $ProgramData).TrimEnd($separators)
    if ($resolved.Equals($canonical, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved.StartsWith($canonical + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("LogRoot '$Path' resolves inside '$canonical'. A custom root exists to keep tests out of the " +
            'shared location; it must not be used to write an unprotected tree there.')
    }
    return $resolved
}

function Get-CMTraceLogPath {
    <#
    .SYNOPSIS
    Returns the CMTrace log path for a customer and application without creating it.
    .DESCRIPTION
    Use this to tell a user where a script logs, or to attach the log to a support
    bundle, without taking a write lock or provisioning anything.
    .PARAMETER ApplicationName
    The script, package or application the log belongs to. This is the only segment
    that differs between the logs of one customer.
    .PARAMETER CustomerName
    The customer folder under %ProgramData%. Defaults to the CustomerName in the
    machine-wide configuration written by the core package installer.
    .PARAMETER LogRoot
    The root the customer folder is created under. Defaults to the system's own
    ProgramData path.
    .EXAMPLE
    Get-CMTraceLogPath -ApplicationName 'CustomInventory' -CustomerName 'Contoso'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ApplicationName,
        [string] $CustomerName,
        [string] $LogRoot
    )

    if (-not $LogRoot) { $LogRoot = Get-CMTraceProgramDataPath }
    if (-not $CustomerName) { $CustomerName = Get-CMTraceCustomerName }
    Assert-CMTraceNameSegment -Name $ApplicationName -Purpose 'ApplicationName'
    Assert-CMTraceNameSegment -Name $CustomerName -Purpose 'CustomerName'
    if (-not $LogRoot) { throw 'LogRoot is empty: the system ProgramData path could not be resolved.' }

    return (Join-Path (Join-Path (Join-Path (Join-Path $LogRoot $CustomerName) $ApplicationName) 'Logs') `
        ($ApplicationName + '.log'))
}

function Get-CMTraceCustomerName {
    <#
    .SYNOPSIS
    Resolves the default customer folder from the machine-wide configuration.
    .DESCRIPTION
    A script should not have to hard-code the customer it is deployed at. When the
    core package has been installed with a CustomerName, every script logs under it
    automatically; otherwise logging falls back to the product name so that a script
    on an unconfigured machine still logs somewhere predictable instead of failing.
    .PARAMETER ConfigurationPath
    Override the configuration file to read, for testing and for diagnosing a device.
    .PARAMETER SkipTrustCheck
    Skip the configuration ACL verification. Intended for tests only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ConfigurationPath,
        [switch] $SkipTrustCheck
    )

    try {
        $arguments = @{ ErrorAction = 'Stop' }
        if ($ConfigurationPath) { $arguments['Path'] = $ConfigurationPath }
        if ($SkipTrustCheck) { $arguments['SkipTrustCheck'] = $true }
        $configuration = Get-LogCollectorEndpointConfiguration @arguments
        if ($configuration.PSObject.Properties['CustomerName'] -and $configuration.CustomerName) {
            return [string] $configuration.CustomerName
        }
    }
    catch {
        # An absent or untrusted configuration must not stop a script from logging: the log
        # is often the only place the configuration problem will be recorded. A missing
        # command is a wiring fault, not an unconfigured machine, and is not swallowed.
        if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -and
            $_.Exception -is [Management.Automation.CommandNotFoundException]) {
            throw
        }
        Write-Verbose "Get-CMTraceCustomerName: falling back to 'LogCollector' ($($_.Exception.Message))"
    }
    return 'LogCollector'
}

function ConvertTo-CMTraceText {
    <#
    .SYNOPSIS
    Neutralises anything in a caller value that could forge or corrupt a record.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [switch] $Attribute
    )

    # A record is one line ended by a fixed terminator, so a newline or an embedded
    # terminator in the message would let a caller inject additional records.
    $text = $Value -replace '[\r\n]+', ' '
    $text = $text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
    $text = $text.Replace(']LOG]!>', ']LOG] !>')
    if ($Attribute) {
        # Attributes are double-quoted; a quote would end the attribute early.
        $text = $text -replace '["<>]', "'"
    }
    if ($text.Length -gt $script:MaxMessageLength) {
        $text = $text.Substring(0, $script:MaxMessageLength) + '...[truncated]'
    }
    return $text
}

function New-CMTraceRecord {
    <#
    .SYNOPSIS
    Formats one CMTrace record.
    .DESCRIPTION
    The time bias follows Win32_TimeZone.Bias, the convention the ConfigMgr client
    itself writes: UTC = local time + bias, so UTC+02:00 is written as -120.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Message,
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [int] $Type,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Source,
        [DateTimeOffset] $Timestamp = [DateTimeOffset]::Now
    )

    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $bias = [int] (-$Timestamp.Offset.TotalMinutes)
    $sign = if ($bias -lt 0) { '-' } else { '+' }
    $time = '{0}{1}{2:000}' -f $Timestamp.ToString('HH:mm:ss.fff', $invariant), $sign, [Math]::Abs($bias)
    $context = ''
    try { $context = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $context = '' }

    return ('<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}">' -f
        (ConvertTo-CMTraceText -Value $Message),
        $time,
        $Timestamp.ToString('MM-dd-yyyy', $invariant),
        (ConvertTo-CMTraceText -Value $Component -Attribute),
        (ConvertTo-CMTraceText -Value $context -Attribute),
        $Type,
        $PID,
        (ConvertTo-CMTraceText -Value $Source -Attribute))
}

function Invoke-CMTraceRotation {
    <#
    .SYNOPSIS
    Rotates the active log through a fixed set of numbered slots before it exceeds its quota.
    .DESCRIPTION
    Slots are a fixed numeric series rather than a wildcard enumeration, so rotation can
    never delete an unrelated file that happens to sit in the same directory.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int] $MaxFileBytes,
        [Parameter(Mandatory)] [int] $MaxArchives,
        [int] $IncomingBytes = 0
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $active = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($active.Length + $IncomingBytes -le $MaxFileBytes) { return }

    if ($MaxArchives -eq 0) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return
    }
    $last = '{0}.{1}' -f $Path, $MaxArchives
    if (Test-Path -LiteralPath $last -PathType Leaf) { Remove-Item -LiteralPath $last -Force -ErrorAction Stop }
    for ($slot = $MaxArchives - 1; $slot -ge 1; $slot--) {
        $source = '{0}.{1}' -f $Path, $slot
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Move-Item -LiteralPath $source -Destination ('{0}.{1}' -f $Path, ($slot + 1)) -Force -ErrorAction Stop
        }
    }
    Move-Item -LiteralPath $Path -Destination ($Path + '.1') -Force -ErrorAction Stop
}

function Get-CMTraceLockStream {
    <#
    .SYNOPSIS
    Takes the exclusive cross-process lock guarding one log's rotation and append.
    .DESCRIPTION
    Rotation renames the active file, so the active file cannot itself be the lock:
    the handle would follow the rename and two writers could still rotate the same
    numbered slots on top of each other. A separate zero-length lock file, opened
    denying all sharing, gives rotation and the append one owner at a time.

    The lock lives beside the log in the directory that has already been verified,
    and rotation only ever touches the numbered slots, so it is never rotated away.
    Its descriptor grants no access to Users: a standard user who could open it at
    all could hold it and stop every elevated writer on the device from logging.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $SkipTrustCheck
    )

    $lockPath = $Path + '.lock'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
                if (-not $SkipTrustCheck) { Assert-CMTraceTrustedPath -Path $lockPath }
                return [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            }
            if ($SkipTrustCheck) {
                return [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            }
            # Created with its descriptor rather than created and then hardened, so no
            # window exists in which a user could hold the lock hostage.
            return (New-CMTraceFileWithSecurity -Path $lockPath -Security (New-CMTraceSecurityDescriptor -Lock) -Exclusive)
        }
        catch [IO.IOException] {
            # 32/33 sharing violation and lock, 80/183 the file appeared underneath us.
            if (($_.Exception.HResult -band 0xffff) -notin @(32, 33, 80, 183)) { throw }
            if ($timer.ElapsedMilliseconds -ge $script:LockTimeoutMilliseconds) {
                throw [TimeoutException]::new("Timed out waiting for the log lock '$lockPath'.", $_.Exception)
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Write-CMTraceRecordToFile {
    <#
    .SYNOPSIS
    Rotates if needed and appends one record, as a single cross-process transaction.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Record,
        [Parameter(Mandatory)] [int] $MaxFileBytes,
        [Parameter(Mandatory)] [int] $MaxArchives,
        [switch] $SkipTrustCheck
    )

    $bytes = $script:Utf8NoBom.GetBytes($Record + "`r`n")
    if ($bytes.Length -gt $MaxFileBytes) {
        # Otherwise the quota is silently exceeded by every single write: rotation would
        # run on each call and still leave a file larger than the caller asked for.
        throw ("MaxFileBytes is $MaxFileBytes but one record is $($bytes.Length) bytes, so the log could " +
            'never stay within its quota. Raise MaxFileBytes or shorten the message.')
    }

    # Rotation and the append are one transaction: checking the size, renaming the numbered
    # slots and appending must not interleave with another process doing the same, or a
    # writer can rotate away the file another writer just created.
    $lock = Get-CMTraceLockStream -Path $Path -SkipTrustCheck:$SkipTrustCheck
    try {
        Invoke-CMTraceRotation -Path $Path -MaxFileBytes $MaxFileBytes -MaxArchives $MaxArchives `
            -IncomingBytes $bytes.Length

        # The lock serialises writers, but Users can read the log, and a reader that opens
        # it denying writers would otherwise fail the append outright. Retried while such a
        # reader holds it, rather than losing the record.
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            try {
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    if (-not $SkipTrustCheck) { Assert-CMTraceTrustedPath -Path $Path }
                    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                }
                elseif ($SkipTrustCheck) {
                    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                }
                else {
                    # Created with its descriptor rather than created and then hardened,
                    # so no window exists in which the new file is writable by a user.
                    $stream = New-CMTraceFileWithSecurity -Path $Path -Security (New-CMTraceSecurityDescriptor)
                }
                break
            }
            catch [IO.IOException] {
                # 32/33 sharing violation and lock, 80/183 the file appeared underneath us.
                if (($_.Exception.HResult -band 0xffff) -notin @(32, 33, 80, 183)) { throw }
                if ($timer.ElapsedMilliseconds -ge $script:LockTimeoutMilliseconds) {
                    throw [TimeoutException]::new("Timed out appending to the log '$Path'.", $_.Exception)
                }
                Start-Sleep -Milliseconds 50
            }
        }
        try {
            $null = $stream.Seek(0, [IO.SeekOrigin]::End)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }
    finally { $lock.Dispose() }
}

function Write-CMTraceLog {
    <#
    .SYNOPSIS
    Writes one CMTrace-format entry to the shared per-application log.
    .DESCRIPTION
    Every script on a managed endpoint logs through this one call, so all of a
    customer's logs share a format and live in one predictable place:

        %ProgramData%\<CustomerName>\<ApplicationName>\Logs\<ApplicationName>.log

    The file opens in CMTrace or OneTrace with severity colouring and the component,
    thread and source-line columns populated.

    The log tree is created with a protected DACL: SYSTEM and Administrators write,
    Users read. Writing therefore requires an elevated session or SYSTEM, which is
    already required to submit telemetry. An existing tree that a non-administrator
    could tamper with is refused rather than trusted.
    .PARAMETER Message
    The text to record. Newlines and control characters are flattened so one call
    always produces exactly one record.
    .PARAMETER Level
    Verbose, Debug and Info record as CMTrace type 1, Warning as 2 and Error as 3,
    which is what drives the yellow and red highlighting in the viewer.
    .PARAMETER ApplicationName
    The script, package or application this log belongs to. Defaults to the base name
    of the calling script, so a script that passes nothing still gets its own log.
    .PARAMETER CustomerName
    The customer folder under %ProgramData%. Defaults to the CustomerName in the
    machine-wide configuration, then to 'LogCollector'.
    .PARAMETER Component
    The CMTrace component column. Defaults to the calling function, or the calling
    script when called from top-level code.
    .PARAMETER LogRoot
    The root the customer folder is created under. Defaults to the system's own
    ProgramData path. A custom root is a test facility and must be accompanied by
    -SkipTrustCheck, because a caller-supplied root cannot be trusted the way the
    system path can.
    .PARAMETER MaxFileBytes
    Rotate once the active log would exceed this size.
    .PARAMETER MaxArchives
    How many rotated files to keep. 0 discards the log instead of archiving it.
    .PARAMETER SkipTrustCheck
    Skip both the protected-DACL provisioning and its verification, so the log can be
    written without elevation. Only accepted together with an explicit -LogRoot, so it
    can never be used to write an unprotected tree at the canonical location. Intended
    for tests; never use it on a device.
    .PARAMETER PassThru
    Return the path that was written to.
    .EXAMPLE
    Write-CMTraceLog -Message 'Upgrade started' -CustomerName 'Contoso'

    Logs to %ProgramData%\Contoso\<calling script>\Logs\<calling script>.log.
    .EXAMPLE
    Write-CMTraceLog -Level Error -Message "Copy failed: $($_.Exception.Message)" `
        -ApplicationName 'W11Upgrade' -CustomerName 'Contoso'
    .EXAMPLE
    try { Copy-Item $src $dst -ErrorAction Stop }
    catch { Write-CMTraceLog -Level Error -Message $_.Exception.Message; throw }
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [AllowEmptyString()] [string] $Message,
        [Parameter(Position = 1)] [ValidateSet('Verbose', 'Debug', 'Info', 'Warning', 'Error')] [string] $Level = 'Info',
        [string] $ApplicationName,
        [string] $CustomerName,
        [string] $Component,
        [string] $LogRoot,
        [ValidateRange(1024, 104857600)] [int] $MaxFileBytes = 5242880,
        [ValidateRange(0, 32)] [int] $MaxArchives = 5,
        [switch] $SkipTrustCheck,
        [switch] $PassThru
    )

    begin {
        # The two are only meaningful together. Alone, -SkipTrustCheck would provision the
        # canonical %ProgramData% tree with inherited permissions, leaving the path every
        # script logs to writable by any user; alone, -LogRoot would have the trust checks
        # applied to a caller-supplied root whose own ancestors nothing has verified.
        $customRoot = $PSBoundParameters.ContainsKey('LogRoot') -and $LogRoot
        if ($customRoot -ne $SkipTrustCheck.IsPresent) {
            throw ('-LogRoot and -SkipTrustCheck may only be used together: a custom log root is a test ' +
                'facility, and skipping the trust check at the canonical location would leave the shared ' +
                'log tree writable by any user.')
        }
        $programData = Get-CMTraceProgramDataPath
        if ($customRoot) { $LogRoot = Resolve-CMTraceCustomRoot -Path $LogRoot -ProgramData $programData }
        else { $LogRoot = $programData }
    }

    process {
        $caller = @(Get-PSCallStack)[1]
        $callerScript = if ($caller -and $caller.ScriptName) { $caller.ScriptName } else { '' }

        if (-not $ApplicationName) {
            # Default to the producing script, so a script that names nothing still gets
            # its own log rather than sharing one bucket with every other script. A file
            # name may legitimately contain characters a folder must not, so it is
            # normalised rather than rejected.
            $derived = if ($callerScript) { [IO.Path]::GetFileNameWithoutExtension($callerScript) } else { 'PowerShell' }
            $ApplicationName = ConvertTo-CMTraceNameSegment -Name $derived
        }
        if (-not $Component) {
            $Component = if ($caller -and $caller.FunctionName -and $caller.FunctionName -ne '<ScriptBlock>') {
                $caller.FunctionName
            }
            elseif ($callerScript) { Split-Path $callerScript -Leaf }
            else { 'PowerShell' }
        }
        $source = if ($callerScript) { '{0}:{1}' -f (Split-Path $callerScript -Leaf), $caller.ScriptLineNumber } else { '' }

        $path = Get-CMTraceLogPath -ApplicationName $ApplicationName -CustomerName $CustomerName -LogRoot $LogRoot
        if (-not $PSCmdlet.ShouldProcess($path, "Write a $Level entry")) { return }

        $directory = Split-Path $path -Parent
        $application = Split-Path $directory -Parent
        $customer = Split-Path $application -Parent
        foreach ($tier in @($customer, $application, $directory)) {
            New-CMTraceDirectory -Path $tier -SkipTrustCheck:$SkipTrustCheck
        }

        $record = New-CMTraceRecord -Message $Message -Component $Component -Source $source `
            -Type $script:LevelTypes[$Level]
        Write-CMTraceRecordToFile -Path $path -Record $record -MaxFileBytes $MaxFileBytes `
            -MaxArchives $MaxArchives -SkipTrustCheck:$SkipTrustCheck

        if ($PassThru) { return $path }
    }
}

Export-ModuleMember -Function Write-CMTraceLog, Get-CMTraceLogPath, Get-CMTraceCustomerName
