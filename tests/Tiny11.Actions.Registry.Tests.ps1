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
