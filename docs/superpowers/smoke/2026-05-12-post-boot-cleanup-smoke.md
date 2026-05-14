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
| P6 | Worker (reuses P1's VM) | Real CU cycle + EventID 19 | ⏳ pending |
| P7 | Worker (fresh VM via VHDX-copy of P1) | Per-user fan-out + new-user inheritance | ⏳ pending |
| P8 | Worker (fresh VM via VHDX-copy of P1) | Edge re-staging behavior after CU | ⏳ pending |

P1-P5 build + first-boot smoke complete; all five PASS after a single feedback iteration
that surfaced 5 latent bugs (see fixes below). P6-P8 are observation-only on real Microsoft
CU servers + Hyper-V VM time; no further code changes expected unless smoke surfaces another
bug.

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

## P6 — Real CU cycle observation (Worker) — PENDING

- **Date:** _to be filled_
- **Build:** Worker, reuses P1d's VM (or fresh build if P1's VM was destroyed)
- **Trigger under test:** `Microsoft-Windows-WindowsUpdateClient/Operational` EventID 19 (CU install-complete)
- **Result:** ⏳ pending
- **Steps:**
  1. Baseline app inventory: `Get-AppxProvisionedPackage -Online | Select DisplayName | Sort DisplayName > C:\baseline-prov.txt`; same for `Get-AppxPackage -AllUsers`.
  2. Re-enable WU if needed (`Set-Service wuauserv -StartupType Manual` + `Start-Service wuauserv`), `usoclient StartScan`, install latest CU via Settings → Windows Update.
  3. Post-CU inventory pre-cleanup: `Get-AppxProvisionedPackage -Online | Sort DisplayName > C:\post-cu-prov.txt`; `Compare-Object` against baseline.
  4. Wait ~10 min for cleanup task to fire on EventID 19.
  5. Post-cleanup inventory: `> C:\post-cleanup-prov.txt`; `Compare-Object` against baseline.
  6. `Get-ScheduledTaskInfo` on `Post-Boot Cleanup`: assert `LastRunTime` is post-CU and `LastTaskResult = 0`.
- **Pass criteria:** Every restaged package observed in step 3 that maps to a `provisioned-appx` catalog action is GONE in step 5. Log shows `REMOVED` entries.
- **Document during run:**
  - Which packages were restaged by the CU.
  - Which were re-removed by the cleanup task.
  - Any restaged packages NOT in the catalog → these define the catalog ceiling for v1.0.2 expansion.
- **Wall-clock estimate:** ~2-3 hours including CU download + observation window (longer on Patch Tuesday saturation).

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

## P8 — Edge re-staging behavior — PENDING

- **Date:** _to be filled_
- **Build:** Worker, fresh VM via VHDX-copy of P1d's VHDX
- **Trigger under test:** Edge restage paths after CU + cleanup-task removal
- **Result:** ⏳ pending
- **Steps:**
  1. Pre-CU: assert all four Edge paths absent — `C:\Program Files (x86)\Microsoft\Edge`, `\EdgeUpdate`, `\EdgeCore`, `C:\Windows\System32\Microsoft-Edge-Webview`.
  2. Run a full CU cycle (same as P6 step 2).
  3. Post-CU pre-cleanup: re-check the four paths. Edge MAY restage into one or more — note which.
  4. Wait for cleanup task to fire on EventID 19.
  5. Post-cleanup: re-check the four paths. Cleanup should have re-removed whichever Edge folder(s) restaged.
- **Pass criteria:** Edge restage paths that are catalog-covered are GONE post-cleanup. Log shows `REMOVED` entries for each restaged Edge path. Any restage into a path NOT covered by the catalog → document for v1.0.2 catalog expansion.
- **Wall-clock estimate:** ~2-3 hours, similar to P6 pacing.

---

## Commit cadence

Per the plan, commit each smoke case as it lands:

```
test(smoke): P6 Worker real CU cycle — restaged appx re-removed within 10 min of CU completion
test(smoke): P7 NTUSER fan-out — multi-user + .DEFAULT-replacement all carry the registry value
test(smoke): P8 Edge re-staging — cleanup re-removes catalog-covered paths after CU restage
```

After all 8 cases PASS, Batch 2 BLOCKERs (audit `2026-05-13-v1.0.1-pre-smoke-audit.md`) gate
the v1.0.1 tag.
