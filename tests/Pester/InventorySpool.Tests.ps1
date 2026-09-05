<#
.SYNOPSIS
    Pester tests for the durable local spool.

.DESCRIPTION
    Covers the properties that make the spool safe rather than a liability:
    atomic writes, oldest-first ordering, age/count/size quotas, quarantine of
    corrupt or permanently-rejected entries, and single-writer locking.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $repoRoot 'src\Client\InventorySpool.psm1') -Force -DisableNameChecking

    function Set-SpoolFixtureDacl {
        param($Path, $Acl)
        if ((Get-Item -LiteralPath $Path).PSIsContainer) {
            $access = New-Object Security.AccessControl.DirectorySecurity
        }
        else { $access = New-Object Security.AccessControl.FileSecurity }
        $access.SetSecurityDescriptorBinaryForm($Acl.GetSecurityDescriptorBinaryForm(),
            [Security.AccessControl.AccessControlSections]::Access)
        $item = Get-Item -LiteralPath $Path
        if ($PSVersionTable.PSVersion.Major -le 5) { $item.SetAccessControl($access) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl($item, $access) }
    }
}

Describe 'InventorySpool' {

    BeforeEach {
        # Non-elevated Pester cannot assign Administrators ownership. Only the
        # fixture identity is substituted; real filesystem ACL/reparse checks run.
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
        $script:SpoolRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("logcollector-spool-" + [guid]::NewGuid().ToString('N'))
        $null = Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot
    }

    Context 'Filesystem trust boundary' {
        It 'creates protected new directories and files and accepts them on reuse' {
            $nested = Join-Path $script:SpoolRoot 'new-parent\new-spool'
            $path = Save-SpoolEntry -SpoolDirectory $nested -Body '{}' -TableName 'T_CL'
            foreach ($item in @($nested, (Split-Path $nested), (Join-Path $nested 'quarantine'), $path)) {
                (Get-Acl -LiteralPath $item).AreAccessRulesProtected | Should -BeTrue
            }
            { Initialize-SpoolDirectory -SpoolDirectory $nested } | Should -Not -Throw
            @(Get-SpoolEntry -SpoolDirectory $nested).Count | Should -Be 1
        }

        It 'rejects a user-writable existing spool without changing its ACL or planted entry' {
            $path = Save-SpoolEntry -SpoolDirectory $script:SpoolRoot -Body '{"planted":true}' -TableName 'T_CL'
            $acl = Get-Acl -LiteralPath $script:SpoolRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
            Set-SpoolFixtureDacl -Path $script:SpoolRoot -Acl $acl
            $before = (Get-Acl -LiteralPath $script:SpoolRoot).Sddl

            { Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot } | Should -Throw '*untrusted write*'
            { Get-SpoolEntry -SpoolDirectory $script:SpoolRoot } | Should -Throw '*untrusted write*'
            { Enter-SpoolLock -SpoolDirectory $script:SpoolRoot } | Should -Throw '*untrusted write*'
            (Get-Acl -LiteralPath $script:SpoolRoot).Sddl | Should -BeExactly $before
            Test-Path -LiteralPath $path | Should -BeTrue
        }

        It 'rejects a writable ancestor even when the spool itself is protected' {
            $nested = Join-Path $script:SpoolRoot 'nested'
            $null = Initialize-SpoolDirectory -SpoolDirectory $nested
            $acl = Get-Acl -LiteralPath $script:SpoolRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles, 'Allow'))
            Set-SpoolFixtureDacl -Path $script:SpoolRoot -Acl $acl
            { Get-SpoolEntry -SpoolDirectory $nested } | Should -Throw '*untrusted write*'
        }

        It 'allows a shared ancestor only while a trusted non-removable child anchors it' {
            $nested = Join-Path $script:SpoolRoot 'new-spool'
            $acl = Get-Acl -LiteralPath $script:SpoolRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
            Set-SpoolFixtureDacl -Path $script:SpoolRoot -Acl $acl
            # The secure quarantine directory anchors the otherwise shared parent.
            $null = Save-SpoolEntry -SpoolDirectory $nested -Body '{}' -TableName 'T_CL'
            @(Get-SpoolEntry -SpoolDirectory $nested).Count | Should -Be 1
        }

        It 'skips unreadable anchor candidates without treating them as trusted' {
            $denied = Join-Path $script:SpoolRoot 'unreadable'
            $null = Initialize-SpoolDirectory -SpoolDirectory $denied
            $script:AnchorCandidates = @(
                (Get-Item -LiteralPath $denied),
                (Get-Item -LiteralPath (Join-Path $script:SpoolRoot 'quarantine'))
            )
            Mock -ModuleName InventorySpool Get-ChildItem { $script:AnchorCandidates } -ParameterFilter {
                $LiteralPath -eq $script:SpoolRoot -and $Directory
            }
            Mock -ModuleName InventorySpool Get-Acl {
                throw [UnauthorizedAccessException]::new('candidate inaccessible')
            } -ParameterFilter { $LiteralPath -eq $denied }
            InModuleScope InventorySpool -Parameters @{ Root = $script:SpoolRoot } {
                param($Root)
                Test-SpoolAncestorAnchor -Path $Root | Should -BeTrue
            }
        }

        It 'rejects an empty writable ancestor before creating any spool directories' {
            [IO.Directory]::Delete((Join-Path $script:SpoolRoot 'quarantine'))
            $nested = Join-Path $script:SpoolRoot 'new-spool'
            $acl = Get-Acl -LiteralPath $script:SpoolRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
            Set-SpoolFixtureDacl -Path $script:SpoolRoot -Acl $acl
            { Initialize-SpoolDirectory -SpoolDirectory $nested } | Should -Throw '*without a protected child*'
            Test-Path -LiteralPath $nested | Should -BeFalse
        }

        It 'does not treat a removable child as an anchor for a writable ancestor' {
            $quarantine = Join-Path $script:SpoolRoot 'quarantine'
            $acl = Get-Acl -LiteralPath $quarantine
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Delete, 'Allow'))
            Set-SpoolFixtureDacl -Path $quarantine -Acl $acl
            $acl = Get-Acl -LiteralPath $script:SpoolRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
            Set-SpoolFixtureDacl -Path $script:SpoolRoot -Acl $acl
            { Initialize-SpoolDirectory -SpoolDirectory (Join-Path $script:SpoolRoot 'new-spool') } |
                Should -Throw '*without a protected child*'
        }

        It 'rejects user-writable files before reading, aging, updating, removing or quarantining them' {
            $path = Save-SpoolEntry -SpoolDirectory $script:SpoolRoot -Body '{}' -TableName 'T_CL'
            $acl = Get-Acl -LiteralPath $path
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
            Set-SpoolFixtureDacl -Path $path -Acl $acl
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)
            { ConvertFrom-SpoolFile -Path $path } | Should -Throw '*untrusted write*'
            { Get-SpoolEntry -SpoolDirectory $script:SpoolRoot } | Should -Throw '*untrusted write*'
            { Update-SpoolEntryAttempt -Path $path } | Should -Throw '*untrusted write*'
            { Remove-SpoolEntry -Path $path } | Should -Throw '*untrusted write*'
            { Move-SpoolEntryToQuarantine -Path $path } | Should -Throw '*untrusted write*'
            { Invoke-SpoolMaintenance -SpoolDirectory $script:SpoolRoot } | Should -Throw '*untrusted write*'
            { Save-SpoolEntry -SpoolDirectory $script:SpoolRoot -Body '{}' -TableName 'T_CL' } | Should -Throw '*untrusted write*'
            Test-Path -LiteralPath $path | Should -BeTrue
        }

        It 'rejects an untrusted directory owner despite a protected administrator-only DACL' {
            Mock -ModuleName InventorySpool Get-Acl {
                $acl = New-Object Security.AccessControl.DirectorySecurity
                $acl.SetSecurityDescriptorSddlForm('O:S-1-5-21-1-2-3-1001D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
                return $acl
            } -ParameterFilter { $LiteralPath -eq $script:SpoolRoot }
            { Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot } | Should -Throw '*untrusted owner*'
        }

        It 'rejects an untrusted file owner despite a protected administrator-only DACL' {
            $script:UntrustedFile = Save-SpoolEntry -SpoolDirectory $script:SpoolRoot -Body '{}' -TableName 'T_CL'
            Mock -ModuleName InventorySpool Get-Acl {
                $acl = New-Object Security.AccessControl.FileSecurity
                $acl.SetSecurityDescriptorSddlForm('O:S-1-5-21-1-2-3-1001D:P(A;;FA;;;SY)(A;;FA;;;BA)')
                return $acl
            } -ParameterFilter { $LiteralPath -eq $script:UntrustedFile }
            { ConvertFrom-SpoolFile -Path $script:UntrustedFile } | Should -Throw '*untrusted owner*'
        }

        It 'rejects a junction used as the spool or one of its ancestors' {
            $target = Join-Path $script:SpoolRoot 'target'
            $link = Join-Path $script:SpoolRoot 'junction'
            $null = Initialize-SpoolDirectory -SpoolDirectory $target
            $null = New-Item -ItemType Junction -Path $link -Target $target
            try {
                { Initialize-SpoolDirectory -SpoolDirectory $link } | Should -Throw '*reparse*'
                { Initialize-SpoolDirectory -SpoolDirectory (Join-Path $link 'child') } | Should -Throw '*reparse*'
            }
            finally { [IO.Directory]::Delete($link) }
        }

        It 'rejects a junction used as quarantine before reading entries' {
            $quarantine = Join-Path $script:SpoolRoot 'quarantine'
            [IO.Directory]::Delete($quarantine)
            $null = New-Item -ItemType Junction -Path $quarantine -Target $script:SpoolRoot
            try {
                { Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot } | Should -Throw '*reparse*'
                { Get-SpoolEntry -SpoolDirectory $script:SpoolRoot } | Should -Throw '*reparse*'
            }
            finally { [IO.Directory]::Delete($quarantine) }
        }

        It 'rejects inherited write access instead of protecting the DACL in place' {
            $nested = Join-Path $script:SpoolRoot 'inherited-spool'
            $acl = Get-Acl -LiteralPath $script:SpoolRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Write,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [Security.AccessControl.PropagationFlags]::InheritOnly, 'Allow'))
            Set-SpoolFixtureDacl -Path $script:SpoolRoot -Acl $acl
            $null = New-Item -ItemType Directory -Path $nested
            $before = (Get-Acl -LiteralPath $nested).Sddl
            { Initialize-SpoolDirectory -SpoolDirectory $nested } | Should -Throw '*untrusted write*'
            (Get-Acl -LiteralPath $nested).Sddl | Should -BeExactly $before
        }

        It 'rejects a null DACL even when the owner is trusted' {
            Mock -ModuleName InventorySpool Get-Acl {
                $acl = New-Object Security.AccessControl.DirectorySecurity
                $acl.SetSecurityDescriptorSddlForm('O:BAD:NO_ACCESS_CONTROL')
                return $acl
            } -ParameterFilter { $LiteralPath -eq $script:SpoolRoot }
            { Initialize-SpoolDirectory -SpoolDirectory $script:SpoolRoot } | Should -Throw '*null DACL*'
        }

        It 'accepts a secure existing path that grants users only read access' {
            $acl = Get-Acl -LiteralPath $script:SpoolRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::ReadAndExecute, 'Allow'))
            Set-SpoolFixtureDacl -Path $script:SpoolRoot -Acl $acl
            $before = (Get-Acl -LiteralPath $script:SpoolRoot).Sddl
            $null = Save-SpoolEntry -SpoolDirectory $script:SpoolRoot -Body '{}' -TableName 'T_CL'
            @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot).Count | Should -Be 1
            (Get-Acl -LiteralPath $script:SpoolRoot).Sddl | Should -BeExactly $before
        }

        It 'rejects reparse point entries without following or removing their targets' {
            $target = Join-Path $script:SpoolRoot 'quarantine'
            $link = Join-Path $script:SpoolRoot 'planted.json'
            $null = New-Item -ItemType Junction -Path $link -Target $target
            try {
                { Get-SpoolEntry -SpoolDirectory $script:SpoolRoot } | Should -Throw '*reparse*'
                { Invoke-SpoolMaintenance -SpoolDirectory $script:SpoolRoot } | Should -Throw '*reparse*'
                { ConvertFrom-SpoolFile -Path $link } | Should -Throw '*reparse*'
                Test-Path -LiteralPath $target | Should -BeTrue
            }
            finally { [IO.Directory]::Delete($link) }
        }

        It 'checks non-json entries such as the lock file before opening anything' {
            $path = Join-Path $script:SpoolRoot '.drain.lock'
            Set-Content -LiteralPath $path -Value 'planted'
            $acl = Get-Acl -LiteralPath $path
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [Security.AccessControl.FileSystemRights]::Write, 'Allow'))
            Set-SpoolFixtureDacl -Path $path -Acl $acl
            { Enter-SpoolLock -SpoolDirectory $script:SpoolRoot } | Should -Throw '*untrusted write*'
        }

        It 'rejects alternate streams, UNC and normalized aliases' {
            foreach ($path in @("$script:SpoolRoot`:stream", '\\localhost\c$\spool', "$script:SpoolRoot\..\spool", "$script:SpoolRoot. ")) {
                { Initialize-SpoolDirectory -SpoolDirectory $path } | Should -Throw '*Unsafe spool path*'
            }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:SpoolRoot) {
            Remove-Item -LiteralPath $script:SpoolRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Save-SpoolEntry' {

        It 'writes a readable entry and returns its path' {
            $path = Save-SpoolEntry -Body '{"records":[]}' -TableName 'InventoryWindows_CL' -SpoolDirectory $script:SpoolRoot

            Test-Path -LiteralPath $path | Should -BeTrue
            @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot).Count | Should -Be 1
        }

        It 'leaves no .tmp residue behind after a successful write' {
            $null = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

            @(Get-ChildItem -LiteralPath $script:SpoolRoot -Filter '*.tmp' -File).Count | Should -Be 0
        }

        It 'round-trips the exact body bytes' {
            $body = '{"records":[{"Unicode":"caf\u00e9","Nested":{"a":[1,2,3]}}]}'
            $null = Save-SpoolEntry -Body $body -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

            (Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)[0].Body | Should -BeExactly $body
        }

        It 'creates the quarantine directory alongside the spool' {
            $null = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

            Test-Path -LiteralPath (Join-Path $script:SpoolRoot 'quarantine') | Should -BeTrue
        }

        It 'enforces the entry-count quota by discarding the oldest entries' {
            1..5 | ForEach-Object {
                $null = Save-SpoolEntry -Body "{`"n`":$_}" -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot -MaxEntries 3
                Start-Sleep -Milliseconds 5
            }

            $remaining = @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)
            $remaining.Count | Should -Be 3

            # The survivors must be the newest three, not an arbitrary subset.
            $remaining[-1].Body | Should -BeExactly '{"n":5}'
        }
    }

    Context 'Get-SpoolEntry' {

        It 'returns entries oldest first' {
            1..3 | ForEach-Object {
                $null = Save-SpoolEntry -Body "{`"n`":$_}" -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
                Start-Sleep -Milliseconds 5
            }

            $entries = @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)
            $entries[0].Body | Should -BeExactly '{"n":1}'
            $entries[2].Body | Should -BeExactly '{"n":3}'
        }

        It 'honours the -First limit' {
            1..5 | ForEach-Object {
                $null = Save-SpoolEntry -Body "{`"n`":$_}" -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
                Start-Sleep -Milliseconds 5
            }

            @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot -First 2).Count | Should -Be 2
        }

        It 'returns an empty result for a directory that does not exist' {
            @(Get-SpoolEntry -SpoolDirectory (Join-Path $script:SpoolRoot 'nope')).Count | Should -Be 0
        }

        It 'quarantines an unparseable entry instead of failing the whole drain' {
            $null = Save-SpoolEntry -Body '{"good":true}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
            Set-Content -LiteralPath (Join-Path $script:SpoolRoot '19990101T000000000-corrupt.json') -Value 'not json at all'

            $entries = @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)

            $entries.Count | Should -Be 1
            @(Get-ChildItem -LiteralPath (Join-Path $script:SpoolRoot 'quarantine') -File).Count | Should -Be 1
        }

        It 'quarantines an entry written by an unsupported spool version' {
            $payload = @{ spoolVersion = 'LOGCOLLECTOR-SPOOL-V0'; body = '{}' } | ConvertTo-Json -Compress
            Set-Content -LiteralPath (Join-Path $script:SpoolRoot '19990101T000000001-old.json') -Value $payload

            @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $script:SpoolRoot 'quarantine') -File).Count | Should -Be 1
        }
    }

    Context 'Update-SpoolEntryAttempt' {

        It 'retries a transient replace failure without changing the body' {
            $path = Save-SpoolEntry -Body '{"keep":"me"}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
            InModuleScope InventorySpool { $script:ReplaceCalls = 0 }
            Mock -ModuleName InventorySpool Invoke-SpoolFileReplace {
                param($Source, $Destination)
                $script:ReplaceCalls++
                if ($script:ReplaceCalls -lt 3) { throw [IO.IOException]::new('temporary scanner lock') }
                [IO.File]::Replace($Source, $Destination, [NullString]::Value)
            }
            Mock -ModuleName InventorySpool Start-Sleep {}
            Update-SpoolEntryAttempt -Path $path | Should -Be 1
            Should -Invoke -ModuleName InventorySpool Invoke-SpoolFileReplace -Times 3 -Exactly
            (Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)[0].Body | Should -BeExactly '{"keep":"me"}'
        }

        It 'retains the original entry and fails after bounded replace retries' {
            $path = Save-SpoolEntry -Body '{"keep":"me"}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
            Mock -ModuleName InventorySpool Invoke-SpoolFileReplace { throw [IO.IOException]::new('persistent lock') }
            Mock -ModuleName InventorySpool Start-Sleep {}
            { Update-SpoolEntryAttempt -Path $path } | Should -Throw '*persistent lock*'
            Should -Invoke -ModuleName InventorySpool Invoke-SpoolFileReplace -Times 5 -Exactly
            $entry = @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)[0]
            $entry.Attempts | Should -Be 0
            $entry.Body | Should -BeExactly '{"keep":"me"}'
        }

        It 'increments and persists the attempt counter' {
            $path = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

            Update-SpoolEntryAttempt -Path $path | Should -Be 1
            Update-SpoolEntryAttempt -Path $path | Should -Be 2

            (Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)[0].Attempts | Should -Be 2
        }

        It 'preserves the body across attempt updates' {
            $path = Save-SpoolEntry -Body '{"keep":"me"}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
            $null = Update-SpoolEntryAttempt -Path $path

            (Get-SpoolEntry -SpoolDirectory $script:SpoolRoot)[0].Body | Should -BeExactly '{"keep":"me"}'
        }
    }

    Context 'Move-SpoolEntryToQuarantine' {

        It 'moves the entry out of the live set' {
            $path = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

            $target = Move-SpoolEntryToQuarantine -Path $path -Reason 'http-400'

            Test-Path -LiteralPath $path | Should -BeFalse
            Test-Path -LiteralPath $target | Should -BeTrue
            @(Get-SpoolEntry -SpoolDirectory $script:SpoolRoot).Count | Should -Be 0
        }

        It 'records the reason in the quarantined file name' {
            $path = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

            $target = Move-SpoolEntryToQuarantine -Path $path -Reason 'http-413'

            (Split-Path -Leaf $target) | Should -BeLike '*http-413'
        }
    }

    Context 'Invoke-SpoolMaintenance' {

        It 'deletes entries older than the age quota' {
            $path = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-30)

            $result = Invoke-SpoolMaintenance -SpoolDirectory $script:SpoolRoot -MaxAgeDays 7

            $result.RemovedExpired | Should -Be 1
            $result.RemainingEntries | Should -Be 0
        }

        It 'keeps entries inside the age quota' {
            $null = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot

            $result = Invoke-SpoolMaintenance -SpoolDirectory $script:SpoolRoot -MaxAgeDays 7

            $result.RemovedExpired | Should -Be 0
            $result.RemainingEntries | Should -Be 1
        }

        It 'ages out quarantined entries too, so quarantine cannot grow forever' {
            $path = Save-SpoolEntry -Body '{}' -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot
            $target = Move-SpoolEntryToQuarantine -Path $path -Reason 'http-400'
            (Get-Item -LiteralPath $target).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-30)

            $null = Invoke-SpoolMaintenance -SpoolDirectory $script:SpoolRoot -MaxAgeDays 7

            @(Get-ChildItem -LiteralPath (Join-Path $script:SpoolRoot 'quarantine') -File).Count | Should -Be 0
        }

        It 'cleans up stale .tmp files left by an interrupted write' {
            $stale = Join-Path $script:SpoolRoot 'interrupted.json.tmp'
            Set-Content -LiteralPath $stale -Value 'partial'
            (Get-Item -LiteralPath $stale).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-4)

            $null = Invoke-SpoolMaintenance -SpoolDirectory $script:SpoolRoot -MaxAgeDays 7

            Test-Path -LiteralPath $stale | Should -BeFalse
        }

        It 'enforces the total-size quota by removing the oldest entries first' {
            $big = '{"pad":"' + ('x' * 4000) + '"}'
            1..5 | ForEach-Object {
                $null = Save-SpoolEntry -Body $big -TableName 'T_CL' -SpoolDirectory $script:SpoolRoot -MaxTotalBytes 1073741824
                Start-Sleep -Milliseconds 5
            }

            $result = Invoke-SpoolMaintenance -SpoolDirectory $script:SpoolRoot -MaxTotalBytes 9000

            $result.RemovedOverQuota | Should -BeGreaterThan 0
            $result.RemainingEntries | Should -BeLessThan 5
        }

        It 'is a no-op for a directory that does not exist' {
            $result = Invoke-SpoolMaintenance -SpoolDirectory (Join-Path $script:SpoolRoot 'missing')

            $result.RemovedExpired | Should -Be 0
            $result.RemainingEntries | Should -Be 0
        }
    }

    Context 'Enter-SpoolLock / Exit-SpoolLock' {

        It 'grants the lock to the first caller and refuses the second' {
            $first = Enter-SpoolLock -SpoolDirectory $script:SpoolRoot
            try {
                $first | Should -Not -BeNullOrEmpty

                # A second overlapping run must not drain the same entries twice.
                $second = Enter-SpoolLock -SpoolDirectory $script:SpoolRoot
                $second | Should -BeNullOrEmpty
            }
            finally {
                Exit-SpoolLock -LockStream $first
            }
        }

        It 'allows the lock to be reacquired after release' {
            $first = Enter-SpoolLock -SpoolDirectory $script:SpoolRoot
            Exit-SpoolLock -LockStream $first

            $second = Enter-SpoolLock -SpoolDirectory $script:SpoolRoot
            try { $second | Should -Not -BeNullOrEmpty }
            finally { Exit-SpoolLock -LockStream $second }
        }

        It 'tolerates being released with a null stream' {
            { Exit-SpoolLock -LockStream $null } | Should -Not -Throw
        }
    }
}

Describe 'InventorySpool production trust policy (without fixture substitution)' {
    It 'trusts only SYSTEM and Administrators for spool ownership or writes' {
        InModuleScope InventorySpool {
            Test-SpoolTrustedIdentity -Sid 'S-1-5-18' | Should -BeTrue
            Test-SpoolTrustedIdentity -Sid 'S-1-5-32-544' | Should -BeTrue
            Test-SpoolTrustedIdentity -Sid 'S-1-5-32-545' | Should -BeFalse
            Test-SpoolTrustedIdentity -Sid 'S-1-5-21-1-2-3-1001' | Should -BeFalse
            Test-SpoolTrustedIdentity -Sid 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' | Should -BeFalse
            Test-SpoolTrustedIdentity -Sid 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' -Ancestor | Should -BeTrue
        }
    }

    It 'creates protected SYSTEM and Administrators-only security descriptors' {
        InModuleScope InventorySpool {
            foreach ($directory in @($true, $false)) {
                $acl = New-SpoolSecurityDescriptor -Directory:$directory
                $acl.AreAccessRulesProtected | Should -BeTrue
                $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
                $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                $rules.Count | Should -Be 2
                @($rules.IdentityReference.Value) | Should -Contain 'S-1-5-18'
                @($rules.IdentityReference.Value) | Should -Contain 'S-1-5-32-544'
            }
        }
    }
}
