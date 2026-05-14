Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.psm1')  -Force -DisableNameChecking
    Import-Module (Join-Path $script:srcDir 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:srcDir 'Tiny11.Selections.psm1') -Force -DisableNameChecking

    function New-TestCatalog {
        param([AllowEmptyCollection()][object[]] $Items = @())
        [pscustomobject]@{
            Version    = 1
            Categories = @([pscustomobject]@{ id='store-apps'; displayName='Store apps'; description='x' })
            Items      = @($Items)
            Path       = 'test://catalog'
        }
    }

    function New-AllApplySelections {
        param([Parameter(Mandatory)] $Catalog)
        $h = @{}
        foreach ($it in $Catalog.Items) {
            $h[$it.id] = [pscustomobject]@{ ItemId=$it.id; UserState='apply'; EffectiveState='apply'; Locked=$false; LockedBy=@() }
        }
        $h
    }
}

Describe 'New-Tiny11PostBootCleanupScript' {

    It 'produces a script with header, helpers, and footer when no items apply' {
        $catalog = New-TestCatalog -Items @()
        $script  = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections @{}
        $script | Should -Match '==== tiny11-cleanup triggered ===='
        $script | Should -Match 'function Set-RegistryValue'
        $script | Should -Match 'function Remove-AppxByPackagePrefix'
        $script | Should -Match '==== tiny11-cleanup done ===='
        $script | Should -Not -Match '# --- Item:'
    }

    It 'iterates catalog items in order' {
        $items = @(
            [pscustomobject]@{ id='item-a'; category='store-apps'; displayName='Alpha'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='A.Pkg' }) }
            [pscustomobject]@{ id='item-b'; category='store-apps'; displayName='Bravo'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='B.Pkg' }) }
            [pscustomobject]@{ id='item-c'; category='store-apps'; displayName='Charlie'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='C.Pkg' }) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved

        $indexA = $script.IndexOf('# --- Item: Alpha (item-a) ---')
        $indexB = $script.IndexOf('# --- Item: Bravo (item-b) ---')
        $indexC = $script.IndexOf('# --- Item: Charlie (item-c) ---')
        $indexA | Should -BeGreaterThan -1
        $indexB | Should -BeGreaterThan $indexA
        $indexC | Should -BeGreaterThan $indexB
    }

    It 'skips items where EffectiveState != apply' {
        $items = @(
            [pscustomobject]@{ id='item-keep';  category='store-apps'; displayName='Keep';   description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Keep.Pkg' }) }
            [pscustomobject]@{ id='item-skip';  category='store-apps'; displayName='Skip';   description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Skip.Pkg' }) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = @{
            'item-keep' = [pscustomobject]@{ ItemId='item-keep'; UserState='apply'; EffectiveState='apply'; Locked=$false; LockedBy=@() }
            'item-skip' = [pscustomobject]@{ ItemId='item-skip'; UserState='skip';  EffectiveState='skip';  Locked=$false; LockedBy=@() }
        }
        $script = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match '# --- Item: Keep \(item-keep\) ---'
        $script | Should -Not -Match '# --- Item: Skip \(item-skip\) ---'
        $script | Should -Not -Match 'Skip\.Pkg'
    }

    It 'emits multi-action items with one helper call per action in declared order' {
        $items = @(
            [pscustomobject]@{ id='multi'; category='store-apps'; displayName='Multi'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='filesystem'; op='remove'; path='Program Files\Foo'; recurse=$true }
                [pscustomobject]@{ type='registry';   hive='SOFTWARE'; key='Foo\Bar'; op='remove' }
            ) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved

        $script | Should -Match 'Remove-PathIfPresent -Path .*Program Files\\Foo.* -Recurse \$true'
        $script | Should -Match 'Remove-RegistryKey -KeyPath .*HKLM:\\Software\\Foo\\Bar.*'
        # Locate the body section (post-helpers) by finding the item header, then check ordering there.
        $bodyStart = $script.IndexOf('# --- Item: Multi (multi) ---')
        $bodyStart | Should -BeGreaterThan -1
        $body = $script.Substring($bodyStart)
        $idxFs  = $body.IndexOf('Remove-PathIfPresent -Path')
        $idxReg = $body.IndexOf('Remove-RegistryKey -KeyPath')
        $idxFs | Should -BeLessThan $idxReg
    }

    It 'is deterministic - identical inputs yield identical output' {
        $items = @(
            [pscustomobject]@{ id='det'; category='store-apps'; displayName='Det'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Det.Pkg' }) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $a = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $b = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $a | Should -Be $b
    }
}

Describe 'New-Tiny11PostBootCleanupScript -- targeted snippets' {

    It 'NTUSER fan-out renders as Set-RegistryValueForAllUsers with RelativeKeyPath (no HKU prefix)' {
        $items = @(
            [pscustomobject]@{ id='ntuser'; category='store-apps'; displayName='NTU'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='NTUSER'; key='Software\Microsoft\X'; op='set'; name='Y'; valueType='REG_DWORD'; value='0' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $body     = $script.Substring($script.IndexOf('# --- Item: NTU (ntuser) ---'))
        $body | Should -Match "Set-RegistryValueForAllUsers -RelativeKeyPath 'Software\\Microsoft\\X' -Name 'Y' -Type 'DWord' -Value 0"
    }

    It 'takeown-and-remove with path containing spaces emits DOUBLE-quoted $env:SystemDrive so PS expands at runtime' {
        # Regression guard for B1: single-quoted '$env:SystemDrive\...' is a literal
        # path PS cannot resolve. The emitter MUST produce double quotes so the
        # env-var expands when the cleanup script runs on the target machine.
        $items = @(
            [pscustomobject]@{ id='to'; category='store-apps'; displayName='TO'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='filesystem'; op='takeown-and-remove'; path='Windows\System32\Microsoft-Edge-Webview'; recurse=$true }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match 'Remove-PathWithOwnership -Path "\$env:SystemDrive\\Windows\\System32\\Microsoft-Edge-Webview" -Recurse \$true'
    }

    It 'REG_DWORD emits unquoted int Value' {
        $items = @(
            [pscustomobject]@{ id='dw'; category='store-apps'; displayName='DW'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='7' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Set-RegistryValue -KeyPath 'HKLM:\\Software\\X' -Name 'Y' -Type 'DWord' -Value 7"
    }

    It 'REG_SZ emits quoted string Value' {
        $items = @(
            [pscustomobject]@{ id='sz'; category='store-apps'; displayName='SZ'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_SZ'; value='hello world' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Set-RegistryValue -KeyPath 'HKLM:\\Software\\X' -Name 'Y' -Type 'String' -Value 'hello world'"
    }

    It 'REG_QWORD emits unquoted long Value' {
        $items = @(
            [pscustomobject]@{ id='qw'; category='store-apps'; displayName='QW'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_QWORD'; value='4294967296' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Set-RegistryValue -KeyPath 'HKLM:\\Software\\X' -Name 'Y' -Type 'QWord' -Value 4294967296"
    }

    It 'generated script is pure ASCII (no smart quotes / em-dashes anywhere)' {
        $items = @(
            [pscustomobject]@{ id='x'; category='store-apps'; displayName='X'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='X.Y' }) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        ($script.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }

    It 'unknown action type throws with item ID and action index context (A5 W2 regression guard)' {
        # Pre-fix: Get-Tiny11ActionOnlineCommand throws bare, generator dies,
        # caller writes a partial/null script with no clue which item caused it.
        # Post-fix: generator catches, rethrows with the item id + action index.
        $items = @(
            [pscustomobject]@{ id='item-good';    category='store-apps'; displayName='Good';    description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Good.Pkg' }) }
            [pscustomobject]@{ id='item-broken';  category='store-apps'; displayName='Broken';  description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='provisioned-appx'; packagePrefix='OK.First' }
                [pscustomobject]@{ type='bogus-action-type-that-does-not-exist'; foo='bar' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        { New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved } | Should -Throw -ExpectedMessage "*item 'item-broken'*action index 1*bogus-action-type-that-does-not-exist*"
    }
}
