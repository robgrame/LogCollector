#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:OriginalSkipMain = $env:INTUNE_DEPLOYMENT_TELEMETRY_SKIP_MAIN
    $env:INTUNE_DEPLOYMENT_TELEMETRY_SKIP_MAIN = '1'
    $script:TelemetryScript = Join-Path $PSScriptRoot '..\..\scripts\Intune-DeploymentTelemetry.ps1'
    . $script:TelemetryScript

    function Get-LogCollectorEndpointConfiguration {}
    function Send-LogCollectorData {
        param(
            [uri]$FrontendUrl,
            [string]$TableName,
            [object[]]$Records,
            [string]$Source,
            [string]$CertificateThumbprint,
            [string]$CertificateSubjectLike,
            [string]$CertificateIssuerLike,
            [string[]]$PkiRootCaThumbprints,
            [string[]]$PkiRootCaSubjects,
            [string[]]$PkiIntermediateCaThumbprints,
            [string[]]$PkiIntermediateCaSubjects,
            [int]$MaxAttempts,
            [int]$TimeoutSeconds,
            [int]$MaxDelaySeconds,
            [switch]$SkipDrain
        )
    }

    function New-TestDeliveryConfiguration {
        [pscustomobject]@{
            Endpoint = [uri]'https://telemetry.example.test/api/submit'
            ModuleConfiguration = [pscustomobject]@{}
        }
    }
}

AfterAll {
    $env:INTUNE_DEPLOYMENT_TELEMETRY_SKIP_MAIN = $script:OriginalSkipMain
}

Describe 'Telemetry configuration' {
    It 'supports explicitly disabled telemetry without a module or endpoint' {
        $result = Resolve-LogCollectorTelemetryConfiguration -Mode Disabled `
            -Endpoint '' -MinimumModuleVersion '1.8.0'

        $result.Enabled | Should -BeFalse
        $result.Category | Should -Be 'Disabled'
        (Get-DeploymentTelemetryExitCode -EssentialOperationSucceeded $true) | Should -Be 0
    }

    It 'does not contain direct client-secret or managed-identity credential flows' {
        $source = Get-Content -LiteralPath $script:TelemetryScript -Raw
        $source | Should -Not -Match 'DirectClientSecret|client_secret|APP-REGISTRATION-CLIENT-SECRET'
        $source | Should -Not -Match 'IDENTITY_HEADER|MSI_SECRET|access_token'
    }

    It 'reports a missing LogCollector module without failing provisioning' {
        Mock Import-Module { throw 'module unavailable' }

        $result = Resolve-LogCollectorTelemetryConfiguration -Mode Certificate `
            -Endpoint '' -MinimumModuleVersion '1.8.0'

        $result.Enabled | Should -BeFalse
        $result.Category | Should -Be 'ConfigurationMissing'
        $result.Message | Should -Match 'module unavailable'
        (Get-DeploymentTelemetryExitCode -EssentialOperationSucceeded $true) | Should -Be 0
    }

    It 'rejects endpoint query strings that could contain credentials' {
        Mock Import-Module {}
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{ FrontendUrl = 'https://configured.example.test/api/submit' }
        }

        $result = Resolve-LogCollectorTelemetryConfiguration -Mode Certificate `
            -Endpoint 'https://telemetry.example.test/api/submit?code=secret' `
            -MinimumModuleVersion '1.8.0'

        $result.Enabled | Should -BeFalse
        $result.Category | Should -Be 'ConfigurationMissing'
        $result.Message | Should -Match 'query string'
    }

    It 'uses the protected machine-wide LogCollector endpoint when none is explicit' {
        Mock Import-Module {}
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://configured.example.test/api/submit'
                CertificateThumbprint = 'AABBCCDD'
            }
        }

        $result = Resolve-LogCollectorTelemetryConfiguration -Mode Certificate `
            -Endpoint '' -MinimumModuleVersion '1.8.0'

        $result.Enabled | Should -BeTrue
        $result.Endpoint.AbsoluteUri | Should -Be 'https://configured.example.test/api/submit'
    }

    It 'honors the protected machine-wide submission kill switch' {
        Mock Import-Module {}
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{
                FrontendUrl = 'https://configured.example.test/api/submit'
                SubmissionEnabled = $false
            }
        }

        $result = Resolve-LogCollectorTelemetryConfiguration -Mode Certificate `
            -Endpoint '' -MinimumModuleVersion '1.8.0'

        $result.Enabled | Should -BeFalse
        $result.Category | Should -Be 'Disabled'
    }

    It 'rejects an HTTPS endpoint outside the LogCollector submit route' {
        Mock Import-Module {}
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{ FrontendUrl = 'https://configured.example.test/api/submit' }
        }

        $result = Resolve-LogCollectorTelemetryConfiguration -Mode Certificate `
            -Endpoint 'https://telemetry.example.test/api/other' `
            -MinimumModuleVersion '1.8.0'

        $result.Enabled | Should -BeFalse
        $result.Message | Should -Match '/api/submit'
    }
}

