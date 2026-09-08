@{
    PackageVersion = '1.5.0'
    Environment = ''
    FrontendUrl = ''
    DeviceTableName = 'DeviceInventory_CL'
    AppTableName = 'AppInventory_CL'
    # The package builder supplies the endpoint. Enable only after server mappings are ready.
    SubmissionEnabled = $false
    CollectDeviceInventory = $true
    CollectAppInventory = $true
    CertificateThumbprint = ''
    CertificateIssuerLike = ''
    PkiRootCaThumbprints = @()
    PkiRootCaSubjects = @()
    PkiIntermediateCaThumbprints = @()
    PkiIntermediateCaSubjects = @()
    MaxAttempts = 3
    TimeoutSeconds = 30
}
