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
Version 1.2.0. Builds via dotnet publish; makes no changes to Azure resources.
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
foreach ($required in @('main.bicep', 'modules\log-analytics-tables.bicep', 'certificates\intune-root.base64', 'certificates\intune-intermediate.base64')) {
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
$null = New-Item -ItemType Directory -Path (Join-Path $target 'infra\modules') -Force
Copy-Item -LiteralPath $frontendZip -Destination (Join-Path $target 'Functions\Frontend.zip')
Copy-Item -LiteralPath $workerZip -Destination (Join-Path $target 'Functions\Worker.zip')
Copy-Item -LiteralPath (Join-Path $infraSource 'main.bicep') -Destination (Join-Path $target 'infra\main.bicep')
Copy-Item -LiteralPath (Join-Path $infraSource 'modules\log-analytics-tables.bicep') -Destination (Join-Path $target 'infra\modules\log-analytics-tables.bicep')
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
Requires the Function apps to already exist (e.g. from a previous run). With -SkipInfra,
pass -FrontendAppName/-WorkerAppName if the resource group could contain more than one
LogCollector-like deployment; otherwise app names are auto-discovered and the script
refuses to proceed if the discovery is ambiguous.
.PARAMETER SkipApps
Skip pushing the Function app packages and only deploy infrastructure.
.PARAMETER FrontendAppName
Explicit Frontend Function app name. Required with -SkipInfra when discovery is ambiguous.
.PARAMETER WorkerAppName
Explicit Worker Function app name. Required with -SkipInfra when discovery is ambiguous.
.PARAMETER CustomerPrefix
Short customer/company code (e.g. 'ACI') prepended to every resource name. 1-8 alphanumeric
characters, optionally separated by hyphens, starting and ending with an alphanumeric.
Required when this subscription already hosts another LogCollector deployment, because the
storage account, Service Bus namespace and Function app names are globally unique. Overrides
the value in the parameter file. The template lowercases it, so 'ACI' yields 'aci-...'.
Set it on the first deployment: changing it later renames rather than migrates the resources.
.PARAMETER ExistingLogAnalyticsWorkspaceResourceId
Resource ID of an existing Log Analytics workspace to reuse instead of creating a new one,
e.g. '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>'.
The workspace may live in a different resource group or subscription (same tenant); the
identity running this deployment needs Contributor (or equivalent) on that resource group too,
since custom tables are created/updated there. Leave empty to create a new workspace.
.PARAMETER LogPath
Optional path for the detailed deployment log. Defaults to a timestamped file under
.\Logs next to this script. Console and file logging contain operational metadata only;
subscription IDs are masked and Azure credentials or access tokens are never logged.
.NOTES
Version 1.3.0. Never mutates the caller's persisted `az` default subscription; every
command is scoped with --subscription instead of `az account set`. Writes detailed,
timestamped progress diagnostics to the console and a local log file.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'italynorth',
    [string] $ParameterFile,
    [switch] $SkipInfra,
    [switch] $SkipApps,
    [string] $FrontendAppName,
    [string] $WorkerAppName,
    [ValidatePattern('^$|^[A-Za-z0-9]([A-Za-z0-9-]{0,6}[A-Za-z0-9])?$')]
    [string] $CustomerPrefix = '',
    [string] $ExistingLogAnalyticsWorkspaceResourceId = '',
    [string] $LogPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$deploymentTimer = [Diagnostics.Stopwatch]::StartNew()
$deploymentPhase = 'Initialize'
$logFileEnabled = $true
$logWriteFailureReported = $false
if (-not $PSBoundParameters.ContainsKey('LogPath')) {
    $LogPath = Join-Path (Join-Path $root 'Logs') (
        'Deploy-LogCollector-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
try {
    $LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
    $logDirectory = Split-Path $LogPath -Parent
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop
    }
}
catch {
    $logFileEnabled = $false
    Write-Warning "Detailed log file is unavailable; console logging will continue. Path=$LogPath; Error=$($_.Exception.Message)"
}

function Protect-DeploymentLogValue {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }
    if ($Value.Length -le 12) { return '<masked>' }
    return '{0}...{1}' -f $Value.Substring(0, 8), $Value.Substring($Value.Length - 4)
}

function Write-DeploymentLog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Info', 'Warning', 'Error')] [string] $Level = 'Info'
    )
    $line = '{0} [{1}] [Phase={2}] [ElapsedMs={3}] {4}' -f (
        [DateTime]::UtcNow.ToString('o'),
        $Level.ToUpperInvariant(),
        $deploymentPhase,
        $deploymentTimer.ElapsedMilliseconds,
        $Message)
    if ($logFileEnabled) {
        try {
            Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            $script:logFileEnabled = $false
            if (-not $script:logWriteFailureReported) {
                $script:logWriteFailureReported = $true
                Write-Warning "Detailed log file became unavailable; console logging will continue. Path=$LogPath; Error=$($_.Exception.Message)"
            }
        }
    }
    switch ($Level) {
        'Warning' { Write-Warning $line }
        'Error' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

trap {
    $failure = $_
    Write-DeploymentLog -Level Error -Message (
        "Deployment failed; ErrorType=$($failure.Exception.GetType().FullName); " +
        "Error=$($failure.Exception.Message); Position=$($failure.InvocationInfo.PositionMessage); " +
        "Stack=$($failure.ScriptStackTrace)")
    throw $failure
}

Write-DeploymentLog -Message (
    "Deployment started; ScriptVersion=1.3.0; PowerShell=$($PSVersionTable.PSVersion); " +
    "ProcessId=$PID; LogPath=$LogPath.")
Write-DeploymentLog -Message (
    "Requested scope; Subscription=$(Protect-DeploymentLogValue $SubscriptionId); " +
    "ResourceGroup=$ResourceGroup; Location=$Location; SkipInfra=$([bool]$SkipInfra); " +
    "SkipApps=$([bool]$SkipApps); CustomerPrefixConfigured=$([bool]$CustomerPrefix); " +
    "ExistingWorkspaceConfigured=$([bool]$ExistingLogAnalyticsWorkspaceResourceId).")

$deploymentPhase = 'ValidatePrerequisites'
$azCommand = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
$azVersion = (& $azCommand.Source version --query '"azure-cli"' -o tsv --only-show-errors)
if ($LASTEXITCODE -ne 0) { throw "Azure CLI version check failed (exit code $LASTEXITCODE)." }
Write-DeploymentLog -Message "Azure CLI validated; Path=$($azCommand.Source); Version=$azVersion."

if (-not $PSBoundParameters.ContainsKey('ParameterFile')) {
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $root 'infra') -Filter '*.bicepparam' -File)
    if ($candidates.Count -ne 1) { throw 'Could not uniquely determine the parameter file under .\infra; pass -ParameterFile explicitly.' }
    $ParameterFile = $candidates[0].FullName
    Write-DeploymentLog -Message "Parameter file auto-discovered; CandidateCount=$($candidates.Count); Path=$ParameterFile."
}
if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) { throw "Parameter file not found: $ParameterFile" }
$ParameterFile = (Resolve-Path -LiteralPath $ParameterFile -ErrorAction Stop).ProviderPath
Write-DeploymentLog -Message (
    "Input validation completed; ParameterFile=$ParameterFile; " +
    "ParameterFileSha256=$((Get-FileHash -LiteralPath $ParameterFile -Algorithm SHA256).Hash).")

