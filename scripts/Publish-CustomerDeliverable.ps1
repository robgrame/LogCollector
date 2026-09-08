#Requires -Version 5.1
<#
.SYNOPSIS
Builds the single folder handed to the customer: the Azure deployment package and a
self-contained generator for the Intune Win32 client package.
.DESCRIPTION
Produces '<OutputRoot>\<version>' containing two ready-to-run entry points:

  1-Azure\Deploy-LogCollector.ps1   deploys infrastructure and the pre-built Function apps
  2-Intune\New-IntunePackage.ps1    builds the .intunewin client package

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
$clientSource = Join-Path $repo 'src\InventoryPackage'
$clientModules = Join-Path $repo 'src\Client'
$clientVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $clientSource 'Config.psd1')).PackageVersion

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

# The client payload must be complete before the (slow) dotnet build starts.
$packageFiles = @('Config.psd1', 'Inventory.Collection.psm1', 'Inventory.Runtime.psm1', 'Inventory.Logging.psm1',
    'Run-Inventory.ps1', 'Sync-Spool.ps1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')
foreach ($file in $packageFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $clientSource $file) -PathType Leaf)) { throw "Missing client source: $file" }
}
$detectionTemplate = [IO.File]::ReadAllText((Join-Path $clientSource 'Detect.ps1'))
if (-not $detectionTemplate.Contains('__LOGCOLLECTOR_CONFIGURATION_SHA256__')) {
    throw 'Detection template is missing its configuration hash marker.'
}
$moduleManifest = Test-ModuleManifest -Path (Join-Path $clientModules 'LogCollector.Client.psd1') -ErrorAction Stop

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
$payload = Join-Path $intune 'ClientSource'
$null = New-Item -ItemType Directory -Path (Join-Path $payload 'Modules') -Force
foreach ($file in $packageFiles) { Copy-Item -LiteralPath (Join-Path $clientSource $file) -Destination (Join-Path $payload $file) }
foreach ($file in $moduleManifest.FileList) {
    $name = Split-Path $file -Leaf
    Copy-Item -LiteralPath (Join-Path $clientModules $name) -Destination (Join-Path $payload "Modules\$name")
}

$intuneGenerator = @'
#Requires -Version 5.1
<#
.SYNOPSIS
Builds the LogCollector inventory .intunewin package for deployment as an Intune Win32 app.
.DESCRIPTION
Self-contained: uses only the ClientSource folder shipped next to this script, so neither
this repository nor the .NET SDK is required. Supply Microsoft's IntuneWinAppUtil.exe and
the intake endpoint of your LogCollector deployment.
.PARAMETER IntuneWinAppUtilPath
Path to Microsoft's IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool).
.PARAMETER FrontendUrl
Intake endpoint, e.g. https://<prefix>-logcollector-intake.azurewebsites.net/api/inventory.
Printed by Deploy-LogCollector.ps1 as 'frontendIngestUrl'.
.PARAMETER EnableSubmission
Enable upload to Azure. Omit for a pilot package that installs but keeps both
scheduled tasks disabled, so nothing is transmitted.
.PARAMETER Environment
Free-text environment tag recorded with every record (e.g. Production, Pilot).
.EXAMPLE
.\New-IntunePackage.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe `
  -FrontendUrl https://aci-logcollector-intake.azurewebsites.net/api/inventory `
  -Environment Production -EnableSubmission
.NOTES
Collects no inventory, contacts no network service and changes nothing in Azure or Intune.
Existing output folders are never overwritten.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $IntuneWinAppUtilPath,
    [Parameter(Mandatory)] [Uri] $FrontendUrl,
    [switch] $EnableSubmission,
    [string] $Environment = '',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $DeviceTableName = 'DeviceInventory_CL',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $AppTableName = 'AppInventory_CL',
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
$source = Join-Path $PSScriptRoot 'ClientSource'
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "ClientSource folder not found next to this script: $source" }
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $PSScriptRoot 'Output' }

