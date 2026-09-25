BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:OriginalModulePath = $env:PSModulePath
    $moduleRoot = Join-Path $TestDrive 'PowerShellModules\LogCollector.Client'
    $null = New-Item -ItemType Directory -Path $moduleRoot -Force
    $manifest = Import-PowerShellDataFile (Join-Path $script:Repo 'src\Client\LogCollector.Client.psd1')
    foreach ($file in $manifest.FileList) {
        Copy-Item -LiteralPath (Join-Path $script:Repo "src\Client\$file") -Destination (Join-Path $moduleRoot $file)
    }
    $env:PSModulePath = (Split-Path $moduleRoot -Parent) +
        [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module LogCollector.Client -RequiredVersion 1.11.1 -Force -ErrorAction Stop
    $builder = Join-Path $script:Repo 'scripts\Publish-InventoryPackage.ps1'
    $script:Package = & $builder -OutputRoot (Join-Path $TestDrive 'Package')
    $custom = Join-Path $TestDrive 'OtherTables.psd1'
    (Get-Content (Join-Path $script:Package.PackagePath 'Config.psd1') -Raw).
        Replace('DeviceInventory_CL', 'HardwareLab_CL') | Set-Content $custom
    $script:OtherTables = & $builder -ConfigurationPath $custom -OutputRoot (Join-Path $TestDrive 'OtherTables')
    $script:Installed = Join-Path $TestDrive 'Installed'
    $null = New-Item -ItemType Directory -Path $script:Installed
    Copy-Item -Path (Join-Path $script:Package.PackagePath '*') -Destination $script:Installed -Recurse
    foreach ($variant in @('Package', 'OtherTables')) {
        $package = Get-Variable -Name $variant -Scope Script -ValueOnly
        $text = Get-Content (Join-Path $package.PackagePath 'Detect.ps1') -Raw
        $coreManifestAssignment = '$coreManifest = Join-Path ([Environment]::GetFolderPath(''ProgramFiles'')) ''WindowsPowerShell\Modules\LogCollector.Client\LogCollector.Client.psd1'''
        $fixtureManifestAssignment = '$coreManifest = ''' + (Join-Path $moduleRoot 'LogCollector.Client.psd1').Replace("'", "''") + ''''
        $text = $text.Replace($coreManifestAssignment, $fixtureManifestAssignment)
        # Only redirect the installation root in this test copy. Hash and task checks stay intact.
        $original = '$target = Join-Path (Join-Path ([Environment]::GetFolderPath(''ProgramFiles'')) $customerName) ''CustomInventory'''
        if (-not $text.Contains($original)) { throw 'Detection fixture cannot locate the installation root.' }
        $text.Replace($original, ('$target = ''' + $script:Installed.Replace("'", "''") + '''')) |
            Set-Content (Join-Path $TestDrive "$variant-Detect.ps1")
    }
    $script:PackageDetection = Join-Path $TestDrive 'Package-Detect.ps1'
    $script:OtherTablesDetection = Join-Path $TestDrive 'OtherTables-Detect.ps1'
}

AfterAll {
    Remove-Variable -Name InventoryDetectionTestTasks -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in @('Inventory.Runtime', 'Inventory.Collection', 'Inventory.Logging', 'LogCollector.Client',
        'InventoryClient', 'InventorySpool', 'DeviceIdentity', 'RequestSigning')) {
        Get-Module -All -Name $name | Remove-Module -Force -ErrorAction Stop
    }
    $env:PSModulePath = $script:OriginalModulePath
}

Describe 'Configuration-aware inventory detection' {
    BeforeEach {
        Copy-Item -LiteralPath (Join-Path $script:Package.PackagePath 'Config.psd1') -Destination $script:Installed -Force
        $global:InventoryCoreSubmissionEnabled = $true
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{ CustomerName = 'LogCollector'; SubmissionEnabled = $global:InventoryCoreSubmissionEnabled }
        }
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
        $output = @(& $script:PackageDetection)
        $LASTEXITCODE | Should -Be 0
        $output.Count | Should -BeGreaterThan 0
        $output -join '' | Should -Match 'CoreSubmissionEnabled=True'
    }

    It 'requires reinstall when collector-specific configuration changes' {
        Copy-Item -LiteralPath (Join-Path $script:OtherTables.PackagePath 'Config.psd1') -Destination $script:Installed -Force
        @(& $script:PackageDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
        @(& $script:OtherTablesDetection).Count | Should -BeGreaterThan 0
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
        @(& $script:PackageDetection).Count | Should -BeGreaterThan 0
        $LASTEXITCODE | Should -Be 0
    }

    It 'rejects a missing installed configuration or runtime file' -ForEach @(
        @{ MissingFile = 'Version' }, @{ MissingFile = 'Config.psd1' },
        @{ MissingFile = 'Inventory.Runtime.psm1' }, @{ MissingFile = 'Inventory.Logging.psm1' }
    ) {
        $path = Join-Path $script:Installed $MissingFile
        Remove-Item -LiteralPath $path
        try {
            @(& $script:PackageDetection).Count | Should -Be 0
            $LASTEXITCODE | Should -Be 1
        }
        finally {
            Copy-Item -LiteralPath (Join-Path $script:Package.PackagePath $MissingFile) -Destination $path
        }
    }

    It 'follows Core enabled-to-disabled changes without rebuilding Inventory' {
        $global:InventoryCoreSubmissionEnabled = $false
        foreach ($task in $global:InventoryDetectionTestTasks) { $task.Settings.Enabled = $false }
        @(& $script:PackageDetection).Count | Should -BeGreaterThan 0
        $LASTEXITCODE | Should -Be 0
    }

    It 'detects drift in any configuration field, including comments' -ForEach @(
        @{ From = 'DeviceInventory_CL'; To = 'HardwareOther_CL' },
        @{ From = 'MaxAttempts = 3'; To = 'MaxAttempts = 4' },
        @{ From = '@{'; To = "@{`n# changed formatting" }
    ) {
        $path = Join-Path $script:Installed 'Config.psd1'
        (Get-Content $path -Raw).Replace($From, $To) | Set-Content $path
        @(& $script:PackageDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects an enabled configuration whose task is disabled' {
        $global:InventoryDetectionTestTasks[1].Settings.Enabled = $false
        @(& $script:PackageDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects a task pointing at another package version or script' {
        $global:InventoryDetectionTestTasks[0].Actions[0].Arguments = '-File "C:\OldPackage\Run-Inventory.ps1"'
        @(& $script:PackageDetection).Count | Should -Be 0
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
        @(& $script:PackageDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'does not detect after uninstall even when configuration and files remain' {
        $global:InventoryDetectionTestTasks = @()
        @(& $script:PackageDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects the unrendered repository template' {
        @(& (Join-Path $script:Repo 'src\InventoryPackage\Detect.ps1')).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects a Core configuration without a customer identity' {
        Mock Get-LogCollectorEndpointConfiguration {
            [pscustomobject]@{ CustomerName = ''; SubmissionEnabled = $true }
        }
        @(& $script:PackageDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects a mismatched installed version file' {
        Set-Content -LiteralPath (Join-Path $script:Installed 'Version') -Value '1.8.0'
        @(& $script:PackageDetection).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }
}
