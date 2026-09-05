<#
.SYNOPSIS
    Pester tests for Invoke-CustomInventory.ps1.

.DESCRIPTION
    Focuses on the behaviour that regressed or was newly added:

      * Disk, Volume and BitLocker collection exist and are on by default.
      * BitLocker reports protector TYPES only - no recovery key material can
        reach the envelope.
      * An optional area that fails produces a warning and an explicit
        CollectionStatus record, never a success-shaped record full of defaults.
      * TPM "absent" and TPM "unavailable" are distinguishable.
      * The collector build version is stamped on every submission.

    Platform commands that may or may not exist on the build running the tests
    (Get-Disk, Get-BitLockerVolume, Confirm-SecureBootUEFI, ...) are installed as
    global stubs, so the suite behaves identically on a server core image, a
    Windows Home image, and a developer workstation.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:CollectorPath = Join-Path $repoRoot 'scripts\Invoke-CustomInventory.ps1'

    Import-Module (Join-Path $repoRoot 'src\Client\DeviceIdentity.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'src\Client\InventorySpool.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'src\Client\InventoryClient.psm1') -Force -DisableNameChecking

    $script:DeviceId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
    $script:FrontendUrl = 'https://host.example/api/inventory'
    $script:StubbedCommands = @('Get-Disk', 'Get-PhysicalDisk', 'Get-Volume', 'Get-BitLockerVolume', 'Confirm-SecureBootUEFI')

    # A plausible-looking recovery password. If this string ever reaches the
    # envelope, the collector is exfiltrating key material.
    $global:LcFakeRecoveryPassword = '111111-222222-333333-444444-555555-666666-777777-888888'

    function Install-PlatformStub {
        <#
        .SYNOPSIS
            Defines a global function that shadows a platform cmdlet, so the tests
            do not depend on which optional Windows features are installed.
        #>
        param(
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [scriptblock] $Body
        )
        Set-Item -Path ("function:global:{0}" -f $Name) -Value $Body
    }

    function Reset-PlatformStubs {
        <#
        .SYNOPSIS
            Restores the default healthy platform used by most tests.
        #>
        $global:LcTpmMode = 'Present'
        $global:LcBitLockerMode = 'Module'

        Install-PlatformStub -Name 'Get-Disk' -Body {
            [pscustomobject]@{
                Number = 0; FriendlyName = 'NVMe SSD 512G'; SerialNumber = 'SN-0001'
                BusType = 'NVMe'; Size = 512110190592; HealthStatus = 'Healthy'
                OperationalStatus = 'Online'; FirmwareVersion = '1.2.3'
                PartitionStyle = 'GPT'; IsBoot = $true
            }
        }

        Install-PlatformStub -Name 'Get-PhysicalDisk' -Body {
            [pscustomobject]@{ DeviceId = '0'; MediaType = 'SSD' }
        }

        Install-PlatformStub -Name 'Get-Volume' -Body {
            [pscustomobject]@{
                DriveLetter = 'C'; FileSystemLabel = 'OS'; FileSystem = 'NTFS'
                Size = 511000000000; SizeRemaining = 250000000000
                DriveType = 'Fixed'; HealthStatus = 'Healthy'
            }
        }

        Install-PlatformStub -Name 'Get-BitLockerVolume' -Body {
            if ($global:LcBitLockerMode -eq 'Throw') { throw 'BitLocker WMI provider is unavailable.' }

            [pscustomobject]@{
                MountPoint = 'C:'; VolumeType = 'OperatingSystem'
                ProtectionStatus = 'On'; VolumeStatus = 'FullyEncrypted'
                EncryptionPercentage = 100; EncryptionMethod = 'XtsAes256'
                AutoUnlockEnabled = $false
                KeyProtector = @(
                    # Deliberately carries a recovery password, exactly as the real
                    # cmdlet does. The collector must read KeyProtectorType only.
                    [pscustomobject]@{ KeyProtectorType = 'Tpm'; RecoveryPassword = '' }
                    [pscustomobject]@{ KeyProtectorType = 'RecoveryPassword'; RecoveryPassword = $global:LcFakeRecoveryPassword }
                )
            }
        }

        Install-PlatformStub -Name 'Confirm-SecureBootUEFI' -Body { $true }
    }

    function Remove-PlatformStubs {
        foreach ($name in $script:StubbedCommands) {
            Remove-Item -Path ("function:global:{0}" -f $name) -Force -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name LcTpmMode, LcBitLockerMode -Scope Global -ErrorAction SilentlyContinue
    }

    function Get-RecordsOfType {
        param($Envelope, [string] $RecordType)

        # Returns a plain array. Every call site wraps the result in @() because
        # Windows PowerShell 5.1 unrolls a single-element result to a scalar, and a
        # scalar PSCustomObject has no .Count. A ",@()" return would fix .Count but
        # break piping, because the wrapped array arrives at Where-Object as one
        # item and member enumeration then matches every record.
        return @($Envelope.records | Where-Object { $_.RecordType -eq $RecordType })
    }
}

