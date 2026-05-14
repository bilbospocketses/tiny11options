Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# B10 (regression guard for bdb38d7 + B2): the v1.0.1 P1 smoke surfaced a
# module-scope cascade bug. Worker.psm1 imports Tiny11.Actions.psm1 -Global at
# its top, which cascades through Actions.Registry -> Tiny11.Hives. Before B2,
# Actions.Registry's `Import-Module Tiny11.Hives.psm1 -Force` had no -Global
# flag, so any reload (PostBoot's body, Core's mid-pipeline reload, etc.) would
# demote Hives from the global scope Worker established. Mount-Tiny11AllHives
# then became invisible to Worker's runtime body and the build aborted with
# CommandNotFoundException mid-hives-phase.
#
# Existing Worker tests assert post-boot wiring exists by regex-matching source
# text -- they CANNOT detect this runtime-only scope demotion. This file does
# the full module-load chain in process and asserts Mount-Tiny11AllHives /
# Dismount-Tiny11AllHives stay globally callable after each plausible reload
# trigger.

BeforeAll {
    # Clean slate so the load chain we exercise is a true fresh load. Pester
    # may have pre-loaded Tiny11 modules from earlier suites in the same
    # session; without this reset, "module already loaded" would mask the
    # cascade behavior.
    Get-Module Tiny11.* | Remove-Module -Force -ErrorAction SilentlyContinue

    $script:srcDir = (Resolve-Path (Join-Path $PSScriptRoot '..' 'src')).Path

    # Step 1: load Worker as the real pipeline does. Worker.psm1's body imports
    # Tiny11.Actions.psm1 -Global, which cascades Actions -> Actions.Registry
    # -> Tiny11.Hives. After the B2 fix (Actions.Registry now imports Hives
    # with -Global), the cascade lands at global scope.
    Import-Module (Join-Path $script:srcDir 'Tiny11.Worker.psm1') -Force -Global -DisableNameChecking

    # Step 2: load PostBoot fresh. PostBoot.psm1's body imports Actions with
    # -Global (no -Force, per the bdb38d7 fix). Without -Force this should be a
    # no-op since Actions is already loaded; pre-bdb38d7 the -Force triggered a
    # cascade reload that demoted Hives.
    Import-Module (Join-Path $script:srcDir 'Tiny11.PostBoot.psm1') -Force -Global -DisableNameChecking
}

Describe 'Worker -> Actions -> PostBoot full module-load chain' {
    It 'Mount-Tiny11AllHives is callable after Worker + PostBoot fresh-load' {
        $cmd = Get-Command Mount-Tiny11AllHives -All -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        ($cmd | Where-Object { $_.Source -eq 'Tiny11.Hives' }) | Should -Not -BeNullOrEmpty
        # Sanity check: the cmdlet should be invokable from session scope, not
        # just discoverable. Calling with -WhatIf would still mount; instead
        # assert via & {} to verify the command resolves without error.
        { Get-Command Mount-Tiny11AllHives } | Should -Not -Throw
    }

    It 'Dismount-Tiny11AllHives is callable after Worker + PostBoot fresh-load' {
        # Sibling assertion -- the same cascade demotion would hit both.
        $cmd = Get-Command Dismount-Tiny11AllHives -All -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        ($cmd | Where-Object { $_.Source -eq 'Tiny11.Hives' }) | Should -Not -BeNullOrEmpty
    }

    It 'Tiny11.Hives module is in the session module table' {
        # If the cascade demoted Hives to a non-global scope, Get-Module
        # (which queries session/global scope by default) would return null
        # even though Get-Command -All still finds it via the function table.
        Get-Module Tiny11.Hives | Should -Not -BeNullOrEmpty
    }
}

Describe 'Module-scope cascade after a forced Actions reload (B2 regression guard)' {
    BeforeAll {
        # Simulate the mid-pipeline reload pattern: an `Import-Module
        # Tiny11.Actions.psm1 -Force` while Worker is already loaded. Pre-B2,
        # the cascade through Actions.Registry -> Hives (where Actions.Registry's
        # Hives import lacked -Global) demoted Hives to local scope, leaving
        # Mount-Tiny11AllHives invisible to the global session.
        Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.psm1') -Force -Global -DisableNameChecking
    }

    It 'Mount-Tiny11AllHives survives the forced Actions cascade' {
        $cmd = Get-Command Mount-Tiny11AllHives -All -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        ($cmd | Where-Object { $_.Source -eq 'Tiny11.Hives' }) | Should -Not -BeNullOrEmpty
    }

    It 'Tiny11.Hives module remains in the session module table after the cascade' {
        Get-Module Tiny11.Hives | Should -Not -BeNullOrEmpty
    }

    It 'Tiny11.Actions.Registry.psm1 source still imports Hives with -Global (structural mirror)' {
        # If a future refactor strips -Global from line 2 of Actions.Registry,
        # the dynamic tests above will fire when the cascade demotes Hives.
        # This structural check adds a clearer diagnostic at fail time.
        $source = Get-Content (Join-Path $script:srcDir 'Tiny11.Actions.Registry.psm1') -Raw
        $source | Should -Match '(?ms)Import-Module[^\r\n]*Tiny11\.Hives\.psm1[^\r\n]*-Global'
    }
}
