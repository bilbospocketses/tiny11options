# WIM-integrity gate + `-Save` retry + synthetic-WIM E2E harness — Design

- **Date:** 2026-05-30
- **Status:** Approved (design); awaiting implementation codeword
- **Repo:** `tiny11options` (`main` @ `84a421b`, v1.0.28)
- **Supersedes:** the todo STAGING dossier "WIM-integrity gate + E2E harness" (lines 86–126 of `todo_tiny11options.md`)
- **Related:** binding decision *"Install-regression root cause: the 5 reverted files are IMAGE-NEUTRAL"*; v1.0.3 smoke `docs/superpowers/smoke/2026-05-14-v1.0.3-catalog-and-logging-smoke.md`

---

## 1. Problem

`Dismount-WindowsImage -Save` writes every offline modification back into `install.wim` — a large, slow write. Under transient host interference (Defender real-time scan, Windows Search indexer, a lingering file handle, Controlled Folder Access) the save can fail or **partially** commit: a WIM structurally readable enough to author an ISO from, but with subtly missing/corrupt file data. The ISO builds fine and then **Windows Setup fails at the file-copy step** — the v1.0.26 symptom.

The v1.0.28 bisect *proved* all five reverted image-shaping files are image-neutral, so the v1.0.26 install failure was not the code — it was **intermittent**, and the save-dismount is the one step that writes the final image while exposed to transient host interference. v1.0.27/v1.0.28 carry the same save code; they simply didn't hit the lock.

