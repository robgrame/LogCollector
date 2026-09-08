@{
    RootModule = 'LogCollector.Client.psm1'
    ModuleVersion = '1.6.0'
    GUID = '4ca10d53-456c-4ce0-a860-14d4b6644db9'
    Author = 'LogCollector'
    Description = 'Shared certificate-authenticated telemetry client for Windows PowerShell scripts.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-DeviceIdentitySnapshot'
        'Get-ClientCertificate'
        'New-SignedInventoryRequest'
        'New-InventoryEnvelope'
        'Get-LogCollectorSpoolPath'
        'Export-LogCollectorSchema'
        'Send-LogCollectorData'
        'Sync-LogCollectorSpool'
        'Send-LogAnalyticsData'
        'Get-LogCollectorEndpointConfiguration'
        'Get-LogCollectorConfigurationPath'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    FileList = @(
        'LogCollector.Client.psd1'
        'LogCollector.Client.psm1'
        'EndpointConfiguration.psm1'
        'DeviceIdentity.psm1'
        'RequestSigning.psm1'
        'InventoryClient.psm1'
        'InventorySpool.psm1'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('Windows', 'Inventory', 'mTLS', 'LogAnalytics')
        }
    }
}
