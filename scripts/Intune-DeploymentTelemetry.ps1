#requires -Version 5.1

<#
.SYNOPSIS
Collects local Windows and MDM telemetry for Intune deployment-latency analysis.

.DESCRIPTION
Designed for Microsoft Intune Platform Scripts running as SYSTEM in a 64-bit
Windows PowerShell host. The first execution timestamp and correlation ID are
written once to HKLM and never overwritten.

Telemetry is optional and never blocks provisioning. Certificate mode uses the
installed LogCollector.Client module, its device certificate, protected spool,
and HTTPS intake endpoint. Disabled mode performs local collection without
attempting remote delivery.
#>

#region Configuration - set these values before signing and uploading to Intune
$TelemetryMode = 'Disabled'
$TelemetryEndpoint = ''
$LogCollectorTableName = 'IntuneDeploymentTelemetry_CL'
$LogCollectorModuleMinimumVersion = '1.8.0'
$AssignmentTimestampUtc = '2026-08-28T17:00:00Z'
$IntunePolicyId = '91652293-8a62-4ed5-90ff-19baa07c249c'
$EventLookbackHours = 72
$MaximumMdmEvents = 20
$MaximumImePollTimestamps = 100
$MaximumImeLogBytes = 32MB
$ImeLogScanBudgetSeconds = 15
$UploadTimeoutSeconds = 15
$UploadBudgetSeconds = 20
#endregion Configuration

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptVersion = '1.6.1'
$RegistryPath = 'HKLM:\SOFTWARE\Bigfix Tags\IntuneDeploymentTelemetry'
$LogDirectory = Join-Path $env:ProgramData 'IntuneDeploymentTelemetry'
$TranscriptPath = $null
$MdmAdminLog = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
$script:Errors = [System.Collections.Generic.List[object]]::new()
$script:TranscriptStarted = $false
$script:LocalStorageReady = $false

function ConvertTo-UtcIso8601 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$Value
    )

    return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-OptionalUtcIso8601 {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        if ($Value -is [datetime]) {
            return ConvertTo-UtcIso8601 -Value $Value
        }

        $fileTime = 0L
        if ([long]::TryParse([string]$Value, [ref]$fileTime) -and
            $fileTime -gt 100000000000000000L) {
            return ConvertTo-UtcIso8601 -Value ([datetime]::FromFileTimeUtc($fileTime))
        }

        $parsed = [datetime]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal
        )
        return ConvertTo-UtcIso8601 -Value $parsed
    }
    catch {
        return $null
    }
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Add-TelemetryError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $entry = [ordered]@{
        TimestampUtc = ConvertTo-UtcIso8601 -Value ([datetime]::UtcNow)
        Operation    = $Operation
        Message      = $ErrorRecord.Exception.Message
        ErrorType    = $ErrorRecord.Exception.GetType().FullName
        HResult      = ('0x{0:X8}' -f ($ErrorRecord.Exception.HResult -band 0xffffffff))
    }

    $script:Errors.Add([pscustomobject]$entry)
    Write-Warning ('{0}: {1}' -f $Operation, $ErrorRecord.Exception.Message)
}

function Get-TelemetryErrorSnapshot {
    [CmdletBinding()]
    param()

    $maximumErrors = 25
    return [pscustomobject]@{
        Errors         = @($script:Errors | Select-Object -First $maximumErrors)
        TruncatedCount = [Math]::Max(0, $script:Errors.Count - $maximumErrors)
    }
}

function Invoke-TelemetryOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Operation,

        [Parameter()]
        $Default = $null
    )

    try {
        return & $Operation
    }
    catch {
        Add-TelemetryError -Operation $Name -ErrorRecord $_
        return $Default
    }
}

function Initialize-LocalLogging {
    [CmdletBinding()]
    param()

    try {
        $directoryExisted = Test-Path -LiteralPath $LogDirectory -PathType Container
        if (-not $directoryExisted) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }

        $directory = Get-Item -LiteralPath $LogDirectory -Force
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use reparse-point log directory: $LogDirectory"
        }

        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagation = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $systemSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid, $null
        )
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null
        )
        $allowedSids = @($systemSid.Value, $administratorsSid.Value)
        if ($directoryExisted) {
            $existingAcl = Get-Acl -LiteralPath $LogDirectory
            $unexpectedAllow = @($existingAcl.Access | Where-Object {
                $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Translate(
                    [Security.Principal.SecurityIdentifier]
                ).Value -notin $allowedSids
            })
            if (-not $existingAcl.AreAccessRulesProtected -or $unexpectedAllow.Count -gt 0) {
                throw 'Existing telemetry directory does not have the required protected ACL.'
            }
        }

        foreach ($sid in @($systemSid, $administratorsSid)) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow
            )
            $acl.AddAccessRule($rule)
        }
        $acl.SetOwner($administratorsSid)
        Set-Acl -LiteralPath $LogDirectory -AclObject $acl -ErrorAction Stop

        $script:TranscriptPath = Join-Path $LogDirectory (
            'IntuneDeploymentTelemetry-{0}.log' -f [guid]::NewGuid().ToString('N')
        )
        Get-ChildItem -LiteralPath $LogDirectory -Filter 'IntuneDeploymentTelemetry-*.log' -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 9 |
            Remove-Item -Force
        Get-ChildItem -LiteralPath $LogDirectory -Filter 'FailedUpload-*.json' -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 4 |
            Remove-Item -Force

        Start-Transcript -LiteralPath $script:TranscriptPath -Force | Out-Null
        $script:TranscriptStarted = $true
        $script:LocalStorageReady = $true
    }
    catch {
        Add-TelemetryError -Operation 'StartTranscript' -ErrorRecord $_
    }
}

function Test-SecureLocalStorage {
    [CmdletBinding()]
    param()

    if (-not $script:LocalStorageReady -or
        -not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        return $false
    }

    $directory = Get-Item -LiteralPath $LogDirectory -Force
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }

    try {
        $acl = Get-Acl -LiteralPath $LogDirectory
        if (-not $acl.AreAccessRulesProtected) {
            return $false
        }

        $allowedSids = @(
            [Security.Principal.SecurityIdentifier]::new(
                [Security.Principal.WellKnownSidType]::LocalSystemSid, $null
            ).Value
            [Security.Principal.SecurityIdentifier]::new(
                [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null
            ).Value
        )
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -ne
                [Security.AccessControl.AccessControlType]::Allow) {
                continue
            }
            $sid = $rule.IdentityReference.Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
            if ($sid -notin $allowedSids) {
                return $false
            }
        }
        return $true
    }
    catch {
        Add-TelemetryError -Operation 'ValidateSecureLocalStorage' -ErrorRecord $_
        return $false
    }
}

