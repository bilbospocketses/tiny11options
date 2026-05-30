Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Autounattend'

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
    It "maps tweak-bypass-nro=apply to HIDE_ONLINE_ACCOUNT_SCREENS=true" {
        $resolved = @{
            'tweak-bypass-nro'        = [pscustomobject]@{ EffectiveState='apply' }
            'tweak-disable-chat-icon' = [pscustomobject]@{ EffectiveState='skip' }
            'tweak-compact-install'   = [pscustomobject]@{ EffectiveState='apply' }
        }
        $b = Get-Tiny11AutounattendBindings -ResolvedSelections $resolved -ImageIndex 6
        $b['HIDE_ONLINE_ACCOUNT_SCREENS'] | Should -Be 'true'
        $b['CONFIGURE_CHAT_AUTO_INSTALL'] | Should -Be 'true'
        $b['COMPACT_INSTALL']             | Should -Be 'true'
        $b['IMAGE_INDEX']                 | Should -Be '6'
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
