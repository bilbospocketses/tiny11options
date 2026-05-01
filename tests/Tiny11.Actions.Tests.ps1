Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions'

Describe "Invoke-Tiny11Action" {
    BeforeEach {
        Mock -CommandName 'Invoke-RegistryAction'         -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-FilesystemAction'        -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-ScheduledTaskAction'     -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-ProvisionedAppxAction'   -ModuleName 'Tiny11.Actions' -MockWith { }
    }
    It "routes registry"         { Invoke-Tiny11Action -Action @{ type='registry'; op='set'; hive='SOFTWARE'; key='K'; name='N'; valueType='REG_DWORD'; value='0' } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-RegistryAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes filesystem"       { Invoke-Tiny11Action -Action @{ type='filesystem'; op='remove'; path='X'; recurse=$false } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-FilesystemAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes scheduled-task"   { Invoke-Tiny11Action -Action @{ type='scheduled-task'; op='remove'; path='Y'; recurse=$false } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-ScheduledTaskAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes provisioned-appx" { Invoke-Tiny11Action -Action @{ type='provisioned-appx'; packagePrefix='X' } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-ProvisionedAppxAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "throws on unknown type"  { { Invoke-Tiny11Action -Action @{ type='ghost' } -ScratchDir 'C:\s' } | Should -Throw }
}
