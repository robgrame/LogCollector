targetScope = 'resourceGroup'

// =============================================================================
// LogCollector - secure Windows inventory ingestion.
//
//   Windows client  --mTLS + signed body-->  Frontend Function App (Linux B1,
//   Always On, client certificates REQUIRED)  --blob + pointer-->  Service Bus
//   Standard  -->  Worker Function App (.NET 10 isolated, Flex Consumption)
//   -->  Azure Monitor Logs Ingestion API / DCR  -->  Log Analytics custom table
//
// Design constraints encoded here:
//   * The frontend is on a dedicated B1 plan because Flex Consumption does not
//     support clientCertEnabled, and mandatory client certificates are the whole
//     authentication model. Always On keeps the mTLS listener warm.
//   * The worker is on Flex Consumption because it is purely event-driven and
//     benefits from scale-to-zero. It has no HTTP surface at all.
//   * There is no Function key and no shared secret. Every service-to-service
//     hop uses a user-assigned managed identity with a least-privilege role.
//   * Shared key access to storage is disabled, so an exfiltrated connection
//     string is not a credential that exists to be stolen.
// =============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short application name used as the resource-name prefix.')
@minLength(3)
@maxLength(12)
param appName string = 'logcollector'

@description('Environment discriminator appended to resource names.')
@allowed(['dev', 'test', 'prod'])
param environment string = 'prod'

@description('Frontend App Service plan SKU. B1 is the user-selected ingress tier.')
@allowed(['B1', 'B2', 'B3', 'S1', 'S2', 'S3', 'P1v3', 'P2v3', 'P3v3'])
param frontendPlanSku string = 'B1'

@description('Service Bus queue carrying blob pointer messages.')
param inventoryQueueName string = 'inventory-ingestion'

@description('Blob container holding submitted inventory payloads.')
param payloadContainerName string = 'inventory-payloads'

@description('Azure Table used for the distributed replay-nonce store.')
param nonceTableName string = 'RequestNonces'

@description('Primary Log Analytics custom table for Windows inventory.')
param inventoryTableName string = 'InventoryWindows_CL'

@description('Interactive retention (days) for the workspace and the custom table.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Days a submitted payload blob is retained before lifecycle deletion.')
@minValue(1)
@maxValue(365)
param payloadRetentionDays int = 14

// --- Client certificate trust (base64 DER, comma/semicolon/pipe separated) ---
// Supplied at deployment time from the enterprise PKI. Certificates are public
// data; no secret material is ever placed in these parameters.

@description('Base64 DER of the enterprise PKI ROOT CA certificate(s). Trust anchors.')
param trustedRootCertificatesBase64 string = ''

@description('Base64 DER of the enterprise PKI intermediate CA certificate(s). Path hints only.')
param trustedIntermediateCertificatesBase64 string = ''

@description('Base64 DER of the Intune MDM Device CA ROOT certificate(s). Enables the Intune enrollment tier.')
param trustedIntuneRootCertificatesBase64 string = ''

@description('Base64 DER of the Intune MDM Device CA intermediate certificate(s).')
param trustedIntuneIntermediateCertificatesBase64 string = ''

@description('Optional pipe-separated CA subject DNs that must appear in the chain.')
param trustedCaSubjects string = ''

@description('Optional comma-separated CA thumbprints that must appear in the chain.')
param trustedCaThumbprints string = ''

@description('Allow the Intune enrollment certificate as a second trust tier.')
param allowIntuneEnrollmentCertificateFallback bool = true

@description('Pipe-separated allow-list of Intune enrollment issuer subject DNs.')
param intuneEnrollmentIssuerSubjects string = 'CN=Microsoft Intune MDM Device CA|CN=Microsoft Intune Device Management Device CA'

@description('How the certificate is bound to an Entra device id.')
@allowed(['Auto', 'SubjectCN', 'SanDns', 'SanUri', 'Thumbprint', 'IntuneEnrollmentOid'])
param deviceIdBindingClaim string = 'Auto'

