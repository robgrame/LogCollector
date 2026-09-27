#Requires -Version 5.1
<#
.SYNOPSIS
Builds the complete customer release: Azure deployment, Core generator, prebuilt Inventory
Intune packages, documentation, integrity verification, ZIP archives and checksums.
.DESCRIPTION
Produces '<OutputRoot>\<version>' containing four customer-ready sections:

  1-Azure\Deploy-LogCollector.ps1   deploys infrastructure and the pre-built Function apps
  2-Intune                          shared Core source and post-deployment generator
  3-Inventory                       prebuilt Custom Inventory package and detection script
  4-Documentation                   component path references

The release folder also contains release notes, a strict SHA-256 verifier and a complete
manifest. Customer and Azure-only ZIP archives plus external SHA-256 sidecars are created
beside the versioned folder.
.PARAMETER OutputRoot
Folder under which a versioned deliverable folder is created. Defaults to '<repo>\out\Customer'.
.PARAMETER ParameterFile
Bicep parameter file bundled as the deployment default. Defaults to
'infra\logcollector.bicepparam'.
.PARAMETER DeviceTableName
Log Analytics device inventory table used by the Inventory package.
.PARAMETER AppTableName
Log Analytics application inventory table used by the Inventory package.
.PARAMETER IntuneWinAppUtilPath
Optional explicit path to Microsoft's signed IntuneWinAppUtil.exe. When omitted, the
canonical Core and Inventory builders search the repository tools folder and PATH.
.NOTES
Version 1.4.1. Builds via dotnet publish; makes no changes to Azure resources and never
overwrites an existing deliverable.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()] [string] $OutputRoot,
    [ValidateNotNullOrEmpty()] [string] $ParameterFile,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $DeviceTableName = 'DeviceInventory_CL',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $AppTableName = 'AppInventory_CL',
    [string] $IntuneWinAppUtilPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $repo 'out\Customer' }
$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
if ($PSBoundParameters.ContainsKey('ParameterFile')) {
    $ParameterFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ParameterFile)
}
if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath')) {
    $IntuneWinAppUtilPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $IntuneWinAppUtilPath)
}

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
$moduleManifestPath = Join-Path $clientModules 'LogCollector.Client.psd1'
$moduleManifestData = Import-PowerShellDataFile -LiteralPath $moduleManifestPath
$moduleManifest = Test-ModuleManifest -Path $moduleManifestPath -ErrorAction Stop
# The core installer refuses a module whose version differs from its own, so a mismatch must
# fail while building the deliverable rather than on every device at install time.
$coreVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $coreSource 'Config.psd1')).PackageVersion
if ($coreVersion -ne $moduleManifest.Version.ToString()) {
    throw ("Core package version '$coreVersion' does not match the shared module version " +
        "'$($moduleManifest.Version)'. They ship together and must be bumped together.")
}
$inventoryVersion = (Import-PowerShellDataFile -LiteralPath (
        Join-Path $repo 'src\InventoryPackage\Config.psd1')).PackageVersion
$sourceCommit = try {
    $resolvedCommit = (& git -C $repo rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $resolvedCommit) { 'unknown' } else { $resolvedCommit }
}
catch { 'unknown' }
$mutableParameterFile = "1-Azure\infra\$([IO.Path]::GetFileName($parameterFileToScan))"
$mutableParameterFileBase64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($mutableParameterFile))

$customerZip = Join-Path $OutputRoot "LogCollector-Customer-$solutionVersion.zip"
$deploymentZip = Join-Path $OutputRoot "LogCollector-Deployment-$solutionVersion.zip"
$customerChecksum = "$customerZip.sha256"
$deploymentChecksum = "$deploymentZip.sha256"
foreach ($output in @($target, $customerZip, $deploymentZip, $customerChecksum, $deploymentChecksum)) {
    if (Test-Path -LiteralPath $output) {
        throw "Output already exists: $output. Customer releases are never overwritten."
    }
}

