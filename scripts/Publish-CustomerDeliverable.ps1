#Requires -Version 5.1
<#
.SYNOPSIS
Builds the single folder handed to the customer: the Azure deployment package and a
self-contained generator for the shared Intune Win32 Core package.
.DESCRIPTION
Produces '<OutputRoot>\<version>' containing two ready-to-run entry points:

  1-Azure\Deploy-LogCollector.ps1   deploys infrastructure and the pre-built Function apps
  2-Intune\New-IntunePackage.ps1    builds the shared Core .intunewin package

The Azure part is produced by Publish-DeploymentPackage.ps1 and keeps its internal layout
untouched. The Intune part bundles the client sources so the customer never needs this
repository, the .NET SDK or PowerShell modules from the build machine: only the Azure CLI
(to deploy) and Microsoft's IntuneWinAppUtil.exe (to package).
.PARAMETER OutputRoot
Folder under which a versioned deliverable folder is created. Defaults to '<repo>\out\Customer'.
.PARAMETER ParameterFile
Bicep parameter file bundled as the deployment default. Defaults to
'infra\logcollector.bicepparam'.
.NOTES
Version 1.0.0. Builds via dotnet publish; makes no changes to Azure resources and never
overwrites an existing deliverable.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()] [string] $OutputRoot,
    [ValidateNotNullOrEmpty()] [string] $ParameterFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $repo 'out\Customer' }

function Get-ProjectVersion {
    param([string] $CsprojPath)
    if (-not (Test-Path -LiteralPath $CsprojPath -PathType Leaf)) { throw "Project file not found: $CsprojPath" }
    $xml = [xml](Get-Content -LiteralPath $CsprojPath -Raw)
    $node = $xml.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
    if (-not $node) { throw "No <Version> element found in $CsprojPath" }
    return [string]$node
}
$solutionVersion = Get-ProjectVersion (Join-Path $repo 'src\Functions\Frontend\LogCollector.Frontend.csproj')
$clientModules = Join-Path $repo 'src\Client'
$coreSource = Join-Path $repo 'src\CorePackage'
$coreFiles = @('Config.psd1', 'Core.Provisioning.psm1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')

$target = Join-Path $OutputRoot $solutionVersion
if (Test-Path -LiteralPath $target) { throw "Output already exists: $target. Use a new OutputRoot; deliverables are never overwritten." }

# The parameter file is copied verbatim into a folder handed to an external party, so refuse
# anything that looks like a tenant/subscription id or an embedded secret rather than trusting
# the operator to have picked a customer-neutral file.
$parameterFileToScan = if ($PSBoundParameters.ContainsKey('ParameterFile')) { $ParameterFile } else { Join-Path $repo 'infra\logcollector.bicepparam' }
if (-not (Test-Path -LiteralPath $parameterFileToScan -PathType Leaf)) { throw "Parameter file not found: $parameterFileToScan" }
$parameterText = Get-Content -LiteralPath $parameterFileToScan -Raw
# Only the *name-based* rule below runs against comment-stripped text: a remark such as
# "// ask for the password out of band" is not a secret and used to reject clean files.
# Every other rule runs against the ORIGINAL text, because the comment stripper is not
# string-aware and would truncate 'https://host?sv=..&sig=SECRET' at the '//', hiding the
# very secret the sig= rule exists to catch. A GUID or key inside a comment is still a
# leak, so scanning the raw text there is also the safer behaviour.
$commentless = [regex]::Replace($parameterText, '/\*.*?\*/', ' ', 'Singleline')
$commentless = [regex]::Replace($commentless, '(?m)//.*$', ' ')
$guids = @([regex]::Matches($parameterText, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
if ($guids.Count -gt 0) {
    throw ("Parameter file '$parameterFileToScan' contains GUID(s) that may identify a tenant, " +
        "subscription or customer and must not be delivered: " + ($guids -join ', '))
}
# Names that carry a secret, matched only where they are a parameter or property being assigned,
# so prose no longer trips the scan while the assignments that actually matter still do.
$secretNames = 'password|passwd|pwd|secret|clientSecret|connectionString|apiKey|accessToken|sasToken|sharedAccessKey|accountKey|credential'
$namePattern = "(?im)(?:^\s*(?:param|var)\s+|['`"]?\b)($secretNames)\b['`"]?\s*[:=]"
foreach ($rule in @(
        @{ Pattern = $namePattern;            Text = $commentless },
        @{ Pattern = 'AccountKey\s*=';        Text = $parameterText },
        @{ Pattern = 'SharedAccessKey\s*=';   Text = $parameterText },
        @{ Pattern = '[?&]sig=';              Text = $parameterText },
        @{ Pattern = '-----BEGIN';            Text = $parameterText })) {
    $hit = [regex]::Match($rule.Text, $rule.Pattern)
    if ($hit.Success) {
        throw "Parameter file '$parameterFileToScan' matches the secret pattern '$($rule.Pattern)' (near '$($hit.Value.Trim())') and must not be delivered."
    }
}
# Opaque blobs (PFX/PKCS#12, embedded certificates) survive every name-based rule above.
$blob = [regex]::Match($parameterText, '[A-Za-z0-9+/]{200,}={0,2}')
if ($blob.Success) {
    throw ("Parameter file '$parameterFileToScan' contains a $($blob.Value.Length)-character opaque " +
        'base64 blob, which may be certificate or key material, and must not be delivered.')
}

foreach ($file in $coreFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $coreSource $file) -PathType Leaf)) { throw "Missing core package source: $file" }
}
$moduleManifest = Test-ModuleManifest -Path (Join-Path $clientModules 'LogCollector.Client.psd1') -ErrorAction Stop
# The core installer refuses a module whose version differs from its own, so a mismatch must
# fail while building the deliverable rather than on every device at install time.
$coreVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $coreSource 'Config.psd1')).PackageVersion
if ($coreVersion -ne $moduleManifest.Version.ToString()) {
    throw ("Core package version '$coreVersion' does not match the shared module version " +
        "'$($moduleManifest.Version)'. They ship together and must be bumped together.")
}