$subscriptionArgs = @('--subscription', $SubscriptionId)
# Only override the parameter file's customerPrefix when one was supplied, so an existing
# installation redeployed without -CustomerPrefix keeps its current resource names.
$prefixArgs = @()
if ($CustomerPrefix) { $prefixArgs = @('--parameters', "customerPrefix=$CustomerPrefix") }
# Only override the parameter file's workspace setting when one was supplied, so a
# redeploy without this switch keeps whatever workspace choice was already in effect.
$workspaceArgs = @()
if ($ExistingLogAnalyticsWorkspaceResourceId) { $workspaceArgs = @('--parameters', "existingLogAnalyticsWorkspaceResourceId=$ExistingLogAnalyticsWorkspaceResourceId") }

$deploymentPhase = 'ResolveResourceGroup'
Write-DeploymentLog -Message "Checking resource group; Name=$ResourceGroup; Subscription=$(Protect-DeploymentLogValue $SubscriptionId)."
$groupExists = (& $azCommand.Source group exists --name $ResourceGroup @subscriptionArgs) -eq 'true'
if ($LASTEXITCODE -ne 0) { throw "Resource group lookup failed (exit code $LASTEXITCODE)." }
Write-DeploymentLog -Message "Resource group lookup completed; Name=$ResourceGroup; Exists=$groupExists."
if (-not $groupExists) {
    if ($PSCmdlet.ShouldProcess($ResourceGroup, "Create resource group in $Location")) {
        Write-DeploymentLog -Message "Creating resource group; Name=$ResourceGroup; Location=$Location."
        & $azCommand.Source group create --name $ResourceGroup --location $Location --only-show-errors @subscriptionArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group $ResourceGroup (exit code $LASTEXITCODE)." }
        Write-DeploymentLog -Message "Resource group created; Name=$ResourceGroup; Location=$Location."
    }
}
else {
    Write-DeploymentLog -Message "Using existing resource group; Name=$ResourceGroup."
}

