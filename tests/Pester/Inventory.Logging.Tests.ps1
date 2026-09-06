BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $package = Join-Path $TestDrive 'package'
    $null = New-Item -ItemType Directory -Path (Join-Path $package 'Modules')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src\InventoryPackage\Inventory.Logging.psm1') -Destination $package
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src\Client\InventorySpool.psm1') -Destination (Join-Path $package 'Modules')
    $script:LoggerPath = Join-Path $package 'Inventory.Logging.psm1'
    $script:GuardPath = Join-Path $package 'Modules\InventorySpool.psm1'
    Import-Module $script:GuardPath -Force -DisableNameChecking
    Import-Module $script:LoggerPath -Force
}

Describe 'Inventory logging isolated filesystem unit tests' {
    BeforeEach {
        $script:LogRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName InventorySpool Assert-SpoolHierarchy {
            param($Path, [switch] $Directory, [switch] $AllowMissing, [switch] $Create)
            if ($Create) { $null = [IO.Directory]::CreateDirectory($Path) }
            if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { return $true }
            if ($AllowMissing) { return $false }
            throw [IO.FileNotFoundException]::new('Fixture path missing.')
        }
        Mock -ModuleName InventorySpool New-SpoolFileStream {
            param($Path)
            [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        Mock -ModuleName Inventory.Logging Get-Acl {
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
            return $acl
        }
    }

    It 'exports only the four API functions and does not initialize or import the guard on import' -Tag Adapters {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force).Count
        Import-Module $script:LoggerPath -Force
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force).Count | Should -Be $before
        $exports = @((Get-Module Inventory.Logging).ExportedFunctions.Keys | Sort-Object)
        ($exports -join ',') | Should -Be 'New-InventoryDiagnosticSink,New-InventoryLogContext,Write-InventoryLog,Write-InventoryLogFailure'
        InModuleScope Inventory.Logging { $script:LogGuard | Should -BeNullOrEmpty }
    }

    It 'initializes storage with the specified defaults and separate component paths' {
        foreach ($component in @('Install', 'Inventory', 'Spool')) {
            $context = New-InventoryLogContext -Component $component -Directory $script:LogRoot
            $context.RunId | Should -BeOfType ([guid])
            $context.Component | Should -Be $component
            $context.Path | Should -Be (Join-Path $script:LogRoot "$component.log")
            $context.MaxFileBytes | Should -Be 2097152
            $context.MaxArchives | Should -Be 4
            $context.MaxAgeDays | Should -Be 14
            (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
        }
        Should -Invoke -ModuleName InventorySpool Assert-SpoolHierarchy -ParameterFilter { $Directory -and $Create } -Times 3 -Exactly
        Should -Invoke -ModuleName InventorySpool New-SpoolFileStream -Times 6 -Exactly
    }

    It 'returns only a positional callback with captured context and writer command' -Tag Adapters {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $runId = $context.RunId.ToString('D')
        $path = $context.Path
        $result = @(New-InventoryDiagnosticSink -Context $context)
        $result.Count | Should -Be 1
        $sink = $result[0]
        $sink | Should -BeOfType ([scriptblock])
        (Get-Item -LiteralPath $path).Length | Should -Be 0
        $context = $null
        $output = @(& {
            param($Callback)
            function Write-InventoryLog { throw 'A caller shadow must not replace the captured command.' }
            & $Callback 'RunStarted' @{}
        } $sink)
        $output.Count | Should -Be 0
        $record = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $record.RunId | Should -Be $runId
        $record.Event | Should -Be RunStarted
    }

    It 'assigns warning and information levels to diagnostic callbacks without swallowing write errors' -Tag Adapters {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $sink = New-InventoryDiagnosticSink -Context $context
        foreach ($event in @('CollectionWarning', 'CertificateUnavailable', 'SpoolQuarantined')) {
            & $sink $event @{}
        }
        & $sink 'HttpResult' @{ StatusCode = 503 }
        & $sink 'HttpResult' @{ StatusCode = 202 }
        & $sink 'CollectionCompleted' @{}
        $records = @([IO.File]::ReadAllLines($context.Path) | ForEach-Object { $_ | ConvertFrom-Json })
        ($records.Level -join ',') | Should -Be 'Warning,Warning,Warning,Warning,Info,Info'
        { & $sink 'RunStarted' @{ Message = 'must-not-persist' } } | Should -Throw '*Unsupported*'
        Mock -ModuleName InventorySpool Assert-SpoolHierarchy { throw [IO.IOException]::new('fixture writer failed') }
        { & $sink 'RunStarted' @{} } | Should -Throw '*fixture writer failed*'
    }

    It 'logs only approved failure metadata and preserves the primary error for the caller' -Tag Adapters {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $primary = $null
        $rethrown = $null
        try {
            try { throw [InvalidOperationException]::new('secret-primary-message') }
            catch {
                $primary = $_
                @(Write-InventoryLogFailure -Context $context -ErrorRecord $_ -Stage Collect).Count | Should -Be 0
                throw
            }
        }
        catch { $rethrown = $_ }
        [object]::ReferenceEquals($primary.Exception, $rethrown.Exception) | Should -BeTrue
        $rethrown.FullyQualifiedErrorId | Should -BeExactly $primary.FullyQualifiedErrorId
        $rethrown.InvocationInfo.ScriptLineNumber | Should -Be $primary.InvocationInfo.ScriptLineNumber
        $raw = [IO.File]::ReadAllText($context.Path)
        $raw | Should -Not -Match 'secret-primary-message|FullyQualifiedErrorId|StackTrace|TargetObject'
        $record = $raw | ConvertFrom-Json
        $record.Event | Should -Be RunFailed
        $record.Level | Should -Be Error
        ($record.Data.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should -Be 'ErrorCategory,ExceptionType,HResult,SourceLine,Stage'
        $record.Data.Stage | Should -Be Collect
        $record.Data.ExceptionType | Should -Be $primary.Exception.GetType().FullName
        $record.Data.HResult | Should -Be $primary.Exception.HResult
        $record.Data.ErrorCategory | Should -Be $primary.CategoryInfo.Category.ToString()
        $record.Data.SourceLine | Should -Be $primary.InvocationInfo.ScriptLineNumber
        $record.Data.SourceLine | Should -BeGreaterThan 0
    }

    It 'uses zero for absent invocation information without serializing error IDs or targets' -Tag Adapters {
        $context = New-InventoryLogContext -Component Install -Directory $script:LogRoot
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [IO.IOException]::new('secret-message'), 'secret-error-id',
            [System.Management.Automation.ErrorCategory]::ReadError, 'secret-target')
        Write-InventoryLogFailure -Context $context -ErrorRecord $errorRecord -Stage Initialize
        $raw = [IO.File]::ReadAllText($context.Path)
        $raw | Should -Not -Match 'secret'
        $record = $raw | ConvertFrom-Json
        $record.Data.SourceLine | Should -Be 0
        $record.Data.ErrorCategory | Should -Be ReadError
    }

    It 'emits a safe secondary error even under Stop preference without masking the original failure' -Tag Adapters {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        Mock -ModuleName InventorySpool Assert-SpoolHierarchy {
            throw [UnauthorizedAccessException]::new('secret-secondary-message')
        }
        $primary = $null
        $rethrown = $null
        $secondary = @()
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Stop'
            try {
                try { throw [InvalidOperationException]::new('secret-primary-message') }
                catch {
                    $primary = $_
                    $secondary = @(Write-InventoryLogFailure -Context $context -ErrorRecord $_ -Stage Collect -ErrorAction Stop 2>&1)
                    throw
                }
            }
            catch { $rethrown = $_ }
        }
        finally { $ErrorActionPreference = $oldPreference }
        [object]::ReferenceEquals($primary.Exception, $rethrown.Exception) | Should -BeTrue
        $rethrown.FullyQualifiedErrorId | Should -BeExactly $primary.FullyQualifiedErrorId
        $secondary.Count | Should -Be 1
        $secondary[0] | Should -BeOfType ([System.Management.Automation.ErrorRecord])
        $secondary[0].Exception.Message | Should -Match 'ExceptionType=System.UnauthorizedAccessException; HResult=-2147024891'
        $secondary[0].Exception.Message | Should -Not -Match 'secret|Collect'
        (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
    }

    It 'writes UTF8 JSONL without BOM or success output with UTC PID and stable per-context RunId' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $stage = "quoted `"value`"`r`nnext " + [char]0x00e9
        @(Write-InventoryLog -Context $context -Event RunStarted -Data @{ Stage = $stage }).Count | Should -Be 0
        @(Write-InventoryLog -Context $context -Event RunCompleted -Data @{} -Level Warning).Count | Should -Be 0
        $raw = [IO.File]::ReadAllBytes($context.Path)
        $raw[0] | Should -Be 123
        $raw[-1] | Should -Be 10
        $lines = [IO.File]::ReadAllLines($context.Path)
        $lines.Count | Should -Be 2
        $first = $lines[0] | ConvertFrom-Json
        $first.Data.Stage | Should -BeExactly $stage
        $lines[0] | Should -Match '"TimestampUtc":"[^"]+Z"'
        $first.PID | Should -Be $PID
        $first.RunId | Should -Be $context.RunId.ToString('D')
        $first.Component | Should -Be Inventory
        $first.Level | Should -Be Info
        ($lines[1] | ConvertFrom-Json).RunId | Should -Be $first.RunId
        (New-InventoryLogContext -Component Inventory -Directory $script:LogRoot).RunId | Should -Not -Be $context.RunId
    }

    It 'accepts all parent events and the complete scalar schema' {
        $context = New-InventoryLogContext -Component Install -Directory $script:LogRoot
        $data = @{
            Stage = 'Configure'; PackageVersion = '1.4.5'; ModuleVersion = '1.0.0'; Mode = 'Install'
            Endpoint = 'https://example.invalid/api/inventory'; ConfigurationSha256 = ('a' * 64)
            SubmissionEnabled = $true; DeviceTableName = 'Device_CL'; AppTableName = 'App_CL'
            EntraDeviceId = [guid]::NewGuid(); CertificateThumbprint = ('b' * 40)
            CertificateNotAfterUtc = [DateTime]::UtcNow; TableName = 'Device_CL'
            RecordCount = 1; DeviceRecords = 1; AppRecords = 0; BatchCount = 1; BodyBytes = 100
            Attempt = 1; MaxAttempts = 3; StatusCode = 202; Disposition = 'Delivered'; DelaySeconds = 0.5
            SpoolPath = 'C:\Trusted\entry.json'; SpoolDirectory = 'C:\Trusted'; Delivered = 1
            Quarantined = 0; Remaining = 0; Stopped = $false; TaskName = 'Inventory'; Enabled = $true
            SourceLine = 42; ExceptionType = 'System.IO.IOException'; HResult = -2147024891
            ErrorCategory = 'PermissionDenied'; WebExceptionStatus = 'Timeout'
            RootConstraintCount = 1; IntermediateConstraintCount = 0; DurationMs = 15.25
        }
        $events = @(
            'RunStarted', 'RunCompleted', 'RunFailed', 'ConfigurationLoaded',
            'CollectionStarted', 'CollectionCompleted', 'CollectionWarning',
            'CertificateSelectionStarted', 'CertificateSelected', 'CertificateUnavailable',
            'HttpAttempt', 'HttpResult', 'HttpRetry', 'SpoolQueued', 'SpoolQuarantined',
            'SpoolDrainStarted', 'SpoolDrainCompleted', 'TasksRegistered', 'TasksRemoved', 'SubmissionDisabled'
        )
        foreach ($event in $events) {
            Write-InventoryLog -Context $context -Event $event -Data $data
        }
        $records = @([IO.File]::ReadAllLines($context.Path) | ForEach-Object { $_ | ConvertFrom-Json })
        $records.Count | Should -Be $events.Count
        @($records[0].Data.PSObject.Properties).Count | Should -Be $data.Count
        [IO.File]::ReadAllLines($context.Path)[0] | Should -Match '"CertificateNotAfterUtc":"[^"]+Z"'
    }

    It 'rejects unknown events and arbitrary secret-bearing fields without writing any record' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        { Write-InventoryLog -Context $context -Event Unknown } | Should -Throw '*event*'
        foreach ($key in @('Message', 'Body', 'Payload', 'Signature', 'PrivateKey', 'Headers',
            'Response', 'ErrorRecord', 'Exception', 'Configuration', 'stage')) {
            $data = @{}; $data[$key] = 'secret-do-not-persist'
            { Write-InventoryLog -Context $context -Event RunFailed -Data $data } | Should -Throw '*field*'
        }
        (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
    }

    It 'rejects collections coercions invalid scalar types and unbounded strings' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        foreach ($data in @(
            @{ Stage = @('one', 'two') }, @{ Stage = @{ Message = 'secret' } },
            @{ Stage = [Exception]::new('secret') }, @{ Stage = ('x' * 1025) },
            @{ RecordCount = '2' }, @{ RecordCount = 1.5 }, @{ RecordCount = -1 },
            @{ Enabled = 'true' }, @{ DurationMs = [double]::NaN }, @{ DelaySeconds = [double]::PositiveInfinity },
            @{ EntraDeviceId = 'not-guid' }, @{ ConfigurationSha256 = '123' },
            @{ CertificateThumbprint = 'not-thumbprint' }, @{ CertificateNotAfterUtc = 'yesterday' },
            @{ ConfigurationSha256 = (('a' * 64) + "`n") },
            @{ EntraDeviceId = (' ' + [guid]::NewGuid().ToString('D')) }
        )) {
            { Write-InventoryLog -Context $context -Event RunFailed -Data $data } | Should -Throw '*field*'
        }
        (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
    }

    It 'rejects endpoints with credentials queries fragments non-HTTPS or relative paths' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        foreach ($endpoint in @(
            'http://example.invalid', '/api/inventory', 'https://user:secret@example.invalid',
            'https://example.invalid?token=secret', 'https://example.invalid#secret',
            'https://example.invalid?', "https://example.invalid/`nsecret",
            ('https://example.invalid/' + ([string][char]0x00e9 * 500))
        )) {
            { Write-InventoryLog -Context $context -Event HttpAttempt -Data @{ Endpoint = $endpoint } } |
                Should -Throw '*Endpoint*'
        }
        (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
    }

    It 'never serializes secret-bearing ETS properties attached to allowed scalars' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $data = @{
            Stage = ('trusted' | Add-Member -NotePropertyName PrivateKey -NotePropertyValue 'secret-marker' -PassThru)
            RecordCount = (2 | Add-Member -NotePropertyName Body -NotePropertyValue 'secret-marker' -PassThru)
            Enabled = ($true | Add-Member -NotePropertyName Message -NotePropertyValue 'secret-marker' -PassThru)
            DurationMs = (1.5 | Add-Member -NotePropertyName Headers -NotePropertyValue 'secret-marker' -PassThru)
            ConfigurationSha256 = (('a' * 64) | Add-Member -NotePropertyName Signature -NotePropertyValue 'secret-marker' -PassThru)
        }
        $context.Component = ('Inventory' | Add-Member -NotePropertyName Payload -NotePropertyValue 'secret-marker' -PassThru)
        Write-InventoryLog -Context $context -Event RunCompleted -Data $data
        $raw = [IO.File]::ReadAllText($context.Path)
        $raw | Should -Not -Match 'secret-marker|PrivateKey|Payload|Signature|Headers|Message'
        $record = $raw | ConvertFrom-Json
        $record.Data.Stage | Should -Be trusted
        $record.Data.RecordCount | Should -Be 2
        $record.Data.Enabled | Should -BeTrue
        $record.Data.DurationMs | Should -Be 1.5
        $record.Component | Should -Be Inventory
    }

    It 'bounds UTF8 bytes and archives without splitting records or deleting unrelated files' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot -MaxFileBytes 1024 -MaxArchives 2
        $unrelated = Join-Path $script:LogRoot 'Inventory.log.backup'
        [IO.File]::WriteAllText($unrelated, 'keep')
        foreach ($i in 1..30) {
            Write-InventoryLog -Context $context -Event RunCompleted -Data @{ RecordCount = $i }
        }
        $files = @(Get-ChildItem -LiteralPath $script:LogRoot -File | Where-Object { $_.Name -match '^Inventory\.log(?:\.[12])?$' })
        $files.Count | Should -Be 3
        foreach ($file in $files) {
            $file.Length | Should -BeLessOrEqual 1024
            foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
                ($line | ConvertFrom-Json).Event | Should -Be RunCompleted
            }
        }
        (([IO.File]::ReadAllLines($context.Path) | Select-Object -Last 1) | ConvertFrom-Json).Data.RecordCount | Should -Be 30
        [IO.File]::ReadAllText($unrelated) | Should -Be keep
    }

    It 'enforces age on old active logs and archives and reduces prior larger retention settings' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot -MaxFileBytes 1024 -MaxArchives 4
        foreach ($i in 1..30) { Write-InventoryLog -Context $context -Event RunStarted }
        [IO.File]::SetLastWriteTimeUtc($context.Path, [DateTime]::UtcNow.AddDays(-15))
        [IO.File]::SetLastWriteTimeUtc(($context.Path + '.1'), [DateTime]::UtcNow.AddDays(-15))
        $context.MaxArchives = 2
        Write-InventoryLog -Context $context -Event RunCompleted
        [IO.File]::ReadAllLines($context.Path).Count | Should -Be 1
        Test-Path -LiteralPath ($context.Path + '.1') | Should -BeFalse
        Test-Path -LiteralPath ($context.Path + '.3') | Should -BeFalse
        Test-Path -LiteralPath ($context.Path + '.4') | Should -BeFalse
    }

    It 'expires a continuously updated active log by creation age and permits zero archives' {
        $context = New-InventoryLogContext -Component Spool -Directory $script:LogRoot -MaxFileBytes 1024 -MaxArchives 0
        Write-InventoryLog -Context $context -Event RunStarted
        [IO.File]::SetCreationTimeUtc($context.Path, [DateTime]::UtcNow.AddDays(-15))
        Write-InventoryLog -Context $context -Event RunCompleted
        [IO.File]::ReadAllLines($context.Path).Count | Should -Be 1
        foreach ($i in 1..20) { Write-InventoryLog -Context $context -Event RunStarted }
        @(Get-ChildItem -LiteralPath $script:LogRoot | Where-Object { $_.Name -match '^Spool\.log\.\d+$' }).Count | Should -Be 0
    }

    It 'rejects oversized records before rotation and refuses to append to an incomplete record' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot -MaxFileBytes 1024
        { Write-InventoryLog -Context $context -Event RunStarted -Data @{ Stage = ('x' * 500) } } |
            Should -Throw '*record byte limit*'
        (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
        [IO.File]::WriteAllText($context.Path, '{"incomplete":')
        { Write-InventoryLog -Context $context -Event RunStarted } | Should -Throw '*incomplete final record*'
        [IO.File]::ReadAllText($context.Path) | Should -Be '{"incomplete":'
    }

    It 'rejects unsafe paths through the pinned guard and propagates guard failures on every write' {
        foreach ($path in @('\\server\share', 'C:\Temp\..\logs', 'C:\Temp\logs:stream', 'C:\Temp\logs.')) {
            { New-InventoryLogContext -Component Inventory -Directory $path } | Should -Throw '*Unsafe spool path*'
        }
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        Mock -ModuleName InventorySpool Assert-SpoolHierarchy { throw 'Unsafe spool path: reparse point or ACL.' }
        { Write-InventoryLog -Context $context -Event RunStarted } | Should -Throw '*Unsafe spool path*'
        (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
    }

    It 'rejects mismatched context paths and invalid rotation limits' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $context.Path = Join-Path $script:LogRoot 'unrelated.txt'
        { Write-InventoryLog -Context $context -Event RunStarted } | Should -Throw '*does not match*'
        { New-InventoryLogContext -Component Inventory -Directory $script:LogRoot -MaxArchives 33 } | Should -Throw
        { New-InventoryLogContext -Component Inventory -Directory $script:LogRoot -MaxFileBytes 0 } | Should -Throw
    }

    It 'rejects reader ACLs instead of changing them even when the spool trust guard accepts the file' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        Mock -ModuleName Inventory.Logging Get-Acl {
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)')
            return $acl
        }
        { Write-InventoryLog -Context $context -Event RunStarted } | Should -Throw '*Unsafe inventory log ACL*'
        (Get-Item -LiteralPath $context.Path).Length | Should -Be 0
    }

    It 'has a finite contention timeout and releases locks on write failures' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $held = [IO.File]::Open((Join-Path $script:LogRoot '.Inventory.lock'),
            [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        InModuleScope Inventory.Logging { $script:LogLockTimeoutMilliseconds = 100 }
        try {
            { Write-InventoryLog -Context $context -Event RunStarted } | Should -Throw '*Timed out*'
        }
        finally {
            $held.Dispose()
            InModuleScope Inventory.Logging { $script:LogLockTimeoutMilliseconds = 10000 }
        }
        $active = [IO.File]::Open($context.Path, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { { Write-InventoryLog -Context $context -Event RunStarted } | Should -Throw }
        finally { $active.Dispose() }
        { Write-InventoryLog -Context $context -Event RunCompleted } | Should -Not -Throw
    }

    It 'does not retry access denials or unrelated IO failures during atomic lock creation' {
        Mock -ModuleName InventorySpool New-SpoolFileStream { throw [UnauthorizedAccessException]::new('denied') }
        { New-InventoryLogContext -Component Inventory -Directory $script:LogRoot } | Should -Throw '*denied*'
        Should -Invoke -ModuleName InventorySpool New-SpoolFileStream -Times 1 -Exactly
        Mock -ModuleName InventorySpool New-SpoolFileStream { throw [IO.IOException]::new('disk failure') }
        { New-InventoryLogContext -Component Inventory -Directory $script:LogRoot } | Should -Throw '*disk failure*'
        Should -Invoke -ModuleName InventorySpool New-SpoolFileStream -Times 2 -Exactly
    }

    It 'validates existing archives before retention deletes them' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot -MaxArchives 0
        $archive = $context.Path + '.1'
        [IO.File]::WriteAllText($archive, 'do not delete')
        Mock -ModuleName Inventory.Logging Get-Acl {
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)')
            return $acl
        } -ParameterFilter { $LiteralPath -eq $archive }
        { Write-InventoryLog -Context $context -Event RunStarted } | Should -Throw '*Unsafe inventory log ACL*'
        [IO.File]::ReadAllText($archive) | Should -Be 'do not delete'
    }

    It 'waits for an independent PowerShell session to release the component lock' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:LogRoot
        $ready = Join-Path $script:LogRoot 'test-ready'
        $release = Join-Path $script:LogRoot 'test-release'
        $job = Start-Job -ArgumentList (Join-Path $script:LogRoot '.Inventory.lock'), $ready, $release -ScriptBlock {
            param($Path, $Ready, $Release)
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                [IO.File]::WriteAllText($Ready, 'ready')
                $timer = [Diagnostics.Stopwatch]::StartNew()
                while (-not [IO.File]::Exists($Release)) {
                    if ($timer.Elapsed.TotalSeconds -gt 20) { throw 'Fixture release timed out.' }
                    Start-Sleep -Milliseconds 20
                }
                Start-Sleep -Milliseconds 500
            }
            finally { $stream.Dispose() }
        }
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while (-not [IO.File]::Exists($ready)) {
                if ($job.State -in @('Failed', 'Completed') -or $timer.Elapsed.TotalSeconds -gt 20) {
                    throw 'Fixture lock acquisition failed.'
                }
                Start-Sleep -Milliseconds 20
            }
            [IO.File]::WriteAllText($release, 'release')
            Write-InventoryLog -Context $context -Event RunCompleted
            Should -Invoke -ModuleName InventorySpool Assert-SpoolHierarchy -Times 3 -ParameterFilter {
                $Path -eq (Join-Path $script:LogRoot '.Inventory.lock')
            }
            $null = Wait-Job -Job $job -Timeout 20
            $job.State | Should -Be Completed
            Receive-Job -Job $job -ErrorAction Stop
            [IO.File]::ReadAllLines($context.Path).Count | Should -Be 1
        }
        finally {
            Stop-Job -Job $job
            Remove-Job -Job $job -Force
        }
    }
}

