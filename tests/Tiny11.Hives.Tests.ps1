Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Hives'

Describe "Resolve-Tiny11HivePath" {
    It "maps SOFTWARE to scratchdir/Windows/System32/config/SOFTWARE" {
        Resolve-Tiny11HivePath -Hive 'SOFTWARE' -ScratchDir 'C:\scratch' | Should -Be 'C:\scratch\Windows\System32\config\SOFTWARE'
    }
    It "maps NTUSER to Users/Default/ntuser.dat" {
        Resolve-Tiny11HivePath -Hive 'NTUSER' -ScratchDir 'C:\scratch' | Should -Be 'C:\scratch\Users\Default\ntuser.dat'
    }
    It "maps DEFAULT to config/default" {
        Resolve-Tiny11HivePath -Hive 'DEFAULT' -ScratchDir 'C:\scratch' | Should -Be 'C:\scratch\Windows\System32\config\default'
    }
    It "maps COMPONENTS and SYSTEM" {
        (Resolve-Tiny11HivePath -Hive 'COMPONENTS' -ScratchDir 'C:\s').EndsWith('config\COMPONENTS') | Should -BeTrue
        (Resolve-Tiny11HivePath -Hive 'SYSTEM' -ScratchDir 'C:\s').EndsWith('config\SYSTEM') | Should -BeTrue
    }
    It "throws on unknown hive with helpful message" {
        { Resolve-Tiny11HivePath -Hive 'BOGUS' -ScratchDir 'C:\s' } | Should -Throw -ExpectedMessage '*Unknown hive*'
    }
}

Describe "Mount-/Dismount-Tiny11Hive" {
    BeforeEach { Mock -CommandName 'Invoke-RegCommand' -MockWith { 0 } -ModuleName 'Tiny11.Hives' }
    It "calls reg load with HKLM\\zSOFTWARE and the resolved path" {
        Mount-Tiny11Hive -Hive 'SOFTWARE' -ScratchDir 'C:\scratch'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -ParameterFilter {
            $RegArgs -contains 'load' -and $RegArgs -contains 'HKLM\zSOFTWARE' -and ($RegArgs -join ' ') -like '*Windows\System32\config\SOFTWARE*'
        }
    }
    It "calls reg unload with HKLM\\zNTUSER" {
        Dismount-Tiny11Hive -Hive 'NTUSER'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -ParameterFilter {
            $RegArgs -contains 'unload' -and $RegArgs -contains 'HKLM\zNTUSER'
        }
    }
}
