#Requires -Version 5.1
<#
.SYNOPSIS
Publishes a sanitized, history-free snapshot to a separate public GitHub repository.
.DESCRIPTION
Exports tracked files from a committed Git ref, scans the snapshot for customer identifiers,
credentials and environment-specific values, then creates or updates a separate public repository.
The private repository history is never copied.
.NOTES
Version 1.0.0. Use a local, ignored policy file for customer-specific deny strings.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository,
    [string] $SourceRef = 'HEAD',
    [string] $PolicyPath = '.public-release-policy.local.txt',
    [string] $CommitMessage = ('Publish sanitized snapshot {0:yyyy-MM-dd}' -f [DateTime]::UtcNow),
    [switch] $ScanOnly,
    [switch] $KeepStaging
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [switch] $AllowFailure
    )

    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$FilePath failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Get-SnapshotFiles {
    param([Parameter(Mandatory)] [string] $Root)
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force
}

function Read-StrictTextFile {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true)
    }
    else {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
    }
    $text = $encoding.GetString($bytes)
    if ($text.IndexOf([char]0) -ge 0 -or [regex]::IsMatch($text, '[\x01-\x08\x0B\x0C\x0E-\x1F]')) {
        throw 'File contains binary control characters.'
    }
    return $text
}

function Test-SafeCredentialPlaceholder {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [bool] $Quoted
    )

    if ($Value -match '^(?i:example|sample|placeholder|changeme|none|null|redacted|replace[_-]?me)$') { return $true }
    if ($Value -match '^<[^<>]+>$' -or $Value -match '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$') { return $true }
    if (-not $Quoted -and ($Value -match '^\$env:[A-Za-z_][A-Za-z0-9_]*$' -or
            $Value -match '^\$[A-Za-z_][A-Za-z0-9_]*$')) { return $true }
    return $false
}

function Test-AllowedIpv4 {
    param([Parameter(Mandatory)] [string] $Address)

    $parts = @($Address.Split('.') | ForEach-Object { [int]$_ })
    if ($parts.Count -ne 4 -or @($parts | Where-Object { $_ -lt 0 -or $_ -gt 255 }).Count) { return $true }
    if ($parts[0] -in @(0, 10, 127, 255)) { return $true }
    if ($parts[0] -eq 169 -and $parts[1] -eq 254) { return $true }
    if ($parts[0] -eq 172 -and $parts[1] -ge 16 -and $parts[1] -le 31) { return $true }
    if ($parts[0] -eq 192 -and $parts[1] -eq 168) { return $true }
    if ($parts[0] -eq 192 -and $parts[1] -eq 0 -and $parts[2] -eq 2) { return $true }
    if ($parts[0] -eq 198 -and $parts[1] -eq 51 -and $parts[2] -eq 100) { return $true }
    if ($parts[0] -eq 203 -and $parts[1] -eq 0 -and $parts[2] -eq 113) { return $true }
    # ASN.1 object identifiers (X.509 EKU/policy OIDs such as '2.5.29.19' or
    # '1.3.6.1.5.5.7.3.2') use dotted-decimal notation indistinguishable from
    # an IPv4 address by pattern alone once the run is exactly four segments.
    # A valid OID's first arc is 0, 1 or 2; if it is 0 or 1 the second arc is
    # additionally constrained to 0-39. Genuine public IPv4 literals in this
    # codebase never take this shape, so treat it as a non-address.
    if ($parts[0] -eq 2 -or (($parts[0] -eq 0 -or $parts[0] -eq 1) -and $parts[1] -le 39)) { return $true }
    return $false
}

function Test-PlaceholderGuid {
    <#
    .SYNOPSIS
    Recognizes documentation placeholder GUIDs made of a single repeated hex digit.
    .DESCRIPTION
    Values such as 11111111-1111-1111-1111-111111111111 or
    33333333-3333-3333-3333-333333333333 are a common, unambiguous documentation
    convention. A real random GUID has a negligible chance of matching this shape,
    so treating it as a placeholder does not meaningfully weaken the scan.
    #>
    param([Parameter(Mandatory)] [string] $Value)

    $compact = $Value.Replace('-', '')
    return (@($compact.ToCharArray() | Select-Object -Unique).Count -eq 1)
}