$frontendAppNameResolved = $FrontendAppName
$workerAppNameResolved = $WorkerAppName
$frontendIdentityNameResolved = $null
$entraDeviceValidationEnabledResolved = $null
$infraDeployed = $false
if (-not $SkipInfra) {
    if ($PSCmdlet.ShouldProcess($ResourceGroup, 'Deploy infrastructure (Bicep)')) {
        $deploymentPhase = 'DeployInfrastructure'
        $deploymentName = 'LogCollector-' + (Get-Date -Format 'yyyyMMddHHmmss')
        Write-DeploymentLog -Message (
            "Starting Bicep deployment; DeploymentName=$deploymentName; ResourceGroup=$ResourceGroup; " +
            "Template=$(Join-Path $root 'infra\main.bicep'); ParameterFile=$ParameterFile; " +
            "Location=$Location; CustomerPrefixOverride=$([bool]$CustomerPrefix); " +
            "WorkspaceOverride=$([bool]$ExistingLogAnalyticsWorkspaceResourceId).")
        $outputsJson = & $azCommand.Source deployment group create `
            --resource-group $ResourceGroup `
            --name $deploymentName `
            --template-file (Join-Path $root 'infra\main.bicep') `
            --parameters $ParameterFile `
            --parameters location=$Location `
            --query properties.outputs `
            --only-show-errors -o json @prefixArgs @workspaceArgs @subscriptionArgs
        if ($LASTEXITCODE -ne 0) { throw "Infrastructure deployment failed (exit code $LASTEXITCODE)." }
        $outputs = $outputsJson | ConvertFrom-Json
        $frontendAppNameResolved = $outputs.frontendAppName.value
        $workerAppNameResolved = $outputs.workerAppName.value
        $frontendIdentityNameResolved = $outputs.frontendIdentityName.value
        $entraDeviceValidationEnabledResolved = [bool]$outputs.entraDeviceValidationEnabled.value
        $infraDeployed = $true
        Write-DeploymentLog -Message (
            "Bicep deployment completed; DeploymentName=$deploymentName; " +
            "FrontendApp=$frontendAppNameResolved; WorkerApp=$workerAppNameResolved; " +
            "FrontendIdentity=$frontendIdentityNameResolved; " +
            "LogAnalyticsWorkspace=$($outputs.logAnalyticsWorkspaceName.value); " +
            "EntraDeviceValidationEnabled=$entraDeviceValidationEnabledResolved.")
        Write-Output "Frontend ingest URL: $($outputs.frontendIngestUrl.value)"
        Write-Output "Log Analytics workspace: $($outputs.logAnalyticsWorkspaceName.value)"
    }
    else {
        # -WhatIf (or a declined ShouldProcess): nothing was actually deployed, so app
        # names cannot be resolved from outputs. Do not fall through to app deployment.
        Write-DeploymentLog -Message 'Infrastructure deployment skipped by WhatIf/ShouldProcess; application deployment is also skipped.'
        Write-Output 'Infrastructure deployment skipped (WhatIf); app packages will not be previewed.'
        $SkipApps = $true
    }
}
else {
    Write-DeploymentLog -Message 'Infrastructure deployment skipped by -SkipInfra.'
}

if (-not $SkipApps) {
    if (-not $infraDeployed -and (-not $frontendAppNameResolved -or -not $workerAppNameResolved)) {
        $deploymentPhase = 'DiscoverApplications'
        Write-DeploymentLog -Message "Discovering Function Apps in resource group; ResourceGroup=$ResourceGroup."
        # Infra was skipped and no explicit names were given: discover by naming convention,
        # but refuse if the resource group holds more than one candidate for either role.
        $frontendMatches = @(& $azCommand.Source functionapp list --resource-group $ResourceGroup --query "[?ends_with(name, '-intake')].name" -o tsv --only-show-errors @subscriptionArgs)
        $workerMatches = @(& $azCommand.Source functionapp list --resource-group $ResourceGroup --query "[?ends_with(name, '-worker')].name" -o tsv --only-show-errors @subscriptionArgs)
        if ($frontendMatches.Count -ne 1) { throw "Found $($frontendMatches.Count) candidate Frontend app(s) in $ResourceGroup; pass -FrontendAppName explicitly." }
        if ($workerMatches.Count -ne 1) { throw "Found $($workerMatches.Count) candidate Worker app(s) in $ResourceGroup; pass -WorkerAppName explicitly." }
        $frontendAppNameResolved = $frontendMatches[0]
        $workerAppNameResolved = $workerMatches[0]
        Write-DeploymentLog -Message (
            "Function App discovery completed; FrontendCandidates=$($frontendMatches.Count); " +
            "WorkerCandidates=$($workerMatches.Count); FrontendApp=$frontendAppNameResolved; " +
            "WorkerApp=$workerAppNameResolved.")
    }
    if ($PSCmdlet.ShouldProcess($frontendAppNameResolved, 'Deploy Frontend package')) {
        $deploymentPhase = 'DeployFrontend'
        $frontendPackage = Join-Path $root 'Functions\Frontend.zip'
        Write-DeploymentLog -Message (
            "Starting Frontend package deployment; App=$frontendAppNameResolved; " +
            "Package=$frontendPackage; Sha256=$((Get-FileHash -LiteralPath $frontendPackage -Algorithm SHA256).Hash).")
        # The Frontend enforces mandatory client certificates (clientCertEnabled=true), which
        # also locks down its Kudu/SCM endpoint; config-zip deployment calls that endpoint
        # internally and fails with a non-JSON response ("Expecting value: line 1 column 1")
        # if it cannot authenticate there. Deny all main-site traffic before changing mTLS;
        # the rule does not apply to SCM. config-zip restarts the app, so the access restriction
        # is the durable security boundary throughout the transaction. Restore mTLS before
        # removing the restriction and starting the app.
        $deploymentLockRule = 'LogCollectorDeploymentLock-{0}-{1}' -f $PID, (Get-Date -Format 'yyyyMMddHHmmss')
        $deploymentLockMayExist = $false
        $frontendDeploymentFailure = $null
        $cleanupErrors = @()
        try {
            Write-DeploymentLog -Message "Applying temporary deny-all main-site restriction; App=$frontendAppNameResolved; Rule=$deploymentLockRule."
            $deploymentLockMayExist = $true
            & $azCommand.Source webapp config access-restriction add `
                --name $frontendAppNameResolved `
                --resource-group $ResourceGroup `
                --rule-name $deploymentLockRule `
                --action Deny `
                --ip-address '0.0.0.0/0' `
                --priority 1 `
                --scm-site false `
                --only-show-errors @subscriptionArgs | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to apply the temporary deployment access restriction to $frontendAppNameResolved (exit code $LASTEXITCODE)." }
            Write-DeploymentLog -Message "Temporary main-site restriction applied; App=$frontendAppNameResolved; Rule=$deploymentLockRule."

            Write-DeploymentLog -Message "Stopping Frontend before changing client certificate enforcement; App=$frontendAppNameResolved."
            & $azCommand.Source functionapp stop --name $frontendAppNameResolved --resource-group $ResourceGroup --only-show-errors @subscriptionArgs
            if ($LASTEXITCODE -ne 0) { throw "Failed to stop $frontendAppNameResolved before deployment (exit code $LASTEXITCODE)." }

            Write-DeploymentLog -Message "Temporarily disabling client certificate enforcement behind the deny-all restriction; App=$frontendAppNameResolved."
            & $azCommand.Source functionapp update --name $frontendAppNameResolved --resource-group $ResourceGroup --set clientCertEnabled=false --only-show-errors @subscriptionArgs | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to temporarily disable client certificate enforcement on $frontendAppNameResolved (exit code $LASTEXITCODE)." }
            Write-DeploymentLog -Message "Pushing Frontend zip through Azure CLI; App=$frontendAppNameResolved."
            & $azCommand.Source functionapp deployment source config-zip --resource-group $ResourceGroup --name $frontendAppNameResolved --src $frontendPackage --only-show-errors @subscriptionArgs
            if ($LASTEXITCODE -ne 0) { throw "Frontend deployment failed (exit code $LASTEXITCODE)." }
            Write-DeploymentLog -Message "Frontend package deployment completed; App=$frontendAppNameResolved."
        }
        catch {
            $frontendDeploymentFailure = $_
        }
        finally {
            $mTlsRestored = $false
            $deploymentLockRemoved = -not $deploymentLockMayExist

            try {
                & $azCommand.Source functionapp update --name $frontendAppNameResolved --resource-group $ResourceGroup --set clientCertEnabled=true --only-show-errors @subscriptionArgs | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $mTlsRestored = $true
                    Write-DeploymentLog -Message "Client certificate enforcement restored; App=$frontendAppNameResolved; Enabled=True."
                }
                else {
                    $cleanupErrors += "Failed to re-enable client certificate enforcement on $frontendAppNameResolved (exit code $LASTEXITCODE)."
                }
            }
            catch {
                $cleanupErrors += "Failed to re-enable client certificate enforcement on ${frontendAppNameResolved}: $($_.Exception.Message)"
            }

            if ($deploymentLockMayExist -and $mTlsRestored) {
                try {
                    & $azCommand.Source webapp config access-restriction remove `
                        --name $frontendAppNameResolved `
                        --resource-group $ResourceGroup `
                        --rule-name $deploymentLockRule `
                        --scm-site false `
                        --only-show-errors @subscriptionArgs | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $deploymentLockRemoved = $true
                        Write-DeploymentLog -Message "Temporary main-site restriction removed; App=$frontendAppNameResolved; Rule=$deploymentLockRule."
                    }
                    else {
                        $cleanupErrors += "Failed to remove temporary access restriction '$deploymentLockRule' from $frontendAppNameResolved (exit code $LASTEXITCODE)."
                    }
                }
                catch {
                    $cleanupErrors += "Failed to remove temporary access restriction '$deploymentLockRule' from ${frontendAppNameResolved}: $($_.Exception.Message)"
                }
            }
            elseif ($deploymentLockMayExist) {
                $cleanupErrors += "Temporary access restriction '$deploymentLockRule' was intentionally retained because mTLS restoration failed."
            }

            if ($mTlsRestored -and $deploymentLockRemoved) {
                try {
                    & $azCommand.Source functionapp start --name $frontendAppNameResolved --resource-group $ResourceGroup --only-show-errors @subscriptionArgs
                    if ($LASTEXITCODE -eq 0) {
                        Write-DeploymentLog -Message "Frontend restarted after protected deployment transaction; App=$frontendAppNameResolved."
                    }
                    else {
                        $cleanupErrors += "Client certificate enforcement was restored, but $frontendAppNameResolved could not be restarted (exit code $LASTEXITCODE)."
                    }
                }
                catch {
                    $cleanupErrors += "Client certificate enforcement was restored, but ${frontendAppNameResolved} could not be restarted: $($_.Exception.Message)"
                }
            }
            else {
                $cleanupErrors += "$frontendAppNameResolved was not restarted because the secure deployment boundary was not fully restored."
            }

        }
        if ($frontendDeploymentFailure -or $cleanupErrors.Count -gt 0) {
            $failureDetails = @()
            if ($frontendDeploymentFailure) {
                $failureDetails += (
                    "PrimaryErrorType=$($frontendDeploymentFailure.Exception.GetType().FullName); " +
                    "PrimaryError=$($frontendDeploymentFailure.Exception.Message); " +
                    "PrimaryPosition=$($frontendDeploymentFailure.InvocationInfo.PositionMessage)")
            }
            if ($cleanupErrors.Count -gt 0) {
                $failureDetails += ('CleanupErrors=' + ($cleanupErrors -join ' '))
            }
            throw ('Frontend deployment transaction failed: ' + ($failureDetails -join ' '))
        }
    }
    if ($PSCmdlet.ShouldProcess($workerAppNameResolved, 'Deploy Worker package')) {
        $deploymentPhase = 'DeployWorker'
        $workerPackage = Join-Path $root 'Functions\Worker.zip'
        Write-DeploymentLog -Message (
            "Starting Worker package deployment; App=$workerAppNameResolved; " +
            "Package=$workerPackage; Sha256=$((Get-FileHash -LiteralPath $workerPackage -Algorithm SHA256).Hash).")
        & $azCommand.Source functionapp deployment source config-zip --resource-group $ResourceGroup --name $workerAppNameResolved --src $workerPackage --only-show-errors @subscriptionArgs
        if ($LASTEXITCODE -ne 0) { throw "Worker deployment failed (exit code $LASTEXITCODE)." }
        Write-DeploymentLog -Message "Worker package deployment completed; App=$workerAppNameResolved."
    }
}
else {
    Write-DeploymentLog -Message 'Application package deployment skipped by -SkipApps.'
}

