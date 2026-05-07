---
title: Path C — Bundled .exe launcher
date: 2026-05-07
status: approved (brainstorming)
author: Jamie Chapman
---

# Path C — Bundled .exe launcher

## Context

tiny11options v0.2.0 ships as a PowerShell-based ISO trimmer with a WebView2 + WPF wizard hosted *from* PowerShell via `Tiny11.WebView2.psm1` and `Tiny11.Bridge.psm1`. Path C is the next major deliverable: a single signed `tiny11options.exe` that delivers the polished UX (no PowerShell window flash, no pwsh-pwsh-f environmental risk) and adds a built-in update mechanism so users on older versions can adopt fixes without manually re-downloading.

The v0.2.0 todo entry framed Path C as a thin `.exe` wrapper around the existing PS-hosted WPF window with a "~1 day" scope. During brainstorming the direction shifted to a native C# WPF host (full rewrite of the GUI shell). Revised scope estimate: ~1 work-week of focused implementation. The added work buys (a) elimination of the PowerShell-window flash, (b) elimination of the pwsh-pwsh-f environmental risk that the v0.2.0 runtime guard works around, and (c) native-fast bridge handler latency.

## Goals

- Single-file `tiny11options.exe` that GUI users download and double-click. No .NET runtime prerequisite.
- Headless invocation `tiny11options.exe -Source X -Edition 'Pro' -OutputIso Y` that mirrors the existing `pwsh tiny11maker.ps1 -Source X ...` semantics, with stdout/stderr flowing to the calling shell.
- Built-in update notification + one-click apply via Velopack.
- Code signing via Microsoft Trusted Signing so SmartScreen passes clean and updates apply silently.
- `pwsh tiny11maker.ps1` remains a documented advanced workflow. The `.ps1` / `.psm1` files stay in the repo unchanged in their roles as the actual ISO-build engine.

## Non-goals

- Cross-platform: the `.exe` is Windows-only by design; Win11 image trimming is a Windows-only domain.
- Automated end-to-end ISO build test harness — still deferred per the existing TODO.
- Auto-update for the script-based workflow. Only the `.exe` self-updates; users running `tiny11maker.ps1` manage versions via `git pull`.
- PowerShell module Authenticode signing.
- Multi-architecture: `win-x64` only for v1.0; ARM64 deferred.

## Decisions

### D1 — Update mechanism: Velopack with passive notification + one-click apply

User experience:
- Launcher checks for updates in the background on app startup (non-blocking, ~1s).
- If an update is available, a small badge appears next to the theme-toggle icon in the wizard chrome.
- User clicks the badge → small dialog: `v0.3.0 available — [View changelog] [Install & restart] [Dismiss]`.
- "Install & restart" downloads the delta `.nupkg`, applies it, restarts into the new version.
- "Dismiss" hides the badge until next app launch.
- Headless mode (`-Source X` etc.) skips the update check entirely. CI / automation users get deterministic behavior.

Mechanism: Velopack as the update orchestrator. We publish `.nupkg` files (full + delta) and a `RELEASES` manifest as GitHub Release assets. Velopack on the client fetches the manifest, computes the delta, and applies via its bootstrapper.

### D2 — Code signing: Microsoft Trusted Signing

- Service: Microsoft Trusted Signing (Azure-managed, ~$10/month, ~$120/year).
- Certificate-profile publisher name: **Jamie Chapman**.
- Auth: GitHub Actions OIDC federation to Azure. No long-lived signing keys checked into the repo.
- Both the `tiny11options.exe` itself AND every Velopack release artifact (`Setup.exe`, `.nupkg` files) are signed in the same workflow step.
- PowerShell module signing (`.ps1` / `.psm1`): out of scope. The launcher invokes `powershell.exe` with `-ExecutionPolicy Bypass`, so script signatures don't matter for the launcher's own use.

### D3 — C# project layout