function Test-PublicSnapshot {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string[]] $DeniedLiterals
    )

    $allowedGuids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    @(
        '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001',
        '00000003-0000-0000-c000-000000000000', '11111111-2222-3333-4444-555555555555',
        'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
        '3f2504e0-4f89-11d3-9a0c-0305e82c3302', '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
        '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3', '3913510d-42f4-4e42-8a64-420c390055eb',
        '43d0d8ad-25c7-4714-9337-8ba259a9fe05', '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0',
        '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39', '974c5e8b-45b9-4653-ba55-5f855dd0fb88',
        'b7e6dc6d-f1e8-4753-8033-0f276bb0955b', '4ca10d53-456c-4ce0-a860-14d4b6644db9'
    ) | ForEach-Object { $null = $allowedGuids.Add($_) }

    $binaryExtensions = @(
        '.7z', '.bin', '.bmp', '.dll', '.doc', '.docx', '.eot', '.exe', '.gif', '.gz',
        '.ico', '.intunewin', '.jpeg', '.jpg', '.nupkg', '.pdf', '.pfx', '.png', '.so',
        '.tar', '.tif', '.tiff', '.ttf', '.webp', '.woff', '.woff2', '.xls', '.xlsx', '.zip'
    )
    $findings = New-Object 'Collections.Generic.List[object]'
    foreach ($file in @(Get-SnapshotFiles -Root $Root)) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
        $displayFile = $relative
        $pathFindings = New-Object 'Collections.Generic.List[string]'
        foreach ($literal in $DeniedLiterals) {
            if ($relative.IndexOf($literal, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $pathFindings.Add('Local deny policy in path')
            }
        }
        foreach ($match in [regex]::Matches($relative, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')) {
            if (-not $allowedGuids.Contains($match.Value) -and -not (Test-PlaceholderGuid -Value $match.Value)) {
                $pathFindings.Add('Unapproved GUID in path')
            }
        }
        if ([regex]::IsMatch($relative, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')) {
            $pathFindings.Add('Email address in path')
        }
        if ($pathFindings.Count -gt 0) {
            $displayFile = '[redacted path]'
            foreach ($kind in $pathFindings) {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = $kind; Value = '[redacted]' })
            }
        }

        if ($file.Length -gt 5MB) {
            $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'File exceeds scan limit'; Value = '[redacted]' })
            continue
        }
        if ($file.Extension.ToLowerInvariant() -in $binaryExtensions) {
            $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Unsupported binary file'; Value = '[redacted]' })
            continue
        }
        try { $text = Read-StrictTextFile -Path $file.FullName }
        catch {
            $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Non-text or invalid encoding'; Value = '[redacted]' })
            continue
        }

        foreach ($literal in $DeniedLiterals) {
            if ($text.IndexOf($literal, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Local deny policy'; Value = '[redacted]' })
            }
        }

        foreach ($match in [regex]::Matches($text, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')) {
            if (-not $allowedGuids.Contains($match.Value) -and -not (Test-PlaceholderGuid -Value $match.Value)) {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Unapproved GUID'; Value = '[redacted]' })
            }
        }

        foreach ($match in [regex]::Matches($text, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')) {
            if ($match.Value -notmatch '(?i)@(example\.invalid|users\.noreply\.github\.com)$') {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Email address'; Value = '[redacted]' })
            }
        }

        foreach ($match in [regex]::Matches($text, '(?i)https://([a-z0-9-]+)\.azurewebsites\.net')) {
            $hostLabel = $match.Groups[1].Value
            if ($hostLabel -notmatch '^(your-|example|sample|test)') {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Concrete Azure hostname'; Value = '[redacted]' })
            }
        }

        foreach ($match in [regex]::Matches($text, '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])')) {
            if (-not (Test-AllowedIpv4 -Address $match.Value)) {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Public IPv4 address'; Value = '[redacted]' })
            }
        }

        $secretAssignmentPattern = '(?im)["'']?\b(Client[\s_-]*Secret|Azure[\s_-]*Client[\s_-]*Secret|Password|Api[\s_-]*Key|Access[\s_-]*Token|Bearer[\s_-]*Token|Primary[\s_-]*Key|Workspace[\s_-]*Key|Function[\s_-]*Key)\b["'']?\s*[:=]\s*(?:"([^"]*)"|''([^'']*)''|([^\s,;}]+))'
        foreach ($match in [regex]::Matches($text, $secretAssignmentPattern)) {
            $quoted = $match.Groups[2].Success -or $match.Groups[3].Success
            $candidate = if ($match.Groups[2].Success) { $match.Groups[2].Value }
                elseif ($match.Groups[3].Success) { $match.Groups[3].Value }
                else { $match.Groups[4].Value }
            if (-not (Test-SafeCredentialPlaceholder -Value $candidate -Quoted $quoted)) {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = 'Credential assignment'; Value = '[redacted]' })
            }
        }

        $genericPatterns = @(
            @{ Kind = 'Private key'; Pattern = '(?i)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' },
            @{ Kind = 'Storage account key'; Pattern = '(?i)AccountKey\s*=\s*[^;\s]{8,}' },
            @{ Kind = 'GitHub token'; Pattern = '(?i)\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b' },
            @{ Kind = 'Customer OneDrive path'; Pattern = '(?i)OneDrive\s*-\s*[^\\/\r\n]+' },
            @{ Kind = 'Azure resource ID'; Pattern = '(?i)/subscriptions/(?!00000000-0000-0000-0000-000000000000)[0-9a-f-]{36}/' }
        )
        foreach ($rule in $genericPatterns) {
            foreach ($match in [regex]::Matches($text, $rule.Pattern)) {
                $findings.Add([pscustomobject]@{ File = $displayFile; Kind = $rule.Kind; Value = '[redacted]' })
            }
        }
    }

    return $findings.ToArray()
}

