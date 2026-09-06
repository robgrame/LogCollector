#Requires -Version 5.1
<#
.SYNOPSIS
Collects reusable Windows device and application inventory with the existing record contract.

.NOTES
Version 1.1.2. Collection logic adapted from the customer-provided script by
Jan Ketil Skanke, with contributions from Sandy Zeng and Maurice Daly.
This module performs no collection or network activity when imported.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-InventoryCollectionDiagnostic {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CollectionStarted', 'CollectionCompleted', 'CollectionWarning')]
        [string] $Event,
        [Parameter(Mandatory)] [string] $Stage,
        [int] $SourceLine = (Get-PSCallStack)[1].ScriptLineNumber,
        [System.Exception] $Exception,
        [int] $RecordCount,
        [int] $DeviceRecords,
        [int] $AppRecords
    )

    $context = Get-Variable -Name InventoryDiagnosticContext -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $context -or $null -eq $context.Sink) {
        return
    }
    if ($null -ne $context.Failure) {
        throw $context.Failure
    }

    $data = @{ Stage = $Stage; SourceLine = $SourceLine }
    if ($null -ne $Exception) {
        $data.ExceptionType = $Exception.GetType().FullName
        $data.HResult = [int] $Exception.HResult
    }
    foreach ($name in @('RecordCount', 'DeviceRecords', 'AppRecords')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $data[$name] = [int] $PSBoundParameters[$name]
        }
    }

    try {
        $null = & $context.Sink $Event $data
    }
    catch {
        # Provider catches must not downgrade a diagnostic callback failure to a warning.
        $context.Failure = $_
        throw
    }
}

function Write-InventoryCollectionWarning {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [System.Exception] $Exception,
        [string] $Stage
    )

    $context = Get-Variable -Name InventoryDiagnosticContext -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $context -and $null -ne $context.Failure) {
        throw $context.Failure
    }

    Write-Warning $Message
    if ($null -ne $context -and $null -ne $context.Sink) {
        $caller = (Get-PSCallStack)[1]
        if ([string]::IsNullOrEmpty($Stage)) {
            $Stage = $caller.FunctionName
        }
        Write-InventoryCollectionDiagnostic -Event CollectionWarning -Stage $Stage `
            -SourceLine $caller.ScriptLineNumber -Exception $Exception
    }
}

function Get-InventoryPropertyValue {
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [array]) {
        return @($InputObject | ForEach-Object {
                Get-InventoryPropertyValue -InputObject $_ -Name $Name
            })
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-InventoryLegacyString {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return $null
    }

    return "$Value"
}

function Get-InventoryRequiredCimInstance {
    param(
        [Parameter(Mandatory)] [string] $ClassName,
        [string] $Namespace
    )

    $stage = "Get-InventoryRequiredCimInstance.$ClassName"
    Write-InventoryCollectionDiagnostic -Event CollectionStarted -Stage $stage
    try {
        if ([string]::IsNullOrWhiteSpace($Namespace)) {
            $result = @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
        }
        else {
            $result = @(Get-CimInstance -ClassName $ClassName -Namespace $Namespace -ErrorAction Stop)
        }
    }
    catch {
        Write-InventoryCollectionDiagnostic -Event CollectionWarning -Stage $stage -Exception $_.Exception
        throw "Required CIM class '$ClassName' could not be queried: $($_.Exception.Message)"
    }

    if ($result.Count -eq 0) {
        Write-InventoryCollectionDiagnostic -Event CollectionWarning -Stage $stage
        throw "Required CIM class '$ClassName' returned no instances."
    }

    Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage $stage `
        -RecordCount $result.Count
    return $result
}

