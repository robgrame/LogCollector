<#
.SYNOPSIS
Shared telemetry facade for independent Windows PowerShell scripts.
.NOTES
Version 1.5.0. Import the manifest; no authentication, I/O or network calls occur on import.
#>
Set-StrictMode -Version Latest

foreach ($dependency in @('EndpointConfiguration', 'DeviceIdentity', 'RequestSigning', 'InventorySpool', 'InventoryClient')) {
    Import-Module (Join-Path $PSScriptRoot "$dependency.psm1") -Scope Local -DisableNameChecking
}

function Get-LogCollectorSpoolPath {
    <#
    .SYNOPSIS
    Returns an endpoint-specific spool path without creating it.
    .DESCRIPTION
    All scripts using this endpoint and root share a queue. Changing endpoints never
    silently redirects a previous endpoint's retained telemetry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $FrontendUrl,
        [string] $SpoolRoot = 'C:\ProgramData\LogCollector\SharedSpool'
    )
    Assert-LogCollectorEndpoint -FrontendUrl $FrontendUrl
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($FrontendUrl.AbsoluteUri)
        $bucket = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    return (Join-Path $SpoolRoot $bucket)
}

function Resolve-LogCollectorCertificate {
    param(
        [string] $DeviceId,
        [string] $Thumbprint,
        [string] $SubjectLike,
        [string] $IssuerLike,
        [string[]] $PkiRootCaThumbprints = @(),
        [string[]] $PkiRootCaSubjects = @(),
        [string[]] $PkiIntermediateCaThumbprints = @(),
        [string[]] $PkiIntermediateCaSubjects = @()
    )

    try {
        return Get-ClientCertificate -EntraDeviceId $DeviceId -Thumbprint $Thumbprint `
            -SubjectLike $SubjectLike -IssuerLike $IssuerLike `
            -PkiRootCaThumbprints $PkiRootCaThumbprints -PkiRootCaSubjects $PkiRootCaSubjects `
            -PkiIntermediateCaThumbprints $PkiIntermediateCaThumbprints `
            -PkiIntermediateCaSubjects $PkiIntermediateCaSubjects -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'LogCollector.ClientCertificateNotFound*') { throw }
        # Only expected certificate absence is deferred. Store/provider/programming failures propagate.
        return $null
    }
}

function Assert-LogCollectorLocalOutputPath {
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('//', [StringComparison]::Ordinal)) {
        throw 'OutputPath must be on a local fixed drive; UNC and device paths are not allowed.'
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'OutputPath must resolve to a local fixed drive.'
    }
    $drive = New-Object IO.DriveInfo($root)
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'OutputPath must be on a local fixed drive; removable and network drives are not allowed.'
    }

    $relative = $fullPath.Substring($root.Length)
    $current = $root
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($segment in @($relative.Split($separators, [StringSplitOptions]::RemoveEmptyEntries))) {
        $current = [IO.Path]::Combine($current, $segment)
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.LinkType) {
                throw "OutputPath cannot contain a symbolic link, junction or other reparse point: $current"
            }
        }
        catch [Management.Automation.ItemNotFoundException] { break }
    }

    return $fullPath
}

function Get-LogCollectorJsonType {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [Enum]) { return 'number' }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) { return 'number' }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [datetime] -or
        $Value -is [DateTimeOffset] -or $Value -is [guid] -or $Value -is [uri]) { return 'string' }
    if ($Value -is [Collections.IDictionary]) { return 'object' }
    if ($Value -is [Collections.IEnumerable]) { return 'array' }
    return 'object'
}