- Subfolder `launcher/` under repo root holds the C# project.
- Solution file `tiny11options.sln` at repo root.
- Target framework: `net10.0-windows` (LTS through Nov 2028).
- WPF enabled, WinForms disabled.
- Self-contained single-file publish:
  - `<PublishSingleFile>true</PublishSingleFile>`
  - `<SelfContained>true</SelfContained>`
  - `<RuntimeIdentifier>win-x64</RuntimeIdentifier>`
  - `<IncludeAllContentForSelfExtract>true</IncludeAllContentForSelfExtract>`
- Resulting `.exe` size: ~75-90 MB. Velopack delta updates keep wire footprint small for existing users.
- Embedded resources via MSBuild globs:
  - `../ui/**/*` (HTML / CSS / JS for the WebView2 UI)
  - `../catalog/**/*` (catalog YAML)
  - `../autounattend.template.xml`
  - `../tiny11maker.ps1` (orchestrator)
  - The retained PS modules from `../src/`: `Tiny11.Iso.psm1`, `Tiny11.Worker.psm1`, `Tiny11.Catalog.psm1`, `Tiny11.Hives.psm1`, `Tiny11.Selections.psm1`, `Tiny11.Autounattend.psm1`, `Tiny11.Actions.psm1`, `Tiny11.Actions.Registry.psm1`, `Tiny11.Actions.Filesystem.psm1`, `Tiny11.Actions.ProvisionedAppx.psm1`, `Tiny11.Actions.ScheduledTask.psm1`
  - The new `tiny11maker-from-config.ps1` wrapper script (see "Implementation note" below)
  - Excludes `../tests/`, `../oscdimg-cache/`, `../dist/`, `../win11.iso`, `../docs/`, the deleted `Tiny11.Bridge.psm1` and `Tiny11.WebView2.psm1`
- WebView2 SDK: referenced via the existing vendored DLLs at `dependencies/webview2/1.0.2535.41/`. Keeps consistency with v0.2.0's vendored model and avoids NuGet version drift.
- Velopack: `<PackageReference Include="Velopack" Version="…" />` — exact version pinned at implementation start to whatever is the latest stable Velopack release at that time. Do NOT use a floating version range.
- Build output: `dist/` at repo root (gitignored; matches existing release-artifact convention).

### D4 — GUI hosting: native C# WPF

The C# host owns the WPF window and the WebView2 control directly. The bridge (JSON `{type, payload}` over `WebMessageReceived`) is implemented in C# and dispatches to native handlers. PowerShell becomes an implementation detail invoked only for ISO validation and the build worker.

This **deletes**:
- `src/Tiny11.WebView2.psm1` — window/theme/settings logic ported to C#.
- `src/Tiny11.Bridge.psm1` — JSON dispatch ported to C#.

The Pester tests covering those two modules are retired; their drift coverage moves into the new xUnit tier.

