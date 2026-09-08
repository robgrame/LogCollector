BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1') -Force -ErrorAction Stop

    # Private helpers live in a nested module, which InModuleScope on the root module
    # cannot reach. Invoking the nested module's PSModuleInfo runs inside its scope.
    $script:Logging = (Get-Module LogCollector.Client).NestedModules |
        Where-Object { $_.Name -eq 'CMTraceLogging' }

    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:Root -Force

    # The suite runs unelevated, so the protected-DACL provisioning cannot assign
    # Administrators as owner. -SkipTrustCheck exercises everything else; the ACL
    # behaviour itself is covered by its own rejection tests below.
    function Write-TestLog {
        param([hashtable] $Arguments = @{})
        $splat = @{
            CustomerName   = 'Contoso'
            LogRoot        = $script:Root
            SkipTrustCheck = $true
        }
        foreach ($key in $Arguments.Keys) { $splat[$key] = $Arguments[$key] }
        return (Write-CMTraceLog @splat -PassThru)
    }
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-CMTraceLogPath' {
    It 'differs only by application name, so one customer keeps one predictable tree' {
        $a = Get-CMTraceLogPath -ApplicationName 'W11Upgrade' -CustomerName 'Contoso' -LogRoot 'C:\Data'
        $b = Get-CMTraceLogPath -ApplicationName 'CustomInventory' -CustomerName 'Contoso' -LogRoot 'C:\Data'
        $a | Should -Be 'C:\Data\Contoso\W11Upgrade\Logs\W11Upgrade.log'
        $b | Should -Be 'C:\Data\Contoso\CustomInventory\Logs\CustomInventory.log'
    }

    It 'does not create anything, so it is safe to call for a support message' {
        $path = Get-CMTraceLogPath -ApplicationName 'NeverCreated' -CustomerName 'Contoso' -LogRoot $script:Root
        Test-Path -LiteralPath (Split-Path $path -Parent) | Should -BeFalse
    }

    It 'rejects a traversal sequence rather than writing outside the tree' {
        { Get-CMTraceLogPath -ApplicationName '..\..\Windows\System32' -CustomerName 'Contoso' -LogRoot 'C:\Data' } |
            Should -Throw '*is not usable as a folder name*'
    }

    It 'rejects a directory separator in either segment' {
        { Get-CMTraceLogPath -ApplicationName 'a/b' -CustomerName 'Contoso' -LogRoot 'C:\Data' } |
            Should -Throw '*is not usable as a folder name*'
        { Get-CMTraceLogPath -ApplicationName 'App' -CustomerName 'a\b' -LogRoot 'C:\Data' } |
            Should -Throw '*is not usable as a folder name*'
    }

    It 'rejects a reserved Windows device name, which is not an ordinary folder' {
        foreach ($name in @('CON', 'NUL', 'LPT1', 'con.log')) {
            { Get-CMTraceLogPath -ApplicationName $name -CustomerName 'Contoso' -LogRoot 'C:\Data' } |
                Should -Throw '*reserved Windows device name*'
        }
    }

    It 'rejects a trailing dot or space, which Windows would resolve to a different path' {
        { Get-CMTraceLogPath -ApplicationName 'App.' -CustomerName 'Contoso' -LogRoot 'C:\Data' } |
            Should -Throw '*must not end with a dot or a space*'
    }

    It 'rejects an empty or over-long segment' {
        { Get-CMTraceLogPath -ApplicationName '' -CustomerName 'Contoso' -LogRoot 'C:\Data' } | Should -Throw
        { Get-CMTraceLogPath -ApplicationName ('a' * 65) -CustomerName 'Contoso' -LogRoot 'C:\Data' } |
            Should -Throw '*is not usable as a folder name*'
    }
}