function Get-OrCreateExecutionState {
    [CmdletBinding()]
    param()

    $mutex = $null
    $lockTaken = $false
    try {
        $mutex = [Threading.Mutex]::new($false, 'Global\IntuneDeploymentTelemetryRegistry')
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [Threading.AbandonedMutexException] {
            # Ownership transfers to this thread when an abandoned mutex is observed.
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            throw 'Timed out waiting for the telemetry registry lock.'
        }

        if (-not (Test-Path -LiteralPath $RegistryPath)) {
            New-Item -Path $RegistryPath -Force | Out-Null
        }

        $properties = Get-ItemProperty -LiteralPath $RegistryPath
        $firstExecution = Get-PropertyValue -InputObject $properties `
            -Name 'FirstExecutionTimestampUTC'
        $correlationId = Get-PropertyValue -InputObject $properties `
            -Name 'CorrelationId'

        if ([string]::IsNullOrWhiteSpace([string]$firstExecution)) {
            $firstExecution = ConvertTo-UtcIso8601 -Value ([datetime]::UtcNow)
            New-ItemProperty -LiteralPath $RegistryPath -Name 'FirstExecutionTimestampUTC' `
                -Value $firstExecution -PropertyType String -Force | Out-Null
        }

        if ([string]::IsNullOrWhiteSpace([string]$correlationId)) {
            $correlationId = [guid]::NewGuid().ToString()
            New-ItemProperty -LiteralPath $RegistryPath -Name 'CorrelationId' `
                -Value $correlationId -PropertyType String -Force | Out-Null
        }

        # ScriptVersion describes the latest executing version; the first timestamp is immutable.
        New-ItemProperty -LiteralPath $RegistryPath -Name 'ScriptVersion' `
            -Value $ScriptVersion -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $RegistryPath -Name 'LastExecutionTimestampUTC' `
            -Value (ConvertTo-UtcIso8601 -Value ([datetime]::UtcNow)) `
            -PropertyType String -Force | Out-Null

        return [pscustomobject]@{
            FirstExecutionTimestampUtc = [string]$firstExecution
            CorrelationId              = [string]$correlationId
            RegistryWriteSuccess       = $true
        }
    }
    catch {
        Add-TelemetryError -Operation 'InitializeRegistryState' -ErrorRecord $_
        return [pscustomobject]@{
            FirstExecutionTimestampUtc = $null
            CorrelationId              = [guid]::NewGuid().ToString()
            RegistryWriteSuccess       = $false
        }
    }
    finally {
        if ($lockTaken -and $null -ne $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-DsRegStatus {
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        AzureAdJoined   = $false
        AzureAdDeviceId = $null
        TenantId        = $null
        UserUPN         = $null
    }

    $output = & "$env:SystemRoot\System32\dsregcmd.exe" /status 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "dsregcmd.exe exited with code $LASTEXITCODE."
    }

    foreach ($line in $output) {
        if ($line -match '^\s*AzureAdJoined\s*:\s*(YES|NO)\s*$') {
            $result.AzureAdJoined = $Matches[1] -eq 'YES'
        }
        elseif ($line -match '^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})\s*$') {
            $result.AzureAdDeviceId = $Matches[1]
        }
        elseif ($line -match '^\s*TenantId\s*:\s*([0-9a-fA-F-]{36})\s*$') {
            $result.TenantId = $Matches[1]
        }
        elseif ($line -match '^\s*UserEmail\s*:\s*(.+?)\s*$') {
            $result.UserUPN = $Matches[1]
        }
    }

    return [pscustomobject]$result
}

function Get-MdmEnrollment {
    [CmdletBinding()]
    param()

    $enrollmentRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    $candidates = @()

    if (Test-Path -LiteralPath $enrollmentRoot) {
        foreach ($key in Get-ChildItem -LiteralPath $enrollmentRoot -ErrorAction Stop) {
            try {
                $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $providerId = Get-PropertyValue -InputObject $item -Name 'ProviderID'
                $upn = Get-PropertyValue -InputObject $item -Name 'UPN'
                $discoveryService = Get-PropertyValue -InputObject $item `
                    -Name 'DiscoveryServiceFullURL'
                if ($providerId -or $upn -or $discoveryService) {
                    $firstSync = Get-ItemProperty `
                        -LiteralPath (Join-Path $key.PSPath 'FirstSync') `
                        -ErrorAction SilentlyContinue
                    $enrollmentDate = @(
                        Get-PropertyValue -InputObject $item -Name 'EnrollmentDate'
                        Get-PropertyValue -InputObject $item -Name 'EnrollmentTime'
                        Get-PropertyValue -InputObject $firstSync -Name 'FirstSyncTime'
                    ) | Where-Object {
                        $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)
                    } | Select-Object -First 1

                    $candidates += [pscustomobject]@{
                        EnrollmentId       = $key.PSChildName
                        ProviderId         = [string]$providerId
                        UserUPN            = [string]$upn
                        TenantId           = [string](Get-PropertyValue -InputObject $item -Name 'AADTenantID')
                        EnrollmentType     = Get-PropertyValue -InputObject $item -Name 'EnrollmentType'
                        EnrollmentState    = Get-PropertyValue -InputObject $item -Name 'EnrollmentState'
                        EntDMID            = [string](Get-PropertyValue -InputObject $item -Name 'EntDMID')
                        DiscoveryService   = [string]$discoveryService
                        EnrollmentDateUtc  = ConvertTo-OptionalUtcIso8601 -Value $enrollmentDate
                    }
                }
            }
            catch {
                Add-TelemetryError -Operation ('ReadEnrollment:{0}' -f $key.PSChildName) -ErrorRecord $_
            }
        }
    }

    $selected = $candidates |
        Sort-Object @{ Expression = { $_.ProviderId -match 'MS DM Server|Intune' }; Descending = $true },
                    @{ Expression = { -not [string]::IsNullOrWhiteSpace($_.EntDMID) }; Descending = $true } |
        Select-Object -First 1

    if ($null -eq $selected) {
        return [pscustomobject]@{
            Status             = 'NotDiscovered'
            EnrollmentId       = $null
            ManagedDeviceId    = $null
            EnrollmentDateUtc  = $null
            UserUPN            = $null
            TenantId           = $null
            ProviderId         = $null
            EnrollmentType     = $null
            EnrollmentState    = $null
        }
    }

    $status = if ($selected.EnrollmentState -eq 1) { 'Enrolled' } else { 'EnrollmentDiscovered' }
    return [pscustomobject]@{
        Status             = $status
        EnrollmentId       = $selected.EnrollmentId
        ManagedDeviceId    = $selected.EntDMID
        EnrollmentDateUtc  = $selected.EnrollmentDateUtc
        UserUPN            = $selected.UserUPN
        TenantId           = $selected.TenantId
        ProviderId         = $selected.ProviderId
        EnrollmentType     = $selected.EnrollmentType
        EnrollmentState    = $selected.EnrollmentState
    }
}

function Get-MdmScheduledTask {
    [CmdletBinding()]
    param()

    $tasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' `
        -ErrorAction SilentlyContinue
    $result = foreach ($task in $tasks) {
        try {
            $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
            [pscustomobject]@{
                TaskName          = $task.TaskName
                TaskPath          = $task.TaskPath
                State             = [string]$task.State
                LastRunTimeUtc    = if ($info.LastRunTime -is [datetime] -and
                    $info.LastRunTime.Year -ge 2000) {
                    ConvertTo-UtcIso8601 -Value $info.LastRunTime
                } else { $null }
                NextRunTimeUtc    = if ($info.NextRunTime -is [datetime] -and
                    $info.NextRunTime.Year -ge 2000) {
                    ConvertTo-UtcIso8601 -Value $info.NextRunTime
                } else { $null }
                LastTaskResult    = $info.LastTaskResult
                NumberOfMissedRuns = $info.NumberOfMissedRuns
            }
        }
        catch {
            Add-TelemetryError -Operation ('ReadScheduledTask:{0}' -f $task.TaskName) -ErrorRecord $_
        }
    }

    return @($result)
}

function Get-MdmEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$StartTimeUtc,

        [Parameter(Mandatory)]
        [int]$MaximumEvents
    )

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $MdmAdminLog
            StartTime = $StartTimeUtc.ToLocalTime()
        } -MaxEvents $MaximumEvents -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound|NoMatchingLogsFound') {
            return @()
        }
        throw
    }

    $result = foreach ($eventRecord in $events) {
        $activityId = $null
        try {
            $xml = [xml]$eventRecord.ToXml()
            $correlation = Get-PropertyValue -InputObject $xml.Event.System `
                -Name 'Correlation'
            $activityId = [string](Get-PropertyValue -InputObject $correlation `
                -Name 'ActivityID')
        }
        catch {
            Add-TelemetryError -Operation ('ParseMdmEventXml:{0}' -f $eventRecord.RecordId) -ErrorRecord $_
        }

        [pscustomobject]@{
            TimeCreatedUtc = ConvertTo-UtcIso8601 -Value $eventRecord.TimeCreated
            EventId        = $eventRecord.Id
            Level          = $eventRecord.LevelDisplayName
            RecordId       = $eventRecord.RecordId
            ActivityId     = $activityId
        }
    }

    return @($result)
}

function Get-EstimatedMdmCycle {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Events,

        [Parameter()]
        [Nullable[datetime]]$SinceUtc,

        [Parameter(Mandatory)]
        [datetime]$WindowStartUtc,

        [Parameter(Mandatory)]
        [bool]$EventsTruncated,

        [Parameter()]
        [Nullable[datetime]]$OldestRetainedEventUtc
    )

    if ($null -eq $SinceUtc) {
        return [pscustomobject]@{
            Count  = $null
            Method = 'AssignmentTimestampNotProvided'
        }
    }

    $since = [datetime]$SinceUtc
    if ($since -lt $WindowStartUtc) {
        return [pscustomobject]@{
            Count  = $null
            Method = 'AssignmentOlderThanEventWindow'
        }
    }

    $eligible = @($Events | Where-Object {
        [datetime]::Parse($_.TimeCreatedUtc, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind) -ge $since
    } | Sort-Object TimeCreatedUtc)

    if ($eligible.Count -eq 0) {
        return [pscustomobject]@{
            Count  = 0
            Method = if ($EventsTruncated) {
                'NoMatchingEventsInTruncatedSample'
            } else {
                'NoDMEDPEventsAfterAssignment'
            }
        }
    }

    if ($EventsTruncated -and
        ($null -eq $OldestRetainedEventUtc -or
        [datetime]$OldestRetainedEventUtc -gt $since)) {
        return [pscustomobject]@{
            Count  = $null
            Method = 'EventSampleDoesNotCoverAssignment'
        }
    }

    $activityIds = @($eligible |
        ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_.ActivityId)) {
                ([string]$_.ActivityId).Trim('{}').ToLowerInvariant()
            }
        } |
        Where-Object { $_ -and $_ -ne [guid]::Empty.ToString() } |
        Select-Object -Unique)

    if ($activityIds.Count -gt 0) {
        return [pscustomobject]@{
            Count  = $activityIds.Count
            Method = 'DistinctDMEDPActivityIds'
        }
    }

    # Fallback: events separated by at least 15 minutes are treated as distinct sessions.
    $cycles = 0
    $previous = $null
    foreach ($eventRecord in $eligible) {
        $current = [datetime]::Parse(
            $eventRecord.TimeCreatedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        if ($null -eq $previous -or ($current - $previous).TotalMinutes -ge 15) {
            $cycles++
        }
        $previous = $current
    }

    return [pscustomobject]@{
        Count  = $cycles
        Method = 'FifteenMinuteEventClusters'
    }
}

