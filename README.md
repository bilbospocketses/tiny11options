<p align="center">
  <img src="launcher/Resources/tiny11options.png" alt="tiny11options" width="512">
</p>

# tiny11options

> **Built on the shoulders of [ntdevlabs / NTDEV](https://github.com/ntdevlabs) and the upstream [tiny11builder](https://github.com/ntdevlabs/tiny11builder) project.** Enormous credit to the upstream maintainer for the years of deep image-trimming work that this fork stands on — the DISM orchestration, the `install.wim` + `boot.wim` mount/commit choreography, the autounattend integration, the scratch-mount-deploy pipeline. tiny11options exists only because that foundation was built first. If you find this fork useful, please go give the original a star and consider donating to them for this incredible project!

A catalog-driven Windows 11 image trimmer with an interactive WebView2 + WPF wizard. Build your own customized Win11 ISO by picking what to keep and what to remove from a curated list of ~74 items across 10 categories.

## What's different from upstream

| | Upstream tiny11builder | tiny11options |
|---|---|---|
| Removal list | Fixed | You choose, item-by-item, via wizard or JSON profile |
| Interface | Linear PS script | 3-step WebView2 + WPF wizard, OR scripted via `-Source` / `-Config` |
| Catalog | Hardcoded in script | Single source of truth in `catalog/catalog.json` |
| Re-running with same selections | Re-edit script | `-Config <profile>.json` |
| Edge removal | Yes | Yes — but WebView2 Runtime is **explicitly preserved** (see below) |

## Two modes

`tiny11options` has two **entry points** and two **modes**. Pick the entry point that matches what you have installed; the mode is just whether you pass `-NonInteractive` (and build args) or not.

| Entry point | Install requirement | Use when |
|---|---|---|
| **`tiny11options.exe`** (bundled launcher) | Nothing — single Win32 binary, downloaded from [Releases](https://github.com/bilbospocketses/tiny11options/releases) | You want the easiest path; you're an end user; you don't have or want PowerShell 7+ installed |
| **`tiny11maker.ps1`** (direct script invocation, repo clone) | Windows PowerShell 5.1 (built into every Windows install) — OR PowerShell 7+ (`pwsh.exe`, [must be installed separately](https://github.com/PowerShell/PowerShell/releases)) | You've cloned the repo to fork / customize / iterate; you're running CI without distributing the launcher binary |

Both entry points support both modes. The Interactive and Scripted sections below show each entry point side-by-side so you can copy whichever matches your setup.

### Interactive (GUI wizard)

A 1200×900 wizard window opens (resizable; size remembered between sessions in `%LOCALAPPDATA%\tiny11options\settings.json`). The theme follows your system light/dark preference on first launch, with a toggle button in the header to override (override is persisted in WebView2 localStorage):

1. **Source** — two-column layout. **Left card (Source & paths)** carries four required fields marked with a red asterisk: Win11 ISO source, edition, scratch directory, output ISO path. Scratch auto-prefills at boot to a per-build temp path you can replace; output auto-prefills to `<scratchDir>\tiny11.iso` once scratch is set. Path fields validate format + parent-exists + writability before letting you advance. A right-aligned "Fields marked with * are required" legend sits in the card header. **Right card (Build options)** carries five toggles: unmount source ISO when finished, fast-build (skip recovery compression), install post-boot cleanup task (default on), log build output (default on; expands an indented "Append to existing log" sub-toggle that preserves prior log entries instead of overwriting), and Core mode (checking it expands a drawer with the Core-mode warning + a ".NET 3.5" sub-option; Core mode skips Step 2 entirely).
2. **Customize** — browse 10 categories of removable items + tweaks; drill into any category to fine-tune; click anywhere on a row to toggle it; "Check all" / "Uncheck all" button operates on the visible filtered set; Save / Load profile JSON; cross-category search.
3. **Build** — read-only four-card confirmation: **Paths**, **Build mode**, **Customizations**, and a fourth "Ready to build" CTA card. The first three carry per-card "Edit in Step X" buttons that jump back and focus the relevant field. The fourth card transforms in place when you click Build: progress bar + phase + step + cancel buttons during the build, with an expandable "Show build details" panel; completion + error + cancel surfaces also reuse the fourth card while the first three stay frozen at click-time values. The wizard breadcrumb at the top is clickable for both forward and backward navigation (forward gated by the same required-fields check as the Next button; all navigation is disabled mid-build).

**Easiest — bundled launcher (`tiny11options.exe`):** double-click the Start menu shortcut after running the Velopack `Setup.exe` from [Releases](https://github.com/bilbospocketses/tiny11options/releases), or launch directly from any terminal (`cmd.exe`, `powershell.exe`, or `pwsh.exe` — all work):

```powershell
.\tiny11options.exe
```

**From source (`tiny11maker.ps1`):** any of the forms below works from any Windows terminal. Pick whichever matches what you have installed.

- **Using Windows PowerShell 5.1** — built into every Windows install, no extra download:

  ```powershell
  powershell -NoProfile -File tiny11maker.ps1
  ```

- **Using PowerShell 7+** — `pwsh.exe` must be installed first (`winget install Microsoft.PowerShell`, the Microsoft Store, or the [GitHub releases page](https://github.com/PowerShell/PowerShell/releases)). The `cmd /c` prefix is load-bearing — bare `pwsh -NoProfile -File tiny11maker.ps1` typed into a `pwsh` terminal is rejected at startup (see [Known caveat](#known-caveat--pwsh-from-pwsh-invocation) and the Scripted section below for the full workaround list):

  ```bat
  cmd /c pwsh -NoProfile -File tiny11maker.ps1
  ```

### Scripted (CLI / headless)

Pass `-NonInteractive` and the build args (the same things you'd otherwise click through in the GUI) to either entry point. All forms below produce identical builds.

**Easiest — bundled launcher (`tiny11options.exe`):**

```powershell
.\tiny11options.exe -NonInteractive `
    -Source "C:\path\to\Win11.iso" `
    -Config "config\examples\tiny11-classic.json" `
    -Edition "Windows 11 Pro" `
    -OutputPath "C:\out\tiny11.iso"
```

The launcher forwards every wrapper-script argument verbatim to `tiny11maker.ps1` (it does not parse them itself); internally it always invokes Windows PowerShell 5.1, so it's immune to the pwsh-from-pwsh constraint that affects the direct-script path below. `tiny11options.exe` also supports two launcher-only flags for build logging (`--log` / `--append`) — see [Build logging](#build-logging-launcher-only-v103) below.

**From source (`tiny11maker.ps1`):** four working forms — all produce identical builds, copy-paste safely into `cmd.exe`, `powershell.exe`, or `pwsh.exe`. **Pick whichever feels least ugly. The ONLY invocation that doesn't work is bare `pwsh -File tiny11maker.ps1` typed into a `pwsh.exe` terminal** (the rejected pwsh-from-pwsh pattern; see the red example at the bottom of this section).

#### Using Windows PowerShell 5.1 (works on every Windows — no extra install required)

Direct invocation:

```powershell
powershell -NoProfile -File tiny11maker.ps1 -Source "C:\path\to\Win11.iso" -Config "config\examples\tiny11-classic.json" -Edition "Windows 11 Pro" -OutputPath "C:\out\tiny11.iso" -NonInteractive
```

Equivalent with an explicit `cmd /c` wrapper (useful if `powershell.exe` somehow isn't on `PATH` — unusual but possible on heavily-locked-down installs):

```bat
cmd /c powershell -NoProfile -File tiny11maker.ps1 -Source "C:\path\to\Win11.iso" -Config "config\examples\tiny11-classic.json" -Edition "Windows 11 Pro" -OutputPath "C:\out\tiny11.iso" -NonInteractive
```

#### Using PowerShell 7+ (`pwsh.exe` must be installed first)

If you haven't installed PowerShell 7+ yet, use the Windows PowerShell 5.1 forms above instead — they work on a stock Windows install with no extra download. The forms below only work AFTER you've installed `pwsh.exe` (`winget install Microsoft.PowerShell`, the Microsoft Store, or the [GitHub releases page](https://github.com/PowerShell/PowerShell/releases)). Both forms route through a non-pwsh parent process (`cmd.exe` or `powershell.exe`) so the script's pwsh-from-pwsh gate stays quiet regardless of where you started:

```bat
cmd /c pwsh -NoProfile -File tiny11maker.ps1 -Source "C:\path\to\Win11.iso" -Config "config\examples\tiny11-classic.json" -Edition "Windows 11 Pro" -OutputPath "C:\out\tiny11.iso" -NonInteractive
```

```powershell
powershell -NoProfile -Command "pwsh -NoProfile -File tiny11maker.ps1 -Source 'C:\path\to\Win11.iso' -Config 'config\examples\tiny11-classic.json' -Edition 'Windows 11 Pro' -OutputPath 'C:\out\tiny11.iso' -NonInteractive"
```

#### The only invocation that DOESN'T work

Bare `pwsh -File tiny11maker.ps1` pasted directly into a `pwsh.exe` terminal (PowerShell 7+). The script rejects this at startup with exit code 1 because the pwsh-from-pwsh pattern deterministically produces ISOs that fail Win11 25H2 Setup product-key validation:

```diff
- # bare pwsh -File ... pasted into a pwsh terminal (PowerShell 7+):
- pwsh -NoProfile -File tiny11maker.ps1 -Source "C:\path\to\Win11.iso" -NonInteractive
-
- # Write-Error: pwsh-from-pwsh invocation is not supported. This combination produces
- # ISOs that fail Setup product-key validation on Windows 11 25H2 (mechanism unknown;
- # build output is content-identical to working invocations).
- # Workarounds:
- #   1. Use tiny11options.exe -NonInteractive (bundled launcher, immune to this constraint and doesn't need pwsh installed).
- #   2. Use one of the powershell -File forms above (no pwsh needed at all).
- #   3. Prefix with cmd /c (the cmd /c pwsh form above).
- #   4. Wrap in powershell -Command (the powershell -Command pwsh form above).
- # exit 1
```

See [Known caveat — pwsh-from-pwsh invocation](#known-caveat--pwsh-from-pwsh-invocation) below for the full mechanism story.

#### Args reference (both entry points)

These are the wrapper-script arguments — accepted by both `tiny11options.exe -NonInteractive ...` and `tiny11maker.ps1` direct invocations. The launcher just forwards them verbatim to the script.

- **`-Source`** — accepts an `.iso` path or a drive letter (`E:`, `E:\`, just `E`).
- **`-Edition`** — resolves an edition name (case-insensitive exact match) to the right `ImageIndex` by enumerating the source. Cleaner than `-ImageIndex` because the index varies between ISOs.
- **`-ImageIndex`** — the edition index inside `install.wim` (typically 6 for Pro on consumer ISOs). Mutually exclusive with `-Edition`; use whichever you prefer.
- **`-Config`** — one of the example profiles in `config/examples/` or your own JSON.
- **`-ScratchDir`** — working directory the build pipeline uses for scratch space (DISM mount root, hive temp files, intermediate WIM exports). **Needs ~10 GB free.** Optional. **When invoking `tiny11maker.ps1` directly:** defaults to the script's own directory (`$PSScriptRoot`) — i.e. your repo clone, which usually isn't where you want a multi-GB write. Specify a `-ScratchDir <path>` explicitly to control where it lands. **When invoking via `tiny11options.exe`:** the GUI Step 1 lets you pick one (and the headless CLI accepts `-ScratchDir <path>` like any other wrapper arg); the launcher then forwards your choice to the script.
- **`-OutputPath`** — output ISO path. Optional; defaults to `<scratchDir>\tiny11.iso`.
- **`-NonInteractive`** — suppresses the GUI; implied when both `-Source` and `-Config` are present.
- **`-FastBuild`** — skip the post-build recovery-image compression pass (~2 GB smaller savings forfeited, ~5–10 minutes faster).
- **`-NoPostBootCleanup`** — opt out of installing the [post-boot cleanup task](#post-boot-cleanup-task-v101). Default behavior installs the task; this switch suppresses it.

The authoritative reference is the script itself:

```powershell
powershell -NoProfile -Command "Get-Help .\tiny11maker.ps1 -Detailed"
```

#### Build logging (launcher-only, v1.0.3+)

Two flags consumed by `tiny11options.exe` itself, NOT forwarded to `tiny11maker.ps1`. **They only work via the bundled launcher** — `powershell -File tiny11maker.ps1 --log ...` would just pass `--log` through to the wrapper script as an unknown parameter and fail.

- **`--log <path>`** — write build output (stdout + stderr) to the given file IN ADDITION to the attached console. Lowercase only (`--Log` / `--LOG` are NOT recognized and fall through to `tiny11maker.ps1` as unknown wrapper params).

  Two accepted forms:
  - **Space form: `--log <path>`** — the path MUST be the very next argument after `--log`. The parser greedily consumes whatever follows `--log` as the path, so do NOT put any other flag in between. Correct: `--log "C:\logs\build.log" -Source ...`. Wrong: `--log -Source ... "C:\logs\build.log"` (the parser would treat `-Source` as the log path).
  - **Equals form: `--log=<path>`** — the path is fused into the same token, no separating space. Correct: `--log="C:\logs\build.log"` or `--log=C:\logs\build.log` (no quotes needed if the path has no spaces).

  **Position of the `--log <path>` pair (or `--log=<path>` token) in the overall arg list does NOT matter** — it can sit at the start, in the middle, or at the end. Surrounding `-Source` / `-Edition` / etc. wrapper args keep their relative order after the launcher strips out the `--log` flag and its value.

  Relative paths resolve against the current working directory (the directory you ran the launcher from, captured BEFORE the launcher swaps its own `WorkingDirectory` during init). On duplicate `--log` occurrences the LAST one wins. An empty `--log=` (equals with no value) is a parse error (exit 12); a bare `--log` at the very end of the arg list with nothing after it is also a parse error (exit 12).

- **`--append`** — when paired with `--log`, append to the existing log file rather than overwriting (default is overwrite). Lowercase only.

  **Position-independent**: `--append` can appear ANYWHERE in your argument list — before `--log`, after `--log`, sandwiched between wrapper params, at the very end — it just needs `--log` to also be present somewhere on the same line. Using `--append` without `--log` is a parse error (exit 12 — "you can't append to nothing").

Headless logging is opt-in — by default, `tiny11options.exe` writes to whatever console is attached (or nothing, in piped contexts where `AttachConsole` fails). If you need a build artifact for troubleshooting, pass `--log`. The Step 1 GUI checkbox ("Log build output", on by default) does NOT carry over to headless invocations; the two paths are independent.

Example with `--log`:

```powershell
.\tiny11options.exe -NonInteractive --log C:\logs\tiny11build.log `
    -Source "C:\path\to\Win11.iso" `
    -Config "config\examples\tiny11-classic.json" `
    -Edition "Windows 11 Pro" `
    -OutputPath "C:\out\tiny11.iso"
```

#### Exit codes

`tiny11options.exe`:

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | build failure |
| `2` | host-architecture rejection (non-x64 host — see [Architecture and language support](#architecture-and-language-support)) |
| `10` | resource-extraction failure |
| `11` | `powershell.exe` not found on PATH |
| `12` | invalid `--log` / `--append` argument |
| `13` | log file could not be opened |

`tiny11maker.ps1` (direct invocation): `0` for success, `1` for build failure (also `1` if the script's pwsh-from-pwsh gate fires — see the red example above).

## Post-boot cleanup task (v1.0.1+)

Windows cumulative updates silently restage inbox apps (Clipchamp, Copilot, Outlook, etc.) and reset hardening registry values. Microsoft confirms this is by design ([Q&A 4081909](https://learn.microsoft.com/en-us/answers/questions/4081909/windows-11-cumulative-update-changing-registry-com): *"Windows Update restores registry settings. This is by design."*).

The post-boot cleanup task re-removes only the items you chose to remove at build time, every time Windows Update finishes installing a CU (plus daily at 03:00 and 10 minutes after every boot, as a backstop).

The task:

- Is **tailored per build** -- your selections at Step 2 of the launcher determine exactly what gets re-removed. Items you chose to keep are never touched.
- Is **idempotent** -- already-correct state is a fast read-and-skip; only restaged items get the work done. Logged to `C:\Windows\Logs\tiny11-cleanup.log` (5000-line rolling, ~3 months of history).
- Runs as **SYSTEM** at boot + daily + on every WU EventID 19. Default execution time limit 30 minutes.
- Is **opt-out**. Uncheck "Install post-boot cleanup task" in Step 1 of the launcher, or pass `-NoPostBootCleanup` on the CLI.

**Known limitation (v1.0.1):** the cleanup script only re-applies what the catalog enumerates. The `tweak-disable-sponsored-apps` item currently covers 4 of the 11 canonical `ContentDeliveryManager` registry values; the other 7 (FeatureManagementEnabled, PreInstalledAppsEverEnabled, RotatingLockScreenEnabled, RotatingLockScreenOverlayEnabled, SlideshowEnabled, SoftLandingEnabled, SystemPaneSuggestionsEnabled) plus `HKLM\SOFTWARE\Policies\Microsoft\WindowsStore\AutoDownload=2` remain uncovered by the catalog and will be restored by CUs. The 4 values that *are* covered propagate to user profiles created after cleanup runs (the cleanup loads `C:\Users\Default\NTUSER.DAT` into a transient `HKU:\tiny11_default` mount, writes through it, and unloads -- new accounts inherit the disabled state). Catalog completeness lands in v1.0.2.

### Choose carefully -- build-time selections are permanent for the life of this ISO

The cleanup task carries the contract in BOTH directions:

- **Items you chose to KEEP at build time will always stay.** If you kept Edge, the cleanup task literally contains no Edge-removal code -- it's not a runtime "should I skip this?" check, the relevant commands are simply not in the generated `C:\Windows\Setup\Scripts\tiny11-cleanup.ps1`. Microsoft can restage Edge through every CU it wants; the task will never touch it.

- **Items you chose to REMOVE at build time will keep getting removed -- forever.** If you removed Clipchamp at build time and later change your mind and install it from the Store, the cleanup task will detect it and remove it again at the next trigger (every boot, daily at 03:00, and on every Windows Update EventID 19). There is no "pause for this user", no "ignore once", no opt-out at runtime.

**Plan your selections with long-term use in mind.** The cleanup task makes your decisions stick -- that's the whole point of v1.0.1 -- but it also means you need to choose at build time as if your selections are baked into the OS, because they effectively are.

**Changing your mind later means a full reinstall.** If 6 months in you decide you actually want an app you removed, the only path back is:

1. Build a fresh ISO with the updated selections (or import your prior `.json` profile from Step 4 and tweak it).
2. Reinstall Windows from the new ISO.
3. Reinstall your applications, restore your data, redo your customizations.
4. You *could* delete the prebuilt task in Task Scheduler, but this would allow all of the other apps that you don't want back in as well. 

The cleanup task on an already-deployed system cannot be reconfigured at runtime -- its decision tree is baked into the script at build time and stays that way for the life of the ISO.

**Practical tip:** if you're on the fence about an app, keep it. The marginal cost of keeping an app is ~50-100 MB on disk; the cost of being wrong is a full Windows reinstall. Errors of "I removed too much" are far more expensive than errors of "I kept too much".

## Build modes

The launcher offers two build modes in Step 1. Pick the one that fits your use case:

### Standard tiny11 (default)

Reduced Windows 11 image. Removes ~74 catalog items (consumer apps, Office stubs, telemetry components, sponsored apps, scheduled tasks, etc.) configurable per-item in Step 2. Output ISO is ~2 GB smaller than vanilla Windows 11; with the "Fast build" checkbox unchecked, recovery compression saves an additional ~2 GB.

**Use when:** you want a leaner Windows 11 install for everyday use, kept up to date via Windows Update, with the option to add languages or enable features later. Suitable as a daily-driver Windows install.

**Serviceability:** ✅ Windows Update works. Languages and features can be added post-install. Standard Microsoft servicing pipeline applies.

### tiny11 Core (smaller, non-serviceable)

Significantly more aggressive image reduction. In addition to standard tiny11's removals, Core also:
- Removes the entire WinSxS component store (preserving only ~30 retained subdirs needed for boot)
- Disables Windows Defender (services set to disabled)
- Disables Windows Update (services + policies + RunOnce)
- Removes additional system packages: Internet Explorer remnants, Media Player, WordPad, TabletPCMath, StepsRecorder, language features (Handwriting/OCR/Speech/TextToSpeech), Wallpaper-Content-Extended, Defender-Client
- Replaces winre.wim with an empty file
- Optionally enables .NET 3.5 at build time (the only feature you can opt into — cannot be added post-install)

**Use when:** rapid VM testing, short-lived dev environments, embedded/appliance scenarios where post-install changes don't matter and the smallest practical Windows 11 image is the goal.

**Serviceability:** ❌ Windows Update is disabled and the WinSxS store is gone. You cannot install Windows Updates, add languages, or enable Windows features after install. **Not suitable as a daily-driver Windows install.**

**Build time:** Core builds take ~30-45 minutes with default compression. The WinSxS-wipe phase alone runs ~5-10 minutes — longer than any single phase in a standard build. **Fast Build** (checkbox in Step 1) skips Phase 22's recovery compression and swaps Phase 20's `/Compress:max` for `/Compress:fast`, saving roughly 15-30 minutes per Core build at the cost of a modestly larger ISO. Recommended for VM testing and iterative builds where ISO size doesn't matter.

**Cancellation cleanup:** if you cancel during the WinSxS-wipe phase, the scratch directory is left in a non-resumable state (locked NTFS permissions, half-populated WinSxS_edit, dangling DISM mount). The Build failed screen surfaces a "⚠ Run cleanup automatically" button that runs the six recovery commands for you — one click, no manual elevated-PowerShell session needed. The same six commands are shown below the button as a copy-paste fallback for manual control or if the automatic run fails. Standard tiny11 builds don't reach this state — cancel cleanup is automatic in both modes.

**Post-build cleanup:** after a successful build, the Build complete screen offers an optional "Clean up scratch directory" button that removes the temporary build directories (multi-GB on Core builds). Your output ISO is preserved — the script refuses to run if the ISO path falls inside one of the cleanup targets.

To select Core mode, check the "Build tiny11 Core" box at the bottom of Step 1. The wizard then skips Step 2 (no per-item customization in Core) and goes directly to Step 3 with a Core-mode summary.

## WebView2 boundary

This is **not** a generic "remove all Edge stuff" script. We strip the Edge **browser** binary, but leave the **WebView2 Runtime** alone.

Why: the WebView2 Runtime is the rendering engine behind the Start menu's web-results pane, the Widgets surface, the Settings app's payment pages, and several other Win11 shell surfaces. Removing it leaves the system functional-but-broken in subtle ways (no Start search results, blank Widgets panel, etc.). Upstream tiny11builder removes both; tiny11options keeps the Runtime so the resulting OS still feels "stock Win11" minus the bloat.

The catalog item `remove-edge` controls Edge browser; `remove-edge-webview` (if you check it) removes the WebView2 *binary* but leaves the Runtime registry entries intact. Choose carefully.

## Catalog

Single source of truth: [`catalog/catalog.json`](catalog/catalog.json). 10 categories, ~74 items, every item traceable to the legacy upstream removal list.

Each item has:
- `id` — stable identifier used in profile JSONs
- `category` — one of the 10 categories (`store-apps`, `xbox-and-gaming`, `communication`, `edge-and-webview`, `onedrive`, `telemetry`, `sponsored`, `copilot-ai`, `hardware-bypass`, `oobe`)
- `displayName` / `description`
- `default` — `apply` (remove/tweak) or `skip` (keep)
- `actions` — one or more typed action records (`registry`, `registry-pattern-zero`, `provisioned-appx`, `filesystem`, `scheduled-task`)
- `runtimeDepsOn` — array of other item ids this item *requires* to also be applied (locks them when the parent is kept)

To add a new removal: append a new item to `catalog.json` matching the schema, run `pwsh -File tests/Run-Tests.ps1` (the catalog-loader tests will validate the schema), and submit a PR or just commit on your own fork.

## Profile examples

Four profiles are provided in [`config/examples/`](config/examples/):

| Profile | Purpose |
|---|---|
| `tiny11-classic.json` | Mirrors the upstream tiny11builder removal list — the closest analog to "what tiny11builder produces" |
| `keep-edge.json` | Like classic, but keeps Microsoft Edge (still removes everything else) |
| `keep-edge-and-clipchamp.json` | Demonstrates pinning multiple keep-list items at once (used by smoke testing) |
| `minimal-removal.json` | Conservative — removes only obvious bloat (Xbox, Solitaire, Teams chat icon), keeps everything else |

A profile JSON has shape `{ "version": 1, "selections": { "<item-id>": "apply"|"skip", ... } }` and only needs to list items that diverge from the catalog defaults. The `minimal-removal.json` profile leverages this asymmetrically: it lists ~64 items as `skip` (to override the default-apply for items you want to KEEP) and omits the ~10 items it wants to remove (Xbox category + chat-icon tweak) so they take the catalog's default `apply` state.

## System requirements

- Windows 11 host (10 may work for scripted builds; GUI requires WebView2 Runtime, which is preinstalled on Win11)
- **Host architecture: x64.** The bundled `tiny11options.exe` launcher is published `win-x64` only and rejects non-x64 hosts at startup (see [Architecture and language support](#architecture-and-language-support) below).
- PowerShell 7 (`pwsh.exe`) on PATH for the GUI; PowerShell 5.1 (`powershell.exe`) is sufficient for scripted mode
- Microsoft Edge WebView2 Runtime (preinstalled on Win11; on Win10, install from https://developer.microsoft.com/microsoft-edge/webview2/)
- ~10 GB free in the scratch directory
- A Windows 11 ISO (Microsoft media-creation-tool, direct ISO download, or VL/MSDN multi-edition).

The build process self-elevates via UAC; no need to launch as admin manually.

## Architecture and language support

### Source ISO architecture (the BUILD INPUT)

**Both x64 (amd64) and arm64 source ISOs are supported.** Microsoft distributes Windows 11 arm64 ISOs at https://www.microsoft.com/en-us/software-download/windows11arm64 (separate page from the x64 download — the standard Media Creation Tool cannot create arm64 installation media).

Core mode auto-detects the source architecture via `dism /Get-WimInfo` and selects the right WinSxS keep-list (31 entries for amd64, 33 for arm64). Standard (Worker) mode is architecture-neutral — the catalog actions operate on language- and arch-agnostic paths (appx package families, registry paths, filesystem locations) so it just works on either source.

### Host architecture (what RUNS the build)

**The bundled `tiny11options.exe` launcher is win-x64 only.** On Windows-on-ARM64 hosts (Surface Pro X / 9 / 11 SQ3 / X Elite, Copilot+ PCs with Snapdragon X Elite/Plus), the launcher rejects the host at startup with a clear message rather than running under PRISM emulation and surfacing as mysterious WebView2 / pwsh / Velopack failures three minutes into a build.

**Workaround for arm64 hosts**: invoke the PowerShell entry-point directly. The build pipeline itself is fully arm64-compatible.

```powershell
# From cmd.exe or Windows PowerShell 5.1 (NOT from pwsh — see "Known caveat" below)
pwsh -NoProfile -File tiny11maker.ps1 `
    -Source 'C:\path\to\Win11_arm64.iso' `
    -Edition 'Windows 11 Pro' `
    -OutputPath 'C:\out\tiny11-arm64.iso' `
    -NonInteractive
```

Native arm64 launcher support is tracked as a deferred follow-up for when arm64 user demand materializes (~5% of the Win11 installed base today, growing).

### Source ISO language

**All Windows 11 primary Language Packs are supported, including Serbian Latin.** Core mode auto-detects the source ISO's UI language via `dism /Get-Intl`, parses the BCP-47 locale tag (`en-US`, `de-DE`, `ja-JP`, `zh-CN`, `zh-TW`, `sr-Latn-RS`, etc.), and interpolates it into 4 of the 12 system-package removal patterns: `Microsoft-Windows-LanguageFeatures-{Handwriting,OCR,Speech,TextToSpeech}-{lang}-Package`. Worker mode doesn't touch LanguageFeatures-* packages so language detection isn't relevant there.

If detection fails (marker line absent, malformed), the language code defaults to `en-US` and the four LanguageFeatures-* removals no-op on non-English images. The detection logic is covered by ~45 Pester regression tests against every Language Pack tag Windows ships, plus defensive coverage for longer BCP-47 forms that Microsoft uses in LIPs today and might promote to primary Language Packs in future releases.

> **Note on Windows Defender language**: regardless of source ISO language, post-trim Windows Defender may surface in English on some images even when the rest of the UI is localized. This is a side-effect of the LanguageFeatures-* removal stripping Defender's localized resource fallback chain, not a detection bug. It's been observed on upstream tiny11builder (e.g. issue #507 on a zh-CN source) and the same constraint applies here. Workaround: keep `LanguageFeatures-*` packages by removing the relevant Core mode patterns from the build — but be aware the savings from that removal are non-trivial.

## Known caveat — pwsh-from-pwsh invocation

`pwsh.exe` invoked from another `pwsh.exe` terminal (`pwsh → pwsh -File tiny11maker.ps1`) **deterministically produces ISOs that fail Win11 25H2 Setup product-key validation**, even though the build output is content-identical to working invocations. Mechanism is unknown; full investigation 2026-05-04 → 2026-05-06 confirmed every byte of the produced ISO matches a working build except for `reg.exe` timestamp/sequence noise inside hives.

The script blocks this combination at runtime with a clear error message. **Workaround**: launch `tiny11maker.ps1` from a `cmd.exe` or Windows PowerShell 5.1 terminal. A future bundled `.exe` launcher will eliminate this caveat by always running under a controlled host.

Five working invocation patterns:
- `cmd → powershell -File tiny11maker.ps1` ✅
- `cmd → pwsh -File tiny11maker.ps1` ✅
- `powershell → powershell -File tiny11maker.ps1` ✅
- `powershell → pwsh -File tiny11maker.ps1` ✅
- `pwsh → powershell -File tiny11maker.ps1` ✅

One blocked:
- `pwsh → pwsh -File tiny11maker.ps1` ❌ (rejected at startup with workaround instructions)

## Running tests

```powershell
pwsh -NoProfile -File tests/Run-Tests.ps1
```

508 Pester tests (catalog parsing + schema validation, selection model + reconcile/lock logic, registry hive helpers, four action handlers including the post-boot online emitter shapes, action dispatcher, ISO mounting + edition enumeration, autounattend templating + drift detection, worker / Core dispatch, bridge protocol, WebView2 SDK detection, post-boot generator + helpers golden + Format-PSNamedParams + task XML + SetupComplete + Install + the v1.0.2 audit-bundle regression guards across A3 / A4 / A5 / A6 / A7 / A11 + boot.wim pipelineSucceeded wrap + Core Hives -Global + the v1.0.3 BCP-47 language regex coverage across every Windows 11 Language Pack tag including Serbian Latin + the v1.0.3 `registry-pattern-zero` action-type coverage from catalog completeness phase 2 + v1.0.7 takeown/icacls stderr noise-suppression guards + v1.0.8 audit-cleanup guards: registry pattern-zero scope + catalog hive/required-field validation + autounattend missing-ID throw + autounattend 7-day cache expiry + filesystem noise-filter anchored regex + orchestrator type-aware Build-RelaunchArgs / NonInteractive self-elevation refuse + v1.0.10 retargeting of the UI source-text Pester suite onto the v1.0.9 Step 1 two-column / Step 3 segmented-cards surface: canMoveForward forward-nav predicate gates on outputFilled + outputClean + Output ISO Step 1 field markup with `.req-asterisk` label + `aria-required` input + reserved `.error-slot`, replacing 9 deleted assertions against the pre-v1.0.9 Step 3 output-required-warning + outputMissing predicate + Build ISO tooltip + 4 anchor rewrites on Cleanup.Tests.ps1 for buildDisabled wiring moved into renderIdleCtaCard / build-error path running through renderErrorCard + 1 PostBootCleanup anchor rewrite onto stable input id literals; dead `.output-required-warning` CSS rules + their 3 retained CSS-rule tests pruned in the same release) and 138 xUnit launcher tests (BuildHandlers / CleanupHandlers / EmbeddedResources drift / payload contracts + v1.0.3 ArchitectureGate rejection coverage for arm64 / arm / x86 hosts + v1.0.3 A13 HeadlessArgs parser + BuildLogPathResolver coverage + v1.0.7 AppVersion formatter + v1.0.8 ArgQuoting shared helper + bridge requestType echo + Process state cache-before-Dispose + v1.0.9 AutoScratchPath generator + PathValidationHandlers covering scratch + output path validation with writability probe).

Note on the v1.0.1 "409 / 0" headline: the 2026-05-14 empirical audit reconciled this against `Invoke-Pester` runs in a worktree at each landing commit and revealed v1.0.1 actually shipped at **408 passed / 1 failed** (the prior figure reported `TotalCount` rather than `PassedCount`). The persistent failure was a CRLF-vs-LF byte-equal mismatch in the helpers golden fixture and healed in the v1.0.2 cycle by the A6 W2 line-ending-normalize fix. The full audit-verified chain is embedded in `CHANGELOG.md` `[1.0.1] > Test counts > Audit-verified Pester test count chain`.

Build path and ISO install are smoke-tested via two documented matrices: the v1.0.1 baseline at `docs/superpowers/smoke/2026-05-12-post-boot-cleanup-smoke.md` (P1-P9 all PASS), and the v1.0.3 cycle matrix at `docs/superpowers/smoke/2026-05-14-v1.0.3-catalog-and-logging-smoke.md` (P1-P9 + A11-I3-S2 + A13-S1..S4 all PASS; A11-I3-S1 N/A on 25H2 with documented indirect-verification rationale; Findings 1, 3, 4 captured as informational). End-to-end automated build-pipeline + GUI tests beyond these manual matrices remain a future follow-up.

## VM testing recommendations

Built ISOs target Hyper-V Generation 2 + VirtualBox + VMware. Hybrid BIOS+UEFI bootable.

Recommended verification after install:
- Reach OOBE; complete with the local-account workaround if `tweak-bypass-nro` is applied.
- Boot to desktop; open Start menu and search for "edge" — expect web results to render (proves WebView2 Runtime is intact).
- Open Widgets via the taskbar — expect content to load (also WebView2-dependent).
- Verify the apps you removed are gone and the apps you kept (e.g., Edge if `keep-edge.json`) are present.

For headless validation, `dism /Get-WimInfo /WimFile:<your-iso>\sources\install.wim` shows what made it through.

## Contribution / fork boundary

This is a standalone hard fork. Issues and PRs filed here will not be propagated upstream. If you'd like changes to land in the upstream `ntdevlabs/tiny11builder`, file there separately.

## License / credits

Originally based on [`ntdevlabs/tiny11builder`](https://github.com/ntdevlabs/tiny11builder) by NTDEV. The upstream project's removal lists, registry tweaks, and overall approach inform the catalog. Refer to the upstream repository for license and contributor history.

Fork additions (catalog schema, selection/reconcile model, WebView2 + WPF wizard, Pester test suite, runspace-based progress streaming) by the tiny11options maintainers.
