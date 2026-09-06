BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:ModulePath = Join-Path $script:Repo 'src\InventoryPackage\Inventory.Collection.psm1'
    $script:Identity = [pscustomobject]@{
        EntraDeviceId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
        DeviceName = 'IDENTITY-NAME'
        IntuneDeviceId = 'identity-enrollment-id'
    }

    function Install-InventoryPlatformStub {
        param([Parameter(Mandatory)] [string] $Name)
        if ($null -eq (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$Name" -Value { throw 'Unexpected platform command invocation.' }
            $script:InstalledStubs += $Name
        }
    }

    $script:InstalledStubs = @()
    foreach ($name in @('Get-Tpm', 'Get-TpmEndorsementKeyInfo',
            'Get-NetAdapter', 'Get-NetIPConfiguration', 'Get-PhysicalDisk',
            'Get-StorageReliabilityCounter')) {
        Install-InventoryPlatformStub -Name $name
    }

    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Inventory.Collection -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:InstalledStubs) {
        Remove-Item -Path "function:global:$Name" -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Inventory.Collection module surface' {
    It 'exports exactly Get-Inventory' {
        @(Get-Command -Module Inventory.Collection).Name | Should -Be @('Get-Inventory')
    }

    It 'does not collect anything during import' {
        $runspace = [powershell]::Create()
        try {
            $escapedPath = $script:ModulePath.Replace("'", "''")
            $null = $runspace.AddScript(@"
`$script:CimCalls = 0
function Get-CimInstance {
    `$script:CimCalls++
    throw 'Import must not collect.'
}
Import-Module '$escapedPath' -Force -ErrorAction Stop
`$script:CimCalls
"@)
            $output = @($runspace.Invoke())
            $runspace.HadErrors | Should -BeFalse
            $output | Should -Be @(0)
        }
        finally {
            $runspace.Dispose()
        }
    }

    It 'returns typed empty arrays without touching providers when both areas are disabled' {
        Mock -ModuleName Inventory.Collection Get-InventoryRequiredCimInstance { throw 'must not run' }
        $result = Get-Inventory -Identity $script:Identity `
            -CollectDeviceInventory $false -CollectAppInventory $false

        $result.DeviceRecords.GetType().FullName | Should -BeExactly 'System.Object[]'
        $result.AppRecords.GetType().FullName | Should -BeExactly 'System.Object[]'
        $result.DeviceRecords.Count | Should -Be 0
        $result.AppRecords.Count | Should -Be 0
        Should -Invoke -ModuleName Inventory.Collection Get-InventoryRequiredCimInstance -Times 0 -Exactly
    }

    It 'fails explicitly when required computer CIM data is missing' {
        Mock -ModuleName Inventory.Collection Get-CimInstance { @() }
        { Get-Inventory -Identity $script:Identity -CollectAppInventory $false } |
            Should -Throw "*Win32_ComputerSystem*returned no instances*"
    }
}

Describe 'legacy device inventory contract' {
    BeforeEach {
        Mock -ModuleName Inventory.Collection Get-InventoryManagedDeviceInfo {
            [pscustomobject]@{
                ManagedDeviceName = 'REGISTRY-MANAGED-NAME'
                ManagedDeviceID = 'REGISTRY-ENTDMID'
            }
        }
        Mock -ModuleName Inventory.Collection Get-InventorySystemInformation {
            [pscustomobject]@{ SystemSku = 'SKU-WMI'; BaseBoardProduct = 'HP-BOARD' }
        }
        Mock -ModuleName Inventory.Collection Get-InventoryWindowsVersion { '23H2' }
        Mock -ModuleName Inventory.Collection Get-InventoryDefaultUpdateService { 'Windows Update' }
        Mock -ModuleName Inventory.Collection Get-InventoryRegistryValue {
            param($Path, $Name)
            if ($Name -eq 'UBR') { return 3210 }
            if ($Name -eq 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork') { return 0 }
        }
        Mock -ModuleName Inventory.Collection Get-InventoryTpmData {
            [pscustomobject]@{
                TPMReady = 'True'; TPMPresent = 'True'; TPMEnabled = 'True'
                TPMActivated = 'False'; TPMThumbprint = 'TPM-THUMB'
            }
        }
        Mock -ModuleName Inventory.Collection Get-InventoryBitLockerData {
            [pscustomobject]@{
                EncryptionMethod = 'XtsAes256'; VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On'
            }
        }
        Mock -ModuleName Inventory.Collection Get-Command {
            [pscustomobject]@{ Name = $Name }
        } -ParameterFilter { $Name -in @('Get-NetAdapter', 'Get-NetIPConfiguration') }
        Mock -ModuleName Inventory.Collection Get-NetAdapter {
            [pscustomobject]@{
                Status = 'Up'; IfIndex = 7; InterfaceDescription = 'Ethernet'
                InterfaceAlias = 'Ethernet 1'; MacAddress = '00-11-22-33-44-55'
            }
        }
        Mock -ModuleName Inventory.Collection Get-NetIPConfiguration {
            [pscustomobject]@{
                NetProfile = [pscustomobject]@{ Name = 'Lab' }
                IPv4Address = @(
                    [pscustomobject]@{ IPAddress = '10.0.0.10' }
                    [pscustomobject]@{ IPAddress = '10.0.0.11' }
                )
                IPv4DefaultGateway = @(
                    [pscustomobject]@{ NextHop = '10.0.0.1' }
                    [pscustomobject]@{ NextHop = '10.0.0.254' }
                )
            }
        }
        Mock -ModuleName Inventory.Collection Get-InventoryDiskHealth {
            @([pscustomobject]@{
                    'Disk Number' = 0; FriendlyName = 'NVMe'; HealthStatus = 'Healthy'; MediaType = 'SSD'
                    'Disk Wear' = 1; 'Disk 0 Read Errors' = 2; 'Disk 0 Temperature Delta' = -10
                    'Disk 0 ReadErrorsUncorrected' = 0; 'Disk 0 ReadErrorsTotal' = 2
                    'Disk 0 WriteErrorsUncorrected' = 0; 'Disk 0 WriteErrorsTotal' = 3
                })
        }
        Mock -ModuleName Inventory.Collection Get-InventoryRequiredCimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_ComputerSystem' {
                    return [pscustomobject]@{
                        Name = 'CIM-COMPUTER'; UserName = 'CONTOSO\User'
                        Manufacturer = 'Hewlett-Packard'; Model = 'EliteBook'
                        PCSystemType = 2; PCSystemTypeEx = 2; TotalPhysicalMemory = 17179869184
                        SystemSKUNumber = 'SYSTEM-SKU'
                    }
                }
                'Win32_OperatingSystem' {
                    return [pscustomobject]@{
                        LastBootUpTime = (Get-Date).AddDays(-3); InstallDate = (Get-Date '2025-01-02')
                        BuildNumber = 22631; Caption = 'Microsoft Windows 11 Enterprise'
                    }
                }
                'Win32_BIOS' {
                    return [pscustomobject]@{
                        SerialNumber = 'SERIAL'; SMBIOSBIOSVersion = 'R01'
                        ReleaseDate = (Get-Date '2025-02-03')
                        SystemBiosMajorVersion = 1; SystemBiosMinorVersion = 7
                    }
                }
                'Win32_ComputerSystemProduct' {
                    return [pscustomobject]@{ UUID = 'PRODUCT-UUID'; Version = 'Product Version' }
                }
                'Win32_Processor' {
                    return [pscustomobject]@{
                        Name = 'Processor'; Manufacturer = 'CPU Vendor'
                        NumberOfCores = 8; NumberOfLogicalProcessors = 16
                    }
                }
                default { throw "Unexpected CIM class $ClassName" }
            }
        }
    }

    It 'preserves the exact 39 legacy hardware fields and nested records' {
        $record = (Get-Inventory -Identity $script:Identity -CollectAppInventory $false).DeviceRecords[0]
        $expected = @(
            'ManagedDeviceName', 'AzureADDeviceID', 'ManagedDeviceID', 'ComputerName', 'Model',
            'Manufacturer', 'PCSystemType', 'PCSystemTypeEx', 'ComputerUpTime', 'LastBoot',
            'InstallDate', 'WindowsVersion', 'DefaultAUService', 'AUMetered', 'SystemSkuNumber',
            'SerialNumber', 'SMBIOSUUID', 'BiosVersion', 'BiosDate', 'SystemSKU', 'FirmwareType',
            'Memory', 'OSBuild', 'OSRevision', 'OSName', 'CPUManufacturer', 'CPUName', 'CPUCores',
            'CPULogical', 'TPMReady', 'TPMPresent', 'TPMEnabled', 'TPMActived', 'TPMThumbprint',
            'BitlockerCipher', 'BitlockerVolumeStatus', 'BitlockerProtectionStatus',
            'NetworkAdapters', 'DiskHealth'
        )

        @($record.PSObject.Properties.Name) | Should -Be $expected
        @($record.PSObject.Properties.Name).Count | Should -Be 39
        $record.NetworkAdapters[0].PSObject.Properties.Name | Should -Be @(
            'NetInterfaceDescription', 'NetProfileName', 'NetIPv4Adress',
            'NetInterfaceAlias', 'NetIPv4DefaultGateway', 'MacAddress'
        )
        $record.NetworkAdapters[0].NetIPv4Adress | Should -BeExactly '10.0.0.10 10.0.0.11'
        $record.NetworkAdapters[0].NetIPv4DefaultGateway | Should -BeExactly '10.0.0.1 10.0.0.254'
        $record.DiskHealth[0].PSObject.Properties.Name | Should -Contain 'Disk 0 ReadErrorsTotal'
    }

    It 'keeps legacy scalar types and injected identity values' {
        $record = (Get-Inventory -Identity $script:Identity -CollectAppInventory $false).DeviceRecords[0]
        foreach ($name in @($record.PSObject.Properties.Name | Where-Object {
                    $_ -notin @('NetworkAdapters', 'DiskHealth', 'FirmwareType')
                })) {
            $record.$name | Should -BeOfType ([string])
        }
        $record.AzureADDeviceID | Should -BeExactly $script:Identity.EntraDeviceId
        $record.ManagedDeviceID | Should -BeExactly 'REGISTRY-ENTDMID'
        $record.ManagedDeviceName | Should -BeExactly 'REGISTRY-MANAGED-NAME'
        $record.TPMReady | Should -BeExactly 'True'
        $record.TPMActived | Should -BeExactly 'False'
    }

    It 'uses the original HP manufacturer, SKU, and BIOS choices' {
        $record = (Get-Inventory -Identity $script:Identity -CollectAppInventory $false).DeviceRecords[0]
        $record.Manufacturer | Should -BeExactly 'HP'
        $record.Model | Should -BeExactly 'EliteBook'
        $record.SystemSkuNumber | Should -BeExactly 'SYSTEM-SKU'
        $record.SystemSKU | Should -BeExactly 'HP-BOARD'
        $record.BiosVersion | Should -BeExactly '1.7'
    }

    It 'leaves optional values null and emits warnings when providers are unavailable' {
        Mock -ModuleName Inventory.Collection Get-InventoryTpmData {
            Write-Warning 'TPM state is unavailable.'
            [pscustomobject]@{
                TPMReady = $null; TPMPresent = $null; TPMEnabled = $null
                TPMActivated = $null; TPMThumbprint = $null
            }
        }
        Mock -ModuleName Inventory.Collection Get-InventoryBitLockerData {
            Write-Warning 'BitLocker state is unavailable.'
            [pscustomobject]@{ EncryptionMethod = $null; VolumeStatus = $null; ProtectionStatus = $null }
        }
        $warnings = $null
        $record = (Get-Inventory -Identity $script:Identity -CollectAppInventory $false `
                -WarningVariable warnings -WarningAction SilentlyContinue).DeviceRecords[0]

        $record.TPMPresent | Should -BeNullOrEmpty
        $record.BitlockerProtectionStatus | Should -BeNullOrEmpty
        @($warnings) -join "`n" | Should -Match 'TPM state is unavailable'
        @($warnings) -join "`n" | Should -Match 'BitLocker state is unavailable'
    }

    It 'does not expose BitLocker key material' {
        $record = (Get-Inventory -Identity $script:Identity -CollectAppInventory $false).DeviceRecords[0]
        $json = $record | ConvertTo-Json -Depth 10
        $json | Should -Not -Match 'RecoveryPassword|KeyProtector'
    }

    It 'does not substitute the identity IntuneDeviceId when EntDMID is absent' {
        Mock -ModuleName Inventory.Collection Get-InventoryManagedDeviceInfo {
            Write-Warning 'ManagedDeviceID is unavailable because EntDMID is missing from the enrollment registry.'
            [pscustomobject]@{ ManagedDeviceName = 'REGISTRY-MANAGED-NAME'; ManagedDeviceID = $null }
        }
        $warnings = $null
        $record = (Get-Inventory -Identity $script:Identity -CollectAppInventory $false `
                -WarningVariable warnings -WarningAction SilentlyContinue).DeviceRecords[0]

        $record.ManagedDeviceID | Should -BeNullOrEmpty
        $record.AzureADDeviceID | Should -BeExactly $script:Identity.EntraDeviceId
        @($warnings) -join "`n" | Should -Match 'EntDMID is missing'
    }
}

Describe 'legacy application inventory contract' {
    BeforeEach {
        Mock -ModuleName Inventory.Collection Get-InventoryManagedDeviceInfo {
            [pscustomobject]@{
                ManagedDeviceName = 'REGISTRY-MANAGED-NAME'
                ManagedDeviceID = 'REGISTRY-ENTDMID'
            }
        }
        Mock -ModuleName Inventory.Collection Get-InventoryRequiredCimInstance {
            [pscustomobject]@{ Name = 'CIM-COMPUTER'; UserName = 'CONTOSO\User' }
        }
        Mock -ModuleName Inventory.Collection Get-InventoryInteractiveUserSid { 'S-1-5-21-1000' }
        Mock -ModuleName Inventory.Collection Get-InventoryInstalledApplications {
            @(
                [pscustomobject]@{
                    DisplayName = 'Valid Version App'; DisplayVersion = '1.2.0'
                    InstallDate = '20260101'; Publisher = 'Publisher A'; UninstallString = 'remove-a'
                    PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Software\AppAOld'
                }
                [pscustomobject]@{
                    DisplayName = 'Valid Version App'; DisplayVersion = '2.0.0'
                    InstallDate = '20260201'; Publisher = 'Publisher A'; UninstallString = 'remove-a2'
                    PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Software\AppANew'
                }
                [pscustomobject]@{
                    DisplayName = 'Invalid Version App'; DisplayVersion = 'Release-R2'
                    InstallDate = $null; Publisher = 'Publisher B'; UninstallString = $null
                    PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_USERS\S-1-5-21-1000\Software\AppB'
                }
            )
        }
    }

    It 'preserves software identity and all legacy application properties' {
        $records = (Get-Inventory -Identity $script:Identity -CollectDeviceInventory $false).AppRecords
        $expected = @(
            'ComputerName', 'ManagedDeviceName', 'ManagedDeviceID',
            'AppName', 'AppVersion', 'AppInstallDate', 'AppPublisher',
            'AppUninstallString', 'AppUninstallRegPath'
        )

        @($records).Count | Should -Be 2
        @($records[0].PSObject.Properties.Name) | Should -Be $expected
        @($records[0].PSObject.Properties.Name).Count | Should -Be 9
        $records[0].ComputerName | Should -BeExactly 'CIM-COMPUTER'
        $records[0].ManagedDeviceID | Should -BeExactly 'REGISTRY-ENTDMID'
    }

    It 'retains valid and non-version display values without throwing' {
        $records = (Get-Inventory -Identity $script:Identity -CollectDeviceInventory $false).AppRecords
        ($records | Where-Object AppName -eq 'Valid Version App').AppVersion | Should -BeExactly '2.0.0'
        ($records | Where-Object AppName -eq 'Invalid Version App').AppVersion | Should -BeExactly 'Release-R2'
        @($records).Count | Should -Be 2
    }
}

Describe 'application registry views and HKU lifecycle' {
    BeforeEach {
        $global:InventoryExistingHku = $false
        Mock -ModuleName Inventory.Collection Get-PSDrive {
            if ($global:InventoryExistingHku) { [pscustomobject]@{ Name = 'HKU' } }
        }
        Mock -ModuleName Inventory.Collection New-PSDrive { [pscustomobject]@{ Name = 'HKU' } }
        Mock -ModuleName Inventory.Collection Remove-PSDrive {}
        Mock -ModuleName Inventory.Collection Get-ItemProperty {
            param($Path)
            [pscustomobject]@{
                DisplayName = $Path; DisplayVersion = '1.0'; InstallDate = '20260101'
                Publisher = 'Publisher'; UninstallString = 'remove'; PSPath = "Registry::$Path"
            }
        }

    }

    AfterEach {
        Remove-Variable -Name InventoryExistingHku -Scope Global -ErrorAction SilentlyContinue
    }

    It 'queries both machine views and both loaded interactive-user views in a 64-bit host' -Skip:(-not [Environment]::Is64BitProcess) {
        $module = Get-Module Inventory.Collection
        $apps = @(& $module { Get-InventoryInstalledApplications -UserSid 'S-1-5-21-1000' })
        $apps.Count | Should -Be 4
        Should -Invoke -ModuleName Inventory.Collection Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        }
        Should -Invoke -ModuleName Inventory.Collection Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        }
        Should -Invoke -ModuleName Inventory.Collection Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKU:\S-1-5-21-1000\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        }
        Should -Invoke -ModuleName Inventory.Collection Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKU:\S-1-5-21-1000\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        }
    }

    Describe 'managed device enrollment registry identity' {
        BeforeEach {
            Mock -ModuleName Inventory.Collection Get-ChildItem {
                [pscustomobject]@{
                    PSChildName = 'MS DM Server'
                    PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Software\Enrollment\Test'
                }
            }
            Mock -ModuleName Inventory.Collection Get-ItemProperty {
                [pscustomobject]@{
                    EntDeviceName = 'REGISTRY-MANAGED-NAME'
                    EntDMID = 'REGISTRY-ENTDMID'
                }
            }
        }

        It 'returns the original EntDeviceName and EntDMID values' {
            $module = Get-Module Inventory.Collection
            $managed = & $module { Get-InventoryManagedDeviceInfo }

            $managed.ManagedDeviceName | Should -BeExactly 'REGISTRY-MANAGED-NAME'
            $managed.ManagedDeviceID | Should -BeExactly 'REGISTRY-ENTDMID'
        }

        It 'warns and returns null when EntDMID is missing' {
            Mock -ModuleName Inventory.Collection Get-ItemProperty {
                [pscustomobject]@{ EntDeviceName = 'REGISTRY-MANAGED-NAME' }
            }
            $module = Get-Module Inventory.Collection
            $output = @(& $module { Get-InventoryManagedDeviceInfo } 3>&1)
            $managed = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

            $managed.ManagedDeviceID | Should -BeNullOrEmpty
            $warnings -join "`n" | Should -Match 'EntDMID is missing'
        }

        It 'returns null information when every enrollment registry read fails' {
            Mock -ModuleName Inventory.Collection Get-ItemProperty { throw 'registry access denied' }
            $module = Get-Module Inventory.Collection
            $output = @(& $module { Get-InventoryManagedDeviceInfo } 3>&1)
            $managed = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

            $managed.ManagedDeviceName | Should -BeNullOrEmpty
            $managed.ManagedDeviceID | Should -BeNullOrEmpty
            $warnings -join "`n" | Should -Match 'no enrollment registry entry could be read'
        }
    }

    It 'removes only an HKU drive created by the collector' {
        $module = Get-Module Inventory.Collection
        $null = & $module { Get-InventoryInstalledApplications -UserSid 'S-1-5-21-1000' }
        Should -Invoke -ModuleName Inventory.Collection New-PSDrive -Times 1 -Exactly
        Should -Invoke -ModuleName Inventory.Collection Remove-PSDrive -Times 1 -Exactly -ParameterFilter { $Name -eq 'HKU' }

        $global:InventoryExistingHku = $true
        $null = & $module { Get-InventoryInstalledApplications -UserSid 'S-1-5-21-1000' }
        Should -Invoke -ModuleName Inventory.Collection New-PSDrive -Times 1 -Exactly
        Should -Invoke -ModuleName Inventory.Collection Remove-PSDrive -Times 1 -Exactly
    }
}

