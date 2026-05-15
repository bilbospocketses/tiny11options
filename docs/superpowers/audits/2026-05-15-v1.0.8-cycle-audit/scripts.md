# Audit: Top-level scripts + test harness (v1.0.8 cycle)

**Date:** 2026-05-15
**Scope:** *.ps1 at repo root + tests/*.ps1 + tests/Tiny11.TestHelpers.psm1 + tests/golden/regen-helpers-fixture.ps1
**Branch:** main at `285f7b6` (post-v1.0.7)
**Auditor:** parallel subagent (no session context)

## Summary

- BLOCKER: 0
- WARNING: 4
- INFO: 7

---

## A1 — `tiny11maker.ps1` self-elevation drops admin-relaunch exit code; parent process exits 0 before child finishes

**Severity:** WARNING
**File:** `tiny11maker.ps1:89-95,124-127`

`Invoke-SelfElevate` calls `Start-Process -FilePath $pwshPath -ArgumentList $argString -Verb RunAs` with no `-Wait`, then the caller does `exit` (no exit code -- so $LASTEXITCODE or implicit 0). The relaunched elevated process is a wholly separate process, the parent terminates immediately, and headless callers (`tiny11options.exe` HeadlessRunner, CI scripts) cannot observe the build's actual exit status. If the elevated build fails, `tiny11maker.ps1`'s parent process has already returned 0. The README's "Headless via `tiny11options.exe`" section claims documented exit codes (`0 success, 1 build failure`) that the launcher's HeadlessRunner forwards from the script -- the self-elevation path silently breaks that contract when the user has not pre-elevated.

In practice the launcher always invokes the script with `-NonInteractive` but does NOT pre-elevate (`BuildHandlers.cs` and `HeadlessRunner.cs` rely on the script's self-elevation). So the contract relies on the user already being admin. If they aren't, the launcher's exit code says "0 / success" even when the elevated child build failed.

**What/Why/Fix:** Either (a) add `-Wait -PassThru` to `Start-Process`, capture `$proc.ExitCode`, and `exit $proc.ExitCode` so the parent surfaces the child's exit code; or (b) document that headless invocations MUST pre-elevate (and refuse to self-elevate in `-NonInteractive` mode, throwing instead). README claims exit-code propagation; the code doesn't deliver it through the UAC boundary.

---

## A2 — `Build-RelaunchArgs` serializes any non-`[switch]` value with naive `"$val"` interpolation; arrays and objects mangle

**Severity:** WARNING
**File:** `tiny11maker.ps1:66-81`

```powershell
foreach ($entry in $Bound.GetEnumerator()) {
    if ($entry.Key -eq 'Internal') { continue }
    $val = $entry.Value
    if ($val -is [switch]) {
        if ($val.IsPresent) { $parts += "-$($entry.Key)" }
    } else {
        $parts += "-$($entry.Key)"
        $parts += "`"$val`""
    }
}
```

If a future param ever becomes an array (e.g. `[string[]]$Editions`), `"$val"` produces a space-joined string like `"Pro Home"` which the relaunched script parses as the single-string value `Pro Home`. Same risk for `[hashtable]` (renders as `System.Collections.Hashtable`) or any custom object lacking a useful `ToString()`. Current param block is all scalar `[string]`/`[int]`/`[switch]` so no live bug; this is a footgun for v1.0.x parameter growth. The existing `Tiny11.Orchestrator.Tests.ps1` only exercises the `[string]` + `[switch]` cases (lines 1-15) and would not catch an array regression.

Also: paths containing literal `"` characters (rare but legal on NTFS) will produce broken arg strings because the wrapper hardcodes `"`"$val`""` with no escape. The README's "Source accepts an .iso path" doesn't forbid quoted paths.

**Fix:** Add type-aware serialization (`if ($val -is [array]) { foreach ... } elseif ($val -contains '"') { error or escape }`), and add a regression test for the array case in `Tiny11.Orchestrator.Tests.ps1`.

---

## A3 — README test-count claim is stale: states "485 Pester / 105 xUnit" but CHANGELOG v1.0.7 ships 496 / 113

**Severity:** WARNING
**File:** `README.md:285` (line `485 Pester tests ... 105 xUnit launcher tests`); `CHANGELOG.md:27-28` (`Pester: 485/0 -> 496/0 (+11); xUnit: 105/0 -> 113/0 (+8)`)

The README's "Running tests" paragraph hardcodes the v1.0.3 test counts (`485 Pester ... 105 xUnit launcher tests`) and lists v1.0.3 coverage areas (`v1.0.3 BCP-47 language regex coverage`, `v1.0.3 registry-pattern-zero action-type coverage from catalog completeness phase 2`) but does not mention v1.0.7's `+11 Pester` (noise suppression file `Tiny11.Actions.Filesystem.NoiseSuppression.Tests.ps1`) or `+8 xUnit` (`AppVersionTests`). This is technically in the docs-consistency-agent scope, but the test harness is the source-of-truth source for the running totals.

`tests/Run-Tests.ps1` does not export the actual count anywhere durable; the count exists only in the live Pester run output and in CHANGELOG. README's claim becomes stale every release.

**Fix (test-harness side):** add a Pester guard test (e.g. `Tiny11.ReleaseWorkflow.Tests.ps1`-class) that parses the README's claim and asserts it matches `Invoke-Pester ... -PassThru | %{ $_.PassedCount }`. The repo already has tests that grep README for specific strings (cf. `Tiny11.UiApp.Cleanup.Tests.ps1`); a count-parity guard is symmetric.

**Fix (README side):** flagged to the docs-consistency agent in this same audit batch.

---

## A4 — `tiny11-iso-validate.ps1` hardcodes `-MountedByUs:$true` on the dismount call instead of forwarding `$mountResult.MountedByUs`

**Severity:** WARNING
**File:** `tiny11-iso-validate.ps1:33-38`

```powershell
finally {
    if ($mountResult.MountedByUs) {
        Dismount-Tiny11Source -IsoPath $IsoPath -MountedByUs:$true -ForceUnmount:$true
    }
}
```

The outer `if ($mountResult.MountedByUs)` correctly gates the dismount, so the hardcoded `$true` arg below is currently safe. But it deviates from the GUI handler pattern in `tiny11maker.ps1:191` which correctly forwards `$r.MountedByUs` from the Mount result:

```powershell
Dismount-Tiny11Source -IsoPath $r.IsoPath -MountedByUs:$r.MountedByUs -ForceUnmount:$true
```

If the outer guard is ever loosened (e.g. someone removes the `if` block to make dismount always-call) the hardcoded `$true` becomes a latent contract violation. Also: the script passes `$IsoPath` (the script's input parameter) instead of `$mountResult.IsoPath` (the resolved-by-Mount path), which is fine for `.iso` file inputs but cosmetically wrong for the drive-letter case (which doesn't reach this branch, but the symmetry is worth maintaining).

**Fix:** Replace `-MountedByUs:$true` with `-MountedByUs:$mountResult.MountedByUs` and `-IsoPath $IsoPath` with `-IsoPath $mountResult.IsoPath`, matching the GUI handler's shape verbatim.

---

## I1 — `tiny11Coremaker-from-config.ps1` uses `Set-StrictMode -Version Latest` while `tiny11-cancel-cleanup.ps1` uses `'Continue'` ErrorActionPreference; inconsistent across wrappers

**Severity:** INFO
**File:** `tiny11Coremaker-from-config.ps1:31-32`, `tiny11maker-from-config.ps1:28-29`, `tiny11maker.ps1:58-59`, `tiny11-cancel-cleanup.ps1:51-52`, `tiny11-iso-validate.ps1:4-5`, `tiny11-profile-validate.ps1:15-16`

All six top-level scripts apply Set-StrictMode + ErrorActionPreference, but in non-identical combinations:

| Script | StrictMode | ErrorActionPreference | Rationale |
|---|---|---|---|
| `tiny11maker.ps1` | `Latest` | `Stop` | main orchestrator |
| `tiny11maker-from-config.ps1` | `Latest` | `Stop` | matches main |
| `tiny11Coremaker-from-config.ps1` | `Latest` | `Stop` | matches main |
| `tiny11-iso-validate.ps1` | `Latest` | `Stop` | matches main |
| `tiny11-profile-validate.ps1` | `Latest` | `Stop` | matches main |
| `tiny11-cancel-cleanup.ps1` | `Latest` | `Continue` | intentional -- per-step best-effort cleanup |

The cancel-cleanup `Continue` choice is documented in the file header (`Each non-fatal step is best-effort`), and that's the right call for that script. But the choice isn't called out in any cross-file SOP / convention doc; a future contributor adding a 7th script may not know which pattern to adopt.

**Severity: INFO** -- no current bug. Worth a one-line README sentence ("script-side error semantics are Stop except for the cleanup recovery script") or a `docs/superpowers/specs/` style memo.

---

## I2 — `tiny11Coremaker-from-config.ps1` initializes `$logPath = $null` outside `try` but doesn't initialize `$preflightMount` similarly

**Severity:** INFO
**File:** `tiny11Coremaker-from-config.ps1:43-44,86`

```powershell
$logPath = $null   # declared at script scope so catch can ref it

try {
    ...
    $preflightMount = Mount-Tiny11Source -InputPath $Source
    try {
        ...
    } finally {
        if ($preflightMount.MountedByUs) { ... }
    }
```

Under `Set-StrictMode -Version Latest`, `$preflightMount` in the `finally` would throw "variable not set" if `Mount-Tiny11Source` itself threw before the assignment landed. The throw would be caught by the outer try/catch (line 136), but the `finally` block would also have already executed -- and a StrictMode reference to an unset variable is a terminating error itself, so it would mask the original Mount failure.

The pattern works because Mount-Tiny11Source either succeeds (assigns) or throws (skips the rest of the inner try, but Set-StrictMode terminating-error semantics on `if ($preflightMount.MountedByUs)` would re-throw a different, less informative error from the finally block).

`tiny11maker-from-config.ps1:79-91` has the same shape but doesn't initialize anything outside try; same latent risk.

**Severity: INFO** -- requires Mount-Tiny11Source to throw between entering the wrapper try and assigning `$preflightMount`. Mount-Tiny11Source's only throw paths are after the assignment in practice, so the risk is theoretical. Worth noting if any future Mount-Tiny11Source refactor adds an early throw.

---

## I3 — `tiny11maker.ps1` GUI runspace inline scriptblock duplicates `Import-Module` calls that the parent already loaded

**Severity:** INFO
**File:** `tiny11maker.ps1:60-64,257-264`

The parent process imports modules at lines 60-64 (`Tiny11.Catalog`, `Tiny11.Selections`, `Tiny11.Hives`, `Tiny11.Actions`, `Tiny11.Iso`, `Tiny11.Autounattend`, `Tiny11.Worker`) into the main runspace. The GUI build worker (lines 247-285) creates a NEW runspace and the worker scriptblock re-imports `Tiny11.Worker.psm1` + `Tiny11.Bridge.psm1` (lines 260-261). Reasonable -- the new runspace is module-isolated.

But: `Tiny11.Catalog.psm1` is read INTO the worker via `$rs.SessionStateProxy.SetVariable('__catalog', $catalog)` (line 249), which copies the in-memory pscustomobject -- the worker never imports `Tiny11.Catalog.psm1`. If the build pipeline ever calls a `Tiny11.Catalog` cmdlet on the runspace side (e.g. to re-validate), it will fail with CommandNotFound.

`Tiny11.Worker.psm1` does NOT currently call any Catalog functions on the worker side -- it consumes the prebuilt $Catalog/$ResolvedSelections by-value. So this is a latent contract that's currently held by-design; not a bug.

**Severity: INFO** -- worth a comment on line 257-264 noting "worker runspace does NOT load Tiny11.Catalog; downstream pipeline consumes prebuilt catalog by-value".

---

## I4 — `Test-IsAdmin` uses `WindowsIdentity.GetCurrent()` + `WindowsBuiltInRole::Administrator`; correct but unrelated to UAC token state

**Severity:** INFO
**File:** `tiny11maker.ps1:83-87`

The check answers "is the current process running as a member of the local Administrators group" -- which is the right answer for *elevation* detection. It does NOT distinguish "user is in Administrators group but running with a filtered (non-elevated) token" from "user is in Administrators group and running with full elevation". On Windows 11 with UAC enabled, those two cases have IDENTICAL Test-IsAdmin output but RADICALLY different DISM-can-mount-WIM behavior.

In practice this isn't a problem because `Invoke-SelfElevate` uses `-Verb RunAs` which forces a full elevation regardless of the original token; the script's flow is:

1. User starts in non-admin shell → `Test-IsAdmin` returns false → `Invoke-SelfElevate` fires → new process is elevated → `Test-IsAdmin` returns true on the relaunched copy.
2. User starts in admin shell (elevated) → `Test-IsAdmin` returns true → proceeds.

The edge case I'm calling out: if a future user somehow ends up in a shell where they're in the Administrators group but the process is NOT elevated (rare with default UAC), `Test-IsAdmin` returns true, the elevation flow is skipped, and DISM operations fail mid-build with permission errors. Mitigation already exists implicitly via Windows 11's default UAC behavior.

**Severity: INFO** -- worth one comment on line 83 noting the limitation. No current bug.

---

## I5 — `Build-RelaunchArgs` includes `[CmdletBinding()]` but is never called via cmdlet-binding semantics (no `-Verbose`/`-ErrorAction` needed)

**Severity:** INFO
**File:** `tiny11maker.ps1:66-67`

```powershell
function Build-RelaunchArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Bound, [Parameter(Mandatory)][string]$ScriptPath)
```

`[CmdletBinding()]` adds `-Verbose`/`-Debug`/`-ErrorAction`/`-ErrorVariable`/etc. common parameters. The function is a pure string-building helper called once from `Invoke-SelfElevate`; none of those parameters are exercised. Harmless, but inconsistent with `Test-IsAdmin` (line 83) and `Invoke-SelfElevate` (line 89) which use plain `function name { param(...) }` form.

**Severity: INFO** -- cosmetic.

---

## I6 — `tests/Run-Tests.ps1` does not write a Pester result file; CI / smoke audits cannot inspect failures programmatically

**Severity:** INFO
**File:** `tests/Run-Tests.ps1:1-9`, `tests/Tiny11.PesterConfig.ps1:1-7`

```powershell
$config.TestResult.Enabled = $false
```

`Run-Tests.ps1` exits with 0/1 only; no JUnit/NUnit XML, no .json result, no per-test breakdown surfaceable to downstream tooling. The README's smoke-doc claims (`P1-P9 all PASS`) cannot be re-derived from a fresh `Invoke-Pester` run without parsing live stdout. CHANGELOG counts (the source of truth for the 485 -> 496 transition) are maintained by hand.

CI (`.github/workflows/release.yml`) presumably grabs the exit code only. Future cycles where someone needs to bisect a failure (cf. "Audit-verified Pester test count chain" in CHANGELOG.md:194-200) would benefit from XML output.

**Severity: INFO** -- recommend (when CI cycle next visits this) enabling `$config.TestResult.Enabled = $true; $config.TestResult.OutputPath = "$PSScriptRoot/test-results.xml"` and adding the file to release-artifact upload.

---

## I7 — Test-harness mock-scoping discipline is uniformly correct; no Pester 5 `-ModuleName` bleed observed across 58 occurrences in 10 files

**Severity:** INFO (positive finding)
**Files:** `tests/Tiny11.Actions.Tests.ps1`, `tests/Tiny11.Actions.Filesystem.Tests.ps1`, `tests/Tiny11.Actions.ProvisionedAppx.Tests.ps1`, `tests/Tiny11.Actions.Registry.Tests.ps1`, `tests/Tiny11.Autounattend.Tests.ps1`, `tests/Tiny11.Core.Tests.ps1`, `tests/Tiny11.Hives.Tests.ps1`, `tests/Tiny11.Iso.Tests.ps1`, `tests/Tiny11.WebView2.Tests.ps1`, `tests/Tiny11.Worker.Tests.ps1`

All 58 `Mock` invocations across the in-scope test files specify `-ModuleName` explicitly (verified via `Grep`). The Pester 5 footgun where mocks bleed between Describe blocks without per-module scoping is NOT present. Notable disciplined patterns:

- `tests/Tiny11.Iso.Tests.ps1:27-46` mocks `Mount-DiskImage`/`Get-Tiny11VolumeForImage`/`Get-DiskImage`/`Get-WindowsImage`/`Test-Path` all with `-ModuleName 'Tiny11.Iso'`.
- `tests/Tiny11.Worker.Tests.ps1:7` explicitly imports `Tiny11.Actions` alongside `Tiny11.Worker` so the post-A11/v1.0.3 module-move (`Get-Tiny11ApplyItems`/`Invoke-Tiny11ApplyActions` migrated to Actions) keeps `Mock -ModuleName` scope correct -- the comment at lines 3-7 calls out the exact reason.
- `tests/Tiny11.Core.Tests.ps1:290-330,340-565` uses `InModuleScope 'Tiny11.Core'` blocks to scope mocks to internal/non-exported functions cleanly.

`tests/Tiny11.Worker.PostBootImport.IntegrationTests.ps1` even reverses the discipline -- it deliberately *clears* prior modules with `Get-Module Tiny11.* | Remove-Module -Force` (line 24) so the cascade-demotion B10 regression guard exercises a true fresh-load chain.

**Severity: INFO** (positive) -- no fix needed; serves as confirmation that the v1.0.1 -> v1.0.7 cycle's mock-scoping refactors have stuck.

---

## Cross-reference matrix (script claims vs code)

| Source of claim | Claim | File:LINE in code | Verified? |
|---|---|---|---|
| README "Scripted" | `cmd /c pwsh ...` form dodges pwsh-from-pwsh gate | `tiny11maker.ps1:100-122` | YES -- parent-name check on `pwsh` only; cmd as parent passes |
| README "Headless via tiny11options.exe" | `-NoPostBootCleanup` documented in tiny11maker.ps1 .PARAMETER block | `tiny11maker.ps1:36-39` | YES |
| README "Architecture and language support" | Workaround `pwsh -File tiny11maker.ps1` works on arm64 | `tiny11maker.ps1:1-301` | YES -- no arch gate in the script |
| README "Known caveat -- pwsh-from-pwsh invocation" | Five working invocation patterns, one blocked | `tiny11maker.ps1:99-122` | YES -- gate only fires when both parent AND child are pwsh |
| README "Running tests" | `pwsh -NoProfile -File tests/Run-Tests.ps1` | `tests/Run-Tests.ps1:1-9` | YES |
| README "Running tests" | 485 Pester / 105 xUnit | `CHANGELOG.md:27-28` shows 496/113 | **NO -- stale, see A3** |
| CHANGELOG `[1.0.7]` | NoiseSuppression test file lands `+11 Pester` | `tests/Tiny11.Actions.Filesystem.NoiseSuppression.Tests.ps1` | EXISTS (file present, count not re-derived in this audit) |
| CHANGELOG `[1.0.2] A3` | wrapper params `[switch]$NoPostBootCleanup` -- mixed `[bool]+[switch]` pattern dropped | `tiny11maker.ps1:54`, `tiny11maker-from-config.ps1:25`, `tiny11Coremaker-from-config.ps1:28` | YES -- all three wrappers use `[switch]` only |
| CHANGELOG `[1.0.2] A3` | `Get-Help` shows `.PARAMETER NoPostBootCleanup` | `tiny11maker.ps1:36-39` | YES |
| CHANGELOG `[1.0.2] B11 doc` | tiny11maker.ps1 launcher passthrough flags `-FastBuild` / `-NoPostBootCleanup` | `tiny11maker.ps1:33-39,53-54` | YES |
| `.PARAMETER NoPostBootCleanup` block claim | "Once the ISO is built, build-time choices are baked in for the life of the ISO" | `tiny11maker.ps1:38-39` | YES (consistent with README "Choose carefully" section) |
| `tiny11-cancel-cleanup.ps1` Step 1 hive list | unloads zCOMPONENTS / zDEFAULT / zNTUSER / zSOFTWARE / zSYSTEM | `tiny11-cancel-cleanup.ps1:84-87` | YES (test `Tiny11.CancelCleanup.Tests.ps1:112-149` is the lockstep parity guard) |
| `tiny11-cancel-cleanup.ps1` defensive guard | refuses if OutputIso falls inside MountDir/SourceDir | `tiny11-cancel-cleanup.ps1:63-75` | YES (test `Tiny11.CancelCleanup.Tests.ps1:86-96`) |
| `tiny11-profile-validate.ps1` shape | flattens `{id: {ItemId, State}}` -> `{id: state}` | `tiny11-profile-validate.ps1:32-33` | YES (mirrors `tiny11maker.ps1:237-239` legacy flatten loop) |

---

## What was read directly

| File | Lines verified |
|---|---|
| `tiny11maker.ps1` | Full (1-301) |
| `tiny11maker-from-config.ps1` | Full (1-141) |
| `tiny11Coremaker-from-config.ps1` | Full (1-150) |
| `tiny11-iso-validate.ps1` | Full (1-46) |
| `tiny11-profile-validate.ps1` | Full (1-43) |
| `tiny11-cancel-cleanup.ps1` | Full (1-152) |
| `tests/Run-Tests.ps1` | Full (1-9) |
| `tests/Tiny11.PesterConfig.ps1` | Full (1-7) |
| `tests/Tiny11.TestHelpers.psm1` | Full (1-19) |
| `tests/golden/regen-helpers-fixture.ps1` | Full (1-11) |
| `tests/Tiny11.Wrappers.Tests.ps1` | Full (1-106) |
| `tests/Tiny11.CancelCleanup.Tests.ps1` | Full (1-195) |
| `tests/Tiny11.ProfileValidate.Tests.ps1` | Full (1-87) |
| `tests/Tiny11.ScriptEncoding.Tests.ps1` | Full (1-77) |
| `tests/Tiny11.Orchestrator.Tests.ps1` | Full (1-15) |
| `tests/Tiny11.Harness.Tests.ps1` | Full (1-7) |
| `tests/Tiny11.Iso.Tests.ps1` | Full (1-71) |
| `tests/Tiny11.Worker.Tests.ps1` | Full (1-108) |
| `tests/Tiny11.Catalog.Tests.ps1` | Full (1-129) |
| `tests/Tiny11.Worker.PostBootImport.IntegrationTests.ps1` | Full (1-94) |
| `tests/Tiny11.Selections.Tests.ps1` | Full (1-96) |
| `tests/Tiny11.Actions.Tests.ps1` | Full (1-55) |
| `tests/Tiny11.Actions.Filesystem.Tests.ps1` | Full (1-34) |
| `tests/Tiny11.Bridge.Tests.ps1` | Full (1-27) |
| `tests/Tiny11.Hives.Tests.ps1` | Full (1-37) |
| `tests/Tiny11.WebView2.Tests.ps1` | Full (1-78) |
| `tests/Tiny11.Autounattend.Tests.ps1` | Full (1-51) |
| `tests/Tiny11.UiApp.Cleanup.Tests.ps1` | Full (1-261) |
| `tests/Tiny11.Core.Tests.ps1` | Lines 1-1139 (full) |
| `src/Tiny11.Iso.psm1` | Lines 1-79 (full) |
| `src/Tiny11.Worker.psm1` | Lines 13-52 (Invoke-Tiny11BuildPipeline signature + entry) |
| `README.md` | Lines 1-311 (full) |
| `CHANGELOG.md` | Lines 1-200 (Unreleased + [1.0.7] + [1.0.6] + [1.0.5] + [1.0.4] + [1.0.3] + [1.0.2] partial) |

### Cross-check Mock-scope discipline (Pester 5 -ModuleName usage)

| File | Mock count | All scoped? |
|---|---|---|
| `tests/Tiny11.Actions.Registry.Tests.ps1` | 1 | YES |
| `tests/Tiny11.Actions.Tests.ps1` | 5 | YES |
| `tests/Tiny11.Actions.ProvisionedAppx.Tests.ps1` | 4 | YES |
| `tests/Tiny11.Actions.Filesystem.Tests.ps1` | 2 | YES |
| `tests/Tiny11.Core.Tests.ps1` | 34 (all inside `InModuleScope 'Tiny11.Core'`) | YES |
| `tests/Tiny11.Autounattend.Tests.ps1` | 1 | YES |
| `tests/Tiny11.Hives.Tests.ps1` | 1 | YES |
| `tests/Tiny11.Iso.Tests.ps1` | 5 | YES |
| `tests/Tiny11.Worker.Tests.ps1` | 2 (both `-ModuleName 'Tiny11.Actions'` post-A11 move) | YES |
| `tests/Tiny11.WebView2.Tests.ps1` | 3 | YES |
| **Total** | **58** | **YES** |

No Pester 5 mock-bleed bugs surfaced.

### UNCERTAIN items

- A1 severity (WARNING vs BLOCKER): if the launcher-headless path always pre-elevates via `tiny11options.exe`'s `app.manifest`, the parent-exits-0-before-child-finishes path is not reachable for the documented headless invocation. The launcher's app.manifest is OUT OF SCOPE for this audit (launcher agent). If the launcher pre-elevates, A1 downgrades to INFO. Flagged WARNING here based on the README's Scripted-section guidance (`pwsh -NoProfile -File tiny11maker.ps1 ...`) which is a direct-script invocation not gated by launcher pre-elevation.

- A3 categorization (in the scripts audit vs docs-consistency audit): the README test-count claim is in the docs-consistency-agent scope per `index.md`, but the underlying data structure (Pester result + count discipline) is in scripts scope. Flagged here because the fix involves a guard test in the test harness; the docs-consistency agent will independently surface the README drift.
