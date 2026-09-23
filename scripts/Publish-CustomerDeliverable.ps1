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
Version 1.1.2. Builds via dotnet publish; makes no changes to Azure resources and never
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
foreach ($file in $moduleManifestData.FileList) {
    $destination = Join-Path $corePayload "Modules\$file"
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $clientModules $file) -Destination $destination -ErrorAction Stop
}

$generatorSource = Join-Path $PSScriptRoot 'New-IntunePackage.ps1'
if (-not (Test-Path -LiteralPath $generatorSource -PathType Leaf)) {
    throw "Missing Intune package generator source: $generatorSource"
}
Copy-Item -LiteralPath $generatorSource -Destination (Join-Path $intune 'New-IntunePackage.ps1') -ErrorAction Stop

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

Uninstall command (pinned to the version actually installed, not whatever this Intune app's
current package content contains after a later update; ``Uninstall.ps1`` is copied there by
``Install.ps1`` for exactly this reason):

``````text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\$coreVersion\Uninstall.ps1"
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