function ConvertFrom-ImeCmTraceTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line
    )

    $dateMatch = [regex]::Match($Line, 'date="(?<Value>[^"]+)"')
    $timeMatch = [regex]::Match($Line, 'time="(?<Value>[^"]+)"')
    if (-not $dateMatch.Success -or -not $timeMatch.Success) {
        return $null
    }

    try {
        $timeParts = [regex]::Match(
            $timeMatch.Groups['Value'].Value,
            '^(?<Clock>\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)(?<Bias>[+-]\d+)?$'
        )
        if (-not $timeParts.Success) {
            return $null
        }
        $localTimestamp = [datetime]::Parse(
            ('{0} {1}' -f
                $dateMatch.Groups['Value'].Value,
                $timeParts.Groups['Clock'].Value),
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AllowWhiteSpaces
        )
        $localTimestamp = [datetime]::SpecifyKind(
            $localTimestamp,
            [DateTimeKind]::Unspecified
        )
        if ($timeParts.Groups['Bias'].Success) {
            $biasMinutes = [int]$timeParts.Groups['Bias'].Value
            return [datetime]::SpecifyKind(
                $localTimestamp.AddMinutes($biasMinutes),
                [DateTimeKind]::Utc
            )
        }
        return [TimeZoneInfo]::ConvertTimeToUtc($localTimestamp, [TimeZoneInfo]::Local)
    }
    catch {
        return $null
    }
}

