<#
.SYNOPSIS
    LogCollector inventory client: envelope construction, signed submission,
    exponential backoff with jitter, and durable spool draining.

.DESCRIPTION
    Public surface:

      New-InventoryEnvelope        Builds the LOGCOLLECTOR-INVENTORY-V1 body.
      Get-RetryDelaySeconds        Backoff schedule (exponential + full jitter).
      Get-SubmissionDisposition    Maps an HTTP status to a retry decision.
      Send-InventoryEnvelope       Signs and POSTs one envelope, with retries.
      Invoke-InventorySpoolDrain   Drains previously spooled envelopes.
      Invoke-InventorySubmission   Drain-then-send entry point for the task.

    There is no API key parameter anywhere in this module. The client certificate
    is the credential: it authenticates the TLS connection, signs the body, and
    binds the submission to one Entra device id. Adding a Function key would
    reintroduce a fleet-wide shared secret without adding any assurance.

.NOTES
    Windows PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

$script:ModuleRoot = Split-Path -Parent $PSCommandPath

# Deliberately NOT -Force. Import-Module -Force removes an already-loaded copy of
# the target module from the *caller's* session before reloading it into this
# module's scope, which silently unloads DeviceIdentity/InventorySpool for any
# script that imported them alongside this one.
Import-Module (Join-Path $script:ModuleRoot 'DeviceIdentity.psm1') -DisableNameChecking
Import-Module (Join-Path $script:ModuleRoot 'RequestSigning.psm1') -DisableNameChecking
Import-Module (Join-Path $script:ModuleRoot 'InventorySpool.psm1') -DisableNameChecking

$script:EnvelopeVersion = 'LOGCOLLECTOR-INVENTORY-V1'

function Initialize-TlsDefaults {
    <#
    .SYNOPSIS
        Ensures TLS 1.2+ is enabled for this process.
    .DESCRIPTION
        Windows PowerShell 5.1 still defaults to SSL3/TLS1.0 on unpatched hosts;
        the frontend requires TLS 1.2 minimum, so without this the very first
        handshake fails with an unhelpful "connection closed" error.
    #>
    [CmdletBinding()]
    param()

    try {
        $protocols = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ([Enum]::IsDefined([Net.SecurityProtocolType], 'Tls13')) {
            $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
        }
        [Net.ServicePointManager]::SecurityProtocol = $protocols
    }
    catch {
        Write-Verbose 'Initialize-TlsDefaults: unable to adjust SecurityProtocol; continuing with platform defaults.'
    }
}

function New-InventoryEnvelope {
    <#
    .SYNOPSIS
        Builds a LOGCOLLECTOR-INVENTORY-V1 envelope.
    .PARAMETER Records
        One or more objects; each becomes one row in the target custom table.
    .OUTPUTS
        [pscustomobject] ready for ConvertTo-Json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records,
        [Parameter(Mandatory)] [string] $EntraDeviceId,
        [string] $DeviceName,
        [string] $IntuneDeviceId,
        [string] $Source = 'WindowsScheduledTask',
        [hashtable] $Properties,
        [DateTimeOffset] $CollectedAtUtc = [DateTimeOffset]::UtcNow
    )

    if ([string]::IsNullOrWhiteSpace($DeviceName)) { $DeviceName = [System.Environment]::MachineName }

    $normalizedProperties = [ordered]@{}
    if ($Properties) {
        foreach ($key in $Properties.Keys) {
            $normalizedProperties[[string]$key] = [string]$Properties[$key]
        }
    }

    [pscustomobject][ordered]@{
        envelopeVersion = $script:EnvelopeVersion
        tableName       = $TableName
        entraDeviceId   = ([guid]$EntraDeviceId).ToString()
        deviceName      = $DeviceName
        intuneDeviceId  = $IntuneDeviceId
        correlationId   = [guid]::NewGuid().ToString('N')
        source          = $Source
        collectedAtUtc  = $CollectedAtUtc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        properties      = $normalizedProperties
        records         = @($Records)
    }
}

function Get-RetryDelaySeconds {
    <#
    .SYNOPSIS
        Computes the wait before a given attempt.
    .DESCRIPTION
        Exponential backoff with FULL jitter (uniform over [0, ceiling]), not
        "backoff plus a little noise". Full jitter is what actually spreads a
        fleet of thousands of devices that all failed against the same outage;
        partial jitter leaves them clustered and the recovery re-triggers the
        outage. A server-supplied Retry-After always wins.
    .OUTPUTS
        [int] Seconds to sleep.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateRange(1, 64)] [int] $Attempt,
        [int] $BaseDelaySeconds = 5,
        [int] $MaxDelaySeconds = 900,
        [Nullable[int]] $RetryAfterSeconds = $null,
        [double] $JitterFactor = -1
    )

    if ($null -ne $RetryAfterSeconds) {
        $honored = [int]$RetryAfterSeconds
        if ($honored -lt 0) { $honored = 0 }
        if ($honored -gt $MaxDelaySeconds) { $honored = $MaxDelaySeconds }
        return $honored
    }

    $exponent = [Math]::Min($Attempt - 1, 16)
    $ceiling = [Math]::Min($BaseDelaySeconds * [Math]::Pow(2, $exponent), $MaxDelaySeconds)

    if ($JitterFactor -lt 0 -or $JitterFactor -gt 1) {
        $JitterFactor = (Get-Random -Minimum 0 -Maximum 10000) / 10000.0
    }

    $delay = [int][Math]::Floor($ceiling * $JitterFactor)
    if ($delay -lt 1) { $delay = 1 }
    return $delay
}

