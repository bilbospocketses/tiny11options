# Audit: WebView2 UI (v1.0.8 cycle)

**Date:** 2026-05-15
**Scope:** `ui/index.html` + `ui/style.css` + `ui/app.js`
**Branch:** `main` at `285f7b6` (post-v1.0.7)
**Auditor:** parallel subagent (no session context)

## Summary

- BLOCKER: 0
- WARNING: 9
- INFO: 11

XSS surface is sound — `el()` exclusively uses `createTextNode` + `setAttribute`,
zero direct-HTML / `eval` / inline-string-to-DOM injection sinks anywhere in
`ui/app.js`. The `window.__tinyCatalog` injection is also safe under the
implicit "catalog must be valid JSON" invariant (see I2). No BLOCKER issues
found.

Bulk of the findings are accessibility gaps (no keyboard support on the card
grid + item rows, missing `role` on the breadcrumb step indicator, hardcoded
non-theme-aware colors on the cleanup buttons), a handful of state-machine
edge cases (stale validate-iso reply races, uninitialized `state.cleanupRequested`,
profile-load doesn't reset `state.search` / `state.drilledCategory`), and one
defensive-coding concern around the WebView2 modal-confirm path interfering
with in-flight bridge messages.

---

## B1 — Card grid + item rows aren't keyboard-accessible

**Severity:** WARNING
**File:** `ui/app.js:722-731` (cards), `ui/app.js:782` and `ui/app.js:837` (item rows)

**What.** The Step 2 category cards are bare `<div class="card">` elements with
`onclick` and no `tabindex`, no `role="button"`, and no keyboard handler. The
"clickable" item rows (`<li class="clickable">` with `onclick: rowClickHandler`)
have the same gap — they toggle a checkbox on mouse click but are invisible to
Tab + Space/Enter navigation. The native `<input type="checkbox">` inside each
row IS keyboard-reachable, but every other interaction (drilling into a card,
toggling a row by clicking its description text) demands a mouse.

**Why.** WebView2 hosts the UI inside a WPF window; tiny11options is a
desktop-equivalent app where keyboard navigation is a baseline OS expectation.
Users on accessibility tooling (NVDA / JAWS / Narrator) cannot drill into a
category at all from the keyboard — the cards report as plain `<div>` with no
interaction affordance. The native checkboxes get them through item-toggle but
not through the category navigation.

**Fix.** On `.card` add `tabindex="0"`, `role="button"`, and an `onkeydown`
handler that fires the same callback on `Enter` / `Space`. Same treatment for
`<li class="clickable">`. Both are ~6-line additions that mirror existing
`onclick` shape.

---

## B2 — Breadcrumb step indicator has no ARIA semantics

**Severity:** WARNING
**File:** `ui/index.html:9-15`, `ui/app.js:212-218`

**What.** The breadcrumb is `<header class="breadcrumb">` with three `<span>`
children (one per step) plus the update-badge and theme-toggle buttons. No
`role="progressbar"`, no `role="navigation"`, no `aria-current="step"` on the
active span, no `aria-disabled` on the Core-skipped Customize step (CSS just
sets `data-disabled="true"` for styling). Screen readers see three orphan text
runs in a header with no semantic relationship.

**Why.** This is the wizard's primary progress indicator. The visual treatment
makes the relationship obvious (color + underline on active, dim on disabled),
but assistive tech gets nothing. `aria-current="step"` is the canonical attr
for "this is the active step in a sequential flow"; pairing with
`role="navigation"` on the wrapper or `aria-label="Wizard progress"` on the
breadcrumb makes the structure announce correctly.

**Fix.** On the wrapping `<header>` add `aria-label="Wizard progress"`. On the
active span add `aria-current="step"` (toggle in `renderStep()` line 213
alongside the existing `classList.toggle('active', ...)`). On the
Customize-disabled-in-Core branch add `aria-disabled="true"` alongside the
existing `data-disabled` attribute.

---

## B3 — `state.cleanupRequested` is read before initialization

**Severity:** WARNING
**File:** `ui/app.js:591-595`

**What.** `renderCompletionCleanupBlock` reads `state.cleanupRequested` at
line 591 (`disabled: state.cleanupRequested`) and again at line 592 (style
string interpolation) and 594 (click guard). But `state.cleanupRequested` is
never declared in the `state = { ... }` object literal at lines 69-118 — it's
only ever **written** via `state.cleanupRequested = true` at line 595 on click.

First render: `state.cleanupRequested` is `undefined`, which is falsy, so the
button renders as enabled. That works for the happy path. But:

- After a successful build, click cleanup once → sets to `true`. Cleanup
  finishes (cleanup-complete arrives). User reaches another build cycle?
  Currently the post-build cleanup is one-shot per `state.completed` and
  there's no path to a "fresh build complete" while keeping the latch, so this
  is latent rather than active.
- The completion cleanup status renders inline-styled colors (lines 609-613)
  that DON'T respect dark mode — see B7.
- The latch never resets even if the cleanup fails, so the retry path on the
  COMPLETION screen is dead. (The Build-FAILED screen has a different,
  separately-wired retry via `state.cleaning`, but completion-screen retry
  silently doesn't work.)

**Why.** Reading an undeclared `state.*` property is a code smell — it means a
future contributor adding `Object.keys(state)` (e.g., for state-snapshotting in
profile save) would miss this field. The CHANGELOG v1.0.0 entry (line 419)
explicitly says "Removed legacy `state.cleanupRequested` one-shot latch" — but
this code path STILL HAS the latch, just decoupled from `state.cleaning`. The
removal was incomplete.

**Fix.** Either (a) declare `cleanupRequested: false` in the `state` initializer
and reset it on every build-complete handler entry, or (b) replace this latch
with `state.cleaning` (already in state and managed by the inline-status flow),
matching the cancel/error screen's wiring. Option (b) is cleaner and matches
the v1.0.0 cleanup CHANGELOG intent.

---

## B4 — `validate-iso` round-trip has no request-ordering guarantee

**Severity:** WARNING
**File:** `ui/app.js:975-981`, `ui/app.js:1052-1057`

**What.** When the user types an ISO path, `onchange` (line 975) clears
`state.editions` + `state.edition`, posts `validate-iso`, and starts the
spinner. A second `validate-iso` (different path) can be triggered before the
first completes. There's no request ID; the LATER `iso-validated` reply
overwrites the editions list. If the second validate completes FIRST (smaller
ISO, different path mount speed), the state ends up showing the second ISO's
editions then gets clobbered by the first ISO's slow reply.

**Why.** The validate-iso PS pipeline is mount + Get-Editions + dismount —
1-10s. Sub-second user retypes are plausible (typo correction). There's also a
race on cancel: the user could type path A, start validation, type path B
before A's spinner stops. `stopValidationSpinner` is called unconditionally on
any `iso-validated` arrival, so B's spinner gets stopped by A's reply.

**Fix.** Two options:

1. Tag each validate-iso request with a JS-generated nonce; ignore replies whose
   nonce doesn't match the most-recent request. C# would need to round-trip the
   nonce in `iso-validated` / `iso-error` payloads.
2. Compare `p.path` in the response against `state.source` and drop the reply
   if they don't match — the C# side already includes `path` in the response
   payload (`IsoHandlers.cs:61`), so this is a one-line JS-side filter with no
   C# change. Simpler.

Option 2 has a residual edge case: if the user retypes to path A, then B, then
back to A, the A-reply from the first attempt would now match again. Unlikely
in practice; the spinner-elapsed counter would at least show "30s" giving the
user a hint that something's off.

---

## B5 — `state.search` and `state.drilledCategory` aren't reset on profile-load

**Severity:** WARNING
**File:** `ui/app.js:1078-1082`

**What.** `profile-loaded` resets `state.selections` to the validated map but
leaves `state.search` and `state.drilledCategory` untouched. If the user is in
the drill-in view for category X when they click "Load profile...", the load
completes and the user stays in the (now-stale) category X view of the loaded
profile. The search input value persists too.

**Why.** This is mostly cosmetic, but it's surprising: the visible UI doesn't
re-orient to "you just loaded a profile, here's the category overview". The
counter at the top would be correct, but the displayed items reflect the
drill-in. More confusingly, if the loaded profile changed the apply/skip state
of items in the current drill-in, the checkboxes update in place — looks like
they autotoggled.

**Fix.** In the `profile-loaded` handler, reset `state.search = ''` and
`state.drilledCategory = null` before `renderStep()`. Two extra lines.

---

## B6 — Two separate `DOMContentLoaded` handlers can desync on initialization order

**Severity:** WARNING
**File:** `ui/app.js:1043-1048` and `ui/app.js:1217-1235`

**What.** The first handler runs `initTheme() → renderStep() → set
__appVersion`. The second handler (registered ~170 lines later in the file)
wires the update-badge click and posts `request-update-check`. Both fire on
the same DOMContentLoaded event; the order is just registration order in the
file (1043 then 1217 → first runs first).

**Why.** Spreading initialization across two handlers makes it easy for a future
contributor to register a third handler that depends on the second one. The
second handler is also positioned AFTER the entire bridge-message handling
block in the file, so a code reader has to grep for `DOMContentLoaded` to find
out everything that fires at boot. The CHANGELOG v1.0.7 line 14 explicitly
says the version-label rendering went into "the existing `DOMContentLoaded`
handler" — but there are TWO. One is "more existing" than the other.

**Fix.** Consolidate into a single handler near the bottom of the file. Order:
(1) `initTheme()`, (2) wire badge click, (3) `renderStep()`, (4) set
`__appVersion`, (5) post `request-update-check`. One source of boot order.

---

## B7 — Cleanup buttons use hardcoded colors that ignore dark theme

**Severity:** WARNING
**File:** `ui/app.js:465` (cancel/error cleanup button), `ui/app.js:592`,
`ui/app.js:609-613` (completion cleanup status/colors)

**What.** Two cleanup buttons have inline `style:` strings with hardcoded
colors:

- `renderCleanupBlock` (line 465): `border: 2px solid #f4c430; background-color: #fff8e1; color: #5d4e00; ...`
  → yellow-on-cream button. In dark mode this is a bright island in an
  otherwise dim UI. Visible — possibly intentional warning — but inconsistent
  with the rest of the v1.0.0 "theme-aware cleanup panels" rework (CHANGELOG
  line 415 explicitly called out the prior `#fafafa`/`#ddd` hardcoded styles as
  a bug and moved them to CSS variables).

- `renderCompletionCleanupBlock` (lines 611-613): inline status colors
  `#2e7d32` (green ✓) and `#c62828` (red ✗) for success/error states. The
  inline-cleanup-status row at lines 488-507 uses CSS classes
  `.cleanup-inline-success` / `.cleanup-inline-error` that ARE theme-aware
  (`style.css:646-668`), but the COMPLETION block duplicates the logic with
  hardcoded hex. Inconsistency: same semantic UI element, two implementations,
  one theme-aware, one not.

**Why.** The v1.0.0 cleanup-theming sweep covered the panels but not the
buttons or the completion-block status. Dark-mode users see a flash of bright
yellow + a green/red status that doesn't match the surrounding `--bg-card`.

**Fix.** Move both color sets to CSS. For the cleanup button, define a
`.cleanup-button` rule using `var(--warn-bg)` / `var(--warn-fg)` / a
warn-flavored border. For the completion status, reuse the existing
`.cleanup-inline-success` / `.cleanup-inline-error` CSS classes (or rename them
to drop "inline-" since they apply in both contexts now).

---

## B8 — `.app-version` span has `aria-label` that conflicts with its textContent

**Severity:** WARNING
**File:** `ui/index.html:18`, `ui/app.js:1046-1047`

**What.** The version label is:

```html
<span class="app-version" id="app-version" aria-label="Application version"></span>
```

At runtime its textContent is set to `window.__appVersion` (e.g. `"v1.0.7"`).
`aria-label` on a span without `role` is inconsistently announced by assistive
tech, AND when it IS announced, it OVERRIDES the textContent. So a screen
reader user hears `"Application version"` with no version number. Sighted
users see `"v1.0.7"` with no label.

**Why.** This is the v1.0.7 addition's accessibility decoration but it's
backwards. The intent is "tell the user this string is the app version" — but
the existing visible text `v1.0.7` already implies that. If the goal is to
provide additional context, the right pattern is a `<span>` with no aria-label,
or `aria-label="Application version v1.0.7"` constructed at runtime, or
`<span title="Application version">v1.0.7</span>` (title for sighted hover,
textContent for assistive tech).

**Fix.** Drop the `aria-label`. The textContent `v1.0.7` is sufficient — screen
readers will read it. If a sighted-out-of-context user wants more, set
`title="Application version"` for tooltip behavior (different attribute, no
override semantics).

---

## B9 — `confirm()` in the update-badge click path is a blocking modal inside WebView2

**Severity:** WARNING
**File:** `ui/app.js:1224`

**What.** When the user clicks the pulsing update badge:

```javascript
if (confirm(`Install tiny11options v${pendingUpdate.version}?\n\n${notes}${trail}`)) {
    ps({ type: 'apply-update', payload: {} });
}
```

`window.confirm()` blocks the WebView2 message pump. While the modal is open,
NO `chrome.webview` messages can be received — meaning any in-flight build
progress, cleanup progress, or update-error messages from C# get queued (or
silently dropped if WebView2's internal buffer overflows). For a user who
clicks the badge mid-build, this could mask 30+ seconds of build progress
behind a modal dialog.

**Why.** WebView2's `confirm()` is implemented via the `chrome.webview` plumbing
hooked through `BeforeScriptDialogShowing`; the JS runtime IS paused for the
modal's duration. Similar concern for `alert()` at line 1184 (the
"Build could not start:" alert), but that one only fires on start-build
handler-error, which means the build never started — no in-flight progress to
queue.

**Fix.** Build a custom in-app confirmation dialog (a `<div>` overlay rendered
in `renderStep` when `state.pendingUpdate` is being confirmed). Same UX, no
WebView2 pause. This is also a better channel for showing the truncated
changelog (the current 400-char slice + `\n...` in plain text is ugly inside
the OS-native confirm dialog).

---

## I1 — No CSP / SRI on `index.html`

**Severity:** INFO
**File:** `ui/index.html:1-8`

**What.** The HTML has no `<meta http-equiv="Content-Security-Policy">` and no
`integrity=` / `crossorigin=` on the `<link>` or `<script>` tags. WebView2's
`SetVirtualHostNameToFolderMapping("app.local", ..., Allow)` makes everything
under `app.local` same-origin; no cross-origin script sources are loaded; the
catalog is injected via C# `AddScriptToExecuteOnDocumentCreatedAsync`. So
there's no actual attack vector today.

**Why this is INFO not WARNING.** If a future fork ever adds a third-party CDN
include (analytics, font, polyfill), the absence of CSP is a foot-gun. A
default `Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline';
style-src 'self' 'unsafe-inline';` would gate that. The `'unsafe-inline'` is
needed for both the C#-injected catalog and the inline style strings noted in
B7. Not a v1.0.8 ask; mention if doing a security pass.

---

## I2 — Catalog injection trusts catalog.json to be valid, no parse-and-reserialize

**Severity:** INFO
**File:** `launcher/MainWindow.xaml.cs:125-128` (out of UI scope, but the JS-side
contract IS in scope)

**What.** The C# side reads `catalog/catalog.json` raw, concatenates
`"window.__tinyCatalog = " + file_contents + ";"`, and feeds to WebView2 as a
document-created script. If the catalog file is valid JSON, this produces
syntactically-valid JS and is safe. If a catalog file ever contains JS-breaking
content (e.g. ends without a closing `}`, has a trailing comma in some
contexts), the WebView2 script registration fails silently and
`window.__tinyCatalog` is undefined → `state.catalog = undefined` →
`state.catalog.items` throws on first Step 2 entry.

**Why this is INFO not WARNING.** The Pester schema-validation tests cover
catalog correctness, and the catalog is bundled into the launcher exe so
end-users can't tamper with it without rebuilding. A fork maintainer who
introduces an invalid catalog would see WebView2's debug console output the
error. The XSS angle is a non-issue because there's no user-controlled path
into the catalog string. Mentioning for completeness; the C#-side would be the
fix locus, not the JS.

**If the C# side ever wants belt-and-suspenders:** parse the catalog JSON with
`JsonNode.Parse` first and re-serialize it via `JsonSerializer.Serialize`
before injecting; that guarantees output is valid JS regardless of source-file
quirks.

---

## I3 — `el()` helper has ad-hoc boolean-attribute handling

**Severity:** INFO
**File:** `ui/app.js:40-63`

**What.** The `el()` helper at line 40 has a chain of `if/else if` branches:

```javascript
if (k === 'class')          e.className = v;
else if (k === 'data')      Object.entries(v).forEach(([dk, dv]) => e.dataset[dk] = dv);
else if (k === 'checked')   e.checked = !!v;
else if (k === 'disabled')  e.disabled = !!v;
else if (k === 'value')     e.value = v;
else if (k.startsWith('on')) e.addEventListener(k.slice(2).toLowerCase(), v);
else                          e.setAttribute(k, v);
```

`aria-*` attributes fall through to `setAttribute(k, v)` — correct behavior.
Same for `tabindex` / `role` / etc. (used at line 993, 998, 1001 successfully).
The `data` key is special-cased for nested-object shape (`data: { cat: c.id }`)
which is the convention for the dataset API.

But: a contributor adding e.g. `{ readonly: true }` would hit the
`setAttribute('readonly', true)` path, which becomes `readonly="true"` — WORKS
because the attribute presence (any value) sets the boolean, but stylistically
weird. Same for `required`, `multiple`, etc. Real boolean HTML attributes have
no canonical handling here. Compare with `checked` / `disabled` which ARE
special-cased.

**Why this is INFO.** No active bugs; the helper currently handles every
attribute the existing UI passes. But the inconsistency is a footgun for the
future. The fix is to either (a) add an explicit list of boolean attrs that
get the `e.X = !!v` treatment, or (b) document the convention "use the property
name, not the attribute name, for booleans" in a comment block.

---

## I4 — Bulk-select button operates on the visible filtered set (matches README claim)

**Severity:** INFO
**File:** `ui/app.js:670-682`

**What.** `bulkSelectButton` computes `allChecked = unlocked.length > 0 &&
unlocked.every(it => state.selections[it.id] === 'apply')`. When the visible
filtered set is all-apply, the button says "Uncheck all" and a click sets every
unlocked item to `skip`. When ANY visible item is skip, the button says
"Check all" and a click sets every unlocked item to `apply`.

**Why this is INFO.** README claim (line 32): "Check all" / "Uncheck all"
button operates on the visible filtered set. Code matches claim. ✓

The subtle thing is that "visible" means "items currently rendered" — the
search filter is applied BEFORE the bulk button is constructed (at line 799
the bulk button receives `matchingItems`, not the full catalog). So a search
for "edge" + Check All toggles only Edge-matching items. Confirmed in code.

Worth noting for a future PR that adds category filtering or other narrowing:
the bulk button takes whatever items array is handed in. Drill-in mode passes
all items in the category. Search mode passes search results. ✓ both consistent
with README claim.

---

## I5 — `searchResults` filter is naive concatenation, not multi-word AND search

**Severity:** INFO
**File:** `ui/app.js:756-757`

**What.** `matchingItems = state.catalog.items.filter(it =>
(it.displayName + ' ' + (it.description || '')).toLowerCase().includes(term))`.

A search for `"clipchamp app"` only matches if "clipchamp app" appears
contiguously in name+description. A search for `"app clipchamp"` (same words,
different order) returns nothing. Most users expect tokenized AND search
("matches all words, any order").

**Why this is INFO.** Power users may notice but it's a minor UX nit. Catalog
has ~74 items; users will see search hits cleanly with single-word queries.
For multi-word, the substring approach is forgiving when the user phrases the
query in catalog-display order. The CHANGELOG / README don't make any
search-semantics promise.

**Fix (if ever):** Split on whitespace and AND all tokens against the same
concatenated haystack.

---

## I6 — Reset to defaults in search-results view doesn't exit search mode

**Severity:** INFO
**File:** `ui/app.js:805`

**What.** The Reset-to-defaults button in `renderSearchResults` does
`state.selections = {}; renderStep();`. The next render is still in search
mode (state.search is still set), but now showing default selections for all
search-matching items. The user may expect Reset to also return them to the
category overview.

**Why this is INFO.** Subjective UX call. The category-overview Reset button
(line 749) makes more sense to stay in category overview. The search-mode
Reset has two plausible interpretations.

---

## I7 — `confirm()` truncation at 400 chars is silent and may cut mid-word

**Severity:** INFO
**File:** `ui/app.js:1222-1224`

**What.** `const notes = (pendingUpdate.changelog || '').slice(0, 400); const
trail = ... ? '\n...' : '';`. A changelog of exactly 400 chars gets no
truncation indicator. A changelog of 401+ chars gets `\n...` appended but may
cut mid-word or mid-line.

**Why this is INFO.** Minor. The truncated text is a hint to the user, not the
canonical release notes — they'd click "Install" or visit GitHub regardless.

---

## I8 — `cleanup-progress` percent rendering can show "(NaN%)" if PS emits non-numeric

**Severity:** INFO
**File:** `ui/app.js:1145`

**What.** `state.cleanupStatus = { kind: 'progress', message:
\`(${p.percent || 0}%) ${p.step || ''}\` };`. If `p.percent` is sent as
"in_progress" (a string), `||` short-circuits to the string. If it's `NaN`
(from a parse failure upstream), `NaN || 0` is `0` (NaN is falsy). Mostly safe;
worth noting that PS scripts emit `[int]$Percent` so the integer-ness is
upstream-enforced.

**Why this is INFO.** PS-side contract is solid. Mentioning as a small
defensive option: `Number.isFinite(p.percent) ? p.percent : 0` would be a tiny
hardening that survives a future PS marker-shape drift.

---

## I9 — Cleanup retry button doesn't visually surface that mountActive may have flipped during retry

**Severity:** INFO
**File:** `ui/app.js:499-507`

**What.** The error inline-status row shows "Retry cleanup" which calls
`startCleanupFlow()`. `startCleanupFlow` checks `state.mountDir && state.sourceDir`
(both persisted from the original mount-state marker). It does NOT re-check
`state.mountActive`. So a retry will dispatch start-cleanup even if cleanup
already partially succeeded and `mountActive` was set to false by an earlier
cleanup-complete (then later overwritten by a cleanup-error that didn't reset
mountActive).

**Why this is INFO.** The actual state machine in current code makes this
scenario very narrow — cleanup-complete is terminal (sets mountActive=false +
status=success). cleanup-error doesn't change mountActive. So mountActive=false
+ cleanupStatus=error doesn't naturally occur from the bridge messages alone.
But a future "partial cleanup" message could introduce that state without
updating retry semantics.

---

## I10 — `el(..., null, ...)` second-arg-null is widespread but the signature implies "attrs object"

**Severity:** INFO
**File:** `ui/app.js:40-63` and ~50 callsites

**What.** `el(tag, attrs, ...children)` is documented as taking attrs as an
object. Most callsites that need no attrs pass `null` (e.g., `el('h2', null,
'Build complete')`). The helper handles this: `if (attrs)` at line 42 short-
circuits. Works correctly.

**Why this is INFO.** Stylistic only. Could be `el('h2', {}, ...)` for
consistency, or could change the signature to `el(tag, children)` with attrs
detection. Not worth churning ~50 callsites.

---

## I11 — Footer + breadcrumb survive 1000px window floor (no `text-overflow: ellipsis` needed)

**Severity:** INFO
**File:** `ui/style.css:60-66` (body), `ui/style.css:139-147` (footer),
`ui/style.css:65-74` (breadcrumb), and the WPF launcher's 1000×750 minimum

**What.** The `.actions` footer is `display: flex; justify-content: flex-end;
gap: 12px`. The `.app-version` span has `margin-right: auto` to push to LEFT
of the buttons. At narrow widths, the version label could collide with the
buttons. CHANGELOG suggests the launcher clamps window dimensions at 1000×750
(line 436), so realistic users see at least 1000px of footer width. Plenty of
room for `"v1.0.7"` + `< Back` + `Next >`.

**Why this is INFO.** The 1000px floor effectively prevents the collision. A
future `<Version>` that goes to 4+ digits per segment (e.g. `v1.234.5678`)
would consume slightly more space but still fit comfortably. Similarly, the
breadcrumb's three labels + two icon buttons + a 20px gap fit well within
1000px.

The v1.0.8 cycle audit prompt asked specifically about "narrow window widths"
and "text-overflow handling for unexpectedly long version strings": the
launcher's 1000px floor means this isn't reachable in practice; no
`text-overflow: ellipsis` is needed. ✓ contract holds.

If someone ever drops the launcher's minimum-size clamp, the version label
should pick up `text-overflow: ellipsis; overflow: hidden; max-width: ...`
defensively. Not actionable now.