$deploymentPhase = 'PostDeployment'
if (-not $frontendIdentityNameResolved -and $frontendAppNameResolved) {
    $frontendIdentityNameResolved = "$frontendAppNameResolved-identity"
    Write-DeploymentLog -Message "Frontend identity name inferred from app name; Identity=$frontendIdentityNameResolved."
}
if ($null -eq $entraDeviceValidationEnabledResolved -and $frontendAppNameResolved -and -not $WhatIfPreference) {
    Write-DeploymentLog -Message "Reading Entra device validation setting; App=$frontendAppNameResolved."
    $configuredValue = & $azCommand.Source functionapp config appsettings list `
        --name $frontendAppNameResolved `
        --resource-group $ResourceGroup `
        --query "[?name=='EntraDeviceValidation__Enabled'].value | [0]" `
        --only-show-errors -o tsv @subscriptionArgs
    $parsedValue = $false
    if ($LASTEXITCODE -eq 0) {
        if ([string]::IsNullOrWhiteSpace("$configuredValue")) {
            $entraDeviceValidationEnabledResolved = $true
        }
        elseif ([bool]::TryParse("$configuredValue", [ref] $parsedValue)) {
            $entraDeviceValidationEnabledResolved = $parsedValue
        }
    }
    Write-DeploymentLog -Message (
        "Entra device validation setting resolved; App=$frontendAppNameResolved; " +
        "Enabled=$entraDeviceValidationEnabledResolved.")
}
if ($entraDeviceValidationEnabledResolved -eq $true -and $frontendIdentityNameResolved) {
    Write-Warning 'Intune enrollment certificates require Microsoft Graph Device.Read.All application consent before the pilot.'
    Write-Output "Intake managed identity: $frontendIdentityNameResolved"
    Write-Output ("From a trusted, reviewed checkout of this release, run: scripts\Grant-IntuneGraphPermission.ps1 " +
        "-SubscriptionId '$SubscriptionId' -ResourceGroup '$ResourceGroup' -IdentityName '$frontendIdentityNameResolved'")
}
elseif ($entraDeviceValidationEnabledResolved -eq $false) {
    Write-Warning 'Entra device validation is disabled. Intune submissions are accepted without proving that the certificate-bound device belongs to this tenant.'
}
else {
    Write-Warning 'Entra device validation mode could not be determined. Verify the Frontend setting EntraDeviceValidation__Enabled before onboarding devices.'
}
$deploymentPhase = 'Complete'
Write-DeploymentLog -Message (
    "Deployment completed; ResourceGroup=$ResourceGroup; FrontendApp=$frontendAppNameResolved; " +
    "WorkerApp=$workerAppNameResolved; InfrastructureDeployed=$infraDeployed; " +
    "ApplicationsSkipped=$([bool]$SkipApps); LogPath=$LogPath.")
