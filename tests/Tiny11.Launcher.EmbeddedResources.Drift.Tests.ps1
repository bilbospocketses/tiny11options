# Catches files that exist on disk in tracked locations but aren't listed
# in launcher/tiny11options.Launcher.csproj's <EmbeddedResource> entries.
#
# Most likely failure mode: someone adds a new src/Tiny11.*.psm1 module
# (e.g. for a new action handler) and forgets to add the corresponding
# csproj line. The file ships in the repo but doesn't end up embedded
# in the launcher .exe, so the launcher fails at runtime when it tries
# to extract the module to %LOCALAPPDATA%\tiny11options\resources-cache.
#
# ui/** and catalog/** are covered by glob includes (..\ui\**\* and
# ..\catalog\**\*), so files added under those trees auto-pick-up. This
# test doesn't try to validate the globs — only the explicitly-listed
# entries that require manual maintenance.
#
# Intentional exclusions are captured in $intentionallyNotEmbedded with
# inline rationale. Adding to that set requires a comment justifying why
# the file lives in tracked locations but doesn't ship in the launcher.

Describe 'launcher/tiny11options.Launcher.csproj <EmbeddedResource> drift' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $csprojPath = Join-Path $script:repoRoot 'launcher\tiny11options.Launcher.csproj'
        [xml]$csproj = Get-Content -Raw -Path $csprojPath

        # Flatten across all ItemGroup blocks. SelectNodes with descendant XPath
        # catches every EmbeddedResource regardless of which ItemGroup it lives in.
        # Normalize forward slashes to backslashes — MSBuild accepts both on
        # Windows; tests should treat them as equivalent.
        $script:embeddedIncludes = @(
            $csproj.SelectNodes('//EmbeddedResource[@Include]') |
                ForEach-Object { ($_.GetAttribute('Include')) -replace '/', '\' }
        )

        # Files that exist in tracked locations but are intentionally NOT embedded
        # in the launcher .exe. Each entry must have a rationale comment. The test
        # also asserts each entry still exists on disk — catches stale exclusions.
        $script:intentionallyNotEmbedded = @(
            # Legacy v0.1.0 PS modules retained as canonical reference per the
            # 2026-05-08 binding decision (Phase 5 Tasks 27/28 CANCELLED). The
            # C# launcher implements its own bridge + WebView2 host, replacing
            # these modules at runtime. Embedding them would bloat the .exe for
            # no benefit. If we ever port a feature back into PS-only mode, the
            # exclusion comes off and the csproj line gets added.
            'src\Tiny11.Bridge.psm1'
            'src\Tiny11.WebView2.psm1'

            # Upstream ntdevlabs/tiny11builder Core-variant builder. More
            # aggressive removals than tiny11maker.ps1; never ported into our
            # catalog/UI, never consumed at runtime by the launcher. Tracked
            # in our fork as upstream-inherited but dormant. If we ever add a
            # "Core" build mode, the exclusion comes off and the csproj line
            # gets added — until then, no point bloating the launcher .exe.
            'tiny11Coremaker.ps1'
        )
    }

    It 'every Tiny11.*.psm1 in src/ is embedded (or explicitly excluded)' {
        $srcModules = @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src') -Filter 'Tiny11.*.psm1' |
            ForEach-Object { $_.Name })

        # Sanity: src/ should have modules. If this assert fails, the test path
        # resolution is wrong and the foreach below would pass vacuously.
        $srcModules.Count | Should -BeGreaterThan 0

        foreach ($module in $srcModules) {
            $relPath = "src\$module"
            if ($script:intentionallyNotEmbedded -contains $relPath) { continue }

            $expectedInclude = "..\$relPath"
            $script:embeddedIncludes | Should -Contain $expectedInclude `
                -Because "$relPath exists in src/ but isn't listed as <EmbeddedResource Include=`"$expectedInclude`" /> in tiny11options.Launcher.csproj. If this is intentional, add it to `$intentionallyNotEmbedded with a rationale comment."
        }
    }

    It 'every tiny11*.ps1 wrapper at repo root is embedded (or explicitly excluded)' {
        $wrappers = @(Get-ChildItem -Path $script:repoRoot -Filter 'tiny11*.ps1' |
            ForEach-Object { $_.Name })

        # Sanity: at least the orchestrator must be present.
        $wrappers.Count | Should -BeGreaterThan 0

        foreach ($wrapper in $wrappers) {
            if ($script:intentionallyNotEmbedded -contains $wrapper) { continue }

            $expectedInclude = "..\$wrapper"
            $script:embeddedIncludes | Should -Contain $expectedInclude `
                -Because "$wrapper exists at repo root but isn't listed as <EmbeddedResource Include=`"$expectedInclude`" /> in tiny11options.Launcher.csproj. If this is intentional, add it to `$intentionallyNotEmbedded with a rationale comment."
        }
    }

    It 'autounattend.template.xml is embedded' {
        $script:embeddedIncludes | Should -Contain '..\autounattend.template.xml' `
            -Because 'autounattend.template.xml is required by Get-Tiny11AutounattendTemplate 3-tier acquisition (local file -> network fetch -> embedded fallback). Without it the launcher misses the embedded-fallback resource.'
    }

    It 'every entry in $intentionallyNotEmbedded still exists on disk' {
        # Stale exclusions accumulate over time. If a file gets deleted from
        # the repo but stays in $intentionallyNotEmbedded, the exclusion is
        # dead weight and obscures what's actually intentional. This catches
        # that drift in the opposite direction.
        foreach ($relPath in $script:intentionallyNotEmbedded) {
            $abs = Join-Path $script:repoRoot $relPath
            (Test-Path -LiteralPath $abs) | Should -BeTrue `
                -Because "$relPath is in `$intentionallyNotEmbedded but no longer exists on disk. Either restore the file or remove the exclusion entry."
        }
    }
}
