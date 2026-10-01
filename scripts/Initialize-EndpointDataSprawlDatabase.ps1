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

    dotnet run `
        --project $initializerProject `
        --configuration Release `
        -- `
        --server $ServerName `
        --database $DatabaseName `
        --worker-identity-name $WorkerIdentityName `
        --worker-identity-client-id $WorkerIdentityClientId `
        --schema $SchemaPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize database '$DatabaseName' on server '$ServerName'."
    }
}
finally {
    $null = az sql server firewall-rule delete `
        --resource-group $ResourceGroup `
        --server $ServerName `
        --name $firewallRuleName `
        --subscription $SubscriptionId `
        --yes `
        --only-show-errors 2>&1
}

Write-Output "Initialized $ServerName/$DatabaseName for worker identity $WorkerIdentityName."
