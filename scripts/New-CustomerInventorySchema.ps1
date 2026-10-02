#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the Log Analytics/DCR schema definition for a new customer inventory type,
    without requiring the customer to understand Azure Monitor, DCR JSON or the Portal wizard.

.DESCRIPTION
    This is an onboarding-automation tool, not part of the LogCollector Core packages. It
    never contacts Azure, never modifies infra\logcollector.bicepparam, and never creates or
    changes any DCR, table or Function App setting. It only reads local input and writes new
    report/artifact files that a human (the platform owner) reviews before touching the
    authoritative `additionalTelemetryTables` array described in
    docs\customer-add-telemetry-collection.md.

    Two input modes are supported:

      -SchemaSampleJsonPath   Safest and simplest path. Accepts a JSON array of representative
                              rows (for example the output of Export-LogCollectorSchema, or any
                              JSON array the customer can produce). Pure data transform, no
                              script execution at all.

      -CollectorScriptPath    Best-effort automatic capture. Runs the customer's existing
                              collection script in a separate child PowerShell process, with
                              the unqualified commands Send-LogCollectorData, Send-LogAnalyticsData,
                              Export-LogCollectorSchema, operational/local logging and the
                              LogCollector.Client Import-Module call replaced by local mocks
                              that only capture the inventory record objects the script would
                              have sent. Module-qualified calls to those commands are rejected
                              before execution so they cannot bypass the mocks. Dynamic command
                              invocation, runtime code evaluation, child jobs/processes and
                              module-qualified Import-Module are not supported in capture mode;
                              use -SchemaSampleJsonPath for such collectors.
                              (no real network call or module load happens through those three
                              calls). IMPORTANT: this is process separation for convenience, not
                              a security sandbox - every other statement in the customer's
                              script (other module calls, file/network/registry access, etc.)
                              still executes with the caller's own privileges. Only use this
                              mode against a script you already trust/have reviewed; otherwise
                              use -SchemaSampleJsonPath, which never executes anything. If
                              the script still fails (for example because it resolves a
                              certificate before building records), the tool reports the error
                              and recommends adding the tiny `-ExportSchema` branch documented
                              in docs\customer-add-telemetry-collection.md, or exporting a
                              sample JSON and using -SchemaSampleJsonPath instead.

    For every run the tool infers, per column, one of the Azure Monitor DCR column types
    (string, int, long, real, boolean, datetime, dynamic), flags column names that look like
    secrets or personal data, and produces:

      * <TableName>-schema-sample.json    Portal-compatible sample rows.
      * <TableName>-bicep-entry.txt       Ready-to-paste entry for additionalTelemetryTables.
      * <TableName>-onboarding-report.md  Plain-language summary and next steps.

    The bicep entry file is withheld (unless -Force is used) when a likely secret/PII column
    name is detected, so nobody pastes sensitive data into infrastructure-as-code by accident.

.PARAMETER CollectorScriptPath
    Path to the customer's existing collection script. Mutually exclusive with
    -SchemaSampleJsonPath.

.PARAMETER SchemaSampleJsonPath
    Path to a JSON array of representative sample rows. Mutually exclusive with
    -CollectorScriptPath.

.PARAMETER TableName
    Target Log Analytics custom table name, ending in `_CL`.

.PARAMETER Source
    Logical producer name recorded in the `Source` column of the sample rows.

.PARAMETER OutputDirectory
    Directory that receives the three output files. Created if missing. Defaults to
    ".\<TableName>-onboarding" under the current directory.

.PARAMETER MaxRecords
    Maximum number of sample rows considered for type inference (1-100). Default 5.

.PARAMETER Force
    Overwrite existing output files, and still emit the bicep entry file even when a
    likely secret/PII column name was detected (the warning is kept in the report either way).

.EXAMPLE
    .\New-CustomerInventorySchema.ps1 -SchemaSampleJsonPath .\sample.json -TableName 'AssetTagInventory_CL' -Source 'AssetTagCollector'

.EXAMPLE
    .\New-CustomerInventorySchema.ps1 -CollectorScriptPath .\Collect-AssetTags.ps1 -TableName 'AssetTagInventory_CL' -Source 'AssetTagCollector'
.NOTES
    Version 1.1.0.