Describe 'Write-CMTraceLog record format' {
    It 'writes exactly one CMTrace record per call' {
        $path = Write-TestLog @{ Message = 'first'; ApplicationName = 'Format' }
        $null = Write-TestLog @{ Message = 'second'; ApplicationName = 'Format' }
        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match ('^' + [regex]::Escape('<![LOG[first]LOG]!><time='))
    }

    It 'emits the attributes CMTrace parses, in the order the viewer expects' {
        $path = Write-TestLog @{ Message = 'shape'; ApplicationName = 'Shape'; Component = 'MyStep' }
        $line = @(Get-Content -LiteralPath $path)[0]
        $line | Should -Match '^<!\[LOG\[shape\]LOG\]!><time="\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{3}" date="\d{2}-\d{2}-\d{4}" component="MyStep" context="[^"]*" type="1" thread="\d+" file="[^"]*">$'
    }

    It 'maps each level to the CMTrace type that drives the viewer highlighting' {
        $expected = @{ Verbose = 1; Debug = 1; Info = 1; Warning = 2; Error = 3 }
        foreach ($level in $expected.Keys) {
            $path = Write-TestLog @{ Message = "at $level"; Level = $level; ApplicationName = "Lvl$level" }
            @(Get-Content -LiteralPath $path)[0] | Should -Match ('type="{0}"' -f $expected[$level])
        }
    }

    It 'writes the bias as UTC = local + bias, the convention the ConfigMgr client uses' {
        $record = & $script:Logging {
            $stamp = [DateTimeOffset]::new(2026, 9, 8, 20, 3, 52, [TimeSpan]::FromHours(2))
            New-CMTraceRecord -Message 'm' -Component 'c' -Type 1 -Source 's.ps1:1' -Timestamp $stamp
        }
        $record | Should -Match 'time="20:03:52\.000-120"'
        $record | Should -Match 'date="09-08-2026"'
    }

    It 'formats a negative-offset zone with a leading plus and three digits' {
        $record = & $script:Logging {
            $stamp = [DateTimeOffset]::new(2026, 1, 2, 3, 4, 5, [TimeSpan]::FromHours(-5))
            New-CMTraceRecord -Message 'm' -Component 'c' -Type 1 -Source '' -Timestamp $stamp
        }
        $record | Should -Match 'time="03:04:05\.000\+300"'
    }

    It 'records the calling script and line, so CMTrace can show where an entry came from' {
        $script = Join-Path $script:Root 'caller.ps1'
        @(
            'param($LogRoot)'
            'Write-CMTraceLog -Message ''from a script'' -ApplicationName ''Caller'' -CustomerName ''Contoso'' -LogRoot $LogRoot -SkipTrustCheck'
        ) | Set-Content -LiteralPath $script -Encoding UTF8
        # The module is already imported; the child script must not re-import with -Force,
        # which would unload it from this session mid-run.
        & $script -LogRoot $script:Root
        $path = Join-Path $script:Root 'Contoso\Caller\Logs\Caller.log'
        @(Get-Content -LiteralPath $path)[0] | Should -Match 'file="caller\.ps1:\d+"'
    }
}

Describe 'Write-CMTraceLog record integrity' {
    It 'flattens newlines, so a multi-line message cannot forge extra records' {
        $path = Write-TestLog @{ Message = "line one`r`nline two`nline three"; ApplicationName = 'Multi' }
        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeLike '*line one line two line three*'
    }

    It 'neutralises an embedded record terminator, so a caller cannot inject a record' {
        $path = Write-TestLog @{ Message = 'evil]LOG]!><time="00:00:00.000+000" date="01-01-2000"'; ApplicationName = 'Inject' }
        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 1
        # Exactly one terminator: the real one this function appended.
        ([regex]::Matches($lines[0], [regex]::Escape(']LOG]!>'))).Count | Should -Be 1
    }

    It 'strips control characters that would corrupt the file' {
        $path = Write-TestLog @{ Message = "a`0b`tc"; ApplicationName = 'Ctrl' }
        $line = @(Get-Content -LiteralPath $path)[0]
        $line | Should -BeLike '*ab*'
        $line | Should -Not -Match "`0"
    }

    It 'keeps a quote out of an attribute, which would otherwise end it early' {
        $path = Write-TestLog @{ Message = 'm'; ApplicationName = 'Quote'; Component = 'we"ird' }
        @(Get-Content -LiteralPath $path)[0] | Should -Match "component=`"we'ird`""
    }

    It 'truncates an oversized message instead of writing an unbounded line' {
        $path = Write-TestLog @{ Message = ('x' * 20000); ApplicationName = 'Big' }
        $line = @(Get-Content -LiteralPath $path)[0]
        $line | Should -Match ([regex]::Escape('...[truncated]'))
        $line.Length | Should -BeLessThan 9000
    }

    It 'accepts an empty message rather than failing the calling script' {
        { Write-TestLog @{ Message = ''; ApplicationName = 'Empty' } } | Should -Not -Throw
    }
}

