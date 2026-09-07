<#
.SYNOPSIS
    Collects Windows inventory and submits it to the LogCollector frontend.

.DESCRIPTION
    Entry point invoked by the scheduled task. The flow is:

      1. Resolve the device identity (Entra device id is mandatory).
      2. Select the client certificate - enterprise PKI first, Intune enrollment
         certificate as the fallback tier.
      3. Collect the requested inventory areas.
      4. Drain any spooled submissions, then submit the current sample.

    The scheduled task supplies the two-hour RandomDelay, so this script does NOT
    sleep on its own. Doing both would double the spread and make the effective
    collection window four hours wide, which is not what the schedule promises.

    COLLECTION FAILURE POLICY
    Every area is collected inside a guarded section. A section that fails emits a
    warning and a CollectionStatus record describing what went wrong; it never
    emits a success-shaped record with default values. A device reporting
    "TpmPresent = false" because the TPM namespace was unreachable is worse than
    no record at all, because it is indistinguishable from a real answer and it
    silently corrupts fleet-wide queries.

    For the same reason the script distinguishes:
      * Absent      - the query succeeded and returned nothing.
      * Unavailable - the query itself failed; the truth is unknown.
      * NotSupported- the platform cannot answer (for example Secure Boot on
                      legacy BIOS, or BitLocker on an edition without it).

.PARAMETER FrontendUrl
    Full https URL of the ingest endpoint, e.g.
    https://<your-intake>.azurewebsites.net/api/inventory

.PARAMETER TableName
    Target Log Analytics custom table. Must be mapped to a DCR stream server-side.

.PARAMETER Collect
    Areas to collect. Defaults to all areas.

.PARAMETER CertificateThumbprint
    Pins an exact certificate. Overrides automatic selection.

.PARAMETER CertificateIssuerLike
    Semicolon-separated wildcard list matched against the issuer DN of enterprise
    PKI certificates, e.g. "*CONTOSO-ISSUING-CA*;*CONTOSO-ROOT-CA*".

.EXAMPLE
    .\Invoke-CustomInventory.ps1 -FrontendUrl https://host/api/inventory -TableName InventoryWindows_CL

.EXAMPLE
    .\Invoke-CustomInventory.ps1 -FrontendUrl https://host/api/inventory -Collect Disk,BitLocker -WhatIfSubmission

.NOTES
    Windows PowerShell 5.1. Run as SYSTEM so the LocalMachine certificate store,
    the BitLocker/TPM providers and the device-wide spool directory are reachable.

    BitLocker collection reports protector TYPES only. Recovery passwords are
    never read, never logged and never transmitted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $FrontendUrl,

    [ValidateNotNullOrEmpty()]
    [string] $TableName = 'InventoryWindows_CL',

    [string] $SpoolDirectory = 'C:\ProgramData\LogCollector\Spool',

    [string] $CertificateThumbprint,

    [string] $CertificateSubjectLike,

    [string] $CertificateIssuerLike,

    [ValidateSet('Hardware', 'OperatingSystem', 'Software', 'Network', 'Security', 'Disk', 'BitLocker')]
    [string[]] $Collect = @('Hardware', 'OperatingSystem', 'Software', 'Network', 'Security', 'Disk', 'BitLocker'),

    [string] $CollectCsv,

    [int] $MaxAttempts = 4,

    [int] $MaxSpoolAgeDays = 7,

    [switch] $WhatIfSubmission
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('CollectCsv')) {
    if ($PSBoundParameters.ContainsKey('Collect')) { throw 'Use Collect or CollectCsv, not both.' }
    $csvAreas = @($CollectCsv.Split(',') | ForEach-Object { $_.Trim() })
    $allowedAreas = @('Hardware', 'OperatingSystem', 'Software', 'Network', 'Security', 'Disk', 'BitLocker')
    if ($csvAreas.Count -eq 0 -or @($csvAreas | Where-Object { $_ -notin $allowedAreas }).Count -gt 0) {
        throw 'CollectCsv contains an unsupported inventory area.'
    }
    $Collect = $csvAreas
}

