#Requires -Version 5.1
<#
.SYNOPSIS
Builds a self-contained, customer-ready package to deploy LogCollector infrastructure and
pre-compiled Function apps to Azure, without requiring the .NET SDK or the source tree.
.DESCRIPTION
Publishes Frontend and Worker in Release configuration with debug symbols (*.pdb) excluded,
bundles the Bicep infrastructure template, the supplied parameter file and the Intune trust
certificates, and generates a standalone Deploy-LogCollector.ps1 orchestrator that only
requires the Azure CLI. The package is versioned from the Shared/Frontend/Worker project
version (all three must match) and existing output is never overwritten.
.PARAMETER OutputRoot
Folder under which a versioned package folder is created. Defaults to '<repo>\out\Deploy'.
.PARAMETER ParameterFile
Bicep parameter file to bundle as the deployment default. Defaults to
'infra\logcollector.bicepparam'. Must not contain secrets or a subscription/tenant id;
the subscription is always supplied at deploy time via -SubscriptionId.
.NOTES
Version 1.0.0. Builds via dotnet publish; makes no changes to Azure resources.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()] [string] $OutputRoot,
    [ValidateNotNullOrEmpty()] [string] $ParameterFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('OutputRoot')) { $OutputRoot = Join-Path $repo 'out\Deploy' }
if (-not $PSBoundParameters.ContainsKey('ParameterFile')) { $ParameterFile = Join-Path $repo 'infra\logcollector.bicepparam' }
if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) { throw "Parameter file not found: $ParameterFile" }

# The three project versions must agree; the package is named/versioned after them.
function Get-ProjectVersion {
    param([string] $CsprojPath)
    if (-not (Test-Path -LiteralPath $CsprojPath -PathType Leaf)) { throw "Project file not found: $CsprojPath" }
    $xml = [xml](Get-Content -LiteralPath $CsprojPath -Raw)
    $node = $xml.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
    if (-not $node) { throw "No <Version> element found in $CsprojPath" }
    return [string]$node
}
$frontendVersion = Get-ProjectVersion (Join-Path $repo 'src\Functions\Frontend\LogCollector.Frontend.csproj')
$workerVersion = Get-ProjectVersion (Join-Path $repo 'src\Functions\Worker\LogCollector.Worker.csproj')
$sharedVersion = Get-ProjectVersion (Join-Path $repo 'src\Shared\LogCollector.Shared.csproj')
if ($frontendVersion -ne $workerVersion -or $frontendVersion -ne $sharedVersion) {
    throw "Frontend ($frontendVersion), Worker ($workerVersion) and Shared ($sharedVersion) versions must match before packaging."
}
$version = $frontendVersion

$target = Join-Path $OutputRoot $version
if (Test-Path -LiteralPath $target) { throw "Output already exists: $target. Use a new OutputRoot; existing packages are never overwritten." }

$infraSource = Join-Path $repo 'infra'
foreach ($required in @('main.bicep', 'certificates\intune-root.base64', 'certificates\intune-intermediate.base64')) {
    if (-not (Test-Path -LiteralPath (Join-Path $infraSource $required) -PathType Leaf)) { throw "Missing infra source: $required" }
}

if (-not $PSCmdlet.ShouldProcess($target, 'Create client deployment package (build, strip pdb, bundle infra, generate deploy script)')) { return }

$publishScript = Join-Path $PSScriptRoot 'Publish-Function.ps1'
# Publish-Function.ps1 streams dotnet's build output through the pipeline as well; only the
# last emitted line is the zip path (Write-Output $zipPath).
$frontendZip = (& $publishScript -Component Frontend -ExcludePdb) | Select-Object -Last 1
$workerZip = (& $publishScript -Component Worker -ExcludePdb) | Select-Object -Last 1

# Defensive re-check: the customer package must never contain debug symbols.
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($zip in @($frontendZip, $workerZip)) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $pdbEntries = @($archive.Entries | Where-Object { $_.FullName -like '*.pdb' })
        if ($pdbEntries.Count -gt 0) { throw "$zip still contains $($pdbEntries.Count) .pdb entr(y/ies)." }
    }
    finally { $archive.Dispose() }
}

