# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `.gitattributes` enforcing LF line endings repo-wide, with CRLF preserved for `.ps1`/`.bat`/`.cmd` and explicit binary patterns including `.iso`/`.wim`/`.esd`/`.exe`.
- `CHANGELOG.md` (this file) following Keep a Changelog format.
- `.gitignore` excluding scratch artifacts (`*.iso`, `oscdimg-cache/`, `scratchdir/`, `tiny11/`, `tiny11_*.log`, `autounattend.xml`).
- Pester 5.x test scaffolding under `tests/` — Pester config, helpers (`Tiny11.TestHelpers.psm1`), `Run-Tests.ps1`, harness smoke test.
- v1.0.0 design spec (`docs/superpowers/specs/2026-05-01-interactive-variant-builder-design.md`) and 27-task implementation plan (`docs/superpowers/plans/2026-05-01-interactive-variant-builder.md`).
- `src/Tiny11.Catalog.psm1` + tests — JSON catalog loader with schema validation (version, category/item field presence, action-type whitelist, registry hive whitelist, `runtimeDepsOn` cross-reference check).
- `src/Tiny11.Selections.psm1` + tests — selection model with reconcile (single-hop `runtimeDepsOn` locking) and Export/Import roundtrip writing only diverged-from-default keys.
- `src/Tiny11.Hives.psm1` + tests — offline registry hive load/unload helpers covering COMPONENTS, DEFAULT, NTUSER, SOFTWARE, SYSTEM.
- `src/Tiny11.Actions.Registry.psm1` + tests — `Invoke-RegistryAction` with `op=set`/`op=remove`; remove path is idempotent on "key not found" (matches legacy script's silent-swallow behavior, but stricter — only swallows benign not-found, propagates real errors).
- `src/Tiny11.Actions.ProvisionedAppx.psm1` + tests — `Invoke-ProvisionedAppxAction` with module-scope memoization of `dism /Get-ProvisionedAppxPackages` enumeration (fixes O(N) → O(1) regression vs. legacy linear script). Cache invalidates per-removal and exposes `Clear-Tiny11AppxPackageCache` for image-context switches.
- `src/Tiny11.Actions.Filesystem.psm1` + tests — `Invoke-FilesystemAction` with `op=remove` and `op=takeown-and-remove` paths; idempotent on missing path.
- `src/Tiny11.Actions.ScheduledTask.psm1` + tests — `Invoke-ScheduledTaskAction` translating `/`-separated catalog paths under `Windows\System32\Tasks`; idempotent on missing path.
- `src/Tiny11.Actions.psm1` + tests — action dispatcher routing by `type` to the four handler modules.
- `src/Tiny11.Iso.psm1` + tests — source mount/unmount + edition enumeration. `Resolve-Tiny11Source` accepts ISO paths or drive letters; `Mount-Tiny11Source` handles already-mounted state; `Get-Tiny11Editions` enumerates via `Get-WindowsImage`. Internal `Get-Tiny11VolumeForImage` wrapper extracted for Pester-mockability (CIM-typed cmdlets can't bind synthetic fixtures otherwise).
- `src/Tiny11.Autounattend.psm1` + tests + `autounattend.template.xml` — placeholder-substitution template + 3-tier acquisition (local file → fork URL → embedded fallback). Bindings derived from selection state for `HIDE_ONLINE_ACCOUNT_SCREENS`, `CONFIGURE_CHAT_AUTO_INSTALL`, `COMPACT_INSTALL`, `IMAGE_INDEX`. Embedded here-string kept byte-equivalent to the file (drift test forthcoming).
- `catalog/catalog.json` — full 74-item catalog across 10 categories (`store-apps`, `xbox-and-gaming`, `communication`, `edge-and-webview`, `onedrive`, `telemetry`, `sponsored`, `copilot-ai`, `hardware-bypass`, `oobe`). Every legacy `tiny11maker.ps1` removal/reg-set traceable to a catalog item.
- `config/examples/tiny11-classic.json`, `keep-edge.json`, `minimal-removal.json` — sample selection profiles.
- `src/Tiny11.Worker.psm1` + tests — build pipeline orchestrator with progress callbacks. Renders autounattend.xml once after mounting install.wim and writes to BOTH `Windows\System32\Sysprep\autounattend.xml` (inside install.wim, picked up during specialize/oobeSystem passes — mirrors legacy script step that v1's draft worker initially missed) and `tiny11\autounattend.xml` (ISO root).
- `tiny11maker.ps1`: full rewrite from 535-line linear script to ~120-line orchestrator that loads modules and dispatches to scripted vs (Phase 2) interactive mode. New `-Internal` switch lets tests dot-source for function definitions without running the orchestrator. `-FastBuild` switch skips `dism /Cleanup-Image /StartComponentCleanup /ResetBase` and `dism /Export-Image /Compress:recovery` for testing builds (~25–40 min savings; ~5–6 GB ISO instead of ~3.5 GB).
- `tests/Tiny11.Orchestrator.Tests.ps1` — Pester test for `Build-RelaunchArgs` arg-quoting helper used by self-elevation.

### Changed
- `tiny11maker.ps1`: autounattend.xml fallback fetch URL now points at our fork (`bilbospocketses/tiny11options`) instead of upstream `ntdevlabs/tiny11builder`. Ensures any future edits to our `autounattend.xml` reach users who copied only the `.ps1` to a working directory.
- Self-elevation in `tiny11maker.ps1` now uses `(Get-Process -Id $PID).Path` instead of `Start-Process -FilePath 'pwsh'`, satisfying Local-Dependencies-Only by reusing the already-running pwsh executable instead of relying on system PATH resolution.
- `[copy]` phase uses `robocopy.exe /MIR /MT:8` instead of PowerShell `Copy-Item -Recurse` — multi-threaded, ~2-3× faster on the ~4 GB ISO source tree.
- `Set-StrictMode -Version 3.0` added at top of `tests/Tiny11.TestHelpers.psm1` to lock convention before downstream test modules adopt the pattern.
- `Import-Tiny11Module` now uses `-Global` on the underlying `Import-Module` so test-imported modules are visible inside Pester `It` scriptblocks.

### Fixed
- `src/Tiny11.Worker.psm1`: renamed `$source` local to `$mountResult` to avoid PowerShell's case-insensitive variable shadow against the `[string]$Source` parameter, which was coercing the pscustomobject return of `Mount-Tiny11Source` to a string via `.ToString()` (manifested as `PropertyNotFoundException` on `DriveLetter`/`MountedByUs` in the orchestrator but NOT in standalone calls).
- `src/Tiny11.Actions.Registry.psm1`: `op=remove` now treats `reg.exe` exit-1 with "unable to find" message as idempotent success rather than fatal; non-not-found errors still propagate.
- `src/Tiny11.Actions.Filesystem.psm1` / `ProvisionedAppx.psm1`: renamed `$args`/`$matches` locals to `$takeownArgs`/`$matchedPackages` to avoid PowerShell automatic-variable shadowing.
- `src/Tiny11.Actions.psm1`: handler `Import-Module` calls now include `-Global` so handler functions stay visible across Pester scopes.
- **Phase 1 VM smoke pwsh-from-pwsh blocker:** runtime guard in `tiny11maker.ps1` rejects pwsh-from-pwsh invocation, which deterministically produces ISOs that fail Windows 11 25H2 Setup product-key validation. Full investigation 2026-05-04 → 2026-05-06 confirmed build output is content-identical to working invocations across all parent-shell combinations (975/975 loose ISO files byte-identical, 21K boot.wim files byte-identical, 127K install.wim files byte-identical, all 4 hive contents identical at key/value level via `reg compare /s /od`); failure is environmental, not a content fix. Mechanism unknown after deep investigation; [upstream issue #583](https://github.com/ntdevlabs/tiny11builder/issues/583) confirms 25H2 product-key sensitivity exists with stock tiny11builder. Workaround: run from `cmd.exe` or Windows PowerShell 5.1 parent. Path C (post-v1.0.0) eliminates this caveat with a bundled `.exe` launcher.

### Notes
- Fork of [`ntdevlabs/tiny11builder`](https://github.com/ntdevlabs/tiny11builder). Standalone — no upstream contributions planned, but Phase 2 GUI may warrant a design-proposal issue per maintainer's stated GUI plans.
- Active work focuses on `tiny11maker.ps1`. `tiny11Coremaker.ps1` is out of scope for the current effort.
- Targets the **consumer** Win11 ISO (Microsoft media-creation-tool / direct ISO download). VL / MSDN multi-edition ISOs (10+ editions including N variants) trip Setup's stricter VL channel validator; documented as Phase 1 polish to add a pre-flight warning.