# Bumped whenever the emitted record shape changes, so a mixed-version fleet can
# be told apart in Log Analytics.
#   1.0.0 - initial: Hardware, OperatingSystem, Software, Network, Security
#   1.0.1 - added Disk/Volume and BitLocker; guarded sections with CollectionStatus
#           records; TPM and Secure Boot now distinguish Absent from Unavailable.
#   1.0.2 - explicit CSV transport for native powershell.exe -File arguments.
#   1.0.3 - Expect 100-continue transport for large certificate-authenticated uploads.
$script:CollectorVersion = '1.0.3'

$moduleRoot = Join-Path $PSScriptRoot '..\src\Client'
Import-Module (Join-Path $moduleRoot 'DeviceIdentity.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'InventorySpool.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'InventoryClient.psm1') -Force -DisableNameChecking

$uri = [Uri]$FrontendUrl
if ($uri.Scheme -ne 'https') {
    throw "FrontendUrl must use https; '$($uri.Scheme)' would send signed inventory in clear text."
}

function Assert-SupportedSpoolPath {
    <#
    .SYNOPSIS
        Fail-fast shape check on -SpoolDirectory.
    .DESCRIPTION
        This is NOT the security boundary. InventorySpool.psm1 owns spool trust
        (owner, DACL, reparse points) and enforces it before every read, drain and
        save; that check stays authoritative and is not duplicated here.

        This one only turns a misconfigured path into a one-line message instead
        of a module stack trace, and it does so before any inventory is collected
        so the run fails in a second rather than after a full WMI sweep.

        The spool must be an absolute path on a local fixed drive.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path.StartsWith('\\')) {
        throw "SpoolDirectory '$Path' is a UNC or device path. The spool must be on a local fixed drive."
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "SpoolDirectory '$Path' is not an absolute path."
    }

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "SpoolDirectory '$Path' has no drive root."
    }

    try {
        $driveType = (New-Object System.IO.DriveInfo $root).DriveType
    }
    catch {
        throw "SpoolDirectory '$Path' does not resolve to a usable local drive: $($_.Exception.Message)"
    }

    if ($driveType -ne [System.IO.DriveType]::Fixed) {
        throw "SpoolDirectory '$Path' is on a '$driveType' drive. The spool must be on a local fixed drive."
    }
}

Assert-SupportedSpoolPath -Path $SpoolDirectory

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-PropertyValue {
    <#
    .SYNOPSIS
        Safely reads a property that may not exist on this Windows build.
    .DESCRIPTION
        Set-StrictMode -Version Latest turns a reference to a missing property
        into a terminating error. CIM and Storage-module objects gain and lose
        properties across Windows releases, so every optional read goes through
        here rather than gambling on the shape of the current build.
    #>
    param(
        $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return $property.Value
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)] [string] $Name)
    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function New-CollectionStatusRecord {
    <#
    .SYNOPSIS
        Explicit, queryable diagnostics for one collection area.
    #>
    param(
        [Parameter(Mandatory)] [string] $SectionName,
        [Parameter(Mandatory)] [ValidateSet('Collected', 'Empty', 'Failed', 'NotSupported')] [string] $Status,
        [int] $RecordCount = 0,
        [string] $Message = ''
    )

    [ordered]@{
        RecordType         = 'CollectionStatus'
        SectionName        = $SectionName
        SectionStatus      = $Status
        SectionRecordCount = $RecordCount
        SectionMessage     = $Message
    }
}

# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------

function Get-OperatingSystemRecord {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop

    $installDate = Get-PropertyValue $os 'InstallDate'
    $lastBoot = Get-PropertyValue $os 'LastBootUpTime'

    return , [ordered]@{
        RecordType     = 'OperatingSystem'
        Caption        = [string](Get-PropertyValue $os 'Caption')
        Version        = [string](Get-PropertyValue $os 'Version')
        BuildNumber    = [string](Get-PropertyValue $os 'BuildNumber')
        Architecture   = [string](Get-PropertyValue $os 'OSArchitecture')
        OsInstallDate  = if ($installDate) { ([DateTimeOffset]$installDate).ToUniversalTime().ToString('o') } else { $null }
        LastBootUpTime = if ($lastBoot) { ([DateTimeOffset]$lastBoot).ToUniversalTime().ToString('o') } else { $null }
        Locale         = [string](Get-PropertyValue $os 'Locale')
    }
}

