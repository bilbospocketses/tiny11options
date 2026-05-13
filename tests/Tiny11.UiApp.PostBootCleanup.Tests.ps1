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
    It 'checkbox is wired in Step 1 (postBootRow follows fastBuildRow)' {
        $fbIndex = $script:appJs.IndexOf("...fastBuildRow")
        $pbIndex = $script:appJs.IndexOf("...postBootRow")
        $fbIndex | Should -BeGreaterThan -1
        $pbIndex | Should -BeGreaterThan $fbIndex
    }
}