#>
[CmdletBinding(DefaultParameterSetName = 'FromSample')]
param(
    [Parameter(ParameterSetName = 'FromScript', Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $CollectorScriptPath,

    [Parameter(ParameterSetName = 'FromSample', Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $SchemaSampleJsonPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,96}_CL$')]
    [string] $TableName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Source,

    [string] $OutputDirectory,

    [ValidateRange(1, 100)]
    [int] $MaxRecords = 5,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Column names reserved by the Worker; always emitted first, with fixed types, matching
# infra\main.bicep's inventoryColumns and every existing additionalTelemetryTables entry.
$script:PlatformColumns = [ordered]@{
    TimeGenerated  = 'datetime'
    CollectedAtUtc = 'datetime'
    EntraDeviceId  = 'string'
    DeviceName     = 'string'
    IntuneDeviceId = 'string'
    CorrelationId  = 'string'
    RecordIndex    = 'int'
    Source         = 'string'
}

# Heuristic, name-based secret/PII detector. Intentionally broad: false positives only cost a
# manual review, false negatives could leak a credential or personal data into infrastructure-as-code.
$script:SecretNamePattern = '(?i)(password|pwd|secret|token|api[_-]?key|credential|connection[_-]?string|private[_-]?key|passphrase|access[_-]?key|client[_-]?secret|iban|card[_-]?number|cvv|\bssn\b|\bpin\b|codice[_-]?fiscale|authorization|bearer|cookie|session[_-]?id|refresh[_-]?token|sas[_-]?token|e[-_]?mail|\bupn\b|user[_-]?principal[_-]?name|phone|address|first[_-]?name|last[_-]?name|display[_-]?name|employee[_-]?id)'

# Matches the DCR/Bicep column-name identifier policy: must start with a letter, then letters,
# digits or underscores only. Column names that don't match are rejected rather than escaped,
# to avoid ever emitting broken or injected Bicep syntax from an untrusted sample/script.
$script:SafeColumnNamePattern = '^[A-Za-z][A-Za-z0-9_]*$'

$script:IsoDateTimePattern = '^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})?)?$'

function Get-LcSampleValueCategory {
    <#
    .SYNOPSIS
    Classifies a single deserialized JSON value into one Azure Monitor DCR column type.
    Returns $null for a null value (no information contributed by this row).
    #>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { return 'datetime' }
    if ($Value -is [string]) {
        if ($Value -match $script:IsoDateTimePattern) { return 'datetime' }
        return 'string'
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        $asDouble = [double]$Value
        $isIntegral = ($asDouble -eq [math]::Truncate($asDouble))
        if (-not $isIntegral) { return 'real' }
        if ($asDouble -ge [int32]::MinValue -and $asDouble -le [int32]::MaxValue) { return 'int' }
        if ($asDouble -ge [int64]::MinValue -and $asDouble -le [int64]::MaxValue) { return 'long' }
        return 'real'
    }
    if ($Value -is [System.Collections.IDictionary]) { return 'dynamic' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'dynamic' }
    if ($Value -is [System.Collections.IEnumerable]) { return 'dynamic' }
    return 'string'
}

function Merge-LcColumnType {
    <#
    .SYNOPSIS
    Widens a set of per-row category observations for one column into a single DCR type,
    plus a flag telling the caller whether the observations were incompatible (a warning).
    #>
    param([string[]] $Categories)

    $distinct = @($Categories | Where-Object { $_ } | Select-Object -Unique)
    if ($distinct.Count -eq 0) { return @{ Type = 'string'; Mixed = $false } }
    if ($distinct.Count -eq 1) { return @{ Type = $distinct[0]; Mixed = $false } }

    $numericRank = @{ int = 1; long = 2; real = 3 }
    if (($distinct | Where-Object { -not $numericRank.ContainsKey($_) }).Count -eq 0) {
        $widest = ($distinct | Sort-Object { $numericRank[$_] } -Descending | Select-Object -First 1)
        return @{ Type = $widest; Mixed = $false }
    }

    # Incompatible categories (e.g. string and boolean). Fall back to string; the report flags it.
    return @{ Type = 'string'; Mixed = $true }
}

function Get-LcCapturedRecordsFromScript {
    <#
    .SYNOPSIS
    Runs the customer's collection script in a separate child process (not a security sandbox)
    and captures the record objects it would have submitted through Send-LogCollectorData,
    Send-LogAnalyticsData or Export-LogCollectorSchema, without any network call, logging
    side effect or device lookup.
    #>
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $CapturedOutputPath
    )

    $tokens = $null
    $parseErrors = $null
    $collectorAst = [Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath,
        [ref] $tokens,
        [ref] $parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Collector script '$ScriptPath' contains PowerShell parser errors."
    }
    $dynamicInvocations = @($collectorAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $null -eq $node.GetCommandName()
            }, $true))
    if ($dynamicInvocations.Count -gt 0) {
        throw ('Collector script uses dynamic command invocation, which is not supported by the ' +
            'schema harness because it cannot be verified against the mocked LogCollector commands. ' +
            'Use direct command calls or -SchemaSampleJsonPath.')
    }
    $unsupportedRuntimeCommands = @(
        'Invoke-Expression',
        'iex',
        'Invoke-Command',
        'icm',
        'Start-Job',
        'sajb',
        'Start-ThreadJob',
        'Start-Process',
        'saps',
        'pwsh',
        'pwsh.exe',
        'powershell',
        'powershell.exe',
        'cmd',
        'cmd.exe',
        'cscript',
        'cscript.exe',
        'wscript',
        'wscript.exe',
        'mshta',
        'mshta.exe'
    )
    $runtimeEvaluation = @($collectorAst.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
                $commandName = $node.GetCommandName()
                return $commandName -and $commandName -in $unsupportedRuntimeCommands
            }, $true))
    if ($runtimeEvaluation.Count -gt 0 -or
        $collectorAst.Extent.Text -match
            '(?i)\[\s*(System\.Management\.Automation\.)?ScriptBlock\s*\]\s*::\s*Create\s*\(') {
        throw ('Collector script uses runtime code evaluation or child execution, which is not ' +
            'supported by the schema harness. Use direct command calls or -SchemaSampleJsonPath.')
    }
    $mockedCommands = @(
        'Send-LogCollectorData',
        'Send-LogAnalyticsData',
        'Export-LogCollectorSchema',
        'Write-CMTraceLog',
        'Send-LogCollectorOperationalEvent'
    )
    $qualifiedBypasses = @($collectorAst.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
                $commandName = $node.GetCommandName()
                if (-not $commandName -or $commandName -notmatch '\\') { return $false }
                $leafName = $commandName.Substring($commandName.LastIndexOf('\') + 1)
                return $leafName -in $mockedCommands
            }, $true))
    if ($qualifiedBypasses.Count -gt 0) {
        $names = @($qualifiedBypasses | ForEach-Object { $_.GetCommandName() } | Select-Object -Unique)
        throw ("Collector script uses module-qualified LogCollector commands that would bypass schema mocks: " +
            "$($names -join ', '). Use the unqualified command names for schema capture.")
    }
    $qualifiedImports = @($collectorAst.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
                $commandName = $node.GetCommandName()
                return $commandName -and $commandName -match '\\Import-Module$'
            }, $true))
    if ($qualifiedImports.Count -gt 0) {
        throw ('Collector script uses module-qualified Import-Module, which would bypass the schema ' +
            'harness mock. Use unqualified Import-Module or -SchemaSampleJsonPath.')
    }

    $harnessPath = Join-Path ([IO.Path]::GetTempPath()) "LogCollector-SchemaHarness-$([guid]::NewGuid()).ps1"
    $optionsPath = Join-Path ([IO.Path]::GetTempPath()) "LogCollector-SchemaHarness-$([guid]::NewGuid()).json"

    # The harness never receives customer input as PowerShell source text: the script path and
    # output path travel through a JSON options file, so there is no string-injection surface.
    [pscustomobject]@{
        CollectorScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
        CapturedOutputPath  = $CapturedOutputPath
    } | ConvertTo-Json | Set-Content -LiteralPath $optionsPath -Encoding utf8

    $harnessScript = @'
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $OptionsPath)