if (-not $PSCmdlet.ShouldProcess($target, 'Create customer deliverable (Azure deployment package + Intune package generator)')) { return }

$null = New-Item -ItemType Directory -Path $target -Force

# --- 1-Azure -------------------------------------------------------------------------
$azureArgs = @{ OutputRoot = Join-Path $target 'azure-staging' }
if ($PSBoundParameters.ContainsKey('ParameterFile')) { $azureArgs.ParameterFile = $ParameterFile }
$azure = & (Join-Path $PSScriptRoot 'Publish-DeploymentPackage.ps1') @azureArgs | Select-Object -Last 1
Move-Item -LiteralPath $azure.PackagePath -Destination (Join-Path $target '1-Azure')
Remove-Item -LiteralPath (Join-Path $target 'azure-staging') -Recurse -Force

# --- 2-Intune ------------------------------------------------------------------------
$intune = Join-Path $target '2-Intune'
$corePayload = Join-Path $intune 'CoreSource'
$null = New-Item -ItemType Directory -Path (Join-Path $corePayload 'Modules') -Force
foreach ($file in $coreFiles) { Copy-Item -LiteralPath (Join-Path $coreSource $file) -Destination (Join-Path $corePayload $file) }
foreach ($file in $moduleManifest.FileList) {
    $name = Split-Path $file -Leaf
    Copy-Item -LiteralPath (Join-Path $clientModules $name) -Destination (Join-Path $corePayload "Modules\$name")
}

$intuneGenerator = @'
#Requires -Version 5.1
<#
.SYNOPSIS
Builds the shared LogCollector Core .intunewin package for deployment as an Intune Win32 app.
.DESCRIPTION
Self-contained: uses only the CoreSource folder shipped next to this script. The Core package
installs LogCollector.Client and its protected endpoint configuration; it does not collect
inventory, create scheduled tasks or package any application script.
.PARAMETER IntuneWinAppUtilPath
Path to Microsoft's IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Optional: if
omitted, the script looks for it in the 'Tools' folder next to this script (recursively),
then on PATH. Simply dropping IntuneWinAppUtil.exe into '.\Tools\' is enough.
The executable must carry a valid Authenticode signature issued to Microsoft Corporation.
Download: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
.PARAMETER FrontendUrl
Intake endpoint, e.g. https://<prefix>-logcollector-intake.azurewebsites.net/api/submit.
Printed by Deploy-LogCollector.ps1 as 'frontendIngestUrl'.
.PARAMETER Environment
Free-text environment tag recorded with every record (e.g. Production, Pilot).
.PARAMETER CustomerName
Customer folder used by Write-CMTraceLog, so every script on the device logs to
%ProgramData%\<CustomerName>\<ApplicationName>\Logs. Defaults to 'LogCollector'.
.EXAMPLE
.\New-IntunePackage.ps1 -FrontendUrl https://aci-logcollector-intake.azurewebsites.net/api/submit
Uses .\Tools\IntuneWinAppUtil.exe and builds the Core package.
.EXAMPLE
.\New-IntunePackage.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe `
  -FrontendUrl https://aci-logcollector-intake.azurewebsites.net/api/submit `
  -CustomerName ACIInformatica -Environment Production