AfterAll {
    Remove-Variable -Name LcFakeRecoveryPassword -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-CustomInventory' {

    BeforeEach {
        Reset-PlatformStubs

        # The dry run still resolves identity and certificate, so both are mocked.
        Mock Get-DeviceIdentitySnapshot {
            [pscustomobject]@{
                EntraDeviceId  = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
                DeviceName     = 'WKS-TEST'
                IntuneDeviceId = 'intune-test-id'
            }
        }

        Mock Get-ClientCertificate { [pscustomobject]@{ Thumbprint = 'AABBCC'; Subject = 'CN=test' } }

        Mock Get-CimInstance {
            switch -Regex ($ClassName) {
                'Win32_OperatingSystem' {
                    return [pscustomobject]@{
                        Caption = 'Microsoft Windows 11 Enterprise'; Version = '10.0.26100'
                        BuildNumber = '26100'; OSArchitecture = '64-bit'
                        InstallDate = (Get-Date '2025-01-01'); LastBootUpTime = (Get-Date '2026-09-01')
                        Locale = '0409'
                    }
                }
                'Win32_ComputerSystem' {
                    return [pscustomobject]@{
                        Manufacturer = 'Contoso'; Model = 'Book 5'
                        TotalPhysicalMemory = 34359738368; NumberOfLogicalProcessors = 12
                        PCSystemType = 2
                    }
                }
                'Win32_BIOS' { return [pscustomobject]@{ SerialNumber = 'BIOS-123'; SMBIOSBIOSVersion = '1.0.0' } }
                'Win32_Processor' { return [pscustomobject]@{ Name = 'Contoso Core i7' } }
                'Win32_NetworkAdapterConfiguration' {
                    return [pscustomobject]@{
                        Description = 'Contoso NIC'; MACAddress = '00-11-22-33-44-55'
                        IPAddress = @('10.0.0.5'); DHCPEnabled = $true; DNSDomain = 'contoso.example'
                    }
                }
                'Win32_Tpm' {
                    if ($global:LcTpmMode -eq 'Unavailable') { throw 'Access denied to the TPM namespace.' }
                    if ($global:LcTpmMode -eq 'Absent') { return @() }
                    return [pscustomobject]@{ IsEnabled_InitialValue = $true; SpecVersion = '2.0, 0, 1.38' }
                }
                default { return @() }
            }
        }
    }

    AfterEach {
        Remove-PlatformStubs
    }

    Context 'collection areas' {

        It 'accepts Disk and BitLocker as collection areas' {
            $validate = (Get-Command $script:CollectorPath).Parameters['Collect'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

            $validate.ValidValues | Should -Contain 'Disk'
            $validate.ValidValues | Should -Contain 'BitLocker'
        }

        It 'collects Disk and BitLocker by default' {
            # The original inventory carried disks and BitLocker; the defaults must
            # not quietly drop them again.
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -WhatIfSubmission | ConvertFrom-Json

            @(Get-RecordsOfType $envelope 'Disk').Count | Should -BeGreaterThan 0
            @(Get-RecordsOfType $envelope 'Volume').Count | Should -BeGreaterThan 0
            @(Get-RecordsOfType $envelope 'BitLocker').Count | Should -BeGreaterThan 0
            $envelope.properties.CollectedAreas | Should -BeLike '*Disk*'
            $envelope.properties.CollectedAreas | Should -BeLike '*BitLocker*'
        }

        It 'emits Disk and Volume records for the Disk area' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk -WhatIfSubmission | ConvertFrom-Json

            $disks = @(Get-RecordsOfType $envelope 'Disk')
            $disks.Count | Should -Be 1
            $disks[0].DiskNumber | Should -Be 0
            $disks[0].DiskFriendlyName | Should -BeExactly 'NVMe SSD 512G'
            $disks[0].DiskMediaType | Should -BeExactly 'SSD'
            $disks[0].DiskBusType | Should -BeExactly 'NVMe'
            $disks[0].DiskSizeBytes | Should -Be 512110190592
            $disks[0].DiskHealthStatus | Should -BeExactly 'Healthy'
            $disks[0].DiskDataSource | Should -BeExactly 'StorageModule'

            $volumes = @(Get-RecordsOfType $envelope 'Volume')
            $volumes.Count | Should -Be 1
            $volumes[0].VolumeMountPoint | Should -BeExactly 'C:'
            $volumes[0].VolumeFileSystem | Should -BeExactly 'NTFS'
            $volumes[0].VolumeFreeBytes | Should -Be 250000000000
        }

        It 'emits BitLocker records with protector types' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect BitLocker -WhatIfSubmission | ConvertFrom-Json

            $bitlocker = @(Get-RecordsOfType $envelope 'BitLocker')
            $bitlocker.Count | Should -Be 1
            $bitlocker[0].BitLockerMountPoint | Should -BeExactly 'C:'
            $bitlocker[0].BitLockerProtectionStatus | Should -BeExactly 'On'
            $bitlocker[0].BitLockerVolumeStatus | Should -BeExactly 'FullyEncrypted'
            $bitlocker[0].BitLockerEncryptionPercentage | Should -Be 100
            $bitlocker[0].BitLockerKeyProtectorTypes | Should -BeExactly 'RecoveryPassword,Tpm'
            $bitlocker[0].BitLockerDataSource | Should -BeExactly 'BitLockerModule'
        }

        It 'restricts collection to the requested areas' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk -WhatIfSubmission | ConvertFrom-Json

            @(Get-RecordsOfType $envelope 'Software').Count | Should -Be 0
            @(Get-RecordsOfType $envelope 'Network').Count | Should -Be 0
            @(Get-RecordsOfType $envelope 'Hardware').Count | Should -Be 0
        }

        It 'still collects the original areas' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl `
                -Collect Hardware, OperatingSystem, Network, Security -WhatIfSubmission | ConvertFrom-Json

            @(Get-RecordsOfType $envelope 'Hardware').Count | Should -Be 1
            @(Get-RecordsOfType $envelope 'OperatingSystem').Count | Should -Be 1
            @(Get-RecordsOfType $envelope 'Network').Count | Should -Be 1
            @(Get-RecordsOfType $envelope 'Security').Count | Should -Be 1
        }
    }

    Context 'BitLocker key material' {

        It 'never emits a recovery password' {
            $json = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect BitLocker -WhatIfSubmission

            # The stub deliberately exposes a recovery password on the key protector.
            $json | Should -Not -Match ([regex]::Escape($global:LcFakeRecoveryPassword))
            $json | Should -Not -Match '\d{6}-\d{6}-\d{6}-\d{6}-\d{6}-\d{6}-\d{6}-\d{6}'
        }

        It 'emits no property whose name suggests key material' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect BitLocker -WhatIfSubmission | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'BitLocker')[0]

            $names = @($record.PSObject.Properties.Name)
            $names | Should -Not -Contain 'RecoveryPassword'
            $names | Should -Not -Contain 'KeyProtector'
            $names | Should -Not -Contain 'BitLockerRecoveryPassword'

            # The protector TYPE name is expected and is not key material.
            $record.BitLockerKeyProtectorTypes | Should -BeLike '*RecoveryPassword*'
        }
    }

    Context 'collection diagnostics' {

        It 'emits a CollectionStatus record for every requested area' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl `
                -Collect Disk, BitLocker, Security -WhatIfSubmission | ConvertFrom-Json

            $status = @(Get-RecordsOfType $envelope 'CollectionStatus')
            @($status | ForEach-Object { $_.SectionName }) | Should -Contain 'Disk'
            @($status | ForEach-Object { $_.SectionName }) | Should -Contain 'BitLocker'
            @($status | ForEach-Object { $_.SectionName }) | Should -Contain 'Security'
            @($status | Where-Object { $_.SectionStatus -ne 'Collected' }).Count | Should -Be 0
        }

        It 'reports a failed area as Failed with a message instead of empty defaults' {
            $global:LcBitLockerMode = 'Throw'

            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl `
                -Collect BitLocker -WhatIfSubmission -WarningAction SilentlyContinue | ConvertFrom-Json

            # No success-shaped record: a BitLocker row full of blanks would read as
            # "this device is unencrypted", which is a false and dangerous conclusion.
            @(Get-RecordsOfType $envelope 'BitLocker').Count | Should -Be 0

            $status = @(Get-RecordsOfType $envelope 'CollectionStatus' | Where-Object { $_.SectionName -eq 'BitLocker' })
            $status.Count | Should -Be 1
            $status[0].SectionStatus | Should -BeExactly 'Failed'
            $status[0].SectionMessage | Should -BeLike '*BitLocker WMI provider is unavailable*'
        }

        It 'writes a warning when an area fails' {
            $global:LcBitLockerMode = 'Throw'

            $warnings = $null
            $null = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect BitLocker -WhatIfSubmission `
                -WarningVariable warnings -WarningAction SilentlyContinue

            @($warnings) -join "`n" | Should -BeLike "*Collection section 'BitLocker' failed*"
        }

        It 'keeps other areas collecting when one fails' {
            $global:LcBitLockerMode = 'Throw'

            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl `
                -Collect BitLocker, Disk -WhatIfSubmission -WarningAction SilentlyContinue | ConvertFrom-Json

            @(Get-RecordsOfType $envelope 'Disk').Count | Should -Be 1
            @(Get-RecordsOfType $envelope 'CollectionStatus' |
                Where-Object { $_.SectionName -eq 'Disk' }).SectionStatus | Should -BeExactly 'Collected'
        }

        It 'reports an area that returned nothing as Empty rather than Collected' {
            Install-PlatformStub -Name 'Get-Disk' -Body { @() }
            Install-PlatformStub -Name 'Get-Volume' -Body { @() }

            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk -WhatIfSubmission | ConvertFrom-Json

            @(Get-RecordsOfType $envelope 'CollectionStatus' |
                Where-Object { $_.SectionName -eq 'Disk' }).SectionStatus | Should -BeExactly 'Empty'
        }
    }

    Context 'TPM and Secure Boot state' {

        It 'reports a present TPM' {
            $global:LcTpmMode = 'Present'

            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Security -WhatIfSubmission | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'Security')[0]

            $record.TpmQueryStatus | Should -BeExactly 'Present'
            $record.TpmPresent | Should -BeTrue
            $record.TpmEnabled | Should -BeTrue
            $record.TpmSpecVersion | Should -BeLike '2.0*'
        }

        It 'reports an absent TPM as Absent with TpmPresent false' {
            $global:LcTpmMode = 'Absent'

            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Security -WhatIfSubmission | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'Security')[0]

            $record.TpmQueryStatus | Should -BeExactly 'Absent'
            $record.TpmPresent | Should -BeFalse
        }

        It 'reports an unreachable TPM as Unavailable with TpmPresent null, not false' {
            $global:LcTpmMode = 'Unavailable'

            $warnings = $null
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Security -WhatIfSubmission `
                -WarningVariable warnings -WarningAction SilentlyContinue | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'Security')[0]

            # This is the whole point: "we could not ask" must never be recorded as
            # "there is no TPM".
            $record.TpmQueryStatus | Should -BeExactly 'Unavailable'
            $record.TpmPresent | Should -BeNullOrEmpty
            $record.TpmEnabled | Should -BeNullOrEmpty
            $record.TpmMessage | Should -BeLike '*Access denied*'
            @($warnings) -join "`n" | Should -BeLike '*TPM state could not be determined*'
        }

        It 'distinguishes Absent from Unavailable' {
            $global:LcTpmMode = 'Absent'
            $absent = @(Get-RecordsOfType (& $script:CollectorPath -FrontendUrl $script:FrontendUrl `
                -Collect Security -WhatIfSubmission | ConvertFrom-Json) 'Security')[0]

            $global:LcTpmMode = 'Unavailable'
            $unavailable = @(Get-RecordsOfType (& $script:CollectorPath -FrontendUrl $script:FrontendUrl `
                -Collect Security -WhatIfSubmission -WarningAction SilentlyContinue | ConvertFrom-Json) 'Security')[0]

            $absent.TpmQueryStatus | Should -Not -Be $unavailable.TpmQueryStatus
            $absent.TpmPresent | Should -Not -BeNullOrEmpty
            $unavailable.TpmPresent | Should -BeNullOrEmpty
        }

        It 'reports Secure Boot as Enabled when the platform confirms it' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Security -WhatIfSubmission | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'Security')[0]

            $record.SecureBootStatus | Should -BeExactly 'Enabled'
            $record.SecureBootEnabled | Should -BeTrue
        }

        It 'reports Secure Boot as Disabled when the platform denies it' {
            Install-PlatformStub -Name 'Confirm-SecureBootUEFI' -Body { $false }

            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Security -WhatIfSubmission | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'Security')[0]

            $record.SecureBootStatus | Should -BeExactly 'Disabled'
            $record.SecureBootEnabled | Should -BeFalse
        }

        It 'reports Secure Boot as NotSupported on legacy BIOS rather than Disabled' {
            Install-PlatformStub -Name 'Confirm-SecureBootUEFI' -Body {
                throw (New-Object System.PlatformNotSupportedException 'Cmdlet not supported on this platform.')
            }

            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Security -WhatIfSubmission | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'Security')[0]

            # "Disabled" would imply a device that could be secured but is not.
            $record.SecureBootStatus | Should -BeExactly 'NotSupported'
            $record.SecureBootEnabled | Should -BeNullOrEmpty
        }

        It 'reports Secure Boot as Unavailable when the query fails for another reason' {
            Install-PlatformStub -Name 'Confirm-SecureBootUEFI' -Body { throw 'Access was denied.' }

            $warnings = $null
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Security -WhatIfSubmission `
                -WarningVariable warnings -WarningAction SilentlyContinue | ConvertFrom-Json
            $record = @(Get-RecordsOfType $envelope 'Security')[0]

            $record.SecureBootStatus | Should -BeExactly 'Unavailable'
            $record.SecureBootEnabled | Should -BeNullOrEmpty
            @($warnings) -join "`n" | Should -BeLike '*Secure Boot state could not be determined*'
        }
    }

    Context 'envelope' {

        It 'stamps collector version 1.0.3' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk -WhatIfSubmission | ConvertFrom-Json

            $envelope.properties.CollectorVersion | Should -BeExactly '1.0.3'
        }

        It 'accepts a validated CSV list from the native scheduled-task command line' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -CollectCsv 'Disk,BitLocker' -WhatIfSubmission | ConvertFrom-Json
            $envelope.properties.CollectedAreas | Should -BeExactly 'Disk,BitLocker'
            @(Get-RecordsOfType $envelope 'Hardware').Count | Should -Be 0
        }

        It 'rejects unknown or ambiguous CSV collection arguments' {
            { & $script:CollectorPath -FrontendUrl $script:FrontendUrl -CollectCsv 'Disk,Unknown' -WhatIfSubmission } | Should -Throw '*unsupported*'
            { & $script:CollectorPath -FrontendUrl $script:FrontendUrl -CollectCsv 'Disk' -Collect Disk -WhatIfSubmission } | Should -Throw '*not both*'
        }
        It 'records the requested areas' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk, BitLocker -WhatIfSubmission | ConvertFrom-Json

            $envelope.properties.CollectedAreas | Should -BeExactly 'Disk,BitLocker'
        }

        It 'carries the resolved device identity' {
            $envelope = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk -WhatIfSubmission | ConvertFrom-Json

            $envelope.entraDeviceId | Should -BeExactly $script:DeviceId
            $envelope.deviceName | Should -BeExactly 'WKS-TEST'
            $envelope.envelopeVersion | Should -BeExactly 'LOGCOLLECTOR-INVENTORY-V1'
        }

        It 'does not submit anything in dry-run mode' {
            Mock Invoke-InventorySubmission { throw 'the dry run must not submit' }

            $null = & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk -WhatIfSubmission

            Should -Invoke Invoke-InventorySubmission -Times 0 -Exactly
        }

        It 'refuses a non-HTTPS endpoint' {
            { & $script:CollectorPath -FrontendUrl 'http://host.example/api/inventory' -WhatIfSubmission } |
                Should -Throw '*must use https*'
        }

        It 'refuses a spool path that is not on a local fixed drive, before collecting anything' {
            { & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk `
                -SpoolDirectory '\\server\share\spool' -WhatIfSubmission } |
                Should -Throw '*local fixed drive*'

            { & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk `
                -SpoolDirectory 'relative\spool' -WhatIfSubmission } |
                Should -Throw '*absolute path*'
        }

        It 'accepts the default local spool path' {
            { & $script:CollectorPath -FrontendUrl $script:FrontendUrl -Collect Disk -WhatIfSubmission } |
                Should -Not -Throw
        }
    }
}
