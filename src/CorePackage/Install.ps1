#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs the LogCollector core module machine-wide so any script can write to Log Analytics.
.DESCRIPTION
Puts LogCollector.Client on the machine PSModulePath and writes the protected endpoint
configuration. After this runs, any script on the device can call

    Import-Module LogCollector.Client
    Send-LogAnalyticsData -LogType 'W11Upgrade' -Body ($events | ConvertTo-Json)

with no workspace key, no endpoint URL and no install path of its own. Submission is
authenticated by the device's own Intune certificate.

This package registers no scheduled task and collects nothing by itself. It is a
dependency: install it before any package or script that submits telemetry.
.PARAMETER FrontendUrl
Overrides the endpoint in Config.psd1. Intended for a single-machine test install.
.PARAMETER CustomerName
Overrides the customer folder in Config.psd1. This is the <CustomerName> in
%ProgramData%\<CustomerName>\<ApplicationName>\Logs, where Write-CMTraceLog writes.
Intended for a single-machine test install.
.NOTES
Version 1.7.1.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Uri] $FrontendUrl,
    [ValidatePattern('^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])$')] [string] $CustomerName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packageVersion = '1.7.1'

if (-not [Environment]::Is64BitProcess) { throw 'Run this installer with 64-bit Windows PowerShell.' }

$configPath = Join-Path $PSScriptRoot 'Config.psd1'
$config = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
if ($config.PackageVersion -ne $packageVersion) {
    throw "Config.psd1 declares version '$($config.PackageVersion)' but this installer is $packageVersion; do not mix files from different packages."
}
if ($FrontendUrl) { $config['FrontendUrl'] = $FrontendUrl.OriginalString }
if ($CustomerName) { $config['CustomerName'] = $CustomerName }
if (-not $config.FrontendUrl) {
    throw 'Config.psd1 does not set FrontendUrl. Rebuild the package with the customer endpoint, or pass -FrontendUrl for a test install.'
}
# Validated here, not only on the -CustomerName parameter: a name that comes straight from
# Config.psd1 must meet the same rules, or the package installs cleanly and then every
# default Write-CMTraceLog call on the device fails on an unusable folder name.
if ($config.Contains('CustomerName') -and $config.CustomerName) {
    $reserved = @('CON', 'PRN', 'AUX', 'NUL', 'CLOCK$',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    $name = [string] $config.CustomerName
    if ($name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\z' -or $name -cmatch '[. ]\z' -or
        ($name -split '\.')[0].ToUpperInvariant() -in $reserved) {
        throw ("CustomerName '$name' is not usable as a folder name under %ProgramData%: use 1-64 " +
            'characters, starting with a letter or digit, containing only letters, digits, space, dot, ' +
            'underscore or hyphen, not ending in a dot or space, and not a reserved Windows device name.')
    }
}

$manifestPath = Join-Path $PSScriptRoot 'Modules\LogCollector.Client.psd1'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Incomplete package: Modules\LogCollector.Client.psd1 is missing."
}
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
if ($manifest.Version.ToString() -ne $packageVersion) {
    throw "Bundled module is version $($manifest.Version) but this installer is $packageVersion; the two are shipped together and must match."
}

Import-Module (Join-Path $PSScriptRoot 'Core.Provisioning.psm1') -Force -ErrorAction Stop
# Validate the endpoint with the same function the client uses at submission time, so an
# endpoint that installs can never be one the client would later refuse.
$endpointModule = Import-Module (Join-Path $PSScriptRoot 'Modules\EndpointConfiguration.psm1') -PassThru -Force -ErrorAction Stop
& $endpointModule { param($Url) Assert-LogCollectorEndpoint -FrontendUrl ([Uri] $Url) } $config.FrontendUrl

$files = @('LogCollector.Client.psd1')
foreach ($file in $manifest.FileList) { $files += (Split-Path $file -Leaf) }
$files = @($files | Select-Object -Unique)
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "Modules\$file") -PathType Leaf)) {
        throw "Incomplete package: Modules\$file"
    }
}

$target = Get-LogCollectorModuleRoot -Version $packageVersion
if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -eq $target.TrimEnd('\')) {
    throw 'Run Install.ps1 from the distribution folder, not the installed directory.'
}