# Only these files are ever packaged; a stray file next to them must not reach the endpoints,
# and a missing one must fail here rather than during installation on a device.
$payloadFiles = @('Config.psd1', 'Inventory.Collection.psm1', 'Inventory.Runtime.psm1', 'Inventory.Logging.psm1',
    'Run-Inventory.ps1', 'Sync-Spool.ps1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'README.md')
$moduleFiles = @('LogCollector.Client.psd1', 'LogCollector.Client.psm1', 'DeviceIdentity.psm1',
    'RequestSigning.psm1', 'InventoryClient.psm1', 'InventorySpool.psm1')
foreach ($file in $payloadFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $file) -PathType Leaf)) { throw "Missing package source: $file" }
}
foreach ($file in $moduleFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $source "Modules\$file") -PathType Leaf)) { throw "Missing package source: Modules\$file" }
}

$tool = Get-Item -LiteralPath $IntuneWinAppUtilPath -ErrorAction Stop
if ($tool.PSIsContainer -or $tool.Extension -ne '.exe') { throw 'Supply the official IntuneWinAppUtil.exe file.' }

$config = Import-PowerShellDataFile -LiteralPath (Join-Path $source 'Config.psd1')
$version = $config.PackageVersion
$config.FrontendUrl = $FrontendUrl.AbsoluteUri
$config.Environment = $Environment
$config.DeviceTableName = $DeviceTableName
$config.AppTableName = $AppTableName
$config.SubmissionEnabled = [bool]$EnableSubmission
$config.PkiRootCaThumbprints = $PkiRootCaThumbprints
$config.PkiRootCaSubjects = $PkiRootCaSubjects
$config.PkiIntermediateCaThumbprints = $PkiIntermediateCaThumbprints
$config.PkiIntermediateCaSubjects = $PkiIntermediateCaSubjects
foreach ($key in @('PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
    foreach ($entry in $config[$key]) {
        if ([string]::IsNullOrWhiteSpace($entry)) { throw "$key contains an empty entry." }
        if ($key -like '*Thumbprints' -and ($entry -replace '[\s:]', '') -notmatch '^[0-9a-fA-F]{40}$') {
            throw "$key entries must be SHA1 certificate thumbprints (40 hexadecimal digits)."
        }
    }
}

$release = [IO.Path]::GetFullPath((Join-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)) $version))
if ($release.Contains('"')) { throw 'Output paths must not contain double quotes.' }
if (Test-Path -LiteralPath $release) { throw "Output already exists: $release. Choose a new OutputRoot; releases are never overwritten." }
if (-not $PSCmdlet.ShouldProcess($release, 'Build the inventory .intunewin package')) { return }

$staging = Join-Path $release 'Source'
$null = New-Item -ItemType Directory -Path (Join-Path $staging 'Modules') -Force
foreach ($file in $payloadFiles) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $staging $file) -ErrorAction Stop }
foreach ($file in $moduleFiles) { Copy-Item -LiteralPath (Join-Path $source "Modules\$file") -Destination (Join-Path $staging "Modules\$file") -ErrorAction Stop }

# Rewrite Config.psd1 deterministically so its hash matches what Detect.ps1 will look for.
$lines = @('@{')
foreach ($key in @($config.Keys | Sort-Object)) {
    $value = $config[$key]
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
$configPath = Join-Path $staging 'Config.psd1'
[IO.File]::WriteAllText($configPath, ($lines -join "`r`n"), [Text.UTF8Encoding]::new($false))
$configurationSha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash

# Validate through the runtime that will run on the endpoints, so an endpoint the client
# would refuse at install time is rejected here instead.
$runtime = Import-Module (Join-Path $staging 'Inventory.Runtime.psm1') -PassThru -ErrorAction Stop
try { $null = & $runtime { param($Path) Get-InventoryConfiguration -Path $Path } $configPath }
finally { Remove-Module -ModuleInfo $runtime -Force -ErrorAction SilentlyContinue }

$detection = [IO.File]::ReadAllText((Join-Path $source 'Detect.ps1'))
if (-not $detection.Contains('__LOGCOLLECTOR_CONFIGURATION_SHA256__')) { throw 'Detection template is missing its configuration hash marker.' }
$detection = $detection.Replace('__LOGCOLLECTOR_CONFIGURATION_SHA256__', $configurationSha256)
[IO.File]::WriteAllText((Join-Path $staging 'Detect.ps1'), $detection, [Text.UTF8Encoding]::new($false))
$null = Test-ModuleManifest -Path (Join-Path $staging 'Modules\LogCollector.Client.psd1') -ErrorAction Stop

$output = Join-Path $release 'Package'
$null = New-Item -ItemType Directory -Path $output -Force
$arguments = @('-c', ('"{0}"' -f $staging), '-s', 'Install.ps1', '-o', ('"{0}"' -f $output), '-qq')
$process = Start-Process -FilePath $tool.FullName -ArgumentList $arguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
if ($process.ExitCode -ne 0) { throw "IntuneWinAppUtil failed with exit code $($process.ExitCode). Output retained at $release." }
$artifact = Join-Path $output 'Install.intunewin'
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or (Get-Item -LiteralPath $artifact).Length -eq 0) {
    throw "IntuneWinAppUtil produced no nonempty Install.intunewin. Output retained at $release."
}
Copy-Item -LiteralPath (Join-Path $staging 'Detect.ps1') -Destination (Join-Path $release 'Detect.ps1')

