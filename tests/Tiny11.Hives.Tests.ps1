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

Describe "Get-Tiny11RegValueNames (reg.exe enumeration, no .NET registry provider)" {
    # v1.0.30 dismount-lock fix: pattern-zero (and any offline-hive value enumeration)
    # must read value names via reg.exe, never Get-Item/Get-ItemProperty/Test-Path on the
    # HKLM:\z* provider drive -- the provider caches an in-process hive handle that locks
    # Dismount-WindowsImage -Save. These tests pin the reg.exe-only contract + the parser.
    It "returns only the value names matching the pattern, parsed from reg query output" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = @(
                ''
                'HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                '    SubscribedContent-338388Enabled    REG_DWORD    0x1'
                '    SubscribedContent-338389Enabled    REG_DWORD    0x1'
                '    RotatingLockScreenEnabled    REG_DWORD    0x1'
                '    ContentDeliveryAllowed    REG_DWORD    0x1'
                ''
            ) }
        }
        $names = Get-Tiny11RegValueNames -Key 'HKLM\zNTUSER\K' -NamePattern 'SubscribedContent-*Enabled'
        $names | Should -HaveCount 2
        $names | Should -Contain 'SubscribedContent-338388Enabled'
        $names | Should -Contain 'SubscribedContent-338389Enabled'
        $names | Should -Not -Contain 'RotatingLockScreenEnabled'
    }
    It "returns empty when the key is absent (reg query non-zero exit) -- the no-op case" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith { [pscustomobject]@{ ExitCode = 1; Output = @() } }
        Get-Tiny11RegValueNames -Key 'HKLM\zNTUSER\Missing' -NamePattern '*' | Should -HaveCount 0
    }
    It "parses value names that contain spaces (anchors on the 4-space + REG_<type> column)" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = @('    My Value Name    REG_SZ    hello world') }
        }
        Get-Tiny11RegValueNames -Key 'HKLM\zNTUSER\K' -NamePattern '*' | Should -Be 'My Value Name'
    }
    It "ignores the key-path header line and blank lines" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = @('HKEY_LOCAL_MACHINE\zNTUSER\K', '', '    OnlyValue    REG_DWORD    0x0') }
        }
        Get-Tiny11RegValueNames -Key 'HKLM\zNTUSER\K' -NamePattern '*' | Should -Be 'OnlyValue'
    }
    It "enumerates via reg.exe (Invoke-Tiny11RegExe) and never via the provider" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock -CommandName 'Get-Item'         -ModuleName 'Tiny11.Hives' -MockWith { throw 'provider must not be used on offline hives' }
        Mock -CommandName 'Get-ItemProperty' -ModuleName 'Tiny11.Hives' -MockWith { throw 'provider must not be used on offline hives' }
        { Get-Tiny11RegValueNames -Key 'HKLM\zNTUSER\K' } | Should -Not -Throw
        Should -Invoke -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -Times 1
    }
}

Describe "Test-Tiny11HiveLoaded (reg.exe, no provider)" {
    It "true when reg query exits 0 (hive loaded)" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Test-Tiny11HiveLoaded -Hive 'SOFTWARE' | Should -BeTrue
    }
    It "false when reg query exits non-zero (hive not loaded)" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith { [pscustomobject]@{ ExitCode = 1; Output = @() } }
        Test-Tiny11HiveLoaded -Hive 'SOFTWARE' | Should -BeFalse
    }
    It "queries the z-prefixed mount key via reg.exe" {
        Mock -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -MockWith { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Test-Tiny11HiveLoaded -Hive 'NTUSER' | Out-Null
        Should -Invoke -CommandName 'Invoke-Tiny11RegExe' -ModuleName 'Tiny11.Hives' -ParameterFilter {
            $RegArgs -contains 'query' -and $RegArgs -contains 'HKLM\zNTUSER'
        }
    }
}

Describe "Clear-Tiny11StaleHives" {
    # v1.0.26: a build that fails with hives still loaded strands HKLM\z* and bricks every
    # subsequent build at `reg load` ("Access is denied"). Build-start recovery unloads any
    # stranded z-hive, best-effort, and must never throw (a hive genuinely in use is warned, not fatal).
    # v1.0.30: detection is via Test-Tiny11HiveLoaded (reg.exe), not Test-Path (provider).
    It "unloads only the z-hives currently present, and never throws on a failed unload" {
        # Simulate zSOFTWARE + zSYSTEM stranded-loaded from a prior failed build; others absent.
        Mock -CommandName 'Test-Tiny11HiveLoaded' -ModuleName 'Tiny11.Hives' -MockWith { $Hive -in 'SOFTWARE','SYSTEM' }
        Mock -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -MockWith { if (($RegArgs -join ' ') -like '*zSYSTEM*') { throw 'hive in use' }; 0 }
        { Clear-Tiny11StaleHives } | Should -Not -Throw
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -Times 2 -Exactly -ParameterFilter { $RegArgs -contains 'unload' }
    }
    It "is a no-op when no z-hives are loaded" {
        Mock -CommandName 'Test-Tiny11HiveLoaded' -ModuleName 'Tiny11.Hives' -MockWith { $false }
        Mock -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -MockWith { 0 }
        Clear-Tiny11StaleHives
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -Times 0 -Exactly
    }
    It "detects stale hives via reg.exe (Test-Tiny11HiveLoaded), never the provider" {
        Mock -CommandName 'Test-Tiny11HiveLoaded' -ModuleName 'Tiny11.Hives' -MockWith { $false }
        Mock -CommandName 'Test-Path' -ModuleName 'Tiny11.Hives' -MockWith { throw 'provider must not be used to detect stale offline hives' }
        Mock -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -MockWith { 0 }
        { Clear-Tiny11StaleHives } | Should -Not -Throw
        Should -Invoke -CommandName 'Test-Tiny11HiveLoaded' -ModuleName 'Tiny11.Hives' -Times 5 -Exactly
    }
}
