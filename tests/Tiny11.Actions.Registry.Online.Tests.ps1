Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.Registry.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11RegistryOnlineCommand' {
    It 'SOFTWARE op=set REG_DWORD emits Set-RegistryValue with HKLM:\Software prefix and int value' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='Policies\Microsoft\Windows\WindowsCopilot'; op='set'; name='TurnOffWindowsCopilot'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds.Count            | Should -Be 1
        $cmds[0].Kind          | Should -Be 'Set-RegistryValue'
        $cmds[0].Args.KeyPath  | Should -Be 'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot'
        $cmds[0].Args.Name     | Should -Be 'TurnOffWindowsCopilot'
        $cmds[0].Args.Type     | Should -Be 'DWord'
        $cmds[0].Args.Value    | Should -Be 1
        $cmds[0].Args.Value.GetType().Name | Should -Be 'Int32'
    }

    It 'SOFTWARE op=remove emits Remove-RegistryKey' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'; op='remove' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds.Count           | Should -Be 1
        $cmds[0].Kind         | Should -Be 'Remove-RegistryKey'
        $cmds[0].Args.KeyPath | Should -Be 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    }

    It 'SYSTEM op=set emits HKLM:\SYSTEM prefix' {
        $action = [pscustomobject]@{ type='registry'; hive='SYSTEM'; key='Setup\LabConfig'; op='set'; name='BypassTPMCheck'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.KeyPath | Should -Be 'HKLM:\SYSTEM\Setup\LabConfig'
    }

    It 'DEFAULT op=set emits HKU:\.DEFAULT prefix' {
        $action = [pscustomobject]@{ type='registry'; hive='DEFAULT'; key='Control Panel\UnsupportedHardwareNotificationCache'; op='set'; name='SV1'; valueType='REG_DWORD'; value='0' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.KeyPath | Should -Be 'HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache'
    }

    It 'NTUSER op=set emits Set-RegistryValueForAllUsers with RelativeKeyPath (no HKU prefix)' {
        $action = [pscustomobject]@{ type='registry'; hive='NTUSER'; key='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; op='set'; name='Enabled'; valueType='REG_DWORD'; value='0' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds.Count                    | Should -Be 1
        $cmds[0].Kind                  | Should -Be 'Set-RegistryValueForAllUsers'
        $cmds[0].Args.RelativeKeyPath  | Should -Be 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        $cmds[0].Args.PSObject.Properties.Name -contains 'KeyPath' | Should -Be $false
    }

    It 'NTUSER op=remove emits Remove-RegistryKeyForAllUsers' {
        $action = [pscustomobject]@{ type='registry'; hive='NTUSER'; key='Software\Microsoft\Foo'; op='remove' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Kind                 | Should -Be 'Remove-RegistryKeyForAllUsers'
        $cmds[0].Args.RelativeKeyPath | Should -Be 'Software\Microsoft\Foo'
    }

    It 'REG_SZ value stays as string' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_SZ'; value='hello' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.Type  | Should -Be 'String'
        $cmds[0].Args.Value | Should -Be 'hello'
        $cmds[0].Args.Value.GetType().Name | Should -Be 'String'
    }

    It 'REG_QWORD value parses to Int64' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_QWORD'; value='4294967296' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.Type  | Should -Be 'QWord'
        $cmds[0].Args.Value | Should -Be 4294967296
        $cmds[0].Args.Value.GetType().Name | Should -Be 'Int64'
    }

    It 'COMPONENTS hive throws' {
        $action = [pscustomobject]@{ type='registry'; hive='COMPONENTS'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='0' }
        { Get-Tiny11RegistryOnlineCommand -Action $action } | Should -Throw '*COMPONENTS hive cleanup not supported online*'
    }

    It 'unknown op throws' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='nuke'; name='Y'; valueType='REG_DWORD'; value='0' }
        { Get-Tiny11RegistryOnlineCommand -Action $action } | Should -Throw '*Invalid registry op*'
    }

    It 'Description present and non-empty' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Description | Should -Not -BeNullOrEmpty
    }
}
