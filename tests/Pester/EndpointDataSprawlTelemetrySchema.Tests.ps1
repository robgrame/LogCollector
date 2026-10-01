BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:MainBicepPath = Join-Path $script:RepoRoot 'infra\main.bicep'

    $script:MainBicepText = [IO.File]::ReadAllText($script:MainBicepPath)
    $tableStart = $script:MainBicepText.IndexOf(
        'var endpointDataSprawlTelemetryTable = {',
        [StringComparison]::Ordinal)
    if ($tableStart -lt 0) { throw 'The built-in Endpoint Data Sprawl table is missing from main.bicep.' }
    $remainingText = $script:MainBicepText.Substring($tableStart + 1)
    $nextVariableMatch = [regex]::Match(
        $remainingText,
        '(?m)^var additionalTelemetryTableNames =')
    if (-not $nextVariableMatch.Success) {
        throw 'Unable to find the end of the Endpoint Data Sprawl table definition.'
    }
    $nextVariable = $tableStart + 1 + $nextVariableMatch.Index
    $script:EndpointTableText = $script:MainBicepText.Substring(
        $tableStart,
        $nextVariable - $tableStart)

    $script:ExpectedColumns = [ordered]@{
        TimeGenerated      = 'datetime'
        CollectedAtUtc     = 'datetime'
        EntraDeviceId      = 'string'
        DeviceName         = 'string'
        IntuneDeviceId     = 'string'
        CorrelationId      = 'string'
        RecordIndex        = 'int'
        EventId            = 'string'
        Source             = 'string'
        ClientVersion      = 'string'
        UserCorrelationId  = 'string'
        EventTimeUtc       = 'datetime'
        CycleStartedAtUtc  = 'datetime'
        ExecutionId        = 'string'
        RecordType         = 'string'
        ClientType         = 'string'
        Status             = 'string'
        DryRun             = 'boolean'
        SourcePath         = 'string'
        DestinationPath    = 'string'
        FileName           = 'string'
        Extension          = 'string'
        SourceCreatedAtUtc = 'datetime'
        SourceModifiedAtUtc = 'datetime'
        Category           = 'string'
        CategoryProvider   = 'string'
        Bytes              = 'long'
        DurationMs         = 'long'
        ResultCode         = 'string'
        Detail             = 'string'
        Discovered         = 'int'
        Planned            = 'int'
        Moved              = 'int'
        Skipped            = 'int'
        Failed             = 'int'
        Deferred           = 'int'
        OmittedFileResults = 'int'
    }

    $script:ActualColumns = [ordered]@{}
    foreach ($match in [regex]::Matches(
            $script:EndpointTableText,
            "\{ name: '([^']+)', type: '([^']+)' \}")) {
        $script:ActualColumns[$match.Groups[1].Value] = $match.Groups[2].Value
    }
}

Describe 'Endpoint Data Sprawl Remediator telemetry schema' {
    It 'defines exactly the stable client and platform columns with the expected Azure Monitor types' {
        ($script:ActualColumns.Keys -join ',') |
            Should -Be ($script:ExpectedColumns.Keys -join ',')
        foreach ($column in $script:ExpectedColumns.GetEnumerator()) {
            $script:ActualColumns[$column.Key] | Should -Be $column.Value
        }
    }

    It 'does not retain the pre-rename destination' {
        $script:MainBicepText | Should -Not -Match 'OneDriveFileOrganizer_CL'
    }

    It 'generates the DCR streams and both Function App mappings from one table definition' {
        $script:MainBicepText | Should -Match ([regex]::Escape(
            "var ingestionStreamMap = join(map(telemetryTableDefinitions, table => " +
            "'`${table.name}=Custom-`${table.name}'), ';')"))
        ([regex]::Matches(
                $script:MainBicepText,
                [regex]::Escape("{ name: 'Ingestion__StreamMap', value: ingestionStreamMap }")
            )).Count | Should -Be 2
        $script:MainBicepText | Should -Match ([regex]::Escape(
            "streamDeclarations: toObject(telemetryTableDefinitions"))
        $script:MainBicepText | Should -Match ([regex]::Escape(
            "dataFlows: [for table in telemetryTableDefinitions"))
    }
}
