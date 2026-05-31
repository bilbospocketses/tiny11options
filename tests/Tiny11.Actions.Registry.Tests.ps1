Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Hives'
Import-Tiny11Module -Name 'Tiny11.Actions.Registry'

Describe "Invoke-RegistryAction" {
    BeforeEach { Mock -CommandName 'Invoke-RegCommand' -MockWith { 0 } -ModuleName 'Tiny11.Actions.Registry' }
    It "issues 'reg add' for op=set with all fields" {
        $action = @{
            type='registry'; op='set'; hive='SOFTWARE'
            key='Policies\Microsoft\Windows\DataCollection'
            name='AllowTelemetry'; valueType='REG_DWORD'; value='0'
        }
        Invoke-RegistryAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            $RegArgs[0] -eq 'add' -and
            $RegArgs[1] -eq 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' -and
            $RegArgs -contains '/v' -and $RegArgs -contains 'AllowTelemetry' -and
            $RegArgs -contains '/t' -and $RegArgs -contains 'REG_DWORD' -and
            $RegArgs -contains '/d' -and $RegArgs -contains '0' -and
            $RegArgs -contains '/f'
        }
    }
    It "issues 'reg delete' for op=remove" {
        $action = @{ type='registry'; op='remove'; hive='SOFTWARE'; key='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' }
        Invoke-RegistryAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            $RegArgs[0] -eq 'delete' -and
            $RegArgs[1] -eq 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' -and
            $RegArgs -contains '/f'
        }
    }
    It "throws on invalid op" {
        $action = @{ type='registry'; op='nope'; hive='SOFTWARE'; key='X' }
        { Invoke-RegistryAction -Action $action -ScratchDir 'C:\s' } | Should -Throw "*op*"
    }
    It "escapes embedded double-quotes in REG_SZ values for PS 5.1 reg.exe quoting" {
        # Regression guard for Finding 2 (ConfigureStartPins quote-strip): Windows
        # PowerShell 5.1's legacy native-command argument passing does NOT escape
        # embedded " characters when invoking reg.exe via the splat operator.
        # Without pre-escaping, '{"pinnedList": [{}]}' lands as '{pinnedList: [{}]}'
        # in the registry. Verified empirically against the offline SOFTWARE hive
        # of a fresh build before this fix.
        $action = @{
            type='registry'; op='set'; hive='SOFTWARE'
            key='Microsoft\PolicyManager\current\device\Start'
            name='ConfigureStartPins'; valueType='REG_SZ'
            value='{"pinnedList": [{}]}'
        }
        Invoke-RegistryAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            # The value at the /d position must contain BACKSLASH-DQUOTE pairs, not bare quotes.
            $dIndex = [Array]::IndexOf($RegArgs, '/d')
            $dIndex -ge 0 -and $RegArgs[$dIndex + 1] -eq '{\"pinnedList\": [{}]}'
        }
    }
    It "leaves quote-free values unchanged (no spurious escaping)" {
        $action = @{
            type='registry'; op='set'; hive='SOFTWARE'
            key='Policies\Microsoft\Windows\DataCollection'
            name='AllowTelemetry'; valueType='REG_DWORD'; value='0'
        }
        Invoke-RegistryAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            $dIndex = [Array]::IndexOf($RegArgs, '/d')
            $dIndex -ge 0 -and $RegArgs[$dIndex + 1] -eq '0'
        }
    }
}

Describe "Invoke-RegistryPatternZeroAction (offline, reg.exe-only -- no .NET registry provider)" {
    # v1.0.30 dismount-lock fix. Through v1.0.29 this read value names via
    # Get-Item "HKLM:\z<hive>\..." (the .NET provider), which cached an in-process hive
    # handle that survived `reg unload` and locked Dismount-WindowsImage -Save with
    # "being used by another process". It now enumerates via reg.exe (Get-Tiny11RegValueNames)
    # and writes matches via reg.exe (Invoke-RegCommand). These tests pin that contract.
    BeforeEach { Mock -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -MockWith { 0 } }

    It "writes 0 to each matching value name via 'reg add' under the z-mounted key" {
        Mock -CommandName 'Get-Tiny11RegValueNames' -ModuleName 'Tiny11.Actions.Registry' -MockWith {
            @('SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled')
        }
        $action = @{ type='registry-pattern-zero'; hive='NTUSER'; key='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; namePattern='SubscribedContent-*Enabled'; valueType='REG_DWORD' }
        Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -Times 2 -Exactly
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            $RegArgs[0] -eq 'add' -and
            $RegArgs[1] -eq 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -and
            $RegArgs -contains '/v' -and
            $RegArgs -contains '/t' -and $RegArgs -contains 'REG_DWORD' -and
            $RegArgs -contains '/d' -and $RegArgs -contains '0' -and $RegArgs -contains '/f'
        }
    }
    It "is a no-op when no value names match (absent key or no matches)" {
        Mock -CommandName 'Get-Tiny11RegValueNames' -ModuleName 'Tiny11.Actions.Registry' -MockWith { @() }
        $action = @{ type='registry-pattern-zero'; hive='NTUSER'; key='K'; namePattern='SubscribedContent-*Enabled'; valueType='REG_DWORD' }
        Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -Times 0 -Exactly
    }
    It "passes the native z-key and the namePattern through to the reg.exe enumerator" {
        Mock -CommandName 'Get-Tiny11RegValueNames' -ModuleName 'Tiny11.Actions.Registry' -MockWith { @() }
        $action = @{ type='registry-pattern-zero'; hive='NTUSER'; key='Software\X'; namePattern='SubscribedContent-*Enabled'; valueType='REG_DWORD' }
        Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Get-Tiny11RegValueNames' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            $Key -eq 'HKLM\zNTUSER\Software\X' -and $NamePattern -eq 'SubscribedContent-*Enabled'
        }
    }
    It "enumerates via reg.exe (Get-Tiny11RegValueNames), never the .NET provider" {
        Mock -CommandName 'Get-Tiny11RegValueNames' -ModuleName 'Tiny11.Actions.Registry' -MockWith { @() }
        Mock -CommandName 'Get-Item'  -ModuleName 'Tiny11.Actions.Registry' -MockWith { throw 'provider must not be used on offline hives' }
        Mock -CommandName 'Test-Path' -ModuleName 'Tiny11.Actions.Registry' -MockWith { throw 'provider must not be used on offline hives' }
        $action = @{ type='registry-pattern-zero'; hive='NTUSER'; key='K'; namePattern='X*'; valueType='REG_DWORD' }
        { Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\s' } | Should -Not -Throw
        Should -Invoke -CommandName 'Get-Tiny11RegValueNames' -ModuleName 'Tiny11.Actions.Registry' -Times 1
    }
    It "still validates: throws on a non-NTUSER hive" {
        $action = @{ type='registry-pattern-zero'; hive='SOFTWARE'; key='K'; namePattern='X*'; valueType='REG_DWORD' }
        { Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\s' } | Should -Throw '*only supports NTUSER*'
    }
    It "still validates: throws on a non-DWORD/QWORD value type" {
        $action = @{ type='registry-pattern-zero'; hive='NTUSER'; key='K'; namePattern='X*'; valueType='REG_SZ' }
        { Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\s' } | Should -Throw '*REG_DWORD / REG_QWORD*'
    }
}
