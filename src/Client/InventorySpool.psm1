<#
.SYNOPSIS
    Durable on-disk spool for inventory submissions that could not be delivered.

.DESCRIPTION
    A managed device is frequently offline, on a captive portal, or shut down
    mid-run. Losing a sample in those cases would silently bias the inventory, so
    every submission that cannot be delivered is written to disk and retried on a
    later run.

    Design rules that make the spool safe rather than a liability:

      * Trusted filesystem. Existing owners, permissions and reparse points are
        checked before use. New directories and files receive protected ACLs at
        creation. An unsafe legacy spool must be discarded and reprovisioned by
        an administrator, never "repaired" in place and then replayed.

      * Atomic writes. Content is written to a .tmp file and then moved into
        place, so a crash or power loss never leaves a half-written entry that a
        later drain would parse as valid.

      * Bounded growth. Age, entry count and total byte quotas are enforced on
        every save and every drain. An endpoint that cannot reach the service for
        a month must not fill its system drive.

      * Oldest-first drain with a stop-on-transient-failure rule. Continuing to
        hammer an endpoint that just returned 503 turns one outage into a
        self-inflicted DDoS from the fleet.

      * Quarantine, not infinite retry. An entry the server permanently rejects
        is moved aside for operator inspection instead of being replayed forever.

      * Single-writer lock. Two overlapping scheduled-task instances must not
        drain the same entry twice.

    Entries store the envelope body only. Signatures are deliberately NOT stored:
    they are timestamp- and nonce-bound and would be stale by the time the entry
    is drained, so every drain re-signs with a fresh timestamp and nonce.

.NOTES
    Version 1.0.1 - explicit retention on save and rejection of entries exceeding the entire quota.
    Windows PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

$script:SpoolVersion = 'LOGCOLLECTOR-SPOOL-V1'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

function Test-SpoolTrustedIdentity {
    param([string] $Sid, [switch] $Ancestor)

    if ($Sid -in @('S-1-5-18', 'S-1-5-32-544')) { return $true }
    # Windows owns the volume root through TrustedInstaller, not Administrators.
    return ($Ancestor -and $Sid -eq 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
}

function New-SpoolSecurityDescriptor {
    param([switch] $Directory)

    if ($Directory) {
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    }
    else {
        $security = New-Object System.Security.AccessControl.FileSecurity
        $security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
    }
    return $security
}

function Get-SpoolFullPath {
    param([string] $Path)

    # Device paths, UNC paths, ADS and Win32-normalized aliases are not a spool.
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(3) -match '[:/]' -or
        @($Path.Substring(3).TrimEnd('\').Split('\') | Where-Object {
            $_ -eq '.' -or $_ -eq '..' -or $_ -match '[. ]$' -or $_ -match '[<>|?*"]'
        }).Count -gt 0) {
        throw "Unsafe spool path '$Path': use an absolute local Windows path without aliases."
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath)).DriveType -ne [IO.DriveType]::Fixed) {
        throw "Unsafe spool path '$Path': a local fixed drive is required."
    }
    return $fullPath
}

function Test-SpoolAncestorAnchor {
    param([string] $Path)

    # NTFS refuses FSCTL_SET_REPARSE_POINT on nonempty directories. A child
    # that users cannot remove keeps a writable shared ancestor (ProgramData)
    # nonempty without changing permissions on that ancestor or its children.
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction Stop)) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        try {
            $acl = Get-Acl -LiteralPath $child.FullName -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Write-Verbose ("Cannot inspect potential ancestor anchor '{0}'; ignoring this candidate." -f $child.FullName)
            continue
        }
        $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
        if ($null -eq $descriptor.Owner -or $null -eq $descriptor.DiscretionaryAcl -or
            -not (Test-SpoolTrustedIdentity -Sid $descriptor.Owner.Value -Ancestor)) { continue }
        $immutable = $true
        foreach ($ace in $descriptor.DiscretionaryAcl) {
            if ($ace.AceFlags.HasFlag([Security.AccessControl.AceFlags]::InheritOnly)) { continue }
            if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback) {
                $immutable = $false
                break
            }
            # The parent has already been checked for DELETE_CHILD. On the
            # child, GENERIC_ALL/DELETE/WRITE_DAC/WRITE_OWNER permit removal.
            if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                ($ace.AccessMask -band 0x100D0000) -ne 0 -and
                -not (Test-SpoolTrustedIdentity -Sid $ace.SecurityIdentifier.Value -Ancestor)) {
                $immutable = $false
                break
            }
        }
        if ($immutable) { return $true }
    }
    return $false
}

