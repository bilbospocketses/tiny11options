# Structural / contract tests for ui/app.js -- v1.0.13 focus-based update check.
#
# Pre-v1.0.13, update-check fired exactly once: in the DOMContentLoaded handler
# the boot path posted `ps({ type: 'request-update-check', payload: {} })`. The
# user had to close and reopen the app to detect a newer release published
# while the app was open.
#
# v1.0.13 adds a `window.focus` listener that re-fires the same handshake when
# the whole window regains focus (alt-tab back, restore-from-minimized, click
# taskbar icon). Clicking within the already-focused WebView does NOT refire
# the event so there's no thrashing from in-app interaction. A 5-minute
# throttle (UPDATE_CHECK_MIN_INTERVAL_MS) caps actual network calls even
# during alt-tab thrash. The badge.disabled guard skips the check while a
# previously-detected update is mid-download/apply.
#
# Strictly lighter than a setInterval timer: zero idle CPU wakeups, no
# background HTTPS calls when the app is hidden/minimized.

Describe 'ui/app.js -- v1.0.13 focus-based update re-check' {
    BeforeAll {
        $script:appJsPath = (Resolve-Path (Join-Path $PSScriptRoot '..\ui\app.js')).Path
        $script:content   = Get-Content $script:appJsPath -Raw
    }

    Context 'constants + state init' {
        It 'defines UPDATE_CHECK_MIN_INTERVAL_MS as 5 * 60 * 1000 (5 minutes)' {
            $script:content | Should -Match 'const\s+UPDATE_CHECK_MIN_INTERVAL_MS\s*=\s*5\s*\*\s*60\s*\*\s*1000\s*;'
        }

        It 'declares lastUpdateCheckMs as a mutable module-level var initialized to 0' {
            $script:content | Should -Match 'let\s+lastUpdateCheckMs\s*=\s*0\s*;'
        }
    }

    Context 'DOMContentLoaded boot path -- stamp timestamp BEFORE first dispatch' {
        It 'sets lastUpdateCheckMs = Date.now() before the boot request-update-check' {
            # The boot-time stamp must precede the dispatch so the focus listener
            # (registered right after) sees a non-zero baseline and doesn't
            # immediately refire a redundant second check.
            $script:content | Should -Match 'lastUpdateCheckMs\s*=\s*Date\.now\(\)\s*;\s*ps\(\s*\{\s*type:\s*''request-update-check''\s*,\s*payload:\s*\{\}\s*\}\s*\)\s*;'
        }
    }

    Context 'window.focus listener -- re-check on focus regain' {
        It 'registers a focus listener on window' {
            $script:content | Should -Match "window\.addEventListener\(\s*'focus'\s*,"
        }

        It 'skips re-check while badge.disabled (update-applying in flight)' {
            $script:content | Should -Match "window\.addEventListener\(\s*'focus'[\s\S]{0,600}focusBadge\.disabled\s*\)\s*return"
        }

        It 'gates on UPDATE_CHECK_MIN_INTERVAL_MS throttle' {
            # Generous wildcard span -- the listener body is comment-heavy
            # (rationale + guard explanations) so the Date.now check sits ~1k
            # chars from the listener registration.
            $script:content | Should -Match "window\.addEventListener\(\s*'focus'[\s\S]{0,2000}Date\.now\(\)\s*-\s*lastUpdateCheckMs\s*<\s*UPDATE_CHECK_MIN_INTERVAL_MS"
        }

        It 'updates lastUpdateCheckMs BEFORE dispatching the re-check' {
            # Stamp-then-dispatch order matters: the throttle baseline must
            # advance even if the bridge call fails so we don't retry hot.
            $script:content | Should -Match "window\.addEventListener\(\s*'focus'[\s\S]{0,2000}lastUpdateCheckMs\s*=\s*Date\.now\(\)\s*;\s*ps\(\s*\{\s*type:\s*'request-update-check'"
        }

        It 'dispatches the same request-update-check handshake as the boot path' {
            # Reusing the proven JS-initiated handshake is what makes this safe.
            # The C# UpdateHandlers comment explicitly calls out that the async-push
            # path (Task.Run -> SendToJs -> PostWebMessageAsString) had silently
            # dropped messages in a prior smoke; the JS-initiated request-response
            # path is the only proven delivery channel.
            $matches = [regex]::Matches($script:content, "ps\(\s*\{\s*type:\s*'request-update-check'\s*,\s*payload:\s*\{\}\s*\}\s*\)")
            $matches.Count | Should -BeGreaterOrEqual 2
        }
    }
}