$rootResult = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('rev-parse', '--show-toplevel')
$repoRoot = [IO.Path]::GetFullPath(($rootResult.Output | Select-Object -First 1).ToString().Trim())
Set-Location $repoRoot

$status = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('status', '--porcelain')
if ($status.Output.Count -gt 0) { throw 'The private repository working tree must be clean before publishing.' }
$sourceCommit = ((Invoke-NativeCommand -FilePath 'git' -ArgumentList @('rev-parse', '--verify', "$SourceRef^{commit}")).Output | Select-Object -First 1).ToString().Trim()
$headCommit = ((Invoke-NativeCommand -FilePath 'git' -ArgumentList @('rev-parse', '--verify', 'HEAD^{commit}')).Output | Select-Object -First 1).ToString().Trim()
if ($sourceCommit -ne $headCommit) {
    throw 'SourceRef must resolve to the current committed HEAD so repository attributes can be validated safely.'
}
$attributePaths = @((Invoke-NativeCommand -FilePath 'git' -ArgumentList @('ls-files')).Output |
    Where-Object { [IO.Path]::GetFileName($_) -eq '.gitattributes' })
foreach ($attributePath in $attributePaths) {
    $attributeText = Read-StrictTextFile -Path (Join-Path $repoRoot $attributePath)
    $activeExportSubst = @($attributeText -split "\r?\n" | Where-Object {
            $_ -notmatch '^\s*#' -and $_ -match '(^|\s)export-subst(\s|$)'
        })
    if ($activeExportSubst.Count -gt 0) {
        throw "Tracked Git attributes enable export-subst in $attributePath; refusing to export private commit metadata."
    }
}

