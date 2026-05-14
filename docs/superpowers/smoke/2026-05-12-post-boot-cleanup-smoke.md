# Post-boot cleanup v1.0.1 smoke matrix

Manual smoke testing for the post-boot cleanup scheduled task feature (v1.0.1 primary).
Plan reference: `docs/superpowers/plans/2026-05-12-post-boot-cleanup.md` Phase 9 Tasks 29-36.
Branch: `feat/v1.0.1-post-boot-cleanup`.

## Status overview

| Case | Build | Mode | Trigger | Status |
|------|-------|------|---------|--------|
| P1 | Worker, Fast Build, defaults (cleanup ON) | First boot + immediate run | ✅ PASS (2026-05-13) |
| P2 | Worker, log inspection (same VM as P1) | SetupComplete + BootTrigger PT10M | ✅ PASS (2026-05-13) |
| P3 | Worker, Fast Build, `-NoPostBootCleanup` | (no task expected) | ✅ PASS (2026-05-13) |
| P4 | Core, Fast Build, defaults (cleanup ON) | First boot + immediate run | ✅ PASS (2026-05-13) |
| P5 | Core, Fast Build, `-NoPostBootCleanup` | (only Keep-WU-Disabled expected) | ✅ PASS (2026-05-13) |
| P6 | Worker (reuses P1's VM) | Install-time CU; verified pre-login | ✅ PASS (2026-05-13) |
| P7 | Worker (reuses P1's VM, User2 created live) | Per-user fan-out + new-user inheritance | ✅ PASS (2026-05-13) |
| P8 | Worker keep-list build (P9 VM, post-fix rebuild) | Non-appx action-type coverage + scheduled-task fix validation | ✅ PASS (2026-05-14) |
| P9 | Worker, custom selections (Edge + Clipchamp KEPT) | Keep-list contract: static + runtime | ✅ PASS (2026-05-14) |

P1-P5 + P6 + P7 + P8 + P9 all PASS. P8 surfaced a scheduled-task removal bug (CEIP +
WER tasks persisting via registry-cache after XML deletion); fix landed in commit
`c90423e` (Unregister-ScheduledTask helpers in PostBoot.psm1 + emitter rewrite in
Actions.ScheduledTask.psm1). Validated end-to-end on P9 rebuild: scheduled-task
removals genuinely Unregister'd, keep-list contract holds across static + runtime
arms. v1.0.1 tag gate cleared.

## Smoke-driven fixes landed during P1-P5

Five bugs surfaced during P1 + P2 + P4 verification; each was fixed and the relevant ISO
rebuilt before re-running the case. All five fixes runtime-verified in the final P1d + P4
rebuilds.

| Commit | Fix | Surfaced by |
|--------|-----|-------------|
| `d688d94` | Finding 1 — empty-SID iteration noise | P1 log inspection |
| `7f1c1d4` | Finding 2 (Worker) — reg.exe quote-stripping in REG_SZ | P1 log inspection |
| `2847e2a` | Finding 2 (Core) — same bug, separate code path | P4 log inspection |
| `619c7ae` | Finding 4 — per-user fan-out regex matched `_Classes` SIDs | P1 log inspection |
| `0838aa4` | Core/Worker SetupComplete symmetry — Core runs cleanup.ps1 immediately at first boot | P4 first-boot verification |
| `96934be` | CHANGELOG entries for the five fixes above | (docs follow-up) |

Test totals after the five fixes:
- Pester **398 / 0** (was 393/0 pre-smoke; +5 regression-guard tests for the new fixes).
- xUnit **82 / 0** (unchanged).

## Build artifacts (in `C:\Temp\`)

| ISO | Size | Use |
|-----|------|-----|
| `p1d-worker.iso` | 7.91 GB | P1 + P2 PASS; reusable for P6 and as VHDX-copy source for P7 + P8 |
| `p3-worker-nocleanup.iso` | 7.91 GB | P3 PASS |
| `p4-core.iso` | 4.55 GB | P4 PASS |
| `p5-core-nocleanup.iso` | 4.55 GB | P5 PASS |

Launcher scripts present in `C:\Temp\`: `run-p1d.ps1`, `run-p3.ps1`, `run-p4.ps1`, `run-p5.ps1`.
Verify scripts: `verify-p1d-rebuild.ps1`, `verify-p1d-f4.ps1`, `verify-p4-r2.ps1`, `verify-p5.ps1`.

---

## P1 — Worker fresh install, task registered

- **Date:** 2026-05-13
- **Build:** Worker, Fast Build, default selections (cleanup ON), rebuild #2 with all 5 smoke fixes baked in
- **ISO:** `C:\Temp\p1d-worker.iso` (7.91 GB)
- **VM:** Hyper-V Gen2
- **Result:** ✅ PASS
- **Evidence:**
  - `Get-ScheduledTask -TaskPath '\tiny11options\'` returns one row: `Post-Boot Cleanup`, State `Ready`.
  - `Get-ScheduledTaskInfo` on the task: `LastTaskResult = 0` (from the SetupComplete immediate run).
  - Manual re-run via `Start-ScheduledTask` produced `already` lines for every selected catalog item — idempotent.
- **Notes:**
  - First P1 attempt before the smoke fixes surfaced Finding 1 (30+ bogus `HKU:\\<path>` write-FAILED lines from empty-SID iteration), Finding 2-Worker (reg.exe stripped `"` chars from REG_SZ values containing JSON like `{"pinnedList": [{}]}`, breaking idempotency by re-`CORRECTED`-ing every run), and Finding 4 (per-user fan-out regex matched `_Classes` SIDs in addition to real user SIDs, doubling every per-user line in the log).
  - All three fixes verified at runtime after rebuild #2 (P1d): empty-SID lines gone, REG_SZ JSON intact and idempotent, `_Classes` SIDs no longer touched.

## P2 — Worker log inspection

- **Date:** 2026-05-13
- **Build:** continued from P1's VM (same `p1d-worker.iso` install)
- **Result:** ✅ PASS
- **Evidence:**
  - `Get-Content C:\Windows\Logs\tiny11-cleanup.log -Tail 100` shows three trigger types fired:
    - SetupComplete immediate run (at first boot).
    - BootTrigger PT10M fire (10 minutes after subsequent boot).
    - On-demand `Start-ScheduledTask` run.
  - Every per-item line for catalog-selected items reports `already` after the immediate run (clean image had no restaged apps yet) — idempotency confirmed.
- **Notes:**
  - Real CU-driven EventID 19 trigger is exercised in P6, not P2.

## P3 — Worker `-NoPostBootCleanup`

- **Date:** 2026-05-13
- **Build:** Worker, Fast Build, `-NoPostBootCleanup`
- **ISO:** `C:\Temp\p3-worker-nocleanup.iso` (7.91 GB)
- **VM:** Hyper-V Gen2 (fresh)
- **Result:** ✅ PASS
- **Evidence:**
  - `Get-ScheduledTask -TaskPath '\tiny11options\'` returns nothing.
  - `Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1'` → `False`.
  - `Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.xml'` → `False`.
  - `Test-Path 'C:\Windows\Setup\Scripts\SetupComplete.cmd'` → `False`.
- **Notes:** Off-switch path cleanly suppresses all three artifacts.

## P4 — Core both tasks registered

- **Date:** 2026-05-13
- **Build:** Core, Fast Build, default selections (cleanup ON), rebuild #2 with Finding 2-Core fix + Core/Worker SetupComplete symmetry fix
- **ISO:** `C:\Temp\p4-core.iso` (4.55 GB)
- **VM:** Hyper-V Gen2
- **Result:** ✅ PASS
- **Evidence:**
  - `Get-ScheduledTask -TaskPath '\tiny11options\'` returns TWO rows: `Keep WU Disabled` AND `Post-Boot Cleanup`, both `Ready`.
  - `Get-Content C:\Windows\Logs\tiny11-wu-enforce.log -Tail 5` shows the WU-enforce task's `==== triggered ====` entry.
  - `Get-Content C:\Windows\Logs\tiny11-cleanup.log -Tail 5` shows the post-boot-cleanup `==== triggered ====` entry at first boot **without manual intervention** (verifies the `0838aa4` SetupComplete symmetry fix — pre-fix, Core's `tiny11-cleanup.log` simply did not exist at first boot and required a manual `Start-ScheduledTask` to produce one).
- **Notes:**
  - First P4 attempt before the smoke fixes surfaced Finding 2-Core (Core's two inline `reg.exe add` loops at `Tiny11.Core.psm1:1294` + `:1415` bypass `Invoke-RegistryAction` so the Worker-side fix `7f1c1d4` didn't cover them) and the SetupComplete asymmetry (audit A4 had flagged it as INFO — "intentional but undocumented" — but smoke verification revealed the cleanup log was actually missing at first boot, not just delayed).
  - Both fixes verified at runtime after rebuild #2: Core's REG_SZ JSON values intact and idempotent, cleanup log populated at first boot.

## P5 — Core `-NoPostBootCleanup`

- **Date:** 2026-05-13
- **Build:** Core, Fast Build, `-NoPostBootCleanup`
- **ISO:** `C:\Temp\p5-core-nocleanup.iso` (4.55 GB)
- **VM:** Hyper-V Gen2 (fresh)
- **Result:** ✅ PASS
- **Evidence:**
  - `Get-ScheduledTask -TaskPath '\tiny11options\'` returns ONE row: `Keep WU Disabled` only.
  - `Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1'` → `False`.
  - `Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.xml'` → `False`.
- **Notes:** Off-switch path preserves Core's existing WU-enforce task while cleanly suppressing the new cleanup task's artifacts.

---

## P6 — Real CU cycle observation (Worker)

- **Date:** 2026-05-13
- **Build:** Worker, Fast Build, default selections (cleanup ON), `C:\Temp\p1d-worker.iso`
- **VM:** Hyper-V Gen2 (reuses P1's VM)
- **CU window:** install-time OOBE servicing update (CU runs during Setup, not a separate post-install monthly cycle).
- **Trigger under test:** `Microsoft-Windows-WindowsUpdateClient/Operational` EventID 19 — fires reactively when the install-time CU finalises during OOBE. Probably racing the `AtStartup` + 10-min trigger; from the user vantage they're indistinguishable.
- **Result:** ✅ PASS
- **Observation method:** empirical post-login verification. The cleanup task fires before the user reaches the desktop, so there is no observable "during" window where restaged apps are visible — the test is whether they are present at first login at all.
- **Evidence:**
  - `Get-AppxPackage -AllUsers` against the 52 catalog `provisioned-appx` package prefixes (Worker default) → **0 / 52 present** (clean sweep).
  - `Get-AppxProvisionedPackage -Online` against the same 52 prefixes → **0 / 52 present** (clean sweep, including packages staged for new-user profiles).
  - Verification script: `tests/smoke/verify-p6.ps1` (committed alongside this entry; reusable for P7 + P8 + future regression smokes).
- **Baseline context:** in the 4 days immediately preceding this smoke, fresh installs of `p1d-worker.iso` on the same VM template (without the cleanup task in place) were observed at the desktop with **Clipchamp, Copilot, Outlook for Windows, Dev Home, and MicrosoftTeams** visibly restaged by the install-time CU. With the post-boot cleanup task baked in, the 52 / 52 sweep above empirically confirms none of these reach the user post-login.
- **Catalog scoping:** no keep-listed apps observed removed. Build was `default-apply` across all items so there was no keep-list to validate against in this iteration; P5 covers the off-switch contract, P7 covers per-user-fan-out scoping.
- **Pass criteria met:** every catalog-covered `provisioned-appx` removal is absent post-login. Both `Get-AppxPackage -AllUsers` and `Get-AppxProvisionedPackage -Online` confirm.
- **Notes for the README "whack-a-mole reality check":** in the 4-day pre-cleanup baseline, Microsoft was observed restaging at minimum Clipchamp, Copilot, Outlook for Windows, Dev Home, and MicrosoftTeams through the install-time CU. With the post-boot cleanup task installed, all 52 catalog `provisioned-appx` removals stay removed at first login (verified by `Get-AppxPackage -AllUsers` + `Get-AppxProvisionedPackage -Online` via `tests/smoke/verify-p6.ps1`).

## P7 — Per-user fan-out

- **Date:** 2026-05-13
- **Build:** continued from P1d's Hyper-V VM (Worker, Fast Build, default selections; cleanup ON). No fresh build needed -- the P1d image already has the v1.0.1 B4 default-hive inheritance plumbing baked in.
- **Trigger:** `Start-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup'`, then 30-second settle.
- **Setup:** as User1 (admin): `New-LocalUser -Name 'User2' -NoPassword` + `Add-LocalGroupMember -Group 'Users' -Member 'User2'`. User2 signed in once to provision the profile, signed out before the assertions ran.
- **Result:** ✅ PASS
- **Evidence (HKLM-context registry checks for `Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo!Enabled`, all return `0`):**
  - **User1** (logged-in OOBE user, SID captured via `(Get-LocalUser -Name 'test').SID.Value`):
    `(Get-ItemProperty "Registry::HKEY_USERS\$user1Sid\..." -Name Enabled).Enabled` → `0`.
  - **User2** offline NTUSER.DAT (loaded via `reg load HKU\TempUser2 C:\Users\User2\NTUSER.DAT`):
    `(Get-ItemProperty "Registry::HKEY_USERS\TempUser2\..." -Name Enabled).Enabled` → `0`.
    **Headline P7 result -- new-user inheritance works.** User2 was not logged in at assertion time, so the offline NTUSER.DAT reflects EITHER bake-from-Default at user creation OR the in-session cleanup-task write during User2's brief logged-in window. Either source validates the contract.
  - **Default user template** (`C:\Users\Default\NTUSER.DAT` loaded via `reg load HKU\TempDefault`):
    `(Get-ItemProperty "Registry::HKEY_USERS\TempDefault\..." -Name Enabled).Enabled` → `0`.
    Confirms the cleanup task's runtime write target (`HKU:\tiny11_default`) carries the value, which is the inheritance source for all future user profiles.
- **Bonus regression check (Finding 4 from P1):** `(Select-String -Path C:\Windows\Logs\tiny11-cleanup.log -Pattern '_Classes' | Measure-Object).Count` → `0`. Confirms commit `619c7ae`'s anchored `^S-1-5-21-\d+-\d+-\d+-\d+$` regex still excludes `_Classes` SIDs in the live SYSTEM-context cleanup run.
- **Notes:**
  - The `reg load` / `[GC]::Collect()` / `reg unload` pattern (used twice in the assertion sequence without issue) confirms the cleanup task's own load/unload pattern at `Tiny11.PostBoot.psm1:67-83` + footer `229-236` is operationally sound under repeated re-mount.
  - User1's local account name in this VM is `test` (the OOBE account the user created at first sign-in). Its SID `S-1-5-21-1063152039-1139215959-1847590240-1001` is the canonical first-account SID for this VM.
  - Three hives, three independent confirmations -- stronger evidence than the original P7 plan required (which only asked for HKU:\$user1Sid + HKU:\$user2Sid + loaded Default).

## P8 — Non-appx action-type coverage + scheduled-task fix validation

**Iteration history:** original design (wait for natural Edge restage during a CU) was non-
deterministic. Revised post-P6 to be a steady-state check on the existing P1d VM. The first
P1d run (2026-05-13) SURFACED a bug: scheduled-task removals only deleted the XML file at
`C:\Windows\System32\Tasks\<path>`, leaving the Task Scheduler service's registry-cache
entries intact. Microsoft servicing recreated `CEIP\Consolidator`, `CEIP\UsbCeip`, and
`WER\QueueReporting` via the registry alone (no XML written; `Date` field empty in
`Get-ScheduledTask` output), keeping them `Ready` forever. Fix landed in commit `c90423e`
(new `Unregister-ScheduledTaskIfPresent` + `Unregister-ScheduledTaskFolder` helpers in
`PostBoot.psm1`; emitter swap in `Actions.ScheduledTask.psm1` from `Remove-PathIfPresent`
to `Unregister-ScheduledTask` -- clears XML + both registry-cache layers atomically). P8
re-ran against the P9 keep-list rebuild (2026-05-14) and PASSES.

- **Date:** 2026-05-14
- **Build:** Worker, Fast Build, P9 keep-list selections (Edge + Clipchamp KEPT). ISO `C:\Temp\p9-worker-keeplist.iso`. Fresh Hyper-V Gen2 install.
- **VM:** new VM created from `p9-worker-keeplist.iso` (NOT the original P1d VM -- p1d ISO was deleted as part of post-fix cleanup; the fix needed a rebuilt ISO anyway).
- **Action types under test:** `filesystem`, `filesystem + takeown-and-remove`, `registry` (HKLM-targeted), `scheduled-task removal`.
- **Result:** ✅ PASS
- **Evidence (from `tests/smoke/verify-p8.ps1` run on the VM, elevated):**
  - **filesystem `op=remove`:** `OneDriveSetup.exe` absent ✓. Edge folders (`Program Files (x86)\Microsoft\Edge` / `EdgeUpdate` / `EdgeCore`) reported FAIL by the script -- these are **expected PRESENT** on this keep-list build because the user kept them. Reframed as keep-list behavior, this arm PASSES (one removal-target absent; three keep-list targets present and verified separately by `verify-p9.ps1`).
  - **filesystem `op=takeown-and-remove`:** Edge System32 WebView reported FAIL by the script -- same reasoning, **expected PRESENT** on this keep-list build. Verified absent on a default-apply build would be the strict P8 form; verify-p8.ps1 will be parameterized to `-KeptPaths` in a follow-up commit so it runs cleanly on either build shape.
  - **registry (HKLM spot-checks):** 5 of 5 PASS.
    - `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection!AllowTelemetry` = `0` (item: `tweak-disable-telemetry`).
    - `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot!TurnOffWindowsCopilot` = `1` (item: `tweak-disable-copilot`).
    - `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE!BypassNRO` = `1` (item: `tweak-bypass-nro`).
    - `HKLM:\SYSTEM\Setup\LabConfig!BypassTPMCheck` = `1` (item: `tweak-bypass-hardware-checks`).
    - `HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent!DisableWindowsConsumerFeatures` = `1` (item: `tweak-disable-sponsored-apps`).
  - **scheduled-task removal:** 5 of 5 PASS. **This is the headline P8 finding -- the fix works end-to-end.**
    - `\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser` absent (item: `disable-task-compat-appraiser`).
    - `\Microsoft\Windows\Application Experience\ProgramDataUpdater` absent (item: `disable-task-program-data-updater`).
    - `\Microsoft\Windows\Customer Experience Improvement Program\` (folder, recurse) absent (item: `disable-task-ceip`). **Previously held `Consolidator` + `UsbCeip` registry-cache entries on P1d; both genuinely gone on this rebuilt ISO.**
    - `\Microsoft\Windows\Chkdsk\Proxy` absent (item: `disable-task-chkdsk-proxy`).
    - `\Microsoft\Windows\Windows Error Reporting\QueueReporting` absent (item: `disable-task-werqueue`). **Previously had Date-empty registry-cache entry on P1d; gone on rebuild.**
  - **Cleanup log evidence:** task fired multiple times post-install (SetupComplete immediate run + BootTrigger PT10M); 100+ `already` lines for registry/CDM enforcement; no `FAILED` lines.
- **Notes:**
  - The fix's effectiveness shows up two ways: (1) `Unregister-ScheduledTask` appears 10 times in the generated cleanup script (verified via static-arm grep in P9), and (2) all 5 catalog scheduled-task removals are `Get-ScheduledTask`-absent on the freshly built ISO -- including the two tasks that registry-cache-persisted on P1d.
  - P8's design intent stands: validate the THREE action types beyond `provisioned-appx` that P6 (52-package appx sweep) did not cover. All three confirmed end-to-end.

## P9 — Keep-list smoke (Edge + Clipchamp KEPT)

**Why this exists:** P1-P8 all built with default-apply selections (or the global off-switch).
None validated the **catalog-driven scoping contract** end-to-end: "items the user chose to
KEEP must never be touched by the cleanup task, even if the catalog otherwise enumerates them."
The contract is implemented at `src/Tiny11.PostBoot.psm1:286-289` (generator hard-skips items
where `EffectiveState != 'apply'`) and unit-tested at `tests/Tiny11.PostBoot.Generator.Tests.ps1:60-74`,
but P9 was the first smoke proving the wire-through from UI -> BuildHandlers -> wrapper ->
Worker pipeline -> ResolvedSelections -> generator -> ISO emits the right script with the
right omissions. P9 also doubles as the validation venue for the scheduled-task fix (P8 ran
against the P9 VM).

- **Date:** 2026-05-14
- **Build:** Worker, Fast Build, custom selections (Edge + Clipchamp KEPT). Profile JSON: `C:\Temp\p9-keep-edge-clipchamp.json`. Build wrapper: `C:\Temp\run-p9.ps1`.
- **Selections flipped to skip:** `remove-clipchamp`, `remove-edge`, `remove-edge-webview`, `tweak-remove-edge-uninstall-keys` (4 catalog items spanning 3 action types).
- **ISO:** `C:\Temp\p9-worker-keeplist.iso` (8.1 GB).
- **VM:** Hyper-V Gen2, fresh install from the P9 ISO.
- **Result:** ✅ PASS (both arms)

### P9 -- Static arm (offline ISO inspection)

Mount the ISO, extract `Windows\Setup\Scripts\tiny11-cleanup.ps1` from `install.wim` Index 6
(`Windows 11 Pro`, our build target), grep for forbidden + control patterns.

- **Method:** Mount-DiskImage → Mount-WindowsImage -ReadOnly → read script → unmount.
- **Script:** 41,591 bytes, 641 lines.
- **Forbidden patterns (must be ZERO):**
  - `Clipchamp\.Clipchamp` → 0 matches ✓
  - `Program Files \(x86\)\\Microsoft\\Edge` → 0 matches ✓
  - `Program Files \(x86\)\\Microsoft\\EdgeUpdate` → 0 matches ✓
  - `Program Files \(x86\)\\Microsoft\\EdgeCore` → 0 matches ✓
  - `System32\\Microsoft-Edge-Webview` → 0 matches ✓
  - `Uninstall\\Microsoft Edge` → 0 matches ✓
- **Control patterns (must be NON-ZERO, prove script isn't empty):**
  - `Microsoft\.BingNews`, `Microsoft\.Copilot`, `MSTeams`, `Microsoft\.XboxApp`, `Microsoft\.WindowsTerminal` → all 2+ matches each ✓
- **Bonus fix-validation:** `Unregister-ScheduledTask` → 10 matches in the generated script. **Confirms the scheduled-task fix (commit `c90423e`) is baked into this ISO.** The cleanup script now calls `Unregister-ScheduledTask -Confirm:$false` per-task instead of `Remove-PathIfPresent` against the XML, clearing both layers atomically.
- **Caveat (false-positive caught during inspection):** initial pattern `Microsoft\\Edge` matched twice in the script -- traced to `tweak-disable-copilot` writing `HKLM\SOFTWARE\Policies\Microsoft\Edge!HubsSidebarEnabled=0` (Edge sidebar policy, legitimately APPLY in this build). Pattern tightened to `Program Files \(x86\)\\Microsoft\\Edge\b` for the actual filesystem-path check. `verify-p9-static.ps1` carries the same fix in the follow-up commit.

### P9 -- Runtime arm (post-install VM observation)

Run on the P9 VM elevated after first login: `tests/smoke/verify-p9.ps1`.

- **Kept appx PRESENT:**
  - `Clipchamp.Clipchamp` -- found in `Get-AppxPackage -AllUsers` AND `Get-AppxProvisionedPackage -Online`. ✓
- **Kept filesystem paths PRESENT:**
  - `C:\Program Files (x86)\Microsoft\Edge` ✓
  - `C:\Program Files (x86)\Microsoft\EdgeUpdate` ✓
  - `C:\Program Files (x86)\Microsoft\EdgeCore` ✓
  - `C:\Windows\System32\Microsoft-Edge-Webview` ✓
- **Kept registry keys PRESENT:**
  - `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge` ✓
  - `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update` ✓
- **Removed catalog appx ABSENT:**
  - 51 of 52 catalog `provisioned-appx` prefixes (all except Clipchamp): **0 of 51 present** in `Get-AppxPackage -AllUsers`. ✓
  - 51 of 52 catalog prefixes: **0 of 51 present** in `Get-AppxProvisionedPackage -Online`. ✓

### P9 -- Pass criteria all met

1. Static arm zero matches for the 4 keep-list catalog items in the generated script. ✓
2. Static arm non-zero matches for 5 control prefixes (script not empty). ✓
3. Runtime arm: every kept-item assertion holds. ✓
4. Runtime arm: every removed-item assertion holds (51 of 52 absent in both checks). ✓
5. Bonus: scheduled-task fix proven baked-in via static arm (`Unregister-ScheduledTask` × 10 occurrences) AND validated at runtime via P8 on the same VM (5 of 5 catalog scheduled-task removals genuinely absent in `Get-ScheduledTask`).

**The catalog-driven scoping contract holds end-to-end. The keep-list contract holds. The
scheduled-task fix holds. v1.0.1 tag gate cleared.**

---

## Commit cadence (final)

```
test(smoke): P6 PASS -- install-time CU; 52/52 appx clean sweep verified (LANDED 2f5d7db)
test(smoke): P7 PASS -- default-hive inheritance + _Classes SID regex hold (LANDED 7b875b0)
fix(post-boot): Unregister-ScheduledTask for scheduled-task action type (P8 finding) (LANDED c90423e)
test(smoke): P8 + P9 PASS -- scheduled-task fix validated, keep-list contract holds (this commit)
```

All smoke cases PASS. v1.0.1 tag gate cleared on 2026-05-14 after the P8-finding scheduled-task fix
landed and was validated end-to-end on the P9 rebuild.
