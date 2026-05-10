# Coremaker paraphrase audit — 2026-05-10

## Purpose

Bring `Invoke-Tiny11CoreBuildPipeline` (and the rest of `src/Tiny11.Core.psm1`) into compliance — retroactively — with `feedback_legacy_port_section.md` (revision 2026-05-10), which requires literal upstream transcription with deltas as explicit diff hunks rather than paraphrase.

Plan Task 12 of `docs/superpowers/plans/2026-05-07-path-c-bundled-launcher.md` was implemented by paraphrasing `tiny11Coremaker.ps1` rather than transcribing it. Phase 7 C2 has surfaced four runtime errors in succession, each fix-forwarded but cumulatively expensive. This audit produces a side-by-side diff so the next C2 attempt is a single-pass cleanup against an enumerated list rather than another retry-then-debug cycle.

## Methodology

- Anchor: upstream `tiny11Coremaker.ps1` lines 27-571, treated as source of truth.
- Each phase: quote upstream verbatim; quote our implementation verbatim; classify each divergence; flag fixes.
- Citations: `tiny11Coremaker.ps1:NNN` and `src/Tiny11.Core.psm1:NNN` (or other path) for every divergence so a reader can spot-check in seconds.
- This document is the audit. **No code changes ship in this commit.** A separate follow-up commit fixes against this list.

## Scope

The 7 phases agreed in the audit plan (per the audit-method conversation, 2026-05-10):

| # | Phase | Upstream lines | Our lines |
|---|-------|----------------|-----------|
| 4  | appx-removal              | 113-128 | composer 666-681 |
| 5  | system-package-removal    | 134-166 | composer 683-686 + helper 420-455 |
| 9-16 | registry edits          | 334-470 | composer 721-760 + data 240-352 |
| 17 | scheduled-task-cleanup    | 420-438 | composer 762-771 + data 101-109 |
| 18 | cleanup-image             | 478-480 | composer 773-776 |
| 21 | boot-wim                  | 491-523 | composer 798-831 |
| 23 | iso-create                | 529-559 | composer 841-856 |

Findings outside this scope are recorded in **Out-of-scope observations** at the end. They are not part of the agreed audit and are NOT fixed by the follow-up commit unless the user separately authorizes it.

## Severity legend

- **BLOCKING** — wrong behavior; either build fails, or build "succeeds" but the resulting image lacks intended changes.
- **DEVIATION** — intentional or accidental departure from upstream, currently functional, but not documented as a deliberate choice. Either annotate or revert.
- **COSMETIC** — output formatting, naming, or transcript noise. Optional fix.

## Upstream context-traps

Three upstream patterns will trip any paraphrase:

### CT-1. `$ScratchDisk` is referenced but never defined in `tiny11Coremaker.ps1`

Used at upstream lines 335-339 (reg load hive paths), 383 (autounattend copy), and 559 (oscdimg invocation). The variable is presumably inherited from `tiny11maker.ps1` via dot-sourcing or shared scope but `tiny11Coremaker.ps1` never assigns it standalone. Any port that runs this file in isolation will substitute empty string and produce malformed paths — e.g. `\scratchdir\Windows\System32\config\COMPONENTS` (relative, resolved against CWD).

**Status in our port:** non-issue — we use `$mountDir` and `$sourceDir` everywhere instead of `$ScratchDisk\scratchdir` / `$ScratchDisk\tiny11`. Documented here so it's visible if the audit prompts a future implementer to reach for upstream's variable names.

### CT-2. `$tasksPath = "C:\scratchdir\Windows\System32\Tasks"` hardcodes `C:\`

Upstream line 420. Works only when `$mainOSDrive == 'C:'` and `$ScratchDisk == 'C:'`. A user with the OS on D: would silently get nothing removed.

**Status in our port:** fixed — see Phase 17, D17.1.

### CT-3. `$packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })` (upstream line 123)

This is a startswith-any check expressed via two-pass filter. The inner `Where-Object` returns the first prefix string that matches; `-contains` then checks that string is in the original array (always true by construction when the inner Where matched anything; null otherwise). Equivalent to a nested `foreach…break` with an early exit.

**Status in our port:** rewritten to the cleaner nested foreach form (composer 674-681). Functionally equivalent. Documented here as a deliberate clarification, not a bug fix.

---

## Phase 4: appx-removal

### Upstream `tiny11Coremaker.ps1:113-128`

```powershell
$packages = & 'dism' '/English' "/image:$($env:SystemDrive)\scratchdir" '/Get-ProvisionedAppxPackages' |
    ForEach-Object {
        if ($_ -match 'PackageName : (.*)') {
            $matches[1]
        }
    }
$packagePrefixes = 'Clipchamp.Clipchamp_', 'Microsoft.BingNews_', ... (32 prefixes, one line)

$packagesToRemove = $packages | Where-Object {
    $packageName = $_
    $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })
}
foreach ($package in $packagesToRemove) {
    write-host "Removing $package :"
    & 'dism' '/English' "/image:$($env:SystemDrive)\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
}
```

### Our `src/Tiny11.Core.psm1:666-681`

