# Audit: Docs-vs-code consistency (v1.0.8 cycle)

**Date:** 2026-05-15
**Scope:** README + CHANGELOG + .PARAMETER blocks + XML doc comments + docs/superpowers/{specs,plans,smoke,audits} + release-signing-setup.md
**Branch:** main at `285f7b6` (post-v1.0.7 + 2 docs-only follow-ups)
**Auditor:** parallel subagent (no session context)

## Summary

- BLOCKER: 0
- WARNING: 6
- INFO: 7
- Drift (D): 6 items
- Omission (O): 3 items
- Stale (S): 4 items

No BLOCKER-class drift surfaced. The README is the noisiest documentation surface — six of the six WARNING-level findings live there, and all are isolated factual drifts (test counts, action-type inventory, WinSxS keep-list cardinalities, profile descriptions). No security-relevant claim found to be missing in code. CHANGELOG `[1.0.7]` and `[1.0.6]` claims verified against the file system and source where checkable (line counts, file sizes, helper extraction). The release-signing-setup.md has a status header that pre-dates v1.0.2 through v1.0.7 — Microsoft validation flow narrative remains technically accurate but the framing dates the doc to before the actual signing cycle landed.

---

## D1 — README "485 Pester / 105 xUnit" test-count narrative is one release behind

**Severity:** WARNING
**Doc:** README.md:285 ("## Running tests" prose block)
**Code:** CHANGELOG.md:27-28 (`[1.0.7] ### Tests` block), test files under `tests/` and `launcher/Tests/`

Doc claims: "485 Pester tests ... and 105 xUnit launcher tests" — and goes on to enumerate test coverage that stops at v1.0.3 (catalog completeness, BCP-47, registry-pattern-zero) with no mention of the v1.0.7 additions.

Code actually does: v1.0.7 shipped Pester 496/0 and xUnit 113/0 per CHANGELOG (`485 -> 496` from the 11-test `Tiny11.Actions.Filesystem.NoiseSuppression.Tests.ps1`; `105 -> 113` from the 8-test `launcher/Tests/AppVersionTests.cs`). The new test files are present on disk (verified by directory listing). README's test-count headline numbers and the enumerated coverage list both pre-date v1.0.7.

Why it matters: anyone reading README expecting an at-a-glance "current test-suite size" will read 590 total when the real number is 609. The narrative also omits the v1.0.7 `AppVersionTests` and `Filesystem.NoiseSuppression.Tests` files entirely.

Suggested fix direction (doc): bump README test-counts to `496 / 113` and append two new coverage clauses ("AppVersion formatter coverage + the v1.0.7 Finding-4 takeown/icacls stderr noise-suppression guards") inside the parenthetical list. Keep the v1.0.1 `409/0` audit narrative below unchanged.

## D2 — README "29 entries for amd64, 28 for arm64" WinSxS keep-list cardinalities don't match code

**Severity:** WARNING
**Doc:** README.md:236 (Architecture and language support → Source ISO architecture)
**Code:** `src/Tiny11.Core.psm1:195-231` (amd64 list) and `:233-269` (arm64 list)

Doc claims: "Core mode auto-detects the source architecture via `dism /Get-WimInfo` and selects the right WinSxS keep-list (29 entries for amd64, 28 for arm64)."

