#Requires -Version 5.1
<#
.SYNOPSIS
Sends the values of one registry key through LogCollector.
.NOTES
Version 1.0.1. Run elevated or as SYSTEM.
#>
[CmdletBinding()]
param(
    [ValidatePattern('(?i)^HK(LM|CU):\\')]
    [string] $RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
    [ValidateNotNullOrEmpty()]
    [string[]] $ValueName = @('ProductName', 'DisplayVersion'),
    [string] $LogType = 'RegistryInventory'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptName = 'RegistryInventory.ps1'
$scriptVersion = '1.0.1'
$executionId = [guid]::NewGuid()

Import-Module LogCollector.Client -MinimumVersion 1.12.0 -ErrorAction Stop

function Write-RegistryLog {
    param(
        [Parameter(Mandatory)] [string] $EventName,
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Info', 'Warning', 'Error')] [string] $Level = 'Info'
    )

    # Local log:
    # %ProgramData%\<CustomerName>\RegistryInventory\Logs\RegistryInventory.log
    try {
        Write-CMTraceLog -ApplicationName 'RegistryInventory' -Component $scriptName `
            -Level $Level -Message $Message
    }
    catch {
        Write-Warning "Local CMTrace logging failed: $($_.Exception.Message)"
    }

    # Central log:
    # LogCollectorOperations_CL
    try {
        $null = Send-LogCollectorOperationalEvent `
            -PackageName 'Registry Inventory Example' `
            -PackageVersion $scriptVersion `
            -ScriptName $scriptName `
            -EventName $EventName `
            -Level $Level `
            -Message $Message `
            -ExecutionId $executionId
    }
    catch {
        Write-Warning "Central LogCollector logging failed: $($_.Exception.Message)"
    }
}

try {
    Write-RegistryLog -EventName 'CollectionStarted' `
        -Message "Registry inventory started; RegistryPath=$RegistryPath."

    $registryKey = Get-Item -LiteralPath $RegistryPath -ErrorAction Stop
    $availableValueNames = @($registryKey.GetValueNames())

    $records = @(
        foreach ($requestedValueName in $ValueName) {
            if ($availableValueNames -notcontains $requestedValueName) {
                $null = Write-RegistryLog -EventName 'RegistryValueMissing' -Level Warning `
                    -Message "Registry value was not found; RegistryPath=$RegistryPath; ValueName=$requestedValueName."
                continue
            }

            $valueKind = $registryKey.GetValueKind($requestedValueName)
            $value = $registryKey.GetValue(
                $requestedValueName,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

            $valueData = if ($valueKind -eq [Microsoft.Win32.RegistryValueKind]::Binary) {
                [Convert]::ToBase64String([byte[]] $value)
            }
            elseif ($value -is [array]) {
                $value -join '; '
            }
            else {
                [string] $value
            }

            [pscustomobject]@{
                RegistryPath = $RegistryPath
                ValueName    = $requestedValueName
                ValueType    = $valueKind.ToString()
                ValueData    = $valueData
            }
        }
    )

    if ($records.Count -eq 0) {
        Write-RegistryLog -EventName 'CollectionCompleted' -Level Warning `
            -Message "Registry inventory collected no matching values; RegistryPath=$RegistryPath."
        return
    }

    Write-RegistryLog -EventName 'CollectionCompleted' `
        -Message "Registry inventory collected; RegistryPath=$RegistryPath; RecordCount=$($records.Count)."

    # Send-LogAnalyticsData reads endpoint, PKI and enablement from LogCollector Core.
    $result = Send-LogAnalyticsData `
        -LogType $LogType `
        -Body $records `
        -Source $scriptName

    if ($result -and $result.Delivered) {
        Write-RegistryLog -EventName 'SubmissionCompleted' `
            -Message (
                "Registry inventory submission completed; TableName={0}; RecordCount={1}; " +
                "Disposition={2}." -f
                $result.TableName, $result.RecordCount, $result.Disposition)
    }
    elseif ($result) {
        Write-RegistryLog -EventName 'SubmissionDeferred' -Level Warning `
            -Message (
                "Registry inventory was retained for retry; TableName={0}; RecordCount={1}; " +
                "Disposition={2}." -f
                $result.TableName, $result.RecordCount, $result.Disposition)
    }

    $result
}
catch {
    $failure = $_
    $message = "Registry inventory failed; RegistryPath=$RegistryPath; Error=$($failure.Exception.Message)"

    try {
        Write-RegistryLog -EventName 'CollectionFailed' -Level Error -Message $message
    }
    catch {
        Write-Error "Operational logging also failed: $($_.Exception.Message)" -ErrorAction Continue
    }

    throw $failure
}
