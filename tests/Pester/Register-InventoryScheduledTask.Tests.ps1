<#
.SYNOPSIS
    Pester tests for Register-InventoryScheduledTask.ps1.

.DESCRIPTION
    Two kinds of coverage:

      1. Cmdlet compatibility. Every parameter the script passes to a
         ScheduledTasks cmdlet is asserted against the LIVE cmdlet metadata. This
         is what catches the class of defect where a plausible-looking switch
         such as -DontStopIfGoingToSleep does not actually exist: the script
         parses and reviews cleanly, then fails at parameter binding on the
         endpoint and the task is never created.

      2. Behaviour. The real New-ScheduledTask* constructors run (they build
         in-memory objects and touch nothing), while only the four cmdlets that
         mutate the system are mocked. That keeps the schedule assertions honest
         - they inspect the object the script would really have registered.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:ScriptPath = Join-Path $repoRoot 'scripts\Register-InventoryScheduledTask.ps1'
    $script:CollectorPath = Join-Path $repoRoot 'scripts\Invoke-CustomInventory.ps1'

    # Wednesday (8) + Saturday (64) as encoded by MSFT_TaskWeeklyTrigger.
    $script:WednesdayAndSaturday = 72

    function Get-ScheduledTaskCommandAst {
        <#
        .SYNOPSIS
            Returns every ScheduledTasks cmdlet invocation in the script, with the
            parameter names it passes.
        #>
        param([Parameter(Mandatory)] [string] $Path)

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { throw "Script does not parse: $($errors[0].Message)" }

        $commands = $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true)

        $results = New-Object System.Collections.ArrayList
        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            if (-not $name -or $name -notlike '*ScheduledTask*') { continue }

            $parameters = @($command.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object { $_.ParameterName })

            $null = $results.Add([pscustomobject]@{
                Name       = $name
                Parameters = $parameters
            })
        }

        return @($results)
    }

    function Get-LocalStartHour {
        param([Parameter(Mandatory)] [string] $StartBoundary)

        $parsed = [datetime]::Parse(
            $StartBoundary,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)

        if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { return $parsed.ToLocalTime() }
        return $parsed
    }
}

Describe 'Register-InventoryScheduledTask cmdlet compatibility' {

    It 'passes only parameters that exist on the live ScheduledTasks cmdlets' {
        foreach ($invocation in (Get-ScheduledTaskCommandAst -Path $script:ScriptPath)) {
            $metadata = Get-Command -Name $invocation.Name -ErrorAction SilentlyContinue
            $metadata | Should -Not -BeNullOrEmpty -Because "$($invocation.Name) must exist on a supported Windows host"

            foreach ($parameterName in $invocation.Parameters) {
                $matched = @($metadata.Parameters.Keys | Where-Object { $_ -like "$parameterName*" })
                $matched.Count | Should -BeGreaterThan 0 -Because "$($invocation.Name) -$parameterName must be a real parameter"
            }
        }
    }

    It 'does not use the non-existent -DontStopIfGoingToSleep switch' {
        # Asserted against the AST rather than the file text so the explanatory
        # comment in the script does not mask a real regression.
        $settings = @(Get-ScheduledTaskCommandAst -Path $script:ScriptPath |
            Where-Object { $_.Name -eq 'New-ScheduledTaskSettingsSet' })

        $settings.Count | Should -Be 1
        $settings[0].Parameters | Should -Not -Contain 'DontStopIfGoingToSleep'
        (Get-Command New-ScheduledTaskSettingsSet).Parameters.Keys | Should -Not -Contain 'DontStopIfGoingToSleep'
    }

    It 'uses the real -DontStopIfGoingOnBatteries switch instead' {
        $settings = @(Get-ScheduledTaskCommandAst -Path $script:ScriptPath |
            Where-Object { $_.Name -eq 'New-ScheduledTaskSettingsSet' })[0]

        $settings.Parameters | Should -Contain 'DontStopIfGoingOnBatteries'
        (Get-Command New-ScheduledTaskSettingsSet).Parameters.Keys | Should -Contain 'DontStopIfGoingOnBatteries'
    }

    It 'builds the settings object for real without a binding error' {
        {
            New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 30)
        } | Should -Not -Throw
    }

    It 'registers with -Force instead of unregistering first' {
        $invocations = Get-ScheduledTaskCommandAst -Path $script:ScriptPath

        # Unregistering first leaves a window with no inventory task, and a failure
        # in between leaves the device permanently unmanaged.
        @($invocations | Where-Object { $_.Name -eq 'Unregister-ScheduledTask' }).Count | Should -Be 0

        $register = @($invocations | Where-Object { $_.Name -eq 'Register-ScheduledTask' })
        $register.Count | Should -Be 1
        $register[0].Parameters | Should -Contain 'Force'
    }
}