function Get-IntunePolicyIdentity {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfiguredPolicyId,

        [Parameter()]
        [string]$ExecutingScriptPath
    )

    $configured = [guid]::Empty
    $hasConfigured = [guid]::TryParse($ConfiguredPolicyId, [ref]$configured) -and
        $configured -ne [guid]::Empty

    $guidPattern =
        '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $candidateIds = [Collections.Generic.List[guid]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ExecutingScriptPath)) {
        foreach ($candidateMatch in [regex]::Matches(
                $ExecutingScriptPath,
                $guidPattern,
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )) {
            $candidate = [guid]::Empty
            if ([guid]::TryParse($candidateMatch.Value, [ref]$candidate) -and
                $candidate -ne [guid]::Empty -and
                $candidate -notin $candidateIds) {
                $candidateIds.Add($candidate)
            }
        }
    }

    $detected = [guid]::Empty
    $hasDetected = $false
    if (-not [string]::IsNullOrWhiteSpace($ExecutingScriptPath)) {
        $fileName = [IO.Path]::GetFileNameWithoutExtension($ExecutingScriptPath)
        $twoGuidMatch = [regex]::Match(
            $fileName,
            ('^(?:{0})_(?<PolicyId>{0})(?:_\d+)?$' -f $guidPattern),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $numberedPolicyMatch = [regex]::Match(
            $ExecutingScriptPath,
            ('(?:^|[\\/])(?<PolicyId>{0})_\d+(?:[\\/]|$)' -f $guidPattern),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $detectedText = if ($twoGuidMatch.Success) {
            $twoGuidMatch.Groups['PolicyId'].Value
        }
        elseif ($numberedPolicyMatch.Success) {
            $numberedPolicyMatch.Groups['PolicyId'].Value
        }
        else {
            $null
        }
        $hasDetected = -not [string]::IsNullOrWhiteSpace($detectedText) -and
            [guid]::TryParse($detectedText, [ref]$detected) -and
            $detected -ne [guid]::Empty
    }

    $matchStatus = if ($hasConfigured -and $hasDetected) {
        if ($configured -eq $detected) {
            'ConfiguredAndDetectedMatch'
        } else {
            'ConfiguredAndDetectedMismatch'
        }
    } elseif ($hasConfigured) {
        'ConfiguredOnly'
    } elseif ($hasDetected) {
        'DetectedFromScriptPath'
    } elseif ($candidateIds.Count -gt 1) {
        'AmbiguousScriptPath'
    } else {
        'Unavailable'
    }

    return [pscustomobject]@{
        ConfiguredPolicyId = if ($hasConfigured) {
            $configured.ToString()
        } else { $null }
        DetectedPolicyId   = if ($hasDetected) {
            $detected.ToString()
        } else { $null }
        EffectivePolicyId  = if ($hasDetected) {
            $detected.ToString()
        } elseif ($hasConfigured) {
            $configured.ToString()
        } else { $null }
        MatchStatus        = $matchStatus
    }
}

function Get-ImeLogEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$AssignmentUtc,

        [Parameter(Mandatory)]
        [datetime]$CollectionEndUtc,

        [Parameter()]
        [string]$PolicyId,

        [Parameter(Mandatory)]
        [int]$MaximumPollTimestamps,

        [Parameter()]
        [long]$MaximumLogBytes = 33554432,

        [Parameter()]
        [int]$ScanBudgetSeconds = 15,

        [Parameter()]
        [int]$CoverageLagToleranceSeconds = 300,

        [Parameter()]
        [string]$LogDirectoryPath = (
            Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
        )
    )

    $result = [ordered]@{
        LogFilesAnalyzed                 = 0
        LogFilesFailed                   = 0
        LogOldestRetainedUtc             = $null
        LogNewestRetainedUtc             = $null
        ManagementLogOldestRetainedUtc   = $null
        ManagementLogNewestRetainedUtc   = $null
        AgentLogOldestRetainedUtc        = $null
        AgentLogNewestRetainedUtc        = $null
        ManagementLogCoverageStatus      = 'NoLogFiles'
        AgentLogCoverageStatus           = 'NoLogFiles'
        LogCoverageStatus                = 'NoLogFiles'
        LogEvidenceTruncated             = $false
        LogScanStopReason                = $null
        PolicyPollCountSinceAssignment   = 0
        EmptyPolicyResponseCount         = 0
        DeviceCheckInCountSinceAssignment = 0
        GenericWorkloadCheckInCount      = 0
        FirstManagementActivityUtc       = $null
        PolicyPollTimestampsUtc          = @()
        PolicyPollTimestampsTruncated    = $false
        PolicyReceivedUtc                = $null
        PolicyProcessingUtc              = $null
        ScriptMaterializedUtc            = $null
        ExecutionIdentifiedUtc           = $null
    }

    if (-not (Test-Path -LiteralPath $LogDirectoryPath -PathType Container)) {
        return [pscustomobject]$result
    }

    $files = @(
        Get-ChildItem -LiteralPath $LogDirectoryPath -File -ErrorAction Stop |
            Where-Object {
                $_.Name -match
                    '^(IntuneManagementExtension|AgentExecutor)(?:-[^.]+)?\.log$'
            } |
            Sort-Object LastWriteTimeUtc -Descending
    )
    if ($files.Count -eq 0) {
        return [pscustomobject]$result
    }

    $policyText = $null
    if (-not [string]::IsNullOrWhiteSpace($PolicyId)) {
        $policyText = ([guid]$PolicyId).ToString()
    }
    $deduplicationKeys = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $pollTimestamps = [Collections.Generic.List[datetime]]::new()
    $oldestTimestamp = $null
    $newestTimestamp = $null
    $managementOldestTimestamp = $null
    $managementNewestTimestamp = $null
    $agentOldestTimestamp = $null
    $agentNewestTimestamp = $null
    $scheduledBytes = 0L
    $scanStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stopScanning = $false

    foreach ($file in $files) {
        if ($scanStopwatch.Elapsed.TotalSeconds -ge $ScanBudgetSeconds) {
            $result.LogEvidenceTruncated = $true
            $result.LogScanStopReason = 'TimeBudgetExceeded'
            break
        }
        if ($scheduledBytes + [long]$file.Length -gt $MaximumLogBytes) {
            $result.LogEvidenceTruncated = $true
            $result.LogScanStopReason = 'ByteLimitExceeded'
            break
        }
        $scheduledBytes += [long]$file.Length
        $stream = $null
        $reader = $null
        try {
            $stream = [IO.FileStream]::new(
                $file.FullName,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite
            )
            $reader = [IO.StreamReader]::new(
                $stream,
                [Text.Encoding]::UTF8,
                $true
            )
            $result.LogFilesAnalyzed++
            $isAgentLog = $file.Name -match '^AgentExecutor'
            $pendingEntry = $null
            $lineCount = 0

            while (-not $reader.EndOfStream) {
                $lineCount++
                if (($lineCount % 256) -eq 0 -and
                    $scanStopwatch.Elapsed.TotalSeconds -ge $ScanBudgetSeconds) {
                    $result.LogEvidenceTruncated = $true
                    $result.LogScanStopReason = 'TimeBudgetExceeded'
                    $stopScanning = $true
                    break
                }
                $line = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line) -and
                    [string]::IsNullOrWhiteSpace($pendingEntry)) {
                    continue
                }
                if ($line -match '<!\[LOG\[') {
                    $pendingEntry = $line
                }
                elseif ($null -ne $pendingEntry) {
                    $pendingEntry = $pendingEntry + "`n" + $line
                }
                else {
                    $pendingEntry = $line
                }
                if ($line -notmatch '\]LOG\]!><time="') {
                    continue
                }

                $entry = $pendingEntry
                $pendingEntry = $null
                $timestamp = ConvertFrom-ImeCmTraceTimestamp -Line $entry
                if ($null -eq $timestamp) {
                    continue
                }
                if ($null -eq $oldestTimestamp -or $timestamp -lt $oldestTimestamp) {
                    $oldestTimestamp = $timestamp
                }
                if ($null -eq $newestTimestamp -or $timestamp -gt $newestTimestamp) {
                    $newestTimestamp = $timestamp
                }
                if ($isAgentLog) {
                    if ($null -eq $agentOldestTimestamp -or
                        $timestamp -lt $agentOldestTimestamp) {
                        $agentOldestTimestamp = $timestamp
                    }
                    if ($null -eq $agentNewestTimestamp -or
                        $timestamp -gt $agentNewestTimestamp) {
                        $agentNewestTimestamp = $timestamp
                    }
                }
                else {
                    if ($null -eq $managementOldestTimestamp -or
                        $timestamp -lt $managementOldestTimestamp) {
                        $managementOldestTimestamp = $timestamp
                    }
                    if ($null -eq $managementNewestTimestamp -or
                        $timestamp -gt $managementNewestTimestamp) {
                        $managementNewestTimestamp = $timestamp
                    }
                }
                if ($timestamp -lt $AssignmentUtc -or
                    $timestamp -gt $CollectionEndUtc.AddMinutes(5)) {
                    continue
                }

                $eventType = $null
                $eventDetail = ''
                if ($entry -match
                    '\[PowerShell\] Requesting policies with session id\s+(?<SessionId>[0-9a-f-]{36})') {
                    $eventType = 'PolicyRequest'
                    $eventDetail = $Matches['SessionId']
                }
                elseif ($entry -match '\[PowerShell\] response payload is') {
                    if ($entry -match '\[PowerShell\] response payload is\s*\[\s*\]') {
                        $eventType = 'EmptyPolicyResponse'
                    }
                    elseif ($policyText -and
                        $entry.IndexOf(
                            $policyText,
                            [StringComparison]::OrdinalIgnoreCase
                        ) -ge 0) {
                        $eventType = 'TargetPolicyResponse'
                    }
                }
                elseif ($entry -match
                    '\[ServiceBase\], check in using device check in AAD App') {
                    $eventType = 'DeviceCheckIn'
                }
                elseif ($entry -match
                    '\[GenericWorkload\] Initiating GenericWorkload Checkin') {
                    $eventType = 'GenericWorkloadCheckIn'
                }
                elseif ($policyText -and
                    $entry.IndexOf(
                        $policyText,
                        [StringComparison]::OrdinalIgnoreCase
                    ) -ge 0) {
                    if ($entry -match '(?is)decrypt(?:ion|ed)?.*(?:complete|success)') {
                        $eventType = 'ScriptMaterialized'
                    }
                    elseif ($entry -match
                        '(?is)(?:processing|process).*(?:policy|powershell)') {
                        $eventType = 'PolicyProcessing'
                    }
                    elseif ($entry -match
                        '(?is)(?:Adding argument powershell with value|cmd line for running powershell is).+\.ps1') {
                        $eventType = 'ExecutionIdentified'
                    }
                }

                if ($null -eq $eventType) {
                    continue
                }

                $eventKey = '{0}|{1}|{2}' -f
                    $timestamp.Ticks,
                    $eventType,
                    $eventDetail
                if (-not $deduplicationKeys.Add($eventKey)) {
                    continue
                }

                switch ($eventType) {
                    'PolicyRequest' {
                        $result.PolicyPollCountSinceAssignment++
                        $pollTimestamps.Add($timestamp)
                    }
                    'EmptyPolicyResponse' {
                        $result.EmptyPolicyResponseCount++
                    }
                    'DeviceCheckIn' {
                        $result.DeviceCheckInCountSinceAssignment++
                    }
                    'GenericWorkloadCheckIn' {
                        $result.GenericWorkloadCheckInCount++
                    }
                    'TargetPolicyResponse' {
                        if ($null -eq $result.PolicyReceivedUtc -or
                            $timestamp -lt $result.PolicyReceivedUtc) {
                            $result.PolicyReceivedUtc = $timestamp
                        }
                    }
                    'PolicyProcessing' {
                        if ($null -eq $result.PolicyProcessingUtc -or
                            $timestamp -lt $result.PolicyProcessingUtc) {
                            $result.PolicyProcessingUtc = $timestamp
                        }
                    }
                    'ScriptMaterialized' {
                        if ($null -eq $result.ScriptMaterializedUtc -or
                            $timestamp -lt $result.ScriptMaterializedUtc) {
                            $result.ScriptMaterializedUtc = $timestamp
                        }
                    }
                    'ExecutionIdentified' {
                        if ($null -eq $result.ExecutionIdentifiedUtc -or
                            $timestamp -lt $result.ExecutionIdentifiedUtc) {
                            $result.ExecutionIdentifiedUtc = $timestamp
                        }
                    }
                }
                if ($eventType -in @(
                        'PolicyRequest',
                        'EmptyPolicyResponse',
                        'TargetPolicyResponse',
                        'DeviceCheckIn',
                        'GenericWorkloadCheckIn',
                        'PolicyProcessing',
                        'ScriptMaterialized',
                        'ExecutionIdentified'
                    ) -and
                    ($null -eq $result.FirstManagementActivityUtc -or
                    $timestamp -lt $result.FirstManagementActivityUtc)) {
                    $result.FirstManagementActivityUtc = $timestamp
                }
            }
        }
        catch {
            $result.LogFilesFailed++
            $result.LogEvidenceTruncated = $true
            Add-TelemetryError -Operation ('ReadImeLog:{0}' -f $file.Name) `
                -ErrorRecord $_
        }
        finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }
            elseif ($null -ne $stream) {
                $stream.Dispose()
            }
        }
        if ($stopScanning) {
            break
        }
    }
    $scanStopwatch.Stop()

    $result.LogOldestRetainedUtc = $oldestTimestamp
    $result.LogNewestRetainedUtc = $newestTimestamp
    $result.ManagementLogOldestRetainedUtc = $managementOldestTimestamp
    $result.ManagementLogNewestRetainedUtc = $managementNewestTimestamp
    $result.AgentLogOldestRetainedUtc = $agentOldestTimestamp
    $result.AgentLogNewestRetainedUtc = $agentNewestTimestamp

    $coverageRequiredEndUtc = $CollectionEndUtc.AddSeconds(
        -1 * $CoverageLagToleranceSeconds
    )
    $managementRequiredEndUtc = if ($null -ne $result.PolicyReceivedUtc) {
        $result.PolicyReceivedUtc
    }
    else {
        $coverageRequiredEndUtc
    }
    if ($null -eq $managementOldestTimestamp -or
        $null -eq $managementNewestTimestamp) {
        $result.ManagementLogCoverageStatus = 'NoParseableTimestamps'
    }
    elseif ($managementOldestTimestamp -gt $AssignmentUtc) {
        $result.ManagementLogCoverageStatus = 'AssignmentPredatesRetainedLogs'
    }
    elseif ($managementNewestTimestamp -lt $AssignmentUtc) {
        $result.ManagementLogCoverageStatus = 'NoEvidenceAfterAssignment'
    }
    elseif ($managementNewestTimestamp -ge $managementRequiredEndUtc) {
        $result.ManagementLogCoverageStatus = 'Complete'
    }
    else {
        $result.ManagementLogCoverageStatus = 'Partial'
    }

    if ($null -ne $result.ExecutionIdentifiedUtc) {
        $result.AgentLogCoverageStatus = 'ExecutionMarkerFound'
    }
    elseif ($null -eq $agentOldestTimestamp -or $null -eq $agentNewestTimestamp) {
        $result.AgentLogCoverageStatus = 'NoParseableTimestamps'
    }
    elseif ($agentOldestTimestamp -gt $AssignmentUtc) {
        $result.AgentLogCoverageStatus = 'AssignmentPredatesRetainedLogs'
    }
    elseif ($agentNewestTimestamp -ge $coverageRequiredEndUtc) {
        $result.AgentLogCoverageStatus = 'Complete'
    }
    else {
        $result.AgentLogCoverageStatus = 'Partial'
    }

    if ($result.ManagementLogCoverageStatus -eq 'Complete' -and
        $result.AgentLogCoverageStatus -in @('Complete', 'ExecutionMarkerFound')) {
        $result.LogCoverageStatus = 'Complete'
    }
    elseif ($null -eq $oldestTimestamp -or $null -eq $newestTimestamp) {
        $result.LogCoverageStatus = 'NoParseableTimestamps'
    }
    else {
        $result.LogCoverageStatus = 'Partial'
    }

    $orderedPollTimestamps = @($pollTimestamps | Sort-Object)
    $result.PolicyPollTimestampsTruncated =
        $orderedPollTimestamps.Count -gt $MaximumPollTimestamps
    $result.PolicyPollTimestampsUtc = @(
        $orderedPollTimestamps |
            Select-Object -First $MaximumPollTimestamps |
            ForEach-Object { ConvertTo-UtcIso8601 -Value $_ }
    )

    foreach ($propertyName in @(
        'LogOldestRetainedUtc',
        'LogNewestRetainedUtc',
        'ManagementLogOldestRetainedUtc',
        'ManagementLogNewestRetainedUtc',
        'AgentLogOldestRetainedUtc',
        'AgentLogNewestRetainedUtc',
        'FirstManagementActivityUtc',
        'PolicyReceivedUtc',
        'PolicyProcessingUtc',
        'ScriptMaterializedUtc',
        'ExecutionIdentifiedUtc'
    )) {
        if ($null -ne $result[$propertyName]) {
            $result[$propertyName] =
                ConvertTo-UtcIso8601 -Value $result[$propertyName]
        }
    }

    return [pscustomobject]$result
}

function Get-DeploymentDelayClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $ImeEvidence,

        [Parameter()]
        $MdmCycleCount,

        [Parameter()]
        [Nullable[datetime]]$AssignmentUtc,

        [Parameter()]
        [Nullable[datetime]]$LastBootUtc
    )

    if ($null -eq $AssignmentUtc) {
        return [pscustomobject]@{
            Classification = 'InsufficientEvidence'
            Confidence     = 'Low'
        }
    }
    $mdmActivityCount = if ($null -eq $MdmCycleCount) {
        0
    } else {
        [int]$MdmCycleCount
    }
    $imeActivityCount =
        [int]$ImeEvidence.PolicyPollCountSinceAssignment +
        [int]$ImeEvidence.DeviceCheckInCountSinceAssignment +
        [int]$ImeEvidence.GenericWorkloadCheckInCount
    foreach ($lifecycleProperty in @(
            'PolicyReceivedUtc',
            'PolicyProcessingUtc',
            'ScriptMaterializedUtc',
            'ExecutionIdentifiedUtc'
        )) {
        if ($null -ne $ImeEvidence.$lifecycleProperty) {
            $imeActivityCount++
        }
    }

    if ($ImeEvidence.LogCoverageStatus -ne 'Complete' -or
        $ImeEvidence.LogEvidenceTruncated) {
        return [pscustomobject]@{
            Classification = 'InsufficientEvidence'
            Confidence     = 'Low'
        }
    }
    if ($null -ne $LastBootUtc -and
        [datetime]$LastBootUtc -gt [datetime]$AssignmentUtc -and
        $mdmActivityCount -eq 0 -and
        ($null -eq $ImeEvidence.FirstManagementActivityUtc -or
        [datetime]::Parse(
            $ImeEvidence.FirstManagementActivityUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ) -ge [datetime]$LastBootUtc)) {
        return [pscustomobject]@{
            Classification = 'ProbablyOfflineBeforeBoot'
            Confidence     = 'Medium'
        }
    }

    if ($imeActivityCount -eq 0 -and $mdmActivityCount -eq 0) {
        return [pscustomobject]@{
            Classification = 'ProbablyOfflineOrDisconnected'
            Confidence     = 'Medium'
        }
    }
    if ($null -ne $ImeEvidence.PolicyReceivedUtc -and
        $null -ne $ImeEvidence.ExecutionIdentifiedUtc) {
        $received = [datetime]::Parse(
            $ImeEvidence.PolicyReceivedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $execution = [datetime]::Parse(
            $ImeEvidence.ExecutionIdentifiedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        if (($execution - $received).TotalMinutes -le 5) {
            return [pscustomobject]@{
                Classification = 'PolicyDeliveredThenExecutedPromptly'
                Confidence     = 'High'
            }
        }

        return [pscustomobject]@{
            Classification = 'DelayAfterPolicyDelivery'
            Confidence     = 'High'
        }
    }
    if ($null -ne $ImeEvidence.PolicyProcessingUtc -or
        $null -ne $ImeEvidence.ScriptMaterializedUtc -or
        $null -ne $ImeEvidence.ExecutionIdentifiedUtc) {
        return [pscustomobject]@{
            Classification = 'PolicyLifecycleObservedWithoutReceiptMarker'
            Confidence     = 'Medium'
        }
    }
    if ([int]$ImeEvidence.PolicyPollCountSinceAssignment -eq 0) {
        return [pscustomobject]@{
            Classification = 'OnlineWithoutPowerShellPolling'
            Confidence     = 'Medium'
        }
    }
    if ($null -eq $ImeEvidence.PolicyReceivedUtc) {
        return [pscustomobject]@{
            Classification = 'PowerShellPollingPolicyNotReturned'
            Confidence     = 'High'
        }
    }
    if ($null -eq $ImeEvidence.ExecutionIdentifiedUtc) {
        return [pscustomobject]@{
            Classification = 'PolicyReceivedExecutionNotIdentified'
            Confidence     = 'High'
        }
    }

    return [pscustomobject]@{
        Classification = 'PolicyReceivedExecutionNotIdentified'
        Confidence     = 'High'
    }
}

function Get-PendingRestartState {
    [CmdletBinding()]
    param()

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('ComponentBasedServicing')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('WindowsUpdate')
    }

    $sessionManager = Get-ItemProperty `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($null -ne $sessionManager -and $sessionManager.PendingFileRenameOperations) {
        $reasons.Add('PendingFileRenameOperations')
    }

    return [pscustomobject]@{
        IsPending = $reasons.Count -gt 0
        Reasons   = @($reasons)
    }
}

