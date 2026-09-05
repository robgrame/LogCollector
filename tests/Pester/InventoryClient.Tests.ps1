<#
.SYNOPSIS
    Pester tests for envelope construction, retry timing, response
    classification, and the drain/submit orchestration.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $repoRoot 'src\Client\InventorySpool.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'src\Client\InventoryClient.psm1') -Force -DisableNameChecking

    $script:DeviceId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
}

Describe 'InventoryClient' {
BeforeEach {
    # Substitute only the fixture identity on non-elevated Windows test hosts.
    Mock -ModuleName InventorySpool Test-SpoolTrustedIdentity {
        param($Sid, [switch] $Ancestor)
        return ($Sid -in @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -or
            ($Ancestor -and $Sid -eq 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'))
    }
    Mock -ModuleName InventorySpool New-SpoolSecurityDescriptor {
        param([switch] $Directory)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($Directory) {
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetSecurityDescriptorSddlForm("O:${sid}G:${sid}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;$sid)")
        }
        else {
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetSecurityDescriptorSddlForm("O:${sid}G:${sid}D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;$sid)")
        }
        return $acl
    }
}

Context 'New-InventoryEnvelope' {

    It 'produces the LOGCOLLECTOR-INVENTORY-V1 contract' {
        $envelope = New-InventoryEnvelope -TableName 'InventoryWindows_CL' `
            -Records @(@{ RecordType = 'Hardware' }) -EntraDeviceId $script:DeviceId

        $envelope.envelopeVersion | Should -BeExactly 'LOGCOLLECTOR-INVENTORY-V1'
        $envelope.tableName | Should -BeExactly 'InventoryWindows_CL'
        $envelope.entraDeviceId | Should -BeExactly $script:DeviceId
        $envelope.source | Should -BeExactly 'WindowsScheduledTask'
        @($envelope.records).Count | Should -Be 1
    }

    It 'normalizes the device id to canonical GUID form' {
        $envelope = New-InventoryEnvelope -TableName 'T_CL' -Records @(@{ a = 1 }) `
            -EntraDeviceId $script:DeviceId.ToUpper()

        $envelope.entraDeviceId | Should -BeExactly $script:DeviceId
    }

    It 'rejects a device id that is not a GUID' {
        { New-InventoryEnvelope -TableName 'T_CL' -Records @(@{ a = 1 }) -EntraDeviceId 'nope' } |
            Should -Throw
    }

    It 'defaults the device name to the machine name' {
        $envelope = New-InventoryEnvelope -TableName 'T_CL' -Records @(@{ a = 1 }) -EntraDeviceId $script:DeviceId

        $envelope.deviceName | Should -BeExactly ([System.Environment]::MachineName)
    }

    It 'emits a round-trip-safe ISO-8601 UTC collection timestamp' {
        $when = [DateTimeOffset]::new(2026, 4, 1, 6, 0, 0, [TimeSpan]::FromHours(2))

        $envelope = New-InventoryEnvelope -TableName 'T_CL' -Records @(@{ a = 1 }) `
            -EntraDeviceId $script:DeviceId -CollectedAtUtc $when

        $envelope.collectedAtUtc | Should -BeExactly '2026-04-01T04:00:00.0000000+00:00'
    }

    It 'stringifies every property value' {
        $envelope = New-InventoryEnvelope -TableName 'T_CL' -Records @(@{ a = 1 }) `
            -EntraDeviceId $script:DeviceId -Properties @{ Count = 42 }

        $envelope.properties['Count'] | Should -BeOfType [string]
        $envelope.properties['Count'] | Should -BeExactly '42'
    }

    It 'serializes to JSON the frontend can parse' {
        $envelope = New-InventoryEnvelope -TableName 'T_CL' -Records @(@{ RecordType = 'Hardware'; Model = 'X1' }) `
            -EntraDeviceId $script:DeviceId

        $round = $envelope | ConvertTo-Json -Depth 24 -Compress | ConvertFrom-Json

        $round.tableName | Should -BeExactly 'T_CL'
        $round.records[0].Model | Should -BeExactly 'X1'
    }

    It 'always emits records as an array, even for a single record' {
        $json = New-InventoryEnvelope -TableName 'T_CL' -Records @(@{ a = 1 }) `
            -EntraDeviceId $script:DeviceId | ConvertTo-Json -Depth 24 -Compress

        $json | Should -Match '"records":\s*\['
    }
}

Context 'Get-RetryDelaySeconds' {

    It 'grows exponentially with the attempt number' {
        (Get-RetryDelaySeconds -Attempt 1 -BaseDelaySeconds 4 -MaxDelaySeconds 600 -JitterFactor 1.0) | Should -Be 4
        (Get-RetryDelaySeconds -Attempt 2 -BaseDelaySeconds 4 -MaxDelaySeconds 600 -JitterFactor 1.0) | Should -Be 8
        (Get-RetryDelaySeconds -Attempt 3 -BaseDelaySeconds 4 -MaxDelaySeconds 600 -JitterFactor 1.0) | Should -Be 16
    }

    It 'never exceeds the ceiling' {
        (Get-RetryDelaySeconds -Attempt 20 -BaseDelaySeconds 5 -MaxDelaySeconds 300 -JitterFactor 1.0) | Should -Be 300
    }

    It 'applies full jitter so retries are de-correlated across the fleet' {
        (Get-RetryDelaySeconds -Attempt 4 -BaseDelaySeconds 4 -MaxDelaySeconds 600 -JitterFactor 0.5) | Should -Be 16
        (Get-RetryDelaySeconds -Attempt 4 -BaseDelaySeconds 4 -MaxDelaySeconds 600 -JitterFactor 1.0) | Should -Be 32
    }

    It 'never returns less than one second' {
        (Get-RetryDelaySeconds -Attempt 1 -BaseDelaySeconds 5 -MaxDelaySeconds 300 -JitterFactor 0.0) | Should -Be 1
    }

    It 'honours a server-supplied Retry-After over the backoff curve' {
        (Get-RetryDelaySeconds -Attempt 8 -BaseDelaySeconds 5 -MaxDelaySeconds 300 -RetryAfterSeconds 12) | Should -Be 12
    }

    It 'clamps a Retry-After that exceeds the ceiling' {
        (Get-RetryDelaySeconds -Attempt 1 -MaxDelaySeconds 60 -RetryAfterSeconds 6000) | Should -Be 60
    }

    It 'treats a negative Retry-After as no wait' {
        (Get-RetryDelaySeconds -Attempt 1 -RetryAfterSeconds -30) | Should -Be 0
    }

    It 'produces varying delays without an explicit jitter factor' {
        $samples = 1..40 | ForEach-Object {
            Get-RetryDelaySeconds -Attempt 6 -BaseDelaySeconds 5 -MaxDelaySeconds 600
        }

        (@($samples | Sort-Object -Unique).Count) | Should -BeGreaterThan 1
    }
}

Context 'Get-SubmissionDisposition' {

    It 'treats 2xx as delivered' {
        Get-SubmissionDisposition -StatusCode 200 | Should -BeExactly 'Delivered'
        Get-SubmissionDisposition -StatusCode 202 | Should -BeExactly 'Delivered'
    }

    It 'treats throttling and server errors as transient' {
        Get-SubmissionDisposition -StatusCode 408 | Should -BeExactly 'Transient'
        Get-SubmissionDisposition -StatusCode 429 | Should -BeExactly 'Transient'
        Get-SubmissionDisposition -StatusCode 500 | Should -BeExactly 'Transient'
        Get-SubmissionDisposition -StatusCode 503 | Should -BeExactly 'Transient'
    }

    It 'treats certificate and binding rejections as auth failures' {
        # Kept (not quarantined): certificate renewal or re-enrolment can repair these.
        Get-SubmissionDisposition -StatusCode 401 | Should -BeExactly 'AuthFailure'
        Get-SubmissionDisposition -StatusCode 403 | Should -BeExactly 'AuthFailure'
    }

    It 'treats malformed and duplicate submissions as permanent' {
        Get-SubmissionDisposition -StatusCode 400 | Should -BeExactly 'Permanent'
        Get-SubmissionDisposition -StatusCode 409 | Should -BeExactly 'Permanent'
        Get-SubmissionDisposition -StatusCode 413 | Should -BeExactly 'Permanent'
    }
}

Context 'Send-InventoryEnvelope' {

    BeforeAll {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
            (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName('CN=pester-device')),
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:Certificate = $request.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
    }

    It 'enables Expect 100-continue without changing signed body bytes' {
        Mock -ModuleName InventoryClient Invoke-WebRequest {
            param($Uri, $Headers, $Body)
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $Headers['Expect'] | Should -BeExactly '100-continue'
            }
            else {
                [Net.ServicePointManager]::FindServicePoint($Uri).Expect100Continue | Should -BeTrue
            }
            [Text.Encoding]::UTF8.GetString($Body) | Should -BeExactly '{"probe":true}'
            [pscustomobject]@{ StatusCode = 202 }
        }
        $result = Send-InventoryEnvelope -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{"probe":true}' -Certificate $script:Certificate -NoSleep
        $result.Disposition | Should -BeExactly 'Delivered'
        Should -Invoke -ModuleName InventoryClient Invoke-WebRequest -Times 1 -Exactly
    }

    It 'reports Delivered and stops after a single successful attempt' {
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            [pscustomobject]@{ StatusCode = 202; RetryAfterSeconds = $null; Disposition = 'Delivered'; Message = 'ok' }
        }

        $result = Send-InventoryEnvelope -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate -NoSleep

        $result.Disposition | Should -BeExactly 'Delivered'
        $result.Attempts | Should -Be 1
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 1 -Exactly
    }

    It 'retries a transient failure up to the attempt ceiling' {
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            [pscustomobject]@{ StatusCode = 503; RetryAfterSeconds = $null; Disposition = 'Transient'; Message = 'busy' }
        }

        $result = Send-InventoryEnvelope -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate -MaxAttempts 3 -NoSleep

        $result.Disposition | Should -BeExactly 'Transient'
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 3 -Exactly
    }

    It 'does not retry a permanent rejection' {
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            [pscustomobject]@{ StatusCode = 400; RetryAfterSeconds = $null; Disposition = 'Permanent'; Message = 'bad' }
        }

        $result = Send-InventoryEnvelope -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate -MaxAttempts 5 -NoSleep

        $result.Disposition | Should -BeExactly 'Permanent'
        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 1 -Exactly
    }

    It 'does not retry an auth failure' {
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            [pscustomobject]@{ StatusCode = 401; RetryAfterSeconds = $null; Disposition = 'AuthFailure'; Message = 'denied' }
        }

        $null = Send-InventoryEnvelope -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate -MaxAttempts 5 -NoSleep

        Should -Invoke -ModuleName InventoryClient Invoke-InventoryHttpPost -Times 1 -Exactly
    }

    It 'succeeds when a later attempt recovers' {
        $script:Calls = 0
        Mock -ModuleName InventoryClient Invoke-InventoryHttpPost {
            $script:Calls++
            if ($script:Calls -lt 3) {
                [pscustomobject]@{ StatusCode = 503; RetryAfterSeconds = $null; Disposition = 'Transient'; Message = 'busy' }
            }
            else {
                [pscustomobject]@{ StatusCode = 202; RetryAfterSeconds = $null; Disposition = 'Delivered'; Message = 'ok' }
            }
        }

        $result = Send-InventoryEnvelope -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Body '{}' -Certificate $script:Certificate -MaxAttempts 5 -NoSleep

        $result.Disposition | Should -BeExactly 'Delivered'
        $result.Attempts | Should -Be 3
    }
}