if (-not $PSCmdlet.ShouldProcess(
        $target, 'Create complete customer release with Azure, Core generator, Inventory and documentation')) {
    return
}

$null = New-Item -ItemType Directory -Path $target -Force

# --- 1-Azure -------------------------------------------------------------------------
$azureArgs = @{ OutputRoot = Join-Path $target 'azure-staging' }
if ($PSBoundParameters.ContainsKey('ParameterFile')) { $azureArgs.ParameterFile = $ParameterFile }
$azure = & (Join-Path $PSScriptRoot 'Publish-DeploymentPackage.ps1') @azureArgs | Select-Object -Last 1
$azureTarget = Join-Path $target '1-Azure'
Move-Item -LiteralPath $azure.PackagePath -Destination $azureTarget
Remove-Item -LiteralPath (Join-Path $target 'azure-staging') -Recurse -Force

# --- 2-Intune: source and post-deployment Core generator -------------------------------
$intune = Join-Path $target '2-Intune'
$corePayload = Join-Path $intune 'CoreSource'
$null = New-Item -ItemType Directory -Path (Join-Path $corePayload 'Modules') -Force
foreach ($file in $coreFiles) {
    Copy-Item -LiteralPath (Join-Path $coreSource $file) -Destination (Join-Path $corePayload $file)
}
foreach ($file in $moduleManifestData.FileList) {
    $destination = Join-Path $corePayload "Modules\$file"
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $clientModules $file) -Destination $destination -ErrorAction Stop
}

$generatorSource = Join-Path $PSScriptRoot 'New-IntunePackage.ps1'
if (-not (Test-Path -LiteralPath $generatorSource -PathType Leaf)) {
    throw "Missing Intune package generator source: $generatorSource"
}
Copy-Item -LiteralPath $generatorSource -Destination (Join-Path $intune 'New-IntunePackage.ps1')

$toolsDir = Join-Path $intune 'Tools'
$null = New-Item -ItemType Directory -Path $toolsDir -Force
$toolsReadme = @"
# Microsoft Win32 Content Prep Tool

``IntuneWinAppUtil.exe`` is not redistributed in this release. Download the official,
Microsoft-signed tool from:
https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

Place one copy under this folder before rebuilding Core. The included generator validates
the Authenticode signature and refuses non-Microsoft or ambiguous executables.
"@
[IO.File]::WriteAllText(
    (Join-Path $toolsDir 'README.md'), $toolsReadme, [Text.UTF8Encoding]::new($false))

$coreGuide = @"
# Deploying LogCollector Core $coreVersion with Intune

Deploy Azure first. ``1-Azure\Deploy-LogCollector.ps1`` prints ``frontendIngestUrl``;
use that customer-specific URL to build Core:

``````powershell
.\New-IntunePackage.ps1 ``
  -FrontendUrl  <frontendIngestUrl> ``
  -CustomerName <customer-name> ``
  -Environment  Production
``````

The generator produces ``Output\$coreVersion\Package\Install.intunewin`` and a matching
``Output\$coreVersion\Detect.ps1``. Create a Windows Win32 app, run it in System context
with 64-bit PowerShell, and always upload both files from the same generator run.

Install command:

``````text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Install.ps1"
``````

Uninstall command:

``````text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\Uninstall.ps1" -ExpectedVersion $coreVersion
``````

Configure this app as a dependency of Inventory and every application package that imports
``LogCollector.Client``. Put the official signed ``IntuneWinAppUtil.exe`` under ``Tools``
before running ``New-IntunePackage.ps1``.
"@
[IO.File]::WriteAllText(
    (Join-Path $intune 'Intune-Deployment.md'), $coreGuide, [Text.UTF8Encoding]::new($false))