function Get-InteractiveUser {
    [CmdletBinding()]
    param()

    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    return [string]$computerSystem.UserName
}

function Format-MaskedThumbprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Thumbprint)

    $normalized = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($normalized.Length -le 8) { return ('*' * $normalized.Length) }
    return '{0}...{1}' -f $normalized.Substring(0, 4), $normalized.Substring($normalized.Length - 4)
}

function Resolve-LogCollectorTelemetryConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter()][string]$Endpoint,
        [Parameter(Mandatory)][version]$MinimumModuleVersion
    )

    if ($Mode -eq 'Disabled') {
        return [pscustomobject]@{
            Enabled = $false; Category = 'Disabled'; Message = 'Telemetry is explicitly disabled.'
        }
    }
    if ($Mode -ne 'Certificate') {
        return [pscustomobject]@{
            Enabled = $false; Category = 'ConfigurationMissing'; Message = "Unsupported TelemetryMode '$Mode'."
        }
    }

    $originalModulePath = $env:PSModulePath
    $machineModulePath = @(
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsPowerShell\Modules')
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
    ) -join ';'
    try {
        $env:PSModulePath = $machineModulePath
        Import-Module LogCollector.Client -MinimumVersion $MinimumModuleVersion -Force -ErrorAction Stop
        $moduleConfiguration = Get-LogCollectorEndpointConfiguration -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Enabled = $false; Category = 'ConfigurationMissing'; Message = $_.Exception.Message
        }
    }
    finally {
        $env:PSModulePath = $originalModulePath
    }
    if ($moduleConfiguration.PSObject.Properties['SubmissionEnabled'] -and
        $moduleConfiguration.SubmissionEnabled -eq $false) {
        return [pscustomobject]@{
            Enabled = $false
            Category = 'Disabled'
            Message = 'Submission is disabled by the protected LogCollector configuration.'
        }
    }

    $endpointText = if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        [string]$moduleConfiguration.FrontendUrl
    } else {
        $Endpoint
    }
    $parsedEndpoint = $null
    if (-not [uri]::TryCreate($endpointText, [UriKind]::Absolute, [ref]$parsedEndpoint) -or
        $parsedEndpoint.Scheme -ne 'https' -or
        $parsedEndpoint.AbsolutePath -cne '/api/submit' -or
        -not [string]::IsNullOrEmpty($parsedEndpoint.UserInfo) -or
        -not [string]::IsNullOrEmpty($parsedEndpoint.Query) -or
        -not [string]::IsNullOrEmpty($parsedEndpoint.Fragment)) {
        return [pscustomobject]@{
            Enabled = $false
            Category = 'ConfigurationMissing'
            Message = 'TelemetryEndpoint must be an absolute HTTPS /api/submit URI without credentials, query string, or fragment.'
        }
    }

    return [pscustomobject]@{
        Enabled = $true
        Category = 'Configured'
        Message = 'LogCollector certificate authentication configured.'
        Endpoint = $parsedEndpoint
        ModuleConfiguration = $moduleConfiguration
    }
}

