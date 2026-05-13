Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    $script:helpers = & (Get-Module Tiny11.PostBoot) { $script:helpersBlock }
    $script:footer  = & (Get-Module Tiny11.PostBoot) { $script:footerBlock }
}

Describe 'PostBoot helpers block' {
    It 'defines every helper function the emitters reference' {
        foreach ($fn in 'Set-RegistryValue','Set-RegistryValueForAllUsers',
                        'Remove-RegistryKey','Remove-RegistryKeyForAllUsers',
                        'Remove-PathIfPresent','Remove-PathWithOwnership',
                        'Remove-AppxByPackagePrefix') {
            $script:helpers | Should -Match "function $fn"
        }
    }
    It 'Set-RegistryValueForAllUsers iterates HKU SIDs + the loaded default-user hive mount (NOT .DEFAULT)' {
        # Regression guard for B4: .DEFAULT is the LOCAL_SERVICE/NETWORK_SERVICE
        # hive, NOT the new-user-profile template. The helpers must target
        # tiny11_default (loaded from C:\Users\Default\NTUSER.DAT by the header).
        $script:helpers | Should -Match 'HKU:'
        $script:helpers | Should -Match '\^S-1-5-21-'
        $script:helpers | Should -Match 'tiny11_default'
        $script:helpers | Should -Not -Match "\$sids \+= '\.DEFAULT'"
    }
    It 'Set-RegistryValue uses "already" vs "CORRECTED" idempotent-log pattern' {
        $script:helpers | Should -Match 'already'
        $script:helpers | Should -Match 'CORRECTED'
        $script:helpers | Should -Match 'correction FAILED'
    }
    It 'Remove-PathWithOwnership invokes takeown.exe and icacls.exe' {
        $script:helpers | Should -Match 'takeown\.exe'
        $script:helpers | Should -Match 'icacls\.exe'
    }
    It 'Remove-AppxByPackagePrefix calls both provisioned + per-user removal' {
        $script:helpers | Should -Match 'Get-AppxProvisionedPackage'
        $script:helpers | Should -Match 'Remove-AppxProvisionedPackage'
        $script:helpers | Should -Match 'Get-AppxPackage -AllUsers'
        $script:helpers | Should -Match 'Remove-AppxPackage -AllUsers'
    }
    It 'is pure ASCII' {
        ($script:helpers.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
    It 'matches the golden fixture (byte-equal)' {
        $goldenPath = Join-Path $PSScriptRoot 'golden' 'tiny11-cleanup-helpers.txt'
        Test-Path $goldenPath | Should -Be $true
        $golden = [System.IO.File]::ReadAllText($goldenPath)
        $script:helpers | Should -Be $golden
    }
}

Describe 'PostBoot footer block' {
    It 'emits the done banner' {
        $script:footer | Should -Match '==== tiny11-cleanup done ===='
    }
}