# --- 3-Inventory ---------------------------------------------------------------------
$inventoryBuildArgs = @{
    DeviceTableName = $DeviceTableName
    AppTableName = $AppTableName
    OutputRoot = Join-Path $target '3-Inventory'
}
if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath')) {
    $inventoryBuildArgs.IntuneWinAppUtilPath = $IntuneWinAppUtilPath
}
$inventoryPackage = & (Join-Path $PSScriptRoot 'Publish-IntuneWin32Package.ps1') `
    @inventoryBuildArgs | Select-Object -Last 1
$inventoryGuidePath = Join-Path $target "3-Inventory\$inventoryVersion\Intune-Deployment.md"
$inventoryGuide = [IO.File]::ReadAllText($inventoryGuidePath)
$inventoryHeader = @"
# Release-specific configuration

This package uses the endpoint configured centrally by LogCollector Core $coreVersion.
Deploy Core as an Intune dependency and upload
the ``.intunewin`` and ``Detect.ps1`` from this same release.

"@
[IO.File]::WriteAllText(
    $inventoryGuidePath, $inventoryHeader + $inventoryGuide, [Text.UTF8Encoding]::new($false))

# --- 4-Documentation ----------------------------------------------------------------
$documentation = Join-Path $target '4-Documentation'
$null = New-Item -ItemType Directory -Path $documentation -Force
foreach ($document in @(
        'paths-core-client.md',
        'paths-custom-inventory.md',
        'paths-other-scripts.md')) {
    Copy-Item -LiteralPath (Join-Path $repo "docs\$document") `
        -Destination (Join-Path $documentation $document) -ErrorAction Stop
}

# --- Customer instructions, release notes and verifier -------------------------------
$readme = @"
# LogCollector $solutionVersion - customer delivery

This is the complete deployment-ready customer release. Customer-specific Core configuration
is generated only after Azure returns the final intake URL.

| Section | Contents |
| --- | --- |
| ``1-Azure`` | Bicep, prebuilt Function ZIPs and ``Deploy-LogCollector.ps1`` |
| ``2-Intune`` | Core $coreVersion source and post-deployment package generator |
| ``3-Inventory`` | Prebuilt Custom Inventory $inventoryVersion package |
| ``4-Documentation`` | Installed-path and component reference documents |

## Deployment order

1. Run ``.\Verify-Delivery.ps1`` and independently compare the external ZIP checksum.
2. Deploy Azure with ``1-Azure\Deploy-LogCollector.ps1``.
3. Grant Microsoft Graph ``Device.Read.All`` application permission to the intake UAMI
   before enabling the pilot. The administrative helper remains only in the trusted source
   repository and is intentionally not bundled.
4. Run ``2-Intune\New-IntunePackage.ps1`` with the returned ``frontendIngestUrl``, customer
   name and environment. Upload the generated ``.intunewin`` with its matching
   ``Detect.ps1`` and assign it as **LogCollector Core**.
5. Upload ``3-Inventory\$inventoryVersion\Output\Install.intunewin`` with its matching
   ``Detect.ps1``. Configure LogCollector Core as its Intune dependency.

The generated Core configuration is the only endpoint-side location containing the intake
URL. Inventory reads the protected machine-wide Core configuration and does not require its
own endpoint.

Entra device validation is enabled by default. Successful Graph device checks are cached
per Function instance for 240 minutes; failures and disabled/missing devices are never cached.
If the customer cannot grant ``Device.Read.All``, set
``entraDeviceValidationEnabled = false`` in the bundled Bicep parameter file before deployment;
this is an explicit reduction in tenant-membership validation, not the default.

The PowerShell scripts and manifests are not Authenticode-signed. Treat a successful local
manifest check as necessary but not sufficient: compare the ZIP SHA-256 obtained through an
authenticated, independent channel before executing any script.
"@
[IO.File]::WriteAllText(
    (Join-Path $target 'README.md'), $readme, [Text.UTF8Encoding]::new($false))

$releaseNotesSource = Join-Path $repo "docs\release-notes\$solutionVersion.md"
if (-not (Test-Path -LiteralPath $releaseNotesSource -PathType Leaf)) {
    throw "Release notes source not found for solution version $solutionVersion`: $releaseNotesSource"
}
$releaseChanges = [IO.File]::ReadAllText($releaseNotesSource).Trim()
$releaseNotes = @"
# LogCollector $solutionVersion customer release

