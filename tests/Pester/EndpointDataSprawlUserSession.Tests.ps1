BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Store = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Frontend\Services\UserSessionStore.cs'))
    $script:RegisterFunction = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Frontend\Functions\UserSessionRegistrationFunction.cs'))
    $script:Intake = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Frontend\Functions\TelemetryIngestFunction.cs'))
    $script:Pointer = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Shared\Models\QueuedIngestionMessage.cs'))
    $script:WorkerProgram = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Functions\Worker\Program.cs'))
    $script:PermissionHelper = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'scripts\Grant-IntuneGraphPermission.ps1'))
    $script:MainBicep = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'infra\main.bicep'))
    $script:Client = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psm1'))
    $script:Transport = [IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'src\Client\InventoryClient.psm1'))
}

Describe 'Endpoint Data Sprawl delegated user sessions' {
    It 'registers through the exact mTLS endpoint and bearer header' {
        $script:RegisterFunction | Should -Match 'Route = "user-sessions/register"'
        $script:RegisterFunction | Should -Match 'request\.Headers\.Authorization'
        $script:RegisterFunction | Should -Match 'token\.DeviceId != trustedDeviceId'
        $script:RegisterFunction | Should -Not -Match 'authorization\.Parameter.*Log'
    }

    It 'stores only a registration hash and bounded authorization metadata' {
        $script:Store | Should -Match 'SHA256\.HashData'
        $script:Store | Should -Match 'RandomNumberGenerator\.GetBytes\(32\)'
        $script:Store | Should -Match '\["TrustedDeviceId"\]'
        $script:Store | Should -Match '\["UserCorrelationId"\]'
        $script:Store | Should -Match '\["CreatedAtUtc"\]'
        $script:Store | Should -Match '\["ExpiresAtUtc"\]'
        $script:Store | Should -Match '\["RevokedAtUtc"\]'
        $script:Store | Should -Not -Match '\["RegistrationId"\]'
        $script:Store | Should -Match 'PurgeExpiredAsync'
    }

    It 'resolves only the opaque header into a trusted queue correlation' {
        $script:Intake | Should -Match 'RegistrationHeaderName'
        $script:Intake | Should -Match '\.ResolveAsync\('
        $script:Pointer | Should -Match 'JsonPropertyName\("userCorrelationId"\)'
        $script:Pointer | Should -Not -Match 'registrationId'
        $script:Intake | Should -Match 'correlation was omitted'
        $script:Intake | Should -Not -Match 'StatusCodes\.Status403Forbidden,\s*registration\.FailureReason'
    }

    It 'supports certificate-bound revocation without retaining the correlation mapping' {
        $script:RegisterFunction | Should -Match 'Route = "user-sessions/revoke"'
        $script:RegisterFunction | Should -Match '\.RevokeAsync\('
        $script:Store | Should -Match 'entity\["UserCorrelationId"\] = null'
        $script:Client | Should -Match 'function Revoke-LogCollectorUserSession'
    }

    It 'places the HMAC key behind a deterministic Key Vault reference' {
        $script:MainBicep | Should -Match 'Microsoft\.KeyVault/vaults@'
        $script:MainBicep | Should -Match 'user-correlation-hmac-key'
        $script:MainBicep | Should -Match 'roleKeyVaultSecretsUser'
        $script:MainBicep | Should -Match '@Microsoft\.KeyVault\(SecretUri='
        $script:MainBicep | Should -Match (
            'userSessionHmacSecret!\.properties\.secretUri\}\)')
        $script:MainBicep | Should -Match (
            'output userSessionHmacSecretUri[\s\S]*userSessionHmacSecret!\.properties\.secretUri')
        $script:MainBicep | Should -Not -Match 'secretUriWithVersion'
        $script:MainBicep | Should -Not -Match (
            "name: 'UserSession__HmacKeyBase64', value: userSessionHmacKeyBase64")
        $script:MainBicep | Should -Match 'output userSessionHmacSecretUri'
        $script:MainBicep | Should -Match 'param userSessionEnabled bool = false'
        $script:MainBicep | Should -Match 'param userSessionRegistrationTtlMinutes int = 480'
        $script:MainBicep | Should -Match '@maxValue\(1440\)'
    }

    It 'removes Worker Intune primary-user authority and permission' {
        $script:WorkerProgram | Should -Not -Match 'MicrosoftGraph'
        $script:WorkerProgram | Should -Not -Match 'IntunePrimaryUser'
        $script:PermissionHelper | Should -Not -Match 'DeviceManagementManagedDevices\.Read\.All'
        $script:PermissionHelper | Should -Match 'Device\.Read\.All'
        $script:MainBicep | Should -Not -Match 'UserCorrelation__'
    }

    It 'keeps access tokens out of the spool and binds opaque registrations to entries' {
        $script:Client | Should -Match 'AuthenticationHeaderValue\(''Bearer'', \$AccessToken\)'
        $script:Transport | Should -Match "'X-LogCollector-User-Session'"
        $script:Transport | Should -Match 'Save-SpoolEntry[\s\S]*UserSessionRegistrationId'
        $script:Transport | Should -Not -Match 'Save-SpoolEntry.*AccessToken'
    }
}
