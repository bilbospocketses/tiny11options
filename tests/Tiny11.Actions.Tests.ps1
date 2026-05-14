Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions'

Describe "Invoke-Tiny11Action" {
    BeforeEach {
        Mock -CommandName 'Invoke-RegistryAction'              -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-RegistryPatternZeroAction'   -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-FilesystemAction'             -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-ScheduledTaskAction'          -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-ProvisionedAppxAction'        -ModuleName 'Tiny11.Actions' -MockWith { }
    }
    It "routes registry"              { Invoke-Tiny11Action -Action @{ type='registry'; op='set'; hive='SOFTWARE'; key='K'; name='N'; valueType='REG_DWORD'; value='0' } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-RegistryAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes registry-pattern-zero" { Invoke-Tiny11Action -Action @{ type='registry-pattern-zero'; hive='NTUSER'; key='K'; namePattern='Foo*'; valueType='REG_DWORD' } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-RegistryPatternZeroAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes filesystem"            { Invoke-Tiny11Action -Action @{ type='filesystem'; op='remove'; path='X'; recurse=$false } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-FilesystemAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes scheduled-task"        { Invoke-Tiny11Action -Action @{ type='scheduled-task'; op='remove'; path='Y'; recurse=$false } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-ScheduledTaskAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes provisioned-appx"      { Invoke-Tiny11Action -Action @{ type='provisioned-appx'; packagePrefix='X' } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-ProvisionedAppxAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "throws on unknown type"       { { Invoke-Tiny11Action -Action @{ type='ghost' } -ScratchDir 'C:\s' } | Should -Throw }
}

Describe 'Get-Tiny11ActionOnlineCommand (dispatcher)' {
    It 'routes registry action to Get-Tiny11RegistryOnlineCommand' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Set-RegistryValue'
    }
    It 'routes filesystem action' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='X'; recurse=$false }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Remove-PathIfPresent'
    }
    It 'routes scheduled-task action' {
        # Post-P8-finding: dispatcher routes to Unregister-ScheduledTaskIfPresent
        # for leaf removals and Unregister-ScheduledTaskFolder for recurse=true.
        # Previously emitted Remove-PathIfPresent (XML-only deletion), which left
        # Task Scheduler registry-cache entries intact and tasks re-registered by
        # Windows servicing (CEIP, WER QueueReporting) stayed Ready.
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='X\Y'; recurse=$false }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Unregister-ScheduledTaskIfPresent'
    }
    It 'routes provisioned-appx action' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='X.Y' }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Remove-AppxByPackagePrefix'
    }
    It 'routes registry-pattern-zero action to Get-Tiny11RegistryPatternZeroOnlineCommand' {
        $action = [pscustomobject]@{ type='registry-pattern-zero'; hive='NTUSER'; key='X'; namePattern='Y*'; valueType='REG_DWORD' }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Set-RegistryValuePatternToZeroForAllUsers'
    }
    It 'throws on unknown action type' {
        $action = [pscustomobject]@{ type='quantum-defrag' }
        { Get-Tiny11ActionOnlineCommand -Action $action } | Should -Throw '*Unknown action type*'
    }
}