.NOTES
The generated package collects nothing and registers no scheduled task.
Existing output folders are never overwritten.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $IntuneWinAppUtilPath,
    [Parameter(Mandatory)] [Uri] $FrontendUrl,
    [string] $Environment = '',
    [ValidatePattern('^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])$')] [string] $CustomerName = 'LogCollector',
    [string[]] $PkiRootCaThumbprints = @(),
    [string[]] $PkiRootCaSubjects = @(),
    [string[]] $PkiIntermediateCaThumbprints = @(),
    [string[]] $PkiIntermediateCaSubjects = @(),
    [ValidateNotNullOrEmpty()] [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($FrontendUrl.Scheme -ne 'https') {
    throw "FrontendUrl must use https; '$($FrontendUrl.Scheme)' would send signed inventory in clear text."
}
# A reserved DOS device name is still reserved as a folder, so it would produce a package
# that builds cleanly and then fails on every device the moment a script logs. Rejected
# here, where the operator can still fix it, rather than at deployment time.
if (($CustomerName -split '\.')[0].ToUpperInvariant() -in @('CON', 'PRN', 'AUX', 'NUL', 'CLOCK$',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')) {
    throw "CustomerName '$CustomerName' is a reserved Windows device name and cannot be a log folder."
}
$coreSource = Join-Path $PSScriptRoot 'CoreSource'
if (-not (Test-Path -LiteralPath $coreSource -PathType Container)) {
    throw "CoreSource folder not found next to this script: $coreSource. Copy the whole 2-Intune folder, not just this script."
}
$coreFiles = @('Config.psd1', 'Core.Provisioning.psm1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $PSScriptRoot 'Output' }

$moduleFiles = @('LogCollector.Client.psd1', 'LogCollector.Client.psm1', 'EndpointConfiguration.psm1',
    'CMTraceLogging.psm1', 'DeviceIdentity.psm1', 'RequestSigning.psm1', 'InventoryClient.psm1', 'InventorySpool.psm1')
foreach ($file in $coreFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $coreSource $file) -PathType Leaf)) { throw "Missing core package source: $file" }
}
foreach ($file in $moduleFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $coreSource "Modules\$file") -PathType Leaf)) { throw "Missing core package source: Modules\$file" }
}

if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath') -and $IntuneWinAppUtilPath) {
    $tool = Get-Item -LiteralPath $IntuneWinAppUtilPath -ErrorAction Stop
}
else {
    # Convention over configuration: dropping the tool into .\Tools\ is enough. Searched
    # recursively so an unzipped release folder works as-is. Ambiguity is never resolved by
    # guessing: "v1.9" would sort above "v1.10", so two candidates are an error, not a choice.
    $toolsRoot = Join-Path $PSScriptRoot 'Tools'
    $tool = $null
    if (Test-Path -LiteralPath $toolsRoot -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $toolsRoot -Filter 'IntuneWinAppUtil.exe' -Recurse -File -ErrorAction SilentlyContinue)
        if ($found.Count -gt 1) {
            throw ("Found $($found.Count) copies of IntuneWinAppUtil.exe under '$toolsRoot'; " +
                'keep only one or pass -IntuneWinAppUtilPath explicitly. Candidates: ' +
                (($found | ForEach-Object { $_.FullName }) -join '; '))
        }
        if ($found.Count -eq 1) { $tool = $found[0] }
    }
    if (-not $tool) {
        $onPath = Get-Command 'IntuneWinAppUtil.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) { $tool = Get-Item -LiteralPath $onPath.Source }
    }
    if (-not $tool) {
        throw ("IntuneWinAppUtil.exe was not found. Place it in '$toolsRoot' (any subfolder), " +
            'add it to PATH, or pass -IntuneWinAppUtilPath. Download it from ' +
            'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool')
    }
    Write-Verbose "Using content prep tool: $($tool.FullName)"
}
if ($tool.PSIsContainer -or $tool.Extension -ne '.exe') { throw 'Supply the official IntuneWinAppUtil.exe file.' }

