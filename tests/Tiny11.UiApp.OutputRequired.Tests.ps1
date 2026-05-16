# Structural / contract tests for ui/app.js -- Output ISO required-field gate.
#
# Pre-v1.0.9 (v1.0.0 cycle, commit a93aaab): the output-required guard lived on
# Step 3. When the user reached Step 3 with state.outputPath empty, app.js
# computed an `outputMissing` predicate, folded it into `buildDisabled`,
# disabled the Build ISO button, and rendered a `.output-required-warning`
# block above the button explaining the user needed to set the output path.
#
# v1.0.9 redesign (2026-05-16) moved the gate from Step 3 to Step 1: Output ISO
# became a required Step 1 left-column field with its own `.req-asterisk` label
# decoration, `aria-required="true"` input, and reserved `.error-slot` below.
# Forward navigation past Step 1 is now blocked by a shared `canMoveForward()`
# predicate that requires all four Source & paths fields filled AND clean (no
# validation errors, no validations in flight). Step 3 became a pure read-only
# confirmation screen -- the `outputMissing` / `outputWarning` / Build ISO
# tooltip block was removed entirely; Step 3 never sees an empty output path.
#
# This file was rewritten in v1.0.10 to assert the v1.0.9+ Step 1 gating
# surface instead of the deleted Step 3 inline warning. Eight assertions
# against the removed UI were pruned; the surviving `calls renderStep() after
# assigning outputPath` test was kept but had its regex relaxed to match the
# v1.0.9 onchange handler shape (trims input + clears outputError +
# dispatches validation). The buildDisabled regression guard from the deleted
# `renderBuildStep -- buildDisabled predicate` Context was preserved here
# even though the same assertion now lives in Tiny11.UiApp.Cleanup.Tests.ps1
# under renderIdleCtaCard -- it acts as a behavior-level regression guard for
# this file's scope (output-related gating) without coupling to function name.
#
# The three .output-required-warning style.css rule tests pass because the
# v1.0.9 redesign removed the markup but did NOT prune the corresponding CSS
# rules. They are dead CSS. Flagged as a v1.0.11 follow-up; these three tests
# will start failing once the dead CSS is pruned and should be removed in the
# same change.

Describe 'ui/app.js -- Output ISO required-field gate (v1.0.9+ Step 1 surface)' {
    BeforeAll {
        $script:appJsPath = (Resolve-Path (Join-Path $PSScriptRoot '..\ui\app.js')).Path
        $script:content   = Get-Content $script:appJsPath -Raw
    }

    Context 'state model -- error fields survive renderStep' {
        It 'declares state.outputError (mirrors sourceError + scratchError pattern)' {
            $script:content | Should -Match 'outputError\s*:\s*'''''
        }
    }

    Context 'canMoveForward -- forward-nav predicate' {
        It 'defines canMoveForward' {
            $script:content | Should -Match 'function canMoveForward\s*\('
        }

        It 'gates on outputFilled (outputPath non-empty trimmed)' {
            $script:content | Should -Match 'function canMoveForward[\s\S]{0,800}outputFilled\s*=\s*!!\(\s*state\.outputPath[\s\S]{0,80}state\.outputPath\.trim\(\)\s*\)'
        }

        It 'gates on outputClean (no outputError, not validatingOutput)' {
            $script:content | Should -Match 'function canMoveForward[\s\S]{0,800}outputClean\s*=\s*!state\.outputError\s*&&\s*!state\.validatingOutput'
        }
    }

    Context 'renderSourceStep -- Output ISO field markup' {
        It 'renders the Output ISO label with required asterisk' {
            # Label string + .req-asterisk span. Both sit on the same el(...) call.
            $script:content | Should -Match "el\('label',\s*\{\s*for:\s*'out-input'[^}]*\}\s*,\s*'Output ISO[\s\S]{0,200}class:\s*'req-asterisk'"
        }

        It 'sets aria-required on the output input' {
            $script:content | Should -Match "id:\s*'out-input'[\s\S]{0,300}'aria-required':\s*'true'"
        }

        It 'renders a reserved error-slot bound to state.outputError' {
            # Mirrors the source + scratch error-slot pattern. The slot is always
            # in the DOM so column height doesn't jump when an error appears.
            $script:content | Should -Match "class:\s*'error-slot'[\s\S]{0,150}state\.outputError"
        }
    }

    Context 'out-input onchange -- re-render trigger' {
        It 'calls renderStep() after assigning outputPath so downstream nav gating re-evaluates' {
            # v1.0.10: the v1.0.9 onchange handler trims input, clears
            # state.outputError, dispatches validation, then calls renderStep().
            # Pre-v1.0.9 the handler was a bare two-statement assignment +
            # renderStep call; the regex now spans the wider handler body
            # while still anchoring on the load-bearing renderStep() call.
            $script:content | Should -Match "id:\s*'out-input'[\s\S]{0,800}onchange:[\s\S]{0,600}state\.outputPath\s*=[\s\S]{0,400}renderStep\(\)"
        }
    }

    Context 'renderIdleCtaCard regression -- buildDisabled still gates on cleanup state' {
        # v1.0.10: moved here from the deleted 'renderBuildStep -- buildDisabled
        # predicate' Context (the predicate moved from renderBuildStep into
        # renderIdleCtaCard during the v1.0.9 Step 3 redesign; the output-
        # missing branch was removed entirely since Step 1 now gates first).
        # The cleanup-state gate survives unchanged; this is its regression guard.
        It 'still gates on cleaning + cleanupStatus error (regression guard for prior wiring)' {
            $script:content | Should -Match 'buildDisabled\s*=\s*state\.cleaning\s*\|\|\s*\(state\.cleanupStatus\s*&&\s*state\.cleanupStatus\.kind\s*===\s*''error''\)'
        }
    }

}