function Assert-LogCollectorCaseCollisions {
    param(
        [Parameter(Mandatory)] [object[]] $Records,
        [hashtable] $Properties
    )

    $protected = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('TimeGenerated', 'CollectedAtUtc', 'EntraDeviceId', 'DeviceName',
            'IntuneDeviceId', 'CorrelationId', 'Source', 'RecordIndex')) {
        $null = $protected.Add($name)
    }

    $batchSpellings = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $Records.Count; $index++) {
        $record = $Records[$index]
        if ($null -eq $record -or $record -is [string] -or $record -is [ValueType] -or
            (($record -is [Collections.IEnumerable]) -and -not ($record -is [Collections.IDictionary]))) {
            throw "Record at index $index must be an object or dictionary."
        }

        $exact = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $folded = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $recordNames = if ($record -is [Collections.IDictionary]) {
            @($record.Keys | ForEach-Object { [string]$_ })
        }
        else {
            @($record.PSObject.Properties | Where-Object IsGettable | ForEach-Object Name)
        }

        foreach ($name in $recordNames) {
            if ($protected.Contains($name)) { continue }
            $existingSpelling = $null
            if ($batchSpellings.TryGetValue($name, [ref]$existingSpelling)) {
                if (-not [string]::Equals($existingSpelling, $name, [StringComparison]::Ordinal)) {
                    throw "Records contain columns that differ only by letter case: '$existingSpelling' and '$name'."
                }
            }
            else {
                $batchSpellings[$name] = $name
            }
            if (-not $exact.Add($name)) {
                throw "Record at index $index contains duplicate column '$name'."
            }
            if (-not $folded.Add($name)) {
                throw "Record at index $index contains columns that differ only by letter case: '$name'."
            }
        }

        if ($Properties) {
            foreach ($key in $Properties.Keys) {
                $name = [string]$key
                if ($protected.Contains($name) -or $exact.Contains($name)) { continue }
                $existingSpelling = $null
                if ($batchSpellings.TryGetValue($name, [ref]$existingSpelling)) {
                    if (-not [string]::Equals($existingSpelling, $name, [StringComparison]::Ordinal)) {
                        throw "Records and Properties contain columns that differ only by letter case: '$existingSpelling' and '$name'."
                    }
                }
                else {
                    $batchSpellings[$name] = $name
                }
                if ($folded.Contains($name)) {
                    throw "Record at index $index and Properties contain columns that differ only by letter case: '$name'."
                }
            }
        }
    }
}