## Included versions

| Component | Version |
| --- | ---: |
| Azure Frontend, Worker and Shared library | $solutionVersion |
| LogCollector Core / Client | $coreVersion |
| Custom Inventory | $inventoryVersion |

## Changes

$releaseChanges

## Packaged Inventory configuration

``````text
Device table: $DeviceTableName
Application table: $AppTableName
``````

The customer-specific ``FrontendUrl``, ``CustomerName`` and ``Environment`` are supplied to
the Core generator only after Azure deployment returns ``frontendIngestUrl``.
"@
[IO.File]::WriteAllText(
    (Join-Path $target 'RELEASE-NOTES.md'), $releaseNotes, [Text.UTF8Encoding]::new($false))

$verifier = @'
#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$manifestPath = Join-Path $root 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Delivery manifest is missing: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop |
    ConvertFrom-Json -ErrorAction Stop
$expectedMutableFile = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('__MUTABLE_PARAMETER_FILE_BASE64__'))
if ([string] $manifest.SolutionVersion -ne '__SOLUTION_VERSION__' -or
    [string] $manifest.CorePackageVersion -ne '__CORE_VERSION__' -or
    [string] $manifest.InventoryPackageVersion -ne '__INVENTORY_VERSION__' -or
    [string] $manifest.SourceCommit -ne '__SOURCE_COMMIT__') {
    throw 'Delivery manifest contains unexpected component versions or source commit.'
}
$rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
$requiredFiles = @(
    'README.md'
    'RELEASE-NOTES.md'
    'Verify-Delivery.ps1'
    '1-Azure\Deploy-LogCollector.ps1'
    '1-Azure\MANIFEST.json'
    '1-Azure\Functions\Frontend.zip'
    '1-Azure\Functions\Worker.zip'
    '2-Intune\New-IntunePackage.ps1'
    '2-Intune\CoreSource\Config.psd1'
    '3-Inventory\__INVENTORY_VERSION__\Output\Install.intunewin'
    '3-Inventory\__INVENTORY_VERSION__\Detect.ps1'
    '4-Documentation\paths-core-client.md'
    '4-Documentation\paths-custom-inventory.md'
    '4-Documentation\paths-other-scripts.md'
)
$manifestNames = @($manifest.Files.PSObject.Properties | ForEach-Object { $_.Name })
$mutableFiles = @($manifest.MutableFiles | ForEach-Object { [string] $_ })
if ($mutableFiles.Count -ne 1 -or $mutableFiles[0] -ne $expectedMutableFile) {
    throw 'Delivery manifest contains an unexpected mutable-file list.'
}
if ($manifestNames.Count -ne [int] $manifest.FileCount) {
    throw "Manifest file count '$($manifestNames.Count)' does not match '$($manifest.FileCount)'."
}
foreach ($required in $requiredFiles) {
    if ($required -notin $manifestNames) { throw "Delivery manifest is missing required file: $required" }
}
$actualNames = @(
    Get-ChildItem -LiteralPath $root -File -Recurse -Force |
        Where-Object { $_.FullName -ne $manifestPath } |
        ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\') }
)
$undeclared = @(
    $actualNames | Where-Object {
        $_ -notin $manifestNames -and
        $_ -notlike '1-Azure\Logs\*' -and
        $_ -notlike '2-Intune\Output\*' -and
        $_ -notlike '2-Intune\Tools\*'
    }
)
$missing = @($manifestNames | Where-Object { $_ -notin $actualNames })
if ($undeclared.Count -gt 0 -or $missing.Count -gt 0) {
    throw ("Delivery file set differs from the manifest. Undeclared={0}; Missing={1}." -f
        ($undeclared -join ', '), ($missing -join ', '))
}
$verified = 0
foreach ($entry in $manifest.Files.PSObject.Properties) {
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $entry.Name))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest contains a path outside the delivery: $($entry.Name)"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Delivery file is missing: $($entry.Name)"
    }
    if ($entry.Name -eq $expectedMutableFile) { continue }
    if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne [string] $entry.Value) {
        throw "Delivery integrity check failed: $($entry.Name)"
    }
    $verified++
}
Write-Output ("LogCollector delivery verified; Version={0}; Core={1}; Inventory={2}; Files={3}; SourceCommit={4}." -f
    $manifest.SolutionVersion, $manifest.CorePackageVersion,
    $manifest.InventoryPackageVersion, $verified, $manifest.SourceCommit)