function Get-InventoryOptionalCimInstance {
    param(
        [Parameter(Mandatory)] [string] $ClassName,
        [string] $Namespace
    )

    $stage = "Get-InventoryOptionalCimInstance.$ClassName"
    Write-InventoryCollectionDiagnostic -Event CollectionStarted -Stage $stage
    try {
        if ([string]::IsNullOrWhiteSpace($Namespace)) {
            $result = @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
        }
        else {
            $result = @(Get-CimInstance -ClassName $ClassName -Namespace $Namespace -ErrorAction Stop)
        }
    }
    catch {
        Write-InventoryCollectionWarning "Optional CIM class '$ClassName' could not be queried: $($_.Exception.Message)" -Exception $_.Exception -Stage $stage
        Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage $stage -RecordCount 0
        return @()
    }

    if ($result.Count -eq 0) {
        Write-InventoryCollectionWarning "Optional CIM class '$ClassName' returned no instances." -Stage $stage
    }

    Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage $stage `
        -RecordCount $result.Count
    return $result
}

function Get-InventoryRegistryValue {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [switch] $Optional
    )

    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return Get-InventoryPropertyValue -InputObject $item -Name $Name
    }
    catch {
        if ($Optional) {
            Write-InventoryCollectionWarning "Optional registry value '$Path\$Name' is unavailable: $($_.Exception.Message)" -Exception $_.Exception
            return $null
        }
        throw "Required registry value '$Path\$Name' is unavailable: $($_.Exception.Message)"
    }
}

function Get-InventoryManagedDeviceInfo {
    try {
        $keys = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments' -Recurse -ErrorAction Stop |
            Where-Object { $_.PSChildName -eq 'MS DM Server' } |
            Sort-Object -Property PSPath)
    }
    catch {
        Write-InventoryCollectionWarning "Managed device information could not be read from the enrollment registry: $($_.Exception.Message)" -Exception $_.Exception
        return [pscustomobject]@{ ManagedDeviceName = $null; ManagedDeviceID = $null }
    }

    if ($keys.Count -eq 0) {
        Write-InventoryCollectionWarning 'Managed device information is unavailable because no MS DM Server enrollment registry key was found.'
        return [pscustomobject]@{ ManagedDeviceName = $null; ManagedDeviceID = $null }
    }

    $enrollments = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $keys) {
        try {
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $enrollments.Add($item)
        }
        catch {
            Write-InventoryCollectionWarning "An MS DM Server enrollment registry key could not be read: $($_.Exception.Message)" -Exception $_.Exception
        }
    }
    if ($enrollments.Count -eq 0) {
        Write-InventoryCollectionWarning 'Managed device information is unavailable because no enrollment registry entry could be read.'
        return [pscustomobject]@{ ManagedDeviceName = $null; ManagedDeviceID = $null }
    }

    if ($enrollments.Count -gt 1) {
        Write-InventoryCollectionWarning 'Multiple MS DM Server enrollment registry entries were found; the first registry path is used.'
    }
    $selected = $enrollments[0]

    $name = Get-InventoryPropertyValue -InputObject $selected -Name 'EntDeviceName'
    if ([string]::IsNullOrWhiteSpace([string] $name)) {
        Write-InventoryCollectionWarning 'ManagedDeviceName is unavailable because EntDeviceName is missing from the enrollment registry.'
        $name = $null
    }

    $managedDeviceId = Get-InventoryPropertyValue -InputObject $selected -Name 'EntDMID'
    if ([string]::IsNullOrWhiteSpace([string] $managedDeviceId)) {
        Write-InventoryCollectionWarning 'ManagedDeviceID is unavailable because EntDMID is missing from the enrollment registry.'
        $managedDeviceId = $null
    }

    return [pscustomobject]@{
        ManagedDeviceName = ConvertTo-InventoryLegacyString $name
        ManagedDeviceID = ConvertTo-InventoryLegacyString $managedDeviceId
    }
}

function Get-InventoryDefaultUpdateService {
    try {
        $manager = New-Object -ComObject 'Microsoft.Update.ServiceManager' -ErrorAction Stop
        $service = @($manager.Services | Where-Object { $_.IsDefaultAUService -eq $true } |
            Select-Object -First 1)
        if ($service.Count -eq 0) {
            Write-InventoryCollectionWarning 'The default Windows Update service could not be identified.'
            return $null
        }
        return ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue -InputObject $service[0] -Name 'Name')
    }
    catch {
        Write-InventoryCollectionWarning "The Windows Update service provider is unavailable: $($_.Exception.Message)" -Exception $_.Exception
        return $null
    }
}

function Get-InventoryWindowsVersion {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    try {
        $item = Get-ItemProperty -Path $path -ErrorAction Stop
    }
    catch {
        Write-InventoryCollectionWarning "Windows version registry data is unavailable: $($_.Exception.Message)" -Exception $_.Exception
        return $null
    }

    $displayVersion = Get-InventoryPropertyValue -InputObject $item -Name 'DisplayVersion'
    if (-not [string]::IsNullOrWhiteSpace([string] $displayVersion)) {
        return ConvertTo-InventoryLegacyString $displayVersion
    }

    $releaseId = Get-InventoryPropertyValue -InputObject $item -Name 'ReleaseId'
    if (-not [string]::IsNullOrWhiteSpace([string] $releaseId)) {
        return ConvertTo-InventoryLegacyString $releaseId
    }

    Write-InventoryCollectionWarning 'WindowsVersion is unavailable because neither DisplayVersion nor ReleaseId exists.'
    return $null
}

function Get-InventorySystemInformation {
    $instances = @(Get-InventoryOptionalCimInstance -ClassName 'MS_SystemInformation' -Namespace 'root\WMI')
    if ($instances.Count -eq 0) {
        return $null
    }
    return $instances[0]
}

function Get-InventoryTpmData {
    $result = [ordered]@{
        TPMReady = $null
        TPMPresent = $null
        TPMEnabled = $null
        TPMActivated = $null
        TPMThumbprint = $null
    }

    if ($null -eq (Get-Command -Name Get-Tpm -ErrorAction SilentlyContinue)) {
        Write-InventoryCollectionWarning 'TPM state is unavailable because Get-Tpm is not installed.'
    }
    else {
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            if ($null -eq $tpm) {
                Write-InventoryCollectionWarning 'TPM state is unavailable because Get-Tpm returned no data.'
            }
            else {
                $result.TPMReady = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TpmReady')
                $result.TPMPresent = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TpmPresent')
                $result.TPMEnabled = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TpmEnabled')
                $result.TPMActivated = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TpmActivated')
            }
        }
        catch {
            Write-InventoryCollectionWarning "TPM state is unavailable: $($_.Exception.Message)" -Exception $_.Exception
        }
    }

    if ($null -eq (Get-Command -Name Get-TpmEndorsementKeyInfo -ErrorAction SilentlyContinue)) {
        Write-InventoryCollectionWarning 'TPM endorsement certificate information is unavailable because Get-TpmEndorsementKeyInfo is not installed.'
    }
    else {
        try {
            $endorsement = Get-TpmEndorsementKeyInfo -ErrorAction Stop
            $certificates = Get-InventoryPropertyValue $endorsement 'AdditionalCertificates'
            $thumbprints = @($certificates | ForEach-Object {
                    Get-InventoryPropertyValue -InputObject $_ -Name 'Thumbprint'
                } | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
            if ($thumbprints.Count -gt 0) {
                $result.TPMThumbprint = $thumbprints -join ' '
            }
            else {
                Write-InventoryCollectionWarning 'TPM endorsement certificate information returned no thumbprint.'
            }
        }
        catch {
            Write-InventoryCollectionWarning "TPM endorsement certificate information is unavailable: $($_.Exception.Message)" -Exception $_.Exception
        }
    }

    return [pscustomobject] $result
}

function ConvertFrom-InventoryBitLockerProtectionStatus {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) { return $null }
    switch ([int] $Value) {
        0 { 'Off' }
        1 { 'On' }
        2 { 'Unknown' }
        default { 'Unknown' }
    }
}

function ConvertFrom-InventoryBitLockerConversionStatus {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) { return $null }
    switch ([int] $Value) {
        0 { 'FullyDecrypted' }
        1 { 'FullyEncrypted' }
        2 { 'EncryptionInProgress' }
        3 { 'DecryptionInProgress' }
        4 { 'EncryptionPaused' }
        5 { 'DecryptionPaused' }
        default { 'Unknown' }
    }
}

function ConvertFrom-InventoryBitLockerEncryptionMethod {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) { return $null }
    switch ([int] $Value) {
        0 { 'None' }
        1 { 'Aes128Diffuser' }
        2 { 'Aes256Diffuser' }
        3 { 'Aes128' }
        4 { 'Aes256' }
        5 { 'Hardware' }
        6 { 'XtsAes128' }
        7 { 'XtsAes256' }
        default { 'Unknown' }
    }
}

function Get-InventoryBitLockerData {
    $result = [ordered]@{
        EncryptionMethod = $null
        VolumeStatus = $null
        ProtectionStatus = $null
    }

    if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) {
        Write-InventoryCollectionWarning 'BitLocker state is unavailable because SystemDrive is not defined.'
        return [pscustomobject] $result
    }

    try {
        $escapedDrive = $env:SystemDrive.Replace("'", "''")
        $volumes = @(Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' `
                -ClassName 'Win32_EncryptableVolume' -Filter "DriveLetter = '$escapedDrive'" -ErrorAction Stop)
    }
    catch {
        Write-InventoryCollectionWarning "BitLocker status CIM data is unavailable: $($_.Exception.Message)" -Exception $_.Exception
        return [pscustomobject] $result
    }

    if ($volumes.Count -eq 0) {
        Write-InventoryCollectionWarning "BitLocker status is unavailable because no Win32_EncryptableVolume was found for '$env:SystemDrive'."
        return [pscustomobject] $result
    }
    if ($volumes.Count -gt 1) {
        Write-InventoryCollectionWarning "Multiple Win32_EncryptableVolume instances were found for '$env:SystemDrive'; the first is used."
    }
    $volume = $volumes[0]

    try {
        $methodResult = Invoke-CimMethod -InputObject $volume -MethodName 'GetEncryptionMethod' -ErrorAction Stop
        $returnValue = Get-InventoryPropertyValue $methodResult 'ReturnValue'
        if ($null -eq $returnValue -or [uint32] $returnValue -ne 0) {
            Write-InventoryCollectionWarning "BitLocker GetEncryptionMethod returned failure code '$returnValue'."
        }
        else {
            $result.EncryptionMethod = ConvertFrom-InventoryBitLockerEncryptionMethod `
                (Get-InventoryPropertyValue $methodResult 'EncryptionMethod')
        }
    }
    catch {
        Write-InventoryCollectionWarning "BitLocker GetEncryptionMethod failed: $($_.Exception.Message)" -Exception $_.Exception
    }

    try {
        $methodResult = Invoke-CimMethod -InputObject $volume -MethodName 'GetConversionStatus' -ErrorAction Stop
        $returnValue = Get-InventoryPropertyValue $methodResult 'ReturnValue'
        if ($null -eq $returnValue -or [uint32] $returnValue -ne 0) {
            Write-InventoryCollectionWarning "BitLocker GetConversionStatus returned failure code '$returnValue'."
        }
        else {
            $result.VolumeStatus = ConvertFrom-InventoryBitLockerConversionStatus `
                (Get-InventoryPropertyValue $methodResult 'ConversionStatus')
        }
    }
    catch {
        Write-InventoryCollectionWarning "BitLocker GetConversionStatus failed: $($_.Exception.Message)" -Exception $_.Exception
    }

    try {
        $methodResult = Invoke-CimMethod -InputObject $volume -MethodName 'GetProtectionStatus' -ErrorAction Stop
        $returnValue = Get-InventoryPropertyValue $methodResult 'ReturnValue'
        if ($null -eq $returnValue -or [uint32] $returnValue -ne 0) {
            Write-InventoryCollectionWarning "BitLocker GetProtectionStatus returned failure code '$returnValue'."
        }
        else {
            $result.ProtectionStatus = ConvertFrom-InventoryBitLockerProtectionStatus `
                (Get-InventoryPropertyValue $methodResult 'ProtectionStatus')
        }
    }
    catch {
        Write-InventoryCollectionWarning "BitLocker GetProtectionStatus failed: $($_.Exception.Message)" -Exception $_.Exception
    }

    return [pscustomobject] $result
}

function Get-InventoryNetworkAdapters {
    if ($null -eq (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) {
        Write-InventoryCollectionWarning 'Network adapter inventory is unavailable because Get-NetAdapter is not installed.'
        return [object[]] @()
    }
    if ($null -eq (Get-Command -Name Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        Write-InventoryCollectionWarning 'Network IP configuration is unavailable because Get-NetIPConfiguration is not installed.'
    }

    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    }
    catch {
        Write-InventoryCollectionWarning "Network adapter inventory is unavailable: $($_.Exception.Message)" -Exception $_.Exception
        return [object[]] @()
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($adapter in $adapters) {
        $configuration = $null
        if ($null -ne (Get-Command -Name Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            try {
                $configuration = Get-NetIPConfiguration -InterfaceIndex $adapter.IfIndex -ErrorAction Stop
            }
            catch {
                Write-InventoryCollectionWarning "IP configuration for network adapter '$($adapter.InterfaceAlias)' is unavailable: $($_.Exception.Message)" -Exception $_.Exception
            }
        }

        $netProfile = Get-InventoryPropertyValue $configuration 'NetProfile'
        $ipv4Address = Get-InventoryPropertyValue $configuration 'IPv4Address'
        $gateway = Get-InventoryPropertyValue $configuration 'IPv4DefaultGateway'
        $records.Add([pscustomobject] [ordered]@{
                NetInterfaceDescription = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $adapter 'InterfaceDescription')
                NetProfileName = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $netProfile 'Name')
                NetIPv4Adress = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $ipv4Address 'IPAddress')
                NetInterfaceAlias = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $adapter 'InterfaceAlias')
                NetIPv4DefaultGateway = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $gateway 'NextHop')
                MacAddress = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $adapter 'MacAddress')
            })
    }

    return [object[]] $records.ToArray()
}

function Get-InventoryDiskHealth {
    if ($null -eq (Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        Write-InventoryCollectionWarning 'Disk health inventory is unavailable because Get-PhysicalDisk is not installed.'
        return [object[]] @()
    }
    if ($null -eq (Get-Command -Name Get-StorageReliabilityCounter -ErrorAction SilentlyContinue)) {
        Write-InventoryCollectionWarning 'Disk reliability counters are unavailable because Get-StorageReliabilityCounter is not installed.'
    }

    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop |
            Where-Object { $_.BusType -match 'NVMe|SATA|SAS|ATAPI|RAID' } |
            Sort-Object -Property DeviceID)
    }
    catch {
        Write-InventoryCollectionWarning "Disk health inventory is unavailable: $($_.Exception.Message)" -Exception $_.Exception
        return [object[]] @()
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($disk in $disks) {
        $health = $null
        if ($null -ne (Get-Command -Name Get-StorageReliabilityCounter -ErrorAction SilentlyContinue)) {
            try {
                $health = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction Stop
            }
            catch {
                Write-InventoryCollectionWarning "Reliability counters for disk '$($disk.DeviceID)' are unavailable: $($_.Exception.Message)" -Exception $_.Exception
            }
        }

        $temperature = Get-InventoryPropertyValue $health 'Temperature'
        $temperatureMax = Get-InventoryPropertyValue $health 'TemperatureMax'
        $temperatureDelta = $null
        if ($null -ne $temperature -and $null -ne $temperatureMax) {
            $temperatureDelta = [int] $temperature - [int] $temperatureMax
        }

        $deviceId = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $disk 'DeviceID')
        $record = [ordered]@{
            'Disk Number' = Get-InventoryPropertyValue $disk 'DeviceID'
            FriendlyName = Get-InventoryPropertyValue $disk 'FriendlyName'
            HealthStatus = Get-InventoryPropertyValue $disk 'HealthStatus'
            MediaType = Get-InventoryPropertyValue $disk 'MediaType'
            'Disk Wear' = Get-InventoryPropertyValue $health 'Wear'
        }
        $record["Disk $deviceId Read Errors"] = Get-InventoryPropertyValue $health 'ReadErrorsTotal'
        $record["Disk $deviceId Temperature Delta"] = $temperatureDelta
        $record["Disk $deviceId ReadErrorsUncorrected"] = Get-InventoryPropertyValue $health 'ReadErrorsUncorrected'
        $record["Disk $deviceId ReadErrorsTotal"] = Get-InventoryPropertyValue $health 'ReadErrorsTotal'
        $record["Disk $deviceId WriteErrorsUncorrected"] = Get-InventoryPropertyValue $health 'WriteErrorsUncorrected'
        $record["Disk $deviceId WriteErrorsTotal"] = Get-InventoryPropertyValue $health 'WriteErrorsTotal'
        $records.Add([pscustomobject] $record)
    }

    return [object[]] $records.ToArray()
}

function Get-InventoryInteractiveUserSid {
    param([AllowNull()] [string] $UserName)

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        return $null
    }

    try {
        $account = New-Object System.Security.Principal.NTAccount($UserName)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier])
        return $sid.Value
    }
    catch {
        Write-InventoryCollectionWarning "The interactive user SID for '$UserName' could not be resolved: $($_.Exception.Message)" -Exception $_.Exception
        return $null
    }
}

function Get-InventoryInstalledApplications {
    param([AllowNull()] [string] $UserSid)

    $createdHkuDrive = $false
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $paths.Add('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    if ([Environment]::Is64BitProcess) {
        $paths.Add('HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
            $hkuDrive = Get-PSDrive -Name HKU -PSProvider Registry -ErrorAction SilentlyContinue
            $hkuAvailable = $null -ne $hkuDrive
            if ($null -eq $hkuDrive) {
                try {
                    $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction Stop
                    $createdHkuDrive = $true
                    $hkuAvailable = $true
                }
                catch {
                    Write-InventoryCollectionWarning "Interactive-user application inventory is unavailable because the HKU drive could not be created: $($_.Exception.Message)" -Exception $_.Exception
                }
            }

            if ($hkuAvailable) {
                $paths.Add("HKU:\$UserSid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*")
                if ([Environment]::Is64BitProcess) {
                    $paths.Add("HKU:\$UserSid\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")
                }
            }
        }

        $applications = New-Object 'System.Collections.Generic.List[object]'
        foreach ($path in $paths) {
            try {
                # Read complete entries so a missing optional value (for example InstallDate)
                # cannot discard otherwise valid software from the same registry view.
                $items = @(Get-ItemProperty -Path $path -ErrorAction Stop)
            }
            catch {
                Write-InventoryCollectionWarning "Application registry path '$path' is unavailable: $($_.Exception.Message)" -Exception $_.Exception
                continue
            }

            foreach ($item in $items) {
                $displayName = Get-InventoryPropertyValue $item 'DisplayName'
                if (-not [string]::IsNullOrWhiteSpace([string] $displayName)) {
                    $applications.Add($item)
                }
            }
        }

        return [object[]] $applications.ToArray()
    }
    finally {
        if ($createdHkuDrive) {
            Remove-PSDrive -Name HKU -ErrorAction Stop
        }
    }
}

function Get-InventoryVersionRank {
    param([AllowNull()] [object] $DisplayVersion)

    $text = ConvertTo-InventoryLegacyString $DisplayVersion
    $parsed = $null
    $valid = -not [string]::IsNullOrWhiteSpace($text) -and
        [version]::TryParse($text, [ref] $parsed)
    if (-not $valid) {
        $parsed = New-Object System.Version(0, 0)
    }

    return [pscustomobject]@{
        IsValid = [int] $valid
        Parsed = $parsed
        Text = if ($null -eq $text) { '' } else { $text }
    }
}

function Select-InventoryUniqueApplications {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Applications)

    $groups = @($Applications | Group-Object -Property DisplayName)
    $selected = foreach ($group in $groups) {
        $group.Group |
            Sort-Object -Property @(
                @{ Expression = { (Get-InventoryVersionRank (Get-InventoryPropertyValue $_ 'DisplayVersion')).IsValid }; Descending = $true }
                @{ Expression = { (Get-InventoryVersionRank (Get-InventoryPropertyValue $_ 'DisplayVersion')).Parsed }; Descending = $true }
                @{ Expression = { (Get-InventoryVersionRank (Get-InventoryPropertyValue $_ 'DisplayVersion')).Text }; Descending = $true }
                @{ Expression = { ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $_ 'PSPath') }; Descending = $false }
            ) |
            Select-Object -First 1
    }

    return [object[]] @($selected | Sort-Object -Property DisplayName)
}

function Get-InventoryDeviceRecord {
    param(
        [Parameter(Mandatory)] [object] $Identity,
        [Parameter(Mandatory)] [object] $ComputerInfo,
        [AllowNull()] [string] $ManagedDeviceName,
        [AllowNull()] [string] $ManagedDeviceId,
        [Parameter(Mandatory)] [DateTime] $CollectedAt
    )

    $osInfo = @(Get-InventoryRequiredCimInstance -ClassName 'Win32_OperatingSystem')[0]
    $biosInfo = @(Get-InventoryRequiredCimInstance -ClassName 'Win32_BIOS')[0]
    $productInfo = @(Get-InventoryRequiredCimInstance -ClassName 'Win32_ComputerSystemProduct')[0]
    $processors = @(Get-InventoryRequiredCimInstance -ClassName 'Win32_Processor')
    $systemInformation = Get-InventorySystemInformation

    $manufacturer = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $ComputerInfo 'Manufacturer')
    $model = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $ComputerInfo 'Model')
    $biosVersion = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $biosInfo 'SMBIOSBIOSVersion')
    $systemSku = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $systemInformation 'SystemSku')
    if (-not [string]::IsNullOrWhiteSpace($systemSku)) {
        $systemSku = $systemSku.Trim()
    }

    if ($manufacturer -match 'HP|Hewlett-Packard') {
        $manufacturer = 'HP'
    }

    switch -Wildcard ($manufacturer) {
        '*Microsoft*' {
            $manufacturer = 'Microsoft'
            if ($null -ne $model) { $model = $model.Trim() }
        }
        '*HP*' {
            if ($null -ne $model) { $model = $model.Trim() }
            $baseBoardProduct = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $systemInformation 'BaseBoardProduct')
            if (-not [string]::IsNullOrWhiteSpace($baseBoardProduct)) {
                $systemSku = $baseBoardProduct.Trim()
            }
            if ($biosVersion -like '*ver*') {
                if ($biosVersion -match '\.F\.\d+$' -and $biosVersion -match '(?i)Ver\.(.+)$') {
                    $biosVersion = $Matches[1].Trim()
                }
                else {
                    $candidate = ($biosVersion -split '\s+')[0]
                    $parsedBios = $null
                    if ([version]::TryParse($candidate, [ref] $parsedBios)) {
                        $biosVersion = $parsedBios.ToString()
                    }
                    else {
                        Write-InventoryCollectionWarning "HP BIOS version '$biosVersion' could not be normalized; the original value is retained."
                    }
                }
            }
            else {
                $major = Get-InventoryPropertyValue $biosInfo 'SystemBiosMajorVersion'
                $minor = Get-InventoryPropertyValue $biosInfo 'SystemBiosMinorVersion'
                if ($null -ne $major -and $null -ne $minor) {
                    $biosVersion = "$major.$minor"
                }
            }
        }
        '*Dell*' {
            $manufacturer = 'Dell'
            if ($null -ne $model) { $model = $model.Trim() }
            if ($null -ne $biosVersion) { $biosVersion = $biosVersion.Trim() }
        }
        '*Lenovo*' {
            $manufacturer = 'Lenovo'
            $productVersion = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $productInfo 'Version')
            if (-not [string]::IsNullOrWhiteSpace($productVersion)) {
                $model = $productVersion.Trim()
            }
            $computerModel = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $ComputerInfo 'Model')
            if (-not [string]::IsNullOrWhiteSpace($computerModel)) {
                $systemSku = $computerModel.Substring(0, [Math]::Min(4, $computerModel.Length)).Trim()
            }
            $major = Get-InventoryPropertyValue $biosInfo 'SystemBiosMajorVersion'
            $minor = Get-InventoryPropertyValue $biosInfo 'SystemBiosMinorVersion'
            if ($null -ne $major -and $null -ne $minor) {
                $biosVersion = "$major.$minor"
            }
        }
    }

    $pcSystemType = switch (Get-InventoryPropertyValue $ComputerInfo 'PCSystemType') {
        1 { 'Desktop' }
        2 { 'Laptop' }
        3 { 'Workstation' }
        4 { 'EnterpriseServer' }
        5 { 'SOHOServer' }
        6 { 'AppliancePC' }
        7 { 'PerformanceServer' }
        8 { 'Maximum' }
        default { 'Unspecified' }
    }
    $pcSystemTypeEx = switch (Get-InventoryPropertyValue $ComputerInfo 'PCSystemTypeEx') {
        1 { 'Desktop' }
        2 { 'Laptop' }
        3 { 'Workstation' }
        4 { 'EnterpriseServer' }
        5 { 'SOHOServer' }
        6 { 'AppliancePC' }
        7 { 'PerformanceServer' }
        8 { 'Slate' }
        9 { 'Maximum' }
        default { 'Unspecified' }
    }

    $lastBoot = Get-InventoryPropertyValue $osInfo 'LastBootUpTime'
    $uptime = $null
    if ($null -ne $lastBoot) {
        $uptime = [int] (New-TimeSpan -Start $lastBoot -End $CollectedAt).Days
    }
    else {
        Write-InventoryCollectionWarning 'ComputerUpTime is unavailable because LastBootUpTime is missing.'
    }

    $memory = Get-InventoryPropertyValue $ComputerInfo 'TotalPhysicalMemory'
    if ($null -ne $memory) {
        $memory = [Math]::Round(([double] $memory / 1GB))
    }
    else {
        Write-InventoryCollectionWarning 'Memory is unavailable because TotalPhysicalMemory is missing.'
    }

    $processorManufacturers = @($processors | ForEach-Object {
            ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $_ 'Manufacturer')
        } | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $processorNames = @($processors | ForEach-Object {
            ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $_ 'Name')
        } | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $processorCores = @($processors | ForEach-Object {
            ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $_ 'NumberOfCores')
        } | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $processorLogical = @($processors | ForEach-Object {
            ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $_ 'NumberOfLogicalProcessors')
        } | Where-Object { $null -ne $_ } | Select-Object -Unique)

    $meteredValue = Get-InventoryRegistryValue -Path 'HKLM:\Software\Microsoft\WindowsUpdate\UX\Settings' `
        -Name 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork' -Optional
    $metered = $null
    if ($null -ne $meteredValue) {
        $metered = if ("$meteredValue" -eq '0') { 'false' } else { 'true' }
    }

    $tpm = Get-InventoryTpmData
    $bitLocker = Get-InventoryBitLockerData

    return [pscustomobject] [ordered]@{
        ManagedDeviceName = ConvertTo-InventoryLegacyString $ManagedDeviceName
        AzureADDeviceID = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $Identity 'EntraDeviceId')
        ManagedDeviceID = ConvertTo-InventoryLegacyString $ManagedDeviceId
        ComputerName = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $ComputerInfo 'Name')
        Model = ConvertTo-InventoryLegacyString $model
        Manufacturer = ConvertTo-InventoryLegacyString $manufacturer
        PCSystemType = ConvertTo-InventoryLegacyString $pcSystemType
        PCSystemTypeEx = ConvertTo-InventoryLegacyString $pcSystemTypeEx
        ComputerUpTime = ConvertTo-InventoryLegacyString $uptime
        LastBoot = ConvertTo-InventoryLegacyString $lastBoot
        InstallDate = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $osInfo 'InstallDate')
        WindowsVersion = Get-InventoryWindowsVersion
        DefaultAUService = Get-InventoryDefaultUpdateService
        AUMetered = ConvertTo-InventoryLegacyString $metered
        SystemSkuNumber = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $ComputerInfo 'SystemSKUNumber')
        SerialNumber = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $biosInfo 'SerialNumber')
        SMBIOSUUID = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $productInfo 'UUID')
        BiosVersion = ConvertTo-InventoryLegacyString $biosVersion
        BiosDate = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $biosInfo 'ReleaseDate')
        SystemSKU = ConvertTo-InventoryLegacyString $systemSku
        FirmwareType = ConvertTo-InventoryLegacyString $env:firmware_type
        Memory = ConvertTo-InventoryLegacyString $memory
        OSBuild = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $osInfo 'BuildNumber')
        OSRevision = ConvertTo-InventoryLegacyString (Get-InventoryRegistryValue `
                -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR' -Optional)
        OSName = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $osInfo 'Caption')
        CPUManufacturer = ConvertTo-InventoryLegacyString ($processorManufacturers -join ' ')
        CPUName = ConvertTo-InventoryLegacyString ($processorNames -join ' ')
        CPUCores = ConvertTo-InventoryLegacyString ($processorCores -join ' ')
        CPULogical = ConvertTo-InventoryLegacyString ($processorLogical -join ' ')
        TPMReady = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TPMReady')
        TPMPresent = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TPMPresent')
        TPMEnabled = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TPMEnabled')
        TPMActived = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TPMActivated')
        TPMThumbprint = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $tpm 'TPMThumbprint')
        BitlockerCipher = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $bitLocker 'EncryptionMethod')
        BitlockerVolumeStatus = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $bitLocker 'VolumeStatus')
        BitlockerProtectionStatus = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $bitLocker 'ProtectionStatus')
        NetworkAdapters = [object[]] @(Get-InventoryNetworkAdapters)
        DiskHealth = [object[]] @(Get-InventoryDiskHealth)
    }
}

function Get-InventoryAppRecords {
    param(
        [Parameter(Mandatory)] [object] $ComputerInfo,
        [AllowNull()] [string] $ManagedDeviceName,
        [AllowNull()] [string] $ManagedDeviceId
    )

    $userSid = Get-InventoryInteractiveUserSid -UserName (ConvertTo-InventoryLegacyString `
            (Get-InventoryPropertyValue $ComputerInfo 'UserName'))
    $applications = @(Get-InventoryInstalledApplications -UserSid $userSid)
    $applications = @(Select-InventoryUniqueApplications -Applications $applications)
    $records = New-Object 'System.Collections.Generic.List[object]'

    foreach ($application in $applications) {
        $psPath = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $application 'PSPath')
        $registryPath = $null
        if ($null -ne $psPath) {
            $registryPath = ($psPath -split '::')[-1]
        }

        $records.Add([pscustomobject] [ordered]@{
                ComputerName = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $ComputerInfo 'Name')
                ManagedDeviceName = ConvertTo-InventoryLegacyString $ManagedDeviceName
                ManagedDeviceID = ConvertTo-InventoryLegacyString $ManagedDeviceId
                AppName = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $application 'DisplayName')
                AppVersion = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $application 'DisplayVersion')
                AppInstallDate = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $application 'InstallDate')
                AppPublisher = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $application 'Publisher')
                AppUninstallString = ConvertTo-InventoryLegacyString (Get-InventoryPropertyValue $application 'UninstallString')
                AppUninstallRegPath = ConvertTo-InventoryLegacyString $registryPath
            })
    }

    return [object[]] $records.ToArray()
}