function Assert-SpoolNode {
    param([string] $Path, [switch] $Directory, [switch] $Ancestor, [switch] $AllowMissing)

    try { $attributes = [IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException] {
        if ($AllowMissing) { return $false }
        throw
    }
    catch [IO.DirectoryNotFoundException] {
        if ($AllowMissing) { return $false }
        throw
    }

    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Unsafe spool path '$Path': reparse points are forbidden."
    }
    if ((($attributes -band [IO.FileAttributes]::Directory) -ne 0) -ne [bool]$Directory) {
        throw "Unsafe spool path '$Path': unexpected file type."
    }

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if (-not (Test-SpoolTrustedIdentity -Sid $descriptor.Owner.Value -Ancestor:$Ancestor)) {
        throw "Unsafe spool path '$Path': untrusted owner."
    }
    if ($null -eq $descriptor.DiscretionaryAcl) {
        throw "Unsafe spool path '$Path': a null DACL grants unrestricted access."
    }

    # Ancestors must never permit replacement/deletion or security changes.
    # Content/metadata writes additionally require an immutable child anchor.
    # GENERIC_ALL/WRITE, DELETE/WRITE_DAC/WRITE_OWNER, writes and delete-child.
    $writeMask = 0x500D0156
    $needsAnchor = $false
    foreach ($ace in $descriptor.DiscretionaryAcl) {
        if ($Ancestor -and $ace.AceFlags.HasFlag([Security.AccessControl.AceFlags]::InheritOnly)) { continue }
        if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback) {
            throw "Unsafe spool path '$Path': unsupported access rule."
        }
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
            ($ace.AccessMask -band $writeMask) -ne 0 -and
            -not (Test-SpoolTrustedIdentity -Sid $ace.SecurityIdentifier.Value -Ancestor:$Ancestor)) {
            if (-not $Ancestor -or ($ace.AccessMask -band 0x100D0040) -ne 0) {
                throw "Unsafe spool path '$Path': untrusted write access."
            }
            # WRITE_DATA or WRITE_ATTRIBUTES can set a directory reparse point.
            if (($ace.AccessMask -band 0x40000102) -ne 0) { $needsAnchor = $true }
        }
    }
    if ($needsAnchor -and -not (Test-SpoolAncestorAnchor -Path $Path)) {
        throw "Unsafe spool path '$Path': untrusted write access on an ancestor without a protected child."
    }
    return $true
}

function Assert-SpoolHierarchy {
    param([string] $Path, [switch] $Directory, [switch] $AllowMissing, [switch] $Create)

    $fullPath = Get-SpoolFullPath -Path $Path
    $root = [IO.Path]::GetPathRoot($fullPath)
    $parts = @($fullPath.Substring($root.Length).TrimEnd('\').Split('\') | Where-Object { $_ })
    $current = $root
    $null = Assert-SpoolNode -Path $root -Directory -Ancestor:($parts.Count -gt 0)
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $current = Join-Path $current $parts[$i]
        $ancestor = $i -lt ($parts.Count - 1)
        $isDirectory = $ancestor -or $Directory
        $isAncestor = $ancestor -and ($Directory -or $i -lt ($parts.Count - 2))
        $exists = Assert-SpoolNode -Path $current -Directory:$isDirectory -Ancestor:$isAncestor -AllowMissing:($AllowMissing -or $Create)
        if (-not $exists) {
            if (-not $Create) { return $false }
            $security = New-SpoolSecurityDescriptor -Directory
            # These APIs attach the protected DACL during creation. Never create
            # with inherited permissions and subsequently bless existing data.
            if ($PSVersionTable.PSVersion.Major -le 5) {
                $null = [IO.Directory]::CreateDirectory($current, $security)
            }
            else {
                $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $current)
            }
            $null = Assert-SpoolNode -Path $current -Directory
        }
    }
    return $true
}

function Assert-SpoolContents {
    param([string] $SpoolDirectory)

    foreach ($item in @(Get-ChildItem -LiteralPath $SpoolDirectory -Force -ErrorAction Stop)) {
        if ($item.Name -eq 'quarantine') {
            $null = Assert-SpoolNode -Path $item.FullName -Directory
            foreach ($file in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                $null = Assert-SpoolNode -Path $file.FullName
            }
        }
        else {
            # Unexpected directories are rejected, never recursively repaired.
            $null = Assert-SpoolNode -Path $item.FullName
        }
    }
}