$ErrorActionPreference = 'Stop'
$options = Get-Content -LiteralPath $OptionsPath -Raw | ConvertFrom-Json
$global:CapturedRecords = New-Object 'System.Collections.Generic.List[object]'
$global:HarnessErrors = New-Object 'System.Collections.Generic.List[string]'

function Import-Module {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] $Name,
        [Microsoft.PowerShell.Commands.ModuleSpecification[]] $FullyQualifiedName,
        [switch] $Force,
        [switch] $Global,
        [switch] $DisableNameChecking,
        [version] $MinimumVersion,
        [version] $RequiredVersion,
        [version] $MaximumVersion,
        [string] $Scope,
        [string] $Prefix,
        [object[]] $ArgumentList,
        [string[]] $Function,
        [string[]] $Cmdlet,
        [string[]] $Variable,
        [string[]] $Alias,
        [switch] $PassThru,
        [switch] $AsCustomObject,
        [switch] $NoClobber,
        [switch] $SkipEditionCheck,
        [switch] $UseWindowsPowerShell
    )
    $nameText = if ($FullyQualifiedName) {
        (@($FullyQualifiedName | ForEach-Object { $_.Name }) -join ',')
    }
    else {
        "$Name"
    }
    if ($nameText -match 'LogCollector\.Client') {
        Write-Verbose "Schema harness: skipping real Import-Module for '$nameText'."
        return
    }
    Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}