function Get-SubmissionDisposition {
    <#
    .SYNOPSIS
        Maps an HTTP status code to a retry decision.
    .OUTPUTS
        [string] One of: Delivered, Transient, AuthFailure, Permanent.
    .NOTES
        The three failure classes exist because they need different handling:
          Transient   - retry now, then keep in the spool.
          AuthFailure - do not retry now (a bad or missing certificate will not
                        fix itself within one run) but keep the entry, because
                        certificate renewal or re-enrolment can repair it later.
          Permanent   - the request is malformed or duplicated; retrying is
                        guaranteed to fail, so quarantine it for an operator.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $StatusCode)

    if ($StatusCode -ge 200 -and $StatusCode -lt 300) { return 'Delivered' }

    switch ($StatusCode) {
        401 { return 'AuthFailure' }
        403 { return 'AuthFailure' }
        408 { return 'Transient' }
        429 { return 'Transient' }
        default {
            if ($StatusCode -ge 500) { return 'Transient' }
            return 'Permanent'
        }
    }
}

function Get-WebExceptionDetail {
    <#
    .SYNOPSIS
        Normalizes an Invoke-WebRequest failure across Windows PowerShell 5.1 and
        PowerShell 7 into a status code and Retry-After value.
    .OUTPUTS
        [pscustomobject] with StatusCode (0 when the request never reached the
        server) and RetryAfterSeconds.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorRecord)

    $statusCode = 0
    $retryAfter = $null

    $response = $null
    try { $response = $ErrorRecord.Exception.Response } catch { $response = $null }

    if ($null -ne $response) {
        try {
            if ($response.PSObject.Properties.Name -contains 'StatusCode') {
                $raw = $response.StatusCode
                if ($raw -is [int]) { $statusCode = [int]$raw }
                else { $statusCode = [int]$raw.value__ }
            }
        }
        catch { $statusCode = 0 }

        try {
            $headerValue = $null
            if ($response.Headers -and ($response.Headers -is [System.Net.WebHeaderCollection])) {
                $headerValue = $response.Headers['Retry-After']
            }
            elseif ($response.Headers) {
                $values = $null
                if ($response.Headers.TryGetValues('Retry-After', [ref]$values)) {
                    $headerValue = @($values) | Select-Object -First 1
                }
            }

            if ($headerValue) {
                $parsedSeconds = 0
                if ([int]::TryParse([string]$headerValue, [ref]$parsedSeconds)) {
                    $retryAfter = $parsedSeconds
                }
                else {
                    $when = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse([string]$headerValue, [ref]$when)) {
                        $delta = [int]($when - [DateTimeOffset]::UtcNow).TotalSeconds
                        if ($delta -gt 0) { $retryAfter = $delta }
                    }
                }
            }
        }
        catch { $retryAfter = $null }
    }

    [pscustomobject]@{
        StatusCode        = $statusCode
        RetryAfterSeconds = $retryAfter
        Message           = $ErrorRecord.Exception.Message
    }
}

