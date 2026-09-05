#Requires -Version 5.1
<#
.SYNOPSIS
Grants Microsoft Graph Device.Read.All to the intake managed identity.
.NOTES
Version 1.0.1. Requires an authorized Entra administrator signed in through Azure CLI.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [Parameter(Mandatory)]
    [string] $ResourceGroup,
    [string] $IdentityName = 'LogCollector-intake-identity'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$identityJson = & az identity show --subscription $SubscriptionId --resource-group $ResourceGroup --name $IdentityName --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the intake managed identity.' }
$identity = $identityJson | ConvertFrom-Json
$token = & az account get-access-token --subscription $SubscriptionId --resource https://graph.microsoft.com --query accessToken --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Unable to acquire a Graph token for the target subscription tenant.' }
$headers = @{ Authorization = "Bearer $token" }
$graph = Invoke-RestMethod -Method Get -Headers $headers -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?`$select=id,appRoles"
$role = @($graph.appRoles | Where-Object {
    $_.value -eq 'Device.Read.All' -and $_.allowedMemberTypes -contains 'Application' -and $_.isEnabled
})
if ($role.Count -ne 1) { throw 'Expected exactly one enabled Device.Read.All application role.' }
$url = "https://graph.microsoft.com/v1.0/servicePrincipals/$($identity.principalId)/appRoleAssignments"
$existing = Invoke-RestMethod -Method Get -Headers $headers -Uri $url
if (@($existing.value | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $role[0].id }).Count -gt 0) {
    Write-Output 'Device.Read.All is already assigned.'
    return
}
if (-not $PSCmdlet.ShouldProcess($IdentityName, 'Grant Microsoft Graph Device.Read.All application permission')) { return }

$body = @{
    principalId = $identity.principalId
    resourceId = $graph.id
    appRoleId = $role[0].id
} | ConvertTo-Json -Compress
$null = Invoke-RestMethod -Method Post -Headers $headers -Uri $url -ContentType 'application/json' -Body $body
Write-Output 'Assigned Microsoft Graph Device.Read.All to the intake managed identity.'
