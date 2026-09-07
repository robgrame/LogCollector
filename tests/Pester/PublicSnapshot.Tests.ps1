BeforeAll {
    $script:Publisher = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\Publish-PublicSnapshot.ps1'

    function New-PublicSnapshotTestRepo {
        param(
            [string] $Path,
            [string] $Content,
            [string] $PolicyContent = 'customer-secret-marker'
        )
        $null = New-Item -ItemType Directory -Path $Path -Force
        $null = & git -C $Path init -q -b main 2>$null
        $null = & git -C $Path config user.name 'Pester' 2>$null
        $null = & git -C $Path config user.email 'pester@example.invalid' 2>$null
        [IO.File]::WriteAllText((Join-Path $Path 'README.md'), $Content)
        [IO.File]::WriteAllText((Join-Path $Path '.public-snapshot'), "Format=LogCollectorPublicSnapshot/v1`nRepositoryId=__TARGET_REPOSITORY_ID__")
        [IO.File]::WriteAllText((Join-Path $Path '.gitignore'), ".public-release-policy.local.txt`n")
        $null = & git -C $Path add README.md .public-snapshot .gitignore 2>$null
        $null = & git -C $Path commit -q -m 'test fixture' 2>$null
        $policy = Join-Path $Path '.public-release-policy.local.txt'
        [IO.File]::WriteAllText($policy, $PolicyContent)
        return $policy
    }

    function Invoke-PublicSnapshotScan {
        param([string] $Repo, [string] $Policy, [string] $Engine = 'pwsh')
        $output = & $Engine -NoProfile -File $script:Publisher -ScanOnly -PolicyPath $Policy 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}

Describe 'Public snapshot publisher' {
    It 'accepts a clean snapshot with documented placeholders' {
        $repo = Join-Path $TestDrive 'clean'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content @'
Endpoint: https://your-intake.azurewebsites.net/api/submit
Subscription: 00000000-0000-0000-0000-000000000000
Contact: test@example.invalid
Address: 192.0.2.10
'@
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Clean'
    }

    It 'rejects an unapproved GUID' {
        $repo = Join-Path $TestDrive 'guid'
        # Built via concatenation so this fixture GUID is not one contiguous
        # literal in this test file's own source text (it would otherwise
        # trip the scanner when this repository itself is scanned).
        $guid = '12345678-1234' + '-1234-1234-123456789abc'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content "Tenant: $guid"
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Unapproved GUID'
    }

    It 'accepts a documented placeholder GUID made of one repeated hex digit' {
        $repo = Join-Path $TestDrive 'guid-placeholder'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content 'CorrelationId: 22222222-2222-2222-2222-222222222222'
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Clean'
    }

    It 'does not mistake a certificate policy or EKU OID for a public IPv4 address' {
        $repo = Join-Path $TestDrive 'oid'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content @'
ClientAuthEku = '1.3.6.1.5.5.7.3.2'
BasicConstraints = '2.5.29.19'
'@
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Clean'
    }

    It 'rejects a customer-specific local deny literal without echoing it' {
        $repo = Join-Path $TestDrive 'policy'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content 'Deployment for PrivateCustomerName' `
            -PolicyContent 'PrivateCustomerName'
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Local deny policy'
        $result.Output | Should -Not -Match 'PrivateCustomerName'
    }

    It 'rejects common credential assignments without echoing the value' {
        $repo = Join-Path $TestDrive 'credential'
        $content = '{"' + ('client' + '_secret') + '":"' + 'ThisIsARealLookingSecretValue1234567890' + '"}'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content $content
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Credential assignment'
        $result.Output | Should -Not -Match 'ThisIsARealLookingSecretValue'
    }

    It 'does not mistake a quoted dollar-prefixed secret for a variable reference' {
        $repo = Join-Path $TestDrive 'dollar-secret'
        $content = '{"' + ('pass' + 'word') + '":"' + '$uperSecret123456789' + '"}'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content $content
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Credential assignment'
        $result.Output | Should -Not -Match 'uperSecret'
    }

    It 'rejects credentials that merely start with a placeholder-like prefix' {
        $repo = Join-Path $TestDrive 'prefix-secret'
        $content = '{"' + ('pass' + 'word') + '":"' + ('your-' + 'actual-production-secret') + '"}'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content $content
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Credential assignment'
        $result.Output | Should -Not -Match 'actual-production-secret'
    }

    It 'rejects all PEM private-key headers' {
        $repo = Join-Path $TestDrive 'pem-key'
        $content = ('-----BEGIN DSA ' + 'PRIVATE KEY-----') + "`nplaceholder`n-----END DSA PRIVATE KEY-----"
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content $content
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Private key'
        $result.Output | Should -Not -Match 'BEGIN DSA'
    }

    It 'reads a UTF-8 deny policy correctly in Windows PowerShell 5.1' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $repo = Join-Path $TestDrive 'unicode-policy'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content 'Deployment for CaféCustomer' `
            -PolicyContent 'CaféCustomer'
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy -Engine 'powershell.exe' }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Local deny policy'
        $result.Output | Should -Not -Match 'CaféCustomer'
    }

    It 'rejects binary content even with an unrecognized extension' {
        $repo = Join-Path $TestDrive 'binary'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content 'Safe content'
        [IO.File]::WriteAllBytes((Join-Path $repo 'payload.dat'), [byte[]](0, 255, 1, 2, 3, 4))
        $null = & git -C $repo add payload.dat 2>$null
        $null = & git -C $repo commit -q -m 'add binary fixture' 2>$null
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Non-text or invalid encoding'
    }

    It 'rejects export-subst before private commit metadata can enter the archive' {
        $repo = Join-Path $TestDrive 'export-subst'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content 'Safe content'
        [IO.File]::WriteAllText((Join-Path $repo '.gitattributes'), "history.txt export-subst`n")
        [IO.File]::WriteAllText((Join-Path $repo 'history.txt'), '$Format:%s$')
        $null = & git -C $repo add .gitattributes history.txt 2>$null
        $null = & git -C $repo commit -q -m 'private customer commit subject' 2>$null
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'export-subst'
        $result.Output | Should -Not -Match 'private customer commit subject'
    }

    It 'rejects and redacts customer identifiers in file names' {
        $repo = Join-Path $TestDrive 'filename'
        $policy = New-PublicSnapshotTestRepo -Path $repo -Content 'Safe content' `
            -PolicyContent 'PrivateCustomerName'
        [IO.File]::WriteAllText((Join-Path $repo 'PrivateCustomerName.txt'), 'Safe content')
        $null = & git -C $repo add PrivateCustomerName.txt 2>$null
        $null = & git -C $repo commit -q -m 'add named fixture' 2>$null
        Push-Location $repo
        try { $result = Invoke-PublicSnapshotScan -Repo $repo -Policy $policy }
        finally { Pop-Location }
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Local deny policy in path'
        $result.Output | Should -Not -Match 'PrivateCustomerName'
    }
}