function Send-LogCollectorTelemetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$BudgetSeconds
    )

    $arguments = @{
        FrontendUrl = $Configuration.Endpoint
        TableName = $TableName
        Records = @($Payload)
        Source = $Source
        MaxAttempts = 1
        TimeoutSeconds = [Math]::Min($TimeoutSeconds, $BudgetSeconds)
        MaxDelaySeconds = $BudgetSeconds
        SkipDrain = $true
    }
    foreach ($setting in @(
        'CertificateThumbprint', 'CertificateSubjectLike', 'CertificateIssuerLike',
        'PkiRootCaThumbprints', 'PkiRootCaSubjects',
        'PkiIntermediateCaThumbprints', 'PkiIntermediateCaSubjects'
    )) {
        if ($Configuration.ModuleConfiguration.PSObject.Properties[$setting] -and
            $Configuration.ModuleConfiguration.$setting) {
            $arguments[$setting] = $Configuration.ModuleConfiguration.$setting
        }
    }

    $result = Send-LogCollectorData @arguments
    $delivered = $result.Disposition -eq 'Delivered'
    $statusCode = if ($null -ne $result.StatusCode) { [int]$result.StatusCode } else { $null }
    $category = if ($delivered) {
        'Sent'
    } elseif ($statusCode -in @(401, 403)) {
        'AuthenticationError'
    } elseif ([string]$result.Message -match '(?i)timeout|timed out') {
        'Timeout'
    } elseif ($statusCode -gt 0) {
        'HttpError'
    } else {
        'NetworkError'
    }

    return [pscustomobject]@{
        Success = $delivered
        Category = $category
        StatusCode = $statusCode
        Attempts = $result.Attempts
        RequestId = $Payload.ExecutionId
        Message = [string]$result.Message
        Disposition = [string]$result.Disposition
        SpoolDirectory = [string]$result.SpoolDirectory
    }
}
function Get-DeploymentTelemetryExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$EssentialOperationSucceeded
    )

    if ($EssentialOperationSucceeded) {
        return 0
    }
    return 1
}

function Invoke-FailOpenTelemetryOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Operation
    )

    try {
        $operationOutput = @(& $Operation)
        foreach ($item in $operationOutput) {
            Write-Information ([string]$item) -InformationAction Continue
        }
        return $true
    }
    catch {
        Add-TelemetryError -Operation 'TelemetryDelivery' -ErrorRecord $_
        Write-Warning ('Telemetry failed unexpectedly without blocking provisioning. Stage=TelemetryDelivery; Reason={0}; Decision=FailedOpen' -f
            $_.Exception.Message)
        return $false
    }
}