function Get-HardwareRecord {
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    return , [ordered]@{
        RecordType               = 'Hardware'
        Manufacturer             = [string](Get-PropertyValue $system 'Manufacturer')
        Model                    = [string](Get-PropertyValue $system 'Model')
        SerialNumber             = [string](Get-PropertyValue $bios 'SerialNumber')
        BiosVersion              = [string](Get-PropertyValue $bios 'SMBIOSBIOSVersion')
        TotalPhysicalMemoryBytes = [int64](Get-PropertyValue $system 'TotalPhysicalMemory' 0)
        LogicalProcessors        = [int](Get-PropertyValue $system 'NumberOfLogicalProcessors' 0)
        ProcessorName            = [string](Get-PropertyValue $cpu 'Name')
        ChassisType              = [string](Get-PropertyValue $system 'PCSystemType')
    }
}

function Get-SoftwareRecords {
    # Both registry views: 32-bit products on a 64-bit OS live under WOW6432Node
    # and are invisible from the native view, which silently halves the inventory.
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $records = New-Object System.Collections.ArrayList
    foreach ($key in $uninstallKeys) {
        if (-not (Test-Path $key)) { continue }

        foreach ($item in (Get-ChildItem $key -ErrorAction SilentlyContinue)) {
            $displayName = $item.GetValue('DisplayName')
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
            if ($item.GetValue('SystemComponent') -eq 1) { continue }

            $null = $records.Add([ordered]@{
                RecordType          = 'Software'
                DisplayName         = [string]$displayName
                DisplayVersion      = [string]$item.GetValue('DisplayVersion')
                Publisher           = [string]$item.GetValue('Publisher')
                SoftwareInstallDate = [string]$item.GetValue('InstallDate')
                RegistryView        = if ($key -like '*WOW6432Node*') { 'x86' } else { 'native' }
            })
        }
    }

    return @($records)
}

function Get-NetworkRecords {
    $records = New-Object System.Collections.ArrayList
    foreach ($adapter in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop)) {
        $null = $records.Add([ordered]@{
            RecordType  = 'Network'
            Description = [string](Get-PropertyValue $adapter 'Description')
            MacAddress  = [string](Get-PropertyValue $adapter 'MACAddress')
            IpAddresses = (@(Get-PropertyValue $adapter 'IPAddress' @()) -join ',')
            DhcpEnabled = [bool](Get-PropertyValue $adapter 'DHCPEnabled' $false)
            DnsDomain   = [string](Get-PropertyValue $adapter 'DNSDomain')
        })
    }
    return @($records)
}

function Get-SecurityRecord {
    <#
    .SYNOPSIS
        TPM and Secure Boot posture, with unknown state reported as unknown.
    .DESCRIPTION
        TpmQueryStatus separates the three cases that a plain boolean conflates:
          Present     - the CIM query succeeded and returned a TPM.
          Absent      - the query succeeded and returned nothing; there is no TPM.
          Unavailable - the query failed (namespace missing, access denied, WMI
                        broken); whether a TPM exists is unknown.
        TpmPresent/TpmEnabled are left null in the Unavailable case rather than
        defaulting to false, so a query failure can never be mistaken for a
        genuinely unprotected device.
    #>
    $tpmQueryStatus = 'Unavailable'
    $tpmPresent = $null
    $tpmEnabled = $null
    $tpmSpecVersion = $null
    $tpmMessage = ''

    try {
        $tpm = @(Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop)

        if ($tpm.Count -eq 0) {
            $tpmQueryStatus = 'Absent'
            $tpmPresent = $false
        }
        else {
            $tpmQueryStatus = 'Present'
            $tpmPresent = $true
            $enabled = Get-PropertyValue $tpm[0] 'IsEnabled_InitialValue'
            if ($null -ne $enabled) { $tpmEnabled = [bool]$enabled }
            $tpmSpecVersion = [string](Get-PropertyValue $tpm[0] 'SpecVersion')
        }
    }
    catch {
        $tpmMessage = $_.Exception.Message
        Write-Warning ("TPM state could not be determined: {0}" -f $tpmMessage)
    }

    $secureBootStatus = 'Unavailable'
    $secureBootEnabled = $null
    $secureBootMessage = ''

    if (-not (Test-CommandAvailable -Name 'Confirm-SecureBootUEFI')) {
        $secureBootStatus = 'NotSupported'
        $secureBootMessage = 'Confirm-SecureBootUEFI is not available on this system.'
    }
    else {
        try {
            $secureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
            $secureBootStatus = if ($secureBootEnabled) { 'Enabled' } else { 'Disabled' }
        }
        catch [System.PlatformNotSupportedException] {
            # Legacy BIOS: the platform genuinely cannot answer. That is a fact
            # about the device, not a collection failure, so it is not a warning.
            $secureBootStatus = 'NotSupported'
            $secureBootMessage = 'Secure Boot is not supported on this platform (legacy BIOS).'
        }
        catch {
            $secureBootMessage = $_.Exception.Message
            Write-Warning ("Secure Boot state could not be determined: {0}" -f $secureBootMessage)
        }
    }

    return , [ordered]@{
        RecordType         = 'Security'
        TpmQueryStatus     = $tpmQueryStatus
        TpmPresent         = $tpmPresent
        TpmEnabled         = $tpmEnabled
        TpmSpecVersion     = $tpmSpecVersion
        TpmMessage         = $tpmMessage
        SecureBootStatus   = $secureBootStatus
        SecureBootEnabled  = $secureBootEnabled
        SecureBootMessage  = $secureBootMessage
    }
}

