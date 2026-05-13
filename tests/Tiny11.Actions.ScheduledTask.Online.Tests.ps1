Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.ScheduledTask.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11ScheduledTaskOnlineCommand' {
    It 'op=remove recurse=false emits Remove-PathIfPresent against SystemRoot\System32\Tasks' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'; recurse=$false }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds.Count            | Should -Be 1
        $cmds[0].Kind          | Should -Be 'Remove-PathIfPresent'
        $cmds[0].Args.Path     | Should -Be '$env:SystemRoot\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        $cmds[0].Args.Recurse  | Should -Be $false
    }

    It 'op=remove recurse=true emits Recurse=true (task folder removal)' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\Customer Experience Improvement Program'; recurse=$true }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Args.Recurse | Should -Be $true
    }

    It 'path separator normalization: forward slash becomes backslash' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Chkdsk/Proxy'; recurse=$false }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Args.Path | Should -Be '$env:SystemRoot\System32\Tasks\Microsoft\Windows\Chkdsk\Proxy'
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
}
