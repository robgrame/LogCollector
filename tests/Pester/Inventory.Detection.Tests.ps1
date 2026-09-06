BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $builder = Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1'
    $script:Disabled = & $builder -FrontendUrl 'https://example.invalid/api/inventory' -OutputRoot (Join-Path $TestDrive 'Disabled')
    $custom = Join-Path $TestDrive 'Enabled.psd1'
    (Get-Content (Join-Path $script:Disabled.PackagePath 'Config.psd1') -Raw).
        Replace('SubmissionEnabled = $false', 'SubmissionEnabled = $true') | Set-Content $custom
    $script:Enabled = & $builder -ConfigurationPath $custom -OutputRoot (Join-Path $TestDrive 'Enabled')
    $script:Installed = Join-Path $TestDrive 'Installed'
    $null = New-Item -ItemType Directory -Path $script:Installed
    Copy-Item -Path (Join-Path $script:Enabled.PackagePath '*') -Destination $script:Installed -Recurse
    foreach ($variant in @('Enabled', 'Disabled')) {
        $package = Get-Variable -Name $variant -Scope Script -ValueOnly
        $text = Get-Content (Join-Path $package.PackagePath 'Detect.ps1') -Raw
        # Only redirect the installation root in this test copy. Hash and task checks stay intact.
        $original = '$target = Join-Path ([Environment]::GetFolderPath(''ProgramFiles'')) ''LogCollector\CustomInventory\' + $package.PackageVersion + ''''
        if (-not $text.Contains($original)) { throw 'Detection fixture cannot locate the installation root.' }
        $text.Replace($original, ('$target = ''' + $script:Installed.Replace("'", "''") + '''')) |
            Set-Content (Join-Path $TestDrive "$variant-Detect.ps1")
    }
    $script:EnabledDetection = Join-Path $TestDrive 'Enabled-Detect.ps1'
    $script:DisabledDetection = Join-Path $TestDrive 'Disabled-Detect.ps1'
}

AfterAll {
    Remove-Variable -Name InventoryDetectionTestTasks -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in @('Inventory.Runtime', 'Inventory.Collection', 'LogCollector.Client',
        'InventoryClient', 'InventorySpool', 'DeviceIdentity', 'RequestSigning')) {
        Get-Module -All -Name $name | Remove-Module -Force -ErrorAction Stop
    }
}

Describe 'Configuration-aware inventory detection' {
    BeforeEach {
        Copy-Item -LiteralPath (Join-Path $script:Enabled.PackagePath 'Config.psd1') -Destination $script:Installed -Force
        $global:InventoryDetectionTestTasks = @(
            foreach ($entry in @(
                @{ Name = 'LogCollector-CustomInventory'; Script = 'Run-Inventory.ps1' },
                @{ Name = 'LogCollector-CustomInventory-Spool'; Script = 'Sync-Spool.ps1' }
            )) {
                [pscustomobject]@{
                    TaskName = $entry.Name; TaskPath = '\LogCollector\'
                    Settings = [pscustomobject]@{ Enabled = $true }
                    Principal = [pscustomobject]@{ UserId = 'S-1-5-18'; LogonType = 'ServiceAccount'; RunLevel = 'Highest' }
                    Actions = @([pscustomobject]@{
                        Execute = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                        Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:Installed $entry.Script)
                    })
                }
            }
        )
        Mock Get-ScheduledTask { $global:InventoryDetectionTestTasks }
    }

    It 'detects the enabled package with stdout and exit zero' {
        $output = @(& $script:EnabledDetection)
        $LASTEXITCODE | Should -Be 0
        $output.Count | Should -BeGreaterThan 0
        $output -join '' | Should -Match 'SubmissionEnabled=True'
    }

    It 'requires reinstall for disabled-to-enabled configuration then detects the updated installation' {
        Copy-Item -LiteralPath (Join-Path $script:Disabled.PackagePath 'Config.psd1') -Destination $script:Installed -Force
        @(& $script:EnabledDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
        Copy-Item -LiteralPath (Join-Path $script:Enabled.PackagePath 'Config.psd1') -Destination $script:Installed -Force
        @(& $script:EnabledDetection).Count | Should -BeGreaterThan 0
        $LASTEXITCODE | Should -Be 0
    }

    It 'accepts native ScheduledTasks property types without registering a task' {
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        foreach ($task in $global:InventoryDetectionTestTasks) {
            $action = New-ScheduledTaskAction -Execute $task.Actions[0].Execute -Argument $task.Actions[0].Arguments
            $definition = New-ScheduledTask -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet)
            $task.Principal = $definition.Principal
            $task.Actions = $definition.Actions
            $task.Settings = $definition.Settings
        }
        @(& $script:EnabledDetection).Count | Should -BeGreaterThan 0
        $LASTEXITCODE | Should -Be 0
    }

    It 'rejects a missing installed configuration or runtime file' -ForEach @(
        @{ MissingFile = 'Config.psd1' }, @{ MissingFile = 'Inventory.Runtime.psm1' }
    ) {
        $path = Join-Path $script:Installed $MissingFile
        Remove-Item -LiteralPath $path
        try {
            @(& $script:EnabledDetection).Count | Should -Be 0
            $LASTEXITCODE | Should -Be 1
        }
        finally {
            Copy-Item -LiteralPath (Join-Path $script:Enabled.PackagePath $MissingFile) -Destination $path
        }
    }

    It 'supports enabled-to-disabled rollout without changing the script version' {
        $script:Disabled.PackageVersion | Should -BeExactly $script:Enabled.PackageVersion
        @(& $script:DisabledDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
        Copy-Item -LiteralPath (Join-Path $script:Disabled.PackagePath 'Config.psd1') -Destination $script:Installed -Force
        foreach ($task in $global:InventoryDetectionTestTasks) { $task.Settings.Enabled = $false }
        @(& $script:DisabledDetection).Count | Should -BeGreaterThan 0
        $LASTEXITCODE | Should -Be 0
    }

    It 'detects drift in any configuration field, including comments' -ForEach @(
        @{ From = 'example.invalid'; To = 'other.invalid' },
        @{ From = "CertificateThumbprint = ''"; To = "CertificateThumbprint = 'AABB'" },
        @{ From = '@{'; To = "@{`n# changed formatting" }
    ) {
        $path = Join-Path $script:Installed 'Config.psd1'
        (Get-Content $path -Raw).Replace($From, $To) | Set-Content $path
        @(& $script:EnabledDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects an enabled configuration whose task is disabled' {
        $global:InventoryDetectionTestTasks[1].Settings.Enabled = $false
        @(& $script:EnabledDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects a task pointing at another package version or script' {
        $global:InventoryDetectionTestTasks[0].Actions[0].Arguments = '-File "C:\OldPackage\Run-Inventory.ps1"'
        @(& $script:EnabledDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects an unexpected executable, extra action or non-SYSTEM principal' -ForEach @(
        @{ Change = 'Executable' }, @{ Change = 'ExtraAction' }, @{ Change = 'Principal' }
    ) {
        switch ($Change) {
            'Executable' { $global:InventoryDetectionTestTasks[0].Actions[0].Execute = 'pwsh.exe' }
            'ExtraAction' { $global:InventoryDetectionTestTasks[0].Actions += $global:InventoryDetectionTestTasks[0].Actions[0] }
            'Principal' { $global:InventoryDetectionTestTasks[0].Principal.UserId = 'TestUser' }
        }
        @(& $script:EnabledDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'does not detect after uninstall even when configuration and files remain' {
        $global:InventoryDetectionTestTasks = @()
        @(& $script:EnabledDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects the unrendered repository template' {
        @(& (Join-Path $script:Repo 'src\InventoryPackage\Detect.ps1')).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }
}