```powershell
& $ProgressCallback @{ phase='appx-removal'; step="Removing provisioned apps"; percent=15 }
$appxPrefixes = Get-Tiny11CoreAppxPrefixes
$allAppxOutput = (& 'dism.exe' '/English' "/image:$mountDir" '/Get-ProvisionedAppxPackages') -join "`n"
$allAppxPackages = @()
foreach ($line in ($allAppxOutput -split "`n")) {
    if ($line -match 'PackageName\s*:\s*(.+)') { $allAppxPackages += $Matches[1].Trim() }
}
foreach ($pkg in $allAppxPackages) {
    foreach ($prefix in $appxPrefixes) {
        if ($pkg -like "$prefix*") {
            & 'dism.exe' '/English' "/image:$mountDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$pkg" | Out-Null
            break
        }
    }
}
```

### Divergences

| ID | Severity | Description | Fix direction |
|----|----------|-------------|---------------|
| D4.1 | DEVIATION | Regex `PackageName\s*:\s*(.+)` (ours) vs `PackageName : (.*)` (upstream). Ours is more permissive on whitespace. Functional in both cases for current DISM output. | Keep ours — strictly safer. Add a one-line comment noting the deliberate widening. |
| D4.2 | COSMETIC | Binary name `dism.exe` (ours) vs `dism` (upstream). Both PATH-resolve identically on Windows. | None. |
| D4.3 | DEVIATION | We pipe Remove-ProvisionedAppxPackage stdout to `\| Out-Null`; upstream lets it flow to transcript. We also DO NOT capture/check `$LASTEXITCODE`. A failed appx removal is silent in both transcript and downstream behavior. | Capture `$LASTEXITCODE` after the Remove call; emit `build-progress` markers per package or at minimum a summary count. Don't throw — upstream tolerates failures, so we should too — but make them visible. |
| D4.4 | COSMETIC | `$matches[1]` (upstream lowercase) vs `$Matches[1]` (ours capitalized). PowerShell automatic variable, case-insensitive. | None. |
| D4.5 | DEVIATION | Filter expression rewritten from upstream's `Where-Object { ... }` two-pass to nested `foreach…break`. Documented as CT-3. | Keep ours — clearer. Annotate if not already. |
| D4.6 | COSMETIC | Upstream emits `Write-Host "Removing $package :"` per package; ours is silent. | Add per-package `Write-Verbose` or a `build-progress` substep marker. Optional. |

---

## Phase 5: system-package-removal

### Upstream `tiny11Coremaker.ps1:134-166`

```powershell
$scratchDir = "$($env:SystemDrive)\scratchdir"
$packagePatterns = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64",
    "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35",
    "Windows-Defender-Client-Package~31bf3856ad364e35~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-StepsRecorder-Package~"
)

# Get all packages
$allPackages = & dism /image:$scratchDir /Get-Packages /Format:Table
$allPackages = $allPackages -split "`n" | Select-Object -Skip 1

foreach ($packagePattern in $packagePatterns) {
    $packagesToRemove = $allPackages | Where-Object { $_ -like "$packagePattern*" }
    foreach ($package in $packagesToRemove) {
        $packageIdentity = ($package -split "\s+")[0]
        Write-Host "Removing $packageIdentity..."
        & dism /image:$scratchDir /Remove-Package /PackageName:$packageIdentity
    }
}
```

### Our composer dispatch — `src/Tiny11.Core.psm1:683-686`

```powershell
& $ProgressCallback @{ phase='system-package-removal'; step='Removing system packages (IE, MediaPlayer, Defender, etc.)'; percent=20 }
$sysPatterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode $languageCode
Invoke-Tiny11CoreSystemPackageRemoval -ScratchDir $mountDir -Patterns $sysPatterns -LanguageCode $languageCode
```

### Our helper — `src/Tiny11.Core.psm1:420-455` (`Invoke-Tiny11CoreSystemPackageRemoval`)

```powershell
$enumResult = Invoke-CoreDism -Arguments @('/English', "/image:$ScratchDir", '/Get-Packages', '/Format:Table')
if ($enumResult.ExitCode -ne 0) {
    throw "dism /Get-Packages failed (exit $($enumResult.ExitCode)): $($enumResult.Output)"
}

$allLines = $enumResult.Output -split "`n"