function Invoke-InventoryHttpPost {
    <#
    .SYNOPSIS
        Performs one signed POST. Never throws for HTTP errors.
    .OUTPUTS
        [pscustomobject] with StatusCode, RetryAfterSeconds, Disposition, Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $Uri,
        [Parameter(Mandatory)] [string] $Body,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [int] $TimeoutSeconds = 100
    )

    # Sign inside the attempt: the timestamp and nonce must be fresh for every
    # single transmission, otherwise a retry is indistinguishable from a replay.
    $signed = New-SignedInventoryRequest -Uri $Uri -Body $Body -Certificate $Certificate -Method 'POST'
    # Let the TLS endpoint finish certificate negotiation before sending a large body.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $signed.Headers['Expect'] = '100-continue'
    }
    else {
        [Net.ServicePointManager]::FindServicePoint($Uri).Expect100Continue = $true
    }

    try {
        $response = Invoke-WebRequest `
            -Uri $Uri `
            -Method Post `
            -Body $signed.BodyBytes `
            -ContentType 'application/json' `
            -Headers $signed.Headers `
            -Certificate $Certificate `
            -TimeoutSec $TimeoutSeconds `
            -UseBasicParsing `
            -ErrorAction Stop

        $statusCode = [int]$response.StatusCode
        return [pscustomobject]@{
            StatusCode        = $statusCode
            RetryAfterSeconds = $null
            Disposition       = (Get-SubmissionDisposition -StatusCode $statusCode)
            Message           = 'ok'
        }
    }
    catch {
        $detail = Get-WebExceptionDetail -ErrorRecord $_

        # StatusCode 0 means DNS/TLS/socket failure: the device is offline or the
        # endpoint is unreachable. That is always transient from the client's view.
        if ($detail.StatusCode -eq 0) {
            $disposition = 'Transient'
        }
        else {
            $disposition = Get-SubmissionDisposition -StatusCode $detail.StatusCode
        }

        return [pscustomobject]@{
            StatusCode        = $detail.StatusCode
            RetryAfterSeconds = $detail.RetryAfterSeconds
            Disposition       = $disposition
            Message           = $detail.Message
        }
    }
}

function Send-InventoryEnvelope {
    <#
    .SYNOPSIS
        Signs and POSTs one envelope body, retrying transient failures.
    .OUTPUTS
        [pscustomobject] with Disposition, StatusCode, Attempts, Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $Uri,
        [Parameter(Mandatory)] [string] $Body,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [int] $MaxAttempts = 4,
        [int] $BaseDelaySeconds = 5,
        [int] $MaxDelaySeconds = 300,
        [int] $TimeoutSeconds = 100,
        [switch] $NoSleep
    )

    Initialize-TlsDefaults

    $last = $null
    $attempt = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $last = Invoke-InventoryHttpPost -Uri $Uri -Body $Body -Certificate $Certificate -TimeoutSeconds $TimeoutSeconds

        if ($last.Disposition -ne 'Transient') { break }
        if ($attempt -eq $MaxAttempts) { break }

        $delay = Get-RetryDelaySeconds `
            -Attempt $attempt `
            -BaseDelaySeconds $BaseDelaySeconds `
            -MaxDelaySeconds $MaxDelaySeconds `
            -RetryAfterSeconds $last.RetryAfterSeconds

        Write-Verbose ("Send-InventoryEnvelope: attempt {0} returned {1}; sleeping {2}s" -f $attempt, $last.StatusCode, $delay)
        if (-not $NoSleep) { Start-Sleep -Seconds $delay }
    }

    [pscustomobject]@{
        Disposition = $last.Disposition
        StatusCode  = $last.StatusCode
        Attempts    = $attempt
        Message     = $last.Message
    }
}

function Invoke-InventorySpoolDrain {
    <#
    .SYNOPSIS
        Delivers previously spooled envelopes, oldest first.
    .DESCRIPTION
        Runs BEFORE the current sample is submitted, so the backlog is the thing
        that gets the freshest connectivity rather than being starved behind new
        data. Draining stops at the first transient or auth failure: if the
        service is down, continuing would waste the run's time budget and add
        load to an already unhealthy endpoint.
    .OUTPUTS
        [pscustomobject] with Delivered, Quarantined, Remaining, Stopped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $Uri,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory)] [string] $SpoolDirectory,
        [int] $MaxEntriesPerRun = 50,
        [int] $MaxAttemptsPerEntry = 2,
        [int] $MaxSpoolAgeDays = 7,
        [int] $MaxSpoolEntries = 500,
        [int] $MaxSpoolTotalBytes = 67108864,
        [int] $MaxDeliveryAttempts = 10,
        [switch] $NoSleep
    )

    $summary = [pscustomobject]@{
        Delivered   = 0
        Quarantined = 0
        Remaining   = 0
        Stopped     = $false
    }

    $lock = Enter-SpoolLock -SpoolDirectory $SpoolDirectory
    if ($null -eq $lock) {
        Write-Verbose 'Invoke-InventorySpoolDrain: another drain holds the lock; skipping.'
        $summary.Stopped = $true
        return $summary
    }

    try {
        # Age out first: never spend a delivery attempt on an entry that policy
        # has already decided is too old to be useful.
        $null = Invoke-SpoolMaintenance `
            -SpoolDirectory $SpoolDirectory `
            -MaxAgeDays $MaxSpoolAgeDays `
            -MaxEntries $MaxSpoolEntries `
            -MaxTotalBytes $MaxSpoolTotalBytes

        foreach ($entry in @(Get-SpoolEntry -SpoolDirectory $SpoolDirectory -First $MaxEntriesPerRun)) {
            if ($entry.Attempts -ge $MaxDeliveryAttempts) {
                Write-Verbose ("Invoke-InventorySpoolDrain: entry {0} exhausted its attempt budget." -f $entry.Path)
                $null = Move-SpoolEntryToQuarantine -Path $entry.Path -Reason 'attempts-exhausted'
                $summary.Quarantined++
                continue
            }

            if ((Update-SpoolEntryAttempt -Path $entry.Path) -lt 0) {
                $summary.Quarantined++
                continue
            }

            $result = Send-InventoryEnvelope `
                -Uri $Uri `
                -Body $entry.Body `
                -Certificate $Certificate `
                -MaxAttempts $MaxAttemptsPerEntry `
                -NoSleep:$NoSleep

            switch ($result.Disposition) {
                'Delivered' {
                    Remove-SpoolEntry -Path $entry.Path
                    $summary.Delivered++
                }
                'Permanent' {
                    $null = Move-SpoolEntryToQuarantine -Path $entry.Path -Reason ("http-{0}" -f $result.StatusCode)
                    $summary.Quarantined++
                }
                default {
                    # Transient or AuthFailure: leave the entry in place and stop.
                    Write-Verbose ("Invoke-InventorySpoolDrain: stopping on {0} (status {1})." -f $result.Disposition, $result.StatusCode)
                    $summary.Stopped = $true
                }
            }

            if ($summary.Stopped) { break }
        }

        $summary.Remaining = @(Get-SpoolEntry -SpoolDirectory $SpoolDirectory).Count
    }
    finally {
        Exit-SpoolLock -LockStream $lock
    }

    return $summary
}