Describe 'LogCollector delivery classification' {
    BeforeEach {
        $script:Payload = [pscustomobject]@{ ExecutionId = [guid]::NewGuid().ToString() }
    }

    It 'reports a delivered batch as sent' {
        Mock Send-LogCollectorData {
            [pscustomobject]@{
                Disposition = 'Delivered'; StatusCode = 202; Attempts = 1
                Message = 'accepted'; SpoolDirectory = 'C:\ProgramData\LogCollector\SharedSpool\x'
            }
        }

        $result = Send-LogCollectorTelemetry -Configuration (New-TestDeliveryConfiguration) `
            -Payload $script:Payload -TableName 'IntuneDeploymentTelemetry_CL' `
            -Source 'test.ps1' -TimeoutSeconds 5 -BudgetSeconds 10

        $result.Success | Should -BeTrue
        $result.Category | Should -Be 'Sent'
    }

    It 'classifies an authentication rejection retained in the spool' {
        Mock Send-LogCollectorData {
            [pscustomobject]@{
                Disposition = 'Deferred'; StatusCode = 403; Attempts = 1
                Message = 'forbidden'; SpoolDirectory = 'C:\ProgramData\LogCollector\SharedSpool\x'
            }
        }

        $result = Send-LogCollectorTelemetry -Configuration (New-TestDeliveryConfiguration) `
            -Payload $script:Payload -TableName 'IntuneDeploymentTelemetry_CL' `
            -Source 'test.ps1' -TimeoutSeconds 5 -BudgetSeconds 10

        $result.Success | Should -BeFalse
        $result.Category | Should -Be 'AuthenticationError'
    }

    It 'classifies a timeout retained in the spool' {
        Mock Send-LogCollectorData {
            [pscustomobject]@{
                Disposition = 'Deferred'; StatusCode = 0; Attempts = 1
                Message = 'request timed out'; SpoolDirectory = 'C:\ProgramData\LogCollector\SharedSpool\x'
            }
        }

        $result = Send-LogCollectorTelemetry -Configuration (New-TestDeliveryConfiguration) `
            -Payload $script:Payload -TableName 'IntuneDeploymentTelemetry_CL' `
            -Source 'test.ps1' -TimeoutSeconds 5 -BudgetSeconds 10

        $result.Category | Should -Be 'Timeout'
    }

    It 'passes a bounded single-attempt request to the shared client' {
        $script:CapturedDeliveryParameters = $null
        Mock Send-LogCollectorData {
            $script:CapturedDeliveryParameters = @{
                MaxAttempts = $MaxAttempts
                TimeoutSeconds = $TimeoutSeconds
                MaxDelaySeconds = $MaxDelaySeconds
                SkipDrain = [bool]$SkipDrain
            }
            [pscustomobject]@{
                Disposition = 'Deferred'; StatusCode = 500; Attempts = 1
                Message = 'server error'; SpoolDirectory = 'C:\ProgramData\LogCollector\SharedSpool\x'
            }
        }

        $null = Send-LogCollectorTelemetry -Configuration (New-TestDeliveryConfiguration) `
            -Payload $script:Payload -TableName 'IntuneDeploymentTelemetry_CL' `
            -Source 'test.ps1' -TimeoutSeconds 15 -BudgetSeconds 20

        $script:CapturedDeliveryParameters.MaxAttempts | Should -Be 1
        $script:CapturedDeliveryParameters.TimeoutSeconds | Should -Be 15
        $script:CapturedDeliveryParameters.MaxDelaySeconds | Should -Be 20
        $script:CapturedDeliveryParameters.SkipDrain | Should -BeTrue
    }
}

