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

Describe "Clear-Tiny11StaleHives" {
    # v1.0.26: a build that fails with hives still loaded strands HKLM\z* and bricks every
    # subsequent build at `reg load` ("Access is denied"). Build-start recovery unloads any
    # stranded z-hive, best-effort, and must never throw (a hive genuinely in use is warned, not fatal).
    It "unloads only the z-hives currently present, and never throws on a failed unload" {
        # Simulate zSOFTWARE + zSYSTEM stranded-loaded from a prior failed build; others absent.
        Mock -CommandName 'Test-Path' -ModuleName 'Tiny11.Hives' -MockWith { $LiteralPath -in 'HKLM:\zSOFTWARE','HKLM:\zSYSTEM' }
        Mock -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -MockWith { if (($RegArgs -join ' ') -like '*zSYSTEM*') { throw 'hive in use' }; 0 }
        { Clear-Tiny11StaleHives } | Should -Not -Throw
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -Times 2 -Exactly -ParameterFilter { $RegArgs -contains 'unload' }
    }
    It "is a no-op when no z-hives are loaded" {
        Mock -CommandName 'Test-Path' -ModuleName 'Tiny11.Hives' -MockWith { $false }
        Mock -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -MockWith { 0 }
        Clear-Tiny11StaleHives
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -Times 0 -Exactly
    }
}