function Invoke-InventorySubmission {
    <#
    .SYNOPSIS
        Drains the spool and submits the current envelope.
    .OUTPUTS
        [pscustomobject] with Disposition, StatusCode, Spooled, SpoolPath, Drain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Uri] $Uri,
        [Parameter(Mandatory)] [object] $Envelope,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [string] $SpoolDirectory = 'C:\ProgramData\LogCollector\Spool',
        [int] $MaxAttempts = 4,
        [int] $BaseDelaySeconds = 5,
        [int] $MaxDelaySeconds = 300,
        [int] $MaxSpoolAgeDays = 7,
        [int] $MaxSpoolEntries = 500,
        [int] $MaxSpoolTotalBytes = 67108864,
        [switch] $SkipDrain,
        [switch] $NoSleep
    )

    Initialize-TlsDefaults

    # Fail closed even with -SkipDrain: unsafe pre-existing spool contents must
    # never be repaired or used by a later privileged invocation.
    $null = Initialize-SpoolDirectory -SpoolDirectory $SpoolDirectory

    $body = $Envelope | ConvertTo-Json -Depth 24 -Compress
    $tableName = [string]$Envelope.tableName

    $drain = $null
    if (-not $SkipDrain) {
        $drain = Invoke-InventorySpoolDrain `
            -Uri $Uri `
            -Certificate $Certificate `
            -SpoolDirectory $SpoolDirectory `
            -MaxSpoolAgeDays $MaxSpoolAgeDays `
            -MaxSpoolEntries $MaxSpoolEntries `
            -MaxSpoolTotalBytes $MaxSpoolTotalBytes `
            -NoSleep:$NoSleep
    }

    $result = Send-InventoryEnvelope `
        -Uri $Uri `
        -Body $body `
        -Certificate $Certificate `
        -MaxAttempts $MaxAttempts `
        -BaseDelaySeconds $BaseDelaySeconds `
        -MaxDelaySeconds $MaxDelaySeconds `
        -NoSleep:$NoSleep

    $spoolPath = $null

    # A Permanent rejection is not spooled: the payload itself is the problem, so
    # replaying it would only reproduce the same rejection on every later run.
    if ($result.Disposition -eq 'Transient' -or $result.Disposition -eq 'AuthFailure') {
        $spoolPath = Save-SpoolEntry `
            -Body $body `
            -TableName $tableName `
            -SpoolDirectory $SpoolDirectory `
            -MaxEntries $MaxSpoolEntries `
            -MaxTotalBytes $MaxSpoolTotalBytes

        Write-Verbose ("Invoke-InventorySubmission: spooled to {0} after {1}." -f $spoolPath, $result.Disposition)
    }

    [pscustomobject]@{
        Disposition = $result.Disposition
        StatusCode  = $result.StatusCode
        Attempts    = $result.Attempts
        Message     = $result.Message
        Spooled     = ($null -ne $spoolPath)
        SpoolPath   = $spoolPath
        Drain       = $drain
    }
}

Export-ModuleMember -Function `
    Initialize-TlsDefaults, `
    New-InventoryEnvelope, `
    Get-RetryDelaySeconds, `
    Get-SubmissionDisposition, `
    Get-WebExceptionDetail, `
    Invoke-InventoryHttpPost, `
    Send-InventoryEnvelope, `
    Invoke-InventorySpoolDrain, `
    Invoke-InventorySubmission
