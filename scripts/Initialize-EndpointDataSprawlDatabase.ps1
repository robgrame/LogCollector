[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9-]{1,63}$')]
    [string]$ServerName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$')]
    [string]$DatabaseName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]{2,128}$')]
    [string]$WorkerIdentityName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$WorkerIdentityClientId,

    [ValidatePattern('^[A-Za-z0-9-]{2,128}$')]
    [string]$DashboardIdentityName,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$DashboardIdentityClientId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [string]$SchemaPath = (Join-Path $PSScriptRoot '..\infra\sql\001-endpoint-data-sprawl.sql')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    throw "SQL schema file not found: $SchemaPath"
}

if ([string]::IsNullOrWhiteSpace($DashboardIdentityName) -ne
    [string]::IsNullOrWhiteSpace($DashboardIdentityClientId)) {
    throw 'DashboardIdentityName and DashboardIdentityClientId must both be supplied or both omitted.'
}

$publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 30).ip
if ($publicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw 'Unable to determine a valid public IPv4 address for the temporary SQL firewall rule.'
}

$ruleSuffix = if ($env:GITHUB_RUN_ID -match '^\d+$') {
    $env:GITHUB_RUN_ID
}
else {
    [Guid]::NewGuid().ToString('N').Substring(0, 12)
}
$firewallRuleName = "Deployment-$ruleSuffix"
$initializerProject = Join-Path $PSScriptRoot '..\tools\LogCollector.DatabaseInitializer\LogCollector.DatabaseInitializer.csproj'
$ruleCreated = $false
$primaryError = $null

try {
    az sql server firewall-rule create `
        --resource-group $ResourceGroup `
        --server $ServerName `
        --name $firewallRuleName `
        --start-ip-address $publicIp `
        --end-ip-address $publicIp `
        --subscription $SubscriptionId `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create temporary SQL firewall rule '$firewallRuleName'."
    }
    $ruleCreated = $true

    $initializerArguments = @(
        '--server', $ServerName,
        '--database', $DatabaseName,
        '--worker-identity-name', $WorkerIdentityName,
        '--worker-identity-client-id', $WorkerIdentityClientId,
        '--schema', $SchemaPath
    )
    if (-not [string]::IsNullOrWhiteSpace($DashboardIdentityName)) {
        $initializerArguments += @(
            '--dashboard-identity-name', $DashboardIdentityName,
            '--dashboard-identity-client-id', $DashboardIdentityClientId
        )
    }

    dotnet run `
        --project $initializerProject `
        --configuration Release `
        -- @initializerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize database '$DatabaseName' on server '$ServerName'."
    }
}
catch {
    $primaryError = $_
}
finally {
    if ($ruleCreated) {
        az sql server firewall-rule delete `
            --resource-group $ResourceGroup `
            --server $ServerName `
            --name $firewallRuleName `
            --subscription $SubscriptionId `
            --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $cleanupError = [InvalidOperationException]::new(
                "Failed to remove temporary SQL firewall rule '$firewallRuleName'.")
            if ($null -ne $primaryError) {
                throw [AggregateException]::new(
                    'Database initialization and firewall cleanup both failed.',
                    @($primaryError.Exception, $cleanupError))
            }

            throw $cleanupError
        }
    }
}

if ($null -ne $primaryError) {
    throw $primaryError
}

$dashboardMessage = if ([string]::IsNullOrWhiteSpace($DashboardIdentityName)) {
    ' without a dashboard identity'
}
else {
    " and dashboard identity $DashboardIdentityName"
}
Write-Output "Initialized $ServerName/$DatabaseName for worker identity $WorkerIdentityName$dashboardMessage."