function Assert-InventoryIdentity {
    param([Parameter(Mandatory)] [object] $Identity)

    foreach ($name in @('EntraDeviceId', 'DeviceName', 'IntuneDeviceId')) {
        if ($null -eq $Identity.PSObject.Properties[$name]) {
            throw "Identity must contain the '$name' property."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string] (Get-InventoryPropertyValue $Identity 'EntraDeviceId'))) {
        throw 'Identity.EntraDeviceId must not be empty.'
    }
}

function Get-Inventory {
    <#
    .PARAMETER DiagnosticSink
    Optional synchronous callback invoked as & $DiagnosticSink $Event $Data.
    Receives only collection stage identifiers, source lines, exception types/codes,
    and record counts. Callback output is discarded and callback failures propagate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Identity,
        [bool] $CollectDeviceInventory = $true,
        [bool] $CollectAppInventory = $true,
        [scriptblock] $DiagnosticSink
    )

    $previousContext = Get-Variable -Name InventoryDiagnosticContext -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $script:InventoryDiagnosticContext = [pscustomobject]@{ Sink = $DiagnosticSink; Failure = $null }
    try {
        Write-InventoryCollectionDiagnostic -Event CollectionStarted -Stage 'Get-Inventory'
        Write-InventoryCollectionDiagnostic -Event CollectionStarted -Stage 'Assert-InventoryIdentity'
        Assert-InventoryIdentity -Identity $Identity
        Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage 'Assert-InventoryIdentity'
        $deviceRecords = New-Object 'System.Collections.Generic.List[object]'
        $appRecords = New-Object 'System.Collections.Generic.List[object]'

        if ($CollectDeviceInventory -or $CollectAppInventory) {
            $computerInfo = @(Get-InventoryRequiredCimInstance -ClassName 'Win32_ComputerSystem')[0]
            if ([string]::IsNullOrWhiteSpace([string] (Get-InventoryPropertyValue $computerInfo 'Name'))) {
                throw "Required CIM class 'Win32_ComputerSystem' did not provide Name."
            }
            Write-InventoryCollectionDiagnostic -Event CollectionStarted -Stage 'Get-InventoryManagedDeviceInfo'
            $managedDeviceInfo = Get-InventoryManagedDeviceInfo
            Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage 'Get-InventoryManagedDeviceInfo'

            if ($CollectDeviceInventory) {
                Write-InventoryCollectionDiagnostic -Event CollectionStarted -Stage 'Get-InventoryDeviceRecord'
                $deviceRecords.Add((Get-InventoryDeviceRecord -Identity $Identity -ComputerInfo $computerInfo `
                        -ManagedDeviceName $managedDeviceInfo.ManagedDeviceName `
                        -ManagedDeviceId $managedDeviceInfo.ManagedDeviceID -CollectedAt (Get-Date)))
                Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage 'Get-InventoryDeviceRecord' `
                    -RecordCount $deviceRecords.Count
            }
            if ($CollectAppInventory) {
                Write-InventoryCollectionDiagnostic -Event CollectionStarted -Stage 'Get-InventoryAppRecords'
                foreach ($record in @(Get-InventoryAppRecords -ComputerInfo $computerInfo `
                            -ManagedDeviceName $managedDeviceInfo.ManagedDeviceName `
                            -ManagedDeviceId $managedDeviceInfo.ManagedDeviceID)) {
                    $appRecords.Add($record)
                }
                Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage 'Get-InventoryAppRecords' `
                    -RecordCount $appRecords.Count
            }
        }

        Write-InventoryCollectionDiagnostic -Event CollectionCompleted -Stage 'Get-Inventory' `
            -DeviceRecords $deviceRecords.Count -AppRecords $appRecords.Count
        return [pscustomobject]@{
            DeviceRecords = [object[]] $deviceRecords.ToArray()
            AppRecords = [object[]] $appRecords.ToArray()
        }
    }
    finally {
        if ($null -eq $previousContext) {
            Remove-Variable -Name InventoryDiagnosticContext -Scope Script
        }
        else {
            $script:InventoryDiagnosticContext = $previousContext
        }
    }
}

Export-ModuleMember -Function Get-Inventory