Describe 'network and BitLocker helper regressions' {
    It 'member-enumerates array properties and space-joins the legacy network strings' {
        Mock -ModuleName Inventory.Collection Get-Command {
            [pscustomobject]@{ Name = $Name }
        } -ParameterFilter { $Name -in @('Get-NetAdapter', 'Get-NetIPConfiguration') }
        Mock -ModuleName Inventory.Collection Get-NetAdapter {
            [pscustomobject]@{
                Status = 'Up'; IfIndex = 9; InterfaceDescription = 'Adapter'
                InterfaceAlias = 'Adapter 9'; MacAddress = 'AA-BB-CC-DD-EE-FF'
            }
        }
        Mock -ModuleName Inventory.Collection Get-NetIPConfiguration {
            [pscustomobject]@{
                NetProfile = [pscustomobject]@{ Name = 'Profile' }
                IPv4Address = @(
                    [pscustomobject]@{ IPAddress = '192.0.2.10' }
                    [pscustomobject]@{ IPAddress = '192.0.2.11' }
                )
                IPv4DefaultGateway = @(
                    [pscustomobject]@{ NextHop = '192.0.2.1' }
                    [pscustomobject]@{ NextHop = '192.0.2.254' }
                )
            }
        }
        $module = Get-Module Inventory.Collection
        $network = @(& $module { Get-InventoryNetworkAdapters })

        $network[0].NetIPv4Adress | Should -BeExactly '192.0.2.10 192.0.2.11'
        $network[0].NetIPv4DefaultGateway | Should -BeExactly '192.0.2.1 192.0.2.254'
        Should -Invoke -ModuleName Inventory.Collection Get-NetIPConfiguration -Times 1 -Exactly `
            -ParameterFilter { $InterfaceIndex -eq 9 }
    }

    It 'collects only BitLocker status methods and maps their enum values' {
        Mock -ModuleName Inventory.Collection Get-CimInstance {
            New-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' `
                -ClassName 'Win32_EncryptableVolume' -ClientOnly -Property @{ DriveLetter = 'C:' }
        } -ParameterFilter {
            $Namespace -eq 'root\cimv2\Security\MicrosoftVolumeEncryption' -and
            $ClassName -eq 'Win32_EncryptableVolume'
        }
        Mock -ModuleName Inventory.Collection Invoke-CimMethod {
            switch ($MethodName) {
                'GetEncryptionMethod' { [pscustomobject]@{ ReturnValue = 0; EncryptionMethod = 7 } }
                'GetConversionStatus' { [pscustomobject]@{ ReturnValue = 0; ConversionStatus = 1 } }
                'GetProtectionStatus' { [pscustomobject]@{ ReturnValue = 0; ProtectionStatus = 1 } }
                default { throw "Unexpected BitLocker method $MethodName" }
            }
        }
        $module = Get-Module Inventory.Collection
        $status = & $module { Get-InventoryBitLockerData }

        $status.EncryptionMethod | Should -BeExactly 'XtsAes256'
        $status.VolumeStatus | Should -BeExactly 'FullyEncrypted'
        $status.ProtectionStatus | Should -BeExactly 'On'
        Should -Invoke -ModuleName Inventory.Collection Invoke-CimMethod -Times 3 -Exactly
        Should -Invoke -ModuleName Inventory.Collection Invoke-CimMethod -Times 0 -Exactly `
            -ParameterFilter { $MethodName -match 'KeyProtector|NumericalPassword' }
    }

    It 'warns and leaves a BitLocker field null when a status method returns failure' {
        Mock -ModuleName Inventory.Collection Get-CimInstance {
            New-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' `
                -ClassName 'Win32_EncryptableVolume' -ClientOnly -Property @{ DriveLetter = 'C:' }
        }
        Mock -ModuleName Inventory.Collection Invoke-CimMethod {
            switch ($MethodName) {
                'GetEncryptionMethod' { [pscustomobject]@{ ReturnValue = 5; EncryptionMethod = 7 } }
                'GetConversionStatus' { [pscustomobject]@{ ReturnValue = 0; ConversionStatus = 2 } }
                'GetProtectionStatus' { [pscustomobject]@{ ReturnValue = 0; ProtectionStatus = 0 } }
            }
        }
        $module = Get-Module Inventory.Collection
        $output = @(& $module { Get-InventoryBitLockerData } 3>&1)
        $status = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

        $status.EncryptionMethod | Should -BeNullOrEmpty
        $status.VolumeStatus | Should -BeExactly 'EncryptionInProgress'
        $status.ProtectionStatus | Should -BeExactly 'Off'
        $warnings -join "`n" | Should -Match 'GetEncryptionMethod returned failure code'
    }

    It 'preserves the native Get-BitLockerVolume enum strings used by legacy queries' {
        $module = Get-Module Inventory.Collection
        $names = @('None', 'Aes128Diffuser', 'Aes256Diffuser', 'Aes128', 'Aes256', 'Hardware', 'XtsAes128', 'XtsAes256')
        for ($value = 0; $value -lt $names.Count; $value++) {
            (& $module { param($Number) ConvertFrom-InventoryBitLockerEncryptionMethod $Number } $value) |
                Should -BeExactly $names[$value]
        }
    }
}
