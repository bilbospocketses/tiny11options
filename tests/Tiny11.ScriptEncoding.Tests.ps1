# Repo-wide invariant: every PowerShell/CMD script file must be either pure-ASCII
# or UTF-8 BOM-prefixed. PowerShell 5.1 reads UTF-8-no-BOM files as Windows-1252
# ANSI; em-dashes, smart quotes, arrows, and other Unicode prose punctuation get
# mangled into multi-byte garbage and break the parser at runtime.
#
# This test is the Layer-2 safety net behind the user-tier
# pre-edit-script-encoding-verify hook. The hook blocks at write time. This test
# catches anything the hook missed (e.g. files created by Bash cat-heredoc, edits
# made outside Claude Code, or hook bypasses).
#
# Allow-rule: non-ASCII codepoints are permitted IFF the file has a UTF-8 BOM
# (EF BB BF as the first three bytes). The UiApp.Cleanup.Tests.ps1 file uses this
# allowance to assert against literal check/cross glyphs rendered by the UI.

Describe 'Script encoding invariant (Layer-2 backstop)' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $extensions = @('*.ps1', '*.psm1', '*.psd1', '*.cmd', '*.bat')
        $excludeRegex = '\\(bin|obj|node_modules|\.git)\\'

        $script:offenders = @()
        foreach ($ext in $extensions) {
            Get-ChildItem -LiteralPath $repoRoot -Filter $ext -Recurse -File `
                | Where-Object { $_.FullName -notmatch $excludeRegex } `
                | ForEach-Object {
                    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
                    $firstNonAsciiOffset = -1
                    for ($i = 0; $i -lt $bytes.Length; $i++) {
                        if ($bytes[$i] -gt 0x7F) { $firstNonAsciiOffset = $i; break }
                    }
                    $hasNonAscii = ($firstNonAsciiOffset -ge 0)
                    if ($hasNonAscii -and -not $hasBom) {
                        # Compute line:col of the first offending byte for a useful error.
                        $line = 1; $col = 1
                        for ($i = 0; $i -lt $firstNonAsciiOffset; $i++) {
                            if ($bytes[$i] -eq 0x0A) { $line++; $col = 1 } else { $col++ }
                        }
                        $relPath = $_.FullName.Substring($repoRoot.Length + 1)
                        $script:offenders += [PSCustomObject]@{
                            Path = $relPath
                            FirstByte = '0x{0:X2}' -f $bytes[$firstNonAsciiOffset]
                            Line = $line
                            Col = $col
                        }
                    }
                }
        }
    }

    It 'every .ps1/.psm1/.psd1/.cmd/.bat file is pure-ASCII or UTF-8 BOM-prefixed' {
        if ($script:offenders.Count -gt 0) {
            $report = ($script:offenders | ForEach-Object {
                "  - $($_.Path)  (first non-ASCII byte $($_.FirstByte) at line $($_.Line), col $($_.Col))"
            }) -join "`n"
            $msg = @"
Encoding invariant violated. The following script files contain non-ASCII
codepoints but are not UTF-8 BOM-prefixed. PowerShell 5.1 will read them as
Windows-1252 ANSI and parser-crash on Unicode prose punctuation.

Offenders:
$report

Fix options per file:
  1. Replace non-ASCII with ASCII equivalents (em-dash -> '--', arrow -> '->',
     curly quotes -> straight quotes, ellipsis -> '...').
  2. If the non-ASCII is intentional (e.g. UI glyph a regex must match
     literally), rewrite the file with a UTF-8 BOM.

Rule source: feedback_ascii_only_user_scripts.md +
~/.claude/hooks/pre-edit-script-encoding-verify.py
"@
            throw $msg
        }
        $script:offenders.Count | Should -Be 0
    }
}
