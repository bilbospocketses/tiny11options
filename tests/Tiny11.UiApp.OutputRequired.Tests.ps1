# Structural / contract tests for ui/app.js -- output-required guard.
#
# When the user leaves the scratch directory blank on Step 1, the auto-populate-
# from-scratch path never fires for the output ISO, so state.outputPath stays null.
# Pre-fix, the Build ISO button enabled regardless and pwsh bombed at parameter
# binding with ParameterArgumentValidationErrorEmptyStringNotAllowed on -OutputIso
# (build scripts ValidateNotNullOrEmpty the param). Post-fix, the Build ISO button
# is disabled until outputPath is non-empty, an inline warning surfaces above the
# button, and the C# handler refuses to spawn pwsh on an empty path as a backstop.
#
# This file is a sibling to Tiny11.UiApp.Cleanup.Tests.ps1 -- same regex-against-
# source-text discipline, no JS framework wired up.

Describe 'ui/app.js -- output-required guard' {
    BeforeAll {
        $script:appJsPath = (Resolve-Path (Join-Path $PSScriptRoot '..\ui\app.js')).Path
        $script:content   = Get-Content $script:appJsPath -Raw
        $script:cssPath   = (Resolve-Path (Join-Path $PSScriptRoot '..\ui\style.css')).Path
        $script:css       = Get-Content $script:cssPath -Raw
    }

    Context 'renderBuildStep -- buildDisabled predicate' {
        It 'computes outputMissing from empty/whitespace outputPath' {
            $script:content | Should -Match 'outputMissing\s*=\s*!state\.outputPath\s*\|\|\s*!state\.outputPath\.trim\(\)'
        }

        It 'folds outputMissing into buildDisabled' {
            $script:content | Should -Match 'buildDisabled\s*=[^;]*outputMissing'
        }

        It 'still gates on cleaning + cleanupStatus error (regression guard for prior wiring)' {
            $script:content | Should -Match 'buildDisabled\s*=\s*state\.cleaning\s*\|\|\s*\(state\.cleanupStatus\s*&&\s*state\.cleanupStatus\.kind\s*===\s*''error''\)'
        }
    }

    Context 'renderBuildStep -- inline warning' {
        It 'renders an output-required-warning element when outputMissing' {
            $script:content | Should -Match "output-required-warning"
        }

        It 'warning includes user-actionable copy mentioning the output ISO path' {
            $script:content | Should -Match 'Choose an output location for the ISO file'
        }

        It 'warning mentions %TEMP% so users understand scratch can stay blank' {
            $script:content | Should -Match '%TEMP%'
        }

        It 'warning is omitted when outputPath is set (null branch present)' {
            # Conditional `outputWarning = outputMissing ? el('div', ...) : null;` -- the
            # el(...) body holds the user-facing warning copy (~300 chars), so window
            # generously to accommodate future copy edits.
            $script:content | Should -Match 'outputWarning\s*=\s*outputMissing[\s\S]{0,800}:\s*null'
        }

        It 'warning is rendered into the build section above the Build ISO button' {
            # Section structure: el('section', { class: 'build' }, ..., outputWarning, el('button', {...lots of onclick code...}, 'Build ISO')).
            # The button body holds the full onclick handler (multi-line state mutation
            # + ps() post + ~16 payload fields), so window generously here too.
            $script:content | Should -Match "outputWarning,\s*el\('button',\s*\{[\s\S]{0,2000}'Build ISO'"
        }
    }

    Context 'renderBuildStep -- Build ISO button' {
        It 'has a tooltip explaining the disabled state when output is missing' {
            $script:content | Should -Match "title:\s*outputMissing\s*\?\s*'Set the Output ISO path first\.'\s*:\s*null"
        }
    }

    Context 'out-input onchange -- re-render trigger' {
        It 'calls renderStep() after assigning outputPath so the gate reactively re-evaluates' {
            # Pre-fix, onchange was a bare assignment; the warning + disabled-state never
            # updated until something else triggered a render.
            $script:content | Should -Match 'onchange:\s*e\s*=>\s*\{\s*state\.outputPath\s*=\s*e\.target\.value;\s*renderStep\(\);\s*\}'
        }
    }

    Context 'style.css -- output-required-warning rule' {
        It 'declares the .output-required-warning class' {
            $script:css | Should -Match '\.output-required-warning\s*\{'
        }

        It 'uses theme-aware --warn-bg / --warn-fg variables (dark + light parity)' {
            $script:css | Should -Match '\.output-required-warning[\s\S]{0,400}--warn-bg'
            $script:css | Should -Match '\.output-required-warning[\s\S]{0,400}--warn-fg'
        }

        It 'declares the .output-required-glyph circle badge' {
            $script:css | Should -Match '\.output-required-glyph\s*\{'
        }
    }
}
