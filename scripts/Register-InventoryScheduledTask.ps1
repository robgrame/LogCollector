<#
.SYNOPSIS
    Registers the LogCollector inventory scheduled task: Wednesday and Saturday
    at 09:00 with an exact two-hour RandomDelay.

.DESCRIPTION
    Creates or updates a SYSTEM-context scheduled task that runs the collection
    script on the original Wednesday/Saturday 09:00 cadence.

    Why the delay is exactly PT2H and lives on the trigger:

      * The fleet-wide spread is what protects the single B1 frontend instance.
        Without it, thousands of devices fire at the same wall-clock minute and
        the ingress collapses under a thundering herd it can never absorb.

      * It belongs on the trigger, not in the script. A Start-Sleep inside the
        script would hold a PowerShell process (and its memory) for up to two
        hours on every endpoint, is invisible to Task Scheduler, and fights the
        execution time limit.

    RandomDelay is set on the trigger at creation AND re-asserted on the
    registered task object, then read back and verified. Task Scheduler accepts a
    malformed duration without complaint and simply does not apply it, so an
    unverified write is indistinguishable from a silent loss of the spread.

    Registration uses Register-ScheduledTask -Force rather than
    Unregister-then-Register. Unregistering first leaves a window in which the
    device has no inventory task at all; if the subsequent registration fails,
    the device is left permanently unmanaged.

.PARAMETER DaysOfWeek
    Days the task runs. Defaults to the original Wednesday/Saturday cadence.

.PARAMETER StartTime
    Local start time, HH:mm. Defaults to 09:00.

.PARAMETER RandomDelay
    ISO-8601 duration for the trigger delay. Defaults to PT2H and is validated,
    because an unparseable value is accepted by the API and silently disables the
    spread.

.EXAMPLE
    .\Register-InventoryScheduledTask.ps1 -FrontendUrl https://host/api/inventory

.NOTES
    Version 1.0.2.
    Must run elevated. Windows PowerShell 5.1.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $FrontendUrl,

    [string] $TableName = 'InventoryWindows_CL',

    [string] $ScriptPath = (Join-Path $PSScriptRoot 'Invoke-CustomInventory.ps1'),

    [string] $TaskName = 'LogCollector-Inventory',

    [string] $TaskPath = '\LogCollector\',

    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string[]] $DaysOfWeek = @('Wednesday', 'Saturday'),

    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string] $StartTime = '09:00',

    [ValidatePattern('^P(?=.)(\d+D)?(T(?=.)(\d+H)?(\d+M)?(\d+S)?)?$')]
    [string] $RandomDelay = 'PT2H',

    [string] $CertificateIssuerLike,

    [string] $CertificateThumbprint,

    [string] $SpoolDirectory = 'C:\ProgramData\LogCollector\Spool',

    [ValidateSet('Hardware', 'OperatingSystem', 'Software', 'Network', 'Security', 'Disk', 'BitLocker')]
    [string[]] $Collect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Collection script not found at '$ScriptPath'."
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath

function Assert-SupportedSpoolPath {
    <#
    .SYNOPSIS
        Fail-fast shape check on -SpoolDirectory.
    .DESCRIPTION
        This is NOT the security boundary. InventorySpool.psm1 owns spool trust
        (owner, DACL, reparse points) and re-validates it on the device at every
        run; that check stays authoritative.

        This one exists so a bad path is refused HERE, while an administrator is
        present and it costs one retyped argument, instead of registering
        successfully and then failing on every endpoint at the scheduled hour,
        surfacing only as a Last Run Result with no explanation.

        The spool must be an absolute path on a local fixed drive, so UNC shares,
        device paths, relative paths and removable or mapped drives are refused.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path.StartsWith('\\')) {
        throw "SpoolDirectory '$Path' is a UNC or device path. The spool must be on a local fixed drive."
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "SpoolDirectory '$Path' is not an absolute path."
    }

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "SpoolDirectory '$Path' has no drive root."
    }

    try {
        $driveType = (New-Object System.IO.DriveInfo $root).DriveType
    }
    catch {
        throw "SpoolDirectory '$Path' does not resolve to a usable local drive: $($_.Exception.Message)"
    }

    if ($driveType -ne [System.IO.DriveType]::Fixed) {
        throw "SpoolDirectory '$Path' is on a '$driveType' drive. The spool must be on a local fixed drive."
    }
}

Assert-SupportedSpoolPath -Path $SpoolDirectory

$argumentList = @(
    '-NoProfile'
    '-NonInteractive'
    '-ExecutionPolicy Bypass'
    ('-File "{0}"' -f $resolvedScriptPath)
    ('-FrontendUrl "{0}"' -f $FrontendUrl)
    ('-TableName "{0}"' -f $TableName)
    ('-SpoolDirectory "{0}"' -f $SpoolDirectory)
)

if ($CertificateIssuerLike) { $argumentList += ('-CertificateIssuerLike "{0}"' -f $CertificateIssuerLike) }
if ($CertificateThumbprint) { $argumentList += ('-CertificateThumbprint "{0}"' -f $CertificateThumbprint) }
if ($Collect) { $argumentList += ('-CollectCsv "{0}"' -f ($Collect -join ',')) }

$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument ($argumentList -join ' ')

$randomDelaySpan = [System.Xml.XmlConvert]::ToTimeSpan($RandomDelay)

$trigger = New-ScheduledTaskTrigger `
    -Weekly `
    -DaysOfWeek $DaysOfWeek `
    -At ([datetime]::ParseExact($StartTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)) `
    -RandomDelay $randomDelaySpan

# SYSTEM: the LocalMachine store holds the device certificate, BitLocker and TPM
# providers need local admin, and the spool lives under ProgramData. A user
# context would see none of them.
$principal = New-ScheduledTaskPrincipal `
    -UserId 'S-1-5-18' `
    -LogonType ServiceAccount `
    -RunLevel Highest

# NOTE: New-ScheduledTaskSettingsSet has no -DontStopIfGoingToSleep parameter;
# the real switch is -DontStopIfGoingOnBatteries. Passing the non-existent name
# is a parameter-binding error that aborts registration entirely, so the task is
# never created. Every switch used here is asserted against the live cmdlet
# metadata by tests/Pester/Register-InventoryScheduledTask.Tests.ps1.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 30)

if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Register scheduled task')) {

    # -Force updates an existing task in place. Unregistering first would leave a
    # window with no inventory task, and a failure in between would leave the
    # device with no task at all.
    $null = Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Collects Windows inventory and submits it over mTLS to the LogCollector frontend.' `
        -Force

    # Re-assert RandomDelay on the registered object. Some Windows builds drop the
    # trigger-level value during registration; this is cheap and idempotent.
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    $task.Triggers[0].RandomDelay = $RandomDelay
    $null = Set-ScheduledTask -InputObject $task

    $verify = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    $appliedDelay = $verify.Triggers[0].RandomDelay
    $appliedDays = $verify.Triggers[0].DaysOfWeek
    $appliedStart = $verify.Triggers[0].StartBoundary

    if ($appliedDelay -ne $RandomDelay) {
        throw "RandomDelay verification failed: expected '$RandomDelay' but the task reports '$appliedDelay'."
    }

    Write-Output ([pscustomobject]@{
        TaskName      = $TaskName
        TaskPath      = $TaskPath
        DaysOfWeek    = ($DaysOfWeek -join ',')
        StartTime     = $StartTime
        StartBoundary = $appliedStart
        RandomDelay   = $appliedDelay
        RunAs         = 'SYSTEM'
        ScriptPath    = $resolvedScriptPath
    })
}