foreach ($pattern in $Patterns) {
    $matchedItems = $allLines |
        Where-Object { $_ -like "$pattern*" } |
        ForEach-Object { ($_ -split '\s+')[0] }
    if (-not $matchedItems) {
        Write-Verbose "No matches for pattern: $pattern (non-fatal — package may be absent in this ISO version)"
        continue
    }
    foreach ($identity in $matchedItems) {
        $removeResult = Invoke-CoreDism -Arguments @('/English', "/image:$ScratchDir", '/Remove-Package', "/PackageName:$identity")
        if ($removeResult.ExitCode -ne 0) {
            Write-Verbose "dism /Remove-Package $identity failed (exit $($removeResult.ExitCode)) — non-fatal, continuing"
        }
    }
}
```

### Divergences

| ID | Severity | Description | Fix direction |
|----|----------|-------------|---------------|
| D5.1 | DEVIATION | We add `/English` to both `/Get-Packages` and `/Remove-Package` invocations. Upstream omits it. `/English` forces English DISM output, which is required for our `-like "$pattern*"` filter to work on non-English locales. | Keep ours — defensible improvement. Annotate as deliberate. |
| D5.2 | DEVIATION | Upstream skips first output line (`\| Select-Object -Skip 1`); we don't. Header rows from `/Format:Table` won't `-like`-match a `Microsoft-Windows-...` pattern, so the omission is functionally safe but is a paraphrase. | Add `\| Select-Object -Skip 1` to `$allLines = ...` line for parity. Cheap defense-in-depth. |
| D5.3 | DEVIATION | Function parameter name is `$ScratchDir` but composer passes `$mountDir`. Naming is misleading — it's actually the offline-mount directory, not a scratch root. | Rename parameter to `$MountDir` (one-symbol cleanup; no behavior change). |
| D5.4 | DEVIATION | Failed Remove-Package is `Write-Verbose` (silent unless `-Verbose`). Upstream's `& dism …` lets failures hit transcript. | Upgrade to `Write-Warning` or emit a `build-progress` substep showing per-package failure. Build keeps running either way. |
| D5.5 | NON-BUG | 12 patterns match upstream verbatim, including the four `$languageCode`-templated entries. Confirmed against `Get-Tiny11CoreSystemPackagePatterns` data accessor lines 64-75. | None. |

---

## Phases 9-16: registry edits

### THE BIG FINDING — D9.1 (BLOCKING)

**Upstream loads hives at lines 335-339:**

```powershell
reg load HKLM\zCOMPONENTS $ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS | Out-Null
reg load HKLM\zDEFAULT    $ScratchDisk\scratchdir\Windows\System32\config\default   | Out-Null
reg load HKLM\zNTUSER     $ScratchDisk\scratchdir\Users\Default\ntuser.dat          | Out-Null
reg load HKLM\zSOFTWARE   $ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE  | Out-Null
reg load HKLM\zSYSTEM     $ScratchDisk\scratchdir\Windows\System32\config\SYSTEM    | Out-Null
```

So the loaded keys live at `HKLM\zCOMPONENTS`, `HKLM\zDEFAULT`, `HKLM\zNTUSER`, `HKLM\zSOFTWARE`, `HKLM\zSYSTEM`.

**Upstream then references them with literal paths**, e.g. `tiny11Coremaker.ps1:341`:

```powershell
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f'
```

**Our data table (`Get-Tiny11CoreRegistryTweaks`) carries the `z` prefix in the `Hive` field:**

```powershell
[pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zDEFAULT'; Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV1'; Type='REG_DWORD'; Value=0 }
```
(`src/Tiny11.Core.psm1:244` — Hive value is `'zDEFAULT'`, with the z.)

**Our composer at `src/Tiny11.Core.psm1:741-742` then prepends `\z` to that already-z-prefixed value:**

```powershell
$mountKey = "HKLM\z$($t.Hive)"
$fullKey  = "$mountKey\$($t.Path)"
```

PowerShell string interpolation evaluates this as `"HKLM\z" + "zDEFAULT"` = **`HKLM\zzDEFAULT`** (double-z). Every reg add and reg delete in Phases 9-16 targets the wrong key.

**Effect:**
- `reg.exe add HKLM\zzDEFAULT\Control Panel\UnsupportedHardwareNotificationCache /v SV1 /t REG_DWORD /d 0 /f` succeeds with exit 0 because reg.exe creates the missing parent `HKLM\zzDEFAULT` as a regular HKLM subkey.
- The write goes to in-memory HKLM, NOT to the loaded `HKLM\zDEFAULT` hive.
- Phase `registry-unload` unloads `HKLM\zDEFAULT` (correctly, via the bare hive name passed to `Dismount-Tiny11Hive`). The `HKLM\zzDEFAULT` leftover lingers in HKLM but is irrelevant to the offline image — the image's hives never received any of our edits.
- The Core build "succeeds" but the resulting image has zero of the intended tweaks: TPM/CPU/SecureBoot bypass not applied, sponsored apps not disabled, Defender not disabled, Windows Update not disabled, telemetry not disabled, etc.

**This is the single highest-priority bug in the audit.** It silently invalidates the entire purpose of the Core mode build. Has not surfaced in C2 retries because: (a) reg.exe exits 0, so the build proceeds past Phases 9-16 happily; (b) the user has not yet booted a Core ISO and observed that none of the bypass/disable behaviors were applied.

**Fix:** Drop `\z` from the composer interpolation. Change `src/Tiny11.Core.psm1:741` from:

```powershell
$mountKey = "HKLM\z$($t.Hive)"
```

to:

```powershell
$mountKey = "HKLM\$($t.Hive)"
```

Apply the **same fix at `src/Tiny11.Core.psm1:814`** in the boot-wim block (D21.1).

The data file's existing comment at line 219 already documents the design intent — `Hive : hive prefix used in offline mount (e.g. 'zSOFTWARE')` — i.e. data carries the prefix; composer doesn't re-add it.

### Composer (full block) — `src/Tiny11.Core.psm1:721-760`

```powershell
& $ProgressCallback @{ phase='registry-load'; step='Loading hives'; percent=66 }
foreach ($hive in @('COMPONENTS', 'DEFAULT', 'NTUSER', 'SOFTWARE', 'SYSTEM')) {
    Mount-Tiny11Hive -Hive $hive -ScratchDir $mountDir
}