function Add-SchemaHarnessRecords {
    param([Parameter(Mandatory)] $Body)

    $records = if ($Body -is [byte[]]) {
        @(([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json))
    }
    elseif ($Body -is [string]) {
        @(($Body | ConvertFrom-Json))
    }
    else {
        @($Body)
    }
    foreach ($record in $records) {
        if ($null -ne $record) { $global:CapturedRecords.Add($record) }
    }
    return [object[]] $records
}

function Send-LogCollectorData {
    [CmdletBinding()]
    param(
        [Uri] $FrontendUrl,
        [string] $TableName,
        [object[]] $Records,
        [string] $Source,
        [hashtable] $Properties,
        [datetimeoffset] $CollectedAtUtc,
        [switch] $QueueOnly,
        [string] $SpoolRoot
    )
    foreach ($record in $Records) { $global:CapturedRecords.Add($record) }
    [pscustomobject]@{
        Disposition = 'CapturedForSchema'; StatusCode = 202; Attempts = 1
        Spooled = $false; SpoolDirectory = $null
    }
}

function Send-LogAnalyticsData {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $LogType,
        [Parameter(Mandatory)] $Body,
        [Alias('WorkspaceId')] [string] $CustomerId,
        [Alias('WorkspaceKey')] [string] $SharedKey,
        [Uri] $FrontendUrl,
        [string] $Source,
        [hashtable] $Properties,
        [switch] $QueueOnly,
        [scriptblock] $DiagnosticSink
    )
    $records = @(Add-SchemaHarnessRecords -Body $Body)
    $tableName = if ($LogType.EndsWith('_CL', [StringComparison]::OrdinalIgnoreCase)) {
        $LogType
    }
    else {
        "${LogType}_CL"
    }
    $response = [pscustomobject]@{
        StatusCode = 200; Delivered = $true; Disposition = 'CapturedForSchema'
        TableName = $tableName; RecordCount = $records.Count
        Detail = 'Upload payload captured for schema'
    }
    $response | Add-Member -MemberType ScriptMethod -Name ToString -Force -Value {
        '{0} : {1}' -f $this.StatusCode, $this.Detail
    }
    return $response
}

function Write-CMTraceLog {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [AllowEmptyString()] [string] $Message,
        [Parameter(Position = 1)] [string] $Level = 'Info',
        [string] $ApplicationName,
        [string] $CustomerName,
        [string] $Component,
        [string] $LogRoot,
        [int] $MaxFileBytes,
        [int] $MaxArchives,
        [switch] $SkipTrustCheck,
        [switch] $PassThru
    )
    if ($PassThru) {
        return [IO.Path]::Combine(
            [IO.Path]::GetTempPath(),
            'LogCollector-SchemaHarness',
            'Suppressed.log')
    }
}

function Send-LogCollectorOperationalEvent {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $PackageName,
        [Parameter(Mandatory)] [string] $PackageVersion,
        [Parameter(Mandatory)] [string] $ScriptName,
        [Parameter(Mandatory)] [string] $EventName,
        [Parameter(Mandatory)] [string] $Level,
        [Parameter(Mandatory)] [string] $Message,
        [guid] $ExecutionId,
        [Uri] $FrontendUrl,
        [switch] $QueueOnly,
        [scriptblock] $DiagnosticSink
    )
    [pscustomobject]@{
        StatusCode = 200; Delivered = $true; Disposition = 'SuppressedForSchema'
        TableName = 'LogCollectorOperations_CL'; RecordCount = 0
    }
}