This **kept**, untouched:
- `tiny11maker.ps1` (orchestrator entry point)
- `Tiny11.Iso.psm1`, `Tiny11.Worker.psm1`, `Tiny11.Catalog.psm1`, `Tiny11.Hives.psm1`
- `Tiny11.Actions.*.psm1` (registry, filesystem, provisioned-appx, scheduled-task)
- `Tiny11.Selections.psm1` (still used by `tiny11maker.ps1`'s internal logic; the GUI's selection-reconcile path is implemented in C# alongside)
- `Tiny11.Autounattend.psm1` (drift test still applies)

The retained modules carry the heavy DISM / hive-loading / `dism.exe` orchestration. The Pester suite continues to cover them.

## Architecture

```
                          tiny11options.exe (.NET 10 WPF, self-contained)
                                          │
                ┌─────────────────────────┴────────────────────────┐
                │                                                  │
        no CLI args (GUI)                                  has CLI args (headless)
                │                                                  │
        ┌───────▼─────────┐                                ┌───────▼────────┐
        │ App startup     │                                │ Extract bundled│
        │  - Show window  │                                │ tiny11maker.ps1│
        │  - Init WebView2│                                │ + src/*.psm1 to│
        │  - Load ui/ from│                                │ %TEMP%\        │
        │    embedded res │                                │ tiny11options- │
        │  - Velopack     │                                │ <pid>\         │
        │    update check │                                │                │
        │    (background) │                                │ Spawn          │
        │                 │                                │ powershell.exe │
        │ Bridge dispatch:│                                │ -ExecutionPolicy│
        │  C# handlers    │                                │   Bypass       │
        │  for fast ops   │                                │ -NoProfile     │
        │  (browse, save, │                                │ -WindowStyle   │
        │  load, reconcile│                                │   Hidden       │
        │  )              │                                │ -File <ps1>    │
        │                 │                                │   <args>       │
        │  Subprocess pwsh│                                │                │
        │  for slow ops   │                                │ Stream stdout/ │
        │  (validate-iso, │                                │ err to console │
        │  build worker)  │                                │ via            │
        │                 │                                │ AttachConsole  │
        │                 │                                │                │
        │                 │                                │ Return child   │
        └─────────────────┘                                │ exit code      │
                                                           └────────────────┘
```

**Why PowerShell stays as the implementation language for ISO validation + build worker:**
1. The `dism.exe` / `Mount-DiskImage` / hive-loading code in `Tiny11.Iso.psm1` and `Tiny11.Worker.psm1` is hundreds of lines and well-tested by the Pester suite. Rewriting in C# would burn the test investment and introduce regressions.
2. Headless mode runs the same PS scripts as `tiny11maker.ps1` does today. Any user who runs `pwsh tiny11maker.ps1` standalone (the documented advanced workflow) gets identical behavior.

**Why GUI bridge handlers move to C#:**
1. Eliminates the pwsh-host-WPF window flash + the pwsh-pwsh-f environmental risk.
2. Native handler latency for browse / save / load / reconcile (~ms instead of process spawn).
3. Window / theme / settings code is UI infrastructure that belongs in the C# layer.

## Project structure

```
tiny11options/
├── launcher/                                 ← NEW — C# project tree
│   ├── tiny11options.Launcher.csproj
│   ├── App.xaml / App.xaml.cs                ← WPF app bootstrap
│   ├── MainWindow.xaml / MainWindow.xaml.cs  ← Hosts WebView2
│   ├── Program.cs                            ← Entry: arg detection, GUI vs headless
│   ├── Headless/
│   │   ├── HeadlessRunner.cs                 ← Extract PS resources, spawn pwsh, stream IO
│   │   └── EmbeddedResources.cs              ← Helpers: copy embedded .ps1/.psm1 to %TEMP%
│   ├── Gui/
│   │   ├── Bridge.cs                         ← WebMessageReceived → handler dispatch
│   │   ├── Handlers/
│   │   │   ├── BrowseHandlers.cs             ← Folder/file pickers (WPF dialogs)
│   │   │   ├── ProfileHandlers.cs            ← Save/load profile JSON
│   │   │   ├── SelectionHandlers.cs          ← Catalog reconcile (port of Tiny11.Selections)
│   │   │   ├── IsoHandlers.cs                ← Validate-iso (subprocess pwsh)
│   │   │   └── BuildHandlers.cs              ← start-build (subprocess pwsh + progress stream)
│   │   ├── Theme/ThemeManager.cs             ← System theme detect, light/dark toggle
│   │   ├── Settings/UserSettings.cs          ← Port of Tiny11.WebView2.psm1 settings code
│   │   └── Updates/UpdateNotifier.cs         ← Velopack check + theme-icon-area badge
│   ├── Resources/                            ← MSBuild <EmbeddedResource> globs target this
│   │   └── (no committed files; resources pulled from ../ui, ../src, ../catalog, ../*.xml)
│   ├── Tests/
│   │   └── tiny11options.Launcher.Tests.csproj  ← xUnit Tier 1
│   └── README.md                             ← Build instructions for launcher subproject
│
├── tiny11options.sln                         ← NEW — solution at repo root
│
├── src/                                      ← UNCHANGED in retained modules; Bridge + WebView2 deleted
├── ui/                                       ← UNCHANGED — embedded into .exe
├── catalog/                                  ← UNCHANGED — embedded into .exe
├── autounattend.template.xml                 ← UNCHANGED — embedded into .exe
├── tiny11maker.ps1                           ← UNCHANGED — embedded into .exe (headless mode)
├── tests/                                    ← Pester tests; entries for deleted modules removed
│
├── dist/                                     ← NEW — single-file publish + Velopack output (gitignored)
│
├── .github/workflows/release.yml             ← NEW — build + Trusted Signing + Velopack release
└── ... (all other existing files stay)
```

## Data flow

### Headless mode

```
Program.Main(args)
  └─ args.Length > 0 → HeadlessRunner.Run(args)
        ├─ tempDir = %TEMP%\tiny11options-<pid>\
        ├─ EmbeddedResources.ExtractTo(tempDir)
        │     copies tiny11maker.ps1 + src/*.psm1 + catalog/*.yaml + autounattend.template.xml
        ├─ Process.Start("powershell.exe",
        │     "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden " +
        │     "-File \"<tempDir>\\tiny11maker.ps1\" " + EscapeArgs(args))
        ├─ Stream child stdout/stderr → console (this app uses WindowsApplication subsystem +
        │     AttachConsole(ATTACH_PARENT_PROCESS) so output flows to the calling shell)
        ├─ Wait for child exit
        ├─ tempDir cleanup (best-effort; non-fatal if locked by AV)
        └─ Environment.Exit(child.ExitCode)
```

The `AttachConsole(ATTACH_PARENT_PROCESS)` trick is the standard pattern for a single `.exe` that wants both GUI mode (no console flash) and headless mode (output streams to the parent shell). Without it, `tiny11options.exe -Edition X` from PowerShell would either flash a console window or swallow stdout.

### GUI mode

```
Program.Main(args)
  └─ args.Length == 0 → App.Run()
        └─ MainWindow loads
              ├─ WebView2 init (CoreWebView2InitializationCompleted)
              │     ├─ Set virtual host: app.local → embedded ui/ resources
              │     ├─ Navigate to http://app.local/index.html
              │     └─ Subscribe to WebMessageReceived
              ├─ Theme detection + apply (system → user override from settings.json)
              ├─ Window size restore from settings.json
              └─ UpdateNotifier.CheckAsync() (background; non-blocking)
                    ├─ Velopack: query GitHub Releases manifest
                    ├─ If newer version found:
                    │     - Set Bridge state: updateAvailable = true
                    │     - Send {type:"update-available", payload:{version, changelog}} to JS
                    │     - JS shows badge dot next to theme icon
                    └─ Otherwise: no-op

JS: window.chrome.webview.postMessage({type:"validate-iso", payload:{isoPath:"…"}})
  └─ Bridge.WebMessageReceived
        └─ HandlerRegistry.Dispatch(message)
              └─ IsoHandlers.ValidateIso(payload):
                    ├─ Spawn pwsh subprocess: a small wrapper script that imports
                    │     Tiny11.Iso.psm1 from the in-app extracted copy and calls
                    │     Test-Tiny11SourceIsConsumer / Resolve-Tiny11ImageIndex
                    ├─ Read structured JSON result from child stdout
                    └─ Send {type:"iso-validated"|"iso-error", payload:…} to JS

User clicks Build:
  JS sends {type:"start-build", payload:{selections, options}}
    └─ BuildHandlers.StartBuild
          ├─ Write build-config.json to tempDir
          ├─ Spawn pwsh: tiny11maker.ps1 -ConfigPath tempDir\build-config.json
          │     (or a thin tiny11maker-from-config.ps1 wrapper — see "Implementation
          │     notes" below for the trade-off)
          ├─ Stream child stdout line-by-line → parse {type:"build-progress",…} markers
          │     The PS worker already emits structured JSON progress markers in v0.2.0
          ├─ For each marker: forward to JS as bridge message
          └─ On exit: send {type:"build-complete"|"build-error",…}
```

**Note on parent-of-pwsh:** since the GUI mode's parent is `tiny11options.exe` (a regular Windows app, not pwsh), the spawned pwsh child's parent process is the `.exe` itself — never pwsh. The pwsh-pwsh-f environmental issue from v0.1.0 cannot recur in this architecture.

### Implementation note: `-ConfigPath` vs `tiny11maker-from-config.ps1` wrapper

Two equivalent ways to feed selections to the build worker:
1. Add a `-ConfigPath` parameter to `tiny11maker.ps1` that reads selections from JSON instead of from interactive wizard state.
2. Keep `tiny11maker.ps1` interactive entry untouched; add a thin `tiny11maker-from-config.ps1` wrapper that reads JSON, sets selection state, and calls `Tiny11.Worker.psm1` directly.

Recommended: option 2. Avoids touching the entry script (less regression risk). The wrapper becomes a new file embedded into the `.exe` alongside `tiny11maker.ps1`.

## Error handling

### Headless mode failures

| Failure | Behavior |
|---|---|
| Resource extraction to %TEMP% fails (disk full, ACL) | Write error to stderr, exit code 10 |
| `powershell.exe` not on PATH | Write actionable error to stderr ("Windows PowerShell 5.1 or PowerShell 7+ is required"), exit code 11 |
| Child pwsh exits non-zero | Pass through child's exit code; child's stderr already streamed to console |
| Argument parsing failure (unknown flag) | Pass-through to PS — `tiny11maker.ps1`'s own param block rejects it; child handles UX consistency |
| %TEMP% cleanup fails (DLL still loaded by AV) | Log to debug stream, swallow — non-fatal; OS reaps %TEMP% on reboot |
| %TEMP% non-writable (corporate lockdown) | Try `%LOCALAPPDATA%\tiny11options\runtime\<pid>\` as alternate extraction dir; if that also fails, write error to stderr, exit code 12 |

### GUI mode failures

| Failure | Behavior |
|---|---|
| WebView2 Runtime missing on host | WPF MessageBox: "WebView2 Runtime is required. Install from <link>." Then `Process.Start("https://…/webview2runtime")` and exit. Same UX as the v0.2.0 PS guard. |
| ui/ embedded resource extraction fails | MessageBox + exit; no fallback because nothing to render |
| Subprocess pwsh fails for `validate-iso` | Send `{type:"iso-error", payload:{message}}` to JS; existing UI handles this path |
| Subprocess pwsh fails mid-build | Send `{type:"build-error", payload:{message, stdoutTail, stderrTail}}`; UI shows "Build failed" with details panel and "Open log" button |
| Velopack update check fails (network down, GitHub 503) | Silent — no badge, no log noise. Users manually fetch later if they care. |
| Velopack update apply fails | MessageBox "Update download failed: <reason>. Try again later." Don't crash the app; user keeps using current version |
| Bridge handler throws (programming error) | Log to file at `%LOCALAPPDATA%\tiny11options\logs\launcher-<date>.log`, send `{type:"handler-error", payload:{message}}` to JS, JS shows in error banner |
| Settings.json corrupt | Log + ignore (returns defaults); next save overwrites — same approach as v0.2.0 PS code |

### Logging

- GUI mode: `%LOCALAPPDATA%\tiny11options\logs\launcher-YYYY-MM-DD.log` (rolling daily, retain 7 days). Captures bridge errors, Velopack events, subprocess invocations.
- Headless mode: stderr only. No log file. Caller already has stderr in their script.

## Testing

### Tier 1 — xUnit unit tests

Project: `launcher/Tests/tiny11options.Launcher.Tests.csproj` (xUnit + Moq).

| Component | Coverage |
|---|---|
| `EmbeddedResources.ExtractTo` | Extracts to a temp dir; verify file count, content roundtrip, error on read-only target |
| `HeadlessRunner` arg pass-through | Build the spawn command-line for a known input; assert correct quoting / escaping (especially paths with spaces) |
| `Bridge` JSON dispatch | Mock handler registry; send malformed JSON, unknown type, valid type → assert correct handler invoked / error response |
| `SelectionHandlers.Reconcile` | Port of the Pester selections-reconcile tests to xUnit — same fixtures, same expected outputs (catalog with deps, locked items, conflicts) |
| `ProfileHandlers` save/load | Round-trip a profile JSON through save/load, assert schema preserved |
| `UserSettings` | Corrupt-JSON returns defaults; valid round-trip; concurrent-write doesn't dataloss (FileShare flags) |
| `ThemeManager` | System-theme change event → property changed; user override beats system |
| `UpdateNotifier` | Mock Velopack interface; available-update sets state + sends bridge message; no-update sets nothing |

### Tier 2 — Pester suite (existing)

Untouched PS modules continue to be covered:
- `Tiny11.Iso.psm1`, `Tiny11.Worker.psm1`, `Tiny11.Catalog.psm1`, `Tiny11.Hives.psm1`
- `Tiny11.Actions.*.psm1`
- `Tiny11.Selections.psm1` (Pester coverage retained; xUnit covers the C# port separately)
- `Tiny11.Autounattend.psm1` + drift test

Removed Pester tests:
- `tests/Tiny11.Bridge.Tests.ps1` (4 tests) — module deleted
- `tests/Tiny11.WebView2.Tests.ps1` (8 tests) — module deleted

Net post-Path-C: ~70 Pester tests + ~50 xUnit tests (estimated; final count after implementation).

### Tier 3 — Manual smoke

| # | Scenario |
|---|---|
| Smoke 1 | `tiny11options.exe` double-click → wizard opens → all 3 wizard steps render → cancel → exit cleanly |
| Smoke 2 | Headless: `tiny11options.exe -Source X -Edition 'Pro' -OutputIso Y` → ISO build matches `pwsh tiny11maker.ps1 -Source X -Edition 'Pro' -OutputIso Y` byte-for-byte (deep diff, same as v0.1.0 verification) |
| Smoke 3 | Velopack update flow: stage a fake newer release locally, run launcher, verify badge appears, click → install dialog → install + restart → verify new version runs |
| Smoke 4 | First-run extraction time on a clean machine (no `%TEMP%\.net\…\<hash>\` present) — should be <2s for the .NET 10 runtime extraction |
| Smoke 5 | SmartScreen behavior on a freshly-signed binary — should pass clean (no "unrecognized app" warning) |

### Drift test

New Pester test `tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1` that verifies the launcher `.csproj` `<EmbeddedResource>` globs include every file under `ui/`, the named subset of `src/` files, every file under `catalog/`, and the named XML / PS1 files. Catches the regression where someone adds a new file under `ui/` but forgets to verify the build embeds it.

## Release pipeline

### Workflow file: `.github/workflows/release.yml`

Triggered on tag push (`v*`).

```yaml
on:
  push:
    tags: ['v*']

jobs:
  build-and-sign:
    runs-on: windows-latest
    permissions:
      id-token: write          # for OIDC federation to Azure
      contents: write          # for gh release create
    steps:
      - checkout
      - setup-dotnet (10.x SDK)
      - dotnet restore launcher/tiny11options.Launcher.csproj
      - dotnet test launcher/Tests/                   # xUnit tier 1 must pass
      - pwsh -Command "Invoke-Pester tests/"          # Pester tier 2 must pass
      - dotnet publish launcher/tiny11options.Launcher.csproj
            -c Release
            -r win-x64
            -p:PublishSingleFile=true
            -p:SelfContained=true
            -p:IncludeAllContentForSelfExtract=true
            -o dist/raw/
      - Trusted Signing action (Azure.CodeSigning.Action@v0)
            - Auth: GitHub OIDC → Azure (federated, no stored secrets)
            - Sign: dist/raw/tiny11options.exe
            - Endpoint: from repo secrets
      - vpk pack
            --packId tiny11options
            --packVersion <tag without v>
            --packDir dist/raw/
            --mainExe tiny11options.exe
            --releaseNotes <changelog excerpt for this version>
            --output dist/releases/
            --signCommand <invoke Trusted Signing action for the .nupkg + Setup.exe>
      - gh release create v<version>
            dist/releases/*.nupkg
            dist/releases/Setup.exe
            dist/releases/RELEASES
            --notes-file <changelog excerpt>
            --target main
```

### Trusted Signing one-time setup

Documented in `launcher/README.md`:
1. Azure tenant + Trusted Signing account (~$10/mo) created in Azure Portal.
2. Certificate profile created (publisher: "Jamie Chapman").
3. GitHub repo configured with a federated identity credential pointing at the workflow.
4. Repo secrets:
   - `AZURE_TENANT_ID`
   - `AZURE_CLIENT_ID`
   - `AZURE_SUBSCRIPTION_ID`
   - `TRUSTED_SIGNING_ENDPOINT`
   - `TRUSTED_SIGNING_ACCOUNT`
   - `TRUSTED_SIGNING_CERT_PROFILE`

No long-lived signing key is checked in.

### Local dev signing

Local builds during development run unsigned. The xUnit + Pester tests run against unsigned binaries. SmartScreen will warn on locally-built `.exe` runs — that's fine for dev. Only CI release builds are signed.

### Velopack release artifacts

- `tiny11options-<version>-full.nupkg` — full self-contained app (~80 MB)
- `tiny11options-<version>-delta.nupkg` — delta from previous version (typically <5 MB if only handler / UI changes; full size if the .NET runtime version bumped)
- `Setup.exe` — Velopack's bootstrapper installer (the file new users download for first install; ~80 MB matching the full app)
- `RELEASES` — Velopack's manifest pointing at all available versions

The launcher's `UpdateNotifier` queries the GitHub Releases API for the latest tag, then asks Velopack to fetch the `RELEASES` file from that release's assets. Velopack handles delta selection automatically.

### Versioning

- `CHANGELOG.md` `[Unreleased]` block accumulates between releases.
- Cutting a release: rename `[Unreleased]` to `[<version>] - <date>`, push tag.
- The workflow reads the changelog to populate release notes — the changelog entry IS the release-notes copy seen in-app and on GitHub.

## Estimated scope

~1 work-week of focused implementation. Sub-budget:

| Area | Estimate |
|---|---|
| WPF App.xaml + MainWindow.xaml hosting WebView2 | ~2 hours |
| Theme detection + persistence (port from PS) | ~2 hours |
| Window size persistence (port from PS) | ~1 hour |
| WebView2 WebMessageReceived bridge + C# handler dispatch | ~4 hours |
| Native handlers (browse, save/load profile, reconcile-selections) | ~6 hours |
| Subprocess invocation of pwsh (ISO validation + build worker) | ~6 hours |
| Velopack integration | ~3 hours |
| MSBuild embedded resources for ui/, src/, catalog/, autounattend | ~2 hours |
| Single-file publish config + verify | ~2 hours |
| GitHub Actions release pipeline (build + sign + Velopack + GitHub Release) | ~4 hours |
| xUnit Tier 1 tests | ~5 hours |
| Pester drift coverage adjustments | ~2 hours |
| Manual smoke + iteration | ~6 hours |

Total: ~45 hours.

## Out of scope

- Cross-platform launcher
- End-to-end ISO build automation (still deferred per existing TODO)
- Auto-update for the script-based workflow
- PowerShell module Authenticode signing
- Multi-architecture (`win-x64` only; ARM64 deferred)

## Open follow-ups

None. Every design question raised in the v0.2.0 todo entry's Path C section is locked in by this spec.
