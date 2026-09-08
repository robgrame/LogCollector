<#
.SYNOPSIS
Shared telemetry facade for independent Windows PowerShell scripts.
.NOTES
Version 1.5.0. Import the manifest; no authentication, I/O or network calls occur on import.
#>
Set-StrictMode -Version Latest

foreach ($dependency in @('DeviceIdentity', 'RequestSigning', 'InventorySpool', 'InventoryClient')) {
    Import-Module (Join-Path $PSScriptRoot "$dependency.psm1") -Scope Local -DisableNameChecking
}

function Assert-LogCollectorEndpoint {
    param([Uri] $FrontendUrl)

    if ($null -eq $FrontendUrl -or -not $FrontendUrl.IsAbsoluteUri -or
        $FrontendUrl.Scheme -ne 'https' -or $FrontendUrl.UserInfo -or
        $FrontendUrl.Query -or $FrontendUrl.Fragment -or
        @('/api/submit', '/api/inventory') -cnotcontains $FrontendUrl.AbsolutePath -or
        $FrontendUrl.OriginalString -cnotmatch '\A(?i:https)://[^/\\?#]+/api/(?:submit|inventory)\z') {
        throw 'FrontendUrl must be an absolute HTTPS /api/submit or /api/inventory URL without credentials, query or fragment.'
    }
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

Export-ModuleMember -Function Get-DeviceIdentitySnapshot, Get-ClientCertificate, New-SignedInventoryRequest, `
    New-InventoryEnvelope, Get-LogCollectorSpoolPath, Export-LogCollectorSchema, Send-LogCollectorData, `
    Sync-LogCollectorSpool