function Test-IsProcessAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-TelemetryPayload {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Creates an in-memory payload and does not change system state.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter',
        'ImeMaximumPollTimestamps',
        Justification = 'Used inside the deferred GetImeLogEvidence script block.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter',
        'ImeMaximumLogBytes',
        Justification = 'Used inside the deferred GetImeLogEvidence script block.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter',
        'ImeLogScanBudgetSeconds',
        Justification = 'Used inside the deferred GetImeLogEvidence script block.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ExecutionState,

        [Parameter(Mandatory)]
        [datetime]$CurrentExecutionUtc,

        [Parameter()]
        [Nullable[datetime]]$PolicyAssignmentTimestampUtc,

        [Parameter(Mandatory)]
        [int]$MdmEventLookbackHours,

        [Parameter(Mandatory)]
        [int]$MdmMaximumEvents,

        [Parameter()]
        [string]$ConfiguredPolicyId,

        [Parameter()]
        [string]$ExecutingScriptPath,

        [Parameter(Mandatory)]
        [int]$ImeMaximumPollTimestamps,

        [Parameter(Mandatory)]
        [long]$ImeMaximumLogBytes,

        [Parameter(Mandatory)]
        [int]$ImeLogScanBudgetSeconds
    )

    $operatingSystem = Invoke-TelemetryOperation -Name 'GetOperatingSystem' -Operation {
        Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    }
    $dsreg = Invoke-TelemetryOperation -Name 'GetDsRegStatus' -Operation {
        Get-DsRegStatus
    }
    $enrollment = Invoke-TelemetryOperation -Name 'GetMdmEnrollment' -Operation {
        Get-MdmEnrollment
    }
    $tasks = @(Invoke-TelemetryOperation -Name 'GetMdmScheduledTasks' -Operation {
        Get-MdmScheduledTask
    } -Default @())
    $tasks = @($tasks | Sort-Object LastRunTimeUtc -Descending)
    $tasksTruncated = $false
    while ($tasks.Count -gt 0) {
        $taskJson = ConvertTo-Json -InputObject @($tasks) -Depth 5 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($taskJson) -le 28672) {
            break
        }
        $tasksTruncated = $true
        $tasks = @($tasks | Select-Object -First ($tasks.Count - 1))
    }
    $eventWindowStartUtc = [datetime]::UtcNow.AddHours(-$MdmEventLookbackHours)
    $cycleEventLimit = 2000
    $allEvents = @(Invoke-TelemetryOperation -Name 'GetMdmEvents' -Operation {
        Get-MdmEvent -StartTimeUtc $eventWindowStartUtc `
            -MaximumEvents ($cycleEventLimit + 1)
    } -Default @())
    $cycleEventsTruncated = $allEvents.Count -gt $cycleEventLimit
    if ($cycleEventsTruncated) {
        $allEvents = @($allEvents | Select-Object -First $cycleEventLimit)
    }
    $oldestCycleEventUtc = $null
    if ($allEvents.Count -gt 0) {
        $oldestCycleEventUtc = [datetime]::Parse(
            $allEvents[-1].TimeCreatedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    $events = @($allEvents | Select-Object -First $MdmMaximumEvents)
    $eventsTruncated = $allEvents.Count -gt $MdmMaximumEvents
    while ($events.Count -gt 0) {
        $eventJson = ConvertTo-Json -InputObject @($events) -Depth 5 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($eventJson) -le 28672) {
            break
        }
        $eventsTruncated = $true
        $events = @($events | Select-Object -First ($events.Count - 1))
    }
    $pendingRestart = Invoke-TelemetryOperation -Name 'GetPendingRestartState' -Operation {
        Get-PendingRestartState
    }
    $lastBootUtc = $null
    $uptimeHours = $null
    $osVersion = $null
    $buildNumber = $null
    if ($null -ne $operatingSystem) {
        $lastBoot = if ($operatingSystem.LastBootUpTime -is [datetime]) {
            $operatingSystem.LastBootUpTime.ToUniversalTime()
        } else {
            [Management.ManagementDateTimeConverter]::ToDateTime(
                [string]$operatingSystem.LastBootUpTime
            ).ToUniversalTime()
        }
        $lastBootUtc = ConvertTo-UtcIso8601 -Value $lastBoot
        $uptimeHours = [Math]::Round(([datetime]::UtcNow - $lastBoot).TotalHours, 2)
        $osVersion = [string]$operatingSystem.Version
        $buildNumber = [string]$operatingSystem.BuildNumber
    }

    $lastTaskSync = $tasks |
        Where-Object { $_.LastRunTimeUtc } |
        Sort-Object LastRunTimeUtc -Descending |
        Select-Object -First 1
    $lastEventSync = $events |
        Sort-Object TimeCreatedUtc -Descending |
        Select-Object -First 1
    $lastKnownSync = @(
        if ($lastTaskSync) { $lastTaskSync.LastRunTimeUtc }
        if ($lastEventSync) { $lastEventSync.TimeCreatedUtc }
    ) | Sort-Object -Descending | Select-Object -First 1

    $assignment = if ($null -ne $PolicyAssignmentTimestampUtc -and
        [datetime]$PolicyAssignmentTimestampUtc -gt [datetime]::MinValue) {
        ([datetime]$PolicyAssignmentTimestampUtc).ToUniversalTime()
    } else {
        $null
    }
    $cycles = Get-EstimatedMdmCycle -Events $allEvents -SinceUtc $assignment `
        -WindowStartUtc $eventWindowStartUtc `
        -EventsTruncated $cycleEventsTruncated `
        -OldestRetainedEventUtc $oldestCycleEventUtc
    $firstExecution = ConvertTo-OptionalUtcIso8601 -Value $ExecutionState.FirstExecutionTimestampUtc
    $assignmentLatency = if ($null -ne $assignment -and $null -ne $firstExecution) {
        $firstExecutionDate = [datetime]::Parse(
            $firstExecution,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        [Math]::Round(($firstExecutionDate - $assignment).TotalMinutes, 2)
    } else {
        $null
    }
    $policyIdentity = Get-IntunePolicyIdentity `
        -ConfiguredPolicyId $ConfiguredPolicyId `
        -ExecutingScriptPath $ExecutingScriptPath
    $imeEvidence = if ($null -ne $assignment) {
        Invoke-TelemetryOperation -Name 'GetImeLogEvidence' -Operation {
            Get-ImeLogEvidence -AssignmentUtc $assignment `
                -CollectionEndUtc $CurrentExecutionUtc `
                -PolicyId $policyIdentity.EffectivePolicyId `
                -MaximumPollTimestamps $ImeMaximumPollTimestamps `
                -MaximumLogBytes $ImeMaximumLogBytes `
                -ScanBudgetSeconds $ImeLogScanBudgetSeconds
        }
    } else {
        $null
    }
    $lastBootForClassification = if ($null -ne $lastBootUtc) {
        [datetime]::Parse(
            $lastBootUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } else {
        $null
    }
    $delayClassification = if ($null -ne $imeEvidence) {
        Get-DeploymentDelayClassification -ImeEvidence $imeEvidence `
            -MdmCycleCount $cycles.Count `
            -AssignmentUtc $assignment `
            -LastBootUtc $lastBootForClassification
    } else {
        [pscustomobject]@{
            Classification = 'InsufficientEvidence'
            Confidence     = 'Low'
        }
    }
    $assignmentToImeExecution = $null
    $imePolicyToExecution = $null
    if ($null -ne $imeEvidence -and $imeEvidence.ExecutionIdentifiedUtc) {
        $imeExecution = [datetime]::Parse(
            $imeEvidence.ExecutionIdentifiedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $assignmentToImeExecution =
            [Math]::Round(($imeExecution - $assignment).TotalMinutes, 2)
        if ($imeEvidence.PolicyReceivedUtc) {
            $imeReceived = [datetime]::Parse(
                $imeEvidence.PolicyReceivedUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            )
            $imePolicyToExecution =
                [Math]::Round(($imeExecution - $imeReceived).TotalSeconds, 2)
        }
    }

    $tenantId = if ($dsreg -and $dsreg.TenantId) {
        $dsreg.TenantId
    } elseif ($enrollment) {
        $enrollment.TenantId
    } else {
        $null
    }
    $errorSnapshot = Get-TelemetryErrorSnapshot

    return [ordered]@{
        TimestampUtc                  = ConvertTo-UtcIso8601 -Value $CurrentExecutionUtc
        DeviceId                     = if ($enrollment) { $enrollment.EnrollmentId } else { $null }
        AzureAdDeviceId               = if ($dsreg) { $dsreg.AzureAdDeviceId } else { $null }
        ManagedDeviceId               = if ($enrollment) { $enrollment.ManagedDeviceId } else { $null }
        TenantDirectoryId             = $tenantId
        FirstExecutionTimestampUtc    = $ExecutionState.FirstExecutionTimestampUtc
        CurrentExecutionTimestampUtc  = ConvertTo-UtcIso8601 -Value $CurrentExecutionUtc
        AssignmentTimestampUtc        = if ($assignment) { ConvertTo-UtcIso8601 -Value $assignment } else { $null }
        AssignmentToExecutionMinutes  = $assignmentLatency
        ConfiguredIntunePolicyId       = $policyIdentity.ConfiguredPolicyId
        DetectedIntunePolicyId         = $policyIdentity.DetectedPolicyId
        IntunePolicyIdMatchStatus      = $policyIdentity.MatchStatus
        IMEPolicyPollCountSinceAssignment = if ($imeEvidence) {
            $imeEvidence.PolicyPollCountSinceAssignment
        } else { $null }
        IMEEmptyPolicyResponseCount    = if ($imeEvidence) {
            $imeEvidence.EmptyPolicyResponseCount
        } else { $null }
        IMEDeviceCheckInCountSinceAssignment = if ($imeEvidence) {
            $imeEvidence.DeviceCheckInCountSinceAssignment
        } else { $null }
        IMEGenericWorkloadCheckInCount = if ($imeEvidence) {
            $imeEvidence.GenericWorkloadCheckInCount
        } else { $null }
        IMEPolicyPollTimestampsUtc     = if ($imeEvidence) {
            @($imeEvidence.PolicyPollTimestampsUtc)
        } else { @() }
        IMEPolicyPollTimestampsTruncated = if ($imeEvidence) {
            $imeEvidence.PolicyPollTimestampsTruncated
        } else { $false }
        IMEPolicyReceivedUtc           = if ($imeEvidence) {
            $imeEvidence.PolicyReceivedUtc
        } else { $null }
        IMEPolicyProcessingUtc         = if ($imeEvidence) {
            $imeEvidence.PolicyProcessingUtc
        } else { $null }
        IMEScriptMaterializedUtc       = if ($imeEvidence) {
            $imeEvidence.ScriptMaterializedUtc
        } else { $null }
        IMEExecutionIdentifiedUtc      = if ($imeEvidence) {
            $imeEvidence.ExecutionIdentifiedUtc
        } else { $null }
        AssignmentToIMEExecutionMinutes = $assignmentToImeExecution
        IMEPolicyToExecutionSeconds    = $imePolicyToExecution
        IMELogOldestRetainedUtc        = if ($imeEvidence) {
            $imeEvidence.LogOldestRetainedUtc
        } else { $null }
        IMELogNewestRetainedUtc        = if ($imeEvidence) {
            $imeEvidence.LogNewestRetainedUtc
        } else { $null }
        IMEManagementLogOldestRetainedUtc = if ($imeEvidence) {
            $imeEvidence.ManagementLogOldestRetainedUtc
        } else { $null }
        IMEManagementLogNewestRetainedUtc = if ($imeEvidence) {
            $imeEvidence.ManagementLogNewestRetainedUtc
        } else { $null }
        IMEAgentLogOldestRetainedUtc   = if ($imeEvidence) {
            $imeEvidence.AgentLogOldestRetainedUtc
        } else { $null }
        IMEAgentLogNewestRetainedUtc   = if ($imeEvidence) {
            $imeEvidence.AgentLogNewestRetainedUtc
        } else { $null }
        IMEManagementLogCoverageStatus = if ($imeEvidence) {
            $imeEvidence.ManagementLogCoverageStatus
        } else { 'AssignmentTimestampNotProvided' }
        IMEAgentLogCoverageStatus      = if ($imeEvidence) {
            $imeEvidence.AgentLogCoverageStatus
        } else { 'AssignmentTimestampNotProvided' }
        IMELogFilesAnalyzed            = if ($imeEvidence) {
            $imeEvidence.LogFilesAnalyzed
        } else { 0 }
        IMELogFilesFailed              = if ($imeEvidence) {
            $imeEvidence.LogFilesFailed
        } else { 0 }
        IMELogCoverageStatus           = if ($imeEvidence) {
            $imeEvidence.LogCoverageStatus
        } else { 'AssignmentTimestampNotProvided' }
        IMELogEvidenceTruncated        = if ($imeEvidence) {
            $imeEvidence.LogEvidenceTruncated
        } else { $false }
        DeploymentDelayClassification = $delayClassification.Classification
        DeploymentDelayConfidence     = $delayClassification.Confidence
        LastBootTimeUtc               = $lastBootUtc
        UptimeHours                   = $uptimeHours
        OSVersion                     = $osVersion
        BuildNumber                   = $buildNumber
        RestartPending                = if ($pendingRestart) { $pendingRestart.IsPending } else { $null }
        RestartPendingReasons         = if ($pendingRestart) { @($pendingRestart.Reasons) } else { @() }
        MDMEnrollmentStatus           = if ($enrollment) { $enrollment.Status } else { 'Unknown' }
        MDMEnrollmentDateUtc          = if ($enrollment) { $enrollment.EnrollmentDateUtc } else { $null }
        MDMProviderId                 = if ($enrollment) { $enrollment.ProviderId } else { $null }
        MDMEnrollmentType             = if ($enrollment) {
            [string]$enrollment.EnrollmentType
        } else { $null }
        MDMEnrollmentState            = if ($enrollment) {
            [string]$enrollment.EnrollmentState
        } else { $null }
        LastKnownMDMSync              = $lastKnownSync
        EstimatedMDMCheckInCycles     = $cycles.Count
        MDMCheckInCycleMethod         = $cycles.Method
        MDMEventWindowStartUtc         = ConvertTo-UtcIso8601 -Value $eventWindowStartUtc
        MDMEventsTruncated             = $eventsTruncated
        MDMCycleEventsTruncated        = $cycleEventsTruncated
        MDMCycleOldestRetainedUtc      = if ($oldestCycleEventUtc) {
            ConvertTo-UtcIso8601 -Value $oldestCycleEventUtc
        } else { $null }
        MDMScheduledTasks             = $tasks
        MDMScheduledTasksTruncated    = $tasksTruncated
        MDMEvents                     = $events
        DeviceCorrelationId           = $ExecutionState.CorrelationId
        ExecutionId                   = [guid]::NewGuid().ToString()
        ScriptVersion                 = $ScriptVersion
        RegistryWriteSuccess          = $ExecutionState.RegistryWriteSuccess
        TelemetryMode                 = $TelemetryMode
        Errors                        = $errorSnapshot.Errors
        ErrorsTruncatedCount          = $errorSnapshot.TruncatedCount
    }
}

if ($env:INTUNE_DEPLOYMENT_TELEMETRY_SKIP_MAIN -eq '1') {
    return
}

$exitCode = Get-DeploymentTelemetryExitCode -EssentialOperationSucceeded $true
Initialize-LocalLogging
Write-Output "Starting Intune deployment telemetry version $ScriptVersion."

try {
    $currentExecutionUtc = [datetime]::UtcNow
    if (-not (Test-IsProcessAdministrator)) {
        throw 'The essential local collection must run elevated as SYSTEM or an administrator.'
    }
    if ($EventLookbackHours -lt 1 -or $EventLookbackHours -gt 168) {
        throw 'EventLookbackHours must be between 1 and 168.'
    }
    if ($MaximumMdmEvents -lt 1 -or $MaximumMdmEvents -gt 100) {
        throw 'MaximumMdmEvents must be between 1 and 100.'
    }
    if ($MaximumImePollTimestamps -lt 1 -or
        $MaximumImePollTimestamps -gt 500) {
        throw 'MaximumImePollTimestamps must be between 1 and 500.'
    }
    if ($MaximumImeLogBytes -lt 1MB -or $MaximumImeLogBytes -gt 128MB) {
        throw 'MaximumImeLogBytes must be between 1 MB and 128 MB.'
    }
    if ($ImeLogScanBudgetSeconds -lt 1 -or
        $ImeLogScanBudgetSeconds -gt 60) {
        throw 'ImeLogScanBudgetSeconds must be between 1 and 60.'
    }
    if ($AssignmentTimestampUtc -notmatch '(?i)(Z|[+-]\d{2}:\d{2})$') {
        throw 'Configure AssignmentTimestampUtc as ISO 8601 with Z or an explicit UTC offset.'
    }
    $parsedAssignment = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
        $AssignmentTimestampUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsedAssignment
    )) {
        throw 'AssignmentTimestampUtc is not a valid ISO 8601 timestamp.'
    }
    $assignmentValue = [Nullable[datetime]]$parsedAssignment.UtcDateTime
    $state = Get-OrCreateExecutionState
    $payload = New-TelemetryPayload -ExecutionState $state `
        -CurrentExecutionUtc $currentExecutionUtc `
        -PolicyAssignmentTimestampUtc $assignmentValue `
        -MdmEventLookbackHours $EventLookbackHours `
        -MdmMaximumEvents $MaximumMdmEvents `
        -ConfiguredPolicyId $IntunePolicyId `
        -ExecutingScriptPath $PSCommandPath `
        -ImeMaximumPollTimestamps $MaximumImePollTimestamps `
        -ImeMaximumLogBytes $MaximumImeLogBytes `
        -ImeLogScanBudgetSeconds $ImeLogScanBudgetSeconds

    $telemetryOperationSucceeded = Invoke-FailOpenTelemetryOperation -Operation {
        $telemetryConfiguration = Resolve-LogCollectorTelemetryConfiguration `
            -Mode $TelemetryMode -Endpoint $TelemetryEndpoint `
            -MinimumModuleVersion $LogCollectorModuleMinimumVersion
        $configuredEndpoint = if ($telemetryConfiguration.PSObject.Properties['Endpoint']) {
            $telemetryConfiguration.Endpoint.GetLeftPart([UriPartial]::Path)
        } else {
            '<not-configured>'
        }
        Write-Output ('Telemetry configuration: Mode={0}; Endpoint={1}; State={2}' -f
            $TelemetryMode, $configuredEndpoint, $telemetryConfiguration.Category)

        if (-not $telemetryConfiguration.Enabled) {
            Write-Warning ('Telemetry skipped without blocking provisioning. Mode={0}; Reason={1}; Decision=Skipped' -f
                $TelemetryMode, $telemetryConfiguration.Message)
        }
        elseif ($UploadTimeoutSeconds -lt 1 -or $UploadTimeoutSeconds -gt 300 -or
            $UploadBudgetSeconds -lt 1 -or $UploadBudgetSeconds -gt 900) {
            Write-Warning 'Telemetry timeout configuration is invalid. Decision=Skipped'
        }
        else {
            $configuredThumbprint =
                $telemetryConfiguration.ModuleConfiguration.CertificateThumbprint
            if (-not [string]::IsNullOrWhiteSpace($configuredThumbprint)) {
                Write-Output ('Telemetry certificate configured: Thumbprint={0}' -f
                    (Format-MaskedThumbprint -Thumbprint $configuredThumbprint))
            }
            $upload = Send-LogCollectorTelemetry `
                -Configuration $telemetryConfiguration `
                -Payload $payload `
                -TableName $LogCollectorTableName `
                -Source 'Intune-DeploymentTelemetry.ps1' `
                -TimeoutSeconds $UploadTimeoutSeconds `
                -BudgetSeconds $UploadBudgetSeconds

            if ($upload.Success) {
                Write-Output ('Telemetry accepted. Mode={0}; ExecutionId={1}; HTTP={2}; Attempts={3}; Decision=Sent' -f
                    $TelemetryMode, $payload.ExecutionId, $upload.StatusCode,
                    $upload.Attempts)
            }
            else {
                Write-Warning ('Telemetry failed without blocking provisioning. Category={0}; HTTP={1}; Attempts={2}; Disposition={3}; Spool={4}; Decision=FailedOpen' -f
                    $upload.Category, $upload.StatusCode, $upload.Attempts,
                    $upload.Disposition, $upload.SpoolDirectory)
            }
        }
    }
    if (-not $telemetryOperationSucceeded) {
        Write-Warning 'Telemetry failed unexpectedly without blocking provisioning. Decision=FailedOpen'
    }
}
catch {
    Add-TelemetryError -Operation 'Main' -ErrorRecord $_
    Write-Error $_ -ErrorAction Continue
    $exitCode = Get-DeploymentTelemetryExitCode -EssentialOperationSucceeded $false
}
finally {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Warning "Unable to stop transcript: $($_.Exception.Message)"
        }
    }
}

exit $exitCode