Write-Output "Deployment complete. Detailed log: $LogPath"
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
- ``Logs\Deploy-LogCollector-<timestamp>.log`` — detailed execution trace generated at deploy time.

## Usage
``````powershell
.\Deploy-LogCollector.ps1 -SubscriptionId <sub-id> -ResourceGroup <rg-name> -Location italynorth
``````

The script reports each phase to the console and attempts to write the same timestamped
diagnostic records to ``.\Logs``. Use ``-LogPath C:\Logs\LogCollector-deploy.log`` to select
another location. If the file is unavailable, deployment continues with console logging.
Script-generated records include resource discovery, selected paths, package hashes, Azure
CLI operations, durations and decisions; they mask the subscription ID and never record
Azure credentials or access tokens. Azure CLI errors are emitted by the CLI itself and can
include resource IDs.

### Resource name collisions

The storage account, Service Bus namespace and Function app names are globally unique across
Azure. If the deployment fails with ``StorageAccountAlreadyTaken`` or
``StorageAccountInAnotherResourceGroup`` — for example because this subscription already
hosts another LogCollector installation — redeploy with a short customer/company code:

``````powershell
.\Deploy-LogCollector.ps1 -SubscriptionId <sub-id> -ResourceGroup <rg-name> ``
  -Location italynorth -CustomerPrefix ACI
