#Requires -Version 5.1
# Version 1.4.5. Protected, bounded metadata-only diagnostics; no activity on import.
Set-StrictMode -Version Latest

$script:LogGuard = $null
$script:LogEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
$script:LogLockTimeoutMilliseconds = 10000
$script:LogEvents = @(
    'RunStarted', 'RunCompleted', 'RunFailed', 'ConfigurationLoaded',
    'CollectionStarted', 'CollectionCompleted', 'CollectionWarning',
    'CertificateSelectionStarted', 'CertificateSelected', 'CertificateUnavailable',
    'HttpAttempt', 'HttpResult', 'HttpRetry', 'SpoolQueued', 'SpoolQuarantined',
    'SpoolDrainStarted', 'SpoolDrainCompleted', 'TasksRegistered', 'TasksRemoved',
    'SubmissionDisabled'
)
$script:LogStrings = @(
    'Stage', 'PackageVersion', 'ModuleVersion', 'Mode', 'DeviceTableName', 'AppTableName',
    'TableName', 'Disposition', 'SpoolPath', 'SpoolDirectory', 'TaskName',
    'ExceptionType', 'ErrorCategory', 'WebExceptionStatus'
)
$script:LogCounts = @(
    'RecordCount', 'DeviceRecords', 'AppRecords', 'BatchCount', 'BodyBytes',
    'Attempt', 'MaxAttempts', 'StatusCode', 'Delivered', 'Quarantined', 'Remaining',
    'SourceLine', 'RootConstraintCount', 'IntermediateConstraintCount'
)
$script:LogBooleans = @('SubmissionEnabled', 'Stopped', 'Enabled')

