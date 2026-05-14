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
                        'Remove-AppxByPackagePrefix',
                        'Unregister-ScheduledTaskIfPresent','Unregister-ScheduledTaskFolder') {
            $script:helpers | Should -Match "function $fn"
        }
    }
    It 'Unregister-ScheduledTask helpers call Unregister-ScheduledTask -Confirm:$false (P8 regression guard)' {
        # P8 finding: the previous scheduled-task emitter deleted only the XML
        # file at C:\Windows\System32\Tasks\..., leaving the Task Scheduler
        # service's registry cache intact. Tasks Microsoft servicing
        # re-registers via registry-only paths (CEIP Consolidator/UsbCeip, WER
        # QueueReporting observed on 2026-05-13 P1d smoke) stayed Ready. The
        # new helpers MUST call Unregister-ScheduledTask which clears both XML
        # and registry-cache entries.
        $script:helpers | Should -Match 'Unregister-ScheduledTask -TaskPath \$TaskPath -TaskName \$TaskName -Confirm:\$false'
        $script:helpers | Should -Match 'Unregister-ScheduledTask -TaskPath \$t\.TaskPath -TaskName \$t\.TaskName -Confirm:\$false'
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
    It 'HKU SID list uses Select-Object -ExpandProperty (not .PSChildName) so empty pipelines stay empty' {
        # Regression guard for the smoke-surfaced bug: @((empty | Where).PSChildName)
        # returns @($null) -- a single-null-element array -- and iterating that
        # produces one bogus HKU:\\<path> write per fan-out call. -ExpandProperty
        # preserves empty-when-empty semantics. Pre-fix log lines looked like:
        #   "HKU:\\Software\... key-create FAILED: The parameter is incorrect."
        $script:helpers | Should -Match 'Select-Object -ExpandProperty PSChildName'
        $script:helpers | Should -Not -Match '\}\)\.PSChildName\)'
    }
    It 'HKU SID filter excludes _Classes suffix (per-user hive only, not user HKCR)' {
        # Regression guard for Finding 4 (smoke P2): the bare '^S-1-5-21-' regex
        # matches both 'S-1-5-21-...-1001' (real user) AND 'S-1-5-21-...-1001_Classes'
        # (user's HKEY_CLASSES_ROOT portion). Writing policy keys like
        # InputPersonalization / ContentDeliveryManager to _Classes pollutes that
        # hive with COM-namespace-irrelevant orphan keys. End-anchored regex
        # '^S-1-5-21-\d+-\d+-\d+-\d+$' rejects the _Classes suffix.
        $script:helpers | Should -Match '\^S-1-5-21-\\d\+-\\d\+-\\d\+-\\d\+\$'
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
    It 'Remove-AppxByPackagePrefix explicitly imports the Appx module (B8 regression guard)' {
        # B8: SYSTEM-context PS 5.1 sessions (the scheduled-task context) may
        # not auto-discover the Appx module on debloated images, causing every
        # Get/Remove-AppxPackage call to throw "not recognized". An explicit
        # idempotent Import-Module Appx -ErrorAction SilentlyContinue at the
        # top of the function makes the dependency explicit and survives even
        # the worst auto-discovery regression.
        $fnPattern = '(?ms)function Remove-AppxByPackagePrefix.*?(?=\nfunction |\z)'
        $fnBody = ($script:helpers | Select-String -Pattern $fnPattern -AllMatches).Matches[0].Value
        $fnBody | Should -Match 'Import-Module Appx -ErrorAction SilentlyContinue'
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
