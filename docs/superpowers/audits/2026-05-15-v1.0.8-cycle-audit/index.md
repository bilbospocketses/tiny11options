# 2026-05-15 v1.0.8-cycle thorough audit

Outside-perspective audit performed via parallel subagents (no session context,
fresh-eyes review). Findings-only — no code changes — to be triaged into v1.0.8
fixes after the dispatch completes.

## Baseline state

- Branch: `main` at commit `285f7b6` (after v1.0.7 release tag on `251d8d0` plus
  two docs-only follow-ups: `ee754a0` (Scripted section three-example rewrite)
  and `285f7b6` (Scripted section consolidated to one shell-agnostic example)).
- Latest release: **v1.0.7** (2026-05-15) — bundled UI version-display + Finding 4
  stderr suppression + Node.js 24 (`actions/checkout@v6` + `actions/setup-dotnet@v5`)
  + `windows-2025-vs2026` runner pin. First annotation-free release since v1.0.2.
- Tests: **Pester 496/0**, **xUnit 113/0**.
- Active backlog before audit: v1.0.8 cycle = Microsoft Trusted Signing only
  (5 GitHub Action secrets). This audit may surface new v1.0.8 candidates.

## Scopes (one parallel agent per row)

| # | Scope | Findings file |
|---|---|---|
| 1 | C# launcher — `launcher/**/*.cs` + csproj + app.manifest + xUnit tests | `launcher.md` |
| 2 | PowerShell modules — `src/Tiny11.*.psm1` (Core, Worker, Actions.*, PostBoot, Hives, Iso, Selections, Autounattend, Catalog) | `ps-modules.md` |
| 3 | Top-level scripts — `tiny11maker.ps1` + `*-from-config.ps1` + `*-validate.ps1` + `tiny11-cancel-cleanup.ps1` | `scripts.md` |
| 4 | UI — `ui/index.html` + `ui/style.css` + `ui/app.js` | `ui.md` |
| 5 | CI / release pipeline — `.github/workflows/release.yml` + `global.json` + `tests/Run-Tests.ps1` | `ci.md` |
| 6 | Docs-vs-code consistency — `README.md` + `CHANGELOG.md` + script `.PARAMETER` blocks + `docs/superpowers/specs/*.md` + smoke-doc claims vs current code | `docs-consistency.md` |

## Finding vocabulary (matches v1.0.1 audit precedent in `docs/superpowers/audits/2026-05-13-v1.0.1-audit-*.md`)

- `A`-prefix — **Added/Architectural**: enhancements the existing code is missing (better error messages, defensive checks, structural improvements, factoring opportunities, naming/comment improvements).
- `B`-prefix — **Broken/Bug**: logic errors, race conditions, resource leaks, missing-null-checks, error paths that swallow signal, contract violations, security issues (command injection, etc.).
- `I`-prefix — **Informational**: things to know but not necessarily fix (dead-code candidates, performance edge cases, things to revisit if conditions change).
- `D`-prefix (docs-consistency scope only) — **Docs drift**: docs say X but code says Y.
- `O`-prefix (docs-consistency scope only) — **Omission**: code has a behavior docs don't mention.
- `S`-prefix (docs-consistency scope only) — **Stale**: docs reference outdated state (old version numbers, removed flags, etc.).
- `W`-suffix — **Warning sub-item** under a root finding (e.g. `B1-W1`, `B1-W2`).

## Severity buckets

- **BLOCKER**: would prevent v1.0.8 from being shippable as-is (security flaw, deterministic data loss path, broken contract end-users rely on, runtime crash).
- **WARNING**: should fix in v1.0.8 if cheap (~1-2 commits); defer to v1.0.9 otherwise.
- **INFO**: posterity / future cycles / decided-not-to-fix patterns.

## Aggregate triage

**Triage decision (2026-05-15, user-approved):**

- **v1.0.8 = "audit cleanup" release** — ALL audit-derived fixes except signing.
- **v1.0.9 = Microsoft Trusted Signing** — original v1.0.8 plan; deferred one cycle so the audit cleanup ships isolated and the signing wire-up doesn't share a commit history with 40+ unrelated fixes.

Severity buckets retained:
- **BLOCKER** — must fix in v1.0.8 (1 item).
- **WARNING (cheap)** — Tier 2: ~1-line or small targeted fix. In v1.0.8 by default (19 items).
- **WARNING (medium+)** — Tier 3: full court press, no half-baked work. In v1.0.8 with specific implementation recommendations below (16 items).
- **Already fixed post-audit** — Tier 4: do NOT re-fix (1 item).
- **Signing-related** — Tier 5: defer to v1.0.9 (2 items).
- **INFO** — Tier 6: posterity; touch only if same file is open for another reason.