[pscustomobject]@{
    PackageVersion = $version
    IntuneWinPackage = $artifact
    PackageSha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
    DetectionScript = Join-Path $release 'Detect.ps1'
    InstallCommand = '"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Install.ps1"'
    UninstallCommand = ('"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ProgramW6432%\LogCollector\CustomInventory\{0}\Uninstall.ps1"' -f $version)
    SubmissionEnabled = $config.SubmissionEnabled
    ConfigurationSha256 = $configurationSha256
}
'@
[IO.File]::WriteAllText((Join-Path $intune 'New-IntunePackage.ps1'), $intuneGenerator, [Text.UTF8Encoding]::new($false))

$intuneGuide = @"
# Deploying the LogCollector client with Intune

Client package version **$clientVersion**. Everything below uses only the files in this
folder; the LogCollector source tree is not required.

## 1. Prerequisites

* **IntuneWinAppUtil.exe** - Microsoft Win32 Content Prep Tool.
  Download: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
* Windows PowerShell 5.1 or PowerShell 7 to run the generator.
* The intake endpoint of your deployment, printed by ``1-Azure\Deploy-LogCollector.ps1`` as
  **``frontendIngestUrl``**.
* Intune permissions to create and assign a Win32 app.

## 2. Build the package

Start with a **pilot** package. Omitting ``-EnableSubmission`` installs the client with both
scheduled tasks **created but disabled**: no collection and no transmission happen on their
own, so install and detection can be validated first, and collection can be exercised
on demand with the manual command in section 4.

``````powershell
.\New-IntunePackage.ps1 ``
  -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe ``
  -FrontendUrl  https://<prefix>-logcollector-intake.azurewebsites.net/api/inventory ``
  -Environment  Pilot
``````

Once the pilot is validated, build the production package by adding ``-EnableSubmission``.
Because output folders are never overwritten, send it to a different location:

``````powershell
.\New-IntunePackage.ps1 ``
  -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe ``
  -FrontendUrl  https://<prefix>-logcollector-intake.azurewebsites.net/api/inventory ``
  -Environment  Production -EnableSubmission ``
  -OutputRoot   .\Output-Production
``````

The command prints ``PackageSha256``, ``ConfigurationSha256`` and the effective
``SubmissionEnabled``. It produces:

| Path | Contents |
| --- | --- |
| ``Output\$clientVersion\Package\Install.intunewin`` | The package to upload to Intune |
| ``Output\$clientVersion\Detect.ps1`` | The detection script to upload |
| ``Output\$clientVersion\Source`` | The 16 payload files, for inspection |

``Source`` and ``Package`` are kept apart so the tool never wraps its own output.

### Optional parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| ``-Environment`` | *(empty)* | Free-text tag stored with every record |
| ``-DeviceTableName`` | ``DeviceInventory_CL`` | Target Log Analytics table for device records |
| ``-AppTableName`` | ``AppInventory_CL`` | Target Log Analytics table for application records |
| ``-PkiRootCaThumbprints`` | ``@()`` | Restrict client certificates to specific root CAs |
| ``-PkiIntermediateCaThumbprints`` | ``@()`` | Restrict to specific intermediate CAs |