function Get-DiskRecords {
    <#
    .SYNOPSIS
        Physical disks and volumes.
    .DESCRIPTION
        Prefers the Storage module because it reports media type, bus type and
        health, none of which Win32_DiskDrive exposes. Falls back to WMI on
        systems where the Storage module is absent, and records which source was
        used so a query can tell a thin record from a rich one.
    #>
    $records = New-Object System.Collections.ArrayList

    if (Test-CommandAvailable -Name 'Get-Disk') {
        $physical = @()
        try { $physical = @(Get-PhysicalDisk -ErrorAction Stop) }
        catch { Write-Warning ("Physical disk media type unavailable: {0}" -f $_.Exception.Message) }

        foreach ($disk in @(Get-Disk -ErrorAction Stop)) {
            $number = Get-PropertyValue $disk 'Number'
            $match = $physical | Where-Object { (Get-PropertyValue $_ 'DeviceId') -eq [string]$number } | Select-Object -First 1

            $null = $records.Add([ordered]@{
                RecordType            = 'Disk'
                DiskNumber            = [int](Get-PropertyValue $disk 'Number' -1)
                DiskFriendlyName      = [string](Get-PropertyValue $disk 'FriendlyName')
                DiskSerialNumber      = [string](Get-PropertyValue $disk 'SerialNumber')
                DiskMediaType         = [string](Get-PropertyValue $match 'MediaType')
                DiskBusType           = [string](Get-PropertyValue $disk 'BusType')
                DiskSizeBytes         = [int64](Get-PropertyValue $disk 'Size' 0)
                DiskHealthStatus      = [string](Get-PropertyValue $disk 'HealthStatus')
                DiskOperationalStatus = [string](Get-PropertyValue $disk 'OperationalStatus')
                DiskFirmwareVersion   = [string](Get-PropertyValue $disk 'FirmwareVersion')
                DiskPartitionStyle    = [string](Get-PropertyValue $disk 'PartitionStyle')
                DiskIsBoot            = [bool](Get-PropertyValue $disk 'IsBoot' $false)
                DiskDataSource        = 'StorageModule'
            })
        }
    }
    else {
        foreach ($drive in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)) {
            $null = $records.Add([ordered]@{
                RecordType            = 'Disk'
                DiskNumber            = [int](Get-PropertyValue $drive 'Index' -1)
                DiskFriendlyName      = [string](Get-PropertyValue $drive 'Model')
                DiskSerialNumber      = ([string](Get-PropertyValue $drive 'SerialNumber')).Trim()
                DiskMediaType         = [string](Get-PropertyValue $drive 'MediaType')
                DiskBusType           = [string](Get-PropertyValue $drive 'InterfaceType')
                DiskSizeBytes         = [int64](Get-PropertyValue $drive 'Size' 0)
                DiskHealthStatus      = [string](Get-PropertyValue $drive 'Status')
                DiskOperationalStatus = ''
                DiskFirmwareVersion   = [string](Get-PropertyValue $drive 'FirmwareRevision')
                DiskPartitionStyle    = ''
                DiskIsBoot            = $false
                DiskDataSource        = 'Win32_DiskDrive'
            })
        }
    }

    foreach ($volume in (Get-VolumeRecords)) { $null = $records.Add($volume) }

    return @($records)
}

