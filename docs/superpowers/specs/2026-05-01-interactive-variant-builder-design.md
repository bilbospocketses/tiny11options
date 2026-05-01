# Interactive Variant Builder — Design Spec

**Status:** approved 2026-05-01
**Target version:** v1.0.0 of `bilbospocketses/tiny11options` (first proper release of the fork)
**Scope:** primary entry point `tiny11maker.ps1`. `tiny11Coremaker.ps1` is unchanged in v1.0.0.

---

## 1. Motivation

Today's `tiny11maker.ps1` is a 535-line linear script that strips a hardcoded set of components from a Windows 11 image. There is no way for a user to keep individual items (Edge, Microsoft Store apps they want, specific tweaks) without forking and hand-editing the script.

The goal of this work is to turn the script into a configurable image builder where the user **sees every change the script would make and selects which to apply**, while preserving the simple "clone the repo and run a `.ps1`" distribution model.

Constraints carried forward from the project's identity:

- Stays a PowerShell script — no compiled binary, no installer, no build pipeline.
- Network fetches at runtime are deliberate (per the project's dependency-policy waiver) and must remain so for `autounattend.template.xml`, `oscdimg.exe`, and the WebView2 SDK.
- Standalone fork — no upstream PRs.
- Windows-only. The work being done (DISM, offline registry hives, `oscdimg.exe`, WebView2) is fundamentally Windows-bound.

## 2. Goals and non-goals

### Goals

- An interactive GUI that presents every removable item and tweak organized into ~10 categories with two-tier drill-in.
- A scripted mode (`-Config <path>`) that consumes a JSON file matching what the GUI produces, for CI / repeated runs.
- A single `catalog/catalog.json` source-of-truth that drives both modes; adding a new removable item is a JSON edit, not a script change.
- An ISO-file-or-drive-letter input (`-Source`) instead of "user pre-mounts the ISO and types the drive letter."
- Bake the existing brittleness items (param-forwarding through self-elevation, double-prompt for image index, brittle architecture extraction, blocking `Read-Host` at end) into the new design so they're closed out as a side effect.

### Non-goals (explicitly out of scope for v1.0.0)

- **Linux portability.** The work is Windows-bound; a Linux port would be a parallel project.
- **Removing the Evergreen WebView2 Runtime.** It powers built-in Windows 11 surfaces (Start menu search results, Widgets); removing it breaks the OS in subtle ways. Off the table permanently for this fork.
- **`tiny11Coremaker.ps1` changes.** That script stays as-is in v1.0.0.
- **Live image-size estimates.** Computing accurate size requires running the removals; we don't lie with heuristics.
- **Browser-based fallback when WebView2 Runtime is missing on the host.** Surface a clear error and exit instead.
- **Auto-installing the WebView2 Runtime on the host.** Different category of action than the script's other network fetches; user installs it themselves.
- **Multi-edition build in one run.** One run = one edition. Run the script twice for two editions.

## 3. High-level architecture

```
                    +----------------------------------+
                    |        tiny11maker.ps1            |
                    |  (orchestrator + worker engine)   |
                    +----------------------------------+
                                |
              +-----------------+------------------+
              |                                    |
     [interactive mode]                   [scripted mode]
              |                                    |
              v                                    v
    +-----------------+                  +------------------+
    | UI launcher     |                  | -Config X.json   |
    | (loads catalog, |                  | (skip UI, read   |
    | spawns WPF win) |                  |  selections)     |
    +-----------------+                  +------------------+
              |
              v
    +------------------------------------------+
    | WPF window hosting WebView2              |
    |   Step 1: Source                         |
    |   Step 2: Customize (categories+drill-in)|
    |   Step 3: Build                          |
    +------------------------------------------+
              |
              +-- selections JSON --
              |
              v
    +------------------------------------------+
    | Worker engine (runspace)                 |
    |   For each catalog item set to "apply":  |
    |     execute its actions in order         |
    |   (provisioned-appx, filesystem, reg,    |
    |    scheduled-task)                       |
    |   Render autounattend.xml from template  |
    |   Build hybrid BIOS+UEFI ISO via oscdimg |
    +------------------------------------------+
              |
              v
        produces tiny11.iso at user-chosen output path
```

### Repository layout

```
tiny11options/
  tiny11maker.ps1                         # orchestrator + worker
  tiny11Coremaker.ps1                     # unchanged in v1.0.0
  autounattend.template.xml               # template with placeholders
  catalog/
    catalog.json                          # single source of truth for removable items
  ui/
    index.html
    style.css
    app.js
  config/
    examples/
      tiny11-classic.json                 # reproduces today's tiny11 behavior
      keep-edge.json                      # sample: keep Edge browser
      minimal-removal.json                # sample: trim only ad apps + telemetry
  dependencies/                           # populated on first run
    webview2/<version>/
      Microsoft.Web.WebView2.Core.dll
      Microsoft.Web.WebView2.Wpf.dll
      WebView2Loader.dll
    oscdimg/<version>/                    # existing-style cache (today's script downloads to PSScriptRoot; we'll move it here)
      oscdimg.exe
  docs/
    superpowers/specs/
      2026-05-01-interactive-variant-builder-design.md  # this file
  CHANGELOG.md
  README.md
  .gitattributes
```

### Three layers, clean responsibilities

1. **Catalog (data)** — `catalog/catalog.json`. The single source of truth for what can be applied. Both modes consume it. Adding a new item = one JSON edit.
2. **UI (presentation)** — `ui/*`. Renders the two-tier view, returns selections. Has no knowledge of how applications are performed.
3. **Worker engine (action)** — embedded in `tiny11maker.ps1`. Reads selections, dispatches to one of four action handlers. Has no knowledge of UI.

Each layer can be modified, tested, or replaced independently. A future Linux port would reuse layers 1 and 2 and rewrite only layer 3.

## 4. Catalog schema

`catalog/catalog.json` is a single JSON file. Two top-level concepts: removal items and tweak items, both expressed as checkbox-able "changes to apply". Verb is **"Apply"** — checked means "apply this change to the image."

### Schema

```jsonc
{
  "version": 1,
  "categories": [
    { "id": "store-apps",        "displayName": "Microsoft Store apps",          "description": "..." },
    { "id": "xbox-and-gaming",   "displayName": "Xbox & Gaming",                 "description": "..." },
    { "id": "communication",     "displayName": "Communication apps",            "description": "..." },
    { "id": "edge-and-webview",  "displayName": "Edge & WebView2",               "description": "..." },
    { "id": "onedrive",          "displayName": "OneDrive",                      "description": "..." },
    { "id": "telemetry",         "displayName": "Telemetry & diagnostics",      "description": "..." },
    { "id": "sponsored",         "displayName": "Sponsored content & Start pins","description": "..." },
    { "id": "copilot-ai",        "displayName": "Copilot & AI",                  "description": "..." },
    { "id": "hardware-bypass",   "displayName": "Hardware requirements",         "description": "..." },
    { "id": "oobe",              "displayName": "Setup experience (OOBE)",       "description": "..." }
  ],
  "items": [
    {
      "id": "remove-clipchamp",
      "category": "store-apps",
      "displayName": "Clipchamp video editor",
      "description": "The Clipchamp video editor app.",
      "default": "apply",
      "runtimeDepsOn": [],
      "actions": [
        { "type": "provisioned-appx", "packagePrefix": "Clipchamp.Clipchamp" }
      ]
    },
    {
      "id": "remove-edge",
      "category": "edge-and-webview",
      "displayName": "Microsoft Edge browser",
      "description": "Edge browser application + the inbox System32 Edge-Webview component + orphan uninstall registry keys. Does NOT remove the WebView2 Runtime, which apps and Windows shell features need.",
      "default": "apply",
      "runtimeDepsOn": [],
      "actions": [
        { "type": "filesystem", "op": "remove",            "path": "Program Files (x86)/Microsoft/Edge",          "recurse": true },
        { "type": "filesystem", "op": "remove",            "path": "Program Files (x86)/Microsoft/EdgeUpdate",    "recurse": true },
        { "type": "filesystem", "op": "remove",            "path": "Program Files (x86)/Microsoft/EdgeCore",      "recurse": true },
        { "type": "filesystem", "op": "takeown-and-remove","path": "Windows/System32/Microsoft-Edge-Webview",     "recurse": true },
        { "type": "registry",   "op": "remove", "hive": "SOFTWARE", "key": "WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Microsoft Edge" },
        { "type": "registry",   "op": "remove", "hive": "SOFTWARE", "key": "WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Microsoft Edge Update" }
      ]
    },
    {
      "id": "tweak-disable-telemetry",
      "category": "telemetry",
      "displayName": "Disable Windows telemetry",
      "description": "Sets AllowTelemetry=0, advertising ID off, ink/text harvesting off, dmwappushservice disabled. Removes the Customer Experience Improvement Program scheduled-task folder.",
      "default": "apply",
      "runtimeDepsOn": [],
      "actions": [
        { "type": "registry", "op": "set", "hive": "NTUSER",   "key": "Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo", "name": "Enabled",         "valueType": "REG_DWORD", "value": "0" },
        { "type": "registry", "op": "set", "hive": "SOFTWARE", "key": "Policies\\Microsoft\\Windows\\DataCollection",                  "name": "AllowTelemetry",  "valueType": "REG_DWORD", "value": "0" },
        { "type": "registry", "op": "set", "hive": "SYSTEM",   "key": "ControlSet001\\Services\\dmwappushservice",                      "name": "Start",           "valueType": "REG_DWORD", "value": "4" },
        { "type": "scheduled-task", "op": "remove", "path": "Microsoft/Windows/Customer Experience Improvement Program", "recurse": true }
      ]
    }
  ]
}
```

### Action types

| `type`              | Required fields                                                                 | Maps to today's script |
|---------------------|---------------------------------------------------------------------------------|------------------------|
| `provisioned-appx`  | `packagePrefix`                                                                 | `dism /Remove-ProvisionedAppxPackage` matched against `Get-ProvisionedAppxPackages` |
| `filesystem`        | `op` (`remove` \| `takeown-and-remove`), `path` (relative to scratchdir), `recurse` | The Edge / OneDrive surgery blocks |
| `registry`          | `op` (`set` \| `remove`), `hive` (`COMPONENTS`\|`DEFAULT`\|`NTUSER`\|`SOFTWARE`\|`SYSTEM`), `key`, plus `name`/`valueType`/`value` for `set` | The big offline-hive tweak blocks |
| `scheduled-task`    | `op` (`remove`), `path` (relative to `Windows/System32/Tasks`), `recurse`       | The task-XML deletion block |

Hives are referenced by **logical name**. The worker engine maps `"SOFTWARE"` → `HKLM\zSOFTWARE` at execution time.

### Granularity

- **Removal items: ~50** — one per AppX prefix in today's list; plus Edge, OneDrive setup exe.
- **Tweak items: ~13** — one per *block* of related registry sets in today's script (telemetry-as-a-bundle, sponsored-apps-as-a-bundle, hardware-bypass-as-a-bundle, etc.), not per individual reg key.

Total ~63 items across 10 categories.

### Hard prereqs (`runtimeDepsOn`)

Field expresses real-world runtime dependencies in the natural direction: "this item depends on those items being kept too."

**v1 catalog ships with zero edges.** The script doesn't remove the WebView2 Runtime, so Teams / Outlook / Copilot don't have a real prereq dependency on anything in our catalog. The schema field exists for future use.

Reconcile rule when edges do exist: when a dependent is set to `skip` (kept), the UI auto-sets each item in its `runtimeDepsOn` to `skip` and **locks** that checkbox with a tooltip explaining which dependent(s) are pinning it. When all pinning dependents return to `apply`, the item unlocks and restores the user's prior preference (or its catalog default).

### Defaults

Every item ships with `"default": "apply"`. First-run UI state reproduces today's tiny11 behavior exactly. Power user clicks Build immediately and gets the same image as today.

## 5. UI structure

Three-step wizard inside one resizable WPF window hosting WebView2 (~900×700 default, min 700×500).

### Common shell

```
+-------------------------------------------------------------------+
| tiny11options                                              [_][X] |
+-------------------------------------------------------------------+
|  (1) Source     >    (2) Customize    >    (3) Build              |  <- breadcrumb
+-------------------------------------------------------------------+
|                       [step content area]                         |
+-------------------------------------------------------------------+
|                                              [< Back]  [ Next > ] |
+-------------------------------------------------------------------+
```

Breadcrumb is non-clickable. User moves forward only after each step's required input is valid.

### Step 1 — Source

Fields:
- **Windows 11 ISO** — text input + Browse button. Accepts an `.iso` file path or a drive letter (`E`, `E:`, `E:\`). Pre-extracted directory paths are not supported in v1.0.0.
- **Edition** — dropdown populated after ISO is parsed (lists indices and edition names from `Get-WindowsImage`).
- **Scratch directory** — text input + Browse, default `$PSScriptRoot`. Needs ~10 GB free.
- **Unmount source ISO when build finishes** — checkbox, default checked. User-controlled instead of auto-detect logic.

Behavior:
- ISO Browse opens `OpenFileDialog` filtered to `.iso`.
- On ISO field blur: PS validates (does it have `install.wim` or `install.esd`?), populates Edition dropdown. Spinner shown during 1-3 second parse. If invalid, red banner under the field with specific reason.
- Next disabled until: ISO valid + Edition selected + Scratch dir writable.

### Step 2 — Customize

#### Category-grid view

```
+----------------------------------------------------------------+
| Search:  [____________________ ]  Items applied: 47/63         |
| [Save profile...] [Load profile...] [Reset to defaults]        |
|                                                                |
| +-----------------+ +-----------------+ +-----------------+    |
| | Store apps      | | Xbox & Gaming   | | Communication   |    |
| | <description>   | | <description>   | | <description>   |    |
| | [✓] 12 / 12     | | [✓] 7 / 7       | | [~] 4 / 5       |    |
| +-----------------+ +-----------------+ +-----------------+    |
|                                                                |
| ...                                                            |
+----------------------------------------------------------------+
```

Each card:
- Category name + short description.
- Master state indicator: `[✓] N/N` (all applied), `[ ] 0/N` (all skipped), `[~] X/N` (mixed). Click toggles all-on / all-off / restore-default.
- Click anywhere on body → drill into item view.

Top of grid:
- **Search box** filters items across all categories on display name + description.
- **Items applied counter** updates live.
- **Save profile** — `SaveFileDialog` (PS-hosted), default to `config/`, writes JSON in the same shape `-Config` consumes.
- **Load profile** — `OpenFileDialog`, validates `version` against catalog, applies to UI.
- **Reset to defaults** — restores every item to its catalog `default`.

#### Item drill-in view

```
+----------------------------------------------------------------+
| < Back to categories            Communication apps             |
|                                                                |
| Search in this category: [________________ ]                   |
| Apply all  Skip all  Reset                                     |
|                                                                |
| [✓] Microsoft Mail & Calendar (communicationsapps)             |
|     The legacy Mail and Calendar app.                          |
|                                                                |
| [⊘] Example item                                       🔒      |
|     Locked — kept because you chose to keep <dependent>.       |
|     <Click to scroll to that dependent>                        |
+----------------------------------------------------------------+
```

Per-item display:
- Checkbox state: `[✓]` applied / `[ ]` skipped / `[⊘]` locked-skipped (greyed) / `[⊗]` locked-applied (greyed).
- Display name + package name or path in muted style.
- One-line description from catalog.
- Locked items show 🔒 + a yellow "why" line listing every dependent currently pinning them.

### Step 3 — Build

```
+----------------------------------------------------------------+
|  Ready to build                                                |
|                                                                |
|  Source:      <path>                                           |
|  Edition:     <name> (index N)                                  |
|  Scratch:     <path>                                           |
|                                                                |
|  Output ISO:                                                   |
|    [ <scratchdir>\tiny11.iso ]                                 |
|                                                  [ Browse... ] |
|                                                                |
|  Changes to apply:  47 items across 8 categories               |
|     [Show details ▾]                                           |
|                                                                |
|  Estimated time: 15-30 minutes                                 |
|                                                                |
|                          [ Build ISO ]                         |
+----------------------------------------------------------------+
```

Output path:
- Defaults to `<scratchdir>\tiny11.iso` (matches today's script behavior).
- Browse opens `SaveFileDialog` filtered to `.iso`, default name `tiny11.iso`.
- Disabled scenarios: directory doesn't exist, no write permission, target equals source ISO, target inside scratch working subfolders.
- Yellow banner if target file already exists ("will be overwritten"). No modal.

### Build progress

Same window transitions to a progress view (no close):

```
+----------------------------------------------------------------+
|  Building tiny11 image...                                      |
|  [============================>          ] 64%                  |
|  Phase: Removing provisioned apps                              |
|  Step:  Removing Microsoft.WindowsTerminal (32 of 47)          |
|  [Show log ▾]                                                  |
|                                              [ Cancel build ]  |
+----------------------------------------------------------------+
```

Progress bar advances by phase: mount → app removal → registry tweaks → scheduled task removal → finalize WIM → boot.wim treatment → ISO build.

PS posts events back via `CoreWebView2.PostWebMessageAsString`. "Show log" expander reveals the raw DISM/PS output for users wanting detail.

On success: progress turns green, "Open output folder" + "Close" buttons appear.

On Cancel: PS attempts cleanup (unmount, remove scratchdir) and closes the window. Cancellation mid-DISM is best-effort; we surface a warning that scratch may need manual cleanup.

### Visual style

- Modern flat / Fluent-inspired, rounded corners, subtle shadows, generous whitespace.
- Light + dark themes auto-detected from `HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`.
- System accent color picked up from registry for primary buttons and breadcrumb highlight.
- Inline SVG icons (no font-icon CDN, no web fonts).
- Typography: Segoe UI Variable (system default on Win11).

## 6. PS ↔ WebView bridge

### Bootstrap sequence

1. Resolve dependencies (WebView2 SDK assemblies; fetch from NuGet on first run).
2. `Add-Type` the WPF and WebView2 assemblies.
3. Build XAML window from a small here-string; locate the `WebView2` control.
4. Init `CoreWebView2Environment` with userdata folder under `dependencies/webview2/`.
5. `EnsureCoreWebView2Async` (synchronously waited).
6. `SetVirtualHostNameToFolderMapping("ui.tiny11options", "<repo>/ui", DenyCors)` so the page sees itself as a normal HTTPS origin.
7. `AddScriptToExecuteOnDocumentCreatedAsync($"window.__tinyCatalog = {catalogJson};")` so the catalog is available before any page script runs.
8. Subscribe `WebMessageReceived` handler.
9. Navigate to `https://ui.tiny11options/index.html`.
10. `ShowDialog()` — blocks PS until window closed.

### Dependency model

Three categories of dependency, all per the project's dependency-policy waiver:

| Dependency | Resolution | Refresh |
|---|---|---|
| WebView2 SDK assemblies | First-run fetch from `https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/<pinned-version>`, extract three required files into `dependencies/webview2/<version>/`, cache locally | Pin update in script |
| `oscdimg.exe` | First-run fetch from MS symbol server (existing logic; relocate cache from `$PSScriptRoot` to `dependencies/oscdimg/<version>/`) | Pin update in script |
| `autounattend.template.xml` | Three-tier: local file → fork URL → embedded fallback | Update file → update fork URL response → update embedded copy |
| WebView2 **Runtime** (host) | NOT fetched. Detected at startup; clear error + install URL if missing | User installs via Microsoft |

### Message protocol

All messages are JSON strings with a discriminator field `type`. No correlation IDs, no schema versioning, no RPC framework.

**JS → PS:**

| `type`                  | Payload fields |
|-------------------------|----------------|
| `validate-iso`          | `path` |
| `validate-output-path`  | `path` |
| `save-profile-request`  | `selections` |
| `load-profile-request`  | (none) |
| `build`                 | `source`, `imageIndex`, `scratchDir`, `outputPath`, `unmountSource`, `selections` |
| `cancel`                | (none) |
| `close`                 | (none) |

**PS → JS:**

| `type`              | Payload fields |
|---------------------|----------------|
| `iso-validated`     | `editions[]` (each `{index, name, architecture, languageCode}`) |
| `iso-error`         | `message` |
| `output-validated`  | `warning?` |
| `output-error`      | `message` |
| `profile-saved`     | `path` |
| `profile-loaded`    | `selections` |
| `profile-error`     | `message` |
| `build-progress`    | `phase`, `step`, `percent`, `logLine?` |
| `build-complete`    | `outputPath` |
| `build-error`       | `message`, `phase?`, `partial?` |

### Build worker — runspace pattern

Build phase runs in a separate runspace so the UI thread stays responsive. Worker calls a `Post-Progress` helper that marshals via `$window.Dispatcher.Invoke` to `WebView.PostWebMessageAsString`. Cancellation token checked at phase boundaries (mount → unmount → DISM call boundaries), not mid-DISM.

### Failure modes

| Failure | Detection | UX |
|---|---|---|
| WebView2 Runtime missing on host | `EnsureCoreWebView2Async` throws | Console error: "Microsoft Edge WebView2 Runtime is required. On Windows 11 this is preinstalled; on Windows 10 install from https://developer.microsoft.com/microsoft-edge/webview2/." Exit. |
| WebView2 SDK NuGet fetch fails | `Invoke-WebRequest` throws / extraction fails | Console error with the URL and the error; exit. |
| HTML page fails to load | `NavigationCompleted.IsSuccess=false` | Window shows blank → log to console → close window. |
| User force-closes window mid-build | `Window.Closing` event | Cancel token fires; worker cleans up scratch dir; PS exits. |
| Build phase throws unhandled | try/catch around `Invoke-BuildPipeline` | Post `build-error` with phase + message + partial state; worker terminates; user sees error screen with cleanup-required warning. |

## 7. autounattend.xml templating

The current `autounattend.xml` has values that overlap with catalog tweak items:
- `HideOnlineAccountScreens=true` overlaps with `tweak-bypass-nro` (BypassNRO=1 in registry).
- `ConfigureChatAutoInstall=false` overlaps with `tweak-disable-chat-icon`.

To prevent contradictions, autounattend.xml is **templated** at build time from `autounattend.template.xml` against the user's selections.

### Template placeholders

```xml
<HideOnlineAccountScreens>{{HIDE_ONLINE_ACCOUNT_SCREENS}}</HideOnlineAccountScreens>
<ConfigureChatAutoInstall>{{CONFIGURE_CHAT_AUTO_INSTALL}}</ConfigureChatAutoInstall>
<Compact>{{COMPACT_INSTALL}}</Compact>
<Value>{{IMAGE_INDEX}}</Value>
```

The template-resolution map lives in the script:

```powershell
$autounattendBindings = @{
    'HIDE_ONLINE_ACCOUNT_SCREENS' = if ($selections['tweak-bypass-nro'] -eq 'apply') { 'true' } else { 'false' }
    'CONFIGURE_CHAT_AUTO_INSTALL' = if ($selections['tweak-disable-chat-icon'] -eq 'apply') { 'false' } else { 'true' }
    'COMPACT_INSTALL'             = if ($selections['tweak-compact-install'] -eq 'apply') { 'true' } else { 'false' }
    'IMAGE_INDEX'                 = $imageIndex
}
```

A new catalog item `tweak-compact-install` (default `apply`) is added so `<Compact>` is no longer unconditional.

### Three-tier acquisition chain

1. `autounattend.template.xml` exists next to script → use it.
2. Missing → `Invoke-RestMethod https://raw.githubusercontent.com/bilbospocketses/tiny11options/refs/heads/main/autounattend.template.xml` → cache locally.
3. Network fetch fails → fall back to a here-string baked into the script with the canonical template.

When the embedded fallback fires, the script logs "using embedded autounattend template" so the user knows.

**Maintenance:** the embedded fallback must stay in sync with `autounattend.template.xml`. A small Pester test compares the embedded string against the file content and fails the test if they diverge.

## 8. Script param surface

```powershell
tiny11maker.ps1 [-Source <path-or-letter>]
                [-Config <selections.json>]
                [-ImageIndex <n>]
                [-ScratchDir <path>]
                [-OutputPath <iso-path>]
                [-NonInteractive]
```

All params optional. Friction-minimized:

- **Interactive launch:** `tiny11maker.ps1` — wizard handles everything.
- **Pre-filled interactive launch:** `tiny11maker.ps1 -Source <path>` — wizard opens with Step 1 pre-filled.
- **Scripted launch:** `tiny11maker.ps1 -Source <path> -Config profile.json` — `-NonInteractive` is implied; GUI is skipped.
- **Forced non-interactive:** `-NonInteractive` may be passed explicitly; if any required input is missing, script errors out instead of prompting or launching the GUI.

Self-elevation forwards `$PSBoundParameters` losslessly via the runas relaunch — fixes today's "self-elevation drops args" brittleness item.

## 9. Brittleness items closed by this work

The four items deferred under todo item #3 are subsumed by this refactor:

| Item | Resolution |
|---|---|
| Self-elevation drops args | New param surface (`-Source`, `-Config`, `-OutputPath`, `-ScratchDir`, `-ImageIndex`, `-NonInteractive`) all forwarded losslessly through runas via `$PSBoundParameters` serialization |
| Double-prompt for image index | Eliminated — Step 1 has one Edition dropdown |
| Brittle architecture extraction (regex on `dism /Get-WimInfo`) | Replaced with `(Get-WindowsImage -ImagePath ... -Index $index).Architecture` |
| Bare `Read-Host "Press Enter"` blocking script end | Removed — build-complete screen has a Close button instead |

After this lands, todo item #3 is closed (not re-deferred).

## 10. Test strategy

| Layer | Approach |
|---|---|
| Catalog parsing & dispatch logic | Pester unit tests: action-handler argument construction, hive-name mapping, `runtimeDepsOn` reconciliation, profile JSON load/save round-trip, autounattend template resolution |
| Embedded autounattend fallback drift | Pester test asserts the embedded here-string equals `autounattend.template.xml` byte-for-byte |
| End-to-end build | Manual VM smoke test per release: build a `tiny11-classic.json` profile, boot resulting ISO in Hyper-V Gen2 + VirtualBox, verify install completes and Start menu/search/Widgets work |
| Automated VM harness | Out of scope for v1.0.0; tracked in todo item #2 |

CI runs Pester only. Manual VM smoke is a release-gate checklist item.

## 11. Versioning

This refactor changes invocation from positional drive letters (`tiny11maker.ps1 E D`) to a friction-minimized flag set. Breaking change for the small set of users running the existing script as a one-liner.

**v1.0.0** is the first proper release tag of the fork. Subsequent catalog additions are minor versions; subsequent breaking schema/UI changes are majors.

CHANGELOG already exists from earlier bootstrap; ship-time entry will move from `[Unreleased]` to `[1.0.0] - <release-date>`.

## 12. Out-of-scope items (revisited)

For clarity, these are NOT being built in v1.0.0:

- Linux / cross-platform support
- Removing the WebView2 Runtime (off the table permanently)
- `tiny11Coremaker.ps1` changes
- Live image-size estimates
- Browser-based UI fallback when WebView2 missing
- Auto-installing the WebView2 Runtime on the host
- Multi-edition build in one run
- Automated VM test harness (todo item #2)

## 13. Open questions / future work

These don't block v1.0.0 but should be revisited:

- **Profile schema versioning** — when we eventually need to migrate a saved profile across catalog versions, how do we handle removed/renamed item IDs? Likely a "migrate" hook in the load path.
- **Catalog deltas vs. full snapshots in profile JSON** — current design stores only items the user has explicitly chosen (others use catalog default). This means catalog-default changes silently affect old profiles. Pro: profiles stay current. Con: surprise. Worth a future audit.
- **Soft warnings (`softWarnings` field)** — deferred; reconsider if real-world reports show items that "probably still work but might be flaky" warrant non-blocking notices. Until then, the `description` field carries that information.
- **Per-edition catalog** — some items only apply to specific Windows editions (e.g. Pro-only). Today's catalog ignores edition. If we get reports of failures on specific editions, add an optional `editionFilter` field.

## 14. Acceptance criteria (definition of done for v1.0.0)

- [ ] `tiny11maker.ps1` launches, GUI renders, three wizard steps function.
- [ ] `catalog/catalog.json` covers every removal and tweak block in today's script (~63 items, ~10 categories).
- [ ] User can build today's tiny11 image via "click through with defaults."
- [ ] User can build a "keep Edge" image (un-check Edge category) and the resulting ISO boots and installs.
- [ ] Profile save/load round-trips through `config/<name>.json`.
- [ ] Scripted mode (`-Source -Config`) produces the same ISO as the equivalent GUI selections.
- [ ] WebView2 Runtime missing → clear error, no crash.
- [ ] WebView2 SDK first-run fetch works on a clean machine.
- [ ] All four brittleness items closed.
- [ ] Manual VM smoke passes for `tiny11-classic.json` profile in Hyper-V Gen2 + VirtualBox.
- [ ] Pester unit tests pass.
- [ ] CHANGELOG updated; `[1.0.0]` entry written.
- [ ] README updated to describe the new workflow + WebView2 boundary explanation.