``````

That produces ``aci-LogCollector-intake``, ``acilogcollectordata`` and so on (the template
lowercases the prefix). Set it on the first deployment: changing it later renames rather than
migrates the resources.

Use ``-SkipInfra`` to redeploy only the Function app code against an existing resource group,
or ``-SkipApps`` to only (re)apply the infrastructure template. Run with ``-WhatIf`` first to
preview the changes.

### Optional Microsoft Entra device validation for Intune certificates

The secure default is ``entraDeviceValidationEnabled = true``. In this mode, devices authenticated
with Microsoft Intune enrollment certificates are also verified as enabled devices in the
frontend identity's tenant. Grant Microsoft Graph ``Device.Read.All`` application permission to
the exact intake identity printed by ``Deploy-LogCollector.ps1`` before starting the pilot.

The operator must hold **Privileged Role Administrator** or **Global Administrator** in Entra.
Cloud Application Administrator is not sufficient for Microsoft Graph application permissions.
Azure ``Contributor``, ``Owner`` and ``User Access Administrator`` do not include this consent.

The administrative helper is intentionally **not bundled** in this unsigned deployment package:
running package-supplied PowerShell as a tenant administrator would create an unnecessary
supply-chain trust boundary. Run ``scripts\Grant-IntuneGraphPermission.ps1`` only from a trusted,
reviewed checkout of the matching LogCollector release, or implement the equivalent app-role
assignment through your organization's approved Entra administration process.

