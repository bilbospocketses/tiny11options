$script:wrappers = @(
    @{ Name = 'tiny11maker-from-config.ps1';     Path = "$PSScriptRoot/../tiny11maker-from-config.ps1" },
    @{ Name = 'tiny11Coremaker-from-config.ps1'; Path = "$PSScriptRoot/../tiny11Coremaker-from-config.ps1" }
)

Describe "Wrapper-script payload-splat regression guard" {
    # Regression guard for the C5-smoke wrapper-strip bug fixed in commit `2ecef90`.
    # Both wrapper scripts (`tiny11maker-from-config.ps1` and `tiny11Coremaker-from-
    # config.ps1`) MUST forward the entire build-progress payload via splat
    # (`Write-Marker 'build-progress' $p`) instead of reconstructing a per-key
    # whitelist hashtable (`Write-Marker 'build-progress' @{ phase = $p.phase; ... }`).
    #
    # Pre-fix, the wrapper layer silently stripped any payload field it didn't
    # explicitly know about. When mount-state markers added new fields
    # (mountActive, mountDir, sourceDir), the wrappers swallowed them and the
    # auto-cleanup UI behavior broke despite unit tests on both ends passing.
    # This test asserts the structural pattern that prevents that regression.

    It "wrapper <Name> exists" -ForEach $script:wrappers {
        Test-Path $Path | Should -BeTrue
    }

    It "wrapper <Name> uses splat-through pattern: Write-Marker 'build-progress' `$p" -ForEach $script:wrappers {
        $content = Get-Content $Path -Raw
        # Pattern: Write-Marker 'build-progress' $p  (note: $p is a literal $ then p)
        $content | Should -Match "Write-Marker 'build-progress' \`$p\b"
    }

    It "wrapper <Name> does NOT use the field-stripping pattern @{ phase = `$p.phase; ... }" -ForEach $script:wrappers {
        $content = Get-Content $Path -Raw
        # The exact bug pattern from before commit `2ecef90`:
        #   @{ phase = $p.phase; step = $p.step; percent = $p.percent }
        # Match permissive whitespace around tokens. Any occurrence of $p.<known-field>
        # inside a hashtable literal passed to Write-Marker would have suppressed
        # arbitrary new fields. Check each common field-stripping signature.
        $content | Should -Not -Match '@\{\s*phase\s*=\s*\$p\.phase'
        $content | Should -Not -Match '@\{\s*step\s*=\s*\$p\.step'
        $content | Should -Not -Match '@\{\s*percent\s*=\s*\$p\.percent'
    }
}

Describe 'tiny11Coremaker-from-config.ps1 -NoPostBootCleanup switch (A3 W1+W2 post-fix shape)' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11Coremaker-from-config.ps1' }
    It 'defines [switch]$NoPostBootCleanup as the sole cleanup-toggle param' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'NoPostBootCleanup'
        # A3 W1: the [bool]$InstallPostBootCleanup wrapper param is gone --
        # asymmetric with the other [switch]-everywhere params and prone to
        # the relaunch-serialization fragility called out in the audit.
        $params | Should -Not -Contain 'InstallPostBootCleanup'
    }
    It 'derives the pipeline -InstallPostBootCleanup bool from -not $NoPostBootCleanup' {
        $source = Get-Content $script:wrapperPath -Raw
        # The pipeline function still takes -InstallPostBootCleanup [bool];
        # the wrapper now derives the bool from the single switch.
        $source | Should -Match '-InstallPostBootCleanup \(-not \$NoPostBootCleanup\.IsPresent\)'
        $source | Should -Match '-PostBootCleanupCatalog'
        $source | Should -Match '-PostBootCleanupResolvedSelections'
        # Make sure the legacy and-not expression is gone:
        $source | Should -Not -Match '\$InstallPostBootCleanup\s+-and\s+-not\s+\$NoPostBootCleanup'
    }
}

Describe 'tiny11maker-from-config.ps1 -NoPostBootCleanup switch (A3 W1+W2 post-fix shape)' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11maker-from-config.ps1' }

    It 'defines [switch]$NoPostBootCleanup as the sole cleanup-toggle param' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'NoPostBootCleanup'
        $params | Should -Not -Contain 'InstallPostBootCleanup'
    }

    It 'derives the pipeline -InstallPostBootCleanup bool from -not $NoPostBootCleanup' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup \(-not \$NoPostBootCleanup\.IsPresent\)'
        $source | Should -Not -Match '\$InstallPostBootCleanup\s+-and\s+-not\s+\$NoPostBootCleanup'
    }
}

Describe 'tiny11maker.ps1 -NoPostBootCleanup switch (A3 W1+W2+W3 post-fix shape)' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11maker.ps1' }

    It 'defines [switch]$NoPostBootCleanup as the sole cleanup-toggle param' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'NoPostBootCleanup'
        $params | Should -Not -Contain 'InstallPostBootCleanup'
    }

    It 'derives the pipeline -InstallPostBootCleanup bool from -not $NoPostBootCleanup' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup \(-not \$NoPostBootCleanup\.IsPresent\)'
        $source | Should -Not -Match '\$InstallPostBootCleanup\s+-and\s+-not\s+\$NoPostBootCleanup'
    }

    It 'help block documents .PARAMETER NoPostBootCleanup (A3 W3)' {
        # Pre-fix the help block had no .PARAMETER stanza for FastBuild,
        # InstallPostBootCleanup, or NoPostBootCleanup. Get-Help would not
        # show the cleanup opt-out mechanism. Post-A3 we document the switch.
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '(?ms)\.PARAMETER NoPostBootCleanup\s*\r?\n.+post-boot cleanup'
    }
}