'@
$verifier = $verifier.
    Replace('__SOLUTION_VERSION__', $solutionVersion).
    Replace('__CORE_VERSION__', $coreVersion).
    Replace('__INVENTORY_VERSION__', $inventoryVersion).
    Replace('__SOURCE_COMMIT__', [string] $sourceCommit).
    Replace('__MUTABLE_PARAMETER_FILE_BASE64__', $mutableParameterFileBase64)
[IO.File]::WriteAllText(
    (Join-Path $target 'Verify-Delivery.ps1'), $verifier, [Text.UTF8Encoding]::new($false))

$hashes = [ordered]@{}
foreach ($file in Get-ChildItem -LiteralPath $target -File -Recurse -Force | Sort-Object FullName) {
    $relative = $file.FullName.Substring($target.Length).TrimStart('\')
    $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}
$manifest = [ordered]@{
    SolutionVersion = $solutionVersion
    CorePackageVersion = $coreVersion
    InventoryPackageVersion = $inventoryVersion
    FileCount = $hashes.Count
    BuiltAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceCommit = [string] $sourceCommit
    MutableFiles = @($mutableParameterFile)
    InventoryConfiguration = [ordered]@{
        DeviceTableName = $DeviceTableName
        AppTableName = $AppTableName
    }
    Security = [ordered]@{
        AuthenticodeSigned = $false
        RequiredVerification = 'Run Verify-Delivery.ps1 and compare the external ZIP SHA-256 through an authenticated channel.'
    }
    Note = 'Files covers the exact delivered file set except MANIFEST.json. Generated 1-Azure Logs are excluded.'
    Files = $hashes
}
[IO.File]::WriteAllText(
    (Join-Path $target 'MANIFEST.json'),
    ($manifest | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory(
    $target, $customerZip, [IO.Compression.CompressionLevel]::Optimal, $false)
[IO.Compression.ZipFile]::CreateFromDirectory(
    $azureTarget, $deploymentZip, [IO.Compression.CompressionLevel]::Optimal, $false)
$customerZipHash = (Get-FileHash -LiteralPath $customerZip -Algorithm SHA256).Hash
$deploymentZipHash = (Get-FileHash -LiteralPath $deploymentZip -Algorithm SHA256).Hash
[IO.File]::WriteAllText(
    $customerChecksum,
    "$customerZipHash *$(Split-Path $customerZip -Leaf)`r`n",
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    $deploymentChecksum,
    "$deploymentZipHash *$(Split-Path $deploymentZip -Leaf)`r`n",
    [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    SolutionVersion = $solutionVersion
    CorePackageVersion = $coreVersion
    InventoryPackageVersion = $inventoryVersion
    DeliverablePath = [IO.Path]::GetFullPath($target)
    CustomerZip = [IO.Path]::GetFullPath($customerZip)
    CustomerZipSha256 = $customerZipHash
    DeploymentZip = [IO.Path]::GetFullPath($deploymentZip)
    DeploymentZipSha256 = $deploymentZipHash
    CoreGeneratorPath = Join-Path $intune 'New-IntunePackage.ps1'
    InventoryPackagePath = $inventoryPackage.PackagePath
    InventoryPackageSha256 = $inventoryPackage.PackageSha256
    FileCount = $hashes.Count
    HashedFileCount = $hashes.Count
}