if ($PSCmdlet.ShouldProcess($target, 'Install the LogCollector core module machine-wide')) {
    # Harden the parent too. Protecting only the version directory is not enough: a principal
    # holding create/delete-child rights on the parent can rename it away and put its own
    # directory at the same path, which SYSTEM-scheduled work would then import.
    $moduleRoot = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $moduleRoot -Force -ErrorAction Stop
    }
    Set-LogCollectorMachineAcl -Path $moduleRoot
    Assert-LogCollectorMachineAcl -Path $moduleRoot

    # Stage the complete version beside the live one and swap by rename, so a failure part
    # way through never leaves an importable but incomplete module on the device.
    $stage = '{0}.staging-{1}' -f $target, ([guid]::NewGuid().ToString('N'))
    $retired = $null
    try {
        $null = New-Item -ItemType Directory -Path $stage -Force -ErrorAction Stop
        Set-LogCollectorMachineAcl -Path $stage
        foreach ($file in $files) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Modules\$file") -Destination (Join-Path $stage $file) -Force -ErrorAction Stop
        }
        Set-LogCollectorMachineAcl -Path $stage
        Assert-LogCollectorMachineAcl -Path $stage
        foreach ($file in $files) {
            Set-LogCollectorMachineAcl -Path (Join-Path $stage $file)
            Assert-LogCollectorMachineAcl -Path (Join-Path $stage $file)
        }

        if (Test-Path -LiteralPath $target -PathType Container) {
            # Rename first: a recursive delete of the live directory can fail part way and
            # would otherwise leave the installed version broken with no replacement ready.
            $retired = '{0}.retired-{1}' -f $target, ([guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $target -Destination $retired -ErrorAction Stop
        }
        try {
            Move-Item -LiteralPath $stage -Destination $target -ErrorAction Stop

            Assert-LogCollectorMachineAcl -Path $target
            foreach ($file in $files) { Assert-LogCollectorMachineAcl -Path (Join-Path $target $file) }

            $settings = [ordered] @{
                FrontendUrl       = [string] $config.FrontendUrl
                SubmissionEnabled = [bool] $config.SubmissionEnabled
                Environment       = [string] $config.Environment
                PackageVersion    = $packageVersion
            }
            foreach ($key in @('CustomerName', 'CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
                    'PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
                if ($config.Contains($key) -and $config[$key]) { $settings[$key] = $config[$key] }
            }
            $endpointPath = Join-Path $env:ProgramData 'LogCollector\Config\Endpoint.psd1'
            Write-LogCollectorEndpointConfiguration -Path $endpointPath -Configuration ([hashtable] $settings)

            # Prove the contract the package exists to provide: import by name from a clean
            # session that has never seen this path, and read the configuration back through
            # the ACL check. Passed as an encoded command rather than a temporary script file:
            # writing a script into the elevated user's %TEMP% and then executing it lets a
            # same-user, medium-integrity process race the file between creation and execution.
            $machineModulePath = @(
                (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsPowerShell\Modules'),
                (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
            ) -join ';'
            $probe = @"
`$ErrorActionPreference = 'Stop'
# Sanitize the module search path first. The inherited PSModulePath normally puts the
# user's Documents directory ahead of Program Files, so an unelevated same-user process
# could plant a matching module there and have this elevated child import it instead.
`$env:PSModulePath = '$machineModulePath'
Import-Module LogCollector.Client -RequiredVersion $packageVersion -ErrorAction Stop
`$loaded = Get-Module LogCollector.Client
if (`$loaded.ModuleBase -ne '$target') { throw ('Imported ' + `$loaded.ModuleBase + ' instead of the installed module.') }
if (-not (Get-Command Send-LogAnalyticsData -Module LogCollector.Client -ErrorAction SilentlyContinue)) { throw 'Send-LogAnalyticsData is not available.' }
Write-Output (Get-LogCollectorEndpointConfiguration).FrontendUrl
"@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
            $resolved = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
            if ($LASTEXITCODE -ne 0 -or ($resolved -join '') -notlike "*$($config.FrontendUrl)*") {
                throw "Post-install verification failed: $($resolved -join ' ')"
            }
        }
        catch {
            # Anything from the swap up to and including verification failed, so the new
            # version must not be left live. The retired copy is the only known-good
            # installation on the device: put it back before surfacing the original error.
            $failure = $_
            if ($retired -and (Test-Path -LiteralPath $retired -PathType Container)) {
                if (Test-Path -LiteralPath $target) {
                    $rejected = '{0}.failed-{1}' -f $target, ([guid]::NewGuid().ToString('N'))
                    Move-Item -LiteralPath $target -Destination $rejected -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $target)) {
                        Remove-Item -LiteralPath $rejected -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                if (Test-Path -LiteralPath $target) {
                    # The rejected version could not be moved aside, so restoring on top of it
                    # is impossible. Say so loudly: this needs manual recovery, and silently
                    # rethrowing would leave an unverified module live and look like a
                    # transient install failure.
                    throw ("Install failed and the previous version could not be restored: '$target' is still occupied " +
                        "by the rejected version and the known-good copy remains at '$retired'. Original error: $failure")
                }
                Move-Item -LiteralPath $retired -Destination $target -ErrorAction Stop
                $retired = $null
            }
            throw $failure
        }
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Only now, with the new version verified end to end, is the previous installation
    # redundant. A leftover `.retired-*` directory is inert: PSModulePath only considers
    # child directories whose name parses as a version.
    if ($retired -and (Test-Path -LiteralPath $retired)) {
        Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Output "Installed LogCollector core $packageVersion at $target; endpoint $($config.FrontendUrl); SubmissionEnabled=$($config.SubmissionEnabled)."
    if (-not $config.SubmissionEnabled) {
        Write-Warning 'SubmissionEnabled is false: scripts will spool locally instead of delivering until it is enabled.'
    }
}