function Export-LogCollectorSchema {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $TableName,
        [object[]] $Records,
        [string] $Source,
        [string] $OutputPath,
        [hashtable] $Properties,
        [int] $MaxRecords,
        [switch] $Force
    )
    foreach ($record in $Records) { $global:CapturedRecords.Add($record) }
    [pscustomobject]@{
        TableName = $TableName; StreamName = "Custom-$TableName"; OutputPath = $OutputPath
        RecordCount = $Records.Count; ColumnNames = @()
    }
}

try {
    $collector = Get-Command -Name $options.CollectorScriptPath -ErrorAction Stop
    $callArgs = @{}
    if ($collector.Parameters.ContainsKey('ExportSchema')) { $callArgs['ExportSchema'] = $true }
    foreach ($parameterName in @('FrontendUrl', 'StatePath', 'SpoolRoot')) {
        if (-not $collector.Parameters.ContainsKey($parameterName)) { continue }
        $parameterInfo = $collector.Parameters[$parameterName]
        $isMandatory = @($parameterInfo.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        }).Count -gt 0
        if (-not $isMandatory) { continue }
        $callArgs[$parameterName] = switch ($parameterInfo.ParameterType.Name) {
            'Uri' { 'https://schema-harness.invalid/api/submit' }
            default { 'schema-harness-placeholder' }
        }
    }
    & $options.CollectorScriptPath @callArgs | Out-Null
}
catch {
    $global:HarnessErrors.Add($_.Exception.Message)
}

[pscustomobject]@{
    Records = $global:CapturedRecords.ToArray()
    Errors  = $global:HarnessErrors.ToArray()
} | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $options.CapturedOutputPath -Encoding utf8
'@

    Set-Content -LiteralPath $harnessPath -Value $harnessScript -Encoding utf8

    try {
        $engine = (Get-Process -Id $PID).Path
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $harnessPath, '-OptionsPath', $optionsPath)
        Write-Verbose "Running collector script in a separate child process (not a sandbox): $engine $($arguments -join ' ')"
        $process = Start-Process -FilePath $engine -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Warning "Schema harness process exited with code $($process.ExitCode)."
        }
    }
    finally {
        Remove-Item -LiteralPath $harnessPath -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $CapturedOutputPath)) {
        throw "The collector script did not produce any capturable output. Verify it calls Send-LogCollectorData, Send-LogAnalyticsData or Export-LogCollectorSchema with real record objects."
    }
    $captured = Get-Content -LiteralPath $CapturedOutputPath -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $optionsPath -ErrorAction SilentlyContinue

    if ($captured.Errors -and $captured.Errors.Count -gt 0) {
        foreach ($message in $captured.Errors) { Write-Warning "Collector script reported: $message" }
    }
    if (-not $captured.Records -or $captured.Records.Count -eq 0) {
        throw "The collector script ran but never called Send-LogCollectorData, Send-LogAnalyticsData or Export-LogCollectorSchema with record objects. Add the '-ExportSchema' branch documented in docs\customer-add-telemetry-collection.md, or use -SchemaSampleJsonPath with a hand-produced sample."
    }
    return @($captured.Records)
}

function Get-LcRecordsFromSampleJson {
    param([Parameter(Mandatory)] [string] $Path)

    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $parsed) { throw "Sample file '$Path' is empty or not valid JSON." }
    $records = @($parsed)
    if ($records.Count -eq 0) { throw "Sample file '$Path' did not contain any record objects." }
    foreach ($record in $records) {
        if ($record -isnot [System.Collections.IDictionary] -and $record -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Sample file '$Path' must contain an array of JSON objects (one per record), not scalar or array values."
        }
    }
    return $records
}