# This executable is about to be run, and with discovery it may not have been chosen by hand,
# so an .exe extension is not evidence of anything. Require a valid Microsoft signature.
$signature = Get-AuthenticodeSignature -LiteralPath $tool.FullName -ErrorAction Stop
if ($signature.Status -ne 'Valid') {
    throw ("'$($tool.FullName)' does not carry a valid Authenticode signature (status: " +
        "$($signature.Status)). Download the official tool from " +
        'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool')
}
$signer = $signature.SignerCertificate.Subject
if ($signer -notmatch '(?i)O=Microsoft Corporation') {
    throw "'$($tool.FullName)' is signed by '$signer', not by Microsoft Corporation; refusing to run it."
}
Write-Verbose "Content prep tool signature verified: $signer"

$coreConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $coreSource 'Config.psd1')
$coreVersion = $coreConfig.PackageVersion
$coreConfig.FrontendUrl = $FrontendUrl.AbsoluteUri
$coreConfig.Environment = $Environment
$coreConfig.CustomerName = $CustomerName
$coreConfig.SubmissionEnabled = $true
$coreConfig.PkiRootCaThumbprints = $PkiRootCaThumbprints
$coreConfig.PkiRootCaSubjects = $PkiRootCaSubjects
$coreConfig.PkiIntermediateCaThumbprints = $PkiIntermediateCaThumbprints
$coreConfig.PkiIntermediateCaSubjects = $PkiIntermediateCaSubjects
foreach ($key in @('PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
    foreach ($entry in $coreConfig[$key]) {
        if ([string]::IsNullOrWhiteSpace($entry)) { throw "$key contains an empty entry." }
        if ($key -like '*Thumbprints' -and ($entry -replace '[\s:]', '') -notmatch '^[0-9a-fA-F]{40}$') {
            throw "$key entries must be SHA1 certificate thumbprints (40 hexadecimal digits)."
        }
    }
}

$release = [IO.Path]::GetFullPath((Join-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)) $coreVersion))
if ($release.Contains('"')) { throw 'Output paths must not contain double quotes.' }
if (Test-Path -LiteralPath $release) { throw "Output already exists: $release. Choose a new OutputRoot; releases are never overwritten." }
if (-not $PSCmdlet.ShouldProcess($release, 'Build the LogCollector Core .intunewin package')) { return }

