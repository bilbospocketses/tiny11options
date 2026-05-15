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

    It "throws on missing item ID instead of defaulting to apply" {
        $resolved = @{}  # No item IDs at all
        { Get-Tiny11AutounattendBindings -ResolvedSelections $resolved -ImageIndex 6 } | Should -Throw "*not found in ResolvedSelections*"
    }
}

Describe "Get-Tiny11AutounattendTemplate (3-tier)" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }

    It "uses the local file when present" {
        $local = Join-Path $script:tmp 'autounattend.template.xml'
        Set-Content -Path $local -Value '<unattend>local</unattend>' -Encoding UTF8
        $r = Get-Tiny11AutounattendTemplate -LocalPath $local
        $r.Source | Should -Be 'Local'
        $r.Content | Should -Be '<unattend>local</unattend>'
    }
    It "falls back to embedded when local missing and network mocked to fail" {
        Mock -CommandName 'Invoke-RestMethod' -ModuleName 'Tiny11.Autounattend' -MockWith { throw "no network" }
        $r = Get-Tiny11AutounattendTemplate -LocalPath (Join-Path $script:tmp 'nope.xml')
        $r.Source | Should -Be 'Embedded'
        $r.Content | Should -Match '<unattend'
    }
    It "refetches from network when cached file is older than 7 days" {
        $local = Join-Path $script:tmp 'stale.xml'
        Set-Content -Path $local -Value '<unattend>stale-cache</unattend>' -Encoding UTF8
        # Backdate the file 10 days to simulate stale cache
        (Get-Item -LiteralPath $local).LastWriteTime = (Get-Date).AddDays(-10)
        # Mock network to return fresh content
        Mock -CommandName 'Invoke-RestMethod' -ModuleName 'Tiny11.Autounattend' -MockWith { '<unattend>fresh-network</unattend>' }
        $r = Get-Tiny11AutounattendTemplate -LocalPath $local
        $r.Source | Should -Be 'Network'
        $r.Content | Should -Be '<unattend>fresh-network</unattend>'
        # Verify the cache was refreshed on disk
        Get-Content -LiteralPath $local -Raw | Should -Match 'fresh-network'
    }
    It "uses cached file when mtime is within 7-day window" {
        $local = Join-Path $script:tmp 'fresh-cache.xml'
        Set-Content -Path $local -Value '<unattend>fresh-cache</unattend>' -Encoding UTF8
        # Backdate to 3 days (within window) -- should still use cache
        (Get-Item -LiteralPath $local).LastWriteTime = (Get-Date).AddDays(-3)
        # Mock network to prove it's NOT called (would change result if it were)
        Mock -CommandName 'Invoke-RestMethod' -ModuleName 'Tiny11.Autounattend' -MockWith { '<unattend>should-not-be-used</unattend>' }
        $r = Get-Tiny11AutounattendTemplate -LocalPath $local
        $r.Source | Should -Be 'Local'
        $r.Content | Should -Be '<unattend>fresh-cache</unattend>'
    }
}