$null = New-Item -ItemType Directory -Path (Join-Path $target 'Functions') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $target 'infra\certificates') -Force
Copy-Item -LiteralPath $frontendZip -Destination (Join-Path $target 'Functions\Frontend.zip')
Copy-Item -LiteralPath $workerZip -Destination (Join-Path $target 'Functions\Worker.zip')
Copy-Item -LiteralPath (Join-Path $infraSource 'main.bicep') -Destination (Join-Path $target 'infra\main.bicep')
Copy-Item -LiteralPath (Join-Path $infraSource 'certificates\intune-root.base64') -Destination (Join-Path $target 'infra\certificates\intune-root.base64')
Copy-Item -LiteralPath (Join-Path $infraSource 'certificates\intune-intermediate.base64') -Destination (Join-Path $target 'infra\certificates\intune-intermediate.base64')
$parameterFileName = Split-Path $ParameterFile -Leaf
Copy-Item -LiteralPath $ParameterFile -Destination (Join-Path $target "infra\$parameterFileName")

# Clean up the transient build folders created by Publish-Function.ps1.
Remove-Item -LiteralPath (Split-Path $frontendZip -Parent) -Recurse -Force
Remove-Item -LiteralPath (Split-Path $workerZip -Parent) -Recurse -Force

$deployScript = @'
#Requires -Version 5.1
<#
.SYNOPSIS
Deploys the LogCollector infrastructure and the bundled Frontend/Worker packages to Azure.
.DESCRIPTION
Self-contained: requires only the Azure CLI (az) logged in with rights on the target
subscription/resource group. Does not require the .NET SDK or the LogCollector source tree.
.PARAMETER SubscriptionId
Target Azure subscription id. Never stored in this package; supply it at deploy time.
.PARAMETER ResourceGroup
Resource group to deploy into. Created if it does not already exist.
.PARAMETER Location
Azure region for a newly created resource group. Ignored if the resource group exists.
.PARAMETER ParameterFile
Bicep parameter file. Defaults to the single .bicepparam file bundled under .\infra.
.PARAMETER SkipInfra
Skip the infrastructure (Bicep) deployment and only push the Function app packages.
Requires the Function apps to already exist (e.g. from a previous run).
.PARAMETER SkipApps
Skip pushing the Function app packages and only deploy infrastructure.
.NOTES
Version 1.0.0.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'italynorth',
    [string] $ParameterFile,
    [switch] $SkipInfra,
    [switch] $SkipApps
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
if (-not $PSBoundParameters.ContainsKey('ParameterFile')) {
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $root 'infra') -Filter '*.bicepparam' -File)
    if ($candidates.Count -ne 1) { throw 'Could not uniquely determine the parameter file under .\infra; pass -ParameterFile explicitly.' }
    $ParameterFile = $candidates[0].FullName
}
if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) { throw "Parameter file not found: $ParameterFile" }

& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Could not select subscription $SubscriptionId (exit code $LASTEXITCODE)." }

$groupExists = (& az group exists --name $ResourceGroup) -eq 'true'
if (-not $groupExists) {
    if ($PSCmdlet.ShouldProcess($ResourceGroup, "Create resource group in $Location")) {
        & az group create --name $ResourceGroup --location $Location --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group $ResourceGroup (exit code $LASTEXITCODE)." }
    }
}