### Tier 1 — BLOCKER (must fix)

| ID | Finding | Locations | Fix |
|---|---|---|---|
| **ps-modules B1** | `Get-Member -MemberType NoteProperty` enumerates PowerShell-injected ghost properties (`PSPath`, `PSChildName`, etc.). Latent today (no catalog pattern matches `PS*`); damaging the moment a broader pattern is added — would create real `REG_DWORD` values literally named `PSPath` under every user's hive on every cleanup pass. | `src/Tiny11.Actions.Registry.psm1:140-143` (offline path); `src/Tiny11.PostBoot.psm1:297-300` (online path) | Replace with `Get-Item -LiteralPath $regPath \| Select-Object -ExpandProperty Property` at both sites. Add a Pester guard exercising a key with both a real value name AND a `PSPath`-shaped NoteProperty; assert only the real name is enumerated. |

### Tier 2 — Cheap WARNINGs (in v1.0.8 by default)

| ID | Finding | Fix shape |
|---|---|---|
| **launcher B1** | `BuildHandlers.CloseActiveLog` reads `HasExited` / `ExitCode` after Dispose. | Cache to locals BEFORE `Dispose`; call `CloseActiveLog(localExit)` after. ~5 lines. |
| **launcher B4** | `Bridge.DispatchJsonAsync` returns `handler-error` without echoing original request type. | Include `requestType: msg.Type` in handler-error payload. ~3 lines C# + adjust JS routing if it benefits. |
| **ps-modules A1** | `Mount-DiskImage -PassThru` returns before `Get-Volume` sees the assigned drive letter on busy boxes. | Add 100ms-increment poll loop with ~5s ceiling around `Get-Volume` after mount. ~10 lines. |
| **ps-modules A3** | Catalog schema validator only checks `hive` for `type == 'registry'`, misses `registry-pattern-zero`. | Widen the check: `if ($action.type -in @('registry','registry-pattern-zero'))`. Also add required-field validation (`namePattern`, `valueType`, `key`, `hive`) at catalog-load boundary. |
| **ps-modules A5** | `Get-Tiny11AutounattendBindings` silently defaults to `'apply'` when item ID is missing from `$ResolvedSelections`. | Throw on missing ID. Add Pester guard. |
| **ps-modules I12** | Core's PS-script write uses `[System.Text.Encoding]::UTF8` (BOM behavior runtime-dependent); PostBoot correctly uses `[System.Text.UTF8Encoding]::new($true)`. | Standardize on `[System.Text.UTF8Encoding]::new($true)` at the Core site. ~1 line. |
| **scripts A4** | `tiny11-iso-validate.ps1` hardcodes `-MountedByUs:$true` on dismount instead of forwarding `$mountResult.MountedByUs`. | Mirror the GUI handler pattern exactly. Cosmetic but cheap. |
| **ci B1** | CI's Pester step inlines its own config, bypasses `Run-Tests.ps1`'s `#Requires Pester 5.3.1/5.99.99` pin. Will silently regress on Pester 6.0. | Replace inline config with `pwsh -NoProfile -File tests/Run-Tests.ps1`. |
| **ci B4** | Workflow refers to `Tiny11Options.Launcher.csproj` (capital T,O); on-disk is lowercase. Also redundant restore: launcher-only restore then Test/Publish re-restore. | Solution-level `dotnet restore tiny11options.sln` + `--no-restore` on Test/Publish + fix path-case. Optionally add `actions/cache@v4` for NuGet (defer if not done). |
| **ui B3** | `state.cleanupRequested` read but never declared in state initializer. Latch never resets — completion-screen retry is dead. v1.0.0 cleanup-latch removal was incomplete. | Replace with `state.cleaning` (matches v1.0.0 intent + the build-failed screen's wiring). |
| **ui B4** | `validate-iso` replies have no request ID; out-of-order replies clobber state. | One-line JS-side filter: drop reply if `p.path !== state.source`. (C# side already echoes `path`.) |
| **ui B5** | `profile-loaded` doesn't reset `state.search` / `state.drilledCategory`. | 2-line reset before re-render. |
| **ui B8** | v1.0.7 regression: `.app-version` `aria-label="Application version"` OVERRIDES textContent for screen readers. | **Switch to `title="Application version"` + drop `aria-label`.** Tooltip behavior for sighted users; screen readers read textContent. |
| **docs D1** | README "485 Pester / 105 xUnit" stale vs actual 496 / 113; v1.0.7 coverage not mentioned. | Bump counts; append two coverage clauses (AppVersion formatter + Filesystem.NoiseSuppression guards). |
| **docs D2** | README "29 entries amd64, 28 arm64" wrong; actual amd64=31 (after de-dupe), arm64=33 (no de-dupe). `Tiny11.Core.psm1:176` comment carries same stale numbers. | Update README + code comment. Re-audit arm64 list for genuine dupes; de-dupe if any. |
| **docs D3** | `minimal-removal.json` description (README) is OPPOSITE of what the file does. File has 4 skip entries + 70 implicit applies = aggressive cut. README says conservative. | **Rewrite the JSON profile** to truly minimal: explicit `apply` for ~3-5 "obvious bloat" items (Xbox, Solitaire, Teams chat icon, etc.); explicit `skip` for the remaining ~70. (User pick: rewrite file, NOT description.) |
| **docs D4** | README action-type list omits `registry-pattern-zero` (added v1.0.3). | Add to parenthesized list at README:202. |
| **docs O1** | `keep-edge-and-clipchamp.json` shipped but absent from README profile table. | Add fourth row to the table. |
| **(consolidated)** **scripts A3** | Duplicate of docs D1 — see above. | Resolved via D1 + optional Pester guard test (covered separately if desired). |

### Tier 3 — Medium+ WARNINGs (in v1.0.8, full court press)

Each item includes the recommended implementation; user can approve or pick alternative during engagement.

| ID | Finding | Recommended fix | Specific question (if any) |
|---|---|---|---|
| **launcher B2** | `_activeLogWriter` not gated by per-run identity. Start-build #2 can have its writer clobbered by start-build #1's pending stderr-fallback finally. | **Capture writer ref like `capturedBuild` captures Process** (mirrors the existing pattern); gate `CloseActiveLog` on `ReferenceEquals(_activeLogWriter, capturedWriter)`. | None — straightforward mirror of existing pattern. |
| **launcher B3** | Command-line injection via unescaped `"` in path args across 3 arg builders. LOW practical risk (admin-elevated single-user) but defensive fix is cheap. | **Factor `QuoteIfNeeded` from `HeadlessRunner.cs:190-196` into a shared helper.** Use from all three builders (`BuildStandardArgs`, `BuildCoreArgs`, `BuildCleanupArgs`, plus `DismountSourceIsoIfApplicable`). Add xUnit guard. | None — purely defensive. Skip JS-side path validation (admin-elevated single-user threat model unchanged). |
| **launcher B5** | `ConsoleAttach.AttachToParent` ignores return value. v1.0.1 audit A13 carried forward. `--log` flag is the workaround. | **Implement v1.0.1 audit Option C** — check return value, refresh `Console.Out` via `Console.SetOut(...)`, fall back to `AllocConsole`. Pair with existing `--log` flag (still preferred). | Verification needed during engagement: confirm AllocConsole doesn't break the existing `--log` flag's separate writer path. |
| **ps-modules A2** | `Get-Tiny11AutounattendTemplate` silently writes network-fetched template to disk; subsequent invocations use cached even if upstream fixes the template. No integrity check, no expiry. | **Drop the disk-cache entirely.** Path is Local → Network → Embedded fallback per the function header; we can simplify to Local-then-Embedded if no local file exists. Network fetch becomes ephemeral (in-memory) when explicitly requested; cache-to-disk goes away. | Confirm during engagement: what does the production code path actually use? If Worker calls this with a non-existent `$LocalPath` (relying on first-run network fetch), dropping the cache means every build re-fetches from GitHub. **Maybe better path: keep cache but add a date-stamp expiry (e.g., 7 days).** I'll surface this when implementing. |
| **ps-modules A4** | `Invoke-NativeWithNoiseFilter` (my v1.0.7 work): asymmetric — string lines slip through unfiltered; stdout dropped entirely. | Apply filter to both branches (`$_ -is [ErrorRecord]` and `else { $msg = [string]$_ }`). **Anchor regexes with `^`.** Question: surface takeown.exe's `SUCCESS:` stdout vs current "dropped silently" behavior? **Recommend pass-through** — build log gets more useful, no current consumer of the dropped output. | Confirm: pass takeown SUCCESS lines through to stdout, or keep dropping? (Recommended: pass through.) |
| **ps-modules A6** | `Invoke-Tiny11BuildPipeline` finally-block silently swallows scratch-cleanup `Remove-Item` failures via `-EA SilentlyContinue`. Locked files = stale partial trees on next build. | Stop swallowing; surface `"Some scratch files could not be deleted (rmdir-locked) — they will be cleaned at next build"` to the user via a progress marker. Actual lock release happens on reboot. | None — user-visible improvement only. |
| **ps-modules A7** | **(Empirically verified above — launcher path is safe; naming is conflated.)** `Invoke-Tiny11CoreBuildPipeline` params `-PostBootCleanupCatalog` / `-PostBootCleanupResolvedSelections` conflate "catalog data" with "post-boot cleanup data." | **Rename:** `-PostBootCleanupCatalog` → `-Catalog`; `-PostBootCleanupResolvedSelections` → `-ResolvedSelections`. Keep `-InstallPostBootCleanup` as the orthogonal task-install switch. Update wrapper script + internal call sites + tests. Add a test exercising Core + `InstallPostBootCleanup=$false` + Catalog present — asserts the offline overlay phase still runs. | None — empirical verification cleared the path. |
| **ps-modules A8** | `Start-CoreProcess` doesn't capture `$LASTEXITCODE` atomically. If `& $FileName @Arguments` itself throws (e.g., FileName missing), `$exit` is never assigned. | Initialize `$exit = -1` sentinel before the try. Wrap the native call in `try { ... } catch { throw "Start-CoreProcess: invocation of '$FileName' failed before exit-code was captured: $($_.Exception.Message)" }`. | None — straightforward defensive hardening. |
| **scripts A1** | `tiny11maker.ps1` self-elevation drops exit code through the UAC boundary. Headless launcher pre-elevates so bundled-exe path unaffected; direct `pwsh -File tiny11maker.ps1` invocation by a non-admin user is the affected path. | Add `-Wait -PassThru` to `Start-Process`, capture `$proc.ExitCode`, `exit $proc.ExitCode`. | Question: should self-elevation be REFUSED in `-NonInteractive` mode entirely (forcing CI callers to pre-elevate) as a belt-and-suspenders fix? **Recommend yes** — `-NonInteractive` + non-admin should fail fast with a clear error, not invisibly succeed-then-fail across the UAC boundary. |
| **scripts A2** | `Build-RelaunchArgs` uses naive `"$val"` interpolation. Latent (current params all scalar `[string]`/`[int]`/`[switch]`); footgun for future array params + paths containing `"`. | **Type-aware serialization** — handle `[array]` by repeating the param name per element; escape `"` in path-bearing values. Add Pester regression test for the array case. | None — defensive hardening, no behavior change for current param set. |
| **ui B1** | Cards (`<div class="card">`) + item rows (`<li class="clickable">`) not keyboard-accessible. Critical a11y gap for keyboard-only / screen-reader users. | Add `tabindex="0"`, `role="button"`, `onkeydown` (Enter/Space → existing click handler) to both. ~6 lines per type. | None — implementing as proposed in audit. |
| **ui B2** | Breadcrumb step indicator has no ARIA semantics. Screen readers see three orphan spans. | Add `aria-label="Wizard progress"` on wrapper; `aria-current="step"` toggle in `renderStep()`; `aria-disabled="true"` on the Core-skipped Customize step. | None — implementing as proposed in audit. |
| **ui B6** | Two `DOMContentLoaded` handlers at `app.js:1043` and `app.js:1217`. | Consolidate into one near bottom of file. Order: `initTheme()` → wire badge click → `renderStep()` → set `__appVersion` → post `request-update-check`. | None — implementing as proposed. |
| **ui B7** | Cleanup buttons (cancel + completion) use hardcoded hex colors ignoring dark mode. Inline cleanup status uses theme-aware `.cleanup-inline-success/-error`; completion-block duplicates with hardcoded hex. | Move both color sets to CSS vars. Reuse existing `.cleanup-inline-success/-error` classes (rename to drop "inline-" since they apply in both contexts). Add a `.cleanup-button` rule using `var(--warn-bg)` / `var(--warn-fg)` / warn-flavored border. | None — implementing as proposed. |
| **ui B9** | `confirm()` in update-badge click blocks WebView2 message pump. In-flight bridge messages queue during modal lifetime. | **Build custom in-app confirmation overlay** rendered when `state.pendingUpdate` is being confirmed. Same UX, no WebView2 pause. ~50-100 lines of new UI + CSS. | None — implementing as proposed. Largest UI piece of v1.0.8; will scope a separate sub-branch / commit. |

### Tier 4 — Already fixed post-audit (do NOT re-fix)

| ID | Status |
|---|---|
| **docs S3** | release-signing-setup.md Status banner — fixed in commit `764b790` (2026-05-15). |

### Tier 5 — Defer to v1.0.9 (signing-related)

| ID | Finding | v1.0.9 fix |
|---|---|---|
| **ci B2** | All 5 Trusted Signing secrets in job-level `env:`. Only `AZURE_TENANT_ID` needs that scope (gates). | Keep `AZURE_TENANT_ID` job-level; move other 4 to step-level `env:` or pass via `${{ secrets.* }}` in `with:` blocks. |
| **ci B3** | `azure/trusted-signing-action@v0.5.1` is a Jan 2024 pre-GA tag; action was renamed + GA'd as `azure/artifact-signing-action@v2.0.0`. | Bump to `azure/artifact-signing-action@v2.0.0`; verify input param names didn't rename in the rebrand. Test green-path via `workflow_dispatch` before relying on tag push. |

### Tier 6 — INFOs (posterity, no action required)

Counts: launcher 9, ps-modules 12, scripts 7, ui 11, ci 8, docs 4 (D5, D6, O2, O3 plus S1, S2, S4 as stale-bookkeeping). Total 51 INFOs + 4 D/O/S posterity.

Touch any of these only when the same file is open for another v1.0.8 reason. Notable cluster: ps-modules I1 (DEFAULT hive dead-write) and I5 (Invoke-RegCommand locale-fragile error matching) are the most likely future BLOCKER-candidates if the catalog or user base broadens.

### Empirical verification log

- **A7 verified 2026-05-15:** `tiny11Coremaker-from-config.ps1:117-118` passes `-PostBootCleanupCatalog $catalog` and `-PostBootCleanupResolvedSelections $resolved` unconditionally. The `-NoPostBootCleanup` switch only flows to `-InstallPostBootCleanup`. Launcher's bundled-exe Core path DOES apply the catalog at offline build time even with `-NoPostBootCleanup`. The `Tiny11.Core.psm1:1386-1391` comment confirms v1.0.3's A11 was the fix; pre-v1.0.3 the catalog WAS dropped in that case. **Conclusion:** real defect is naming conflation (handled in Tier 3), not silent catalog-drop in the launcher path.

### v1.0.8 sequencing recommendation

1. **Branch:** `feat/v1.0.8-audit-cleanup` off `main` at `869f9d0`.
2. **Commit cadence:** logically grouped commits (~10-15 commits total), not one mega-commit. Suggested grouping:
   - BLOCKER + Pester guard (1 commit)
   - PS-modules Tier 2 (A1, A3, A5, I12) (1-2 commits)
   - PS-modules Tier 3 (A2, A4, A6, A7-rename, A8) (3-4 commits)
   - Launcher Tier 2 + Tier 3 (B1, B2, B3, B4, B5) (3-4 commits)
   - Scripts (A1, A2, A4) (1-2 commits)
   - UI Tier 2 (B3, B4, B5, B8) (1-2 commits)
   - UI Tier 3 a11y (B1, B2) (1 commit)
   - UI Tier 3 cosmetic (B6, B7) (1 commit)
   - UI B9 (custom modal overlay) — own commit, possibly own sub-branch
   - CI (B1, B4) (1 commit)
   - Docs (D1, D2, D3-rewrite, D4, O1, + CHANGELOG ### Documentation) (1-2 commits)
   - Version bump + CHANGELOG + tag (1 commit)
3. **Smoke matrix:** v1.0.8 is non-build-path-affecting for the most part. The Core rename (A7) and the noise-filter (A4) DO touch the build path; both warrant a single targeted Core+catalog smoke run before tag (not a full P1-P9 re-matrix unless smoke surfaces a problem).
4. **Tests:** target Pester 496 → ~510+ (new guards), xUnit 113 → ~118+ (B3 / B4 / B5 / B1 guards as appropriate).
5. **Estimated cycle length:** larger than typical v1.0.x — 30+ items spanning 6 scopes. Each commit lands on the branch; v1.0.8 tag at end. No v1.0.7.1 docs-patch tag — docs land in v1.0.8 per user direction.