try {
    $allTweaks = Get-Tiny11CoreRegistryTweaks
    $phaseMap = @{
        'bypass-sysreqs'   = @{ phase='registry-bypass';            step='Applying system-requirement bypass keys'; percent=68 }
        'sponsored-apps'   = @{ phase='registry-sponsored-apps';    step='Disabling sponsored apps + ContentDeliveryManager'; percent=71 }
        'telemetry'        = @{ phase='registry-telemetry';         step='Disabling telemetry'; percent=73 }
        'defender-disable' = @{ phase='registry-defender-disable';  step='Disabling Windows Defender services'; percent=75 }
        'update-disable'   = @{ phase='registry-update-disable';    step='Disabling Windows Update'; percent=77 }
        'misc'             = @{ phase='registry-misc';              step='BitLocker / Chat / Copilot / Teams / Outlook / etc.'; percent=79 }
    }
    foreach ($cat in @('bypass-sysreqs', 'sponsored-apps', 'telemetry', 'defender-disable', 'update-disable', 'misc')) {
        & $ProgressCallback $phaseMap[$cat]
        $catTweaks = $allTweaks | Where-Object Category -eq $cat
        foreach ($t in $catTweaks) {
            $mountKey = "HKLM\z$($t.Hive)"   # <-- D9.1 BUG
            $fullKey  = "$mountKey\$($t.Path)"
            if ($t.Op -eq 'add') {
                & 'reg.exe' 'add' $fullKey '/v' $t.Name '/t' $t.Type '/d' $t.Value '/f' | Out-Null
            } elseif ($t.Op -eq 'delete') {
                if ($t.PSObject.Properties['Name'] -and $t.Name) {
                    & 'reg.exe' 'delete' $fullKey '/v' $t.Name '/f' | Out-Null
                } else {
                    & 'reg.exe' 'delete' $fullKey '/f' | Out-Null
                }
            }
        }
    }
}
finally {
    & $ProgressCallback @{ phase='registry-unload'; step='Unloading hives'; percent=81 }
    foreach ($hive in @('SYSTEM', 'SOFTWARE', 'NTUSER', 'DEFAULT', 'COMPONENTS')) {
        try { Dismount-Tiny11Hive -Hive $hive } catch { Write-Warning "Failed to unload hive ${hive}: $_" }
    }
}
```

### Other divergences in Phases 9-16

| ID | Severity | Description | Fix direction |
|----|----------|-------------|---------------|
| D9.1 | **BLOCKING** | Double-z bug. Detailed above. | Drop `\z` from composer interpolation at line 741. |
| D9.2 | DEVIATION | Upstream issues 5 reg-add invocations duplicating already-set values (3× `ContentDeliveryAllowed`, 2× `SubscribedContentEnabled`). Our data dedupes those to 1 each (count: 26 sponsored-apps entries vs. 27 unique upstream lines, after the case-insensitive merge below). | Keep dedupe — registry writes are idempotent. Annotate as deliberate dedupe of upstream redundancy. |
| D9.3 | DEVIATION | Upstream lines 352-354 use uppercase `SOFTWARE` segment in path; lines 361-374 use mixed-case `Software`. Registry paths are case-INsensitive at the API level — both target the same physical key. We preserved both case spellings as separate data entries (lines 259-261 vs 266-269). Net effect: 3 functional duplicate writes. | Keep — no harm, preserves upstream's (functional) redundancy and makes data auditable against upstream byte-for-byte. |
| D9.4 | DEVIATION | Upstream lines 392-393 use bare `reg delete "HKEY_LOCAL_MACHINE\zSOFTWARE\…"` (full hive name, no `& reg`) instead of the pattern at lines 341-390. Our data captures these as `Op='delete'` rows with `Hive='zSOFTWARE'` (lines 296-297). The composer routes them through the same `& 'reg.exe' 'delete'` path. `HKEY_LOCAL_MACHINE` and `HKLM` are aliases. | None — already faithfully captured. |
| D9.5 | DEVIATION | Defender services in upstream (lines 459-469) use `Set-ItemProperty -Path "HKLM:\zSYSTEM\..."` (PSDrive form) rather than `& reg add`. Effect is identical — both write to the offline hive. We capture as `Op='add'` rows (lines 345-349) — composer dispatches through `reg.exe`. | None — equivalent semantics. |
| D9.6 | DEVIATION | Upstream lines 392-393 reg-deletes a KEY (no `/v`). Upstream lines 410-411 also delete keys. Upstream line 377-378 delete keys (no `/v`). Our composer at line 746 inspects `$t.PSObject.Properties['Name'] -and $t.Name` to choose `/v $name` vs key-delete. Data file omits `Name` field on key-deletes. Logic correct. | None. |
| D9.7 | COSMETIC | Upstream emits `Write-Host` between sub-blocks ("Bypassing system requirements", "Disabling Sponsored Apps", etc.). We emit `build-progress` markers via the phaseMap. Equivalent visibility through the launcher UI; transcript loses the inline labels. | None — markers are the right abstraction here. |

### D9.1 fix verification path

After dropping `\z` from the composer:
- `reg.exe add HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache /v SV1 …` writes into the loaded hive.
- On `reg unload HKLM\zDEFAULT`, the change persists to `<mount>\Users\Default\ntuser.dat` (or relevant config hive file).
- After `dism /Unmount-Image /Commit`, the install.wim contains the modified hive.
- A Pester regression test should construct a fake hive file (`reg save` from a test source), Mount-Tiny11Hive, run a single tweak from the data table through the composer's reg-write logic, Dismount-Tiny11Hive, and verify the value landed in the saved hive (`reg query` on a re-loaded copy). This catches any future return of the double-z bug.

### Coverage spot-check (informational)

Counted entries in `Get-Tiny11CoreRegistryTweaks` per category, against upstream line ranges:

| Category | Our count | Upstream lines | Upstream invocation count | Notes |
|---------|-----------|----------------|---------------------------|-------|
| bypass-sysreqs (install.wim) | 10 | 341-350 | 10 | 1:1, includes UnsupportedHardwareNotificationCache (4) + LabConfig (5) + MoSetup (1). |
| sponsored-apps | 26 | 352-380 (29 lines) | 27 (-2 deletes = 25 adds + 2 deletes) | Dedupe of explicit dupes (3×CDA, 2×SCE) but preserved 3 case-insensitive duplicates intentionally (D9.3). |
| telemetry | 10 | 397-406 | 10 | 1:1. |
| update-disable | 16 | 441-456 | 16 | 1:1. |
| defender-disable | 6 | 459-470 | 5 services + 1 SettingsPageVisibility | 1:1. |
| misc | 17 | 382-419 (selected) | 17 | 1:1, includes BypassNRO/ReserveStorage/BitLocker/Chat/TaskbarMn/Edge-uninstall-deletes (2)/OneDrive/UScheduler-OutlookUpdate/UScheduler-DevHomeUpdate/UScheduler_Oobe-deletes (2)/Copilot/HubsSidebar/SearchBoxSuggestions/Teams/WindowsMail. |
| **Total** | **85** | | **~85** | Within ±2 of upstream's effective unique writes. Coverage acceptable. |

---

## Phase 17: scheduled-task-cleanup

### Upstream `tiny11Coremaker.ps1:420-438`

```powershell
$tasksPath = "C:\scratchdir\Windows\System32\Tasks"