$policyFullPath = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($PolicyPath)) { $PolicyPath } else { Join-Path $repoRoot $PolicyPath }))
if (-not (Test-Path -LiteralPath $policyFullPath -PathType Leaf)) {
    throw "Local deny policy not found: $policyFullPath. Create it with one customer-specific literal per line."
}
$rootPrefix = $repoRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $policyFullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The local deny policy must be stored inside the private repository and ignored by Git.'
}
$policyRelativePath = $policyFullPath.Substring($rootPrefix.Length)
$ignored = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('check-ignore', '--quiet', '--', $policyRelativePath) -AllowFailure
if ($ignored.ExitCode -ne 0) {
    throw 'The local deny policy must be ignored by Git before publishing.'
}
$policyText = (Read-StrictTextFile -Path $policyFullPath).TrimStart([char]0xFEFF)
$deniedLiterals = @(
    $policyText -split "\r?\n" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
)
if ($deniedLiterals.Count -eq 0) { throw 'The local deny policy contains no active entries.' }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('LogCollector-public-' + [guid]::NewGuid().ToString('N'))
$snapshot = Join-Path $tempRoot 'snapshot'
$archive = Join-Path $tempRoot 'snapshot.zip'
$publicClone = Join-Path $tempRoot 'public'
$null = New-Item -ItemType Directory -Path $snapshot -Force
try {
    $emptyAttributes = Join-Path $tempRoot 'empty.gitattributes'
    [IO.File]::WriteAllText($emptyAttributes, '')
    $previousNoSystemAttributes = $env:GIT_ATTR_NOSYSTEM
    try {
        $env:GIT_ATTR_NOSYSTEM = '1'
        $null = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-c', "core.attributesFile=$emptyAttributes", 'archive', '--format=zip', "--output=$archive", $SourceRef)
    }
    finally {
        if ($null -eq $previousNoSystemAttributes) { Remove-Item Env:GIT_ATTR_NOSYSTEM -ErrorAction SilentlyContinue }
        else { $env:GIT_ATTR_NOSYSTEM = $previousNoSystemAttributes }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $snapshot)

    $markerName = '.public-snapshot'
    $markerPath = Join-Path $snapshot $markerName
    $markerTemplate = "Format=LogCollectorPublicSnapshot/v1`nRepositoryId=__TARGET_REPOSITORY_ID__"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
        (Read-StrictTextFile -Path $markerPath).Trim().Replace("`r`n", "`n") -ne $markerTemplate) {
        throw "The source snapshot has a missing or invalid safety marker $markerName."
    }

    $findings = @(Test-PublicSnapshot -Root $snapshot -DeniedLiterals $deniedLiterals)
    if ($findings.Count -gt 0) {
        $details = $findings | Sort-Object File, Kind, Value -Unique | Format-Table -AutoSize | Out-String
        throw "Public snapshot validation failed with $($findings.Count) finding(s):`n$details"
    }

    if ($ScanOnly) {
        [pscustomobject]@{ Status = 'Clean'; SourceRef = $SourceRef; FileCount = @(Get-ChildItem $snapshot -Recurse -File).Count }
        return
    }
    if ([string]::IsNullOrWhiteSpace($Repository) -or $Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw '-Repository must be supplied as owner/name unless -ScanOnly is used.'
    }

    $repoCheck = Invoke-NativeCommand -FilePath 'gh' -ArgumentList @('repo', 'view', $Repository, '--json', 'id,visibility') -AllowFailure
    $repositoryExisted = $repoCheck.ExitCode -eq 0
    if (-not $repositoryExisted) {
        if ($PSCmdlet.ShouldProcess($Repository, 'Create public GitHub repository')) {
            $null = Invoke-NativeCommand -FilePath 'gh' -ArgumentList @('repo', 'create', $Repository, '--public', '--description', 'Secure Azure Monitor log ingestion with certificate-authenticated Windows clients.')
            $repoCheck = Invoke-NativeCommand -FilePath 'gh' -ArgumentList @('repo', 'view', $Repository, '--json', 'id,visibility')
        }
        else { return }
    }
    $repoMetadata = ($repoCheck.Output -join '') | ConvertFrom-Json
    if ($repoMetadata.visibility -ne 'PUBLIC') { throw "Target repository $Repository exists but is not public." }
    if ([string]::IsNullOrWhiteSpace($repoMetadata.id)) { throw "Unable to resolve immutable repository ID for $Repository." }
    $boundMarker = "Format=LogCollectorPublicSnapshot/v1`nRepositoryId=$($repoMetadata.id)"
    [IO.File]::WriteAllText($markerPath, $boundMarker, [Text.UTF8Encoding]::new($false))

    $null = Invoke-NativeCommand -FilePath 'gh' -ArgumentList @('repo', 'clone', $Repository, $publicClone)
    $existingFiles = @(Get-ChildItem -LiteralPath $publicClone -Force | Where-Object Name -ne '.git')
    $existingMarkerPath = Join-Path $publicClone $markerName
    if ($repositoryExisted -and (-not (Test-Path -LiteralPath $existingMarkerPath -PathType Leaf) -or
            (Read-StrictTextFile -Path $existingMarkerPath).Trim().Replace("`r`n", "`n") -ne $boundMarker)) {
        throw "Refusing to overwrite $Repository because its snapshot marker is missing or bound to a different repository."
    }
    $existingFiles | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $snapshot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $publicClone -Recurse -Force
    }

    $null = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $publicClone, 'checkout', '-B', 'main')
    $null = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $publicClone, 'add', '-A')
    $changes = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $publicClone, 'diff', '--cached', '--quiet') -AllowFailure
    if ($changes.ExitCode -eq 0) {
        [pscustomobject]@{ Status = 'Unchanged'; Repository = $Repository; SourceRef = $SourceRef }
        return
    }
    if ($changes.ExitCode -ne 1) { throw 'Unable to determine whether the public snapshot changed.' }

    if ($PSCmdlet.ShouldProcess($Repository, 'Commit and push sanitized public snapshot')) {
        $null = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $publicClone, 'commit', '-m', $CommitMessage)
        $null = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $publicClone, 'push', '-u', 'origin', 'main')
        [pscustomobject]@{ Status = 'Published'; Repository = $Repository; SourceRef = $SourceRef }
    }
}
finally {
    if (-not $KeepStaging -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
