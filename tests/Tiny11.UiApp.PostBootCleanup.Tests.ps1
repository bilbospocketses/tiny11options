Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:appJs = Get-Content (Join-Path $PSScriptRoot '..' 'ui' 'app.js') -Raw
}

Describe 'Post-boot cleanup UI wiring' {
    It 'state.installPostBootCleanup is initialized to true' {
        $script:appJs | Should -Match 'installPostBootCleanup\s*:\s*true'
    }
    It 'start-build payload includes installPostBootCleanup' {
        $script:appJs | Should -Match 'installPostBootCleanup\s*:\s*state\.installPostBootCleanup'
    }
    It 'app.js renders a checkbox with id install-post-boot-cleanup' {
        $script:appJs | Should -Match "id:\s*'install-post-boot-cleanup'"
        $script:appJs | Should -Match "type:\s*'checkbox'"
    }
    It 'checkbox is wired in Step 1 after fast-build (install-post-boot-cleanup follows fast-build)' {
        # v1.0.10: rewritten after the v1.0.9 Step 1 two-column redesign removed
        # the named ...fastBuildRow / ...postBootRow spread variables. The
        # install-post-boot-cleanup checkbox still ships in Step 1's right card
        # immediately after the fast-build checkbox + hint paragraph; assertion
        # now anchors on the input id literals which are stable across renders.
        $fbIndex = $script:appJs.IndexOf("id: 'fast-build'")
        $pbIndex = $script:appJs.IndexOf("id: 'install-post-boot-cleanup'")
        $fbIndex | Should -BeGreaterThan -1
        $pbIndex | Should -BeGreaterThan $fbIndex
    }
}