function Get-VolumeRecords {
    $records = New-Object System.Collections.ArrayList

    if (Test-CommandAvailable -Name 'Get-Volume') {
        foreach ($volume in @(Get-Volume -ErrorAction Stop)) {
            $driveLetter = Get-PropertyValue $volume 'DriveLetter'
            $mountPoint = if ($driveLetter) { "{0}:" -f $driveLetter } else { [string](Get-PropertyValue $volume 'Path') }

            $null = $records.Add([ordered]@{
                RecordType         = 'Volume'
                VolumeMountPoint   = $mountPoint
                VolumeLabel        = [string](Get-PropertyValue $volume 'FileSystemLabel')
                VolumeFileSystem   = [string](Get-PropertyValue $volume 'FileSystem')
                VolumeSizeBytes    = [int64](Get-PropertyValue $volume 'Size' 0)
                VolumeFreeBytes    = [int64](Get-PropertyValue $volume 'SizeRemaining' 0)
                VolumeDriveType    = [string](Get-PropertyValue $volume 'DriveType')
                VolumeHealthStatus = [string](Get-PropertyValue $volume 'HealthStatus')
                VolumeDataSource   = 'StorageModule'
            })
        }
    }
    else {
        foreach ($logical in @(Get-CimInstance Win32_LogicalDisk -ErrorAction Stop)) {
            $null = $records.Add([ordered]@{
                RecordType         = 'Volume'
                VolumeMountPoint   = [string](Get-PropertyValue $logical 'DeviceID')
                VolumeLabel        = [string](Get-PropertyValue $logical 'VolumeName')
                VolumeFileSystem   = [string](Get-PropertyValue $logical 'FileSystem')
                VolumeSizeBytes    = [int64](Get-PropertyValue $logical 'Size' 0)
                VolumeFreeBytes    = [int64](Get-PropertyValue $logical 'FreeSpace' 0)
                VolumeDriveType    = [string](Get-PropertyValue $logical 'DriveType')
                VolumeHealthStatus = ''
                VolumeDataSource   = 'Win32_LogicalDisk'
            })
        }
    }

    return @($records)
}

function ConvertFrom-BitLockerProtectionStatus {
    param($Value)
    switch ([int]$Value) {
        0 { 'Off' }
        1 { 'On' }
        2 { 'Unknown' }
        default { 'Unknown' }
    }
}

function ConvertFrom-BitLockerConversionStatus {
    param($Value)
    switch ([int]$Value) {
        0 { 'FullyDecrypted' }
        1 { 'FullyEncrypted' }
        2 { 'EncryptionInProgress' }
        3 { 'DecryptionInProgress' }
        4 { 'EncryptionPaused' }
        5 { 'DecryptionPaused' }
        default { 'Unknown' }
    }
}

function ConvertFrom-BitLockerEncryptionMethod {
    param($Value)
    switch ([int]$Value) {
        0 { 'None' }
        1 { 'AES_128_WITH_DIFFUSER' }
        2 { 'AES_256_WITH_DIFFUSER' }
        3 { 'AES_128' }
        4 { 'AES_256' }
        5 { 'HardwareEncryption' }
        6 { 'XTS_AES_128' }
        7 { 'XTS_AES_256' }
        default { 'Unknown' }
    }
}

function ConvertFrom-BitLockerKeyProtectorType {
    param($Value)
    switch ([int]$Value) {
        0 { 'Unknown' }
        1 { 'Tpm' }
        2 { 'ExternalKey' }
        3 { 'RecoveryPassword' }
        4 { 'TpmAndPin' }
        5 { 'TpmAndStartupKey' }
        6 { 'TpmAndPinAndStartupKey' }
        7 { 'PublicKey' }
        8 { 'Passphrase' }
        9 { 'TpmCertificate' }
        10 { 'Sid' }
        default { 'Unknown' }
    }
}