Write-Host "Deleting scheduled task definition files..."

# Application Compatibility Appraiser
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue

# Customer Experience Improvement Program (removes the entire folder and all tasks within it)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue

# Program Data Updater
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue

# Chkdsk Proxy
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue

# Windows Error Reporting (QueueReporting)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

Write-Host "Task files have been deleted."
```

### Our `src/Tiny11.Core.psm1:762-771`

```powershell
& $ProgressCallback @{ phase='scheduled-task-cleanup'; step='Removing 5 scheduled task definitions'; percent=82 }
$taskTargets = Get-Tiny11CoreScheduledTaskTargets
foreach ($t in $taskTargets) {
    $abs = Join-Path $mountDir "Windows\System32\Tasks\$($t.RelPath)"
    if (Test-Path -LiteralPath $abs) {
        if ($t.Recurse) { Remove-Item -Path $abs -Recurse -Force -ErrorAction SilentlyContinue }
        else             { Remove-Item -Path $abs -Force -ErrorAction SilentlyContinue }
    }
}
```

### Divergences

| ID | Severity | Description | Fix direction |
|----|----------|-------------|---------------|
| D17.1 | DEVIATION (improvement) | Upstream hardcodes `C:\scratchdir`. Ours uses `$mountDir`. Fixes upstream's CT-2. | Keep — annotate as deliberate fix of upstream defect. |
| D17.2 | DEVIATION | Upstream relies on `-ErrorAction SilentlyContinue` for missing paths; we add an explicit `Test-Path -LiteralPath` first. Both work; ours is one syscall heavier per target. | Keep — the explicit Test-Path makes a misconfiguration easier to flag in future debugging. |
| D17.3 | NON-BUG | 5 paths and recurse flags match (CEIP=true with Recurse, others=false). Verified against `Get-Tiny11CoreScheduledTaskTargets` lines 102-108. | None. |

---

## Phase 18: cleanup-image

### Upstream `tiny11Coremaker.ps1:478-480`

```powershell
Write-Host "Cleaning up image..."
& 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' >null
Write-Host "Cleanup complete."
```

### Our `src/Tiny11.Core.psm1:773-776`

```powershell
& $ProgressCallback @{ phase='cleanup-image'; step='DISM /Cleanup-Image /StartComponentCleanup /ResetBase'; percent=84 }
$cleanResult = Invoke-CoreDism -Arguments @('/English', "/image:$mountDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
if ($cleanResult.ExitCode -ne 0) { throw "DISM /Cleanup-Image failed: $($cleanResult.Output)" }
```

### Divergences

| ID | Severity | Description | Fix direction |
|----|----------|-------------|---------------|
| D18.1 | DEVIATION (improvement) | Upstream redirects stdout to `>null` and ignores exit code; ours captures + throws on non-zero. A failed Cleanup-Image now becomes a build error rather than a silently-corrupted image that fails later in opaque ways. | Keep — annotate as deliberate. |
| D18.2 | NON-BUG | Path argument equivalent (`$mainOSDrive\scratchdir` upstream, `$mountDir` ours — both are the offline mount root). | None. |

---

## Phase 21: boot-wim

### Upstream `tiny11Coremaker.ps1:491-523`

```powershell
Write-Host "Mounting boot image:"
$wimFilePath = "$($env:SystemDrive)\tiny11\sources\boot.wim"
& takeown "/F" $wimFilePath >null
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false
& 'dism' '/English' '/mount-image' "/imagefile:$mainOSDrive\tiny11\sources\boot.wim" '/index:2' "/mountdir:$mainOSDrive\scratchdir"

Write-Host "Loading registry..."
reg load HKLM\zCOMPONENTS $mainOSDrive\scratchdir\Windows\System32\config\COMPONENTS
reg load HKLM\zDEFAULT    $mainOSDrive\scratchdir\Windows\System32\config\default
reg load HKLM\zNTUSER     $mainOSDrive\scratchdir\Users\Default\ntuser.dat
reg load HKLM\zSOFTWARE   $mainOSDrive\scratchdir\Windows\System32\config\SOFTWARE
reg load HKLM\zSYSTEM     $mainOSDrive\scratchdir\Windows\System32\config\SYSTEM

Write-Host "Bypassing system requirements(on the setup image):"
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' >null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' >null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' >null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' >null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck'        '/t' 'REG_DWORD' '/d' '1' '/f' >null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck'        '/t' 'REG_DWORD' '/d' '1' '/f' >null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' >null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck'    '/t' 'REG_DWORD' '/d' '1' '/f' >null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck'        '/t' 'REG_DWORD' '/d' '1' '/f' >null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' >null
& 'reg' 'add' 'HKEY_LOCAL_MACHINE\zSYSTEM\Setup' '/v' 'CmdLine' '/t' 'REG_SZ' '/d' 'X:\sources\setup.exe' '/f' >null

Write-Host "Tweaking complete!"
Write-Host "Unmounting Registry..."
reg unload HKLM\zCOMPONENTS >null
reg unload HKLM\zDEFAULT    >null
reg unload HKLM\zNTUSER     >null
reg unload HKLM\zSOFTWARE   >null
reg unload HKLM\zSYSTEM     >null

Write-Host "Unmounting image..."
& 'dism' '/English' '/unmount-image' "/mountdir:$mainOSDrive\scratchdir" '/commit'
```

### Our `src/Tiny11.Core.psm1:798-831`

```powershell
& $ProgressCallback @{ phase='boot-wim'; step='Mounting boot.wim index 2 + applying bypass-sysreqs'; percent=93 }
$bootWim = Join-Path $sourceDir 'sources\boot.wim'
Invoke-CoreTakeown -Path $bootWim | Out-Null
Invoke-CoreIcacls  -Path $bootWim | Out-Null
Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
Invoke-CoreDism -Arguments @('/English', '/Mount-Image', "/ImageFile:$bootWim", '/Index:2', "/MountDir:$mountDir") | Out-Null
try {
    foreach ($hive in @('COMPONENTS', 'DEFAULT', 'NTUSER', 'SOFTWARE', 'SYSTEM')) {
        Mount-Tiny11Hive -Hive $hive -ScratchDir $mountDir
    }
    try {
        # Apply only the bypass-sysreqs subset to the setup image
        $bootTweaks = Get-Tiny11CoreRegistryTweaks | Where-Object Category -eq 'bypass-sysreqs'
        foreach ($t in $bootTweaks) {
            $mountKey = "HKLM\z$($t.Hive)"   # <-- D21.1 BUG (same as D9.1)
            $fullKey  = "$mountKey\$($t.Path)"
            if ($t.Op -eq 'add') {
                & 'reg.exe' 'add' $fullKey '/v' $t.Name '/t' $t.Type '/d' $t.Value '/f' | Out-Null
            }
        }
        # Plus the setup-image-only CmdLine override (upstream tiny11Coremaker.ps1 line 514)
        & 'reg.exe' 'add' 'HKLM\zSYSTEM\Setup' '/v' 'CmdLine' '/t' 'REG_SZ' '/d' 'X:\sources\setup.exe' '/f' | Out-Null
    }
    finally {
        foreach ($hive in @('SYSTEM', 'SOFTWARE', 'NTUSER', 'DEFAULT', 'COMPONENTS')) {
            try { Dismount-Tiny11Hive -Hive $hive } catch { Write-Warning "Failed to unload hive ${hive}: $_" }
        }
    }
}
finally {
    Invoke-CoreDism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Commit') | Out-Null
}
```

### Divergences

| ID | Severity | Description | Fix direction |
|----|----------|-------------|---------------|
| D21.1 | **BLOCKING** | Same `HKLM\z$($t.Hive)` double-z bug as D9.1 (line 814). Bypass-sysreqs subset on boot.wim silently no-ops — meaning the setup-image bypasses for TPM/CPU/SecureBoot/etc. don't actually apply. The CmdLine override at line 821 is a hardcoded literal `HKLM\zSYSTEM\Setup` (correct), so that one IS applied. | Drop `\z` from `$mountKey = "HKLM\z$($t.Hive)"` — change to `"HKLM\$($t.Hive)"`. Same fix as D9.1. |
| D21.2 | DEVIATION | `Set-ItemProperty -Name IsReadOnly` upstream has no try/catch, no `-ErrorAction`. If the RO bit can't be cleared, upstream throws and halts. Ours has `-ErrorAction SilentlyContinue` — silently continues. | Keep ours — defensive (the RO bit is often already clear post-takeown+icacls); but annotate that upstream halts here while we tolerate. |
| D21.3 | DEVIATION | `Invoke-CoreDism … '/Unmount-Image' … '/Commit' \| Out-Null` discards the result tuple — exit code never checked. Upstream's `& 'dism' …` likewise doesn't check. Both will silently succeed-or-fail. | Capture `$result.ExitCode` and `throw` on non-zero, matching the discipline of D18.1. Cheap insurance. |
| D21.4 | DEVIATION | Hive load ordering: ours (line 807) `COMPONENTS, DEFAULT, NTUSER, SOFTWARE, SYSTEM`; unload (line 824) reverse: `SYSTEM, SOFTWARE, NTUSER, DEFAULT, COMPONENTS`. Upstream (497-502 load; 517-521 unload): same load order, same reverse unload. Match. | None. |
| D21.5 | DEVIATION | Hardcoded `'HKLM\zSYSTEM\Setup'` for the CmdLine entry (line 821) bypasses the data table entirely. This is the only registry write in the boot-wim block that doesn't go through the `$mountKey = "HKLM\z..."` path — so it's the only one that actually writes to the loaded hive (because `HKLM\zSYSTEM` is correct). | Once D21.1 is fixed and bypass-sysreqs flows through the data table correctly, this hardcoded line could either stay (it's the "boot-wim only" extra) or be moved into the data table with a new category like `'boot-wim-only'`. Defer that refactor; keep functional fix focused. |

---

## Phase 23: iso-create

### Upstream `tiny11Coremaker.ps1:529-559`

```powershell
Write-Host "Creating ISO image..."
$ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostarchitecture\Oscdimg"
$localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

if ([System.IO.Directory]::Exists($ADKDepTools)) {
    Write-Host "Will be using oscdimg.exe from system ADK."
    $OSCDIMG = "$ADKDepTools\oscdimg.exe"
} else {
    Write-Host "ADK folder not found. Will be using bundled oscdimg.exe."
    $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
    if (-not (Test-Path -Path $localOSCDIMGPath)) {
        Write-Host "Downloading oscdimg.exe..."
        Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath
        if (Test-Path $localOSCDIMGPath) {
            Write-Host "oscdimg.exe downloaded successfully."
        } else {
            Write-Error "Failed to download oscdimg.exe."
            exit 1
        }
    } else {
        Write-Host "oscdimg.exe already exists locally."
    }
    $OSCDIMG = $localOSCDIMGPath
}

& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\tiny11\boot\etfsboot.com#pEF,e,b$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\tiny11" "$PSScriptRoot\tiny11.iso"
```

### Our `src/Tiny11.Core.psm1:841-856` (plus `Tiny11.Worker.psm1:156-168` Resolve-Tiny11Oscdimg)

```powershell
& $ProgressCallback @{ phase='iso-create'; step='Creating bootable ISO with oscdimg'; percent=98 }
Import-Module (Join-Path $PSScriptRoot 'Tiny11.Worker.psm1') -Force
$oscdimgCacheDir = Join-Path $ScratchDir 'oscdimg-cache'
New-Item -ItemType Directory -Force -Path $oscdimgCacheDir | Out-Null
$oscdimg = Resolve-Tiny11Oscdimg -CacheDir $oscdimgCacheDir
if (-not $oscdimg -or -not (Test-Path $oscdimg)) {
    throw "oscdimg.exe could not be resolved (ADK not installed and download failed). Cannot create ISO."
}
& $oscdimg '-m' '-o' '-u2' '-udfver102' `
    "-bootdata:2#p0,e,b$sourceDir\boot\etfsboot.com#pEF,e,b$sourceDir\efi\microsoft\boot\efisys.bin" `
    $sourceDir $OutputIso | Out-Null
```

```powershell
# Tiny11.Worker.psm1:156-168
function Resolve-Tiny11Oscdimg {
    [CmdletBinding()]
    param([string]$CacheDir)
    $hostArch = $env:PROCESSOR_ARCHITECTURE
    $adkPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArch\Oscdimg\oscdimg.exe"
    if (Test-Path $adkPath) { return $adkPath }
    if (-not $CacheDir) { return $null }
    $local = Join-Path $CacheDir 'oscdimg.exe'
    if (Test-Path $local) { return $local }
    $url = 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe'
    Invoke-WebRequest -Uri $url -OutFile $local
    return $local
}
```

### Divergences

| ID | Severity | Description | Fix direction |
|----|----------|-------------|---------------|
| D23.1 | DEVIATION (intentional) | oscdimg resolution delegated to `Resolve-Tiny11Oscdimg` (3-tier ADK → cached → MS-symbol-server). Same logic as upstream. | None. |
| D23.2 | DEVIATION (intentional) | Upstream uses `$ScratchDisk\tiny11` (undefined `$ScratchDisk`!) for both source dir and bootdata anchors. Ours uses `$sourceDir` (= `$ScratchDir\source`) which is structurally what `$ScratchDisk\tiny11` is supposed to resolve to on a working upstream run. **Verification:** our Phase 1 Copy-Item at line 624 mirrors upstream line 61 — both copy the entire ISO root verbatim, so the boot/, efi/, sources/ subtree layout is identical. | None — paths verified to resolve. |
| D23.3 | DEVIATION | oscdimg invocation suppressed with `\| Out-Null`. Upstream lets oscdimg's progress text flow to transcript. | Keep `\| Out-Null` (the marker stream owns user-facing progress now); but capture `$LASTEXITCODE` after the call and throw on non-zero — currently a failed oscdimg run is silent and the launcher would emit `build-complete` despite no ISO. |
| D23.4 | **POTENTIAL BLOCKING** | If `Resolve-Tiny11Oscdimg` falls through to the download branch and `Invoke-WebRequest` throws (offline / firewall / TLS issue), the function emits an uncaught exception. Caller checks `if (-not $oscdimg -or -not (Test-Path $oscdimg))` only AFTER the function returns — so the throw bubbles up and is caught by the wrapper's outer try/catch as a `build-error`. That's actually fine. **But** the local cached path remains as a zero-byte or partially-written `oscdimg.exe` on a next attempt, and `Test-Path` will say "yes, exists" without integrity check. | Add a length / signature check on cached oscdimg.exe before trusting it (or delete on any download exception). Defer if not biting; flag if the user reports oscdimg failures in C2 retries. |
| D23.5 | NON-BUG | oscdimg flag set (`-m -o -u2 -udfver102 -bootdata:…`) and source/dest argument order match upstream. Verified. | None. |

---

## Out-of-scope observations

These were noticed during the audit but fall outside the agreed 7-phase scope. Logged here so they're surfaced; **not part of the follow-up fix commit unless separately authorized.**

| ID | Phase | Severity | Note |
|----|-------|----------|------|
| OOS-1 | Preflight (Phase 0/1) | DEVIATION | Wrapper mounts source ISO twice — once for edition enumeration (preflight), then composer Phase 1 mounts it again to copy contents. Wasteful but functional. Could mount once; not blocking. |
| OOS-2 | Preflight | MISSING FEATURE | Upstream lines 45-58 auto-convert `install.esd` → `install.wim` if no install.wim is present. Ours doesn't — composer assumes install.wim exists at `$sourceDir\sources\install.wim`. Modern Win11 multi-edition ISOs always ship install.wim, so this is unlikely to bite, but if a user picks an older install.esd-only ISO, we'd fail at the takeown step. Cheap to add. |
| OOS-3 | Phase 7 (filesystem-removal) | DEVIATION | We add takeown+icacls before each filesystem target removal; upstream does NOT for the Edge folders (lines 182-185). Upstream relies on later WinSxS-wide takeown, which works because Edge folders may not be ACL-protected on test ISOs. Ours is defensive — keep. |
| OOS-4 | Phase 8 (WinSxS-wipe) | DEVIATION | Upstream lines 186-208 explicitly remove `<arch>_microsoft-edge-webview_*` from WinSxS via takeown+icacls+Remove-Item BEFORE the WinSxS wipe. Our wipe handles this implicitly via the keep-list (the edge-webview prefix is not in the keep-list, so it's discarded when WinSxS_edit replaces WinSxS). Net result: same. Annotate or keep as-is. |
| OOS-5 | Phase 8 | DEVIATION (improvement) | Ours throws if zero patterns matched the keep-list; upstream silently produces a corrupted image. Better failure mode. |
| OOS-6 | Phase 8 | NOTE | Upstream's foreach loop at lines 318-325 runs OUTSIDE the per-arch if/elseif blocks but redundantly with the inner amd64 foreach at 271-278 — net effect for amd64 is "copy each keep-list dir twice", which Copy-Item -Force tolerates. Pure transcribe-faithfully would replicate this redundancy; ours doesn't (single-pass loop). Keep ours — annotate. |
| OOS-7 | Phase 19/20 (unmount-install + export) | DEVIATION (improvement) | Ours uses `/Discard` on pipeline failure; upstream always `/Commit`. Ours protects against committing partially-corrupted edits. Keep. |
| OOS-8 | Phase 22 (export-install-esd) | NON-BUG | Hardcoded `/SourceIndex:1` matches upstream — after Phase 20's Export-Image rewrite, the install.wim has only one image at index 1. Verified. |
| OOS-9 | Architecture detection | DEVIATION | Ours throws on architecture other than amd64/arm64; upstream just continues with the unknown architecture string and any subsequent code paths fail later. Ours fails fast and clearly. Keep. |
| OOS-10 | takeown wrapper | NOTE | `Invoke-CoreTakeown` in our code adds `/D Y` only when `/R` is also passed (per `src/Tiny11.Core.psm1:390-399` comments). Upstream uses no `/D` ever. The `/D Y` answer-the-prompt addition is the fix from commit `be2d8bb` and is correct for non-interactive subprocess context. Keep. |
| OOS-11 | reg-load output handling | NOTE | Upstream uses `>null` to swallow `reg load` success messages. Our `Mount-Tiny11Hive` routes through `Invoke-RegCommand` which the wrapper's STDOUT-line forwarder will see as non-marker lines (and ignore — confirmed in resume banner). No regression. |

---

## Summary

### Findings by severity (in-scope)

| Severity | Count | Phases |
|----------|-------|--------|
| BLOCKING | **2** (same root cause) | D9.1 (registry composer), D21.1 (boot-wim composer) — both `HKLM\z$($t.Hive)` double-z |
| DEVIATION (improvement, keep) | 8 | D5.1, D17.1, D18.1, D21.2, D23.1, D23.2 + others |
| DEVIATION (annotate / minor cleanup) | 6 | D4.1, D4.5, D5.3, D9.2, D9.3, D21.5 |
| DEVIATION (add visibility / capture exit code) | 4 | D4.3, D5.4, D21.3, D23.3 |
| DEVIATION (parity tweak) | 1 | D5.2 (`Select-Object -Skip 1`) |
| COSMETIC | 4 | D4.2, D4.4, D4.6, D9.7 |
| NON-BUG (verified, no action) | 6 | D5.5, D9.4, D9.5, D9.6, D17.3, D18.2, D21.4, D23.5 |

### Findings outside scope

11 observations logged (OOS-1 through OOS-11). None are blocking; most are deviations from upstream that improve robustness. Decision on whether to fold any of these into the follow-up fix commit belongs to the user.

### Fix priority for follow-up commit

1. **D9.1 + D21.1 (BLOCKING) — drop `\z` from `$mountKey = "HKLM\z$($t.Hive)"`** at lines 741 and 814. Single-character fix at each site (delete the literal `z`). This is the primary deliverable.
2. **D5.2** — add `\| Select-Object -Skip 1` to `Invoke-Tiny11CoreSystemPackageRemoval` for upstream parity. One-line.
3. **D4.3, D5.4, D21.3, D23.3** — capture exit codes / elevate failure visibility. ~5-10 lines total across the 4 sites.
4. **D5.3** — rename `$ScratchDir` parameter to `$MountDir` in `Invoke-Tiny11CoreSystemPackageRemoval`. Cosmetic but improves readability.
5. Annotate kept-deviations (D4.1, D5.1, D17.1, D18.1, D21.2, D23.2, OOS-3, OOS-5, OOS-7, OOS-9) with brief comments noting they're deliberate departures from upstream. Prevents the next implementer from "fixing" them back to upstream's broken or less-defensive form.

### Regression test recommendation

After D9.1 + D21.1 fix, add a Pester test that constructs a small synthetic registry hive, mounts it via Mount-Tiny11Hive, runs ONE entry from `Get-Tiny11CoreRegistryTweaks` through the composer's reg-write logic, dismounts, and verifies the value landed at the expected path inside the hive file. This catches a future return of the double-z bug or any other path-formation regression. Suggested name: `tests/Tiny11.Core.RegistryComposer.Tests.ps1`.

### What this audit does not verify

- **Resulting Win11 ISO bootability.** The audit covers code-path correctness against upstream; whether the resulting ISO actually boots in Hyper-V Gen2 / VirtualBox / bare metal is Phase 7 C3 and remains user-driven.
- **Performance.** No timing claims about Phase 8 WinSxS-wipe or Phase 22 install.esd export.
- **Catalog-driven mode** (`Invoke-Tiny11BuildPipeline` in `Tiny11.Worker.psm1`). Out of scope; that path is the v0.1.0 / v0.2.0 catalog mode and is unaffected by Core mode bugs.