Code actually does: counting quoted entries inside the `@(...)` arrays returned by `Get-Tiny11CoreWinSxSKeepList`, amd64 has **31 unique entries** (raw 31, no duplicates after `Select-Object -Unique`); arm64 has **33 entries** (no de-dupe pass on arm64). Both numbers are higher than the README claim. The same stale cardinalities also appear in the code comment at `Tiny11.Core.psm1:176`: `# Per architecture: amd64 (29 entries) or arm64 (28 entries).` so both surfaces are wrong together — code was extended (likely incrementally during the v1.0.3 cycle's arm64 work) without the comment / README being refreshed.

Why it matters: low impact (users don't normally care about the exact retained-subdir count), but it's a verifiable claim that doesn't hold up, and undermines confidence in the README's other architecture-section numbers.

Suggested fix direction (doc + code comment): update README:236 to `31 entries for amd64, 33 for arm64` and refresh the matching comment at `Tiny11.Core.psm1:176`. If the counts feel "off" to a future reader (e.g. arm64 surprisingly larger than amd64), audit the lists for genuine duplicates and de-dupe if warranted, then update the doc.

## D3 — README profile inventory describes `minimal-removal.json` as the OPPOSITE of what the file does

**Severity:** WARNING
**Doc:** README.md:215 (`## Profile examples` table)
**Code:** `config/examples/minimal-removal.json` (5 lines total)

Doc claims:
| `minimal-removal.json` | Conservative — removes only obvious bloat (Xbox, Solitaire, Teams chat icon), keeps everything else |

Code actually does: the profile contains only 4 `skip` entries (`remove-clipchamp`, `remove-windowsterminal`, `remove-msteams`, `remove-onedrive-setup`). Because all 74 catalog items default to `apply` (verified: `(Get-Tiny11Catalog).Items | Group-Object default` shows `apply: 74, skip: 0`), this profile *keeps* those 4 items and *still removes the other 70*. That is **maximum removal minus 4**, not "removes only obvious bloat... keeps everything else."

Why it matters: a user reading the README will pick `minimal-removal.json` expecting a conservative cut and instead get an aggressive cut. This is the most user-facing of the documentation drifts in the audit — a wrong choice here could produce an ISO meaningfully different from the user's intent.

Suggested fix direction: pick one of (a) update the README description to reflect what the file actually does ("Aggressive — keeps Clipchamp, Terminal, MSTeams, OneDrive Setup; removes everything else in the catalog"), or (b) rewrite the JSON profile to match the README description (would require an explicit "items removed" list using a JSON shape that doesn't exist today — the catalog defaults are all `apply`, so a true minimal-removal profile would need to mark ~70 items as `skip` and leave the truly-minimal targets at default `apply`). Option (a) is one line in README; option (b) is a meaningful profile rewrite. The drift is severe enough that I'd flag it as a candidate v1.0.8 fix even though it's a docs change.

## D4 — README action-type inventory misses `registry-pattern-zero`

**Severity:** WARNING
**Doc:** README.md:202 (Catalog section, "Each item has..." bullet list)
**Code:** `src/Tiny11.Catalog.psm1:3` `$ValidActionTypes = @('provisioned-appx','filesystem','registry','registry-pattern-zero','scheduled-task')`

Doc claims: "`actions` — one or more typed action records (`registry`, `provisioned-appx`, `filesystem`, `scheduled-task`)"

Code actually does: catalog loader accepts 5 action types, not 4. `registry-pattern-zero` was added in v1.0.3 (commit `0a10196`, per `CHANGELOG.md:72`) as the action type backing the `SubscribedContent-*Enabled` family removal. The CHANGELOG entry is detailed and accurate; the README's catalog-section bullet was simply never updated to match.

Why it matters: anyone adding a new catalog item by following README will not know `registry-pattern-zero` exists as an option. Coupled with O3 below (no documentation of catalog-item schema in README), this is the second-most-likely source of confusion for new catalog contributors.

Suggested fix direction (doc): add `registry-pattern-zero` to the parenthesized list at README:202 — `(registry, registry-pattern-zero, provisioned-appx, filesystem, scheduled-task)`.

## D5 — README "PowerShell 7 (`pwsh.exe`) on PATH for the GUI" is half-true for the bundled launcher

**Severity:** INFO
**Doc:** README.md:223 (System requirements bullet)
**Code:** `launcher/Gui/Handlers/BuildHandlers.cs:208,569` (`FileName = "powershell.exe"`); `launcher/Headless/HeadlessRunner.cs:96` (same)

Doc claims: "PowerShell 7 (`pwsh.exe`) on PATH for the GUI; PowerShell 5.1 (`powershell.exe`) is sufficient for scripted mode"

Code actually does: the bundled `tiny11options.exe` launcher (the recommended GUI entry-point per the rest of the README) ALWAYS spawns `powershell.exe` (Windows PowerShell 5.1) for its build subprocess. It never touches `pwsh.exe`. The README's claim about pwsh-on-PATH-for-GUI is only true for the LEGACY `pwsh -File tiny11maker.ps1` GUI entry-point (which is itself rare now — the recommended interactive path is `tiny11options.exe`).

Why it matters: a user with no PowerShell 7 installed could be told by the README they can't use the GUI, when in fact the bundled launcher needs only PS 5.1 (built into every supported Windows). Edge case (PS 5.1 is on every Win11 install by default), but a misleading requirement.

Suggested fix direction (doc): rephrase to differentiate the two GUI entry-points — "PowerShell 5.1 (built into Windows) is sufficient for `tiny11options.exe` and for scripted mode; the legacy `pwsh -File tiny11maker.ps1` GUI entry-point requires PowerShell 7 on PATH."

## D6 — CHANGELOG `[1.0.7]` says `AppVersion.cs` is "16-line"; actual is 23 lines

**Severity:** INFO
**Doc:** CHANGELOG.md:14 (`[1.0.7] ### Added` block, "(16-line static class...)")
**Code:** `launcher/Gui/AppVersion.cs` (23 lines per `wc -l`)

Doc claims: "New file `launcher/Gui/AppVersion.cs` (16-line static class with `Current()` accessor and a pure-function `Format()` for testing)."

Code actually does: the file is 23 lines including 9 lines of XML/inline comments. The substantive code is closer to 14 lines. The "16-line" claim was probably an exact pre-comment count or an approximation.

Why it matters: not at all. CHANGELOG hygiene only.

Suggested fix direction: ignore unless the CHANGELOG gets touched for an unrelated reason; mentioning "(~16 line code, 23 lines with comments)" would be the surgical fix.

---

## O1 — README does not mention `keep-edge-and-clipchamp.json` example profile

**Severity:** WARNING
**Doc:** README.md:211-216 (`## Profile examples` table — lists 3 profiles)
**Code:** `config/examples/keep-edge-and-clipchamp.json` (4 skip entries: edge, edge-webview, edge-uninstall-keys, clipchamp)

Doc claims: only three profiles in `config/examples/`: `tiny11-classic.json`, `keep-edge.json`, `minimal-removal.json`.

Code actually does: four profiles ship in `config/examples/`. The fourth (`keep-edge-and-clipchamp.json`) is the load-bearing fixture used by P8 smoke testing per CHANGELOG `[1.0.3]` (`docs/superpowers/smoke/2026-05-14-v1.0.3-catalog-and-logging-smoke.md:25` line P8 — "Worker keep-list build (`config/examples/keep-edge-and-clipchamp.json`)"). The file is committed, referenced from smoke tooling, and demonstrates a useful pattern (keep Edge AND keep one consumer app) — but the README's user-facing profile table doesn't mention it.

Why it matters: omission rather than drift — the file is real and useful, but README readers would never discover it short of `ls config/examples/`. Low-cost fix.

Suggested fix direction (doc): add a fourth row to the profile-examples table — `| keep-edge-and-clipchamp.json | Demonstrates pinning multiple keep-list items at once (used by smoke testing) |`.

## O2 — README/CHANGELOG never document the existence of `tiny11Coremaker.ps1` (the legacy upstream Core script)

**Severity:** INFO
**Doc:** README.md (entire) — no mention
**Code:** `tiny11Coremaker.ps1` (579-line legacy upstream Core builder, ported from `ntdevlabs/tiny11builder`)

Doc claims: nothing — the README discusses Core mode exclusively through the GUI ("Build modes → tiny11 Core") and the headless `tiny11Coremaker-from-config.ps1` wrapper. The original interactive `tiny11Coremaker.ps1` is silent.

Code actually does: the file still exists in the repo root and contains a workable interactive prompt-driven Core builder. It's not embedded into the launcher (verified — only `tiny11Coremaker-from-config.ps1` is in the csproj `<EmbeddedResource>` list). The legacy script appears orphaned but still runnable if a user finds it.

Why it matters: not at all for normal users — the recommended path is `tiny11options.exe` Core mode. But a power user who clones the repo and sees both `tiny11Coremaker.ps1` (interactive) and `tiny11Coremaker-from-config.ps1` (wrapper for the launcher) may be confused about which is canonical.

Suggested fix direction (doc): add a single sentence near the Core-mode README section — "The historical interactive `tiny11Coremaker.ps1` ported from upstream is retained for reference but is not the supported entry point; use `tiny11options.exe` Core mode or `tiny11Coremaker-from-config.ps1` for scripted Core builds." Or, separately, consider whether `tiny11Coremaker.ps1` should be deleted entirely as dead code (this is properly a code-cleanup question, not a docs question — out of scope here).

## O3 — README's "To add a new removal" instructions don't document the catalog-item JSON schema

**Severity:** INFO
**Doc:** README.md:204-205 ("To add a new removal: append a new item to `catalog.json` matching the schema...")
**Code:** `catalog/catalog.json` (74 items as data; schema is implied), `src/Tiny11.Catalog.psm1:35-49` (schema validation)

Doc claims: "append a new item to `catalog.json` matching the schema, run `pwsh -File tests/Run-Tests.ps1` (the catalog-loader tests will validate the schema)..."

Code actually does: the schema is enforced by `Tiny11.Catalog.psm1`'s validation but not documented anywhere in user-facing prose. A contributor must read the existing JSON entries to infer the field shapes, which fields are required, which `type` values are valid (5 — per D4), what `default` accepts (`apply` or `skip`), and what `runtimeDepsOn` does. The README's `actions` bullet at line 202 is the only place the type values are listed and it's already wrong (D4).

Why it matters: combined with D4, this is a meaningful onboarding friction for new catalog contributors. Most users won't add catalog items, but those who do will spend time figuring out the shape.

Suggested fix direction (doc): consider a small sub-section under `## Catalog` showing one annotated example item with each field labeled, e.g.:
```jsonc
{
  "id": "remove-clipchamp",                          // stable identifier; used in profile JSONs
  "category": "store-apps",                          // one of the 10 categories (see list)
  "displayName": "Clipchamp video editor",           // human-readable
  "description": "Removes the Clipchamp.Clipchamp...",
  "default": "apply",                                // 'apply' to remove, 'skip' to keep
  "runtimeDepsOn": [],                               // other item IDs locked when this is kept
  "actions": [                                       // 1+ typed action records
    { "type": "provisioned-appx", "packagePrefix": "Clipchamp.Clipchamp" }
  ]
}
```
Could be deferred to a `docs/CONTRIBUTING-CATALOG.md` if the README itself is already long.

---

## S1 — README v1.0.x version-flavor mentions are mostly historical and well-anchored, but one is stale (`v1.0.1`-era CDM limitation note)

**Severity:** INFO
**Doc:** README.md:128 (`Known limitation (v1.0.1):` paragraph in the Post-boot cleanup section)
**Code:** `CHANGELOG.md:68-72` (v1.0.3 catalog-completeness phase 1 + 2)

Doc claims (line 128): "**Known limitation (v1.0.1):** the cleanup script only re-applies what the catalog enumerates. The `tweak-disable-sponsored-apps` item currently covers 4 of the 11 canonical `ContentDeliveryManager` registry values; the other 7 (FeatureManagementEnabled, PreInstalledAppsEverEnabled, RotatingLockScreenEnabled, RotatingLockScreenOverlayEnabled, SlideshowEnabled, SoftLandingEnabled, SystemPaneSuggestionsEnabled) plus `HKLM\SOFTWARE\Policies\Microsoft\WindowsStore\AutoDownload=2` remain uncovered by the catalog and will be restored by CUs. ... Catalog completeness lands in v1.0.2."

Code actually does: v1.0.3 (NOT v1.0.2) closed the gap. CHANGELOG `[1.0.3]`:
- Phase 1: added `RotatingLockScreenEnabled`, `RotatingLockScreenOverlayEnabled`, `SlideshowEnabled`, `WindowsStore\AutoDownload=2` (commit `8896eeb`)
- Phase 2: added pattern-driven `SubscribedContent-*Enabled` coverage (commit `0a10196`) which dynamically handles the remaining CDM family at runtime

The README paragraph still reads as if the limitation is current, ending with "Catalog completeness lands in v1.0.2." This is stale — v1.0.3 already shipped it, three releases ago.

Why it matters: a user reading the v1.0.1+ heading and the "limitations" paragraph will think they're still missing protections that v1.0.3 actually deployed.

Suggested fix direction (doc): rewrite the paragraph to past-tense ("v1.0.1 shipped with this limitation; v1.0.3 closed it via two catalog-completeness phases — see CHANGELOG `[1.0.3]`"), or delete the paragraph entirely and let the v1.0.3 CHANGELOG carry the historical narrative. The latter is cleaner.

## S2 — CHANGELOG `[1.0.0] > Notes` says "Velopack delta updates begin from v1.0.1 onward"; v1.0.1 release was actually undetectable by clients per the v1.0.4 fix narrative

**Severity:** INFO
**Doc:** CHANGELOG.md:351 (`[1.0.0] **Notes:**` bullet)
**Code:** CHANGELOG.md:50 (`[1.0.4] ### Fixed` block — `releases.win.json` upload fix), CHANGELOG.md:291 (B3 fix in `[1.0.1]` "Audit-verified test count chain")

Doc claims: "v1.0.0 is the first Path C release; no prior bundled `.exe` exists, so Velopack delta updates begin from v1.0.1 onward."

Code actually does: per the v1.0.4 CHANGELOG, every release shipped before v1.0.4 was actually undetectable by the auto-update client because `releases.win.json` was filtered out of the GitHub Release asset glob. The B3 fix in `[1.0.1]` also added the `<Version>` element to csproj, but the manifest-upload gap continued through v1.0.3. So while v1.0.1 was the *intended* first delta-update target, in practice the chain didn't work until v1.0.4 landed.

Why it matters: a user reading `[1.0.0] Notes` linearly with no v1.0.4 context will conclude delta updates worked from v1.0.1 onward. The v1.0.4 fix narrative does correct this in its own block, but the v1.0.0 footnote is technically stale.

Suggested fix direction (doc): add a one-line forward-reference in `[1.0.0] Notes` — "(see `[1.0.4]` for a post-shipping correction: the manifest-upload bug meant v1.0.0–v1.0.3 actually shipped as direct-download-only.)" Low priority — historical-narrative cleanup.

## S3 — `docs/release-signing-setup.md` Status banner says "v1.0.0 ships unsigned; code signing is scheduled for v1.0.2"; v1.0.7 is current and still unsigned

**Severity:** WARNING
**Doc:** `docs/release-signing-setup.md:3-5` (the "Status (2026-05-12)" admonition at the top)
**Code:** `.github/workflows/release.yml` (not directly read here, but referenced by the doc as gating signing on `env.AZURE_TENANT_ID != ''`), index.md (current state: "v1.0.8 cycle = Microsoft Trusted Signing only (5 GitHub Action secrets)")

Doc claims: "**Status (2026-05-12):** **v1.0.0 ships unsigned; code signing is scheduled for v1.0.2.**" with a forward-looking promise that signing lands in v1.0.2.

Code actually does: per the audit index.md, v1.0.7 is the current release (post-2026-05-15) and signing has NOT yet landed — the v1.0.8 cycle is specifically Trusted Signing only. So the signing didn't slip just one release; it slipped from v1.0.2 to v1.0.8 (5 release cycles). The status banner is materially out of date.

Also stale within this doc: section `5a. Push a smoke tag` references checking out `feat/path-c-launcher` (the v1.0.0-era branch). That branch is long-merged.

Why it matters: this doc will be executed against during the v1.0.8 cycle (per audit brief: "v1.0.8 cycle will execute against this; flag any staleness now"). A user starting Part 0 will see the v1.0.2 timeline and may be confused about whether the doc reflects current intent. Beyond that, the `feat/path-c-launcher` branch reference will trip the smoke tag instructions — that branch may or may not still exist locally for the user.

Suggested fix direction (doc): refresh the Status banner to "**Status (2026-05-15):** v1.0.0 through v1.0.7 all shipped unsigned; signing is scheduled for v1.0.8 (deferred through 5 release cycles for unrelated reasons). The signing wiring in `.github/workflows/release.yml` is dormant pending the 5 secrets in Part 4 — once those land, the next tag push produces signed binaries automatically." Also update the smoke-tag branch in `5a` to `main` (or whatever the working v1.0.8 branch will be).

## S4 — README "v1.0.3 cycle matrix" + "v1.0.1 baseline" smoke-test reference paths are accurate; one reference is to a smoke doc still useful but no longer current

**Severity:** INFO
**Doc:** README.md:289 (`Build path and ISO install are smoke-tested via two documented matrices:` paragraph)
**Code:** `docs/superpowers/smoke/2026-05-12-post-boot-cleanup-smoke.md` (v1.0.1 baseline), `docs/superpowers/smoke/2026-05-14-v1.0.3-catalog-and-logging-smoke.md` (v1.0.3 — current most-recent)

Doc claims: smoke-tested via the v1.0.1 baseline (P1-P9 all PASS) and the v1.0.3 cycle matrix (P1-P9 + A11-I3-S2 + A13-S1..S4 all PASS).

Code actually does: both doc files exist and match the README's claimed contents (verified by reading both — P1-P9 statuses in the v1.0.1 doc, P1-P9 + 6 additive cases in the v1.0.3 doc). The README correctly identifies v1.0.3 as "most recent." v1.0.4 / v1.0.5 / v1.0.6 / v1.0.7 did not add smoke matrices; v1.0.7 specifically was about UI version-display + stderr suppression and didn't change the build path.

So this isn't a drift per se, but flagging because: if v1.0.8 ships a Trusted-Signing-only release without a new smoke matrix, the README will continue to point at v1.0.3 — fine, but worth re-checking at v1.0.8 ship time. Mark as STALE in the bookkeeping sense (the reference may continue to age) rather than DRIFT (the claim is currently accurate).

Suggested fix direction: no action needed at v1.0.8 unless v1.0.8 adds new smoke coverage.

---

## I1 — README's claim "10 categories, ~74 items" matches code exactly

**Severity:** INFO (no action)

Verified: `catalog/catalog.json` has 74 items and 10 distinct categories (`store-apps`, `xbox-and-gaming`, `communication`, `edge-and-webview`, `onedrive`, `telemetry`, `sponsored`, `copilot-ai`, `hardware-bypass`, `oobe`). Both `.items.Count` and the `category` enumeration confirmed via PowerShell. README:9, 195, 257 references all consistent. The `~74` framing is also kind in case a future catalog adds or removes a single item.

## I2 — README exit-code table matches launcher code exactly

**Severity:** INFO (no action)

Verified: README:113 lists exit codes 0/1/2/10/11/12/13.

| Code | Source | Verified |
|---|---|---|
| 0 | Process exit, success | `Program.cs:46`, `HeadlessRunner.cs:131` |
| 2 | Architecture rejection | `Program.cs:32` |
| 10 | Resource extraction failure | `HeadlessRunner.cs:59` |
| 11 | powershell.exe not on PATH (Win32Exception) | `HeadlessRunner.cs:138` |
| 12 | Invalid `--log` / `--append` argument | `HeadlessArgs.cs:48,59,77` → `HeadlessRunner.cs:47` |
| 13 | Log file could not be opened | `HeadlessRunner.cs:90` |

Code 1 (build failure) is not a launcher-emitted code per se — it's the wrapper script's `exit 1` propagated through `proc.ExitCode` at `HeadlessRunner.cs:131`. README framing is correct.

## I3 — README `tiny11maker.ps1 .PARAMETER` block matches the README's "Documented flags include..." list

**Severity:** INFO (no action)

Verified: `tiny11maker.ps1:11-43` has `.PARAMETER` stanzas for `Source`, `Config`, `ImageIndex`, `Edition`, `ScratchDir`, `OutputPath`, `NonInteractive`, `FastBuild`, `NoPostBootCleanup`, `Internal`. README:91-95 lists exactly the same user-facing surface (Source / Edition / ImageIndex / Config / OutputPath / NonInteractive / FastBuild / NoPostBootCleanup) with `Internal` correctly omitted as it's a test-only flag. `Get-Help .\tiny11maker.ps1 -Detailed` will produce output consistent with the README.

## I4 — README "post-boot cleanup task" feature description matches `Tiny11.PostBoot.psm1` code

**Severity:** INFO (no action)

Verified:
- README:124 "Logged to `C:\Windows\Logs\tiny11-cleanup.log` (5000-line rolling, ~3 months of history)" → `Tiny11.PostBoot.psm1:23` (`$logPath`) and `:31` (`if ($lineCount -ge 5000)`).
- README:125 "Runs as **SYSTEM** at boot + daily + on every WU EventID 19. Default execution time limit 30 minutes." → `Tiny11.PostBoot.psm1:416-462` (XML with `<UserId>S-1-5-18</UserId>`, BootTrigger PT10M, CalendarTrigger 03:00, EventTrigger EventID=19, `<ExecutionTimeLimit>PT30M</ExecutionTimeLimit>`).
- README:128 "loads `C:\Users\Default\NTUSER.DAT` into a transient `HKU:\tiny11_default` mount, writes through it, and unloads" → `Tiny11.PostBoot.psm1:67-79` (load logic), `:320` (unload).

## I5 — README "Build logging (v1.0.3+)" section accurately matches `HeadlessArgs.cs` + `BuildLogPathResolver.cs`

**Severity:** INFO (no action)

Verified:
- README:100 "Both space-form (`--log out.log`) and equals-form (`--log=out.log`) are accepted." → `HeadlessArgs.cs:42` (equals form) and `:54` (space form).
- README:101 "Using `--append` without `--log` is a parse error (exit 12)." → `HeadlessArgs.cs:74-78` (rejection) and `HeadlessRunner.cs:47` (exit 12).
- README:101 "Lowercase only." → `HeadlessArgs.cs:42,54,65` all use `StringComparison.Ordinal` / direct `==` comparisons, no `OrdinalIgnoreCase`.
- README:103 "Headless logging is opt-in" → `HeadlessRunner.cs:71` (`if (parsed.LogPath != null)` — no log writer when no `--log`).

## I6 — README's "pwsh-from-pwsh invocation" gate logic matches `tiny11maker.ps1` code exactly

**Severity:** INFO (no action)

Verified: README:269-277 lists 5 working invocations and 1 blocked. The script's gate at `tiny11maker.ps1:100-122` checks `$PSVersionTable.PSEdition -eq 'Core'` AND parent process name == `pwsh`. The 5/1 split holds:
- `cmd → powershell`: PSEdition=Desktop, skipped
- `cmd → pwsh`: PSEdition=Core, parent=cmd, passes
- `powershell → powershell`: PSEdition=Desktop
- `powershell → pwsh`: PSEdition=Core, parent=powershell, passes
- `pwsh → powershell`: PSEdition=Desktop
- `pwsh → pwsh`: PSEdition=Core, parent=pwsh, BLOCKED at `Tiny11maker.ps1:107-121`

Three of the workarounds in the error message are also accurate (cmd, powershell, the deferred Path C launcher reference is now actual: `tiny11options.exe`).

## I7 — `tiny11options.Launcher.csproj` `<Version>1.0.7</Version>` matches `app.manifest` `version="1.0.7.0"` and CHANGELOG

**Severity:** INFO (no action)

Verified: `tiny11options.Launcher.csproj:12` has `<Version>1.0.7</Version>`; `app.manifest:3` has `assemblyIdentity version="1.0.7.0"`. CHANGELOG `[1.0.7]` exists and is the most-recent versioned section. The csproj inline comment (`<!-- Version: keep in sync with app.manifest's assemblyIdentity version. ... -->`) correctly documents the cross-file invariant. This was the B3 fix from v1.0.1's audit; the discipline has held through five releases.

---

## Aggregate verdict

The README is the primary documentation drift surface — six of the six WARNING-class findings live there, and all are fixable in single-paragraph edits. The CHANGELOG `[1.0.7]` block is accurate against code where verifiable (file counts, test counts, scope of changes); only one INFO-class drift (D6) found there. The release-signing setup doc has a Status header three releases behind reality — actionable in the v1.0.8 cycle.

No security-relevant claim is missing from code: the post-boot cleanup behavior, the architecture gate, the pwsh-from-pwsh block, the exit-code surface, and the launcher embedded-resource shape all match what the docs promise.

Highest-value v1.0.8 docs touchups, in priority order:
1. **D3** (`minimal-removal.json` description is the opposite of what the file does — user-facing footgun).
2. **D1** (test counts and coverage narrative one release behind).
3. **D2** (WinSxS keep-list cardinalities; also fix the matching comment in `Tiny11.Core.psm1:176`).
4. **S3** (release-signing-setup.md Status header pre-v1.0.8 wait).
5. **D4** (`registry-pattern-zero` missing from action-type list).
6. **O1** (`keep-edge-and-clipchamp.json` not in profile table).

The rest are I-class informational and can ride alongside any future docs touch.
