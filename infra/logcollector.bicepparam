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
