Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Autounattend'
Import-Tiny11Module -Name 'Tiny11.Catalog'
Import-Tiny11Module -Name 'Tiny11.Selections'

Describe "Render-Tiny11Autounattend" {
    It "substitutes placeholders" {
        $template = "A={{HIDE_ONLINE_ACCOUNT_SCREENS}};B={{CONFIGURE_CHAT_AUTO_INSTALL}};C={{COMPACT_INSTALL}};D={{IMAGE_INDEX}}"
        $bindings = @{
            HIDE_ONLINE_ACCOUNT_SCREENS='true'
            CONFIGURE_CHAT_AUTO_INSTALL='false'
            COMPACT_INSTALL='true'; IMAGE_INDEX='6'
        }
        Render-Tiny11Autounattend -Template $template -Bindings $bindings | Should -Be "A=true;B=false;C=true;D=6"
    }
    It "throws on unknown placeholder" {
        { Render-Tiny11Autounattend -Template "X={{UNKNOWN}}" -Bindings @{} } | Should -Throw '*UNKNOWN*'
    }
}

Describe "Get-Tiny11AutounattendBindings" {
    # 2026-05-30 re-harden: derive ResolvedSelections from the REAL catalog (via
    # New-/Resolve-Tiny11Selections) instead of a hand-built fixture. The old fixture
    # fabricated 'tweak-compact-install' as present, which masked the original orphan
    # (referenced by the bindings, absent from catalog.json) for v1.0.8..v1.0.24.
    # Comprehensive orphan detection now lives in Tiny11.Catalog.ReferenceIntegrity.Drift.Tests.ps1.
    BeforeAll {
        $script:catalog = Get-Tiny11Catalog -Path "$PSScriptRoot/../catalog/catalog.json"
    }

    It "produces bindings from real catalog-derived selections (no fabricated IDs)" {
        $selections = New-Tiny11Selections    -Catalog $script:catalog
        $resolved   = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $selections
        $b = Get-Tiny11AutounattendBindings -ResolvedSelections $resolved -ImageIndex 6
        $b.Keys | Should -Contain 'HIDE_ONLINE_ACCOUNT_SCREENS'
        $b.Keys | Should -Contain 'CONFIGURE_CHAT_AUTO_INSTALL'
        $b.Keys | Should -Contain 'COMPACT_INSTALL'
        $b['IMAGE_INDEX'] | Should -Be '6'
    }

    It "maps apply/skip states to the correct autounattend values (real catalog)" {
        $selections = New-Tiny11Selections -Catalog $script:catalog -Overrides @{
            'tweak-bypass-nro'        = 'apply'
            'tweak-disable-chat-icon' = 'apply'
            'tweak-compact-install'   = 'skip'
        }
        $resolved = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $selections
        $b = Get-Tiny11AutounattendBindings -ResolvedSelections $resolved -ImageIndex 6
        $b['HIDE_ONLINE_ACCOUNT_SCREENS'] | Should -Be 'true'    # bypass-nro applied
        $b['CONFIGURE_CHAT_AUTO_INSTALL'] | Should -Be 'false'   # chat-icon applied => chat auto-install OFF (inverted)
        $b['COMPACT_INSTALL']             | Should -Be 'false'   # compact skipped
        $b['IMAGE_INDEX']                 | Should -Be '6'
    }

    It "defaults COMPACT_INSTALL to true (Compact OS on by default)" {
        $selections = New-Tiny11Selections    -Catalog $script:catalog
        $resolved   = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $selections
        $b = Get-Tiny11AutounattendBindings -ResolvedSelections $resolved -ImageIndex 6
        $b['COMPACT_INSTALL'] | Should -Be 'true'
    }

    It "defaults a missing item ID to 'apply' (lenient State; A5 throw permanently dropped)" {
        # The v1.0.8 runtime throw on a missing ID was the wrong layer (it crashed user
        # builds at 18%) and was permanently dropped (see binding decision). State is lenient:
        # a missing ID resolves to 'apply'. Orphan detection lives in the ReferenceIntegrity
        # drift test, NOT a runtime throw.
        $b = Get-Tiny11AutounattendBindings -ResolvedSelections @{} -ImageIndex 6
        $b['COMPACT_INSTALL'] | Should -Be 'true'   # missing => apply => Compact on
    }
}

Describe "Get-Tiny11AutounattendTemplate (bundled + embedded, no network fetch)" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }

    It "uses the local (bundled) file when present" {
        $local = Join-Path $script:tmp 'autounattend.template.xml'
        Set-Content -Path $local -Value '<unattend>local</unattend>' -Encoding UTF8
        $r = Get-Tiny11AutounattendTemplate -LocalPath $local
        $r.Source | Should -Be 'Local'
        $r.Content | Should -Be '<unattend>local</unattend>'
    }
    It "falls back to the embedded template when the local file is missing" {
        $r = Get-Tiny11AutounattendTemplate -LocalPath (Join-Path $script:tmp 'nope.xml')
        $r.Source | Should -Be 'Embedded'
        $r.Content | Should -Match '<unattend'
    }
    It "never performs a runtime network fetch (fetch tier retired in v1.0.28)" {
        # Regression guard for the bundled+embedded-only dependency policy: if a
        # future change re-introduces a runtime fetch, this mock fires and the
        # -Times 0 assertion fails.
        Mock -CommandName 'Invoke-RestMethod' -ModuleName 'Tiny11.Autounattend' -MockWith { throw 'network fetch must not happen' }
        $local = Join-Path $script:tmp 'autounattend.template.xml'
        Set-Content -Path $local -Value '<unattend>local</unattend>' -Encoding UTF8
        Get-Tiny11AutounattendTemplate -LocalPath $local | Out-Null
        Get-Tiny11AutounattendTemplate -LocalPath (Join-Path $script:tmp 'missing.xml') | Out-Null
        Should -Invoke -CommandName 'Invoke-RestMethod' -ModuleName 'Tiny11.Autounattend' -Times 0 -Exactly
    }
}