function Get-BitLockerRecords {
    <#
    .SYNOPSIS
        BitLocker posture per volume.
    .DESCRIPTION
        SECURITY: this function reads protector TYPES only. Recovery passwords are
        deliberately never read. Get-BitLockerVolume returns KeyProtector objects
        that carry a RecoveryPassword property; only KeyProtectorType is touched,
        so no recovery key can reach the envelope, the spool, or Log Analytics.
        Key escrow is Intune's or AD's job, not this collector's.
    #>
    $records = New-Object System.Collections.ArrayList

    if (Test-CommandAvailable -Name 'Get-BitLockerVolume') {
        foreach ($volume in @(Get-BitLockerVolume -ErrorAction Stop)) {
            $protectorTypes = @()
            $protectors = Get-PropertyValue $volume 'KeyProtector'
            if ($protectors) {
                # KeyProtectorType ONLY. Never $_.RecoveryPassword.
                $protectorTypes = @($protectors |
                    ForEach-Object { [string](Get-PropertyValue $_ 'KeyProtectorType') } |
                    Where-Object { $_ } |
                    Sort-Object -Unique)
            }

            $percentage = Get-PropertyValue $volume 'EncryptionPercentage'

            $null = $records.Add([ordered]@{
                RecordType                    = 'BitLocker'
                BitLockerMountPoint           = [string](Get-PropertyValue $volume 'MountPoint')
                BitLockerVolumeType           = [string](Get-PropertyValue $volume 'VolumeType')
                BitLockerProtectionStatus     = [string](Get-PropertyValue $volume 'ProtectionStatus')
                BitLockerVolumeStatus         = [string](Get-PropertyValue $volume 'VolumeStatus')
                BitLockerEncryptionPercentage = if ($null -ne $percentage) { [int]$percentage } else { $null }
                BitLockerEncryptionMethod     = [string](Get-PropertyValue $volume 'EncryptionMethod')
                BitLockerKeyProtectorTypes    = ($protectorTypes -join ',')
                BitLockerAutoUnlockEnabled    = [bool](Get-PropertyValue $volume 'AutoUnlockEnabled' $false)
                BitLockerDataSource           = 'BitLockerModule'
            })
        }

        return @($records)
    }

    # Fallback for editions/images without the BitLocker PowerShell module.
    foreach ($volume in @(Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop)) {
        $protectorTypes = @()
        try {
            $protectorIds = Invoke-CimMethod -InputObject $volume -MethodName 'GetKeyProtectors' -Arguments @{ KeyProtectorType = [uint32]0 } -ErrorAction Stop
            foreach ($id in @(Get-PropertyValue $protectorIds 'VolumeKeyProtectorID' @())) {
                # GetKeyProtectorType returns a numeric type. The recovery password
                # itself would require GetKeyProtectorNumericalPassword, which is
                # never called.
                $typeResult = Invoke-CimMethod -InputObject $volume -MethodName 'GetKeyProtectorType' -Arguments @{ VolumeKeyProtectorID = [string]$id } -ErrorAction Stop
                $protectorTypes += (ConvertFrom-BitLockerKeyProtectorType (Get-PropertyValue $typeResult 'KeyProtectorType' 0))
            }
            $protectorTypes = @($protectorTypes | Sort-Object -Unique)
        }
        catch {
            Write-Warning ("BitLocker key protector types unavailable for {0}: {1}" -f
                [string](Get-PropertyValue $volume 'DriveLetter'), $_.Exception.Message)
        }

        $percentage = Get-PropertyValue $volume 'EncryptionPercentage'

        $null = $records.Add([ordered]@{
            RecordType                    = 'BitLocker'
            BitLockerMountPoint           = [string](Get-PropertyValue $volume 'DriveLetter')
            BitLockerVolumeType           = ''
            BitLockerProtectionStatus     = (ConvertFrom-BitLockerProtectionStatus (Get-PropertyValue $volume 'ProtectionStatus' 2))
            BitLockerVolumeStatus         = (ConvertFrom-BitLockerConversionStatus (Get-PropertyValue $volume 'ConversionStatus' -1))
            BitLockerEncryptionPercentage = if ($null -ne $percentage) { [int]$percentage } else { $null }
            BitLockerEncryptionMethod     = (ConvertFrom-BitLockerEncryptionMethod (Get-PropertyValue $volume 'EncryptionMethod' -1))
            BitLockerKeyProtectorTypes    = ($protectorTypes -join ',')
            BitLockerAutoUnlockEnabled    = $false
            BitLockerDataSource           = 'Win32_EncryptableVolume'
        })
    }

    return @($records)
}

# ---------------------------------------------------------------------------
# Guarded section runner
# ---------------------------------------------------------------------------