function New-LcBicepColumnList {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory data transform; does not change any system or file state.')]
    param([Parameter(Mandatory)] [object[]] $Records, [Parameter(Mandatory)] [int] $MaxRecords)

    $sampled = @($Records | Select-Object -First $MaxRecords)
    $observations = [ordered]@{}
    foreach ($record in $sampled) {
        $propertyNames = if ($record -is [System.Collections.IDictionary]) {
            @($record.Keys | ForEach-Object { [string]$_ })
        }
        else {
            @($record.PSObject.Properties | Where-Object IsGettable | ForEach-Object Name)
        }
        foreach ($name in $propertyNames) {
            if ($script:PlatformColumns.Contains($name)) { continue }
            if ($name -notmatch $script:SafeColumnNamePattern) {
                throw "Column name '$name' is not a valid Azure Monitor/Bicep identifier (must start with a letter and contain only letters, digits or underscores). Rename this field in the source data or script before onboarding it."
            }
            $value = if ($record -is [System.Collections.IDictionary]) { $record[$name] } else { $record.$name }
            $category = Get-LcSampleValueCategory -Value $value
            if (-not $observations.Contains($name)) { $observations[$name] = New-Object 'System.Collections.Generic.List[string]' }
            if ($category) { $observations[$name].Add($category) }
        }
    }

    $customColumns = New-Object 'System.Collections.Generic.List[object]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $secretColumns = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in $observations.Keys) {
        if ($name -match $script:SecretNamePattern) { $secretColumns.Add($name) }
        $merge = Merge-LcColumnType -Categories @($observations[$name])
        if ($merge.Mixed) { $warnings.Add("Column '$name' has values of incompatible types across the sample; defaulted to 'string'. Review manually.") }
        $customColumns.Add([pscustomobject]@{ Name = $name; Type = $merge.Type })
    }

    [pscustomobject]@{
        CustomColumns = $customColumns
        Warnings      = $warnings.ToArray()
        SecretColumns = $secretColumns.ToArray()
    }
}

function Protect-LcNestedSecretValue {
    <#
    .SYNOPSIS
    Recursively walks a deserialized value (dictionary/PSCustomObject/array) and redacts any
    nested property whose name looks like a secret or personal data, so 'dynamic'-typed columns
    can't smuggle sensitive data past the top-level, column-name-only redaction check.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory data transform; does not change any system or file state.')]
    param($Value)

    if ($null -eq $Value) { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy[$key] = if ("$key" -match $script:SecretNamePattern) {
                '<redacted-possible-secret-or-PII-rerun-with--Force-to-include>'
            }
            else {
                Protect-LcNestedSecretValue -Value $Value[$key]
            }
        }
        return $copy
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = if ($property.Name -match $script:SecretNamePattern) {
                '<redacted-possible-secret-or-PII-rerun-with--Force-to-include>'
            }
            else {
                Protect-LcNestedSecretValue -Value $property.Value
            }
        }
        return [pscustomobject] $copy
    }

    if ($Value -is [string]) { return $Value }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { Protect-LcNestedSecretValue -Value $_ })
    }

    return $Value
}

function New-LcSchemaSampleRow {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory data transform; does not change any system or file state.')]
    param(
        [Parameter(Mandatory)] [object[]] $Records,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $CustomColumns,
        [Parameter(Mandatory)] [int] $MaxRecords,
        [Parameter(Mandatory)] [string] $Source,
        [AllowEmptyCollection()] [string[]] $SecretColumns = @(),
        [switch] $RevealSecretValues
    )

    $secretColumnSet = [System.Collections.Generic.HashSet[string]]::new([string[]] $SecretColumns, [System.StringComparer]::OrdinalIgnoreCase)
    $sampled = @($Records | Select-Object -First $MaxRecords)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt $sampled.Count; $index++) {
        $record = $sampled[$index]
        $row = [ordered]@{
            TimeGenerated  = [DateTimeOffset]::UtcNow.ToString('O')
            CollectedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            EntraDeviceId  = '00000000-0000-0000-0000-000000000000'
            DeviceName     = 'SCHEMA-EXAMPLE'
            IntuneDeviceId = '00000000-0000-0000-0000-000000000000'
            CorrelationId  = '00000000000000000000000000000000'
            RecordIndex    = $index
            Source         = $Source
        }
        foreach ($column in $CustomColumns) {
            $value = if ($record -is [System.Collections.IDictionary]) { $record[$column.Name] } else { $record.($column.Name) }
            if ($secretColumnSet.Contains($column.Name) -and -not $RevealSecretValues) {
                $value = '<redacted-possible-secret-or-PII-rerun-with--Force-to-include>'
            }
            elseif ($column.Type -eq 'dynamic' -and -not $RevealSecretValues) {
                # A 'dynamic' column can carry a nested object/array whose own keys look like a
                # secret even when the outer column name doesn't (e.g. Metadata.Password).
                $value = Protect-LcNestedSecretValue -Value $value
            }
            elseif ($column.Type -eq 'string' -and $null -ne $value -and $value -isnot [string]) {
                # Keeps the sample consistent with the inferred Bicep type, e.g. when mixed-type
                # observations were widened to 'string', or a nested object/array was observed.
                $value = ($value | ConvertTo-Json -Depth 24 -Compress)
            }
            $row[$column.Name] = $value
        }
        $rows.Add([pscustomobject]$row)
    }
    return $rows.ToArray()
}