# Rewrite Config.psd1 deterministically so its hash matches what Detect.ps1 will look for.
function ConvertTo-ConfigurationText {
    param([Parameter(Mandatory)] [hashtable] $Configuration)
    $lines = @('@{')
    foreach ($key in @($Configuration.Keys | Sort-Object)) {
        $value = $Configuration[$key]
        if ($value -is [bool]) { $literal = '$' + $value.ToString().ToLowerInvariant() }
        elseif ($value -is [int]) { $literal = $value.ToString([Globalization.CultureInfo]::InvariantCulture) }
        elseif ($value -is [string]) { $literal = "'" + $value.Replace("'", "''") + "'" }
        elseif ($value -is [array]) {
            $items = @($value | ForEach-Object {
                if ($_ -isnot [string]) { throw "Only strings are supported in configuration array $key." }
                "'" + $_.Replace("'", "''") + "'"
            })
            $literal = '@(' + ($items -join ', ') + ')'
        }
        else { throw "Unsupported configuration value type for $key." }
        $lines += "    $key = $literal"
    }
    $lines += '}'
    return ($lines -join "`r`n")
}
function ConvertTo-CoreDetectionPayload {
    param([Parameter(Mandatory)] [hashtable] $Configuration)

    $expected = [ordered] @{}
    foreach ($key in @('FrontendUrl', 'Environment', 'CustomerName', 'SubmissionEnabled', 'PackageVersion',
            'CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
            'PkiRootCaThumbprints', 'PkiRootCaSubjects',
            'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
        if (-not $Configuration.Contains($key)) {
            throw "Core configuration does not define required detection value '$key'."
        }
        $expected[$key] = $Configuration[$key]
    }

    $json = [pscustomobject] $expected | ConvertTo-Json -Depth 4 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}
$coreStaging = Join-Path $release 'Source'
$null = New-Item -ItemType Directory -Path (Join-Path $coreStaging 'Modules') -Force
foreach ($file in $coreFiles) {
    Copy-Item -LiteralPath (Join-Path $coreSource $file) -Destination (Join-Path $coreStaging $file) -ErrorAction Stop
}
foreach ($file in $moduleFiles) {
    Copy-Item -LiteralPath (Join-Path $coreSource "Modules\$file") -Destination (Join-Path $coreStaging "Modules\$file") -ErrorAction Stop
}
$coreConfigPath = Join-Path $coreStaging 'Config.psd1'
[IO.File]::WriteAllText($coreConfigPath, (ConvertTo-ConfigurationText -Configuration $coreConfig), [Text.UTF8Encoding]::new($false))
$coreDetectionPath = Join-Path $coreStaging 'Detect.ps1'
$coreDetection = [IO.File]::ReadAllText($coreDetectionPath)
$coreDetectionMarker = '__LOGCOLLECTOR_CORE_EXPECTED_CONFIGURATION_BASE64__'
if (-not $coreDetection.Contains($coreDetectionMarker)) {
    throw 'Core detection template is missing its expected-configuration marker.'
}
$coreDetectionPayload = ConvertTo-CoreDetectionPayload -Configuration $coreConfig
$coreDetection = $coreDetection.Replace($coreDetectionMarker, $coreDetectionPayload)
[IO.File]::WriteAllText($coreDetectionPath, $coreDetection, [Text.UTF8Encoding]::new($false))
$null = Test-ModuleManifest -Path (Join-Path $coreStaging 'Modules\LogCollector.Client.psd1') -ErrorAction Stop

$coreOutput = Join-Path $release 'Package'
$null = New-Item -ItemType Directory -Path $coreOutput -Force
$coreArguments = @('-c', ('"{0}"' -f $coreStaging), '-s', 'Install.ps1', '-o', ('"{0}"' -f $coreOutput), '-qq')
$coreProcess = Start-Process -FilePath $tool.FullName -ArgumentList $coreArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
if ($coreProcess.ExitCode -ne 0) { throw "IntuneWinAppUtil failed for the core package with exit code $($coreProcess.ExitCode). Output retained at $release." }
$coreArtifact = Join-Path $coreOutput 'Install.intunewin'
if (-not (Test-Path -LiteralPath $coreArtifact -PathType Leaf) -or (Get-Item -LiteralPath $coreArtifact).Length -eq 0) {
    throw "IntuneWinAppUtil produced no nonempty core Install.intunewin. Output retained at $release."
}
Copy-Item -LiteralPath (Join-Path $coreStaging 'Detect.ps1') -Destination (Join-Path $release 'Detect.ps1')
[pscustomobject]@{
    PackageVersion   = $coreVersion
    IntuneWinPackage = $coreArtifact
    PackageSha256    = (Get-FileHash -LiteralPath $coreArtifact -Algorithm SHA256).Hash
    DetectionScript  = Join-Path $release 'Detect.ps1'
    ConfigurationSha256 = (Get-FileHash -LiteralPath $coreConfigPath -Algorithm SHA256).Hash
    InstallCommand   = '"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Install.ps1"'
    UninstallCommand = '"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Uninstall.ps1"'
    ContentPrepTool = $tool.FullName
}
'@
[IO.File]::WriteAllText((Join-Path $intune 'New-IntunePackage.ps1'), $intuneGenerator, [Text.UTF8Encoding]::new($false))

# Microsoft's content prep tool cannot be redistributed, so ship the drop location and the
# instructions instead: New-IntunePackage.ps1 searches this folder recursively.
$toolsDir = Join-Path $intune 'Tools'
$null = New-Item -ItemType Directory -Path $toolsDir -Force
$toolsReadme = @"
# Tools

Place Microsoft's **IntuneWinAppUtil.exe** (Win32 Content Prep Tool) in this folder.
``New-IntunePackage.ps1`` searches here recursively, so either the bare executable or the
whole unzipped release folder works, and no ``-IntuneWinAppUtilPath`` argument is needed.
Keep only **one** copy here: if several are found the generator stops and lists them rather
than guessing which one you meant.

Download: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

The executable is verified before it is run: it must carry a valid Authenticode signature
issued to **Microsoft Corporation**. Download it only from the official repository above.

The tool is Microsoft's and is not redistributed with this delivery. If it is absent, the
generator also looks on ``PATH``, and otherwise fails with a message pointing back here.
"@
[IO.File]::WriteAllText((Join-Path $toolsDir 'README.md'), $toolsReadme, [Text.UTF8Encoding]::new($false))

$intuneGuide = @"
# Deploying LogCollector Core with Intune

Core package version **$coreVersion**. This package installs only the shared
``LogCollector.Client`` PowerShell module and its protected machine-wide configuration.
It does not contain inventory collectors, application scripts or scheduled tasks.

## 1. Prerequisites

* **IntuneWinAppUtil.exe** - Microsoft Win32 Content Prep Tool.
  Download: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
  Microsoft's licence does not allow us to redistribute it, so it is **not** included here.
  Drop the downloaded ``IntuneWinAppUtil.exe`` (or the whole unzipped release folder) into
  ``2-Intune\Tools\`` and the generator finds it by itself - no path parameter needed.
  Alternatively pass ``-IntuneWinAppUtilPath`` or put it on ``PATH``.
  Whatever the source, the generator refuses to run it unless it carries a valid Authenticode
  signature issued to Microsoft Corporation, so download it only from the official repository.
* Windows PowerShell 5.1 or PowerShell 7 to run the generator.
* The intake endpoint of your deployment, printed by ``1-Azure\Deploy-LogCollector.ps1`` as
  **``frontendIngestUrl``**.
* Intune permissions to create and assign a Win32 app.
* The application packages, including Inventory, are maintained and deployed separately.

## 2. Build the Core package

``````powershell
.\New-IntunePackage.ps1 ``
  -FrontendUrl  https://<prefix>-logcollector-intake.azurewebsites.net/api/submit ``
  -CustomerName ACIInformatica ``
  -Environment  Production
``````

(With ``IntuneWinAppUtil.exe`` in ``.\Tools\`` no tool path is needed; otherwise add
``-IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe``.)

The command prints ``ContentPrepTool``, ``PackageSha256`` and ``ConfigurationSha256``.
It produces one Core release:

| Path | Contents |
| --- | --- |
| ``Output\$coreVersion\Package\Install.intunewin`` | Core package to upload to Intune |
| ``Output\$coreVersion\Detect.ps1`` | Configuration-bound Core detection script |
| ``Output\$coreVersion\Source`` | Core installer, configuration and module files |

``Source`` and ``Package`` are kept apart so the tool never wraps its own output.

### Optional parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| ``-Environment`` | *(empty)* | Free-text tag stored with every record |
| ``-CustomerName`` | ``LogCollector`` | Customer folder used by shared CMTrace logs |
| ``-PkiRootCaThumbprints`` | ``@()`` | Restrict client certificates to specific root CAs |
| ``-PkiIntermediateCaThumbprints`` | ``@()`` | Restrict to specific intermediate CAs |

By default the client selects its **Intune device certificate** automatically. The PKI
parameters are only needed when the endpoints must present a certificate from your own PKI.

## 3. Create the Win32 app in Intune

**Apps > Windows > Add > Windows app (Win32)**, then upload
``Output\$coreVersion\Package\Install.intunewin``.

**Program** page - each command is a single line:

Install command:

``````text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Install.ps1"
``````

Uninstall command:

``````text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Uninstall.ps1"
``````

``Sysnative`` prevents Intune Management Extension from redirecting to 32-bit PowerShell,
which the installer refuses. For manual tests from an already 64-bit console use
``System32`` instead, and expand the variables with PowerShell syntax rather than ``%...%``.

| Setting | Value |
| --- | --- |
| Install behavior | System |
| Device restart behavior | No specific action |
| Return codes | 0 = Success, 1 = Failed |

**Requirements**: Windows 10 1809 / Windows 11 or later, 64-bit.

**Detection rules**: *Use a custom detection script* and upload
``Output\$coreVersion\Detect.ps1``. Leave *Run script as 32-bit process* **unchecked** and
*Enforce script signature check* unchecked. The generated detection verifies the module
version and the exact endpoint, environment, customer name, submission state and PKI
criteria selected for this build.

**Assignments**: assign to a device group. Start with a small pilot ring.

Configure **LogCollector Core** as a dependency of each separate application package that
imports ``LogCollector.Client``. Inventory is one such application package; it is not
created or modified by this generator.

## 4. Validate the Core pilot

On a targeted device, after the app installs:

``````powershell
(Get-Module -ListAvailable LogCollector.Client | Sort-Object Version -Descending |
    Select-Object -First 1).Version
Import-Module LogCollector.Client -MinimumVersion $coreVersion -ErrorAction Stop
Get-LogCollectorEndpointConfiguration
``````

The returned configuration must show the expected ``FrontendUrl``, ``Environment`` and
``CustomerName``. Core itself performs no collection and registers no task. Test data
submission from the pilot version of an application package, not from Core installation.

``````powershell
Get-Content "`$env:ProgramData\LogCollector\Config\Endpoint.psd1"
``````

## 5. Troubleshooting

| Symptom | Cause and remedy |
| --- | --- |
| Core reported *Not installed* after a successful install | Upload the ``Detect.ps1`` produced by the same generator run as the Core ``.intunewin``. |
| Application script cannot import the module | Verify its Win32 App declares LogCollector Core as a dependency and runs in 64-bit PowerShell. |
| Configuration shows the previous endpoint | Replace both the Core ``.intunewin`` and detection script, then force an Intune sync. |
| Install fails immediately | Verify the install command uses ``Sysnative``; the installer refuses 32-bit PowerShell. |

## 6. Upgrading

For configuration-only changes, keep the software version and rebuild with the new values,
then replace both package and detection in the existing Core Win32 App. For code changes,
bump the Core/module version before rebuilding. Application packages are upgraded through
their own source, packaging and detection lifecycle.
"@
[IO.File]::WriteAllText((Join-Path $intune 'Intune-Deployment.md'), $intuneGuide, [Text.UTF8Encoding]::new($false))

# --- Instructions and manifest --------------------------------------------------------
# Placeholder so the README is on disk (and therefore hashed) before the manifest is built;
# MANIFEST.json is the only file it cannot cover, since it cannot hash itself.
$readmePath = Join-Path $target 'README.md'

$readme = @"
# LogCollector $solutionVersion - delivery package

Core PowerShell package version: **$coreVersion**.

Everything needed to deploy the LogCollector Azure services and build the shared Core
PowerShell dependency. Application packages such as Inventory are maintained separately
and are not generated by this deliverable.

| Folder | Purpose |
| --- | --- |
| ``1-Azure`` | Deploys infrastructure and the pre-built Function apps |
| ``2-Intune`` | Builds the shared Core ``.intunewin`` package |
| ``2-Intune\CoreSource`` | Payload of the shared **core dependency** package |
| ``2-Intune\Tools`` | Drop ``IntuneWinAppUtil.exe`` here; it is found automatically |

## Prerequisites

* **Azure CLI** (``az``), signed in with ``az login``. Rights to create resources in the
  target resource group, plus User Access Administrator (the template creates role assignments).
* **IntuneWinAppUtil.exe** - Microsoft Win32 Content Prep Tool, for step 2 only.
  Download: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
  We cannot redistribute it; copy it into ``2-Intune\Tools\`` and it is picked up
  automatically (see ``2-Intune\Tools\README.md``).
* Windows PowerShell 5.1 or PowerShell 7.

## Step 1 - deploy to Azure

``````powershell
cd 1-Azure
.\Deploy-LogCollector.ps1 ``
  -SubscriptionId <subscription-id> ``
  -ResourceGroup  <resource-group> ``
  -Location       italynorth ``
  -CustomerPrefix <short-code>
``````

``-CustomerPrefix`` (max 8 alphanumeric characters, e.g. your company code) is prepended to
every resource name. Storage account, Service Bus namespace and Function app names must be
globally unique across Azure, so set it on the **first** deployment; changing it later
renames rather than migrates the resources. See ``1-Azure\README.md`` for the naming table,
collision handling and troubleshooting.

Add ``-WhatIf`` to preview without changing anything.

When it finishes the script prints **``frontendIngestUrl``**. Copy it: step 2 needs it.

## Step 2 - build the Core Intune package

``````powershell
cd 2-Intune
.\New-IntunePackage.ps1 ``
  -FrontendUrl  <frontendIngestUrl from step 1> ``
  -CustomerName <customer-name> ``
  -Environment  Production
``````

The script prints the paths to use in Intune:

| Intune field | Value |
| --- | --- |
| App package file | ``Output\$coreVersion\Package\Install.intunewin`` |
| Detection rule | Custom script -> ``Output\$coreVersion\Detect.ps1`` (do NOT tick "run as 32-bit") |
| Install behaviour | System |

Create one Win32 App named **LogCollector Core**. Always upload ``Detect.ps1`` produced by
the same build as the Core ``.intunewin``.
It is bound to the requested endpoint, environment, customer name, submission state and PKI
criteria. Rebuilding with changed configuration therefore remediates devices that still hold
the previous configuration without requiring a software-version bump.

Assign the core app to every device that runs any script which writes to Log Analytics, not
only to Inventory devices. Configure it as a dependency of each separately maintained
application Win32 App. It is what lets an arbitrary script do:

``````powershell
Import-Module LogCollector.Client
Send-LogAnalyticsData -LogType 'W11Upgrade' -Body (`$events | ConvertTo-Json)
``````

with no workspace key and no endpoint URL of its own. See ``2-Intune\CoreSource\README.md``.
Inventory and every other migrated script retain their own package, installer, detection,
assignment and upgrade lifecycle.

Install and uninstall command lines (they must use ``Sysnative``, the installer refuses
32-bit PowerShell) are given in full in ``2-Intune\Intune-Deployment.md``, together with the
pilot validation procedure and troubleshooting.

Assign the app to a device group.

## Client authentication

Devices authenticate with mutual TLS using their **Intune device certificate**; no secrets,
keys or passwords are placed on the endpoints. The intake endpoint rejects any request
without a valid client certificate, so a plain browser request to ``/api/health`` returning
**403 "Client Certificate Required"** confirms the service is healthy.

## Integrity

``MANIFEST.json`` lists the SHA256 of every delivered file except itself. To verify after transfer:

``````powershell
`$m = Get-Content MANIFEST.json -Raw | ConvertFrom-Json
`$m.Files.PSObject.Properties | ForEach-Object {
    `$actual = (Get-FileHash -LiteralPath `$_.Name -Algorithm SHA256).Hash
    '{0}: {1}' -f `$_.Name, `$(if (`$actual -eq `$_.Value) { 'OK' } else { 'MISMATCH' })
}
``````
"@
[IO.File]::WriteAllText($readmePath, $readme, [Text.UTF8Encoding]::new($false))

$commit = (& git -C $repo rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $commit) { $commit = 'unknown' }
$hashes = [ordered]@{}
foreach ($file in Get-ChildItem -LiteralPath $target -File -Recurse) {
    $relative = $file.FullName.Substring($target.Length).TrimStart('\')
    $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}
$manifest = [ordered]@{
    SolutionVersion = $solutionVersion
    CorePackageVersion = $coreVersion
    BuiltAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceCommit = [string]$commit
    Note = 'Files covers every delivered file except MANIFEST.json, which cannot hash itself.'
    Files = $hashes
}
[IO.File]::WriteAllText((Join-Path $target 'MANIFEST.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    SolutionVersion = $solutionVersion
    CorePackageVersion = $coreVersion
    DeliverablePath = [IO.Path]::GetFullPath($target)
    AzureEntryPoint = Join-Path $target '1-Azure\Deploy-LogCollector.ps1'
    IntuneEntryPoint = Join-Path $target '2-Intune\New-IntunePackage.ps1'
    FileCount = @(Get-ChildItem -LiteralPath $target -File -Recurse).Count
    HashedFileCount = $hashes.Count
}
