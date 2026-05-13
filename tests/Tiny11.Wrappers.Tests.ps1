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

Describe 'tiny11Coremaker-from-config.ps1 -InstallPostBootCleanup switches' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11Coremaker-from-config.ps1' }
    It 'defines both switches' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'InstallPostBootCleanup'
        $params | Should -Contain 'NoPostBootCleanup'
    }
    It 'threads InstallPostBootCleanup to the pipeline' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup'
        $source | Should -Match '-PostBootCleanupCatalog'
        $source | Should -Match '-PostBootCleanupResolvedSelections'
    }
}

Describe 'tiny11maker-from-config.ps1 -InstallPostBootCleanup switches' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11maker-from-config.ps1' }

    It 'defines both switches' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'InstallPostBootCleanup'
        $params | Should -Contain 'NoPostBootCleanup'
    }

    It 'threads InstallPostBootCleanup through to Invoke-Tiny11BuildPipeline' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup'
        $source | Should -Match '\$InstallPostBootCleanup\s+-and\s+-not\s+\$NoPostBootCleanup'
    }
}

Describe 'tiny11maker.ps1 -InstallPostBootCleanup switches' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11maker.ps1' }

    It 'defines -InstallPostBootCleanup and -NoPostBootCleanup switches' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'InstallPostBootCleanup'
        $params | Should -Contain 'NoPostBootCleanup'
    }

    It 'passes InstallPostBootCleanup through to Invoke-Tiny11BuildPipeline' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup'
    }

    It 'NoPostBootCleanup overrides InstallPostBootCleanup via and -not pattern' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match 'NoPostBootCleanup'
        $source | Should -Match '\$InstallPostBootCleanup\s+-and\s+-not\s+\$NoPostBootCleanup'
    }
}