Context 'Invoke-InventorySpoolDrain' {

    BeforeAll {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
            (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName('CN=pester-device')),
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:Certificate = $request.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
    }

    BeforeEach {
        $script:SpoolRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("logcollector-drain-" + [guid]::NewGuid().ToString('N'))
        $null = Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot

        1..3 | ForEach-Object {
            $null = Save-SpoolEntry -Body "{`"n`":$_}" -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
            Start-Sleep -Milliseconds 5
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:SpoolRoot) {
            Remove-Item -LiteralPath $script:SpoolRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'delivers and removes every entry when the service is healthy' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
        }

        $result = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -NoSleep

        $result.Delivered | Should -Be 3
        $result.Remaining | Should -Be 0
        $result.Stopped | Should -BeFalse
    }

    It 'never signs or submits a planted user-writable file, even one due for expiration' {
        $path = @(Get-ChildItem -LiteralPath $script:SpoolRoot -Filter '*.json')[0].FullName
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorBinaryForm((Get-Acl -LiteralPath $path).GetSecurityDescriptorBinaryForm(),
            [Security.AccessControl.AccessControlSections]::Access)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
            [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
        $file = Get-Item -LiteralPath $path
        if ($PSVersionTable.PSVersion.Major -le 5) { $file.SetAccessControl($acl) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl($file, $acl) }
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)
        Mock -ModuleName InventoryClient Send-InventoryEnvelope { throw 'Must not sign planted data' }

        { Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -NoSleep } | Should -Throw '*untrusted write*'
        Should -Invoke -ModuleName InventoryClient Send-InventoryEnvelope -Times 0 -Exactly
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'drains oldest first' {
        $script:Seen = New-Object System.Collections.ArrayList
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            $null = $script:Seen.Add($Body)
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
        }

        $null = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -NoSleep

        $script:Seen[0] | Should -BeExactly '{"n":1}'
        $script:Seen[2] | Should -BeExactly '{"n":3}'
    }

    It 'does not sign an entry that the attempt update could not preserve' {
        Mock -ModuleName InventoryClient Update-SpoolEntryAttempt { -1 }
        Mock -ModuleName InventoryClient Send-InventoryEnvelope { throw 'Must not sign rejected entries' }
        $result = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -NoSleep
        $result.Quarantined | Should -Be 3
        Should -Invoke -ModuleName InventoryClient Send-InventoryEnvelope -Times 0 -Exactly
    }

    It 'stops at the first transient failure and keeps the backlog' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Transient'; StatusCode = 503; Attempts = 2; Message = 'busy' }
        }

        $result = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -NoSleep

        $result.Stopped | Should -BeTrue
        $result.Delivered | Should -Be 0
        $result.Remaining | Should -Be 3
        Should -Invoke -ModuleName InventoryClient Send-InventoryEnvelope -Times 1 -Exactly
    }

    It 'quarantines permanently rejected entries and keeps draining' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Permanent'; StatusCode = 400; Attempts = 1; Message = 'bad' }
        }

        $result = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -NoSleep

        $result.Quarantined | Should -Be 3
        $result.Remaining | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:SpoolRoot 'quarantine') -File).Count | Should -Be 3
    }

    It 'drops entries older than the age quota without attempting delivery' {
        Get-ChildItem -LiteralPath $script:SpoolRoot -Filter '*.json' -File | ForEach-Object {
            $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-30)
        }

        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
        }

        $result = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -MaxSpoolAgeDays 7 -NoSleep

        $result.Remaining | Should -Be 0
        Should -Invoke -ModuleName InventoryClient Send-InventoryEnvelope -Times 0 -Exactly
    }

    It 'quarantines an entry that has exhausted its delivery budget' {
        $entry = (Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)[0]
        1..10 | ForEach-Object { $null = Update-SpoolEntryAttempt -Path $entry.Path }

        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
        }

        $result = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -MaxDeliveryAttempts 10 -NoSleep

        $result.Quarantined | Should -Be 1
        $result.Delivered | Should -Be 2
    }

    It 'skips the drain when another run already holds the lock' {
        $lock = Enter-SpoolLock -SpoolDirectory $script:SpoolRoot
        try {
            Mock -ModuleName InventoryClient Send-InventoryEnvelope {
                [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
            }

            $result = Invoke-InventorySpoolDrain -Uri ([Uri]'https://example.invalid/api/inventory') `
                -Certificate $script:Certificate -SpoolDirectory $script:SpoolRoot -NoSleep

            $result.Stopped | Should -BeTrue
            Should -Invoke -ModuleName InventoryClient Send-InventoryEnvelope -Times 0 -Exactly
        }
        finally {
            Exit-SpoolLock -LockStream $lock
        }
    }
}