function Get-InventoryLogGuard {
    if ($null -eq $script:LogGuard) {
        $script:LogGuard = Import-Module (Join-Path $PSScriptRoot 'Modules\InventorySpool.psm1') `
            -PassThru -Scope Local -DisableNameChecking -ErrorAction Stop
    }
    return $script:LogGuard
}

function Assert-InventoryLogFile {
    param([string] $Path, [switch] $AllowMissing)

    $guard = Get-InventoryLogGuard
    $exists = & $guard {
        param($Path, $AllowMissing)
        Assert-SpoolHierarchy -Path $Path -AllowMissing:$AllowMissing
    } $Path ([bool]$AllowMissing)
    if (-not $exists) { return $false }

    # The spool permits extra readers. Logs require the exact protected file
    # DACL used for atomic creation; never repair or bless an existing file.
    $expected = & $guard { New-SpoolSecurityDescriptor }
    $actual = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $access = [Security.AccessControl.AccessControlSections]::Access
    if (-not $actual.AreAccessRulesProtected -or
        $actual.GetSecurityDescriptorSddlForm($access) -cne $expected.GetSecurityDescriptorSddlForm($access)) {
        throw "Unsafe inventory log ACL: '$Path' must grant access only to SYSTEM and Administrators."
    }
    return $true
}

function New-InventoryLogFile {
    param([string] $Path)

    $guard = Get-InventoryLogGuard
    return (& $guard { param($Path) New-SpoolFileStream -Path $Path } $Path)
}

function Enter-InventoryLogLock {
    param([string] $Directory, [string] $Component)

    $path = Join-Path $Directory ('.{0}.lock' -f $Component)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            if (-not (Assert-InventoryLogFile -Path $path -AllowMissing)) {
                try { return (New-InventoryLogFile -Path $path) }
                catch [IO.IOException] {
                    if (($_.Exception.HResult -band 0xffff) -notin @(80, 183)) { throw }
                    # A competing creator is not permission to trust its file.
                    $null = Assert-InventoryLogFile -Path $path
                }
            }
            return [IO.File]::Open($path, [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if (($_.Exception.HResult -band 0xffff) -notin @(32, 33)) { throw }
            if ($timer.ElapsedMilliseconds -ge $script:LogLockTimeoutMilliseconds) {
                throw [TimeoutException]::new('Timed out acquiring the inventory log lock.', $_.Exception)
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Assert-InventoryLogContext {
    param([object] $Context)

    if ($null -eq $Context -or $Context -isnot [pscustomobject]) {
        throw 'An inventory log context is required.'
    }
    foreach ($name in @('RunId', 'Component', 'Directory', 'Path', 'MaxFileBytes', 'MaxArchives', 'MaxAgeDays')) {
        if ($null -eq $Context.PSObject.Properties[$name]) { throw "Missing log context field '$name'." }
    }
    if ($Context.RunId -isnot [guid] -or $Context.Component -cnotin @('Install', 'Inventory', 'Spool') -or
        $Context.Directory -isnot [string] -or $Context.Path -isnot [string] -or
        $Context.MaxFileBytes -isnot [int] -or $Context.MaxFileBytes -lt 1024 -or $Context.MaxFileBytes -gt 20971520 -or
        $Context.MaxArchives -isnot [int] -or $Context.MaxArchives -lt 0 -or $Context.MaxArchives -gt 32 -or
        $Context.MaxAgeDays -isnot [int] -or $Context.MaxAgeDays -lt 1 -or $Context.MaxAgeDays -gt 365) {
        throw 'Invalid inventory log context.'
    }
    $guard = Get-InventoryLogGuard
    $directory = & $guard { param($Path) Get-SpoolFullPath -Path $Path } $Context.Directory
    if ($Context.Path -cne (Join-Path $directory ($Context.Component + '.log'))) {
        throw 'The inventory log path does not match its component and directory.'
    }
}

function Invoke-InventoryLogMaintenance {
    param([object] $Context, [int] $IncomingBytes = 0)

    $cutoff = [DateTime]::UtcNow.AddDays(-$Context.MaxAgeDays)
    # Fixed numeric slots bound both names and count. Never enumerate or remove
    # unrelated files, other components, or arbitrary suffixes in this directory.
    $files = @()
    foreach ($slot in 0..32) {
        $path = $Context.Path
        if ($slot -gt 0) { $path += ".$slot" }
        if (Assert-InventoryLogFile -Path $path -AllowMissing) {
            $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $files += [pscustomobject]@{ Slot = $slot; File = $file }
        }
    }
    foreach ($entry in $files) {
        $file = $entry.File
        if ($entry.Slot -gt $Context.MaxArchives -or $file.Length -gt $Context.MaxFileBytes -or
            $file.CreationTimeUtc -lt $cutoff -or $file.LastWriteTimeUtc -lt $cutoff) {
            [IO.File]::Delete($file.FullName)
        }
    }
    $activeExists = Assert-InventoryLogFile -Path $Context.Path -AllowMissing
    if ($activeExists) {
        $active = Get-Item -LiteralPath $Context.Path -Force -ErrorAction Stop
        if ($active.Length + $IncomingBytes -gt $Context.MaxFileBytes) {
            if ($Context.MaxArchives -eq 0) {
                [IO.File]::Delete($Context.Path)
            }
            else {
                $last = '{0}.{1}' -f $Context.Path, $Context.MaxArchives
                if (Assert-InventoryLogFile -Path $last -AllowMissing) { [IO.File]::Delete($last) }
                for ($slot = $Context.MaxArchives - 1; $slot -ge 1; $slot--) {
                    $source = '{0}.{1}' -f $Context.Path, $slot
                    if (Assert-InventoryLogFile -Path $source -AllowMissing) {
                        [IO.File]::Move($source, ('{0}.{1}' -f $Context.Path, ($slot + 1)))
                    }
                }
                [IO.File]::Move($Context.Path, ($Context.Path + '.1'))
            }
            $activeExists = $false
        }
    }
    if (-not $activeExists) {
        $stream = New-InventoryLogFile -Path $Context.Path
        try { $stream.Flush($true) }
        finally { $stream.Dispose() }
        # Avoid NTFS filename tunneling retaining the previous active file's age.
        [IO.File]::SetCreationTimeUtc($Context.Path, [DateTime]::UtcNow)
    }
}

function ConvertTo-InventoryLogData {
    param([AllowEmptyCollection()] [hashtable] $Data = @{})

    $result = [ordered]@{}
    foreach ($key in $Data.Keys) {
        if ($key -isnot [string]) { throw 'Inventory log field names must be strings.' }
        $value = $Data[$key]
        if ($key -cin $script:LogStrings) {
            if ($value -isnot [string] -or $value.Length -gt 1024) { throw "Invalid log field '$key'." }
            $value = [string]$value
        }
        elseif ($key -cin $script:LogCounts -or $key -ceq 'HResult') {
            if (($value -isnot [byte] -and $value -isnot [sbyte] -and
                $value -isnot [int16] -and $value -isnot [uint16] -and
                $value -isnot [int32] -and $value -isnot [uint32] -and $value -isnot [int64]) -or
                ($key -cne 'HResult' -and $value -lt 0)) { throw "Invalid log field '$key'." }
            $value = [long]$value
        }
        elseif ($key -cin $script:LogBooleans) {
            if ($value -isnot [bool]) { throw "Invalid log field '$key'." }
            $value = [bool]$value
        }
        elseif ($key -cin @('DelaySeconds', 'DurationMs')) {
            if (($value -isnot [double] -and $value -isnot [single] -and $value -isnot [decimal] -and
                $value -isnot [int] -and $value -isnot [long]) -or
                [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or $value -lt 0) {
                throw "Invalid log field '$key'."
            }
            $value = [double]$value
        }
        elseif ($key -ceq 'Endpoint') {
            if ($value -isnot [string] -and $value -isnot [uri]) { throw "Invalid log field '$key'." }
            $text = [string]$value
            $uri = $null
            if ($text.Length -gt 1024 -or $text -notmatch '\Ahttps://' -or $text -match '[\\?#\x00-\x20]' -or
                -not [uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
                $uri.AbsoluteUri.Length -gt 1024) {
                throw 'Endpoint must be absolute HTTPS without credentials, query, or fragment.'
            }
            $value = $uri.AbsoluteUri
        }
        elseif ($key -ceq 'EntraDeviceId') {
            $id = [guid]::Empty
            if (($value -isnot [string] -and $value -isnot [guid]) -or
                [string]$value -cnotmatch '\A[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z' -or
                -not [guid]::TryParseExact([string]$value, 'D', [ref]$id)) {
                throw "Invalid log field '$key'."
            }
            $value = $id.ToString('D')
        }
        elseif ($key -cin @('ConfigurationSha256', 'CertificateThumbprint')) {
            $pattern = '\A[0-9a-fA-F]{64}\z'
            if ($key -ceq 'CertificateThumbprint') { $pattern = '\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z' }
            if ($value -isnot [string] -or $value -cnotmatch $pattern) { throw "Invalid log field '$key'." }
            $value = [string]$value
        }
        elseif ($key -ceq 'CertificateNotAfterUtc') {
            $date = [DateTimeOffset]::MinValue
            if ($value -is [DateTimeOffset]) { $date = $value }
            elseif ($value -is [DateTime] -and $value.Kind -eq [DateTimeKind]::Utc) {
                $date = [DateTimeOffset]$value
            }
            elseif ($value -is [string] -and $value.Length -le 64 -and
                $value -match '(?:Z|[+-]00:00)$' -and
                [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$date)) { }
            else { throw "Invalid log field '$key'." }
            $value = $date.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        else { throw "Unsupported inventory log field '$key'." }
        # Explicit scalar conversions above also discard ETS properties, which
        # Windows PowerShell 5.1 would otherwise serialize beside scalar values.
        $result[$key] = $value
    }
    return $result
}

function New-InventoryLogContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Install', 'Inventory', 'Spool')] [string] $Component,
        [string] $Directory = 'C:\ProgramData\LogCollector\Logs\CustomInventory',
        [ValidateRange(1024, 20971520)] [int] $MaxFileBytes = 2097152,
        [ValidateRange(0, 32)] [int] $MaxArchives = 4,
        [ValidateRange(1, 365)] [int] $MaxAgeDays = 14
    )

    $guard = Get-InventoryLogGuard
    $Directory = & $guard { param($Path) Get-SpoolFullPath -Path $Path } $Directory
    $Component = @('Install', 'Inventory', 'Spool') | Where-Object { $_ -eq $Component }
    $context = [pscustomobject]@{
        RunId = [guid]::NewGuid()
        Component = $Component
        Directory = $Directory
        Path = Join-Path $Directory ($Component + '.log')
        MaxFileBytes = $MaxFileBytes
        MaxArchives = $MaxArchives
        MaxAgeDays = $MaxAgeDays
    }
    $null = & $guard { param($Path) Assert-SpoolHierarchy -Path $Path -Directory -Create } $Directory
    $lock = Enter-InventoryLogLock -Directory $Directory -Component $Component
    try { Invoke-InventoryLogMaintenance -Context $context }
    finally { $lock.Dispose() }
    return $context
}

function Write-InventoryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $Event,
        [AllowEmptyCollection()] [hashtable] $Data = @{},
        [ValidateSet('Info', 'Warning', 'Error')] [string] $Level = 'Info'
    )

    if ($Event -cnotin $script:LogEvents) { throw 'Unsupported inventory log event.' }
    $safeData = ConvertTo-InventoryLogData -Data $Data
    Assert-InventoryLogContext -Context $Context
    $record = [ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        PID = $PID
        RunId = ([guid]$Context.RunId).ToString('D')
        Component = [string]$Context.Component
        Level = $Level
        Event = $Event
        Data = $safeData
    }
    $bytes = $script:LogEncoding.GetBytes((ConvertTo-Json -InputObject $record -Depth 3 -Compress) + "`n")
    if ($bytes.Length -gt [Math]::Min(16384, [Math]::Floor($Context.MaxFileBytes / 2))) {
        throw 'Inventory log record exceeds the record byte limit.'
    }
    $lock = Enter-InventoryLogLock -Directory $Context.Directory -Component $Context.Component
    try {
        Invoke-InventoryLogMaintenance -Context $Context -IncomingBytes $bytes.Length
        $null = Assert-InventoryLogFile -Path $Context.Path
        $stream = [IO.File]::Open($Context.Path, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 0) {
                $null = $stream.Seek(-1, [IO.SeekOrigin]::End)
                if ($stream.ReadByte() -ne 10) {
                    throw 'Inventory log has an incomplete final record; refusing to append.'
                }
            }
            $null = $stream.Seek(0, [IO.SeekOrigin]::End)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }
    finally { $lock.Dispose() }
}

function New-InventoryDiagnosticSink {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Context)

    $writeLogCommand = Get-Command -Name Write-InventoryLog -CommandType Function -ErrorAction Stop
    return {
        param(
            [Parameter(Mandatory, Position = 0)] [string] $Event,
            [Parameter(Position = 1)] [AllowEmptyCollection()] [hashtable] $Data = @{}
        )

        $level = 'Info'
        if ($Event -in @('CollectionWarning', 'CertificateUnavailable', 'SpoolQuarantined') -or
            ($Event -eq 'HttpResult' -and $Data['StatusCode'] -ne 202)) {
            $level = 'Warning'
        }
        & $writeLogCommand -Context $Context -Event $Event -Data $Data -Level $level
    }.GetNewClosure()
}

function Write-InventoryLogFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)] [string] $Stage
    )

    try {
        $sourceLine = 0
        if ($null -ne $ErrorRecord.InvocationInfo) {
            $sourceLine = $ErrorRecord.InvocationInfo.ScriptLineNumber
        }
        Write-InventoryLog -Context $Context -Event RunFailed -Level Error -Data @{
            Stage = $Stage
            ExceptionType = $ErrorRecord.Exception.GetType().FullName
            HResult = $ErrorRecord.Exception.HResult
            ErrorCategory = $ErrorRecord.CategoryInfo.Category.ToString()
            SourceLine = $sourceLine
        }
    }
    catch {
        # Only failure reporting is caught: the caller still owns and rethrows
        # the primary operation error. Never print the secondary error's text.
        $safeError = 'Inventory failure logging failed (ExceptionType={0}; HResult={1}).' -f
            $_.Exception.GetType().FullName, $_.Exception.HResult
        Write-Error -Message $safeError -ErrorId InventoryLogFailure -Category WriteError -ErrorAction Continue
    }
}

Export-ModuleMember -Function New-InventoryLogContext, Write-InventoryLog, New-InventoryDiagnosticSink, Write-InventoryLogFailure