function New-LcBicepEntryText {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory data transform; does not change any system or file state.')]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $CustomColumns)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('  {')
    $lines.Add("    name: '$TableName'")
    $lines.Add('    columns: [')
    foreach ($platformName in $script:PlatformColumns.Keys) {
        $lines.Add("      { name: '$platformName', type: '$($script:PlatformColumns[$platformName])' }")
    }
    foreach ($column in $CustomColumns) {
        $lines.Add("      { name: '$($column.Name)', type: '$($column.Type)' }")
    }
    $lines.Add('    ]')
    $lines.Add('  }')
    return ($lines -join [Environment]::NewLine)
}

function New-LcOnboardingReport {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory data transform; does not change any system or file state.')]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $CustomColumns,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Warnings,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $SecretColumns,
        [Parameter(Mandatory)] [bool] $BicepEntryWritten,
        [Parameter(Mandatory)] [bool] $UsedCollectorScript
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("# Onboarding automatico: $TableName")
    $lines.Add('')
    $lines.Add("Generato il $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC$((Get-Date).ToString('zzz')).")
    $lines.Add('')
    $lines.Add('## Cosa succede ora')
    $lines.Add('')
    $lines.Add('Nessuna modifica e stata applicata ad Azure. Sono stati generati solo file locali da rivedere.')
    $lines.Add('')
    if ($UsedCollectorScript) {
        $lines.Add('> Attenzione: lo script del cliente e stato eseguito in un processo PowerShell separato con solo le')
        $lines.Add('> chiamate a Send-LogCollectorData/Send-LogAnalyticsData/Export-LogCollectorSchema, logging e modulo LogCollector.Client simulati.')
        $lines.Add('> Non e un sandbox di sicurezza: qualsiasi altra istruzione dello script (accesso a rete, file,')
        $lines.Add('> credenziali, ecc.) viene comunque eseguita con i privilegi di chi ha lanciato lo strumento.')
        $lines.Add('> Eseguire questa modalita solo con script gia rivisti/fidati; in caso contrario usare')
        $lines.Add('> -SchemaSampleJsonPath, che non esegue mai codice del cliente.')
        $lines.Add('')
    }
    $lines.Add('## Colonne rilevate')
    $lines.Add('')
    $lines.Add('| Colonna | Tipo | Origine |')
    $lines.Add('|---|---|---|')
    foreach ($platformName in $script:PlatformColumns.Keys) {
        $lines.Add("| $platformName | $($script:PlatformColumns[$platformName]) | Colonna di piattaforma (riservata) |")
    }
    foreach ($column in $CustomColumns) {
        $lines.Add("| $($column.Name) | $($column.Type) | Dedotta dal campione |")
    }
    $lines.Add('')

    if ($SecretColumns.Count -gt 0) {
        $lines.Add('## Attenzione: possibili segreti o dati personali')
        $lines.Add('')
        foreach ($name in $SecretColumns) {
            $lines.Add("- **$name**: il nome suggerisce un possibile segreto o dato personale. Verificare e, se necessario, rimuovere o rinominare la colonna prima di procedere.")
        }
        $lines.Add('')
        if ($BicepEntryWritten) {
            $lines.Add('> La voce bicep e stata comunque generata perche e stato usato -Force. Rivedere con attenzione prima di consegnarla al proprietario della piattaforma.')
        }
        else {
            $lines.Add('> La voce bicep NON e stata generata per sicurezza. Rimuovere o rinominare le colonne segnalate e rieseguire lo strumento, oppure rieseguirlo con -Force se il rilevamento e un falso positivo confermato.')
        }
        $lines.Add('')
    }

    if ($Warnings.Count -gt 0) {
        $lines.Add('## Altri avvisi')
        $lines.Add('')
        foreach ($warning in $Warnings) { $lines.Add("- $warning") }
        $lines.Add('')
    }

    $lines.Add('## Prossimi passi per il proprietario della piattaforma')
    $lines.Add('')
    $lines.Add("1. Rivedere lo schema sopra e il file ``$TableName-bicep-entry.txt``.")
    $lines.Add('2. Incollare la voce come nuovo elemento dell''array `additionalTelemetryTables` in `infra\logcollector.bicepparam` (nessuna altra voce esistente va toccata).')
    $lines.Add('3. Aprire una Pull Request: la pipeline CI esistente valida automaticamente il bicep.')
    $lines.Add('4. Dopo il merge, ridistribuire l''infrastruttura: tabella, stream DCR, data flow e `Ingestion__StreamMap` su Frontend e Worker vengono generati automaticamente, senza altri passaggi manuali sul Portale Azure.')
    $lines.Add('5. Collaudare con un record reale seguendo la sezione 11 di docs\customer-add-telemetry-collection.md.')
    $lines.Add('')
    $lines.Add('## Nota per il cliente')
    $lines.Add('')
    $lines.Add("Non e richiesta alcuna azione tecnica aggiuntiva: lo script di raccolta puo restare cosi com'e ed inviare i dati con `Send-LogCollectorData` o `Send-LogAnalyticsData` una volta che il proprietario della piattaforma ha completato i passi sopra.")

    return ($lines -join [Environment]::NewLine)
}

# --- Main ---------------------------------------------------------------------------------

if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Get-Location) "$TableName-onboarding" }
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}

