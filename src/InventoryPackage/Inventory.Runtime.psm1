#Requires -Version 5.1
# Version 1.5.0. Optional metadata-only diagnostics; no activity on import.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Modules\LogCollector.Client.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Inventory.Collection.psm1') -ErrorAction Stop

function Get-InventoryConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $config = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    foreach ($key in @('PackageVersion', 'Environment', 'FrontendUrl', 'DeviceTableName', 'AppTableName', 'SubmissionEnabled',
        'CollectDeviceInventory', 'CollectAppInventory', 'CertificateThumbprint',
        'CertificateIssuerLike', 'MaxAttempts', 'TimeoutSeconds')) {
        if (-not $config.ContainsKey($key)) { throw "Missing package configuration: $key" }
    }
    foreach ($key in @('SubmissionEnabled', 'CollectDeviceInventory', 'CollectAppInventory')) {
        if ($config[$key] -isnot [bool]) { throw "$key must be a Boolean." }
    }
    foreach ($key in @('PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
        if (-not $config.ContainsKey($key)) { $config[$key] = @() }
        if ($null -eq $config[$key] -or ($config[$key] -isnot [string] -and $config[$key] -isnot [array])) {
            throw "$key must be an array of strings (use @() to disable the constraint)."
        }
        foreach ($entry in @($config[$key])) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) { throw "$key contains an invalid entry." }
            if ($key -like '*Thumbprints' -and ($entry -replace '[\s:]', '') -notmatch '^[0-9a-fA-F]{40}$') {
                throw "$key entries must be SHA1 certificate thumbprints (40 hexadecimal digits)."
            }
        }
        $config[$key] = @($config[$key])
    }
    foreach ($key in @('DeviceTableName', 'AppTableName')) {
        if ($config[$key] -isnot [string] -or $config[$key] -notmatch '^[A-Za-z][A-Za-z0-9_]{0,96}_CL$') {
            throw "$key must be a valid custom table name ending in _CL."
        }
    }
    if ([string]::IsNullOrWhiteSpace($config.FrontendUrl)) { throw 'Configure FrontendUrl for the destination deployment.' }
    $null = Get-LogCollectorSpoolPath -FrontendUrl $config.FrontendUrl
    if ($config.MaxAttempts -isnot [int] -or $config.MaxAttempts -lt 1 -or $config.MaxAttempts -gt 10) {
        throw 'MaxAttempts must be an integer between 1 and 10.'
    }
    if ($config.TimeoutSeconds -isnot [int] -or $config.TimeoutSeconds -lt 1 -or $config.TimeoutSeconds -gt 300) {
        throw 'TimeoutSeconds must be an integer between 1 and 300.'
    }
    return $config
}

