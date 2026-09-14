using './main.bicep'

param location = 'italynorth'
param appName = 'LogCollector'
param environment = 'prod'
param frontendPlanSku = 'B1'

// Purpose-specific tables in addition to the InventoryWindows_CL example.
// Provisions the Log Analytics table, the Custom-<name> DCR stream declaration,
// the pass-through data flow and the Ingestion__StreamMap entry on both apps.
// Keep this list authoritative: a table created out of band is reverted here.
param additionalTelemetryTables = [
  {
    name: 'DeviceInventory_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'CollectedAtUtc', type: 'datetime' }
      { name: 'EntraDeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'IntuneDeviceId', type: 'string' }
      { name: 'CorrelationId', type: 'string' }
      { name: 'RecordIndex', type: 'int' }
      { name: 'Source', type: 'string' }
      { name: 'ManagedDeviceName', type: 'string' }
      { name: 'AzureADDeviceID', type: 'string' }
      { name: 'ManagedDeviceID', type: 'string' }
      { name: 'ComputerName', type: 'string' }
      { name: 'Model', type: 'string' }
      { name: 'Manufacturer', type: 'string' }
      { name: 'PCSystemType', type: 'string' }
      { name: 'PCSystemTypeEx', type: 'string' }
      { name: 'ComputerUpTime', type: 'string' }
      { name: 'LastBoot', type: 'string' }
      { name: 'InstallDate', type: 'string' }
      { name: 'WindowsVersion', type: 'string' }
      { name: 'DefaultAUService', type: 'string' }
      { name: 'AUMetered', type: 'string' }
      { name: 'SystemSkuNumber', type: 'string' }
      { name: 'SerialNumber', type: 'string' }
      { name: 'SMBIOSUUID', type: 'string' }
      { name: 'BiosVersion', type: 'string' }
      { name: 'BiosDate', type: 'string' }
      { name: 'SystemSKU', type: 'string' }
      { name: 'FirmwareType', type: 'string' }
      { name: 'Memory', type: 'string' }
      { name: 'OSBuild', type: 'string' }
      { name: 'OSRevision', type: 'string' }
      { name: 'OSName', type: 'string' }
      { name: 'CPUManufacturer', type: 'string' }
      { name: 'CPUName', type: 'string' }
      { name: 'CPUCores', type: 'string' }
      { name: 'CPULogical', type: 'string' }
      { name: 'TPMReady', type: 'string' }
      { name: 'TPMPresent', type: 'string' }
      { name: 'TPMEnabled', type: 'string' }
      { name: 'TPMActived', type: 'string' }
      { name: 'TPMThumbprint', type: 'string' }
      { name: 'BitlockerCipher', type: 'string' }
      { name: 'BitlockerVolumeStatus', type: 'string' }
      { name: 'BitlockerProtectionStatus', type: 'string' }
      { name: 'NetworkAdapters', type: 'dynamic' }
      { name: 'DiskHealth', type: 'dynamic' }
    ]
  }
  {
    name: 'AppInventory_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'CollectedAtUtc', type: 'datetime' }
      { name: 'EntraDeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'IntuneDeviceId', type: 'string' }
      { name: 'CorrelationId', type: 'string' }
      { name: 'RecordIndex', type: 'int' }
      { name: 'Source', type: 'string' }
      { name: 'ComputerName', type: 'string' }
      { name: 'ManagedDeviceName', type: 'string' }
      { name: 'ManagedDeviceID', type: 'string' }
      { name: 'AppName', type: 'string' }
      { name: 'AppVersion', type: 'string' }
      { name: 'AppInstallDate', type: 'string' }
      { name: 'AppPublisher', type: 'string' }
      { name: 'AppUninstallString', type: 'string' }
      { name: 'AppUninstallRegPath', type: 'string' }
    ]
  }
  {
    name: 'LogCollectorOperations_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'CollectedAtUtc', type: 'datetime' }
      { name: 'EntraDeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'IntuneDeviceId', type: 'string' }
      { name: 'CorrelationId', type: 'string' }
      { name: 'RecordIndex', type: 'int' }
      { name: 'Source', type: 'string' }
      { name: 'PackageName', type: 'string' }
      { name: 'PackageVersion', type: 'string' }
      { name: 'ScriptName', type: 'string' }
      { name: 'EventName', type: 'string' }
      { name: 'Level', type: 'string' }
      { name: 'Message', type: 'string' }
      { name: 'ExecutionId', type: 'string' }
    ]
  }
  {
    name: 'CPUInfo_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'CollectedAtUtc', type: 'datetime' }
      { name: 'EntraDeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'IntuneDeviceId', type: 'string' }
      { name: 'CorrelationId', type: 'string' }
      { name: 'RecordIndex', type: 'int' }
      { name: 'Source', type: 'string' }
      { name: 'MachineName', type: 'string' }
      { name: 'ProcessorName', type: 'string' }
    ]
  }
  {
    name: 'StatoCertificazione2023_SecureBoot_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'CollectedAtUtc', type: 'datetime' }
      { name: 'EntraDeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'IntuneDeviceId', type: 'string' }
      { name: 'CorrelationId', type: 'string' }
      { name: 'RecordIndex', type: 'int' }
      { name: 'Source', type: 'string' }
      { name: 'Timestamp', type: 'string' }
      { name: 'ComputerName', type: 'string' }
      { name: 'RegistryKey', type: 'string' }
      { name: 'PropertyName', type: 'string' }
      { name: 'Value', type: 'string' }
    ]
  }
  {
    name: 'RegistrySecureBootEnforcement_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'CollectedAtUtc', type: 'datetime' }
      { name: 'EntraDeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'IntuneDeviceId', type: 'string' }
      { name: 'CorrelationId', type: 'string' }
      { name: 'RecordIndex', type: 'int' }
      { name: 'Source', type: 'string' }
      { name: 'ReportId', type: 'string' }
      { name: 'Hostname', type: 'string' }
      { name: 'ClientVersion', type: 'string' }
      { name: 'ScriptName', type: 'string' }
      { name: 'Phase', type: 'string' }
      { name: 'Action', type: 'string' }
      { name: 'ResumeSwitch', type: 'boolean' }
      { name: 'DryRun', type: 'boolean' }
      { name: 'AvailableUpdates', type: 'long' }
      { name: 'AvailableUpdatesHex', type: 'string' }
      { name: 'UEFICA2023Status', type: 'string' }
      { name: 'UEFICA2023Error', type: 'long' }
      { name: 'LastBootUpTimeUtc', type: 'string' }
      { name: 'TPMWmiEventsCount', type: 'int' }
      { name: 'TPMWmiSuccessCount', type: 'int' }
      { name: 'TPMWmiFailureCount', type: 'int' }
      { name: 'TPMWmiWarningCount', type: 'int' }
      { name: 'TPMWmiCA2023Count', type: 'int' }
      { name: 'TPMWmiEvents', type: 'string' }
      { name: 'Details', type: 'dynamic' }
    ]
  }
  {
    name: 'SecureBootInventory_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'CollectedAtUtc', type: 'datetime' }
      { name: 'EntraDeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'IntuneDeviceId', type: 'string' }
      { name: 'CorrelationId', type: 'string' }
      { name: 'RecordIndex', type: 'int' }
      { name: 'Source', type: 'string' }
      { name: 'ReportId', type: 'string' }
      { name: 'ClientVersion', type: 'string' }
      { name: 'MachineName', type: 'string' }
      { name: 'DomainName', type: 'string' }
      { name: 'Manufacturer', type: 'string' }
      { name: 'Model', type: 'string' }
      { name: 'SystemFamily', type: 'string' }
      { name: 'SystemSKUNumber', type: 'string' }
      { name: 'BIOSVersion', type: 'string' }
      { name: 'BIOSName', type: 'string' }
      { name: 'BIOSManufacturer', type: 'string' }
      { name: 'BIOSReleaseDate', type: 'string' }
      { name: 'SMBIOSMajorVersion', type: 'int' }
      { name: 'SMBIOSMinorVersion', type: 'int' }
      { name: 'BaseBoardManufacturer', type: 'string' }
      { name: 'BaseBoardProduct', type: 'string' }
      { name: 'BaseBoardVersion', type: 'string' }
      { name: 'OperatingSystem', type: 'string' }
      { name: 'OSVersion', type: 'string' }
      { name: 'OSBuildNumber', type: 'string' }
      { name: 'OSArchitecture', type: 'string' }
      { name: 'IsVirtualMachine', type: 'boolean' }
      { name: 'VirtualizationPlatform', type: 'string' }
      { name: 'SecureBootEnabled', type: 'boolean' }
      { name: 'UEFISecureBootEnabled', type: 'long' }
      { name: 'UefiCa2023Status', type: 'string' }
      { name: 'UefiCa2023Error', type: 'long' }
      { name: 'WindowsUEFICA2023Capable', type: 'long' }
      { name: 'HighConfidenceOptOut', type: 'long' }
      { name: 'MicrosoftUpdateManagedOptIn', type: 'long' }
      { name: 'ConfidenceLevel', type: 'long' }
      { name: 'SbatLevel', type: 'string' }
      { name: 'SbatUpdateStatus', type: 'string' }
      { name: 'TotalCertificateCount', type: 'int' }
      { name: 'PKCertificateCount', type: 'int' }
      { name: 'KEKCertificateCount', type: 'int' }
      { name: 'DBCertificateCount', type: 'int' }
      { name: 'DBXHashCount', type: 'long' }
      { name: 'PKCertificates', type: 'string' }
      { name: 'KEKCertificates', type: 'string' }
      { name: 'DBCertificates', type: 'string' }
      { name: 'CertificateEnumerationError', type: 'string' }
      { name: 'UpdateEventsTotalCount', type: 'int' }
      { name: 'DBUpdateAttempts', type: 'int' }
      { name: 'DBXUpdateAttempts', type: 'int' }
      { name: 'KEKUpdateAttempts', type: 'int' }
      { name: 'SuccessfulUpdates', type: 'int' }
      { name: 'FailedUpdates', type: 'int' }
      { name: 'LastDBUpdateTime', type: 'string' }
      { name: 'LastDBXUpdateTime', type: 'string' }
      { name: 'LastKEKUpdateTime', type: 'string' }
      { name: 'LastSuccessfulUpdateTime', type: 'string' }
      { name: 'LastFailedUpdateTime', type: 'string' }
      { name: 'EventsLookbackDays', type: 'int' }
      { name: 'CA2023UpdateStatus', type: 'string' }
      { name: 'CA2023EventsCount', type: 'int' }
      { name: 'HasKEKCA2023', type: 'boolean' }
      { name: 'HasOptionROMCA2023', type: 'boolean' }
      { name: 'HasUEFICA2023', type: 'boolean' }
      { name: 'HasBootManagerCA2023', type: 'boolean' }
      { name: 'HasUpdateComplete', type: 'boolean' }
      { name: 'SecureBootUpdateEvents', type: 'string' }
    ]
  }
]

// Public Microsoft Intune certificates from the reference implementation.
// Enterprise PKI trust remains empty until the customer's public CAs are supplied.
param trustedRootCertificatesBase64 = ''
param trustedIntermediateCertificatesBase64 = ''
// Optional PKI chain-role constraints; Intune enrollment trust is independent.
param pkiRootCaThumbprints = ''
param pkiRootCaSubjects = ''
param pkiIntermediateCaThumbprints = ''
param pkiIntermediateCaSubjects = ''
param trustedIntuneRootCertificatesBase64 = loadTextContent('certificates/intune-root.base64')
param trustedIntuneIntermediateCertificatesBase64 = loadTextContent('certificates/intune-intermediate.base64')
param allowIntuneEnrollmentCertificateFallback = true
param checkRevocation = true
// The bundled Intune intermediate publishes no CRL/OCSP endpoints.
// Disable/remove the Entra device to deny access; PKI revocation remains enabled.
param skipIntuneRevocationCheck = true