Describe 'Write-CMTraceLog defaults' {
    It 'defaults the application name to the calling script, so each script gets its own log' {
        $script = Join-Path $script:Root 'My Tool.ps1'
        @(
            'param($LogRoot)'
            'Write-CMTraceLog -Message ''auto'' -CustomerName ''Contoso'' -LogRoot $LogRoot -SkipTrustCheck'
        ) | Set-Content -LiteralPath $script -Encoding UTF8
        & $script -LogRoot $script:Root
        Test-Path -LiteralPath (Join-Path $script:Root 'Contoso\My Tool\Logs\My Tool.log') | Should -BeTrue
    }

    It 'defaults the component to the calling function, which is the CMTrace component column' {
        function Invoke-TestStep {
            Write-CMTraceLog -Message 'in a function' -ApplicationName 'Comp' -CustomerName 'Contoso' `
                -LogRoot $script:Root -SkipTrustCheck -PassThru
        }
        $path = Invoke-TestStep
        @(Get-Content -LiteralPath $path)[0] | Should -Match 'component="Invoke-TestStep"'
    }

    It 'accepts messages from the pipeline, so a script can log a stream of lines' {
        $path = @('one', 'two', 'three') |
            Write-CMTraceLog -ApplicationName 'Pipe' -CustomerName 'Contoso' -LogRoot $script:Root -SkipTrustCheck -PassThru |
            Select-Object -Last 1
        @(Get-Content -LiteralPath $path).Count | Should -Be 3
    }

    It 'writes nothing under -WhatIf' {
        Write-CMTraceLog -Message 'nope' -ApplicationName 'WhatIf' -CustomerName 'Contoso' `
            -LogRoot $script:Root -SkipTrustCheck -WhatIf
        Test-Path -LiteralPath (Join-Path $script:Root 'Contoso\WhatIf') | Should -BeFalse
    }
}

Describe 'Write-CMTraceLog rotation' {
    It 'rotates through numbered slots and keeps no more than MaxArchives' {
        foreach ($i in 1..40) {
            $null = Write-TestLog @{
                Message = ("entry $i " + ('x' * 200)); ApplicationName = 'Rotate'
                MaxFileBytes = 2048; MaxArchives = 2
            }
        }
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'Contoso\Rotate\Logs') | Sort-Object Name)
        # The lock file is expected: rotation moves only the numbered slots, so the lock
        # that serialises rotation is never rotated away underneath a waiting writer.
        $files.Name | Should -Be @('Rotate.log', 'Rotate.log.1', 'Rotate.log.2', 'Rotate.log.lock')
        foreach ($file in $files) { $file.Length | Should -BeLessOrEqual 2048 }
    }

    It 'discards rather than archives when MaxArchives is 0' {
        foreach ($i in 1..20) {
            $null = Write-TestLog @{
                Message = ("entry $i " + ('x' * 200)); ApplicationName = 'NoArchive'
                MaxFileBytes = 1024; MaxArchives = 0
            }
        }
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'Contoso\NoArchive\Logs') | Sort-Object Name)
        $files.Name | Should -Be @('NoArchive.log', 'NoArchive.log.lock')
    }

    It 'refuses a quota smaller than a single record rather than silently exceeding it' {
        { Write-TestLog @{
                Message = ('x' * 4000); ApplicationName = 'TooSmall'; MaxFileBytes = 1024; MaxArchives = 2
            } } | Should -Throw '*could never stay within its quota*'
    }

    It 'never touches an unrelated file sharing the log directory' {
        $null = Write-TestLog @{ Message = 'seed'; ApplicationName = 'Neighbour'; MaxFileBytes = 1024; MaxArchives = 2 }
        $bystander = Join-Path $script:Root 'Contoso\Neighbour\Logs\keep-me.txt'
        Set-Content -LiteralPath $bystander -Value 'do not delete' -Encoding UTF8
        foreach ($i in 1..30) {
            $null = Write-TestLog @{
                Message = ("entry $i " + ('x' * 200)); ApplicationName = 'Neighbour'
                MaxFileBytes = 1024; MaxArchives = 2
            }
        }
        Test-Path -LiteralPath $bystander | Should -BeTrue
        Get-Content -LiteralPath $bystander | Should -Be 'do not delete'
    }
}