function Export-LogCollectorSchema {
    <#
    .SYNOPSIS
    Exports representative final rows for the Azure Monitor custom-table/DCR wizard.
    .DESCRIPTION
    Uses the same records supplied to Send-LogCollectorData, adds the columns normally
    asserted by the Worker, and writes a UTF-8 JSON array. It does not access device
    identity, certificates, the network or Azure, and it does not create a DCR.
    .PARAMETER Records
    Representative objects produced by the collector. Include non-null values for every
    property so that Azure Monitor can infer the intended schema.
    .PARAMETER OutputPath
    Destination JSON file to upload as sample data in the Azure portal.
    .PARAMETER MaxRecords
    Maximum representative records to export. Multiple records can describe heterogeneous
    rows, but every resulting column must still have one stable type.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [object[]] $Records,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Source,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OutputPath,
        [hashtable] $Properties,
        [ValidateRange(1, 100)] [int] $MaxRecords = 10,
        [switch] $Force
    )

    if ([IO.Path]::GetExtension($OutputPath) -ine '.json') {
        throw 'OutputPath must have a .json extension.'
    }
    $fullPath = Assert-LogCollectorLocalOutputPath -Path $OutputPath
    if ($Properties -and $Properties.Count -gt 32) {
        throw 'Properties exceeds the maximum of 32 entries.'
    }
    Assert-LogCollectorCaseCollisions -Records $Records -Properties $Properties

    $reserved = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('TimeGenerated', 'CollectedAtUtc', 'EntraDeviceId', 'DeviceName',
            'IntuneDeviceId', 'CorrelationId', 'Source', 'RecordIndex')) {
        $null = $reserved.Add($name)
    }
    $azureReserved = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('_ResourceId', 'id', '_SubscriptionId', 'TenantId', 'Type', 'UniqueId', 'Title',
            'BilledSize', 'IsBillable', 'InvalidTimeGenerated', '_ItemId', '_ResourceGroup', '_TimeReceived')) {
        $null = $azureReserved.Add($name)
    }

    $rows = New-Object 'Collections.Generic.List[object]'
    $columnTypes = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $sampledRecords = @($Records | Select-Object -First $MaxRecords)
    for ($index = 0; $index -lt $sampledRecords.Count; $index++) {
        $record = $sampledRecords[$index]
        if ($null -eq $record -or $record -is [string] -or $record -is [ValueType] -or
            (($record -is [Collections.IEnumerable]) -and -not ($record -is [Collections.IDictionary]))) {
            throw "Record at index $index must be an object or dictionary."
        }

        $row = [ordered]@{}
        $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        if ($record -is [Collections.IDictionary]) {
            foreach ($key in $record.Keys) {
                $propertyName = [string]$key
                if ([string]::IsNullOrWhiteSpace($propertyName) -or $reserved.Contains($propertyName)) { continue }
                if ($propertyName -cnotmatch '^[A-Za-z][A-Za-z0-9_]{1,44}$' -or $azureReserved.Contains($propertyName)) {
                    throw "Record column '$propertyName' is not valid for an Azure Monitor custom table."
                }
                if (-not $names.Add($propertyName)) {
                    throw "Record at index $index contains duplicate column '$propertyName'."
                }
                $row[$propertyName] = $record[$key]
            }
        }
        else {
            foreach ($property in $record.PSObject.Properties) {
                if (-not $property.IsGettable -or $reserved.Contains($property.Name)) { continue }
                if ($property.Name -cnotmatch '^[A-Za-z][A-Za-z0-9_]{1,44}$' -or $azureReserved.Contains($property.Name)) {
                    throw "Record column '$($property.Name)' is not valid for an Azure Monitor custom table."
                }
                if (-not $names.Add($property.Name)) {
                    throw "Record at index $index contains duplicate column '$($property.Name)'."
                }
                $row[$property.Name] = $property.Value
            }
        }

        if ($Properties) {
            foreach ($key in $Properties.Keys) {
                $propertyName = [string]$key
                if ([string]::IsNullOrWhiteSpace($propertyName) -or $reserved.Contains($propertyName) -or
                    $names.Contains($propertyName)) { continue }
                if ($propertyName -cnotmatch '^[A-Za-z][A-Za-z0-9_]{1,44}$' -or $azureReserved.Contains($propertyName)) {
                    throw "Property column '$propertyName' is not valid for an Azure Monitor custom table."
                }
                $row[$propertyName] = [string]$Properties[$key]
                $null = $names.Add($propertyName)
            }
        }

        $now = [DateTimeOffset]::UtcNow.ToString('O')
        $row['TimeGenerated'] = $now
        $row['CollectedAtUtc'] = $now
        $row['EntraDeviceId'] = '00000000-0000-0000-0000-000000000000'
        $row['DeviceName'] = 'SCHEMA-EXAMPLE'
        $row['IntuneDeviceId'] = '00000000-0000-0000-0000-000000000000'
        $row['CorrelationId'] = '00000000000000000000000000000000'
        $row['Source'] = $Source
        $row['RecordIndex'] = $index

        foreach ($columnName in $row.Keys) {
            $jsonType = Get-LogCollectorJsonType -Value $row[$columnName]
            if ($null -eq $jsonType) { continue }
            $existingType = $null
            if ($columnTypes.TryGetValue($columnName, [ref]$existingType)) {
                if (-not [string]::Equals($existingType, $jsonType, [StringComparison]::Ordinal)) {
                    throw "Column '$columnName' has incompatible JSON types '$existingType' and '$jsonType' across records."
                }
            }
            else {
                $columnTypes[$columnName] = $jsonType
            }
        }

        $rows.Add([pscustomobject]$row)
    }

    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) {
        throw "Schema sample already exists: $fullPath. Use -Force to replace it."
    }
    $directory = Split-Path -Parent $fullPath
    if ($PSCmdlet.ShouldProcess($fullPath, "Export schema sample for $TableName")) {
        if (-not (Test-Path -LiteralPath $directory)) {
            $null = [IO.Directory]::CreateDirectory($directory)
        }
        $fullPath = Assert-LogCollectorLocalOutputPath -Path $fullPath
        $json = ConvertTo-Json -InputObject ([object[]]$rows.ToArray()) -Depth 24
        [IO.File]::WriteAllText($fullPath, $json, (New-Object Text.UTF8Encoding($false)))
    }

    [pscustomobject]@{
        TableName = $TableName
        StreamName = "Custom-$TableName"
        OutputPath = $fullPath
        RecordCount = $rows.Count
        ColumnNames = @($rows[0].PSObject.Properties.Name)
    }
}

