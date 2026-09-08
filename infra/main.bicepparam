using './main.bicep'

// Sample parameter file. Replace the placeholders before deploying.
//
// The certificate parameters take base64-encoded DER (a PEM body with the
// -----BEGIN/END----- lines removed) of PUBLIC CA certificates only. Never put
// a private key, PFX password, or any other secret in this file.
//
// Export a CA certificate to base64 with:
//   [Convert]::ToBase64String((Get-Item Cert:\LocalMachine\Root\<thumbprint>).RawData)

param location = 'westeurope'
param appName = 'logcollector'
param environment = 'prod'
// Set this to a short customer/company code (e.g. 'aci') on first deployment to avoid
// colliding with an existing storage account / Function app name elsewhere in Azure.
// Letters, digits, spaces, hyphens or underscores only (max 8 chars).
// Leave empty ('') when redeploying an existing installation to keep its resource names.
param customerPrefix = ''

param frontendPlanSku = 'B1'
param inventoryQueueName = 'inventory-ingestion'
param payloadContainerName = 'inventory-payloads'
param nonceTableName = 'RequestNonces'
param inventoryTableName = 'InventoryWindows_CL'

param retentionInDays = 90
param payloadRetentionDays = 14

// --- Trust tier 1: enterprise PKI ---
param trustedRootCertificatesBase64 = '<base64-der-of-enterprise-root-ca>'
param trustedIntermediateCertificatesBase64 = '<base64-der-of-enterprise-issuing-ca>'
param trustedCaSubjects = ''
param trustedCaThumbprints = ''

// --- Trust tier 2: Intune enrollment certificate ---
// Leave the root empty to disable the tier entirely; the validator fails closed
// when a tier has no explicitly configured anchor.
param trustedIntuneRootCertificatesBase64 = ''
param trustedIntuneIntermediateCertificatesBase64 = ''
param allowIntuneEnrollmentCertificateFallback = true
param intuneEnrollmentIssuerSubjects = 'CN=Microsoft Intune MDM Device CA|CN=Microsoft Intune Device Management Device CA'

// --- Binding and anti-replay ---
param deviceIdBindingClaim = 'Auto'
param clientCertThumbprintToDeviceMap = ''
param checkRevocation = true
param maxTimestampSkewSeconds = 300
param nonceRetentionSeconds = 7200
param maxRequestBodyBytes = 4194304

param deleteBlobAfterIngestion = false

param tags = {
  application: 'LogCollector'
  environment: 'prod'
  owner: 'endpoint-engineering'
}
