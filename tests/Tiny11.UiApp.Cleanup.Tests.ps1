# Structural / contract tests for ui/app.js cleanup wiring.
#
# Three blocks live in app.js:
#   - renderCleanupBlock          -> cancel/error screen -- button that drives
#                                   startCleanupFlow (navigates to Step 3)
#   - renderCleanupRecipe         -> in-progress details panel -- recipe only,
#                                   no button (mid-build click would race a
#                                   live DISM mount and silently fail to
#                                   delete locked files)
#   - renderCompletionCleanupBlock -> build-complete screen -- "Clean up scratch
#                                   directory" button with outputIso guard
#
# Plus inline-status row + Build ISO disable wiring in renderBuildStep, and a
# two-button Cancel row + chained pendingCleanupAfterCancel flow in
# renderProgress / build-error handler.
#
# These tests exist because we don't have a JS test framework wired up, and
# the wrapper-script field-stripping incident (`28f4eec` / `2ecef90`) and the
# mid-build cleanup-vanishes-on-success incident (2026-05-11) both
# demonstrated that silent gaps between layers cost real time.

Describe 'ui/app.js -- cleanup wiring' {
    BeforeAll {
        $script:appJsPath = (Resolve-Path (Join-Path $PSScriptRoot '..\ui\app.js')).Path
        $script:content   = Get-Content $script:appJsPath -Raw
    }

    It 'app.js exists at expected path' {
        Test-Path $script:appJsPath | Should -BeTrue
    }

    Context 'state model (spinner-flow additions)' {
        It 'declares state.cleaning bool (replaces legacy cleanupRequested latch)' {
            $script:content | Should -Match 'cleaning:\s*false'
        }

        It 'declares state.pendingCleanupAfterCancel (chained flow flag)' {
            $script:content | Should -Match 'pendingCleanupAfterCancel:\s*false'
        }

        It 'no longer declares the legacy state.cleanupRequested one-shot latch' {
            $script:content | Should -Not -Match 'cleanupRequested:\s*(true|false)'
        }
    }

    Context 'startCleanupFlow (centralised dispatch)' {
        It 'defines startCleanupFlow' {
            $script:content | Should -Match 'function startCleanupFlow\s*\('
        }

        It 'sets state.cleaning = true and primes progress status' {
            $script:content | Should -Match "function startCleanupFlow[\s\S]{0,400}state\.cleaning\s*=\s*true[\s\S]{0,200}kind:\s*'progress'"
        }

        It 'navigates to Step 3 (building=false, completed=null, step=build)' {
            $script:content | Should -Match "function startCleanupFlow[\s\S]{0,600}state\.building\s*=\s*false[\s\S]{0,200}state\.completed\s*=\s*null[\s\S]{0,200}state\.step\s*=\s*'build'"
        }

        It "posts start-cleanup with state.mountDir + state.sourceDir" {
            $script:content | Should -Match "function startCleanupFlow[\s\S]{0,800}type:\s*'start-cleanup'[\s\S]{0,200}mountDir:\s*state\.mountDir[\s\S]{0,200}sourceDir:\s*state\.sourceDir"
        }
    }

    Context 'cancelBuildAndCleanup (chained mid-build flow)' {
        It 'defines cancelBuildAndCleanup' {
            $script:content | Should -Match 'function cancelBuildAndCleanup\s*\('
        }

        It 'sets pendingCleanupAfterCancel = true so build-error handler chains start-cleanup' {
            $script:content | Should -Match 'function cancelBuildAndCleanup[\s\S]{0,400}state\.pendingCleanupAfterCancel\s*=\s*true'
        }

        It 'dispatches cancel-build (not start-cleanup directly -- would race live DISM mount)' {
            $script:content | Should -Match "function cancelBuildAndCleanup[\s\S]{0,600}type:\s*'cancel-build'"
        }
    }

    Context 'renderCleanupRecipe (in-progress details panel -- recipe-only, no button)' {
        It 'defines renderCleanupRecipe' {
            $script:content | Should -Match 'function renderCleanupRecipe\s*\('
        }

        It 'self-gates on state.mountActive' {
            $script:content | Should -Match 'function renderCleanupRecipe[\s\S]{0,200}if\s*\(\s*!state\.mountActive\s*\)\s*return\s+null'
        }

        It 'is invoked from renderProgress (in-progress details panel)' {
            $script:content | Should -Match 'function renderProgress[\s\S]{0,3000}renderCleanupRecipe\(\)'
        }

        It 'has NO start-cleanup button onclick (recipe-only -- button moved to Cancel row)' {
            $script:content | Should -Not -Match "function renderCleanupRecipe[\s\S]{0,800}onclick[\s\S]{0,200}start-cleanup"
        }
    }

    Context 'renderProgress -- two-button Cancel row + recipe (no auto-cleanup button mid-build)' {
        It 'renders the original "Cancel build" button posting cancel-build' {
            $script:content | Should -Match "function renderProgress[\s\S]{0,5000}'Cancel build'"
        }

        It 'renders the new "Cancel build & clean up" button wired to cancelBuildAndCleanup' {
            $script:content | Should -Match "function renderProgress[\s\S]{0,5000}onclick:\s*cancelBuildAndCleanup[\s\S]{0,200}'Cancel build & clean up'"
        }

        It 'does NOT invoke renderCleanupBlock inside renderProgress (uses renderCleanupRecipe instead)' {
            $script:content | Should -Not -Match 'function renderProgress[\s\S]{0,4000}renderCleanupBlock\(\)'
        }
    }

    Context 'renderBuildStep -- inline cleanup status row + Build ISO disable' {
        It 'invokes renderInlineCleanupStatus at the top of the Step 3 layout' {
            $script:content | Should -Match 'function renderBuildStep[\s\S]{0,3000}renderInlineCleanupStatus\(\)'
        }

        It 'computes a buildDisabled flag from state.cleaning + cleanupStatus.kind === error' {
            $script:content | Should -Match "function renderBuildStep[\s\S]{0,3000}const buildDisabled\s*=\s*state\.cleaning[\s\S]{0,200}kind\s*===\s*'error'"
        }

        It 'binds disabled: buildDisabled on the Build ISO primary button' {
            $script:content | Should -Match "function renderBuildStep[\s\S]{0,4000}class:\s*'primary'[\s\S]{0,200}disabled:\s*buildDisabled"
        }
    }

    Context 'renderInlineCleanupStatus -- spinner / check / X' {
        It 'defines renderInlineCleanupStatus' {
            $script:content | Should -Match 'function renderInlineCleanupStatus\s*\('
        }

        It 'progress kind renders a .wizard-spinner element' {
            $script:content | Should -Match "function renderInlineCleanupStatus[\s\S]{0,600}kind\s*===\s*'progress'[\s\S]{0,300}class:\s*'wizard-spinner'"
        }

        It 'success kind renders a ✓ glyph' {
            $script:content | Should -Match "function renderInlineCleanupStatus[\s\S]{0,1000}kind\s*===\s*'success'[\s\S]{0,300}✓"
        }

        It 'error kind renders ✗ glyph and a Retry cleanup button' {
            $script:content | Should -Match "function renderInlineCleanupStatus[\s\S]{0,2000}✗[\s\S]{0,400}'Retry cleanup'"
        }

        It 'Retry cleanup button wires onclick to startCleanupFlow' {
            $script:content | Should -Match "function renderInlineCleanupStatus[\s\S]{0,2000}startCleanupFlow\(\)[\s\S]{0,100}'Retry cleanup'"
        }
    }

    Context 'renderCleanupBlock -- build-failed screen button' {
        It 'is invoked from the build-error handler (so cancel/error screen still surfaces it)' {
            $script:content | Should -Match "msg\.type === 'build-error'[\s\S]{0,3000}renderCleanupBlock\(\)"
        }

        It 'button onclick routes through startCleanupFlow (not direct start-cleanup post)' {
            $script:content | Should -Match "function renderCleanupBlock[\s\S]{0,3000}onclick:[\s\S]{0,200}startCleanupFlow"
        }
    }

    Context 'renderCompletionCleanupBlock -- build-complete path (Core + Worker)' {
        It 'defines renderCompletionCleanupBlock function' {
            $script:content | Should -Match 'function renderCompletionCleanupBlock\s*\('
        }

        It 'is invoked from renderComplete' {
            $script:content | Should -Match 'function renderComplete[\s\S]{0,800}renderCompletionCleanupBlock\(\)'
        }

        It 'passes outputIso: state.outputPath to start-cleanup (engages script-side ISO guard)' {
            $script:content | Should -Match "function renderCompletionCleanupBlock[\s\S]{0,1500}type:\s*'start-cleanup'[\s\S]{0,400}outputIso:\s*state\.outputPath"
        }

        It 'labels the button "Clean up scratch directory"' {
            $script:content | Should -Match "'Clean up scratch directory'"
        }
    }

    Context 'build-error header polish -- "Build cancelled" vs "Build failed"' {
        It 'detects cancel by matching "cancelled by user" in the message' {
            $script:content | Should -Match "msg\.type === 'build-error'[\s\S]{0,1500}wasCancelled[\s\S]{0,200}'cancelled by user'"
        }

        It 'renders "Build cancelled" header when cancelled, "Build failed" otherwise' {
            $script:content | Should -Match "wasCancelled\s*\?\s*'Build cancelled'\s*:\s*'Build failed'"
        }

        It 'omits the duplicate message paragraph when cancelled (header already says it)' {
            $script:content | Should -Match 'if\s*\(\s*!wasCancelled\s*\)\s*\{[\s\S]{0,200}p\.message'
        }
    }

    Context 'build-error handler -- pendingCleanupAfterCancel chain' {
        It 'checks state.pendingCleanupAfterCancel and dispatches start-cleanup before showing failure UI' {
            $script:content | Should -Match "msg\.type === 'build-error'[\s\S]{0,400}state\.pendingCleanupAfterCancel[\s\S]{0,800}type:\s*'start-cleanup'"
        }

        It 'clears pendingCleanupAfterCancel after consuming it (so a future build-error renders the failure UI normally)' {
            $script:content | Should -Match 'state\.pendingCleanupAfterCancel\s*=\s*false'
        }
    }

    Context 'cleanup marker handlers -- clear state.cleaning, surface handler-error' {
        It 'cleanup-complete clears state.cleaning and sets success status' {
            $script:content | Should -Match "msg\.type === 'cleanup-complete'[\s\S]{0,400}state\.cleaning\s*=\s*false[\s\S]{0,200}kind:\s*'success'"
        }

        It 'cleanup-error clears state.cleaning and sets error status' {
            $script:content | Should -Match "msg\.type === 'cleanup-error'[\s\S]{0,400}state\.cleaning\s*=\s*false[\s\S]{0,200}kind:\s*'error'"
        }

        It 'handler-error path surfaces to state.cleanupStatus when a cleanup was in flight (no more silent console-only failures)' {
            $script:content | Should -Match "msg\.type === 'handler-error'[\s\S]{0,800}state\.cleaning[\s\S]{0,400}kind:\s*'error'"
        }
    }

    Context 'theme awareness (regression -- no hardcoded panel chrome)' {
        # 2026-05-11: both blocks shipped with inline `background: #fafafa` +
        # `border: 1px solid #ddd`, which ignored data-theme=dark.
        It 'core-cleanup container does not hardcode background hex' {
            $script:content | Should -Not -Match "class:\s*'core-cleanup'[^}]*background:\s*#"
        }

        It 'completion-cleanup container does not hardcode background hex' {
            $script:content | Should -Not -Match "class:\s*'completion-cleanup'[^}]*background:\s*#"
        }
    }
}
