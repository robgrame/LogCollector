#Requires -Version 5.1
<#
.SYNOPSIS
Detects whether the application-logging remediation recently reached LogCollector.
.NOTES
Version 1.1.0. Run as SYSTEM in 64-bit PowerShell through Intune Remediations.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 720)] [int] $MaximumAgeHours = 24,
    [ValidateNotNullOrEmpty()] [string] $StatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not [Environment]::Is64BitProcess) {
    Write-Output 'Application logging probe requires 64-bit PowerShell.'
    exit 1
}
try {
    if (-not $PSBoundParameters.ContainsKey('StatePath')) {
        $usingDefaultStatePath = $true
        $moduleRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) `
            'WindowsPowerShell\Modules\LogCollector.Client'
        $selected = @(
            foreach ($directory in @(Get-ChildItem -LiteralPath $moduleRoot -Directory -ErrorAction Stop)) {
                $version = $null
                if (-not [version]::TryParse($directory.Name, [ref] $version) -or $version -lt [version] '1.10.0') {
                    continue
                }
                $manifest = Join-Path $directory.FullName 'LogCollector.Client.psd1'
                if (Test-Path -LiteralPath $manifest -PathType Leaf) {
                    [pscustomobject]@{ Version = $version; Manifest = $manifest }
                }
            }
        ) | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $selected) {
            Write-Output 'Application logging probe requires LogCollector Core 1.10.0 or later.'
            exit 1
        }
        Import-Module -Name $selected.Manifest -Force -ErrorAction Stop
        $StatePath = Join-Path (Get-LogCollectorDataRoot) 'State\ApplicationLoggingRemediation.json'
    }
    else {
        $usingDefaultStatePath = $false
    }
}
catch {
    Write-Output "Application logging probe could not resolve its customer-scoped state path: $($_.Exception.Message)"
    exit 1
}

try {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        Write-Output 'Application logging probe has not completed successfully.'
        exit 1
    }
    if ($usingDefaultStatePath) {
        $allowed = @('S-1-5-18', 'S-1-5-32-544')
        foreach ($path in @((Split-Path $StatePath -Parent), $StatePath)) {
            $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
            if (-not $acl.AreAccessRulesProtected) {
                throw "Application logging state path is not protected: $path"
            }
            $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -notin $allowed) { throw "Application logging state path has an untrusted owner: $path" }
            foreach ($rule in $acl.Access) {
                if ($rule.AccessControlType -ne 'Allow') { continue }
                $rights = [Security.AccessControl.FileSystemRights]::WriteData -bor
                    [Security.AccessControl.FileSystemRights]::AppendData -bor
                    [Security.AccessControl.FileSystemRights]::Delete -bor
                    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                    [Security.AccessControl.FileSystemRights]::TakeOwnership
                if (($rule.FileSystemRights -band $rights) -eq 0) { continue }
                $sid = try { $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                catch { $rule.IdentityReference.Value }
                if ($sid -notin $allowed) { throw "Application logging state path is writable by an untrusted identity: $path" }
            }
        }
    }

    $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $lastSuccess = [DateTimeOffset]::MinValue
    if ($state.Delivered -ne $true -or
        -not [DateTimeOffset]::TryParse(
            [string] $state.LastSuccessUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref] $lastSuccess)) {
        Write-Output 'Application logging probe state is invalid.'
        exit 1
    }

    $age = [DateTimeOffset]::UtcNow - $lastSuccess.ToUniversalTime()
    if ($age.TotalHours -gt $MaximumAgeHours -or $age.TotalSeconds -lt -300) {
        Write-Output "Application logging probe is stale: last success $($lastSuccess.ToString('o'))."
        exit 1
    }

    Write-Output ("Application logging verified at {0}; ExecutionId={1}." -f
        $lastSuccess.ToUniversalTime().ToString('o'), $state.ExecutionId)
    exit 0
}
catch {
    Write-Output "Application logging probe state could not be read: $($_.Exception.Message)"
    exit 1
}