function Invoke-CollectionSection {
    <#
    .SYNOPSIS
        Runs one collector and returns its records plus a CollectionStatus record.
    .DESCRIPTION
        A failing area must never take down the whole run, and must never be
        represented by default values that read like a successful answer. The
        status record makes "this device did not report disks, and here is why"
        a queryable fact instead of an absence someone has to notice.
    #>
    param(
        [Parameter(Mandatory)] [string] $SectionName,
        [Parameter(Mandatory)] [scriptblock] $Collector
    )

    $records = New-Object System.Collections.ArrayList

    try {
        $collected = @(& $Collector)

        foreach ($record in $collected) {
            if ($null -ne $record) { $null = $records.Add($record) }
        }

        $status = if ($records.Count -gt 0) { 'Collected' } else { 'Empty' }
        $null = $records.Add((New-CollectionStatusRecord -SectionName $SectionName -Status $status -RecordCount $records.Count))
    }
    catch {
        $message = $_.Exception.Message
        Write-Warning ("Collection section '{0}' failed: {1}" -f $SectionName, $message)

        # Discard anything partial: a half-collected section is indistinguishable
        # from a complete one once it reaches the table.
        $records.Clear()
        $null = $records.Add((New-CollectionStatusRecord -SectionName $SectionName -Status 'Failed' -Message $message))
    }

    return @($records)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Verbose 'Resolving device identity...'
$identity = Get-DeviceIdentitySnapshot

Write-Verbose ("Selecting client certificate for device {0}..." -f $identity.EntraDeviceId)
$certificate = Get-ClientCertificate `
    -Thumbprint $CertificateThumbprint `
    -SubjectLike $CertificateSubjectLike `
    -IssuerLike $CertificateIssuerLike `
    -EntraDeviceId $identity.EntraDeviceId

$sections = [ordered]@{
    'OperatingSystem' = { Get-OperatingSystemRecord }
    'Hardware'        = { Get-HardwareRecord }
    'Security'        = { Get-SecurityRecord }
    'Disk'            = { Get-DiskRecords }
    'BitLocker'       = { Get-BitLockerRecords }
    'Network'         = { Get-NetworkRecords }
    'Software'        = { Get-SoftwareRecords }
}

$records = New-Object System.Collections.ArrayList
$failedSections = New-Object System.Collections.ArrayList

foreach ($sectionName in $sections.Keys) {
    if ($Collect -notcontains $sectionName) { continue }

    foreach ($record in (Invoke-CollectionSection -SectionName $sectionName -Collector $sections[$sectionName])) {
        $null = $records.Add($record)
        if ($record.RecordType -eq 'CollectionStatus' -and $record.SectionStatus -eq 'Failed') {
            $null = $failedSections.Add($sectionName)
        }
    }
}

if ($records.Count -eq 0) {
    throw 'No inventory records were collected; refusing to submit an empty envelope.'
}

$envelope = New-InventoryEnvelope `
    -TableName $TableName `
    -Records @($records) `
    -EntraDeviceId $identity.EntraDeviceId `
    -DeviceName $identity.DeviceName `
    -IntuneDeviceId $identity.IntuneDeviceId `
    -Source 'WindowsScheduledTask' `
    -Properties @{ CollectorVersion = $script:CollectorVersion; CollectedAreas = ($Collect -join ',') }

if ($WhatIfSubmission) {
    Write-Output ($envelope | ConvertTo-Json -Depth 24)
    return
}

$result = Invoke-InventorySubmission `
    -Uri $uri `
    -Envelope $envelope `
    -Certificate $certificate `
    -SpoolDirectory $SpoolDirectory `
    -MaxAttempts $MaxAttempts `
    -MaxSpoolAgeDays $MaxSpoolAgeDays

Write-Output ([pscustomobject]@{
    TableName       = $TableName
    Records         = $records.Count
    FailedSections  = (@($failedSections) -join ',')
    CollectorVersion = $script:CollectorVersion
    Disposition     = $result.Disposition
    StatusCode      = $result.StatusCode
    Spooled         = $result.Spooled
    Drained         = if ($result.Drain) { $result.Drain.Delivered } else { 0 }
})

# Non-zero exit on failure so the scheduled task's Last Run Result is meaningful
# to whatever monitors it; a silently "successful" task that never delivers is
# worse than no task at all. A partially collected but delivered run stays exit 0:
# the CollectionStatus records carry that detail to Log Analytics, and failing the
# task would hide a successful delivery behind a section-level problem.
if ($result.Disposition -ne 'Delivered') { exit 1 }