By default the client selects its **Intune device certificate** automatically. The PKI
parameters are only needed when the endpoints must present a certificate from your own PKI.

## 3. Create the Win32 app in Intune

**Apps > Windows > Add > Windows app (Win32)**, then upload
``Output\$clientVersion\Package\Install.intunewin``.

**Program** page - each command is a single line:

Install command:

``````text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Install.ps1"
``````

Uninstall command (uses the installed copy, not the Intune cache):

``````text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ProgramW6432%\LogCollector\CustomInventory\$clientVersion\Uninstall.ps1"
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
``Output\$clientVersion\Detect.ps1``. Leave *Run script as 32-bit process* **unchecked** and
*Enforce script signature check* unchecked. The script is bound to the SHA256 of the exact
``Config.psd1`` inside this package, so a device configured by a different package build is
correctly reported as not installed.

**Assignments**: assign to a device group. Start with a small pilot ring.

## 4. Validate the pilot

On a targeted device, after the app installs:

``````powershell
Get-ScheduledTask -TaskPath '\LogCollector\' | Format-Table TaskName, State
Get-Content 'C:\ProgramData\LogCollector\Logs\CustomInventory\Install.log' -Tail 20
``````

With a pilot package both tasks are present but **Disabled** - that is expected, and it also
means nothing is collected until you ask for it. To exercise collection without transmitting
anything, run an elevated **64-bit** Windows PowerShell and use preview mode:

``````powershell
& "`$env:ProgramFiles\LogCollector\CustomInventory\$clientVersion\Run-Inventory.ps1" -Preview
``````

``-Preview`` collects and prints what would be sent without contacting Azure and without
writing to the spool. ``-QueueOnly`` also collects but stores the result in the local spool,
where it is retained and would be delivered once submission is enabled.

With a production package the tasks are enabled; to force an immediate run:

``````powershell
Start-ScheduledTask -TaskName 'LogCollector-CustomInventory' -TaskPath '\LogCollector\'
Start-Sleep -Seconds 60
Get-ScheduledTaskInfo -TaskName 'LogCollector-CustomInventory' -TaskPath '\LogCollector\' |
    Select-Object LastRunTime, LastTaskResult
Get-Content 'C:\ProgramData\LogCollector\Logs\CustomInventory\Inventory.log' -Tail 20
``````

``LastTaskResult = 0`` means success. In the log, ``CertificateSelected`` shows which Intune
certificate was used and ``HttpResult`` with ``StatusCode 202`` confirms the submission was
accepted.

Then confirm ingestion in Log Analytics:

``````kusto
DeviceInventory_CL | where TimeGenerated > ago(1h) | summarize by DeviceName
AppInventory_CL    | where TimeGenerated > ago(1h) | summarize count() by DeviceName
``````

Records typically appear within a few minutes of the first successful submission.

## 5. Troubleshooting

| Symptom | Cause and remedy |
| --- | --- |
| ``LastTaskResult`` is ``267011`` | The task has simply never run yet. Start it manually. |
| Tasks present but Disabled | The package was built without ``-EnableSubmission``. |
| ``HttpResult`` with ``StatusCode 401`` | The client certificate itself was refused (chain, issuer or request signature). Confirm the device has a valid Intune certificate in ``Cert:\LocalMachine\My``. |
| ``HttpResult`` with ``StatusCode 403`` | The certificate is trusted but the device is not authorised: either the device id bound to the certificate does not match the ``EntraDeviceId`` submitted, or that device is absent or disabled in the tenant of the deployment. Compare ``CertificateSelected`` and the submitted device id in ``Inventory.log``, then check the device object in Entra ID. |
| ``WebExceptionStatus: Timeout`` | Transient network issue. The client retries and spools; check whether the following attempt was ``Delivered``. |
| App reported *Not installed* after a successful install | The detection script does not match this build. Ensure the ``Detect.ps1`` uploaded is the one produced next to the ``.intunewin`` being deployed. |
| Install fails immediately | Verify the install command uses ``Sysnative``; the installer refuses 32-bit PowerShell. |