Describe 'Register-InventoryScheduledTask behaviour' {

    BeforeEach {
        $global:LcRegistered = $null
        $global:LcSetCalledWith = $null
        $global:LcDropRandomDelayOnSet = $false

        # A genuine, unregistered task definition. Using the real type keeps the
        # mocked Set-ScheduledTask -InputObject binding honest.
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile'
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday, Saturday -At '09:00' -RandomDelay (New-TimeSpan -Hours 2)
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet
        $global:LcFakeTask = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

        Mock -CommandName Register-ScheduledTask -MockWith {
            $global:LcRegistered = [pscustomobject]@{
                TaskName    = $TaskName
                TaskPath    = $TaskPath
                Action      = $Action
                Trigger     = $Trigger
                Principal   = $Principal
                Settings    = $Settings
                Description = $Description
                Force       = [bool]$Force
            }
            return $global:LcFakeTask
        }

        Mock -CommandName Get-ScheduledTask -MockWith { $global:LcFakeTask }

        Mock -CommandName Set-ScheduledTask -MockWith {
            $global:LcSetCalledWith = $InputObject
            if ($global:LcDropRandomDelayOnSet) {
                # Simulates a Windows build that silently discards the value.
                $global:LcFakeTask.Triggers[0].RandomDelay = 'PT1H'
            }
            return $global:LcFakeTask
        }

        Mock -CommandName Unregister-ScheduledTask -MockWith { }
    }

    AfterEach {
        # Mock bodies run in their own scope, so the shared fixture has to live in
        # the global scope. Remove it again so it cannot leak between test files.
        Remove-Variable -Name LcRegistered, LcSetCalledWith, LcDropRandomDelayOnSet, LcFakeTask `
            -Scope Global -ErrorAction SilentlyContinue
    }

    It 'defaults to Wednesday and Saturday at 09:00' {
        $result = & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath

        $global:LcRegistered | Should -Not -BeNullOrEmpty
        $global:LcRegistered.Trigger.DaysOfWeek | Should -Be $script:WednesdayAndSaturday
        (Get-LocalStartHour -StartBoundary ([string]$global:LcRegistered.Trigger.StartBoundary)).Hour | Should -Be 9
        (Get-LocalStartHour -StartBoundary ([string]$global:LcRegistered.Trigger.StartBoundary)).Minute | Should -Be 0
        $result.DaysOfWeek | Should -BeExactly 'Wednesday,Saturday'
        $result.StartTime | Should -BeExactly '09:00'
    }

    It 'applies an exact two-hour RandomDelay on the trigger' {
        $result = & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath

        $global:LcRegistered.Trigger.RandomDelay | Should -BeExactly 'PT2H'
        $result.RandomDelay | Should -BeExactly 'PT2H'
    }

    It 'registers with -Force and never unregisters first' {
        $null = & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath

        $global:LcRegistered.Force | Should -BeTrue
        Should -Invoke -CommandName Unregister-ScheduledTask -Times 0 -Exactly
        Should -Invoke -CommandName Register-ScheduledTask -Times 1 -Exactly
    }

    It 're-asserts and verifies RandomDelay after registration' {
        $null = & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath

        Should -Invoke -CommandName Set-ScheduledTask -Times 1 -Exactly
        $global:LcSetCalledWith | Should -Not -BeNullOrEmpty
        $global:LcSetCalledWith.Triggers[0].RandomDelay | Should -BeExactly 'PT2H'
    }

    It 'throws when the platform silently discards RandomDelay' {
        $global:LcDropRandomDelayOnSet = $true

        # A lost RandomDelay means the entire fleet fires at 09:00 sharp. Failing
        # loudly is the only way an operator finds out before that happens.
        { & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath } |
            Should -Throw '*RandomDelay verification failed*'
    }

    It 'runs the task as SYSTEM with the highest run level' {
        $null = & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath

        # The cmdlet normalises the well-known SID to its friendly name, so accept
        # either spelling of the same account.
        $global:LcRegistered.Principal.UserId | Should -BeIn @('S-1-5-18', 'SYSTEM')
        [string]$global:LcRegistered.Principal.LogonType | Should -BeExactly 'ServiceAccount'
        [string]$global:LcRegistered.Principal.RunLevel | Should -BeExactly 'Highest'
    }

    It 'passes the frontend URL and table name through to the collector command line' {
        $null = & $script:ScriptPath `
            -FrontendUrl 'https://host.example/api/inventory' `
            -TableName 'InventoryCustom_CL' `
            -ScriptPath $script:CollectorPath

        $global:LcRegistered.Action.Arguments | Should -BeLike '*-FrontendUrl "https://host.example/api/inventory"*'
        $global:LcRegistered.Action.Arguments | Should -BeLike '*-TableName "InventoryCustom_CL"*'
        $global:LcRegistered.Action.Arguments | Should -BeLike '*-NoProfile*'
    }

    It 'forwards an explicit -Collect list to the collector' {
        $null = & $script:ScriptPath `
            -FrontendUrl 'https://host.example/api/inventory' `
            -ScriptPath $script:CollectorPath `
            -Collect Disk, BitLocker

        $global:LcRegistered.Action.Arguments | Should -BeLike '*-CollectCsv "Disk,BitLocker"*'
    }

    It 'accepts the default local ProgramData spool path and forwards it' {
        # Registering successfully is the positive half of the spool-path guard:
        # the default had to pass validation to reach argument construction.
        $null = & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath

        $global:LcRegistered.Action.Arguments | Should -BeLike '*-SpoolDirectory "C:\ProgramData\LogCollector\Spool"*'
    }

    It 'honours an explicit day and time override' {
        $null = & $script:ScriptPath `
            -FrontendUrl 'https://host.example/api/inventory' `
            -ScriptPath $script:CollectorPath `
            -DaysOfWeek Monday `
            -StartTime '22:30'

        $global:LcRegistered.Trigger.DaysOfWeek | Should -Be 2
        $local = Get-LocalStartHour -StartBoundary ([string]$global:LcRegistered.Trigger.StartBoundary)
        $local.Hour | Should -Be 22
        $local.Minute | Should -Be 30
    }

    It 'does not touch the system when -WhatIf is supplied' {
        & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath $script:CollectorPath -WhatIf

        Should -Invoke -CommandName Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke -CommandName Set-ScheduledTask -Times 0 -Exactly
    }

    It 'fails before registering when the collector script is missing' {
        { & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -ScriptPath 'C:\nope\missing.ps1' } |
            Should -Throw '*Collection script not found*'

        Should -Invoke -CommandName Register-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Register-InventoryScheduledTask parameter validation' {

    It 'rejects a RandomDelay that is not an ISO-8601 duration' {
        foreach ($bad in @('2h', 'PT', 'two hours', '')) {
            { & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -RandomDelay $bad } |
                Should -Throw
        }
    }

    It 'accepts well-formed ISO-8601 durations' {
        foreach ($good in @('PT2H', 'PT30M', 'PT2H30M', 'P1DT2H')) {
            { [System.Xml.XmlConvert]::ToTimeSpan($good) } | Should -Not -Throw
            $good | Should -Match '^P(?=.)(\d+D)?(T(?=.)(\d+H)?(\d+M)?(\d+S)?)?$'
        }
    }

    It 'rejects a malformed start time' {
        foreach ($bad in @('9:00', '25:00', '09-00', 'morning')) {
            { & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -StartTime $bad } |
                Should -Throw
        }
    }

    It 'rejects a day name that is not a weekday' {
        { & $script:ScriptPath -FrontendUrl 'https://host.example/api/inventory' -DaysOfWeek 'Caturday' } |
            Should -Throw
    }

    It 'rejects a UNC or device spool path' {
        # Refused here, with an admin present, rather than registering cleanly and
        # then failing on every endpoint at the scheduled hour.
        foreach ($bad in @('\\server\share\spool', '\\?\C:\spool', '\\.\C:\spool')) {
            { & $script:ScriptPath `
                -FrontendUrl 'https://host.example/api/inventory' `
                -ScriptPath $script:CollectorPath `
                -SpoolDirectory $bad } | Should -Throw '*local fixed drive*'
        }
    }

    It 'rejects a relative spool path' {
        foreach ($bad in @('relative\spool', 'spool')) {
            { & $script:ScriptPath `
                -FrontendUrl 'https://host.example/api/inventory' `
                -ScriptPath $script:CollectorPath `
                -SpoolDirectory $bad } | Should -Throw '*absolute path*'
        }
    }
}