$frontendAppName = $null
$workerAppName = $null
if (-not $SkipInfra) {
    if ($PSCmdlet.ShouldProcess($ResourceGroup, 'Deploy infrastructure (Bicep)')) {
        $deploymentName = 'LogCollector-' + (Get-Date -Format 'yyyyMMddHHmmss')
        $outputsJson = & az deployment group create `
            --resource-group $ResourceGroup `
            --name $deploymentName `
            --template-file (Join-Path $root 'infra\main.bicep') `
            --parameters $ParameterFile `
            --parameters location=$Location `
            --query properties.outputs `
            --only-show-errors -o json
        if ($LASTEXITCODE -ne 0) { throw "Infrastructure deployment failed (exit code $LASTEXITCODE)." }
        $outputs = $outputsJson | ConvertFrom-Json
        $frontendAppName = $outputs.frontendAppName.value
        $workerAppName = $outputs.workerAppName.value
        Write-Output "Frontend ingest URL: $($outputs.frontendIngestUrl.value)"
        Write-Output "Log Analytics workspace: $($outputs.logAnalyticsWorkspaceName.value)"
    }
}

if (-not $SkipApps) {
    if (-not $frontendAppName -or -not $workerAppName) {
        # Infra was skipped: derive the app names from the deployed resources instead of assuming a naming convention.
        $frontendAppName = & az functionapp list --resource-group $ResourceGroup --query "[?ends_with(name, '-intake')].name | [0]" -o tsv --only-show-errors
        $workerAppName = & az functionapp list --resource-group $ResourceGroup --query "[?ends_with(name, '-worker')].name | [0]" -o tsv --only-show-errors
        if (-not $frontendAppName -or -not $workerAppName) { throw 'Could not determine Function app names; deploy infrastructure first or pass -SkipInfra with an existing deployment.' }
    }
    if ($PSCmdlet.ShouldProcess($frontendAppName, 'Deploy Frontend package')) {
        & az functionapp deployment source config-zip --resource-group $ResourceGroup --name $frontendAppName --src (Join-Path $root 'Functions\Frontend.zip') --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Frontend deployment failed (exit code $LASTEXITCODE)." }
    }
    if ($PSCmdlet.ShouldProcess($workerAppName, 'Deploy Worker package')) {
        & az functionapp deployment source config-zip --resource-group $ResourceGroup --name $workerAppName --src (Join-Path $root 'Functions\Worker.zip') --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Worker deployment failed (exit code $LASTEXITCODE)." }
    }
}
Write-Output 'Deployment complete.'
'@
[IO.File]::WriteAllText((Join-Path $target 'Deploy-LogCollector.ps1'), $deployScript, [Text.UTF8Encoding]::new($false))

$frontendHash = (Get-FileHash -LiteralPath (Join-Path $target 'Functions\Frontend.zip') -Algorithm SHA256).Hash
$workerHash = (Get-FileHash -LiteralPath (Join-Path $target 'Functions\Worker.zip') -Algorithm SHA256).Hash
$commit = try { (& git -C $repo rev-parse HEAD) } catch { 'unknown' }
$manifest = [ordered]@{
    Version = $version
    BuiltAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceCommit = $commit
    ParameterFile = $parameterFileName
    Files = [ordered]@{
        'Functions\Frontend.zip' = $frontendHash
        'Functions\Worker.zip' = $workerHash
    }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $target 'MANIFEST.json') -Encoding utf8

$readme = @"
# LogCollector deployment package — v$version

Self-contained package to deploy LogCollector to Azure. Requires only the Azure CLI
(``az``, logged in with rights on the target subscription) — no .NET SDK, no source tree.

## Contents
- ``infra\main.bicep`` — infrastructure template.
- ``infra\$parameterFileName`` — deployment parameters (no secrets, no subscription id).
- ``infra\certificates\`` — Intune MDM trust certificates (base64 DER).
- ``Functions\Frontend.zip``, ``Functions\Worker.zip`` — pre-built Release packages, no .pdb files (see MANIFEST.json for SHA256).
- ``Deploy-LogCollector.ps1`` — deployment orchestrator.

## Usage
``````powershell
.\Deploy-LogCollector.ps1 -SubscriptionId <sub-id> -ResourceGroup <rg-name> -Location italynorth
``````

Use ``-SkipInfra`` to redeploy only the Function app code against an existing resource group,
or ``-SkipApps`` to only (re)apply the infrastructure template. Run with ``-WhatIf`` first to
preview the changes.
"@
Set-Content -LiteralPath (Join-Path $target 'README.md') -Value $readme -Encoding utf8

[pscustomobject]@{
    Version = $version
    PackagePath = [IO.Path]::GetFullPath($target)
    FrontendSha256 = $frontendHash
    WorkerSha256 = $workerHash
    FileCount = @(Get-ChildItem -LiteralPath $target -File -Recurse).Count
}