Describe 'Write-CMTraceLog trust enforcement' {
    It 'refuses a log directory that a standard user could write to' {
        $directory = Join-Path $script:Root 'untrusted'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $acl = Get-Acl -LiteralPath $directory
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
                    (New-Object Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-545'),
                    'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $directory -AclObject $acl
        { & $script:Logging { param($Path) Assert-CMTraceTrustedPath -Path $Path } $directory } |
            Should -Throw '*grants write access to*'
    }

    It 'refuses a log directory that inherits its permissions' {
        $directory = Join-Path $script:Root 'inheriting'
        $null = New-Item -ItemType Directory -Path $directory -Force
        { & $script:Logging { param($Path) Assert-CMTraceTrustedPath -Path $Path } $directory } |
            Should -Throw '*inherits its permissions*'
    }

    It 'refuses a directory owned by a standard user, which is how ProgramData gets squatted' {
        # Created unelevated, so this process's own account owns it: exactly the
        # state a squatter produces by pre-creating the customer folder.
        $directory = Join-Path $script:Root 'squatted'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $acl = Get-Acl -LiteralPath $directory
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            if (-not $rule.IsInherited) { $null = $acl.RemoveAccessRuleSpecific($rule) }
        }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
                    (New-Object Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-18'),
                    'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $directory -AclObject $acl
        { & $script:Logging { param($Path) Assert-CMTraceTrustedPath -Path $Path } $directory } |
            Should -Throw '*not by SYSTEM or Administrators*'
    }

    It 'grants Users read but not write, so support can collect a log without elevation' {
        $sddl = & $script:Logging { (New-CMTraceSecurityDescriptor -Directory).GetSecurityDescriptorSddlForm('Access') }
        $sddl | Should -Match ([regex]::Escape('(A;OICI;0x1200a9;;;BU)'))
        $sddl | Should -Not -Match ([regex]::Escape('(A;OICI;FA;;;BU)'))
    }

    It 'protects the descriptor, so nothing is inherited from ProgramData' {
        $protected = & $script:Logging { (New-CMTraceSecurityDescriptor -Directory).AreAccessRulesProtected }
        $protected | Should -BeTrue
    }

    It 'owns the tree with a SID the trust check actually accepts' {
        # Regression: reading $acl.Owner yields a localised account-name string, so calling
        # Translate on it fails and every correctly hardened directory was rejected.
        $owner = & $script:Logging {
            (New-CMTraceSecurityDescriptor -Directory).GetOwner([Security.Principal.SecurityIdentifier]).Value
        }
        $owner | Should -BeExactly 'S-1-5-32-544'
        $trusted = & $script:Logging { $script:TrustedSids }
        $trusted | Should -Contain $owner
    }

    It 'grants Users no access at all to the lock file' {
        # The lock is opened denying all sharing, so a user who could open it could hold it
        # and stop every elevated writer on the device from logging.
        $sddl = & $script:Logging { (New-CMTraceSecurityDescriptor -Lock).GetSecurityDescriptorSddlForm('Access') }
        $sddl | Should -Not -Match 'BU'
        $sddl | Should -Match ([regex]::Escape('(A;;FA;;;SY)'))
        $sddl | Should -Match ([regex]::Escape('(A;;FA;;;BA)'))
    }

    It 'normalises every derived name into one its own validator accepts' {
        $cases = @(
            'normal-script', 'CON', 'PRN.ps1', 'NUL', ('CON.' + ('a' * 60)), ('x' * 200),
            '...leading', 'trailing...', '   ', '', 'a b c', 'ünïcödé-nàme', ('CON' + ('b' * 70)),
            # Unicode characters that are case-equivalent to ASCII under the default
            # case-insensitive -replace, and so used to survive into an invalid name.
            ([char] 0x212A), ('x' + [char] 0x212A + 'y'), ([char] 0x212B), ('C' + [char] 0x212A + 'y')
        )
        foreach ($case in $cases) {
            $segment = & $script:Logging { param($N) ConvertTo-CMTraceNameSegment -Name $N } $case
            $segment.Length | Should -BeLessOrEqual 64
            { & $script:Logging { param($N) Assert-CMTraceNameSegment -Name $N -Purpose 'ApplicationName' } $segment } |
                Should -Not -Throw -Because "'$case' normalised to '$segment'"
        }
    }

    It 'keeps two long names that share a prefix in separate logs' {
        $first = & $script:Logging { param($N) ConvertTo-CMTraceNameSegment -Name $N } (('same-' * 20) + 'one')
        $second = & $script:Logging { param($N) ConvertTo-CMTraceNameSegment -Name $N } (('same-' * 20) + 'two')
        $first | Should -Not -Be $second
    }

    It 'refuses to write into a reparse point, which could redirect the whole log tree' {
        $target = Join-Path $script:Root 'link-target'
        $link = Join-Path $script:Root 'link'
        $null = New-Item -ItemType Directory -Path $target -Force
        try { $null = New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'this filesystem does not allow creating a junction here'; return }
        { & $script:Logging { param($Path) Assert-CMTraceTrustedPath -Path $Path } $link } |
            Should -Throw '*is a reparse point*'
    }
}

Describe 'Get-CMTraceCustomerName' {
    BeforeAll {
        function New-TestEndpointConfiguration {
            param([string] $Name, [string] $Body)
            $path = Join-Path $script:Root "config-$Name.psd1"
            Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
            return $path
        }
    }

    It 'uses the CustomerName from the machine-wide configuration' {
        $path = New-TestEndpointConfiguration -Name 'named' -Body @"
@{ FrontendUrl = 'https://example.invalid/api/inventory'; CustomerName = 'Contoso' }
"@
        Get-CMTraceCustomerName -ConfigurationPath $path -SkipTrustCheck | Should -Be 'Contoso'
    }

    It 'falls back to the product name when the machine is not configured' {
        $missing = Join-Path $script:Root 'no-such-config.psd1'
        Get-CMTraceCustomerName -ConfigurationPath $missing -SkipTrustCheck | Should -Be 'LogCollector'
    }

    It 'falls back when the configuration exists but names no customer' {
        $path = New-TestEndpointConfiguration -Name 'unnamed' -Body @"
@{ FrontendUrl = 'https://example.invalid/api/inventory' }
"@
        Get-CMTraceCustomerName -ConfigurationPath $path -SkipTrustCheck | Should -Be 'LogCollector'
    }

    It 'never lets an unconfigured machine stop a script from logging' {
        # No -CustomerName and no machine configuration: the log must still be written.
        { Write-CMTraceLog -Message 'still logged' -ApplicationName 'Fallback' `
                -LogRoot $script:Root -SkipTrustCheck } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:Root 'LogCollector\Fallback\Logs\Fallback.log') | Should -BeTrue
    }
}

Describe 'Write-CMTraceLog production-path enforcement' {
    It 'refuses -SkipTrustCheck at the canonical location' {
        # Otherwise any user could provision %ProgramData%\<Customer> with inherited
        # permissions and own the path every elevated script on the device logs to.
        { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' -SkipTrustCheck } |
            Should -Throw '*may only be used together*'
    }

    It 'refuses an empty -LogRoot as a way of reaching the canonical location' {
        foreach ($root in @('', $null)) {
            { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' `
                    -LogRoot $root -SkipTrustCheck } | Should -Throw '*may only be used together*'
        }
    }

    It 'refuses a -LogRoot that resolves to or under the canonical location' {
        $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        $roots = @(
            $programData,
            ($programData + '\'),
            (Join-Path $programData '.'),
            (Join-Path $programData 'Sub'),
            (Join-Path $programData 'Sub\..')
        )
        foreach ($root in $roots) {
            { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' `
                    -LogRoot $root -SkipTrustCheck } | Should -Throw '*resolves inside*'
        }
    }

    It 'refuses an 8.3 short-name alias of the canonical location' {
        # C:\PROGRA~3 is C:\ProgramData, but no lexical comparison sees that.
        $short = 'C:\PROGRA~3'
        if (-not (Test-Path -LiteralPath $short)) { Set-ItResult -Skipped -Because 'short names are disabled here'; return }
        { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' `
                -LogRoot $short -SkipTrustCheck } | Should -Throw '*resolves inside*'
    }

    It 'refuses a UNC alias of the canonical location' {
        { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' `
                -LogRoot '\\localhost\c$\ProgramData' -SkipTrustCheck } | Should -Throw '*UNC or device path*'
    }

    It 'refuses a -LogRoot reached through a junction' {
        $target = Join-Path $script:Root 'root-target'
        $link = Join-Path $script:Root 'root-link'
        $null = New-Item -ItemType Directory -Path $target -Force
        try { $null = New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'this filesystem does not allow creating a junction here'; return }
        { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' `
                -LogRoot $link -SkipTrustCheck } | Should -Throw '*reparse point*'
    }

    It 'refuses a relative -LogRoot, which resolves against the caller''s location' {
        { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' `
                -LogRoot 'relative\path' -SkipTrustCheck } | Should -Throw '*not rooted*'
    }

    It 'refuses a drive-relative -LogRoot, which also depends on the current directory' {
        # [IO.Path]::IsPathRooted('C:relative') is $true, so this needs its own check.
        { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' `
                -LogRoot 'C:relative' -SkipTrustCheck } | Should -Throw '*drive-relative*'
    }

    It 'fails closed when the shared location is aliased by a substituted drive' {
        # A SUBST drive is a DOS device mapping, not a reparse point, so neither the
        # junction walk nor a name comparison can see through it.
        $letter = 90..70 | ForEach-Object { [char]$_ } | Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1
        if (-not $letter) { Set-ItResult -Skipped -Because 'no spare drive letter is available'; return }
        $drive = "${letter}:"
        $null = subst $drive $env:ProgramData 2>&1
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'subst is not available here'; return }
        try {
            { & $script:Logging { param($P, $D) Resolve-CMTraceCustomRoot -Path $P -ProgramData $D } "$drive\" $env:ProgramData } |
                Should -Throw '*resolves inside*'
        } finally { $null = subst $drive /d 2>&1 }
    }

    It 'fails closed when the shared location is itself reached through a junction' {
        # Otherwise a redirected ProgramData could be reached by naming its physical
        # target, which no comparison of the two lexical paths would catch.
        $target = Join-Path $script:Root 'pd-target'
        $link = Join-Path $script:Root 'pd-link'
        $null = New-Item -ItemType Directory -Path $target -Force
        try { $null = New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'this filesystem does not allow creating a junction here'; return }
        { & $script:Logging { param($P, $D) Resolve-CMTraceCustomRoot -Path $P -ProgramData $D } $target $link } |
            Should -Throw '*shared log location*'
    }

    It 'refuses a custom -LogRoot without -SkipTrustCheck' {
        # The trust checks cover the customer, application and Logs directories, not a
        # caller-supplied root, so a custom root must not masquerade as a verified one.
        { Write-CMTraceLog -Message 'x' -ApplicationName 'Bypass' -CustomerName 'Contoso' -LogRoot $script:Root } |
            Should -Throw '*may only be used together*'
    }

    It 'resolves the default root from the system rather than from %ProgramData%' {
        # An attacker-controlled environment must not redirect the whole log tree.
        $expected = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        Get-CMTraceLogPath -ApplicationName 'App' -CustomerName 'Contoso' |
            Should -BeExactly (Join-Path $expected 'Contoso\App\Logs\App.log')
    }
}

Describe 'Write-CMTraceLog concurrency' {
    It 'loses no record when several processes rotate and append at the same time' {
        $writer = Join-Path $script:Root 'writer.ps1'
        @(
            'param($Module, $LogRoot, $Tag)'
            '$ErrorActionPreference = ''Stop'''
            'Import-Module $Module -Force'
            'foreach ($i in 1..40) {'
            '    Write-CMTraceLog -Message "$Tag-$i" -ApplicationName ''Concurrent'' -CustomerName ''Contoso'' `'
            '        -LogRoot $LogRoot -SkipTrustCheck -MaxFileBytes 8192 -MaxArchives 32'
            '}'
        ) | Set-Content -LiteralPath $writer -Encoding UTF8

        $module = Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1'
        $jobs = foreach ($tag in @('a', 'b', 'c')) {
            Start-Job -ScriptBlock {
                param($Writer, $Module, $LogRoot, $Tag)
                & $Writer -Module $Module -LogRoot $LogRoot -Tag $Tag
            } -ArgumentList $writer, $module, $script:Root, $tag
        }
        $null = $jobs | Wait-Job -Timeout 600
        $states = @($jobs | ForEach-Object { $_.State })
        $errors = @($jobs | ForEach-Object { $_.ChildJobs[0].Error } | ForEach-Object { $_.ToString() })
        $jobs | Remove-Job -Force
        $errors | Should -BeNullOrEmpty
        $states | Should -Be @('Completed', 'Completed', 'Completed')

        $logs = Join-Path $script:Root 'Contoso\Concurrent\Logs'
        $lines = @(Get-ChildItem -LiteralPath $logs -Filter 'Concurrent.log*' |
                Where-Object { $_.Name -ne 'Concurrent.log.lock' } |
                ForEach-Object { Get-Content -LiteralPath $_.FullName })
        # Every line is a whole record: an interleaved write would leave a fragment.
        foreach ($line in $lines) { $line | Should -Match '^<!\[LOG\[.*\]LOG\]!><time=".*">$' }
        # 33 slots at 8 KB hold far more than 120 short records, so none may be lost,
        # duplicated or corrupted: exactly the 120 distinct tags must survive.
        $tags = @($lines | ForEach-Object { if ($_ -match '<!\[LOG\[([abc]-\d+)\]LOG\]!>') { $Matches[1] } })
        $tags.Count | Should -Be $lines.Count
        @($tags | Sort-Object -Unique).Count | Should -Be 120
    }
}

Describe 'Core module surface' {
    It 'exports the logging helpers from the shared module, so any script can call them' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1')
        foreach ($name in @('Write-CMTraceLog', 'Get-CMTraceLogPath', 'Get-CMTraceCustomerName')) {
            $manifest.FunctionsToExport | Should -Contain $name
            Get-Command -Module LogCollector.Client -Name $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'ships the logging module in the file list that drives install and detection' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1')
        $manifest.FileList | Should -Contain 'CMTraceLogging.psm1'
    }

    It 'keeps the core package configuration template in step with the module' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\CorePackage\Config.psd1')
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\Client\LogCollector.Client.psd1')
        $config.PackageVersion | Should -Be $manifest.ModuleVersion
        $config.Keys | Should -Contain 'CustomerName'
    }
}