@description('Optional pipe-separated thumbprint=deviceId overrides for PKI templates without an embedded device id.')
param clientCertThumbprintToDeviceMap string = ''

@description('Perform online CRL/OCSP revocation checking on the client certificate chain.')
param checkRevocation bool = true

@description('Maximum accepted clock skew, in seconds, for X-Request-Timestamp.')
@minValue(30)
@maxValue(3600)
param maxTimestampSkewSeconds int = 300

@description('How long a nonce stays reserved, in seconds.')
@minValue(60)
@maxValue(86400)
param nonceRetentionSeconds int = 7200

@description('Maximum accepted request body size in bytes.')
@minValue(1024)
param maxRequestBodyBytes int = 4194304

@description('Delete the payload blob immediately after successful ingestion. Off by default so the lifecycle policy governs retention.')
param deleteBlobAfterIngestion bool = false

@description('Resource tags.')
param tags object = {
  application: 'LogCollector'
  environment: environment
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

var suffix = uniqueString(resourceGroup().id, appName, environment)
var namePrefix = '${appName}-${environment}'

var storageAccountName = take(toLower(replace('${appName}${environment}st${suffix}', '-', '')), 24)
var serviceBusNamespaceName = '${namePrefix}-sb-${take(suffix, 6)}'
var workspaceName = '${namePrefix}-law'
var appInsightsName = '${namePrefix}-appi'
var dceName = '${namePrefix}-dce'
var dcrName = '${namePrefix}-dcr'
var frontendPlanName = '${namePrefix}-frontend-plan'
var workerPlanName = '${namePrefix}-worker-plan'
var frontendAppName = '${namePrefix}-frontend-${take(suffix, 6)}'
var workerAppName = '${namePrefix}-worker-${take(suffix, 6)}'
var frontendIdentityName = '${namePrefix}-frontend-id'
var workerIdentityName = '${namePrefix}-worker-id'

var frontendDeployContainer = 'frontend-deploy'
var workerDeployContainer = 'worker-deploy'

var inventoryStreamName = 'Custom-${inventoryTableName}'
var ingestionStreamMap = '${inventoryTableName}=${inventoryStreamName}'

// Built-in role definition ids.
var roleBlobDataOwner = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var roleQueueDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var roleTableDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
var roleServiceBusSender = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39')
var roleServiceBusReceiver = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0')
var roleMonitoringMetricsPublisher = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
var roleMonitoringReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')

// The flat column set emitted by InventoryRowFactory plus every field the
// collector script produces. Column names are unique across record types on
// purpose: reusing one name with two types (for example a datetime OS install
// date and a string software install date) makes the table unqueryable.
var inventoryColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'CollectedAtUtc', type: 'datetime' }
  { name: 'EntraDeviceId', type: 'string' }
  { name: 'DeviceName', type: 'string' }
  { name: 'IntuneDeviceId', type: 'string' }
  { name: 'CorrelationId', type: 'string' }
  { name: 'RecordIndex', type: 'int' }
  { name: 'Source', type: 'string' }
  { name: 'RecordType', type: 'string' }
  { name: 'CollectorVersion', type: 'string' }
  { name: 'CollectedAreas', type: 'string' }
  { name: 'Caption', type: 'string' }
  { name: 'Version', type: 'string' }
  { name: 'BuildNumber', type: 'string' }
  { name: 'Architecture', type: 'string' }
  { name: 'OsInstallDate', type: 'datetime' }
  { name: 'LastBootUpTime', type: 'datetime' }
  { name: 'Locale', type: 'string' }
  { name: 'Manufacturer', type: 'string' }
  { name: 'Model', type: 'string' }
  { name: 'SerialNumber', type: 'string' }
  { name: 'BiosVersion', type: 'string' }
  { name: 'TotalPhysicalMemoryBytes', type: 'long' }
  { name: 'LogicalProcessors', type: 'int' }
  { name: 'ProcessorName', type: 'string' }
  { name: 'ChassisType', type: 'string' }
  { name: 'DisplayName', type: 'string' }
  { name: 'DisplayVersion', type: 'string' }
  { name: 'Publisher', type: 'string' }
  { name: 'SoftwareInstallDate', type: 'string' }
  { name: 'RegistryView', type: 'string' }
  { name: 'Description', type: 'string' }
  { name: 'MacAddress', type: 'string' }
  { name: 'IpAddresses', type: 'string' }
  { name: 'DhcpEnabled', type: 'boolean' }
  { name: 'DnsDomain', type: 'string' }
  { name: 'TpmPresent', type: 'boolean' }
  { name: 'TpmEnabled', type: 'boolean' }
  { name: 'TpmSpecVersion', type: 'string' }
  { name: 'SecureBootEnabled', type: 'boolean' }
  { name: 'DiskNumber', type: 'int' }
  { name: 'DiskFriendlyName', type: 'string' }
  { name: 'DiskSerialNumber', type: 'string' }
  { name: 'DiskMediaType', type: 'string' }
  { name: 'DiskBusType', type: 'string' }
  { name: 'DiskSizeBytes', type: 'long' }
  { name: 'DiskHealthStatus', type: 'string' }
  { name: 'DiskOperationalStatus', type: 'string' }
  { name: 'DiskFirmwareVersion', type: 'string' }
  { name: 'DiskPartitionStyle', type: 'string' }
  { name: 'DiskIsBoot', type: 'boolean' }
  { name: 'DiskDataSource', type: 'string' }
  { name: 'VolumeMountPoint', type: 'string' }
  { name: 'VolumeLabel', type: 'string' }
  { name: 'VolumeFileSystem', type: 'string' }
  { name: 'VolumeSizeBytes', type: 'long' }
  { name: 'VolumeFreeBytes', type: 'long' }
  { name: 'VolumeDriveType', type: 'string' }
  { name: 'VolumeHealthStatus', type: 'string' }
  { name: 'VolumeDataSource', type: 'string' }
  { name: 'BitLockerMountPoint', type: 'string' }
  { name: 'BitLockerVolumeType', type: 'string' }
  { name: 'BitLockerProtectionStatus', type: 'string' }
  { name: 'BitLockerVolumeStatus', type: 'string' }
  { name: 'BitLockerEncryptionPercentage', type: 'int' }
  { name: 'BitLockerEncryptionMethod', type: 'string' }
  { name: 'BitLockerKeyProtectorTypes', type: 'string' }
  { name: 'BitLockerAutoUnlockEnabled', type: 'boolean' }
  { name: 'BitLockerDataSource', type: 'string' }
  { name: 'SectionName', type: 'string' }
  { name: 'SectionStatus', type: 'string' }
  { name: 'SectionRecordCount', type: 'int' }
  { name: 'SectionMessage', type: 'string' }
  { name: 'TpmQueryStatus', type: 'string' }
  { name: 'TpmMessage', type: 'string' }
  { name: 'SecureBootStatus', type: 'string' }
  { name: 'SecureBootMessage', type: 'string' }
]

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource inventoryTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: inventoryTableName
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    totalRetentionInDays: retentionInDays
    schema: {
      name: inventoryTableName
      columns: inventoryColumns
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Logs Ingestion: data collection endpoint + rule
// ---------------------------------------------------------------------------

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${inventoryStreamName}': {
        columns: inventoryColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: 'inventoryWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ inventoryStreamName ]
        destinations: [ 'inventoryWorkspace' ]
        // 'source' passes rows through unchanged. Column selection already
        // happened client-side in InventoryRowFactory.
        transformKql: 'source'
        outputStream: inventoryStreamName
      }
    ]
  }
  dependsOn: [
    inventoryTable
  ]
}

