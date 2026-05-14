Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.ScheduledTask.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11ScheduledTaskOnlineCommand' {
    It 'op=remove recurse=false emits Unregister-ScheduledTaskIfPresent with parent/leaf split' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'; recurse=$false }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds.Count             | Should -Be 1
        $cmds[0].Kind           | Should -Be 'Unregister-ScheduledTaskIfPresent'
        $cmds[0].Args.TaskPath  | Should -Be '\Microsoft\Windows\Application Experience\'
        $cmds[0].Args.TaskName  | Should -Be 'Microsoft Compatibility Appraiser'
    }

    It 'op=remove recurse=true emits Unregister-ScheduledTaskFolder with trailing-slash prefix' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\Customer Experience Improvement Program'; recurse=$true }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds.Count                    | Should -Be 1
        $cmds[0].Kind                  | Should -Be 'Unregister-ScheduledTaskFolder'
        $cmds[0].Args.TaskPathPrefix   | Should -Be '\Microsoft\Windows\Customer Experience Improvement Program\'
    }

    It 'path separator normalization: forward slash becomes backslash' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Chkdsk/Proxy'; recurse=$false }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Args.TaskPath | Should -Be '\Microsoft\Windows\Chkdsk\'
        $cmds[0].Args.TaskName | Should -Be 'Proxy'
    }

    It 'unknown op throws' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='disable'; path='X'; recurse=$false }
        { Get-Tiny11ScheduledTaskOnlineCommand -Action $action } | Should -Throw '*Invalid scheduled-task op*'
    }

    It 'Description present and references path' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\X'; recurse=$true }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Description | Should -Match 'Microsoft\\Windows\\X'
    }

    It 'top-level leaf task: parent is empty so TaskPath is "\"' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='RootlessTask'; recurse=$false }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Args.TaskPath | Should -Be '\'
        $cmds[0].Args.TaskName | Should -Be 'RootlessTask'
    }

    Context 'P8 finding regression guards' {
        # The previous emitter targeted only the XML file at
        # $env:SystemRoot\System32\Tasks\<relPath>, which left the Task
        # Scheduler service's registry-cache entries intact. Microsoft's
        # servicing pipeline can re-register tasks via the registry alone
        # (no XML file written) -- observed for CEIP Consolidator/UsbCeip and
        # WER QueueReporting on a P1d Worker build (2026-05-13 P8 smoke). The
        # cleanup task's "absent (no-op)" no longer catches them. These guards
        # ensure the emitter never regresses back to XML-only deletion.
        It 'does NOT emit Remove-PathIfPresent for leaf removal' {
            $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='X\Y'; recurse=$false }
            $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
            $cmds[0].Kind | Should -Not -Be 'Remove-PathIfPresent'
        }
        It 'does NOT emit Remove-PathIfPresent for folder-recurse removal' {
            $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='X\Y'; recurse=$true }
            $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
            $cmds[0].Kind | Should -Not -Be 'Remove-PathIfPresent'
        }
        It 'leaf removal does NOT include System32\Tasks in any arg value' {
            $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\Foo'; recurse=$false }
            $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
            ($cmds[0].Args.Values -join ' ') | Should -Not -Match 'System32\\Tasks'
        }
    }
}