function New-SpoolFileStream {
    param([string] $Path)

    $null = Assert-SpoolHierarchy -Path $Path -AllowMissing
    $security = New-SpoolSecurityDescriptor
    if ($PSVersionTable.PSVersion.Major -le 5) {
        return [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $security)
    }
    return [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path), [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
        4096, [IO.FileOptions]::None, $security)
}

function Write-SpoolFile {
    param([string] $Path, [string] $Content)

    $stream = New-SpoolFileStream -Path $Path
    try {
        $bytes = $script:Utf8NoBom.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Initialize-SpoolDirectory {
    <#
    .SYNOPSIS
        Ensures the spool and quarantine directories exist. Returns the spool path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpoolDirectory)

    $null = Assert-SpoolHierarchy -Path $SpoolDirectory -Directory -Create
    Assert-SpoolContents -SpoolDirectory $SpoolDirectory

    $quarantine = Join-Path $SpoolDirectory 'quarantine'
    $null = Assert-SpoolHierarchy -Path $quarantine -Directory -Create

    return $SpoolDirectory
}

function Save-SpoolEntry {
    <#
    .SYNOPSIS
        Persists an envelope body for a later delivery attempt.
    .OUTPUTS
        [string] Full path of the spooled entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Body,
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $SpoolDirectory,
        [ValidateRange(1, 100000)] [int] $MaxEntries = 500,
        [ValidateRange(1, 2147483647)] [int] $MaxTotalBytes = 67108864,
        [ValidateRange(1, 365)] [int] $MaxAgeDays = 7
    )

    $null = Initialize-SpoolDirectory -SpoolDirectory $SpoolDirectory

    $createdUtc = [DateTimeOffset]::UtcNow
    $entry = [ordered]@{
        spoolVersion = $script:SpoolVersion
        createdUtc   = $createdUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        tableName    = $TableName
        attempts     = 0
        body         = $Body
    }

    # Sortable UTC prefix: drain order must not depend on file-system metadata,
    # which copy/restore operations happily rewrite.
    $fileName = '{0}-{1}.json' -f $createdUtc.ToString('yyyyMMddTHHmmssfff'), ([guid]::NewGuid().ToString('N'))
    $finalPath = Join-Path $SpoolDirectory $fileName
    $tempPath = "$finalPath.tmp"

    $json = $entry | ConvertTo-Json -Depth 8 -Compress
    if ($script:Utf8NoBom.GetByteCount($json) -gt $MaxTotalBytes) {
        throw 'The serialized spool entry exceeds the entire spool quota; it cannot be retained.'
    }
    Write-SpoolFile -Path $tempPath -Content $json
    [System.IO.File]::Move($tempPath, $finalPath)

    $null = Invoke-SpoolMaintenance -SpoolDirectory $SpoolDirectory -MaxEntries $MaxEntries `
        -MaxTotalBytes $MaxTotalBytes -MaxAgeDays $MaxAgeDays

    if (-not [IO.File]::Exists($finalPath)) {
        throw 'The new spool entry was evicted during maintenance; delivery has not been retained.'
    }
    return $finalPath
}

function Get-SpoolEntry {
    <#
    .SYNOPSIS
        Returns spooled entries, oldest first.
    .OUTPUTS
        [pscustomobject[]] with Path, CreatedUtc, TableName, Attempts, Body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SpoolDirectory,
        [int] $First = 0
    )

    if (-not (Assert-SpoolHierarchy -Path $SpoolDirectory -Directory -AllowMissing)) { return @() }
    Assert-SpoolContents -SpoolDirectory $SpoolDirectory

    $files = @(Get-ChildItem -LiteralPath $SpoolDirectory -Filter '*.json' -File -Force -ErrorAction Stop |
               Sort-Object Name)

    if ($First -gt 0) { $files = @($files | Select-Object -First $First) }

    $results = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        $entry = ConvertFrom-SpoolFile -Path $file.FullName
        if ($entry) { $null = $results.Add($entry) }
    }

    return @($results)
}

function ConvertFrom-SpoolFile {
    <#
    .SYNOPSIS
        Parses one spool file. Unreadable or malformed files are quarantined, not
        thrown, so a single corrupt entry cannot block the whole drain.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    # Trust failures must escape the corrupt-JSON quarantine handler.
    $null = Assert-SpoolHierarchy -Path $Path
    try {
        $raw = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        Write-Verbose ("ConvertFrom-SpoolFile: quarantining unreadable entry {0}" -f $Path)
        $null = Move-SpoolEntryToQuarantine -Path $Path -Reason 'unreadable'
        return $null
    }

    $names = @($parsed.PSObject.Properties.Name)
    if (($names -notcontains 'spoolVersion') -or ($parsed.spoolVersion -ne $script:SpoolVersion) -or
        ($names -notcontains 'body') -or [string]::IsNullOrWhiteSpace([string]$parsed.body)) {
        Write-Verbose ("ConvertFrom-SpoolFile: quarantining unsupported entry {0}" -f $Path)
        $null = Move-SpoolEntryToQuarantine -Path $Path -Reason 'unsupported-version'
        return $null
    }

    $createdUtc = [DateTimeOffset]::MinValue
    if (($names -contains 'createdUtc') -and
        [DateTimeOffset]::TryParse([string]$parsed.createdUtc, [ref]$createdUtc)) {
        # parsed
    }
    else {
        $createdUtc = [DateTimeOffset]::UtcNow
    }

    $attempts = 0
    if ($names -contains 'attempts') { $attempts = [int]$parsed.attempts }

    $tableName = ''
    if ($names -contains 'tableName') { $tableName = [string]$parsed.tableName }

    [pscustomobject]@{
        Path       = $Path
        CreatedUtc = $createdUtc
        TableName  = $tableName
        Attempts   = $attempts
        Body       = [string]$parsed.body
    }
}

function Remove-SpoolEntry {
    <#
    .SYNOPSIS
        Deletes a spooled entry after it has been delivered.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (Assert-SpoolHierarchy -Path $Path -AllowMissing) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}

function Update-SpoolEntryAttempt {
    <#
    .SYNOPSIS
        Increments the attempt counter on an entry, atomically.
    .OUTPUTS
        [int] The new attempt count, or -1 when the entry could not be updated.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $entry = ConvertFrom-SpoolFile -Path $Path
    if (-not $entry) { return -1 }

    $attempts = $entry.Attempts + 1
    $payload = [ordered]@{
        spoolVersion = $script:SpoolVersion
        createdUtc   = $entry.CreatedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        tableName    = $entry.TableName
        attempts     = $attempts
        body         = $entry.Body
    }

    $tempPath = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    Write-SpoolFile -Path $tempPath -Content ($payload | ConvertTo-Json -Depth 8 -Compress)
    try {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $null = Assert-SpoolHierarchy -Path $Path
            $null = Assert-SpoolHierarchy -Path $tempPath
            try {
                Invoke-SpoolFileReplace -Source $tempPath -Destination $Path
                break
            }
            catch [System.IO.IOException] {
                if ($attempt -eq 5) { throw }
                Write-Verbose ("Atomic spool update temporarily failed for '{0}'; retry {1}/5." -f $Path, ($attempt + 1))
                Start-Sleep -Milliseconds (100 * [Math]::Pow(2, $attempt - 1))
            }
        }
    }
    finally {
        Remove-SpoolEntry -Path $tempPath
    }

    return $attempts
}

function Invoke-SpoolFileReplace {
    param([string] $Source, [string] $Destination)
    [System.IO.File]::Replace($Source, $Destination, [NullString]::Value)
}

function Move-SpoolEntryToQuarantine {
    <#
    .SYNOPSIS
        Moves an entry the server permanently rejected into quarantine.
    .DESCRIPTION
        Quarantined entries are never retried. They are kept so an operator can
        see why a device's submissions are failing; Invoke-SpoolMaintenance ages
        them out under the same age quota as live entries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Reason = 'rejected'
    )

    $null = Assert-SpoolHierarchy -Path $Path
    $spoolDirectory = Split-Path -Parent $Path
    $null = Initialize-SpoolDirectory -SpoolDirectory $spoolDirectory
    $quarantine = Join-Path $spoolDirectory 'quarantine'
    $leaf = Split-Path -Leaf $Path
    $target = Join-Path $quarantine ('{0}.{1}' -f $leaf, ($Reason -replace '[^A-Za-z0-9\-]', '-'))
    Remove-SpoolEntry -Path $target
    [System.IO.File]::Move($Path, $target)
    return $target
}

function Invoke-SpoolMaintenance {
    <#
    .SYNOPSIS
        Enforces the age, count and size quotas across the spool and quarantine.
    .OUTPUTS
        [pscustomobject] with RemovedExpired, RemovedOverQuota, RemainingEntries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SpoolDirectory,
        [int] $MaxAgeDays = 7,
        [int] $MaxEntries = 500,
        [int] $MaxTotalBytes = 67108864
    )

    $result = [pscustomobject]@{
        RemovedExpired   = 0
        RemovedOverQuota = 0
        RemainingEntries = 0
    }

    if (-not (Assert-SpoolHierarchy -Path $SpoolDirectory -Directory -AllowMissing)) { return $result }
    Assert-SpoolContents -SpoolDirectory $SpoolDirectory

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * [Math]::Max(1, $MaxAgeDays))

    $searchRoots = @($SpoolDirectory)
    $quarantine = Join-Path $SpoolDirectory 'quarantine'
    if (Test-Path -LiteralPath $quarantine) { $searchRoots += $quarantine }

    foreach ($root in $searchRoots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Force -ErrorAction Stop)) {
            # Stale .tmp files are the residue of an interrupted atomic write.
            if ($file.Extension -eq '.tmp' -and $file.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddHours(-1)) {
                Remove-SpoolEntry -Path $file.FullName
                continue
            }

            if ($file.LastWriteTimeUtc -lt $cutoff) {
                Remove-SpoolEntry -Path $file.FullName
                $result.RemovedExpired++
            }
        }
    }

    # Count and byte quotas apply to live entries only; quarantine is bounded by age.
    $live = @(Get-ChildItem -LiteralPath $SpoolDirectory -Filter '*.json' -File -Force -ErrorAction Stop |
              Sort-Object Name)

    if ($live.Count -gt $MaxEntries) {
        foreach ($file in @($live | Select-Object -First ($live.Count - $MaxEntries))) {
            Remove-SpoolEntry -Path $file.FullName
            $result.RemovedOverQuota++
        }
        $live = @(Get-ChildItem -LiteralPath $SpoolDirectory -Filter '*.json' -File -Force -ErrorAction Stop |
                  Sort-Object Name)
    }

    $totalBytes = 0
    foreach ($file in $live) { $totalBytes += $file.Length }

    $index = 0
    while ($totalBytes -gt $MaxTotalBytes -and $index -lt $live.Count) {
        $totalBytes -= $live[$index].Length
        Remove-SpoolEntry -Path $live[$index].FullName
        $result.RemovedOverQuota++
        $index++
    }

    $result.RemainingEntries = @(Get-ChildItem -LiteralPath $SpoolDirectory -Filter '*.json' -File -Force -ErrorAction Stop).Count
    return $result
}

function Enter-SpoolLock {
    <#
    .SYNOPSIS
        Takes an exclusive spool lock. Returns $null when another run holds it.
    .DESCRIPTION
        The scheduled task uses a two-hour random delay, so overlapping runs are
        rare but possible after a wake-from-sleep catch-up. Without this lock two
        runs could drain and submit the same entry, producing duplicate rows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpoolDirectory)

    $null = Initialize-SpoolDirectory -SpoolDirectory $SpoolDirectory
    $lockPath = Join-Path $SpoolDirectory '.drain.lock'

    try {
        if (-not (Assert-SpoolHierarchy -Path $lockPath -AllowMissing)) {
            try { return (New-SpoolFileStream -Path $lockPath) }
            catch [IO.IOException] {
                # Only an existing trusted file can be a competing lock creator.
                $null = Assert-SpoolHierarchy -Path $lockPath
            }
        }
        $stream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        return $stream
    }
    catch [System.IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -notin @(32, 33)) { throw }
        Write-Verbose 'Enter-SpoolLock: another drain is already running.'
        return $null
    }
}

function Exit-SpoolLock {
    <#
    .SYNOPSIS
        Releases a lock taken by Enter-SpoolLock.
    #>
    [CmdletBinding()]
    param($LockStream)

    if ($null -ne $LockStream) {
        try { $LockStream.Close() } catch { }
        try { $LockStream.Dispose() } catch { }
    }
}

Export-ModuleMember -Function `
    Initialize-SpoolDirectory, `
    Save-SpoolEntry, `
    Get-SpoolEntry, `
    ConvertFrom-SpoolFile, `
    Remove-SpoolEntry, `
    Update-SpoolEntryAttempt, `
    Move-SpoolEntryToQuarantine, `
    Invoke-SpoolMaintenance, `
    Enter-SpoolLock, `
    Exit-SpoolLock