resource dcrDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'ingestion-errors'
  scope: dcr
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        category: 'LogErrors'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Storage: payload blobs, deployment packages, replay nonce table
// ---------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // appName is >= 3 characters and environment is >= 3, so the truncated name is
  // always well above the 3-character minimum; the analyzer cannot prove it.
  #disable-next-line BCP334
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Identity-only data plane. A connection string that does not work is a
    // credential that cannot leak.
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true }
        table: { enabled: true }
        queue: { enabled: true }
        file: { enabled: true }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource payloadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: payloadContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource frontendDeploy 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: frontendDeployContainer
  properties: {
    publicAccess: 'None'
  }
}

resource workerDeploy 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: workerDeployContainer
  properties: {
    publicAccess: 'None'
  }
}

// Retention backstop. The worker may or may not delete payloads after ingestion
// (see deleteBlobAfterIngestion); this rule guarantees an upper bound either way,
// so an ingestion outage cannot grow the account without limit.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-inventory-payloads'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [ payloadContainerName ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterCreationGreaterThan: payloadRetentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
  dependsOn: [
    payloadContainer
  ]
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource nonceTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: nonceTableName
}

// ---------------------------------------------------------------------------
// Service Bus (Standard) - pointer messages only
// ---------------------------------------------------------------------------

resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: serviceBusNamespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    minimumTlsVersion: '1.2'
    // Local (SAS) auth disabled: the only way in is Entra + RBAC.
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource inventoryQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBus
  name: inventoryQueueName
  properties: {
    // Long enough for a large multi-chunk ingestion, with lock renewal on top.
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P7D'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    // Duplicate detection covers repeated sends with the same MessageId during
    // this window; consumers still use at-least-once delivery semantics.
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'PT1H'
    enablePartitioning: false
    requiresSession: false
    maxSizeInMegabytes: 5120
  }
}

// ---------------------------------------------------------------------------
// Managed identities
// ---------------------------------------------------------------------------

resource frontendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: frontendIdentityName
  location: location
  tags: tags
}

resource workerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: workerIdentityName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Role assignments (least privilege)
// ---------------------------------------------------------------------------

// Frontend: needs Blob Data Owner on the account because the Functions host uses
// AzureWebJobsStorage for its own leases and singleton locks, which requires
// container creation rights that Contributor does not grant.
resource raFrontendBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, frontendIdentity.id, 'blob-owner')
  scope: storage
  properties: {
    roleDefinitionId: roleBlobDataOwner
    principalId: frontendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raFrontendQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, frontendIdentity.id, 'queue')
  scope: storage
  properties: {
    roleDefinitionId: roleQueueDataContributor
    principalId: frontendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raFrontendTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, frontendIdentity.id, 'table')
  scope: storage
  properties: {
    roleDefinitionId: roleTableDataContributor
    principalId: frontendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Send only. The frontend must never be able to read or delete queue messages.
resource raFrontendServiceBus 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(inventoryQueue.id, frontendIdentity.id, 'sb-send')
  scope: inventoryQueue
  properties: {
    roleDefinitionId: roleServiceBusSender
    principalId: frontendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raWorkerBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, workerIdentity.id, 'blob-owner')
  scope: storage
  properties: {
    roleDefinitionId: roleBlobDataOwner
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raWorkerQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, workerIdentity.id, 'queue')
  scope: storage
  properties: {
    roleDefinitionId: roleQueueDataContributor
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raWorkerTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, workerIdentity.id, 'table')
  scope: storage
  properties: {
    roleDefinitionId: roleTableDataContributor
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Receive only. The worker must never be able to inject pointer messages.
resource raWorkerServiceBus 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(inventoryQueue.id, workerIdentity.id, 'sb-receive')
  scope: inventoryQueue
  properties: {
    roleDefinitionId: roleServiceBusReceiver
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Metrics Publisher on the DCR is exactly the permission the Logs
// Ingestion API checks. It is scoped to this DCR, not the workspace, so the
// worker can only write the streams declared above.
resource raWorkerDcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, workerIdentity.id, 'metrics-publisher')
  scope: dcr
  properties: {
    roleDefinitionId: roleMonitoringMetricsPublisher
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raWorkerDce 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dce.id, workerIdentity.id, 'monitoring-reader')
  scope: dce
  properties: {
    roleDefinitionId: roleMonitoringReader
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Frontend: Linux B1, Always On, mandatory client certificates
// ---------------------------------------------------------------------------

resource frontendPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: frontendPlanName
  location: location
  tags: tags
  sku: {
    name: frontendPlanSku
    tier: startsWith(frontendPlanSku, 'B') ? 'Basic' : (startsWith(frontendPlanSku, 'S') ? 'Standard' : 'PremiumV3')
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource frontendApp 'Microsoft.Web/sites@2023-12-01' = {
  name: frontendAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${frontendIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: frontendPlan.id
    httpsOnly: true
    // The authentication model. App Service performs the TLS client-certificate
    // handshake and forwards the leaf in X-ARR-ClientCert; the function then
    // re-validates the chain itself rather than trusting the edge alone.
    clientCertEnabled: true
    clientCertMode: 'Required'
    // Only the unauthenticated liveness probe is exempt. Anything added here
    // bypasses mTLS by path prefix, so the list must stay minimal.
    clientCertExclusionPaths: '/api/health'
    keyVaultReferenceIdentity: frontendIdentity.id
    siteConfig: {
      linuxFxVersion: 'DOTNET-ISOLATED|10.0'
      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/api/health'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: frontendIdentity.properties.clientId }
        { name: 'AZURE_CLIENT_ID', value: frontendIdentity.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }

        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${serviceBus.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential', value: 'managedidentity' }
        { name: 'ServiceBus__clientId', value: frontendIdentity.properties.clientId }
        { name: 'ServiceBus__InventoryQueue', value: inventoryQueueName }

        { name: 'Storage__AccountName', value: storage.name }
        { name: 'Storage__PayloadContainer', value: payloadContainerName }

        { name: 'Replay__StorageAccount', value: storage.name }
        { name: 'Replay__TableName', value: nonceTableName }
        { name: 'Replay__MaxTimestampSkewSeconds', value: string(maxTimestampSkewSeconds) }
        { name: 'Replay__NonceRetentionSeconds', value: string(nonceRetentionSeconds) }

        { name: 'RequestSignature__Required', value: 'true' }
        { name: 'RequestSignature__MaxBodyBytes', value: string(maxRequestBodyBytes) }

        { name: 'ClientCert__RequireClientCert', value: 'true' }
        { name: 'ClientCert__RequireClientAuthEku', value: 'true' }
        { name: 'ClientCert__RequireDeviceBinding', value: 'true' }
        { name: 'ClientCert__TrustForwardedHeader', value: 'true' }
        { name: 'ClientCert__DeviceIdBindingClaim', value: deviceIdBindingClaim }
        { name: 'ClientCert__TrustedRootCertificates', value: trustedRootCertificatesBase64 }
        { name: 'ClientCert__TrustedIntermediateCertificates', value: trustedIntermediateCertificatesBase64 }
        { name: 'ClientCert__TrustedIntuneRootCertificates', value: trustedIntuneRootCertificatesBase64 }
        { name: 'ClientCert__TrustedIntuneIntermediateCertificates', value: trustedIntuneIntermediateCertificatesBase64 }
        { name: 'ClientCert__TrustedCaSubjects', value: trustedCaSubjects }
        { name: 'ClientCert__TrustedCaThumbprints', value: trustedCaThumbprints }
        { name: 'ClientCert__AllowIntuneEnrollmentCertificateFallback', value: string(allowIntuneEnrollmentCertificateFallback) }
        { name: 'ClientCert__IntuneEnrollmentIssuerSubjects', value: intuneEnrollmentIssuerSubjects }
        { name: 'ClientCert__ThumbprintToDeviceMap', value: clientCertThumbprintToDeviceMap }
        { name: 'ClientCert__CheckRevocation', value: string(checkRevocation) }
        { name: 'ClientCert__RevocationMode', value: 'Online' }
        { name: 'ClientCert__RevocationFlag', value: 'ExcludeRoot' }

        { name: 'Ingestion__StreamMap', value: ingestionStreamMap }
        { name: 'Intake__MaxRecordsPerEnvelope', value: '50000' }
      ]
    }
  }
  dependsOn: [
    raFrontendBlob
    raFrontendQueue
    raFrontendTable
    raFrontendServiceBus
    nonceTable
    payloadContainer
  ]
}

// ---------------------------------------------------------------------------
// Worker: .NET 10 isolated on Flex Consumption
// ---------------------------------------------------------------------------

resource workerPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: workerPlanName
  location: location
  tags: tags
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource workerApp 'Microsoft.Web/sites@2023-12-01' = {
  name: workerAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${workerIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: workerPlan.id
    httpsOnly: true
    keyVaultReferenceIdentity: workerIdentity.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${workerDeployContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: workerIdentity.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
        // On-demand scaling, including scale-to-zero. Always-ready instances
        // are an optional latency/cost choice, not a managed-identity requirement.
        alwaysReady: []
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: workerIdentity.properties.clientId }
        { name: 'AZURE_CLIENT_ID', value: workerIdentity.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }

        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${serviceBus.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential', value: 'managedidentity' }
        { name: 'ServiceBus__clientId', value: workerIdentity.properties.clientId }
        { name: 'ServiceBus__InventoryQueue', value: inventoryQueueName }

        { name: 'Storage__AccountName', value: storage.name }
        { name: 'Storage__PayloadContainer', value: payloadContainerName }

        { name: 'Ingestion__DataCollectionEndpoint', value: dce.properties.logsIngestion.endpoint }
        { name: 'Ingestion__DataCollectionRuleId', value: dcr.properties.immutableId }
        { name: 'Ingestion__StreamMap', value: ingestionStreamMap }
        { name: 'Ingestion__MaxChunkBytes', value: '870400' }
        { name: 'Ingestion__MaxAttempts', value: '5' }
        { name: 'Ingestion__BaseRetryDelayMs', value: '1000' }
        { name: 'Ingestion__MaxRetryDelaySeconds', value: '60' }
        { name: 'Ingestion__DeleteBlobAfterIngestion', value: string(deleteBlobAfterIngestion) }
        { name: 'Intake__MaxRecordsPerEnvelope', value: '50000' }
      ]
    }
  }
  dependsOn: [
    raWorkerBlob
    raWorkerQueue
    raWorkerTable
    raWorkerServiceBus
    raWorkerDcr
    raWorkerDce
    workerDeploy
    payloadContainer
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output frontendAppName string = frontendApp.name
output frontendIngestUrl string = 'https://${frontendApp.properties.defaultHostName}/api/inventory'
output frontendHealthUrl string = 'https://${frontendApp.properties.defaultHostName}/api/health'
output workerAppName string = workerApp.name
output storageAccountName string = storage.name
output serviceBusNamespace string = serviceBus.name
output inventoryQueueName string = inventoryQueueName
output logAnalyticsWorkspaceName string = workspace.name
output logAnalyticsWorkspaceId string = workspace.id
output dataCollectionEndpoint string = dce.properties.logsIngestion.endpoint
output dataCollectionRuleImmutableId string = dcr.properties.immutableId
output inventoryStream string = inventoryStreamName
output frontendIdentityClientId string = frontendIdentity.properties.clientId
output workerIdentityClientId string = workerIdentity.properties.clientId
output frontendDeployContainerName string = frontendDeployContainer
output workerDeployContainerName string = workerDeployContainer