Diagnostics are written as one JSON object per line under
``C:\ProgramData\LogCollector\Logs\CustomInventory\`` (``Install.log``, ``Inventory.log``,
``Spool.log``). Records that cannot be delivered are spooled and retried by the
``LogCollector-CustomInventory-Spool`` task; they are kept up to 7 days. Logs and spool
survive uninstall. All paths are restricted to SYSTEM and administrators.

## 6. Upgrading

The two scheduled tasks (``LogCollector-CustomInventory`` and
``LogCollector-CustomInventory-Spool``) have **fixed names** and are re-registered with
``-Force`` by every version, while each version's detection script requires those tasks to
point at *its own* versioned folder. Only one version can therefore be "installed" at a
time, as far as Intune is concerned.

**Recommended:** keep a single Win32 app and update it in place - upload the new
``.intunewin``, replace the detection script with the new ``Detect.ps1``, and update the
uninstall command to the new version path (it is version-specific). The same applies when
moving from the pilot package to the production one: it is a content and detection update
of the same app, not a second app.

If you must use two apps, they **must not be assigned to the same devices at the same
time**: with overlapping assignments each install makes the other app report *Not
installed*, and Intune will reinstall them in a loop. Remove the old assignment first, and
never run the old uninstall after the new version has registered its tasks - it would
delete the tasks the new version depends on. If that happens, reinstall the new version to
restore them.

Installing a new version does not delete earlier version folders; remove them with their
own ``Uninstall.ps1`` only while no other version is installed.
"@
[IO.File]::WriteAllText((Join-Path $intune 'Intune-Deployment.md'), $intuneGuide, [Text.UTF8Encoding]::new($false))

# --- Instructions and manifest --------------------------------------------------------
# Placeholder so the README is on disk (and therefore hashed) before the manifest is built;
# MANIFEST.json is the only file it cannot cover, since it cannot hash itself.
$readmePath = Join-Path $target 'README.md'

$readme = @"
# LogCollector $solutionVersion - delivery package

Client inventory package version: **$clientVersion**.

Everything needed to deploy LogCollector and roll the client out through Intune. The source
tree, the .NET SDK and Bicep CLI are **not** required.

| Folder | Purpose |
| --- | --- |
| ``1-Azure`` | Deploys infrastructure and the pre-built Function apps |
| ``2-Intune`` | Builds the ``.intunewin`` client package |

## Prerequisites

* **Azure CLI** (``az``), signed in with ``az login``. Rights to create resources in the
  target resource group, plus User Access Administrator (the template creates role assignments).
* **IntuneWinAppUtil.exe** - Microsoft Win32 Content Prep Tool, for step 2 only.
  Download: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
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

## Step 2 - build the Intune package

``````powershell
cd 2-Intune
.\New-IntunePackage.ps1 ``
  -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe ``
  -FrontendUrl  <frontendIngestUrl from step 1> ``
  -Environment  Production ``
  -EnableSubmission
``````

Omit ``-EnableSubmission`` to build a **pilot** package: it installs with both scheduled
tasks created but disabled, so nothing runs and nothing is transmitted until you start a
run by hand. Use it to validate install and detection before enabling ingestion.

The script prints the paths to use in Intune:

| Intune field | Value |
| --- | --- |
| App package file | ``Output\$clientVersion\Package\Install.intunewin`` |
| Detection rule | Custom script -> ``Output\$clientVersion\Detect.ps1`` (do NOT tick "run as 32-bit") |
| Install behaviour | System |

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
    ClientPackageVersion = $clientVersion
    BuiltAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceCommit = [string]$commit
    Note = 'Files covers every delivered file except MANIFEST.json, which cannot hash itself.'
    Files = $hashes
}
[IO.File]::WriteAllText((Join-Path $target 'MANIFEST.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    SolutionVersion = $solutionVersion
    ClientPackageVersion = $clientVersion
    DeliverablePath = [IO.Path]::GetFullPath($target)
    AzureEntryPoint = Join-Path $target '1-Azure\Deploy-LogCollector.ps1'
    IntuneEntryPoint = Join-Path $target '2-Intune\New-IntunePackage.ps1'
    FileCount = @(Get-ChildItem -LiteralPath $target -File -Recurse).Count
    HashedFileCount = $hashes.Count
}
