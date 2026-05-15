# Audit: PowerShell modules (v1.0.8 cycle)

**Date:** 2026-05-15
**Scope:** `src/Tiny11.*.psm1` (13 modules in stated scope; `Tiny11.Bridge.psm1` and `Tiny11.WebView2.psm1` adjacent and spot-checked)
**Branch:** `main` at `285f7b6` (post-v1.0.7)
**Auditor:** parallel subagent (no session context)

## Summary

- BLOCKER: 1
- WARNING: 8
- INFO: 12

The PostBoot module is significantly more robust than at the v1.0.1 audit (most of that audit's BLOCKER/WARNING items have been fixed and the rationale is documented inline). Most of the residual risk sits in Core mode (the 1599-line Tiny11.Core.psm1), which composes two huge inline catalog data tables plus inline reg.exe loops that diverge from the catalog-driven path used by Worker. Two areas dominate the new findings: (1) registry-pattern-zero's offline enumeration via `Get-ItemProperty | Get-Member -MemberType NoteProperty` will mis-handle real registry values whose names happen to be PowerShell PSObject "ghost" properties (PSPath/PSParentPath/etc.); (2) several finally-blocks have a subtle resource-leak shape where a thrown exception escaping after a mount succeeds is not guaranteed to unwind cleanly.

---

## B1 — `registry-pattern-zero` offline enumeration drops real `PSPath`/`PSChildName`-shaped value names; matches "ghost" properties when pattern is broad enough

**Severity:** BLOCKER
**File:** `src/Tiny11.Actions.Registry.psm1:140-143` (offline path); `src/Tiny11.PostBoot.psm1:297-300` (online path)

Both paths enumerate registry value names via the pattern:

```powershell
$names = @(Get-ItemProperty -LiteralPath $psPath -ErrorAction SilentlyContinue |
           Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
           Where-Object Name -like $Action.namePattern |
           Select-Object -ExpandProperty Name)
```

`Get-ItemProperty` returns a PSCustomObject whose properties include both the actual registry value names AND PowerShell-injected metadata properties: `PSPath`, `PSParentPath`, `PSChildName`, `PSDrive`, `PSProvider`. `Get-Member -MemberType NoteProperty` returns every NoteProperty — and the PowerShell-injected ones appear as NoteProperty on the wrapping PSObject. The current catalog's only `registry-pattern-zero` action uses `namePattern='SubscribedContent-*Enabled'`, which doesn't match any `PS*` name, so it's currently harmless. But the moment any user adds an action with a broader pattern (e.g., `namePattern='PS*'`, `*Path*`, `Provider*`), or Microsoft ships an inbox value whose name collides with a PS-injected property name, the helper will (a) write `0` to a non-existent value (silent no-op on offline `reg.exe add` path, but DAMAGING on online `Set-RegistryValue` path because it CREATES a `PSPath` value with type `REG_DWORD` 0 under the registry key), and (b) miss the real values.

Worse, in the online path (`PostBoot.psm1:306`), `Set-RegistryValue -KeyPath $userKey -Name $name -Type $Type -Value 0` will happily create a `REG_DWORD` value literally named `PSPath` with data `0` under each user's `Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` — visible in regedit, persistent across reboots, and counted by every Microsoft enterprise audit tool as an unknown vendor write. Since the pattern is user-extensible at catalog time (no allowlist, no exclude-PS-properties filter), this is a real production hazard.

Fix: use `Get-Item -LiteralPath $psPath | Select-Object -ExpandProperty Property` — which returns the actual registry value names array from the provider, with no PSObject metadata pollution. Or explicitly exclude `PS*` names in the filter (`Where-Object { $_.Name -like $namePattern -and $_.Name -notlike 'PS*' }`).

---

## A1 — `Mount-DiskImage -PassThru` race against `Get-Volume` returns null intermittently

**Severity:** WARNING
**File:** `src/Tiny11.Iso.psm1:31-33`

```powershell
$img = Mount-DiskImage -ImagePath $resolved.IsoPath -PassThru
$vol = Get-Tiny11VolumeForImage -DiskImage $img
if (-not $vol -or -not $vol.DriveLetter) { throw "Mount succeeded but no drive letter assigned to $($resolved.IsoPath)" }
```

`Mount-DiskImage -PassThru` returns the DiskImage object as soon as the kernel reports the image attached, but the SCSI bus rescan / drive-letter assignment happens slightly later asynchronously. On a busy box (large background I/O), `Get-Volume` can race the assignment and return an object whose `DriveLetter` field is null — the throw fires and the build aborts with a confusing message even though a `Start-Sleep -Milliseconds 500` retry would succeed. Upstream tiny11builder solved this with a Sleep+retry loop; we removed that and lost the retry. Add a small (≤5s, ~100ms increment) poll loop on `Get-Volume` before declaring failure.

---

## A2 — `Get-Tiny11AutounattendTemplate` silently overwrites local template on network success

**Severity:** WARNING
**File:** `src/Tiny11.Autounattend.psm1:82-95`

If `$LocalPath` does NOT exist, the function fetches from GitHub and writes the response to `$LocalPath` via `Set-Content -Path $LocalPath -Value $content -Encoding UTF8`. The function header says "Local-then-Network-then-Embedded fallback" — but the result is that the *first* invocation that has no local file on disk silently materializes one from the network, which becomes "Local" for every subsequent invocation. If GitHub serves a malformed template (or attacker MITMs the unauthenticated HTTPS — HSTS for raw.githubusercontent.com is in place but not pinned), the bad template gets cached to disk indefinitely. There's no integrity check (no SHA-256 expected hash, no signature) and no auto-refresh.

Also: the cache file is written next to the catalog (via the Worker's `Join-Path (Split-Path $Catalog.Path) '..\autounattend.template.xml'` path), which means a Worker build that succeeds once will use the *first build's* network-cached template forever, even if upstream subsequently fixes a bug in the template. Either (a) drop the disk-cache and rely on Embedded fallback for network-failure cases, (b) add a content hash check pinned at build time, or (c) date-stamp the cache and expire after N days.

---

## A3 — Catalog schema validator does NOT validate `hive` for `registry-pattern-zero` actions

**Severity:** WARNING
**File:** `src/Tiny11.Catalog.psm1:47-49`

```powershell
if ($action.type -eq 'registry' -and ($action.PSObject.Properties.Name -contains 'hive') -and ($action.hive -notin $ValidHives)) {
    throw "Catalog item '$($item.id)' has invalid hive: $($action.hive)"
}
```

The check fires only for `type == 'registry'`. The dispatcher accepts `registry-pattern-zero` as a separate type and also reads `hive`. The catalog at HEAD has `registry-pattern-zero` with `hive: NTUSER` (line 139), which is correctly handled by the dispatcher. But a typo in a future catalog change (`hive: NTUSR`, `hive: HKEY_CURRENT_USER`) would bypass schema validation entirely and surface only at offline-build runtime as a thrown exception deep inside `Invoke-RegistryPatternZeroAction` — which would have already mounted hives. Widen the check: `if ($action.type -in @('registry','registry-pattern-zero')) { ... }`.

Same issue applies to required-field validation: `registry-pattern-zero` requires `namePattern` and `valueType` and `key` and `hive`. The schema validator doesn't enforce any of those — they're caught at dispatch time inside the action module, after hives are already mounted. Required-field validation belongs at the catalog-load boundary.

---

## A4 — `Test-IsKnownBenignTakeownIcaclsNoise` matches messages but `Invoke-NativeWithNoiseFilter` only filters `ErrorRecord` instances

**Severity:** WARNING
**File:** `src/Tiny11.Actions.Filesystem.psm1:37-44`

```powershell
& $FileName @Arguments 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
        $msg = $_.Exception.Message
        if (-not (Test-IsKnownBenignTakeownIcaclsNoise -Line $msg)) {
            [System.Console]::Error.WriteLine($msg)
        }
    }
}
```

Three issues:

1. **Stdout is dropped completely.** If `$_ -is [ErrorRecord]` is false (i.e., normal stdout) the line is silently consumed and goes nowhere. That matches the original `| Out-Null` semantics for `Invoke-Takeown` and `Invoke-Icacls`, but the comment claims "Stdout is dropped, matching the pre-v1.0.7 `| Out-Null` behavior" — and DOES drop it. The functional effect is that takeown.exe's "SUCCESS: ..." lines are now invisible even with `-Verbose`. Previously they showed on-screen during the v1.0.6 builds. Mild regression in observability.

2. **Real stderr that comes through as PSObject-wrapped string** (not as `ErrorRecord`) is also dropped. When PowerShell merges streams with `2>&1`, the exact wrapping behavior depends on whether the native command emits via `WriteErrorLine` vs `WriteError`. In some PS 5.1 builds, native stderr lines arrive as strings (not ErrorRecords), so the noise-filter path doesn't even fire on them. The legacy v1.0.6 `2>&1 | Out-Null` was symmetric (drop both); the new filter is asymmetric (drop strings unconditionally + drop only-matching ErrorRecords). On a system that emits stderr as strings, the entire filter is a no-op and real errors are dropped.

3. **The benign-patterns array uses backslash-escape for literal `\` and explicit-escape for `*`**: `'Windows\\System32\\LogFiles\\WMI\\RtBackup\\\*:\s+Access is denied\.'`. That's correct — the regex sees `Windows\System32\LogFiles\WMI\RtBackup\*: Access is denied.`. But the pattern is anchored neither at start nor end. A path like `C:\malicious\Windows\System32\LogFiles\WMI\RtBackup\*: Access is denied.` would also match. Low risk in practice (no attacker controls the takeown.exe args at this point), but `^` / `$` anchors would be defensive.

Fix: switch to `if ($_ -is [ErrorRecord]) { $msg = $_.Exception.Message } else { $msg = [string]$_ }` and apply the filter to both branches. Anchor the regexes with `^` (since takeown.exe / icacls.exe emit each error on its own line and the noise-suppression test reads line-by-line, `^` is safe and adds defense-in-depth).

---

## A5 — `Get-Tiny11AutounattendBindings`: dropping the `$ResolvedSelections` lookup defaults to `'apply'` — silent behavior change if item IDs are renamed

**Severity:** WARNING
**File:** `src/Tiny11.Autounattend.psm1:66-69`

```powershell
function State($id) { if ($ResolvedSelections.ContainsKey($id)) { $ResolvedSelections[$id].EffectiveState } else { 'apply' } }
```

If a future catalog rename changes `tweak-bypass-nro` → `tweak-bypass-nro-v2` (or just removes it), `Get-Tiny11AutounattendBindings` silently treats that as "apply", overriding the user's actual selection. The user selected `skip` (kept the OOBE network screen), but the rendered autounattend.xml has `<HideOnlineAccountScreens>true</HideOnlineAccountScreens>` anyway. Result: behavior diverges from the user's intent without any error.

Fix: when the ID is absent from `$ResolvedSelections`, throw. Catalog item IDs ARE load-bearing — if the bindings function references one that doesn't exist, it's a coding error (the bindings function is in lockstep with the catalog) that should fail loudly.

---

## A6 — `Invoke-Tiny11BuildPipeline` finally-block leaks scratch dirs when robocopy partially succeeded

**Severity:** WARNING
**File:** `src/Tiny11.Worker.psm1:194-203`

The outer `finally` removes `$tinyDir` and `$scratchImg` unconditionally. If the user cancels mid-copy via `CancellationToken`, the cleanup runs while robocopy still has files open with delete-on-close share modes, and `Remove-Item -Recurse -Force -EA SilentlyContinue` silently misses the locked files. The next build can be confused by stale partial trees.

Two layered issues:
- The `-ErrorAction SilentlyContinue` hides this from the user.
- robocopy can't actually be CHECK-cancelled — `& 'robocopy.exe' ...` runs to completion before `CheckCancel` fires.

Stop swallowing the Remove-Item errors silently; surface "Some scratch files could not be deleted (rmdir-locked) — they will be cleaned at next build" to the user. The actual lock-release happens on next reboot; this is OK as long as the user knows.

---

## A7 — Core's offline catalog-application path is reachable only when `$PostBootCleanupCatalog -and $PostBootCleanupResolvedSelections`

**Severity:** WARNING
**File:** `src/Tiny11.Core.psm1:1392`

```powershell
if ($PostBootCleanupCatalog -and $PostBootCleanupResolvedSelections) {
    Invoke-Tiny11ApplyActions ...
}
```

The comment (lines 1379-1391) describes A11/v1.0.3 as restoring catalog-application symmetry with Worker. But the gate is `$PostBootCleanupCatalog -and $PostBootCleanupResolvedSelections` — both must be non-null. The launcher's CoreFromConfigBuilder always passes both, but any direct PS caller (smoke harness, ad-hoc CLI use of `Invoke-Tiny11CoreBuildPipeline`, a future entry-point that wants Core+catalog without post-boot cleanup) will SILENTLY skip catalog application. The function should not condition catalog application on the post-boot-cleanup *cargo* — those are two orthogonal concerns. Either rename the parameters to `$Catalog` / `$ResolvedSelections` to make their independence clear, or split into two gates so `$InstallPostBootCleanup` doesn't control whether catalog actions get applied at offline build time.

Also: when the user CHECKS "Build tiny11 Core" but UNCHECKS "Install post-boot cleanup task", the launcher currently does pass `$PostBootCleanupCatalog` (`-NoPostBootCleanup` is the cleanup-task gate, not the offline-apply gate). Verify this is the case in `tiny11Coremaker-from-config.ps1`. If it isn't, Core+NoPostBootCleanup ships an ISO where the catalog never landed.

---

## A8 — Core `Start-CoreProcess` localizes `$ErrorActionPreference` but doesn't capture `$LASTEXITCODE` atomically

**Severity:** WARNING
**File:** `src/Tiny11.Core.psm1:474-486`

```powershell
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = & $FileName @Arguments 2>&1
    $exit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEAP
}
```

The native command runs inside the try, but `$LASTEXITCODE` is read in the same `try` block. If `& $FileName @Arguments 2>&1` itself raised a PowerShell terminating error (e.g., `FileName` does not exist on disk), the exception propagates out of the try, the `finally` restores EAP, and `$exit` is never assigned. The function then exits returning a `[pscustomobject]` with `ExitCode = $null` (under StrictMode, this would actually throw on the access to `$exit`, but `$exit` was declared at function scope as `$null`). Result: caller misinterprets "no exit code" as "exit code 0" if it doesn't validate.

Better: surround with explicit `try { ... } catch { ... }` and re-throw with context like "Start-CoreProcess: invocation of '$FileName' failed before exit-code was captured: $($_.Exception.Message)". Also under StrictMode, `$exit` should be initialized to a sentinel (e.g., `$exit = -1`) before the try.

---

## I1 — `HKU:\.DEFAULT` write in `Get-Tiny11RegistryOnlineCommand` is dead — catalog never uses `hive: DEFAULT` for online emission

**Severity:** INFO
**File:** `src/Tiny11.Actions.Registry.psm1:43`

The 2026-05-13 v1.0.1 audit BLOCKER-1 flagged this: `'DEFAULT' { 'HKU:\.DEFAULT' }` writes to the LOCAL_SERVICE / NETWORK_SERVICE hive, not the new-user template. The catalog at HEAD uses `hive: DEFAULT` only for `tweak-bypass-hardware-checks` (catalog.json:162-163), and for that item the same registry values are also written via `hive: NTUSER` (lines 164-165) — so the user-visible behavior (new users see the bypass) is delivered through the NTUSER fan-out path. The `DEFAULT` writes are functionally redundant.

But the code path is still wrong: the online emitter (`Set-RegistryValue` against `HKU:\.DEFAULT` at runtime) actively writes to the LOCAL_SERVICE hive, which is unrelated to the intent. The offline path is similar (writes to `Windows\System32\config\default` — system DEFAULT hive). Removing `'DEFAULT'` from the catalog and renaming it to NTUSER everywhere would eliminate the dead writes. Alternatively, drop `'DEFAULT'` from `$ValidHives` in `Tiny11.Catalog.psm1:4` so the catalog can no longer use it.

---

## I2 — `runtimeDepsOn` semantics are inverted relative to the field name

**Severity:** INFO
**File:** `src/Tiny11.Selections.psm1:26-34`

The field is called `runtimeDepsOn`, suggesting "this item depends on these items at runtime." The code uses it as a *reverse* dependency: "if I (item A) am `skip`, lock items in my `runtimeDepsOn` list to `skip` too." So `runtimeDepsOn` actually means "if I am NOT applied, these items must NOT be applied either" — i.e., it's a co-removal lock from the other direction. A more accurate field name: `lockApplyOnSkip` or `forceSkipWhenSkipped`. Current naming reads as "I depend on X" but the relationship is "X depends on me." Misnamed but functionally correct; rename in a future catalog-version bump.

---

## I3 — `Get-Tiny11Catalog` validates field PRESENCE but not field TYPE

**Severity:** INFO
**File:** `src/Tiny11.Catalog.psm1:30-52`

The validator checks that each item has `id`, `category`, `displayName`, etc., but does NOT check that `actions` is an array (could be a single object), that `runtimeDepsOn` is an array of strings, that `default` is exactly the string `'apply'` or `'skip'` (it does check this — line 40), or that `actions[*].value` is a string for non-binary types. Malformed catalog JSON could pass validation but throw at action-dispatch time.

Add light type checks: `if ($item.actions -isnot [array]) { throw "..." }`, `if ($item.runtimeDepsOn -isnot [array]) { throw "..." }` — failure-mode improvement.

---

## I4 — `Set-StrictMode` flags `runtimeDepsOn` array-access if catalog field is missing on a future schema rev

**Severity:** INFO
**File:** `src/Tiny11.Selections.psm1:29`

`foreach ($dep in $item.runtimeDepsOn)` — the schema validator ensures `runtimeDepsOn` is always present (it's in the required-fields list on line 32 of Catalog.psm1). But the field type check is absent (see I3), so an item with `"runtimeDepsOn": null` would pass validation and reach this loop. Under StrictMode, `foreach ($dep in $null)` is a no-op (does NOT throw), so this is currently safe. Worth noting if anyone strengthens the type check or adds a coerce-to-array pass.

---

## I5 — `Invoke-RegCommand` strips `$LASTEXITCODE` but does not differentiate "already absent" from "permission denied" on `delete`

**Severity:** INFO
**File:** `src/Tiny11.Hives.psm1:25-29`

```powershell
function Invoke-RegCommand {
    param([Parameter(ValueFromRemainingArguments)][string[]]$RegArgs)
    $captured = (& reg.exe @RegArgs) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg.exe failed (exit $LASTEXITCODE): $($RegArgs -join ' ')`n$captured" }
}
```

The `Invoke-RegistryAction` caller (Actions.Registry.psm1:24-27) catches the throw and re-throws unless the message matches `'unable to find'`. That's a string-match contract against reg.exe's localized output — on a German-locale Windows host, reg.exe will say "Das System kann den angegebenen Pfad nicht finden" or similar, and the catch will re-throw, aborting the build. The fix is `$LASTEXITCODE`-based: reg.exe returns exit code 1 for "key not found" specifically (vs other failure modes like exit code 5 for "Access denied"). Distinguishing on exit code is locale-independent.

In practice the build host is the user's box (American/English-locale Windows in 95%+ of cases), and this hasn't bitten. But anyone shipping tiny11options as a multilingual offering would hit this immediately.

---

## I6 — `Mount-Tiny11AllHives` / `Dismount-Tiny11AllHives` foreach-order is hashtable-key-order, not deterministic

**Severity:** INFO
**File:** `src/Tiny11.Hives.psm1:47, 52`

Both loops iterate `$HiveMap.Keys`. `$HiveMap` is a plain `@{}` hashtable (line 3) — PS 5.1 hashtable enumeration order is insertion-ordered in practice but not guaranteed by spec. The mount order is `COMPONENTS, DEFAULT, NTUSER, SOFTWARE, SYSTEM` if PS preserves insertion order (which it does for non-large hashtables in PS 5.1), but `[ordered]@{}` would make this explicit and immune to a future PS version. Cosmetic but worth a one-line fix. The Core module's hive load/unload at lines 1341 and 1403 uses an explicit array `@('COMPONENTS','DEFAULT','NTUSER','SOFTWARE','SYSTEM')` — that's the right pattern. Apply it to the Hives module.

---

## I7 — Worker's `oscdimgCache` resolution falls through to scratch dir on `Resolve-Path -ErrorAction SilentlyContinue` miss

**Severity:** INFO
**File:** `src/Tiny11.Worker.psm1:184-187`

```powershell
$oscdimgCache = Join-Path (Split-Path $Catalog.Path) '..\dependencies\oscdimg' | Resolve-Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path
if (-not $oscdimgCache) {
    $oscdimgCache = (New-Item -ItemType Directory -Force -Path (Join-Path $ScratchDir 'oscdimg-cache')).FullName
}
```

Under StrictMode, `Resolve-Path | Select-Object -ExpandProperty Path` against a non-existent path returns `$null`, which the `-not` check handles. But the layered pipeline silently masks "I couldn't find your bundled oscdimg because the path is mistyped" vs "ADK has it cached, use that." The fallback Then downloads oscdimg from MSDL (Worker.psm1:215 — `https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe`).

The MSDL URL is hardcoded with a specific Microsoft Symbol Server build ID (`3D44737265000`). When Microsoft rotates that, the build breaks silently in the field on machines without ADK installed. Add a hash check on the downloaded oscdimg.exe, or surface a clear error if the URL 404s. Currently `Invoke-WebRequest` on 404 throws and the throw propagates without context.

This is also a local-dependencies-only concern at the architecture level (per the user's global rules): oscdimg.exe is a binary dependency. We have a `dependencies\oscdimg` location for it; we should NOT fall back to downloading at build time. Ship the binary with the app or fail with a clear "bundled oscdimg.exe missing" message pointing to the dependency folder. (Note: this is a comment for the user's broader principle — does not block v1.0.8.)

---

## I8 — Worker's autounattend template cache write path uses `'..\autounattend.template.xml'` with positional `Set-Content -Path`

**Severity:** INFO
**File:** `src/Tiny11.Autounattend.psm1:89`

`Set-Content -Path $LocalPath -Value $content -Encoding UTF8` — positional `-Path`, not `-LiteralPath`. If a future user puts the catalog in a folder whose parent has `[`/`]` in the name (unlikely but legal on NTFS), `Set-Content` would mis-parse as a wildcard. Same WildcardPattern.Escape fix as the PostBoot `Set-RegistryValue` already applies. Cosmetic.

---

## I9 — `Test-IsKnownBenignTakeownIcaclsNoise` regexes are not case-insensitive but Windows file paths ARE

**Severity:** INFO
**File:** `src/Tiny11.Actions.Filesystem.psm1:12-15`

The patterns `'Windows\\System32\\LogFiles\\WMI\\RtBackup\\\*:\s+Access is denied\.'` match exact case. NTFS is case-insensitive, so takeown could in principle emit `windows\system32\logfiles\wmi\rtbackup\*: ...` and the filter would miss it. In practice takeown.exe emits paths in the exact case Microsoft stores them (PascalCase here), so this works. PowerShell `-match` is case-insensitive by default — but only when used as an operator, not for `[regex]::Match`. The filter uses `-match $pattern` operator (line 21), so case-insensitivity IS active. Confirmed safe; documenting for future maintainers who might switch to `[regex]::Match`.

---

## I10 — Bridge module's `Invoke-Tiny11BridgeHandler` accepts `$Message` as untyped and lookups `$Message.type` under StrictMode

**Severity:** INFO
**File:** `src/Tiny11.Bridge.psm1:11-18`

The function is called by the harness handler glue; a malformed message lacking `type` would throw at the `$Message.type` access under StrictMode (PropertyNotFoundException). The function intends to throw `"No handler registered for message type: $($Message.type)"` — the access happens twice (line 14 lookup, line 15 message). If `type` is missing, the lookup throws *before* the user-friendly error message is composed. Caller sees PropertyNotFoundException instead of "missing message type." Add `if (-not $Message.PSObject.Properties['type']) { throw "Bridge message missing 'type' field" }` as the first check.

---

## I11 — Post-boot cleanup script's helpers do not import `Microsoft.PowerShell.Management` (just defensive coverage)

**Severity:** INFO
**File:** `src/Tiny11.PostBoot.psm1:86+`

The helpers block uses `New-Item`, `Get-ItemProperty`, `Set-ItemProperty`, `Test-Path`, `Get-ChildItem`, `Move-Item`, `Add-Content`, `Get-PSDrive`, `New-PSDrive` — all from `Microsoft.PowerShell.Management`. That module IS auto-loaded by every Windows PowerShell session, so there's no actual gap. Documenting for completeness because the v1.0.1 audit B3 was about a similar Appx-module auto-load assumption that actually didn't hold; if anyone debloats `Microsoft.PowerShell.Management` from a future image (unlikely but technically possible), the script would fail. Add an explicit `Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue` to the header block for symmetry with the Appx fix that B3 forced.

---

## I12 — `New-Tiny11CoreWuEnforceScript` HEREDOC uses single-quote escaping but is a CRLF-encoded UTF-8 (no BOM) write

**Severity:** INFO
**File:** `src/Tiny11.Core.psm1:1029-1030`

```powershell
$ps1ContentCRLF = ($ps1Content -split "`r?`n") -join "`r`n"
[System.IO.File]::WriteAllText($ps1Path, $ps1ContentCRLF, [System.Text.Encoding]::UTF8)
```

`[System.Text.Encoding]::UTF8` is **UTF-8 with BOM** in .NET Framework but **UTF-8 without BOM** in .NET 5+. The runtime here is Windows PowerShell 5.1 (.NET Framework 4.x), so this writes WITH BOM. Cross-reference: the v1.0.0 launcher build switched from .NET 6 to .NET 9 for the launcher's C# side, but the PS modules still run under PS 5.1 (.NET Framework). The PS 5.1 `Set-Content -Encoding UTF8` quirk (writes WITH BOM) is well-known; this `[System.Text.Encoding]::UTF8` call also writes with BOM under .NET FW. Confirmed safe — PS 5.1 reads UTF-8-with-BOM correctly. But if a future migration runs these helpers under PS 7 / .NET 9, the same code path writes WITHOUT BOM, and PS 5.1 reading that file would treat it as Windows-1252 and mangle multi-byte chars. The PostBoot equivalent at `Tiny11.PostBoot.psm1:529-532` correctly uses `[System.Text.UTF8Encoding]::new($true)` (explicit BOM=true). The Core path here uses `[System.Text.Encoding]::UTF8` which is BOM-vs-no-BOM dependent on runtime. **Standardize on `[System.Text.UTF8Encoding]::new($true)` everywhere a PS script is written.**

Also `Tiny11.PostBoot.psm1:529-532` is correct; `Tiny11.Core.psm1:1030` is the inconsistent one.

---

## Cross-reference verification (README / CHANGELOG / catalog.json)

| Claim | Where | Verdict |
|---|---|---|
| README: "Post-boot cleanup task runs at boot+10min, daily 03:00, on every WU EventID 19" | line 119 | **Matches code.** `Tiny11.PostBoot.psm1:425-437` defines BootTrigger PT10M + CalendarTrigger 03:00 + EventTrigger EventID=19. |
| README: "Idempotent — already-correct state is a fast read-and-skip" | line 124 | **Matches code.** All `Set-RegistryValue` paths check `$current -eq $Value` (with REG_MULTI_SZ Compare-Object fix per v1.0.1 audit W3). |
| README: "Logs to C:\Windows\Logs\tiny11-cleanup.log (5000-line rolling, ~3 months of history)" | line 124 | **Matches code.** Header block lines 23-39 implement the rotation. 5000 lines = ~3 months IF the task fires at the trigger cadence stated (every ~24h on Calendar + on WU events + on boot). Reasonable approximation. |
| README: "Items you chose to KEEP at build time will always stay" | line 134 | **Matches code.** Generator at `Tiny11.PostBoot.psm1:375-399` skips items whose `EffectiveState != 'apply'`. The skipped-item paths never emit removal commands. |
| README: "tiny11 Core: removes WinSxS preserving ~30 retained subdirs" | line 166 | **Matches code.** `Get-Tiny11CoreWinSxsKeepList` returns 29 entries for amd64 (after de-dupe at line 230), 28 entries for arm64. |
| README: "Core requires post-boot cleanup to do online /Cleanup-Image /StartComponentCleanup /ResetBase because 25H2+ CBS rejects offline" | line 165+ inferred | **Matches code.** Phase 3.5 (Core.psm1:1257-1261) does best-effort offline RevertPendingActions but warns; Phase 18 (Core.psm1:1431-1435) injects SetupComplete.cmd which runs the cleanup online. |
| README line 128: v1.0.1 limitation describing "4 of 11 ContentDeliveryManager values covered" | line 128 | **STALE.** The current catalog has all 11 + the pattern-zero action. Catalog.json:139 is the registry-pattern-zero entry. The v1.0.1-era limitation note should be removed or updated to reflect "Catalog completeness landed in v1.0.3." This is a docs-consistency concern, not a code concern, so it belongs in the docs scope; flagging here because I noticed it. |
| Catalog action types referenced | catalog.json | All five present types (`provisioned-appx`, `registry`, `registry-pattern-zero`, `filesystem`, `scheduled-task`) have dispatcher entries in `Tiny11.Actions.psm1:10-17` and online emitters in respective modules. Confirmed. |
| Catalog uses `hive: DEFAULT` for `tweak-bypass-hardware-checks` | catalog.json:162-163 | See I1: works at runtime via the NTUSER companion writes, but the DEFAULT writes are dead. Cosmetic but worth cleanup. |

---

## Module-level summary

| Module | Strict-mode safe? | Resource lifecycle? | Encoding correct? | Major risk? |
|---|---|---|---|---|
| `Tiny11.Actions.Filesystem.psm1` | Yes | n/a (no mounts) | n/a | A4 (noise filter asymmetry) |
| `Tiny11.Actions.ProvisionedAppx.psm1` | Yes | DISM cache only | n/a | None |
| `Tiny11.Actions.Registry.psm1` | Yes | n/a | n/a | **B1 (pattern-zero enum)** + I1 (DEFAULT dead path) |
| `Tiny11.Actions.ScheduledTask.psm1` | Yes | n/a | n/a | None |
| `Tiny11.Actions.psm1` | Yes | n/a | n/a | None |
| `Tiny11.Autounattend.psm1` | Yes | network cache | UTF8 (PS Set-Content) | A2 (template cache write), A5 (missing-id default to apply) |
| `Tiny11.Bridge.psm1` | Yes | n/a | n/a | I10 (untyped message) |
| `Tiny11.Catalog.psm1` | Yes | file I/O | UTF8 read | A3 (registry-pattern-zero hive validation gap), I3 (no type checks) |
| `Tiny11.Core.psm1` (1599 lines) | Yes | DISM mount + hive mounts + scratch dirs | UTF8 BOM via Set-Content; `[System.Text.Encoding]::UTF8` in places (see I12) | A7 (catalog-application gated on cleanup), A8 (Start-CoreProcess race), I12 (encoding inconsistency vs PostBoot) |
| `Tiny11.Hives.psm1` | Yes | reg load/unload (lifecycle in Worker / Core) | n/a | I5 (locale-fragile error match), I6 (hashtable-key order) |
| `Tiny11.Iso.psm1` | Yes | Mount-DiskImage lifecycle | n/a | A1 (mount/Get-Volume race) |
| `Tiny11.PostBoot.psm1` | Yes (in generator) and **generated script does NOT** (per v1.0.1 audit I1, still true) | hive load + PSDrive | UTF8 BOM correct | **B1 (pattern-zero enum, online path)**, I11 (Management module assumed) |
| `Tiny11.Selections.psm1` | Yes | n/a | UTF8 | I2 (naming), I4 (null-array safety) |
| `Tiny11.Worker.psm1` | Yes | DISM mount + Mount-DiskImage + scratch dirs | UTF8 Set-Content | A6 (silent scratch cleanup failure), I7 (oscdimg fallback download) |

---

## Notes on PS 5.1 vs PS 7 compatibility

All modules in scope use PS 5.1-safe constructs only. Confirmed:

- `[ordered]@{}` — present from PS 3+
- `Set-StrictMode -Version Latest` — present from PS 3+
- `[WildcardPattern]::Escape()` — present from PS 1+
- Native command splatting `& $exe @args` — PS 3+
- `Get-CimInstance` not used (would gate against PS 5.1 servicing levels)
- No `??` (null-coalescing) or `?.` (null-conditional) operators
- No `[Math]::Clamp` (PS 7-only)
- No `Where-Object Name -like 'X'` form requires PS 4+ (present); confirmed available in 5.1

Generated `tiny11-cleanup.ps1` (PostBoot) and `tiny11-wu-enforce.ps1` (Core) target PS 5.1 SYSTEM-context scheduled-task execution — both correctly assume `powershell.exe` (not `pwsh.exe`) and use only PS 5.1-safe constructs.

---

## Recommendations for v1.0.8 cycle

1. **B1 (BLOCKER)**: Fix the `Get-Member -MemberType NoteProperty` enumeration in both `Invoke-RegistryPatternZeroAction` and `Set-RegistryValuePatternToZeroForAllUsers` before any user adds a broader catalog pattern. Replace with `Get-Item -LiteralPath $psPath | Select-Object -ExpandProperty Property`. Add a Pester case exercising a key with `PSPath`-shaped value names.

2. **A3 (cheap, 1-line)**: Widen the catalog hive validation to cover `registry-pattern-zero`.

3. **A5 (1-line + tests update)**: Make `Get-Tiny11AutounattendBindings` throw on missing ID instead of defaulting to `apply`. Add a guard test.

4. **A4 (small refactor)**: Apply the noise filter symmetrically to string AND ErrorRecord branches; anchor regexes with `^`.

5. **I12 (1-line)**: Switch Core's tiny11-wu-enforce.ps1 / SetupComplete.cmd / tiny11-wu-enforce.xml writes from `[System.Text.Encoding]::UTF8` to explicit `[System.Text.UTF8Encoding]::new($true)` to match PostBoot.

6. **A1 (small Iso.psm1 fix)**: Add a 100ms-increment poll loop with ~5s ceiling around `Get-Volume` after `Mount-DiskImage`.

The remaining items (A2 template-cache integrity, A6 robocopy cleanup messaging, A7 catalog-vs-cleanup gate split, A8 Start-CoreProcess hardening, the various INFO entries) are improvements but not user-facing v1.0.8 must-haves. The B1 finding is the only one that warrants a v1.0.8 hot-patch on its own merits.
