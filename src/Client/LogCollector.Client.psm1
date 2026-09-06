<#
.SYNOPSIS
Shared telemetry facade for independent Windows PowerShell scripts.
.NOTES
Version 1.3.3. Import the manifest; no authentication, I/O or network calls occur on import.
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
    New-InventoryEnvelope, Get-LogCollectorSpoolPath, Send-LogCollectorData, Sync-LogCollectorSpool
