Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.Registry.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11RegistryPatternZeroOnlineCommand (A11-I3, v1.0.3)' {
    It 'NTUSER + REG_DWORD emits Set-RegistryValuePatternToZeroForAllUsers with RelativeKeyPath + NamePattern + Type=DWord' {
        $action = [pscustomobject]@{
            type        = 'registry-pattern-zero'
            hive        = 'NTUSER'
            key         = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            namePattern = 'SubscribedContent-*Enabled'
            valueType   = 'REG_DWORD'
        }
        $cmds = @(Get-Tiny11RegistryPatternZeroOnlineCommand -Action $action)
        $cmds.Count                   | Should -Be 1
        $cmds[0].Kind                 | Should -Be 'Set-RegistryValuePatternToZeroForAllUsers'
        $cmds[0].Args.RelativeKeyPath | Should -Be 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        $cmds[0].Args.NamePattern     | Should -Be 'SubscribedContent-*Enabled'
        $cmds[0].Args.Type            | Should -Be 'DWord'
        $cmds[0].Args.PSObject.Properties.Name -contains 'KeyPath' | Should -Be $false
    }

    It 'REG_QWORD maps Type to QWord' {
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='NTUSER'; key='X'; namePattern='Y*'; valueType='REG_QWORD'
        }
        $cmds = @(Get-Tiny11RegistryPatternZeroOnlineCommand -Action $action)
        $cmds[0].Args.Type | Should -Be 'QWord'
    }

    It 'rejects non-NTUSER hive' {
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='SOFTWARE'; key='X'; namePattern='Y*'; valueType='REG_DWORD'
        }
        { Get-Tiny11RegistryPatternZeroOnlineCommand -Action $action } | Should -Throw '*only supports NTUSER*'
    }

    It 'rejects REG_SZ value type' {
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='NTUSER'; key='X'; namePattern='Y*'; valueType='REG_SZ'
        }
        { Get-Tiny11RegistryPatternZeroOnlineCommand -Action $action } | Should -Throw '*REG_DWORD / REG_QWORD*'
    }

    It 'rejects empty namePattern' {
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='NTUSER'; key='X'; namePattern=''; valueType='REG_DWORD'
        }
        { Get-Tiny11RegistryPatternZeroOnlineCommand -Action $action } | Should -Throw '*non-empty namePattern*'
    }
}

Describe 'Invoke-RegistryPatternZeroAction (A11-I3, v1.0.3)' {
    It 'rejects non-NTUSER hive' {
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='SOFTWARE'; key='X'; namePattern='Y*'; valueType='REG_DWORD'
        }
        { Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\Temp\unused' } | Should -Throw '*only supports NTUSER*'
    }

    It 'rejects REG_SZ value type' {
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='NTUSER'; key='X'; namePattern='Y*'; valueType='REG_SZ'
        }
        { Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\Temp\unused' } | Should -Throw '*REG_DWORD / REG_QWORD*'
    }

    It 'rejects empty namePattern' {
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='NTUSER'; key='X'; namePattern=''; valueType='REG_DWORD'
        }
        { Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\Temp\unused' } | Should -Throw '*non-empty namePattern*'
    }

    It 'silent no-op when target offline-mounted key does not exist' {
        # The mount key resolves to HKLM\zNTUSER (native form) and the PSPath check
        # to HKLM:\zNTUSER\<key>. With no actual offline NTUSER hive mounted in
        # the Pester process, the Test-Path returns false and the function
        # early-returns with no reg.exe call attempted. No throw.
        $action = [pscustomobject]@{
            type='registry-pattern-zero'; hive='NTUSER'
            key='Software\NonExistentKey\ForPesterUnitTest'
            namePattern='Foo*'
            valueType='REG_DWORD'
        }
        { Invoke-RegistryPatternZeroAction -Action $action -ScratchDir 'C:\Temp\unused' } | Should -Not -Throw
    }
}