function Get-InventorySubmissionBatch {
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)] [hashtable] $Properties,
        [Parameter(Mandatory)] [DateTimeOffset] $CollectedAtUtc
    )
    $empty = New-InventoryEnvelope -TableName $TableName -Records @() `
        -EntraDeviceId $Identity.EntraDeviceId -DeviceName $Identity.DeviceName `
        -IntuneDeviceId $Identity.IntuneDeviceId -Source 'WindowsCustomInventory' `
        -Properties $Properties -CollectedAtUtc $CollectedAtUtc
    $overhead = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $empty -Depth 24 -Compress))
    $batch = New-Object 'Collections.Generic.List[object]'
    $bytes = $overhead
    foreach ($record in $Records) {
        # Leave headroom for worker-owned metadata below its 850 KiB row limit.
        $json = ConvertTo-Json -InputObject $record -Depth 24 -Compress -ErrorAction Stop -WarningAction Stop
        $size = [Text.Encoding]::UTF8.GetByteCount($json)
        if ($size -gt 768000) { throw "A $TableName record exceeds the package's 750 KiB row limit." }
        if ($batch.Count -gt 0 -and ($batch.Count -ge 500 -or ($bytes + $size + 1) -gt 3145728)) {
            [pscustomobject]@{ TableName = $TableName; Records = $batch.ToArray() }
            $batch.Clear()
            $bytes = $overhead
        }
        $null = $batch.Add($record)
        $bytes += $size + 1
    }
    if ($batch.Count -gt 0) {
        [pscustomobject]@{ TableName = $TableName; Records = $batch.ToArray() }
    }
}

function Invoke-InventoryRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ConfigPath, [switch] $Preview, [switch] $QueueOnly, [scriptblock] $DiagnosticSink)
    if ($Preview -and $QueueOnly) { throw 'Use Preview or QueueOnly, not both.' }
    $config = Get-InventoryConfiguration -Path $ConfigPath
    if ($DiagnosticSink) {
        $null = & $DiagnosticSink 'ConfigurationLoaded' @{
            PackageVersion = $config.PackageVersion; Endpoint = $config.FrontendUrl
            ConfigurationSha256 = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
            SubmissionEnabled = $config.SubmissionEnabled; DeviceTableName = $config.DeviceTableName; AppTableName = $config.AppTableName
            RootConstraintCount = $config.PkiRootCaSubjects.Count + $config.PkiRootCaThumbprints.Count
            IntermediateConstraintCount = $config.PkiIntermediateCaSubjects.Count + $config.PkiIntermediateCaThumbprints.Count
        }
    }
    if (-not $Preview -and -not $QueueOnly -and -not $config.SubmissionEnabled) {
        if ($DiagnosticSink) { $null = & $DiagnosticSink 'SubmissionDisabled' @{ Stage = 'CollectAndSend' } }
        throw 'Submission is disabled: prepare the configured table schemas and DCR mappings first. Preview or QueueOnly remains available.'
    }
    $identity = Get-DeviceIdentitySnapshot -ErrorAction Stop
    $collectedAt = [DateTimeOffset]::UtcNow
    $inventory = Get-Inventory -Identity $identity `
        -CollectDeviceInventory $config.CollectDeviceInventory -CollectAppInventory $config.CollectAppInventory -DiagnosticSink $DiagnosticSink
    $properties = @{ CollectorVersion = $config.PackageVersion; Environment = $config.Environment }
    # Preflight both streams before the first network request.
    $batches = @(
        Get-InventorySubmissionBatch -TableName $config.DeviceTableName -Records @($inventory.DeviceRecords) `
            -Identity $identity -Properties $properties -CollectedAtUtc $collectedAt
        Get-InventorySubmissionBatch -TableName $config.AppTableName -Records @($inventory.AppRecords) `
            -Identity $identity -Properties $properties -CollectedAtUtc $collectedAt
    )
    if ($DiagnosticSink) {
        $null = & $DiagnosticSink 'CollectionCompleted' @{
            Stage = 'BatchPreflight'; DeviceRecords = @($inventory.DeviceRecords).Count
            AppRecords = @($inventory.AppRecords).Count; BatchCount = $batches.Count
        }
    }
    if ($Preview) {
        return [pscustomobject]@{
            Disposition = 'Preview'; DeviceRecords = @($inventory.DeviceRecords).Count
            AppRecords = @($inventory.AppRecords).Count; Batches = $batches.Count
        }
    }
    if ($QueueOnly) { Write-Warning 'QueueOnly: inventory will be retained locally, not sent to Azure.' }
    foreach ($batch in $batches) {
        $result = Send-LogCollectorData -FrontendUrl $config.FrontendUrl -TableName $batch.TableName `
            -Records $batch.Records -Source 'WindowsCustomInventory' -Properties $properties -CollectedAtUtc $collectedAt `
            -CertificateThumbprint $config.CertificateThumbprint -CertificateIssuerLike $config.CertificateIssuerLike `
            -PkiRootCaThumbprints $config.PkiRootCaThumbprints -PkiRootCaSubjects $config.PkiRootCaSubjects `
            -PkiIntermediateCaThumbprints $config.PkiIntermediateCaThumbprints -PkiIntermediateCaSubjects $config.PkiIntermediateCaSubjects `
            -MaxAttempts $config.MaxAttempts -TimeoutSeconds $config.TimeoutSeconds -QueueOnly:$QueueOnly -SkipDrain -DiagnosticSink $DiagnosticSink
        [pscustomobject]@{
            TableName = $batch.TableName; Records = $batch.Records.Count
            Disposition = $result.Disposition; StatusCode = $result.StatusCode
            Spooled = $result.Spooled; Message = $result.Message
        }
    }
}

function Invoke-InventoryDrain {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ConfigPath, [scriptblock] $DiagnosticSink)
    $config = Get-InventoryConfiguration -Path $ConfigPath
    if ($DiagnosticSink) {
        $null = & $DiagnosticSink 'ConfigurationLoaded' @{
            PackageVersion = $config.PackageVersion; Endpoint = $config.FrontendUrl
            ConfigurationSha256 = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
            SubmissionEnabled = $config.SubmissionEnabled
        }
    }
    if (-not $config.SubmissionEnabled) {
        if ($DiagnosticSink) { $null = & $DiagnosticSink 'SubmissionDisabled' @{ Stage = 'Drain' } }
        throw 'Spool submission is disabled until the original table mappings are ready.'
    }
    Sync-LogCollectorSpool -FrontendUrl $config.FrontendUrl `
        -CertificateThumbprint $config.CertificateThumbprint -CertificateIssuerLike $config.CertificateIssuerLike `
        -PkiRootCaThumbprints $config.PkiRootCaThumbprints -PkiRootCaSubjects $config.PkiRootCaSubjects `
        -PkiIntermediateCaThumbprints $config.PkiIntermediateCaThumbprints -PkiIntermediateCaSubjects $config.PkiIntermediateCaSubjects `
        -TimeoutSeconds $config.TimeoutSeconds -MaxAttemptsPerEntry $config.MaxAttempts -DiagnosticSink $DiagnosticSink
}

Export-ModuleMember -Function Get-InventoryConfiguration, Invoke-InventoryRun, Invoke-InventoryDrain