Today there is **zero automated coverage** of the real WIM-commit path: the existing Worker "commit/discard" tests (`tests/Tiny11.Worker.Tests.ps1`) are source-regex assertions (they check the code's *text*), and the `*.Online.Tests.ps1` files are command-descriptor unit tests. Nothing mounts a real WIM.

## 2. Goals / success criteria

1. A corrupt `install.wim`/`boot.wim` can **never ship silently** — the build aborts with a clear, actionable error.
2. A **transient** dismount-save lock no longer fails the build — it is retried with backoff.
3. Both behaviours are **proven automatically in CI** against a real (tiny) WIM.

## 3. Non-goals (explicitly out of scope)

- **Full Windows install/boot validation** (build a real ISO, boot it in a VM, confirm install completes). Deferred Hyper-V tier — GitHub-hosted runners cannot nest Hyper-V, so this is local/self-hosted only.
- **Exercising the real apply handlers** (registry / filesystem / appx) against a real image. Those need a real Windows hive + path structure (`Windows\System32\config\SOFTWARE`, …) that a synthetic WIM does not have. A synthetic WIM is content-agnostic — it validates the WIM *container* mechanics only. Also deferred to the Hyper-V tier.
- README test-count paragraph simplification (separate active TODO).

## 4. Locked decisions

| # | Decision |
|---|----------|
| Fidelity | **Synthetic mini-WIM** harness (CI-runnable), not Hyper-V VM boot. |
| Scope | **Gate + `-Save` retry + harness** land together in one PR. |
| (i) | Helpers live in a **dedicated `src/Tiny11.Wim.psm1` module** (not inline in Worker) — lets the harness target them directly and lets `Core.psm1` reuse them later. |
| (ii) | Gate + retry cover **both `install.wim` and `boot.wim`** (symmetry; boot.wim corruption fails WinPE). |
| (iii) | Retry = **bounded retry-on-any-failure: 3 attempts, 2s/4s/8s backoff.** |
| (iv) | Add **`dism.exe` + `robocopy.exe`** to `project_tiny11options_dependency_policy.md` waiver (OS-intrinsic, not vendorable). |

## 5. Architecture / components

### 5.1 New module `src/Tiny11.Wim.psm1`

Two small, isolated, independently-testable helpers (both exported):

- **`Invoke-Tiny11WimDismountSave -MountPath <string> [-Attempts 3] [-DelaySeconds 2]`**
  Wraps `Dismount-WindowsImage -Path $MountPath -Save` in a bounded retry loop. Backoff doubles each attempt (`DelaySeconds`, then ×2, ×4). Retries on *any* failure. On exhaustion, throws `"<MountPath> dismount-save failed after N attempts: <message>"`. `-DelaySeconds 0` (tests) skips the sleep.

- **`Assert-Tiny11WimIntegrity -ImagePath <string> -Index <int>`**
  Verifies the saved WIM is structurally readable and throws an actionable error on failure (message: *"Build aborted — `<wim>` (index N) failed its post-save integrity check; the image was NOT shipped. Likely transient host interference (AV real-time scan / Windows Search indexer / Controlled Folder Access / a stray file handle). Re-run the build."*).

  **Integrity mechanism (implementation-validated):** the known-thorough verification is a full resource read+verify, which `dism /Export-Image … /CheckIntegrity` performs. The non-FastBuild path already exports, so adding `/CheckIntegrity` there makes the export *itself* the deep gate (check `$LASTEXITCODE`, throw on non-zero). For the post-save check (and the FastBuild path, which has no export), `Assert-Tiny11WimIntegrity` runs `Get-WindowsImage -ImagePath <wim> -Index <n>` — a **structural-readability** verify (the WIM header + the serviced image's metadata must parse). **Note:** `Get-WindowsImage` has **no** `-CheckIntegrity` parameter — that switch exists only on the write/mount/export cmdlets (`Mount-`/`Dismount-`/`Export-`/`New-WindowsImage`); an early draft of this spec wrongly used it. So the post-save gate is readability-only, intentionally weaker than the export's full-resource scan; on the normal build path the export's `/CheckIntegrity` is the authoritative deep gate, and on FastBuild the readability gate is the shipped-artifact gate. **The synthetic harness empirically confirmed** the readability gate is stronger than feared: an injected mid-file byte-flip corruption *is* detected by `Get-WindowsImage` (the harness's corruption case passes rather than falling through to its Inconclusive branch). The harness retains the Inconclusive fallback so a future, subtler corruption that slips past readability is surfaced as a signal rather than a false pass.

### 5.2 `src/Tiny11.Worker.psm1` integration (current anchors)

- Import `Tiny11.Wim.psm1` at the top, following the existing module convention (`-Force -Global -DisableNameChecking`).
- **install.wim commit** (finally block `:113–129`): replace the inline `Dismount-WindowsImage -Path $scratchImg -Save` (`:118`) with `Invoke-Tiny11WimDismountSave`. After the finally, when `$installPipelineSucceeded`, emit a `phase='integrity-check'` progress marker and call `Assert-Tiny11WimIntegrity -Index $ImageIndex`.
- **Export** (`:139`): add `/CheckIntegrity` to `dism /Export-Image`; check `$LASTEXITCODE` and throw on failure; after the rename, `Assert-Tiny11WimIntegrity` the final `install.wim` at **index 1** (export collapses to a single image).
- **boot.wim commit** (finally block `:167–181`): same `Invoke-Tiny11WimDismountSave` wrapper for `:172`; `Assert-Tiny11WimIntegrity -Index 2` after.
- The `-Discard` arms (`:120`, `:174`) stay as-is (no retry on discard).

### 5.3 FastBuild interaction

`FastBuild` skips `/Export-Image` (`:135–142`), so the shipped `install.wim` is the post-`-Save` one → the **post-save gate** is the shipped-artifact gate there. Non-FastBuild → the **export-with-`/CheckIntegrity`** is the shipped-artifact gate (index 1).

### 5.4 Error UX

Reuse the existing failed-build path entirely: a thrown error propagates to the launcher's build-failed `catch` → existing scratch cleanup → WebView2 error display. No new UI surface; the `integrity-check` progress phase just makes the step visible.

### 5.5 Stranded-mount recovery

On retry exhaustion the throw may leave a mount active; this is already handled by the next build's preflight `Clear-WindowsCorruptMountPoint` + `Clear-Tiny11StaleHives` (`Worker.psm1:37–38`). No new cleanup needed.

## 6. Testing

### 6.1 `tests/Tiny11.Wim.Synthetic.Tests.ps1` — Tag `Synthetic` (RequiresAdmin, Slow)

- `BeforeDiscovery` elevation guard → the suite is **skipped** when not admin, so local non-admin runs stay green; CI (admin runner) runs it for real.
- Fixture: `New-WindowsImage` captures a tiny temp tree → a genuine `.wim` (temp dir, cleaned up in `AfterAll`).
- Cases:
  1. **Happy round-trip (real DISM):** capture → `Mount-WindowsImage` → modify a file → `Invoke-Tiny11WimDismountSave` → `Assert-Tiny11WimIntegrity` passes. *(This is the real-WIM validation the dossier asked for.)*
  2. **Gate aborts on corruption:** primary (deterministic) = mock `Get-WindowsImage` within `Tiny11.Wim` scope to report failure → assert `Assert-Tiny11WimIntegrity` throws. Plus a **best-effort, skippable** real byte-corruption variant (truncate/flip the `.wim`) to confirm real detection.
  3. **Retry recovers:** deterministic core = mock `Dismount-WindowsImage` to throw on the first call and succeed on the second → assert `Invoke-Tiny11WimDismountSave` succeeds and was invoked twice. Best-effort real-lock variant (exclusive `FileStream` released between attempts) is skippable.
  4. **Retry gives up:** mock `Dismount-WindowsImage` to always throw → assert it throws after exactly N attempts (`Should -Invoke -Times 3`).

  **Mocking philosophy:** the deterministic control-flow (abort branch, retry count, give-up) uses Pester mocks of the DISM cmdlets; the **real-DISM validation** is the happy round-trip (case 1) against a genuine synthetic WIM. Real corruption / real lock are best-effort add-ons to avoid CI flakiness.

### 6.2 `tests/Tiny11.Worker.Tests.ps1` — source-regex structural guard (non-admin)

Add assertions (mirroring the existing B6/B7 guards) that Worker routes both commits through `Invoke-Tiny11WimDismountSave` and calls `Assert-Tiny11WimIntegrity` — so a future refactor that drops the gate fails fast even where admin/DISM is unavailable.

### 6.3 `Run-Tests.ps1` / `Tiny11.PesterConfig.ps1`

Add `-Tag` / `-ExcludeTag` passthrough (today the runner executes everything unfiltered). CI runs all (admin → `Synthetic` included). Local fast path: `Run-Tests.ps1 -ExcludeTag Synthetic`. **Verify in CI** that the `Synthetic` suite actually executes (not skipped) — i.e., the GitHub `windows-2025-vs2026` runner is elevated enough for `Mount-WindowsImage`. If it is not, that is a finding to surface, not to paper over.

## 7. Compliance (Local-Dependencies-Only)

- New helpers add only OS PowerShell cmdlets (`Get-WindowsImage` / `Dismount-WindowsImage` / `New-WindowsImage`) — no new bundled binary.
- **(iv) waiver update** (`project_tiny11options_dependency_policy.md`): add `dism.exe` and `robocopy.exe` as waived OS-intrinsic tools. Rationale: both are tied to the host's servicing stack / OS and cannot be vendored as portable binaries that match an arbitrary host Windows build. Note that `Get/Mount/Dismount/New-WindowsImage` are the cmdlet face of the same DISM OS component. This is a memory write → lands under the codeword.
- The existing `oscdimg` waiver and its `msdl.microsoft.com` download fallback are unchanged.

## 8. Rollout / landing

- Feature branch off `main` (e.g. `feat/wim-integrity-gate`).
- TDD-ish order: write `Synthetic` + structural tests, then implement `Tiny11.Wim.psm1` + Worker integration to green.
- `CHANGELOG.md` entry (Keep a Changelog).
- Squash PR (`gh pr merge --squash --delete-branch`); CI green **including** the `Synthetic` suite.
- **Version:** this adds a runtime gate (shippable, not test-only), so it warrants a patch tag (**v1.0.29**) — confirm at wrap-up. (v1.1.0 stays reserved for Trusted Signing.)
- **Todo reconciliation:** promote the STAGING block to a single active grouped item, reconcile/replace the two existing items it supersedes, then delete the block (memory write — under codeword).

## 9. Deferred (tracked, not this PR)

- Hyper-V VM full-install E2E tier.
- Real apply-handler-against-real-image coverage.