$records = if ($PSCmdlet.ParameterSetName -eq 'FromScript') {
    $capturedPath = Join-Path ([IO.Path]::GetTempPath()) "LogCollector-Captured-$([guid]::NewGuid()).json"
    try {
        Get-LcCapturedRecordsFromScript -ScriptPath $CollectorScriptPath -CapturedOutputPath $capturedPath
    }
    finally {
        Remove-Item -LiteralPath $capturedPath -ErrorAction SilentlyContinue
    }
}
else {
    Get-LcRecordsFromSampleJson -Path $SchemaSampleJsonPath
}

Write-Verbose "Captured $($records.Count) sample record(s) for table '$TableName'."

$schema = New-LcBicepColumnList -Records $records -MaxRecords $MaxRecords
$sampleRows = New-LcSchemaSampleRow -Records $records -CustomColumns $schema.CustomColumns -MaxRecords $MaxRecords `
    -Source $Source -SecretColumns $schema.SecretColumns -RevealSecretValues:$Force

$samplePath = Join-Path $OutputDirectory "$TableName-schema-sample.json"
$bicepEntryPath = Join-Path $OutputDirectory "$TableName-bicep-entry.txt"
$reportPath = Join-Path $OutputDirectory "$TableName-onboarding-report.md"

foreach ($path in @($samplePath, $bicepEntryPath, $reportPath)) {
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "Output file already exists: $path. Use -Force to overwrite."
    }
}

$sampleRows | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $samplePath -Encoding utf8

$bicepEntryWritten = $false
if ($schema.SecretColumns.Count -eq 0 -or $Force) {
    New-LcBicepEntryText -CustomColumns $schema.CustomColumns | Set-Content -LiteralPath $bicepEntryPath -Encoding utf8
    $bicepEntryWritten = $true
}
else {
    Write-Warning "Not emitting $bicepEntryPath because possible secret/PII column names were detected: $($schema.SecretColumns -join ', '). Re-run with -Force to override after review."
}

New-LcOnboardingReport -CustomColumns $schema.CustomColumns -Warnings $schema.Warnings `
    -SecretColumns $schema.SecretColumns -BicepEntryWritten $bicepEntryWritten `
    -UsedCollectorScript ($PSCmdlet.ParameterSetName -eq 'FromScript') |
    Set-Content -LiteralPath $reportPath -Encoding utf8

[pscustomobject]@{
    TableName        = $TableName
    Source           = $Source
    RecordCount      = $records.Count
    CustomColumns    = $schema.CustomColumns
    Warnings         = $schema.Warnings
    SecretColumns    = $schema.SecretColumns
    BicepEntryWritten = $bicepEntryWritten
    SchemaSamplePath = $samplePath
    BicepEntryPath   = if ($bicepEntryWritten) { $bicepEntryPath } else { $null }
    ReportPath       = $reportPath
}