Describe 'Inventory logging real guarded temp filesystem' {
    BeforeEach {
        # Only fixture ownership is substituted, as in InventorySpool.Tests.
        # Real hierarchy, reparse, ACL and atomic creation code still executes.
        Mock -ModuleName InventorySpool Test-SpoolTrustedIdentity {
            param($Sid, [switch] $Ancestor)
            return ($Sid -in @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -or
                ($Ancestor -and $Sid -eq 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'))
        }
        Mock -ModuleName InventorySpool New-SpoolSecurityDescriptor {
            param([switch] $Directory)
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ($Directory) {
                $acl = New-Object Security.AccessControl.DirectorySecurity
                $acl.SetSecurityDescriptorSddlForm("O:${sid}G:${sid}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;$sid)")
            }
            else {
                $acl = New-Object Security.AccessControl.FileSecurity
                $acl.SetSecurityDescriptorSddlForm("O:${sid}G:${sid}D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;$sid)")
            }
            return $acl
        }
        $script:SecureRoot = Join-Path ([IO.Path]::GetTempPath()) ('inventory-log-test-' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:SecureRoot) {
            Remove-Item -LiteralPath $script:SecureRoot -Recurse -Force -ErrorAction Stop
        }
    }

    It 'creates protected files atomically and rejects a subsequently added read ACE without repair' {
        $context = New-InventoryLogContext -Component Inventory -Directory $script:SecureRoot
        Write-InventoryLog -Context $context -Event RunStarted
        (Get-Acl -LiteralPath $context.Path).AreAccessRulesProtected | Should -BeTrue
        (Get-Acl -LiteralPath (Join-Path $script:SecureRoot '.Inventory.lock')).AreAccessRulesProtected | Should -BeTrue
        $acl = Get-Acl -LiteralPath $context.Path
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
            [Security.AccessControl.FileSystemRights]::Read, 'Allow'))
        $access = New-Object Security.AccessControl.FileSecurity
        $access.SetSecurityDescriptorBinaryForm($acl.GetSecurityDescriptorBinaryForm(),
            [Security.AccessControl.AccessControlSections]::Access)
        $item = Get-Item -LiteralPath $context.Path
        if ($PSVersionTable.PSVersion.Major -le 5) { $item.SetAccessControl($access) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl($item, $access) }
        $before = (Get-Acl -LiteralPath $context.Path).Sddl
        $content = [IO.File]::ReadAllText($context.Path)
        { Write-InventoryLog -Context $context -Event RunCompleted } | Should -Throw '*Unsafe inventory log ACL*'
        (Get-Acl -LiteralPath $context.Path).Sddl | Should -BeExactly $before
        [IO.File]::ReadAllText($context.Path) | Should -BeExactly $content
    }
}

AfterAll {
    Remove-Module Inventory.Logging -ErrorAction SilentlyContinue
}