Context 'Invoke-InventorySubmission' {

    BeforeAll {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
            (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName('CN=pester-device')),
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:Certificate = $request.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
    }

    BeforeEach {
        $script:SpoolRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("logcollector-submit-" + [guid]::NewGuid().ToString('N'))
        $script:Envelope = New-InventoryEnvelope -TableName 'InventoryWindows_CL' `
            -Records @(@{ RecordType = 'Hardware' }) -EntraDeviceId $script:DeviceId
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:SpoolRoot) {
            Remove-Item -LiteralPath $script:SpoolRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not spool a delivered submission' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
        }

        $result = Invoke-InventorySubmission -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Envelope $script:Envelope -Certificate $script:Certificate `
            -SpoolDirectory $script:SpoolRoot -SkipDrain -NoSleep

        $result.Disposition | Should -BeExactly 'Delivered'
        $result.Spooled | Should -BeFalse
    }

    It 'spools a transient failure for a later run' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Transient'; StatusCode = 503; Attempts = 4; Message = 'busy' }
        }

        $result = Invoke-InventorySubmission -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Envelope $script:Envelope -Certificate $script:Certificate `
            -SpoolDirectory $script:SpoolRoot -SkipDrain -NoSleep

        $result.Spooled | Should -BeTrue
        @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot).Count | Should -Be 1
    }

    It 'spools an auth failure, because re-enrolment can repair it later' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'AuthFailure'; StatusCode = 401; Attempts = 1; Message = 'denied' }
        }

        $result = Invoke-InventorySubmission -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Envelope $script:Envelope -Certificate $script:Certificate `
            -SpoolDirectory $script:SpoolRoot -SkipDrain -NoSleep

        $result.Spooled | Should -BeTrue
    }

    It 'does NOT spool a permanent rejection' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Permanent'; StatusCode = 400; Attempts = 1; Message = 'bad envelope' }
        }

        $result = Invoke-InventorySubmission -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Envelope $script:Envelope -Certificate $script:Certificate `
            -SpoolDirectory $script:SpoolRoot -SkipDrain -NoSleep

        # Replaying a payload the server structurally rejected would fail on every
        # future run and never leave the spool.
        $result.Spooled | Should -BeFalse
        @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot).Count | Should -Be 0
    }

    It 'spools the exact body that was submitted' {
        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Transient'; StatusCode = 503; Attempts = 4; Message = 'busy' }
        }

        $null = Invoke-InventorySubmission -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Envelope $script:Envelope -Certificate $script:Certificate `
            -SpoolDirectory $script:SpoolRoot -SkipDrain -NoSleep

        $spooled = (Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)[0].Body | ConvertFrom-Json
        $spooled.entraDeviceId | Should -BeExactly $script:DeviceId
        $spooled.tableName | Should -BeExactly 'InventoryWindows_CL'
    }

    It 'drains the backlog before submitting the current sample' {
        $null = Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot
        $null = Save-SpoolEntry -Body '{"old":true}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

        Mock -ModuleName InventoryClient Send-InventoryEnvelope {
            [pscustomobject]@{ Disposition = 'Delivered'; StatusCode = 202; Attempts = 1; Message = 'ok' }
        }

        $result = Invoke-InventorySubmission -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Envelope $script:Envelope -Certificate $script:Certificate `
            -SpoolDirectory $script:SpoolRoot -NoSleep

        $result.Drain.Delivered | Should -Be 1
        $result.Disposition | Should -BeExactly 'Delivered'
    }

    It 'rejects unsafe spool permissions before signing even when drain is skipped' {
        $null = Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorBinaryForm((Get-Acl -LiteralPath $script:SpoolRoot).GetSecurityDescriptorBinaryForm(),
            [Security.AccessControl.AccessControlSections]::Access)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
            [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
        $directory = Get-Item -LiteralPath $script:SpoolRoot
        if ($PSVersionTable.PSVersion.Major -le 5) { $directory.SetAccessControl($acl) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl) }
        Mock -ModuleName InventoryClient Send-InventoryEnvelope { throw 'Must not sign with an unsafe spool' }
        { Invoke-InventorySubmission -Uri ([Uri]'https://example.invalid/api/inventory') `
            -Envelope $script:Envelope -Certificate $script:Certificate `
            -SpoolDirectory $script:SpoolRoot -SkipDrain -NoSleep } | Should -Throw '*untrusted write*'
        Should -Invoke -ModuleName InventoryClient Send-InventoryEnvelope -Times 0 -Exactly
    }
}
}