If the printed identity name must be rediscovered, stop unless exactly one candidate exists:

``````powershell
`$intakeIdentities = @(az identity list --subscription <sub-id> -g <rg-name> ``
  --query "[?ends_with(name, '-intake-identity')].name" -o tsv)
if (`$intakeIdentities.Count -ne 1) { throw "Expected one intake identity, found `$(`$intakeIdentities.Count)." }
.\scripts\Grant-IntuneGraphPermission.ps1 -SubscriptionId <sub-id> ``
  -ResourceGroup <rg-name> -IdentityName `$intakeIdentities[0]
``````

Do not start the pilot until the helper reports that ``Device.Read.All`` was assigned or was
already present. Without it, the intake accepts the device certificate but returns HTTP 500;
Application Insights shows the Microsoft Graph device lookup returning HTTP 403.

If the customer cannot grant this permission, set ``entraDeviceValidationEnabled = false`` in
``infra\$parameterFileName`` and redeploy. The resulting Function App setting is
``EntraDeviceValidation__Enabled=false``. Certificate-chain validation, request signing,
anti-replay and exact certificate-to-device-ID binding remain enforced, but the service can no
longer prove that the device belongs to the customer's Entra tenant. Use this exception only
after accepting that reduced tenant-isolation control.

### Reusing an existing Log Analytics workspace

By default a new workspace is created alongside the other resources. To send telemetry to a
workspace you already have (in this resource group or another one, same tenant), pass its
resource ID:

``````powershell
.\Deploy-LogCollector.ps1 -SubscriptionId <sub-id> -ResourceGroup <rg-name> -Location italynorth ``
  -ExistingLogAnalyticsWorkspaceResourceId "/subscriptions/<sub-id>/resourceGroups/<law-rg>/providers/Microsoft.OperationalInsights/workspaces/<law-name>"
``````

The identity running the deployment needs Contributor (or an equivalent role that can write
``Microsoft.OperationalInsights/workspaces/tables``) on the workspace's own resource group as
well as on ``<rg-name>``, since the custom tables are created there. Set this on the first
deployment: switching workspaces afterwards does not migrate previously ingested data.

### Worker deployment fails with a 403 on storage

If the Worker deployment fails with
``InaccessibleStorageException`` / ``BlobUploadFailedException: ... 403`` while the Frontend
deploys fine, check the storage account's public network access:

``````powershell
az storage account show -g <rg-name> -n <storage-name> --query publicNetworkAccess -o tsv
``````

The Worker runs on Flex Consumption, which pulls its package from the ``worker-deploy`` blob
container; the deployment service needs to reach the blob endpoint. The template requests
``Enabled``, but an Azure Policy in the tenant may silently force it back to ``Disabled``.
Grant a policy exemption for this storage account, then re-enable and redeploy the apps only:

``````powershell
az storage account update -g <rg-name> -n <storage-name> --public-network-access Enabled
.\Deploy-LogCollector.ps1 -SubscriptionId <sub-id> -ResourceGroup <rg-name> -SkipInfra
``````

Data-plane access stays identity-only regardless: shared key auth is disabled and every
caller must present an Entra identity with an explicit RBAC role.

### Frontend deployment fails with a JSON decode error

If the Frontend package push fails with an Azure CLI traceback ending in
``requests.exceptions.JSONDecodeError: Expecting value: line 1 column 1`` inside
``_get_app_settings_from_scm``, this is expected and handled automatically by this script:
the Frontend enforces mandatory client certificates (``clientCertEnabled=true``), which also
locks down its Kudu/SCM endpoint that ``az functionapp deployment source config-zip`` calls
internally. This script first adds a deny-all access restriction to the main site (not SCM),
stops the Frontend, pushes the package, restores enforcement, removes the restriction and
then starts the app. The restriction remains effective when ``config-zip`` restarts the app.
If the script is terminated mid-transaction, the main site remains blocked rather than being
exposed without mTLS. Verify enforcement, remove the temporary rule and restart the app
manually before considering the deployment complete:

``````powershell
az functionapp show -g <rg-name> -n <frontend-app-name> --query clientCertEnabled -o tsv
az functionapp update -g <rg-name> -n <frontend-app-name> --set clientCertEnabled=true
az webapp config access-restriction show -g <rg-name> -n <frontend-app-name> -o table
az webapp config access-restriction remove -g <rg-name> -n <frontend-app-name> --rule-name <LogCollectorDeploymentLock-...> --scm-site false
az functionapp start -g <rg-name> -n <frontend-app-name>
``````

### Verifying the deployment

``````powershell
az functionapp list -g <rg-name> --query "[].{name:name,state:state}" -o table
``````

Both apps should report ``Running``. A plain HTTPS GET to ``/api/health`` returning
**403 "Client Certificate Required"** is the expected result: the intake endpoint enforces
mutual TLS and rejects any request without a client certificate.
"@
Set-Content -LiteralPath (Join-Path $target 'README.md') -Value $readme -Encoding utf8

[pscustomobject]@{
    Version = $version
    PackagePath = [IO.Path]::GetFullPath($target)
    FrontendSha256 = $frontendHash
    WorkerSha256 = $workerHash
    ParameterFileName = $parameterFileName
    FileCount = @(Get-ChildItem -LiteralPath $target -File -Recurse).Count
}
