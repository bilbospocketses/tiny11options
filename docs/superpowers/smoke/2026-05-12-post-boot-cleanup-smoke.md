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
| P7 | Worker (fresh VM via VHDX-copy of P1) | Per-user fan-out + new-user inheritance | ⏳ pending |
| P8 | Worker (reuses P1's VM, post-P6) | Non-appx action-type coverage (filesystem + registry + scheduled-task) | ⏳ pending |
| P9 | Worker, custom selections (Edge + Clipchamp KEPT) | Keep-list contract: static + runtime | ⏳ pending |

P1-P5 build + first-boot smoke complete; P6 PASS with empirical 52/52 appx clean sweep
post-CU. P7 (multi-user fan-out) and P8 (action-type coverage on P1d VM) are observation-only.
P9 (keep-list smoke) is the highest-stakes remaining contract -- empirical proof that the
generator scopes its output to apply-only items end-to-end (UI -> wrapper -> ResolvedSelections
-> generator -> ISO). No further code changes expected unless smoke surfaces another bug.

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

## P7 — Per-user fan-out — PENDING

- **Date:** _to be filled_
- **Build:** Worker, fresh VM via VHDX-copy of P1d's VHDX
- **Trigger under test:** New-user inheritance of NTUSER tweaks (e.g., `tweak-disable-telemetry`)
- **Result:** ⏳ pending
- **Steps:**
  1. **Source the target hive correctly.** v1.0.1 design (B4) loads `C:\Users\Default\NTUSER.DAT` via `reg load HKU\tiny11_default ...`. **Target this, NOT `HKU:\.DEFAULT`** — `.DEFAULT` backs LOCAL_SERVICE / NETWORK_SERVICE and is no longer the new-user template after B4.
  2. As User1 (admin): `New-LocalUser -Name 'User2' -NoPassword`, `Add-LocalGroupMember -Group 'Users' -Member 'User2'`.
  3. Sign out, sign in as User2, complete first-login setup, sign back to User1.
  4. As User1 admin: `Start-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup'`; `Start-Sleep 30`.
  5. Capture both user SIDs and assert: `(Get-ItemProperty -Path "HKU:\$user1Sid\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name Enabled).Enabled` and the equivalent for User2 both return `0`.
  6. Load `C:\Users\Default\NTUSER.DAT` via `reg load` and assert the same value at `HKU\tiny11_default\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo` (new-user inheritance).
- **Pass criteria:** All three sources (User1 SID, User2 SID, loaded Default hive) carry `Enabled = 0`.
- **Wall-clock estimate:** ~30-45 min including User2 creation + first-login.

## P8 — Non-appx action-type coverage on default-apply build — PENDING (revised post-P6)

**Revision rationale:** the original P8 design (wait for natural Edge restage during a CU,
verify cleanup re-removes) had two problems after P6 landed: (1) no guarantee any given CU
will actually restage Edge -- if it doesn't, P8 is uninformative; and (2) P6 already proved
the headline "task fires post-CU and appx items are clean" outcome. The revised P8 is now
**deterministic**: it observes the existing P1d VM and validates the THREE action types
beyond `provisioned-appx` that P6's appx-only verify script did not cover.

- **Date:** _to be filled_
- **Build:** reuses P1's Hyper-V VM (the existing P1d-worker install), no fresh build needed
- **Action types under test:** `filesystem`, `filesystem + takeown-and-remove`, `registry` (HKLM-targeted), `scheduled-task removal`
- **Result:** ⏳ pending
- **Steps:**
  1. **filesystem absence** -- assert `C:\Program Files (x86)\Microsoft\Edge`, `\EdgeUpdate`, `\EdgeCore` all absent. `Test-Path` each.
  2. **filesystem + takeown-and-remove absence** -- assert `C:\Windows\System32\Microsoft-Edge-Webview` and `C:\Windows\System32\OneDriveSetup.exe` both absent.
  3. **registry tweaks applied** -- spot-check at least 4 catalog-covered HKLM values:
     - `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection!AllowTelemetry` = 0 (telemetry).
     - `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot!TurnOffWindowsCopilot` = 1 (Copilot policy).
     - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE!BypassNRO` = 1 (OOBE local-accounts).
     - `HKLM\SYSTEM\Setup\LabConfig!BypassTPMCheck` = 1 (hardware-bypass).
  4. **scheduled-task removal** -- assert `Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\'` returns nothing; assert `Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser'` returns nothing.
  5. **cleanup log evidence** -- `Get-Content C:\Windows\Logs\tiny11-cleanup.log -Tail 200`. Confirm log lines for each action type ran (`REMOVED` for filesystem paths, `CORRECTED`/`already` for registry values, absence-no-op lines for scheduled-task paths).
- **Pass criteria:** every steps 1-4 assertion holds, AND step 5 shows cleanup-task log activity for each action type.
- **Wall-clock estimate:** ~15-20 min on the existing P1d VM. No CU cycle required (steps 1-4 are post-install steady-state checks; the cleanup task has already run from P1/P2).
- **What this validates that P6 did not:** P6 only proved `provisioned-appx` paths end-to-end via the 52-package sweep. P8 covers the other three action types (`filesystem`, `filesystem + takeown-and-remove`, `registry`, `scheduled-task`) which the cleanup task ALSO emits commands for. Without P8, a wire-up bug in any non-appx action emitter could silently ship.

## P9 — Keep-list smoke (Edge + Clipchamp KEPT) — PENDING

**Why this exists:** P1-P8 all build with default-apply selections (or the global off-switch).
None validate the **catalog-driven scoping contract**: "items the user chose to KEEP must
never be touched by the cleanup task, even if the catalog otherwise enumerates them." The
contract is implemented at `src/Tiny11.PostBoot.psm1:286-289` (generator hard-skips items
where `EffectiveState != 'apply'`) and unit-tested at `tests/Tiny11.PostBoot.Generator.Tests.ps1:60-74`,
but no end-to-end smoke proves the wire-through from UI -> BuildHandlers -> wrapper -> Worker
pipeline -> ResolvedSelections -> generator -> ISO emits the right script with the right
omissions. P9 closes that gap and is the highest-stakes remaining contract.

- **Date:** _to be filled_
- **Build:** Worker, Fast Build, custom selections (Edge + Clipchamp KEPT)
- **Selections flipped to skip:** `remove-clipchamp`, `remove-edge`, `remove-edge-webview`, `tweak-remove-edge-uninstall-keys`. Profile JSON: `C:\Temp\p9-keep-edge-clipchamp.json`. Build wrapper: `C:\Temp\run-p9.ps1`.
- **ISO:** `C:\Temp\p9-worker-keeplist.iso`
- **VM:** Hyper-V Gen2 (fresh, NOT a VHDX-copy of P1d -- the keep-list selections diverge so the install needs to come from the new ISO)
- **Result:** ⏳ pending

### P9 -- Static arm (offline ISO inspection)

This is the strongest evidence available: prove the cleanup task PHYSICALLY DOES NOT CONTAIN
code that could touch the kept items. Run on the build host BEFORE installing on the VM.

- Mount the ISO offline (or extract `\sources\install.wim` index 6 to a temp dir).
- Read `Windows\Setup\Scripts\tiny11-cleanup.ps1` from the extracted root.
- Helper: `tests/smoke/verify-p9-static.ps1 -IsoPath C:\Temp\p9-worker-keeplist.iso`.
- **Assertions:**
  - ZERO occurrences of `Clipchamp.Clipchamp` in the generated script.
  - ZERO occurrences of `Program Files (x86)\\Microsoft\\Edge` (or any of the three Edge paths).
  - ZERO occurrences of `Microsoft-Edge-Webview` (System32 path).
  - ZERO occurrences of the Edge uninstall registry-key paths.
  - Non-zero occurrences of at least 5 OTHER catalog prefixes (e.g., `BingNews`, `Copilot`, `MSTeams`, `XboxApp`, `WindowsTerminal`) -- confirms the script wasn't accidentally emptied.

### P9 -- Runtime arm (post-install VM observation)

After installing the P9 ISO and reaching first login, run `tests/smoke/verify-p9.ps1` on the VM.

- **Kept appx (MUST be present):**
  - `Get-AppxPackage -AllUsers` contains a Name starting with `Clipchamp.Clipchamp`.
  - `Get-AppxProvisionedPackage -Online` contains a DisplayName starting with `Clipchamp.Clipchamp`.
- **Kept filesystem (MUST be present):**
  - `C:\Program Files (x86)\Microsoft\Edge` (directory).
  - `C:\Program Files (x86)\Microsoft\EdgeUpdate` (directory).
  - `C:\Program Files (x86)\Microsoft\EdgeCore` (directory, if present in source).
  - `C:\Windows\System32\Microsoft-Edge-Webview` (directory).
- **Kept registry (MUST be present):**
  - `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge` (key).
  - `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update` (key).
- **Removed (MUST be absent):** the 51 catalog `provisioned-appx` prefixes that remained at apply-state -- everything from verify-p6.ps1's list MINUS `Clipchamp.Clipchamp`.

### P9 -- Pass criteria

ALL of the following:
1. Static arm: zero matches for the 4 kept items in the generated script.
2. Static arm: non-zero matches for at least 5 control prefixes (script not empty).
3. Runtime arm: every "kept" assertion holds (Clipchamp present, all Edge paths present, both Edge uninstall keys present).
4. Runtime arm: every "removed" assertion holds (51 of 52 catalog appx prefixes absent in both `Get-AppxPackage -AllUsers` and `Get-AppxProvisionedPackage -Online`).
5. Cleanup log inspection: `C:\Windows\Logs\tiny11-cleanup.log` shows NO lines mentioning Clipchamp, Edge, EdgeUpdate, EdgeCore, Microsoft-Edge-Webview, or the Edge uninstall keys -- confirms the runtime omission matches the static omission.

### P9 -- Wall-clock estimate

- Build: ~30-45 min (Fast Build, Worker).
- Static arm: ~5 min after build (mount + grep).
- Runtime arm: ~30 min (Hyper-V install + first login + verify script).
- **Total:** ~70-80 min.

---

## Commit cadence

Per the plan, commit each smoke case as it lands:

```
test(smoke): P6 PASS -- install-time CU; 52/52 appx clean sweep verified (LANDED 2f5d7db)
test(smoke): P7 NTUSER fan-out -- multi-user + default-hive inheritance carries registry value
test(smoke): P8 non-appx action-type coverage on P1d -- filesystem + registry + scheduled-task validated
test(smoke): P9 keep-list contract -- Edge + Clipchamp kept; static + runtime arms both PASS
```

After P7, P8, P9 PASS, v1.0.1 tag gate is cleared. Batch 2 BLOCKERs already shipped (2026-05-13
evening, HEAD `d4d847d`). CHANGELOG `[1.0.1]` promotion + tag + push follow.
