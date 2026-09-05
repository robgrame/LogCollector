using './main.bicep'

param location = 'italynorth'
param appName = 'LogCollector'
param environment = 'prod'
param frontendPlanSku = 'B1'

// Public Microsoft Intune certificates from the reference implementation.
// Enterprise PKI trust remains empty until the customer's public CAs are supplied.
param trustedRootCertificatesBase64 = ''
param trustedIntermediateCertificatesBase64 = ''
param trustedIntuneRootCertificatesBase64 = loadTextContent('certificates/intune-root.base64')
param trustedIntuneIntermediateCertificatesBase64 = loadTextContent('certificates/intune-intermediate.base64')
param allowIntuneEnrollmentCertificateFallback = true
param checkRevocation = true
// The bundled Intune intermediate publishes no CRL/OCSP endpoints.
// Disable/remove the Entra device to deny access; PKI revocation remains enabled.
param skipIntuneRevocationCheck = true
