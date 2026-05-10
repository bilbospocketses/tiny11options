# tiny11options

A catalog-driven Windows 11 image trimmer with an interactive WebView2 + WPF wizard. Build your own customized Win11 ISO by picking what to keep and what to remove from a curated list of ~74 items across 10 categories.

This is a hard fork of [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder). It is standalone — no upstream contributions are planned.

## What's different from upstream

| | Upstream tiny11builder | tiny11options |
|---|---|---|
| Removal list | Fixed | You choose, item-by-item, via wizard or JSON profile |
| Interface | Linear PS script | 3-step WebView2 + WPF wizard, OR scripted via `-Source` / `-Config` |
| Catalog | Hardcoded in script | Single source of truth in `catalog/catalog.json` |
| Re-running with same selections | Re-edit script | `-Config <profile>.json` |
| Edge removal | Yes | Yes — but WebView2 Runtime is **explicitly preserved** (see below) |

## Two modes

### Interactive (default)

```powershell
# from cmd.exe or Windows PowerShell 5.1 (NOT from a pwsh terminal — see "Known caveat" below)
pwsh -NoProfile -File tiny11maker.ps1
```

Opens a 1200×900 wizard window (resizable; size is remembered between sessions in `%LOCALAPPDATA%\tiny11options\settings.json`). The theme follows your system light/dark preference on first launch, with a toggle button in the header to override (override is persisted in WebView2 localStorage):
1. **Source** — pick your Win11 ISO + edition, scratch directory, fast-build option.
2. **Customize** — browse 10 categories of removable items + tweaks; drill into any category to fine-tune; click anywhere on a row to toggle it; "Check all" / "Uncheck all" button operates on the visible filtered set; Save / Load profile JSON; cross-category search.
3. **Build** — review the summary; output ISO path is auto-prefilled to `<scratchDir>\tiny11.iso` (override anytime); click Build. Progress streams live; cancel button works mid-build; the "Show build details" panel stays open across phase changes once expanded.

### Scripted

```powershell
pwsh -NoProfile -File tiny11maker.ps1 `
    -Source 'C:\path\to\Win11.iso' `
    -Config 'config\examples\tiny11-classic.json' `
    -Edition 'Windows 11 Pro' `
    -OutputPath 'C:\out\tiny11.iso' `
    -NonInteractive
```

`-Source` accepts an `.iso` path or a drive letter (`E:`, `E:\`, just `E`).
`-Edition` resolves an edition name (case-insensitive exact match) to the right `ImageIndex` by enumerating the source. Cleaner than `-ImageIndex` because the index varies between ISOs.
`-ImageIndex` is the edition index inside `install.wim` (typically 6 for Pro on consumer ISOs). Mutually exclusive with `-Edition`; use whichever you prefer.
`-Config` is one of the example profiles or your own.
`-NonInteractive` suppresses the GUI; implied when both `-Source` and `-Config` are present.

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

**Build time:** Core builds take ~30-45 minutes (similar to standard with recovery compression) but the WinSxS-wipe phase alone runs ~5-10 minutes — longer than any single phase in a standard build.

**Cancellation note:** if you cancel during the WinSxS-wipe phase, the scratch directory is left in a non-resumable state (locked NTFS permissions, half-populated WinSxS_edit, dangling DISM mount). The build-progress UI surfaces a six-command elevated-PowerShell cleanup sequence to recover. Standard tiny11 builds don't have this issue — cancel cleanup is automatic.

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
- `actions` — one or more typed action records (`registry`, `provisioned-appx`, `filesystem`, `scheduled-task`)
- `runtimeDepsOn` — array of other item ids this item *requires* to also be applied (locks them when the parent is kept)

To add a new removal: append a new item to `catalog.json` matching the schema, run `pwsh -File tests/Run-Tests.ps1` (the catalog-loader tests will validate the schema), and submit a PR or just commit on your own fork.

## Profile examples

Three profiles are provided in [`config/examples/`](config/examples/):

| Profile | Purpose |
|---|---|
| `tiny11-classic.json` | Mirrors the upstream tiny11builder removal list — the closest analog to "what tiny11builder produces" |
| `keep-edge.json` | Like classic, but keeps Microsoft Edge (still removes everything else) |
| `minimal-removal.json` | Conservative — removes only obvious bloat (Xbox, Solitaire, Teams chat icon), keeps everything else |

A profile JSON has shape `{ "version": 1, "selections": { "<item-id>": "apply"|"skip", ... } }` and only needs to list items that diverge from the catalog defaults.

## System requirements

- Windows 11 host (10 may work for scripted builds; GUI requires WebView2 Runtime, which is preinstalled on Win11)
- PowerShell 7 (`pwsh.exe`) on PATH for the GUI; PowerShell 5.1 (`powershell.exe`) is sufficient for scripted mode
- Microsoft Edge WebView2 Runtime (preinstalled on Win11; on Win10, install from https://developer.microsoft.com/microsoft-edge/webview2/)
- ~10 GB free in the scratch directory
- A Windows 11 ISO (Microsoft media-creation-tool, direct ISO download, or VL/MSDN multi-edition).

The build process self-elevates via UAC; no need to launch as admin manually.

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

82 Pester tests covering catalog parsing + schema validation, selection model + reconcile/lock logic, registry hive helpers, four action handlers (registry / provisioned-appx / filesystem / scheduled-task), action dispatcher, ISO mounting + edition enumeration, source-is-consumer heuristic + edition-name resolution, autounattend templating + 3-tier acquisition + drift detection, worker dispatch, bridge protocol, WebView2 SDK detection.

GUI behavior and ISO build are verified manually; no headless GUI tests or end-to-end build tests in v0.2.0.

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