function Send-LogCollectorData {
    <#
    .SYNOPSIS
    Sends existing record objects through the intake, retaining temporary failures locally.
    .DESCRIPTION
    Does not collect inventory, change device state, install tasks or exit the caller.
    A usable Entra identity is required even in QueueOnly mode; no identity is invented.
    Delivered means HTTP 202 accepted by intake, not completed Log Analytics ingestion.
    .PARAMETER QueueOnly
    Persist locally without looking for a certificate or making an HTTP request.
    .PARAMETER SpoolRoot
    Protected local root. An endpoint-specific subdirectory is always used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $FrontendUrl,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [object[]] $Records,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Source,
        [hashtable] $Properties,
        [DateTimeOffset] $CollectedAtUtc = [DateTimeOffset]::UtcNow,
        [string] $CertificateThumbprint,
        [string] $CertificateSubjectLike,
        [string] $CertificateIssuerLike,
        [string[]] $PkiRootCaThumbprints = @(),
        [string[]] $PkiRootCaSubjects = @(),
        [string[]] $PkiIntermediateCaThumbprints = @(),
        [string[]] $PkiIntermediateCaSubjects = @(),
        [string] $SpoolRoot = 'C:\ProgramData\LogCollector\SharedSpool',
        [ValidateRange(1, 10)] [int] $MaxAttempts = 3,
        [ValidateRange(1, 300)] [int] $TimeoutSeconds = 30,
        [ValidateRange(1, 900)] [int] $MaxDelaySeconds = 60,
        [ValidateRange(1, 500)] [int] $MaxDrainEntries = 10,
        [ValidateRange(1, 10)] [int] $MaxDrainAttempts = 2,
        [ValidateRange(1, 365)] [int] $MaxSpoolAgeDays = 7,
        [ValidateRange(1, 100000)] [int] $MaxSpoolEntries = 500,
        [ValidateRange(1, 2147483647)] [int] $MaxSpoolTotalBytes = 67108864,
        [switch] $QueueOnly,
        [switch] $SkipDrain,
        [scriptblock] $DiagnosticSink
    )
    Assert-LogCollectorCaseCollisions -Records $Records -Properties $Properties
    $spool = Get-LogCollectorSpoolPath -FrontendUrl $FrontendUrl -SpoolRoot $SpoolRoot
    $identity = Get-DeviceIdentitySnapshot -ErrorAction Stop
    $envelopeVersion = if ($FrontendUrl.AbsolutePath -ceq '/api/submit') {
        'LOGCOLLECTOR-TELEMETRY-V1'
    } else {
        'LOGCOLLECTOR-INVENTORY-V1'
    }
    $envelope = New-InventoryEnvelope -TableName $TableName -Records $Records `
        -EntraDeviceId $identity.EntraDeviceId -DeviceName $identity.DeviceName `
        -IntuneDeviceId $identity.IntuneDeviceId -Source $Source `
        -Properties $Properties -CollectedAtUtc $CollectedAtUtc -EnvelopeVersion $envelopeVersion
    $certificate = $null
    try {
        if (-not $QueueOnly) {
            if ($DiagnosticSink) { $null = & $DiagnosticSink 'CertificateSelectionStarted' @{ EntraDeviceId = $identity.EntraDeviceId } }
            $certificate = Resolve-LogCollectorCertificate -DeviceId $identity.EntraDeviceId `
                -Thumbprint $CertificateThumbprint -SubjectLike $CertificateSubjectLike -IssuerLike $CertificateIssuerLike `
                -PkiRootCaThumbprints $PkiRootCaThumbprints -PkiRootCaSubjects $PkiRootCaSubjects `
                -PkiIntermediateCaThumbprints $PkiIntermediateCaThumbprints `
                -PkiIntermediateCaSubjects $PkiIntermediateCaSubjects
            if ($DiagnosticSink) {
                if ($null -eq $certificate) { $null = & $DiagnosticSink 'CertificateUnavailable' @{} }
                else {
                    $null = & $DiagnosticSink 'CertificateSelected' @{
                        CertificateThumbprint = $certificate.Thumbprint
                        CertificateNotAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
                    }
                }
            }
        }
        $result = Invoke-InventorySubmission -Uri $FrontendUrl -Envelope $envelope -Certificate $certificate `
            -SpoolDirectory $spool -MaxAttempts $MaxAttempts -TimeoutSeconds $TimeoutSeconds `
            -MaxDelaySeconds $MaxDelaySeconds -MaxDrainEntries $MaxDrainEntries -MaxDrainAttempts $MaxDrainAttempts `
            -MaxSpoolAgeDays $MaxSpoolAgeDays -MaxSpoolEntries $MaxSpoolEntries -MaxSpoolTotalBytes $MaxSpoolTotalBytes `
            -QueueOnly:$QueueOnly -SkipDrain:$SkipDrain -DiagnosticSink $DiagnosticSink
        $result | Add-Member -NotePropertyName SpoolDirectory -NotePropertyValue $spool
        return $result
    }
    finally {
        if ($null -ne $certificate) { $certificate.Dispose() }
    }
}

function Sync-LogCollectorSpool {
    <#
    .SYNOPSIS
    Retries retained telemetry without re-running any collection or remediation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $FrontendUrl,
        [string] $CertificateThumbprint,
        [string] $CertificateSubjectLike,
        [string] $CertificateIssuerLike,
        [string[]] $PkiRootCaThumbprints = @(),
        [string[]] $PkiRootCaSubjects = @(),
        [string[]] $PkiIntermediateCaThumbprints = @(),
        [string[]] $PkiIntermediateCaSubjects = @(),
        [string] $SpoolRoot = 'C:\ProgramData\LogCollector\SharedSpool',
        [ValidateRange(1, 500)] [int] $MaxEntriesPerRun = 10,
        [ValidateRange(1, 10)] [int] $MaxAttemptsPerEntry = 2,
        [ValidateRange(1, 300)] [int] $TimeoutSeconds = 30,
        [ValidateRange(1, 900)] [int] $MaxDelaySeconds = 60,
        [ValidateRange(1, 365)] [int] $MaxSpoolAgeDays = 7,
        [ValidateRange(1, 100000)] [int] $MaxSpoolEntries = 500,
        [ValidateRange(1, 2147483647)] [int] $MaxSpoolTotalBytes = 67108864,
        [scriptblock] $DiagnosticSink
    )
    $spool = Get-LogCollectorSpoolPath -FrontendUrl $FrontendUrl -SpoolRoot $SpoolRoot
    $null = Initialize-SpoolDirectory -SpoolDirectory $spool
    $identity = Get-DeviceIdentitySnapshot -ErrorAction Stop
    if ($DiagnosticSink) { $null = & $DiagnosticSink 'CertificateSelectionStarted' @{ EntraDeviceId = $identity.EntraDeviceId } }
    $certificate = Resolve-LogCollectorCertificate -DeviceId $identity.EntraDeviceId `
        -Thumbprint $CertificateThumbprint -SubjectLike $CertificateSubjectLike -IssuerLike $CertificateIssuerLike `
        -PkiRootCaThumbprints $PkiRootCaThumbprints -PkiRootCaSubjects $PkiRootCaSubjects `
        -PkiIntermediateCaThumbprints $PkiIntermediateCaThumbprints `
        -PkiIntermediateCaSubjects $PkiIntermediateCaSubjects
    try {
        if ($DiagnosticSink) {
            if ($null -eq $certificate) { $null = & $DiagnosticSink 'CertificateUnavailable' @{} }
            else {
                $null = & $DiagnosticSink 'CertificateSelected' @{
                    CertificateThumbprint = $certificate.Thumbprint
                    CertificateNotAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
                }
            }
        }
        $result = Invoke-InventorySpoolDrain -Uri $FrontendUrl -Certificate $certificate -SpoolDirectory $spool `
            -MaxEntriesPerRun $MaxEntriesPerRun -MaxAttemptsPerEntry $MaxAttemptsPerEntry `
            -TimeoutSeconds $TimeoutSeconds -MaxDelaySeconds $MaxDelaySeconds `
            -MaxSpoolAgeDays $MaxSpoolAgeDays -MaxSpoolEntries $MaxSpoolEntries -MaxSpoolTotalBytes $MaxSpoolTotalBytes `
            -DiagnosticSink $DiagnosticSink
        $result | Add-Member -NotePropertyName SpoolDirectory -NotePropertyValue $spool
        return $result
    }
    finally {
        if ($null -ne $certificate) { $certificate.Dispose() }
    }
}

function ConvertTo-LogCollectorRecords {
    <#
    .SYNOPSIS
    Normalises a legacy Data Collector API body into record objects.
    .DESCRIPTION
    Call sites pass whatever the old API accepted: a JSON string, the UTF-8 bytes of a
    JSON string, or objects. All three must keep working, so each is reduced to an array
    of records here rather than at every call site.
    #>
    param([Parameter(Mandatory)] [object] $Body)

    $value = $Body
    if ($value -is [byte[]]) {
        # The old API took the UTF-8 bytes of the JSON document, not the objects.
        $value = [Text.Encoding]::UTF8.GetString($value)
    }
    if ($value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'Body is empty; there is nothing to send.' }
        try { $value = ConvertFrom-Json -InputObject $value -ErrorAction Stop }
        catch { throw "Body is not valid JSON: $($_.Exception.Message)" }
    }
    $records = @($value)
    if ($records.Count -eq 0) { throw 'Body contains no records; there is nothing to send.' }
    # Emitted bare: the pipeline unrolls it, and the caller re-wraps with @() so a
    # single-record body is still an array. Do not add a unary comma here as well.
    return $records
}

function Resolve-LogCollectorTableName {
    <#
    .SYNOPSIS
    Turns a legacy Log-Type into a Log Analytics custom table name.
    .DESCRIPTION
    The Data Collector API appended '_CL' server-side, so existing scripts pass a bare
    name such as 'DeviceInventory'. Accept both spellings rather than making every
    caller change a string that already works.
    #>
    param([Parameter(Mandatory)] [string] $LogType)

    $name = $LogType.Trim()
    if (-not $name) { throw 'LogType is empty.' }
    if ($name -notmatch '_CL$') { $name = $name + '_CL' }
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,96}_CL$') {
        throw ("LogType '$LogType' does not map to a valid custom table name. Use letters, " +
            'digits and underscores, starting with a letter.')
    }
    return $name
}

function Send-LogAnalyticsData {
    <#
    .SYNOPSIS
    Sends records to Log Analytics from any script, with no workspace key on the device.
    .DESCRIPTION
    Drop-in replacement for the Send-LogAnalyticsData function that scripts used to carry
    inline against the HTTP Data Collector API. The original signature still binds, so an
    existing call site keeps working unchanged, but delivery now goes through the
    LogCollector intake authenticated by this device's own certificate.

    The -customerId and -sharedKey parameters are accepted and IGNORED. Nothing is sent to
    *.ods.opinsights.azure.com, so a workspace key is no longer needed on the device and
    should be deleted from the calling script. The key is never logged or echoed.

    The returned object stringifies to the legacy '<status> : <detail>' form, so existing
    checks such as `if ($response -match "200 :")` keep working, while `.Disposition`,
    `.StatusCode` and `.SubmissionId` are available for new code.

    Delivered means the intake accepted the batch, not that Log Analytics ingestion has
    completed. When the endpoint cannot be reached the batch is retained in the shared
    spool and reported as Deferred, not silently dropped.
    .PARAMETER LogType
    Destination table. '_CL' is appended when absent, matching the old API's behaviour.
    .PARAMETER Body
    Records to send: a JSON string, the UTF-8 bytes of a JSON string, or objects.
    .PARAMETER FrontendUrl
    Intake endpoint. Defaults to the machine-wide configuration written by the core package.
    .PARAMETER Source
    Identifies the producing script in the emitted records. Defaults to the caller's file name.
    .PARAMETER CustomerId
    Ignored. Accepted so existing call sites bind unchanged.
    .PARAMETER SharedKey
    Ignored, never logged, and no longer required. Remove it from the calling script.
    .EXAMPLE
    Send-LogAnalyticsData -LogType 'W11Upgrade' -Body ($events | ConvertTo-Json)
    .EXAMPLE
    $r = Send-LogAnalyticsData -customerId $id -sharedKey $key -body $json -logType 'DeviceInventory'
    if ($r -match '200 :') { 'ok' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogType,
        [Parameter(Mandatory)] [object] $Body,
        [string] $CustomerId,
        [string] $SharedKey,
        [Uri] $FrontendUrl,
        [string] $Source,
        [hashtable] $Properties,
        [switch] $QueueOnly,
        [scriptblock] $DiagnosticSink
    )

    # Gated on presence alone, not on the value: an unmigrated caller passing an empty or
    # null key is still an unmigrated caller and must be surfaced.
    if ($PSBoundParameters.ContainsKey('SharedKey')) {
        Write-Warning ('Send-LogAnalyticsData: -SharedKey is ignored. This device authenticates ' +
            'with its own certificate. Remove the workspace key from the calling script.')
    }
    if ($PSBoundParameters.ContainsKey('CustomerId') -and $CustomerId) {
        Write-Verbose 'Send-LogAnalyticsData: -CustomerId is ignored; the destination workspace is fixed by the data collection rule.'
    }

    $tableName = Resolve-LogCollectorTableName -LogType $LogType
    $records = @(ConvertTo-LogCollectorRecords -Body $Body)

    $configuration = $null
    if (-not $FrontendUrl) {
        $configuration = Get-LogCollectorEndpointConfiguration
        $FrontendUrl = [Uri] $configuration.FrontendUrl
    }
    Assert-LogCollectorEndpoint -FrontendUrl $FrontendUrl

    # A fleet can be staged before the server-side table mappings exist. Retaining the batch
    # in the spool keeps those records for later delivery instead of discarding them.
    $queueOnly = [bool] $QueueOnly
    if ($configuration -and $configuration.PSObject.Properties['SubmissionEnabled'] -and
        -not $configuration.SubmissionEnabled) {
        $queueOnly = $true
        Write-Verbose 'Send-LogAnalyticsData: SubmissionEnabled is false; the batch is spooled for later delivery.'
    }

    if (-not $Source) {
        # Identify the producing script, so one table can carry several scripts' records.
        $caller = @(Get-PSCallStack)[1]
        $Source = if ($caller -and $caller.ScriptName) { Split-Path $caller.ScriptName -Leaf } else { 'PowerShell' }
    }

    $arguments = @{
        FrontendUrl = $FrontendUrl
        TableName   = $tableName
        Records     = $records
        Source      = $Source
    }
    if ($Properties) { $arguments['Properties'] = $Properties }
    if ($queueOnly) { $arguments['QueueOnly'] = $true }
    if ($DiagnosticSink) { $arguments['DiagnosticSink'] = $DiagnosticSink }
    foreach ($setting in @('CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
            'PkiRootCaThumbprints', 'PkiRootCaSubjects', 'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects')) {
        if ($configuration -and $configuration.PSObject.Properties[$setting] -and $configuration.$setting) {
            $arguments[$setting] = $configuration.$setting
        }
    }

    if (-not $PSCmdlet.ShouldProcess("$FrontendUrl -> $tableName", "Send $($records.Count) record(s)")) { return }

    # Measured before the call so the reported size is the caller's payload, independent of
    # whatever framing the transport adds.
    $payloadBytes = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $records -Depth 10 -Compress))

    $result = Send-LogCollectorData @arguments

    # The legacy contract is a string tested with -match "200 :". Returning an object whose
    # ToString() reproduces that keeps those tests working while exposing real detail.
    $statusCode = if ($result.Disposition -eq 'Delivered') { 200 } else { 202 }
    $kilobytes = [math]::Round($payloadBytes / 1KB, 1)
    $detail = "Upload payload size is $kilobytes Kb ($($result.Disposition))"

    $response = [pscustomobject] @{
        StatusCode         = $statusCode
        Disposition        = $result.Disposition
        TableName          = $tableName
        RecordCount        = $records.Count
        PayloadBytes       = $payloadBytes
        Source             = $Source
        Message            = $result.Message
        IntakeStatusCode   = $result.StatusCode
        Detail             = $detail
        Result             = $result
    }
    $response | Add-Member -MemberType ScriptMethod -Name ToString -Force -Value {
        '{0} : {1}' -f $this.StatusCode, $this.Detail
    }
    return $response
}

Export-ModuleMember -Function Get-DeviceIdentitySnapshot, Get-ClientCertificate, New-SignedInventoryRequest, `
    New-InventoryEnvelope, Get-LogCollectorSpoolPath, Export-LogCollectorSchema, Send-LogCollectorData, `
    Sync-LogCollectorSpool, Send-LogAnalyticsData, Get-LogCollectorEndpointConfiguration, `
    Get-LogCollectorConfigurationPath