Describe 'Provisioning and sensitive-data semantics' {
    It 'detects the Intune policy identifier from the execution path when configuration is empty' {
        $policyId = '22222222-2222-2222-2222-222222222222'
        $identity = Get-IntunePolicyIdentity -ConfiguredPolicyId '' `
            -ExecutingScriptPath "C:\Program Files (x86)\Microsoft Intune Management Extension\Policies\Scripts\$policyId`_1\$policyId`_1.ps1"

        $identity.ConfiguredPolicyId | Should -BeNullOrEmpty
        $identity.DetectedPolicyId | Should -Be $policyId
        $identity.EffectivePolicyId | Should -Be $policyId
        $identity.MatchStatus | Should -Be 'DetectedFromScriptPath'
    }

    It 'returns non-zero only for an essential-operation failure' {
        Get-DeploymentTelemetryExitCode -EssentialOperationSucceeded $true | Should -Be 0
        Get-DeploymentTelemetryExitCode -EssentialOperationSucceeded $false | Should -Be 1
    }

    It 'contains unexpected telemetry exceptions and preserves provisioning success' {
        $result = Invoke-FailOpenTelemetryOperation -Operation {
            throw 'unexpected telemetry failure'
        } 3>$null

        $result | Should -BeFalse
        Get-DeploymentTelemetryExitCode -EssentialOperationSucceeded $true | Should -Be 0
    }

    It 'does not upload formatted MDM event messages' {
        $source = Get-Content -LiteralPath $script:TelemetryScript -Raw
        $source | Should -Not -Match 'FormatDescription\('
        $source | Should -Not -Match 'MessageEventLimit'
    }

    It 'does not emit user identity or LogCollector-reserved payload columns' {
        $source = Get-Content -LiteralPath $script:TelemetryScript -Raw
        $source | Should -Not -Match 'UserUPN\s+=\s+\$userUpn'
        $source | Should -Not -Match 'CurrentLoggedOnUser\s+=\s+\$interactiveUser'
        $source | Should -Not -Match 'DeviceName\s+=\s+\$env:COMPUTERNAME'
        $source | Should -Not -Match '(?m)^\s+CorrelationId\s+=\s+\$ExecutionState\.CorrelationId'
        $source | Should -Match '(?m)^\s+DeviceCorrelationId\s+=\s+\$ExecutionState\.CorrelationId'
    }
}

Describe 'IME evidence and delay classification' {
    It 'classifies polling without target-policy delivery when logs cover the collection window' {
        $logDirectory = Join-Path $TestDrive 'ime-logs'
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
        @(
            '<![LOG[IME started]LOG]!><time="09:59:00.0000000+000" date="9-23-2026">'
            '<![LOG[[PowerShell] Requesting policies with session id 11111111-1111-1111-1111-111111111111]LOG]!><time="10:05:00.0000000+000" date="9-23-2026">'
            '<![LOG[[ServiceBase], check in using device check in AAD App]LOG]!><time="10:09:00.0000000+000" date="9-23-2026">'
        ) | Set-Content -LiteralPath (Join-Path $logDirectory 'IntuneManagementExtension.log') -Encoding UTF8
        @(
            '<![LOG[Agent executor started]LOG]!><time="09:59:00.0000000+000" date="9-23-2026">'
            '<![LOG[Agent executor idle]LOG]!><time="10:09:00.0000000+000" date="9-23-2026">'
        ) | Set-Content -LiteralPath (Join-Path $logDirectory 'AgentExecutor.log') -Encoding UTF8

        $assignment = [datetime]::SpecifyKind([datetime]'2026-09-23T10:00:00', [DateTimeKind]::Utc)
        $collectionEnd = [datetime]::SpecifyKind([datetime]'2026-09-23T10:10:00', [DateTimeKind]::Utc)
        $evidence = Get-ImeLogEvidence -AssignmentUtc $assignment `
            -CollectionEndUtc $collectionEnd -PolicyId '22222222-2222-2222-2222-222222222222' `
            -MaximumPollTimestamps 10 -LogDirectoryPath $logDirectory
        $classification = Get-DeploymentDelayClassification -ImeEvidence $evidence `
            -MdmCycleCount 1 -AssignmentUtc $assignment

        $evidence.LogCoverageStatus | Should -Be 'Complete'
        $classification.Classification | Should -Be 'PowerShellPollingPolicyNotReturned'
        $classification.Confidence | Should -Be 'High'
    }

    It 'does not invalidate classification when only the poll timestamp output list is capped' {
        $evidence = [pscustomobject]@{
            LogCoverageStatus = 'Complete'; LogEvidenceTruncated = $false
            PolicyPollCountSinceAssignment = 2; DeviceCheckInCountSinceAssignment = 1
            GenericWorkloadCheckInCount = 0; PolicyReceivedUtc = $null
            PolicyProcessingUtc = $null; ScriptMaterializedUtc = $null
            ExecutionIdentifiedUtc = $null; FirstManagementActivityUtc = $null
            PolicyPollTimestampsTruncated = $true
        }

        $classification = Get-DeploymentDelayClassification -ImeEvidence $evidence `
            -MdmCycleCount 1 -AssignmentUtc ([datetime]::UtcNow.AddHours(-1))

        $classification.Classification | Should -Be 'PowerShellPollingPolicyNotReturned'
    }

    It 'marks evidence truncated when the IME log byte limit is reached' {
        $logDirectory = Join-Path $TestDrive 'limited-ime-logs'
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
        '<![LOG[IME started]LOG]!><time="10:00:00.0000000+000" date="9-23-2026">' |
            Set-Content -LiteralPath (Join-Path $logDirectory 'IntuneManagementExtension.log') -Encoding UTF8
        $assignment = [datetime]::SpecifyKind([datetime]'2026-09-23T10:00:00', [DateTimeKind]::Utc)
        $collectionEnd = [datetime]::SpecifyKind([datetime]'2026-09-23T10:10:00', [DateTimeKind]::Utc)

        $evidence = Get-ImeLogEvidence -AssignmentUtc $assignment `
            -CollectionEndUtc $collectionEnd -MaximumPollTimestamps 10 `
            -MaximumLogBytes 1 -LogDirectoryPath $logDirectory

        $evidence.LogEvidenceTruncated | Should -BeTrue
        $evidence.LogScanStopReason | Should -Be 'ByteLimitExceeded'
    }
}

Describe 'IME CMTrace timestamp parsing' {
    It 'applies signed CMTrace UTC bias values in minutes' {
        (ConvertFrom-ImeCmTraceTimestamp `
            -Line '<![LOG[test]LOG]!><time="10:00:00.0000000+480" date="9-23-2026">').ToString('o') |
            Should -Be '2026-09-23T18:00:00.0000000Z'
        (ConvertFrom-ImeCmTraceTimestamp `
            -Line '<![LOG[test]LOG]!><time="10:00:00.0000000-120" date="9-23-2026">').ToString('o') |
            Should -Be '2026-09-23T08:00:00.0000000Z'
    }
}
