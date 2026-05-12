# tiny11 Core build mode — design spec

**Date:** 2026-05-09
**Branch:** `feat/path-c-launcher`
**Target version:** v1.0.0 (extends previously-scoped Path C launcher work)
**Author:** brainstorming session 2026-05-09 (Jamie + Claude)

---

## 1. Overview

Add a **tiny11 Core** build mode to the launcher as an alternative to the standard tiny11 build. Core produces a significantly smaller Windows 11 image (sub-2 GB savings via WinSxS wipe + heavier appx/system-package removal + Windows Update + Windows Defender disable) at the cost of serviceability — the resulting install cannot install Windows Updates, add language packs, or enable Windows features.

The feature ports the unique operations of upstream `ntdevlabs/tiny11builder`'s `tiny11Coremaker.ps1` into our launcher's architecture, reusing existing modules (`Tiny11.Iso`, `Tiny11.Hives`, `Tiny11.Actions.*`) where the operations overlap and adding a new `Tiny11.Core` module for Core-specific logic.

### 1.1 Use cases

- **Rapid VM testing** — provision a minimal Win11 image for short-lived dev/test VMs where serviceability isn't needed
- **Reduced attack surface for hardened deployments** — fewer installed components, no Windows Update mechanism active
- **Embedded / appliance scenarios** — Win11 as a bounded runtime where post-install change is undesirable

### 1.2 Explicit non-use-cases

- **Daily-driver Windows install** — non-serviceability makes ongoing security patching impossible
- **Enterprise managed deployments** — domain join + group policy + WSUS workflows depend on Windows Update functioning
- **Long-lived VMs** — the same security-patch issue applies even in VM contexts that persist past initial provisioning

The launcher's UI surfaces these caveats prominently (warning panel below the Core checkbox in Step 1) so users selecting Core mode do so with full awareness of the tradeoff.

### 1.3 Success criteria

1. Core checkbox in Step 1 toggles cleanly; warning + .NET 3.5 checkbox + breadcrumb behavior all respond as designed
2. Core build subprocess produces a working tiny11 Core ISO (boots in Hyper-V, completes Setup, reaches desktop)
3. Output ISO is < 50% the size of an equivalent standard tiny11 build from the same source ISO
4. Cancel during a Core build correctly emits `build-error` to UI; the user has a path to scratch-dir cleanup via in-UI command guidance
5. xUnit and Pester suites stay green; new Core-specific tests cover the data accessors and orchestration functions

---

## 2. Decisions log (from brainstorming)

| topic | decision |
|---|---|
| **Integration depth** | Deep refactor — new `src/Tiny11.Core.psm1` module + `tiny11Coremaker-from-config.ps1` wrapper. Reuse existing `Mount-Tiny11Source`, `Tiny11.Hives`, `Tiny11.Actions.*` modules. Drop upstream `tiny11Coremaker.ps1` after Phase 7 smoke confirms wrapper parity. |
| **Step 2 behavior in Core** | Dim "Customize" breadcrumb pip; navigation skips it on Next/Back. |
| **.NET 3.5** | New Step 1 checkbox visible only when Core is checked. Default unchecked. |
| **Fast build** | Hidden when Core is on (Core has its own fixed compression sequence). |
| **Warning** | Inline below Core checkbox; paraphrased copy. Expands when Core is checked, collapses when unchecked. |
| **Cancel** | Always works. Build-progress UI surfaces the scratch-cleanup caveat with a pre-rendered PowerShell command sequence. |
| **Test orchestrator** | `Invoke-Tiny11CoreBuildPipeline` is unit-untested (24 phases × DISM/filesystem mocking is high-effort low-payoff). Reliance on Phase 7 smoke. Individual Core operations (`Invoke-Tiny11CoreWinSxsWipe`, etc.) are unit-tested with mocked DISM/filesystem. |

---

## 3. Architecture

### 3.1 File / module layout

```
ui/
├── app.js                              ← extended (state.coreMode, state.enableNet35, render changes, nav)
├── style.css                           ← extended (.breadcrumb [data-disabled], .core-warning, .cleanup-cmd)
└── index.html                          ← unchanged

launcher/
├── Gui/
│   └── Handlers/
│       └── BuildHandlers.cs            ← extended (script-path branching on coreMode)
└── Tests/
    ├── BuildHandlersTests.cs           ← extended (4 new tests for Core routing + payload-omit behavior)
    └── ResourceCacheHashTests.cs       ← unchanged

src/                                    ← PS modules
├── Tiny11.Core.psm1                    ← NEW — Core-specific data accessors + orchestrators
├── Tiny11.Iso.psm1                     ← reused for Mount/Get-Editions/Resolve-ImageIndex
├── Tiny11.Hives.psm1                   ← reused for hive load/unload
├── Tiny11.Actions.Registry.psm1        ← reused for reg ops
├── Tiny11.Actions.Filesystem.psm1      ← reused for takeown+icacls+rm
├── Tiny11.Actions.ProvisionedAppx.psm1 ← reused for /Remove-ProvisionedAppxPackage
├── Tiny11.Actions.ScheduledTask.psm1   ← reused for scheduled task removal
└── Tiny11.Worker.psm1                  ← reused for oscdimg invocation

tests/
├── Tiny11.Core.Tests.ps1               ← NEW — ~24 Pester tests
└── Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1
                                         ← updated (csproj expectations + exclusion list amended)

(repo root)
├── tiny11maker.ps1                     ← unchanged (standard mode entry)
├── tiny11maker-from-config.ps1         ← unchanged (standard mode wrapper)
├── tiny11Coremaker-from-config.ps1     ← NEW (Core mode wrapper, ~150 lines)
├── tiny11Coremaker.ps1                 ← retained as parity reference until Phase 7 smoke; deleted in follow-up commit
├── tiny11-iso-validate.ps1             ← unchanged
└── tiny11-profile-validate.ps1         ← unchanged

launcher/tiny11options.Launcher.csproj  ← updated (<EmbeddedResource> entries for new files)
CHANGELOG.md                            ← updated (new "Added — tiny11 Core build mode" section)
README.md                               ← updated (new "## Build modes" section)
```

### 3.2 `src/Tiny11.Core.psm1` API

```powershell
# Data accessors — pure functions, return static arrays
Get-Tiny11CoreAppxPrefixes              # 32 entries, hardcoded
Get-Tiny11CoreSystemPackagePatterns -LanguageCode <string>   # 12 entries, lang-templated
Get-Tiny11CoreFilesystemTargets         # Edge dirs, OneDrive, WinRE, WebView paths
Get-Tiny11CoreScheduledTaskTargets      # 5 task paths
Get-Tiny11CoreRegistryTweaks            # ~60 reg ops as data array (category, op, hive, path, name, type, value)
Get-Tiny11CoreWinSxsKeepList -Architecture <amd64|arm64>     # subdir patterns to retain

# Operation orchestrators — perform work, emit Write-Marker JSON
Invoke-Tiny11CoreWinSxsWipe -ScratchDir <path> -Architecture <amd64|arm64>
Invoke-Tiny11CoreSystemPackageRemoval -ScratchDir <path> -Patterns <string[]> -LanguageCode <string>
Invoke-Tiny11CoreNet35Enable -ScratchDir <path> -SourcePath <path>     # gated; caller decides whether to invoke
Invoke-Tiny11CoreImageExport -SourceImageFile <path> -DestinationImageFile <path> -SourceIndex <int> -Compress <max|recovery>

# Top-level orchestrator — emits build-progress markers per phase
Invoke-Tiny11CoreBuildPipeline -Source <path> -ImageIndex <int> -ScratchDir <path> -OutputIso <path> -EnableNet35 <bool> -UnmountSource <bool> -ProgressCallback <scriptblock>
```

### 3.3 `tiny11Coremaker-from-config.ps1` shape

Mirrors `tiny11maker-from-config.ps1` structurally:

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutputIso,
    [int]$ImageIndex = 0,
    [string]$Edition,
    [string]$ScratchDir,
    [switch]$EnableNet35,
    [switch]$UnmountSource
)

# (Imports + Write-Marker helper identical to standard wrapper)

try {
    # Preflight: mount, enumerate, resolve index
    Write-Marker 'build-progress' @{ phase='preflight'; step='Mounting source for edition enumeration'; percent=0 }
    $preflightMount = Mount-Tiny11Source -InputPath $Source
    try {
        $editions = Get-Tiny11Editions -DriveLetter $preflightMount.DriveLetter
        if ($Edition -and $ImageIndex -le 0) {
            $ImageIndex = Resolve-Tiny11ImageIndex -Editions $editions -Edition $Edition
        }
    } finally {
        if ($preflightMount.MountedByUs) {
            Dismount-Tiny11Source -IsoPath $preflightMount.IsoPath -MountedByUs:$true -ForceUnmount:$true
        }
    }

    # Hand off to the Core build pipeline orchestrator
    Invoke-Tiny11CoreBuildPipeline `
        -Source $Source `
        -ImageIndex $ImageIndex `
        -ScratchDir $ScratchDir `
        -OutputIso $OutputIso `
        -EnableNet35 $EnableNet35.IsPresent `
        -UnmountSource $UnmountSource.IsPresent `
        -ProgressCallback {
            param($p)
            Write-Marker 'build-progress' @{ phase=$p.phase; step=$p.step; percent=$p.percent }
        }

    Write-Marker 'build-complete' @{ outputPath = $OutputIso }
    exit 0
}
catch {
    Write-Marker 'build-error' @{ message = $_.Exception.Message; stackTrace = $_.ScriptStackTrace }
    exit 1
}
```

---

## 4. UI specification

### 4.1 Step 1 layout

`renderSourceStep` extends to render Core controls below the existing fast-build row.

**State (Core OFF — default):**

```
Windows 11 ISO
[path input.....................] [Browse...]
(error banner if any)
Edition
[edition select................] [browse-spacer]
Scratch directory
[path input.....................] [Browse...]
[✓] Unmount source ISO when build finishes
[✓] Fast build (skip recovery compression)        ← checked by default per polish bundle
  Skips DISM /Cleanup-Image and /Export-Image /Compress:recovery.
  Saves 25–40 minutes per build...
[ ] Build tiny11 Core (smaller, non-serviceable)
```

**State (Core ON):**

```
Windows 11 ISO
[path input.....................] [Browse...]
Edition
[edition select................] [browse-spacer]
Scratch directory
[path input.....................] [Browse...]
[✓] Unmount source ISO when build finishes
                                              ← fastBuild row hidden entirely
[✓] Build tiny11 Core (smaller, non-serviceable)
┌────────────────────────────────────────────────────┐
│ ⚠  tiny11 Core builds a significantly smaller     │
│ image, but the output is not serviceable: you      │
│ cannot install Windows Updates, add languages,     │
│ or enable Windows features after install.          │
│ Suitable for VM testing or short-lived development │
│ environments — not as a daily-driver Windows.      │
└────────────────────────────────────────────────────┘
[ ] Enable .NET 3.5 (legacy app compatibility)
  .NET 3.5 must be enabled at build time — cannot be
  added after install. Adds ~100 MB.
```

### 4.2 Breadcrumb behavior

Static markup unchanged (`<div class="breadcrumb"><span data-step="source">Source</span>…</div>`). When `state.coreMode === true`, JS adds `data-disabled="true"` to the `[data-step="customize"]` span. CSS:

```css
.breadcrumb span[data-disabled="true"] {
    opacity: 0.4;
    pointer-events: none;
}
```

Pip stays visually present (so the user sees what was skipped) but reads as inactive.

### 4.3 Navigation routing

```js
// In Next button click handler
if (state.step === 'source') {
    state.step = state.coreMode ? 'build' : 'customize';
}
else if (state.step === 'customize') {
    state.step = 'build';
}

// In Back button click handler
if (state.step === 'customize') {
    state.step = 'source';
}
else if (state.step === 'build') {
    state.step = state.coreMode ? 'source' : 'customize';
}
```

`canAdvance()` for `'source'` returns true under same conditions regardless of Core state.

### 4.4 Step 3 rendering when Core is ON

`renderBuildStep` branches on `state.coreMode`:

```
Ready to build
Source       D:\OneDrive\...\Win11_25H2_English_x64_v2.iso
Edition      Windows 11 Pro (index 6)
Scratch      C:\Temp\scratch
Output ISO   [C:\Temp\tiny11core.iso] [Browse...]
Mode         Core
.NET 3.5     Disabled
[Build ISO]
```

The `Changes: N items applied` row is replaced with `Mode: Core` + `.NET 3.5: <Enabled|Disabled>`.

### 4.5 Output ISO default filename

`prefillOutputIfEmpty` extends:

```js
function prefillOutputIfEmpty() {
    if (state.outputPath || !state.scratchDir) return;
    const trimmed = state.scratchDir.replace(/[\\/]+$/, '');
    const sep = (trimmed.includes('/') && !trimmed.includes('\\')) ? '/' : '\\';
    const filename = state.coreMode ? 'tiny11core.iso' : 'tiny11.iso';
    state.outputPath = trimmed + sep + filename;
}
```

Re-fires on `coreMode` toggle (clears + re-prefills) only when `outputPath` matches the previous default — never overrides a user-typed value.

### 4.6 Build-progress panel (Core mode)

Standard build-progress UI (`renderProgress`) shows progress bar + Phase + Step + Cancel + collapsible build-details.

When `state.coreMode === true`, the build-details panel includes a cleanup-command block:

```
[Show build details]
  Edition       Windows 11 Pro (index 6)
  Build mode    Core
  Output ISO    C:\Temp\tiny11core.iso

  ⚠ If you cancel during the WinSxS wipe phase, the scratch
    directory is left in a non-resumable state (locked NTFS
    permissions + half-populated WinSxS_edit + dangling DISM
    mount). To clean up, run these in an elevated PowerShell
    prompt before starting another build:

  ┌──────────────────────────────────────────────────────────────────────┐
  │ dism /unmount-image /mountdir:"C:\Temp\scratch\mount" /discard       │
  │ dism /cleanup-mountpoints                                            │
  │ takeown /F "C:\Temp\scratch\mount" /R /D Y                           │
  │ icacls "C:\Temp\scratch\mount" /grant Administrators:F /T /C         │
  │ Remove-Item -Path "C:\Temp\scratch\mount" -Recurse -Force `
  │   -ErrorAction SilentlyContinue                                      │
  │ Remove-Item -Path "C:\Temp\scratch\source" -Recurse -Force `
  │   -ErrorAction SilentlyContinue                                      │
  └──────────────────────────────────────────────────────────────────────┘
```

`<scratch>` paths are interpolated from `state.scratchDir` at render time. Rendered in a `<pre class="cleanup-cmd">` so the user can `Ctrl+A → Ctrl+C` to copy all six lines at once.

CSS for `.cleanup-cmd`:

```css
.cleanup-cmd {
    background: var(--bg-input);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: var(--gap);
    font-family: 'Cascadia Code', 'Consolas', monospace;
    font-size: 12px;
    overflow-x: auto;
    white-space: pre;
}
```

### 4.7 Build-failed screen (Core mode)

The current build-failed screen (rendered by the `build-error` handler in `ui/app.js`) is a simple `"Build failed: <message>"` heading with a Close button. When `state.coreMode === true`, the same screen also includes the cleanup-command block.

```
Build failed
Build cancelled by user.

⚠ The Core build was interrupted mid-WinSxS-wipe. The scratch
  directory is left in a non-resumable state. To clean up, run
  these in an elevated PowerShell prompt before starting another
  build:

┌──────────────────────────────────────────────────────────────────────┐
│ dism /unmount-image /mountdir:"C:\Temp\scratch\mount" /discard       │
│ dism /cleanup-mountpoints                                            │
│ takeown /F "C:\Temp\scratch\mount" /R /D Y                           │
│ icacls "C:\Temp\scratch\mount" /grant Administrators:F /T /C         │
│ Remove-Item -Path "C:\Temp\scratch\mount" -Recurse -Force `
│   -ErrorAction SilentlyContinue                                      │
│ Remove-Item -Path "C:\Temp\scratch\source" -Recurse -Force `
│   -ErrorAction SilentlyContinue                                      │
└──────────────────────────────────────────────────────────────────────┘

[Close]
```

Reuses the same `renderCoreCleanupBlock()` helper that the build-progress panel uses — single source of truth for the command sequence + path interpolation. JS implementation:

```js
// In the existing build-error onPs handler
} else if (msg.type === 'build-error') {
    state.building = false;
    const root = document.getElementById('content');
    clear(root);
    const children = [
        el('h2', null, 'Build failed'),
        el('p', null, p.message || 'Unknown error'),
    ];
    if (state.coreMode && state.scratchDir) {
        children.push(renderCoreCleanupBlock());  // same helper as build-details panel
    }
    children.push(el('button', { onclick: () => ps({ type: 'close', payload: {} }) }, 'Close'));
    root.appendChild(el('section', { class: 'error' }, ...children));
}
```

The cleanup block renders only when `state.coreMode === true` AND `state.scratchDir` is set (defensive — can't render commands without the path). Non-Core build failures keep the existing two-line shape (no cleanup needed since no destructive WinSxS wipe occurred).

### 4.8 Why both placements

The build-progress panel surfaces the cleanup block PROACTIVELY — visible while the user is deciding whether to click Cancel, so the recovery cost is in front of them before they commit. The build-failed screen surfaces the same block REACTIVELY — visible after a cancel or error has already happened, when the user is staring at the failure and asking "now what?". Most users will see one or the other depending on their workflow:

- User who opens build-details proactively → catches it during the build
- User who watches the progress bar without expanding details → catches it on the failure screen
- User whose build errors out non-cancel (e.g. .NET 3.5 source missing, WinSxS keep-list mismatch) → catches it on the failure screen

Both placements share the `renderCoreCleanupBlock()` helper, so updating the command sequence happens in one place.

### 4.9 Scratch directory layout (locks down for cleanup-command path interpolation)

`tiny11Coremaker-from-config.ps1` creates two subdirs inside the user's `-ScratchDir`:

- `<scratchDir>\source` — copied Win11 ISO contents (boot/, efi/, sources/install.wim)
- `<scratchDir>\mount` — DISM mount point for install.wim

These match Coremaker's `$mainOSDrive\tiny11` and `$mainOSDrive\scratchdir` respectively, but parameterized to the user's scratch root. Locking this layout lets the cleanup-command UI render exact paths without runtime introspection.

---

## 5. Bridge contract

`start-build` payload gains two fields:

```json
{
  "type": "start-build",
  "payload": {
    "source": "...",
    "edition": 1,
    "scratchDir": "...",
    "outputIso": "...",
    "unmountSource": true,
    "fastBuild": false,
    "selections": { ... },
    "coreMode": true,
    "enableNet35": false
  }
}
```

`fastBuild` and `selections` are still sent (JS doesn't strip them from state when `coreMode=true`), but `BuildHandlers.HandleAsync` does NOT pass them to `tiny11Coremaker-from-config.ps1`. Only `source`, `imageIndex`/`edition`, `scratchDir`, `outputIso`, `unmountSource`, `enableNet35` reach the Core wrapper.

`BuildHandlers` script-path branching:

```csharp
var coreMode = payload?["coreMode"]?.GetValue<bool>() ?? false;
var script = Path.Combine(_resourcesDir,
    coreMode ? "tiny11Coremaker-from-config.ps1" : "tiny11maker-from-config.ps1");
```

---

## 6. Build pipeline phases

`Invoke-Tiny11CoreBuildPipeline` orchestrates 24 phases, emitting `build-progress` markers at each boundary.

| # | phase | step examples | %  | reuse |
|---|---|---|---|---|
| 1 | `preflight` | "Mounting source for edition enumeration" | 0 | `Tiny11.Iso` |
| 2 | `preflight` | "Copying Windows image to scratch" | 5 | `Copy-Item` |
| 3 | `preflight` | "Mounting install.wim for offline edit" | 10 | DISM `/mount-image` |
| 4 | `appx-removal` | "Removing provisioned app: <name>" (×32 prefixes) | 15-20 | `Tiny11.Actions.ProvisionedAppx` |
| 5 | `system-package-removal` | "Removing package: <pattern>" (×12 patterns) | 20-25 | NEW — `Invoke-Tiny11CoreSystemPackageRemoval` |
| 6 | `net35-enable` | "Enabling .NET 3.5 from offline source" | 25-30 | NEW — `Invoke-Tiny11CoreNet35Enable` (skipped when `-EnableNet35:$false`) |
| 7 | `filesystem-removal` | "Removing Edge/OneDrive/WinRE/WebView" | 30-35 | `Tiny11.Actions.Filesystem` |
| 8 | `winsxs-wipe` | "Taking ownership of WinSxS / Copying retained subdirs / Deleting WinSxS / Renaming WinSxS_edit" | 35-65 | NEW — `Invoke-Tiny11CoreWinSxsWipe` |
| 9 | `registry-load` | "Loading hives" | 65-67 | `Tiny11.Hives.Mount-Tiny11Hive` ×5 |
| 10 | `registry-bypass` | "Applying system-requirement bypass keys" | 67-70 | `Tiny11.Actions.Registry` from `Get-Tiny11CoreRegistryTweaks` filtered to `category='bypass'` |
| 11 | `registry-sponsored-apps` | "Disabling sponsored apps + ContentDeliveryManager" | 70-72 | same, `category='sponsored-apps'` |
| 12 | `registry-telemetry` | "Disabling telemetry" | 72-74 | same, `category='telemetry'` |
| 13 | `registry-defender-disable` | "Disabling Windows Defender services" | 74-76 | same, `category='defender-disable'` |
| 14 | `registry-update-disable` | "Disabling Windows Update" | 76-78 | same, `category='update-disable'` |
| 15 | `registry-misc` | "BitLocker, Chat, Copilot, Teams, Outlook, Reserved Storage" | 78-80 | same, `category='misc'` |
| 16 | `registry-unload` | "Unloading hives" | 80-82 | `Tiny11.Hives.Dismount-Tiny11Hive` ×5 |
| 17 | `scheduled-task-cleanup` | "Removing 5 scheduled tasks" | 82-83 | `Tiny11.Actions.ScheduledTask` |
| 18 | `cleanup-image` | "DISM Cleanup-Image / StartComponentCleanup / ResetBase" | 83-85 | NEW — direct DISM invocation |
| 19 | `unmount-install` | "Unmounting install.wim with /commit" | 85-87 | DISM `/unmount-image /commit` |
| 20 | `export-install` | "Exporting install.wim with /Compress:max" | 87-92 | NEW — `Invoke-Tiny11CoreImageExport -Compress max` |
| 21 | `boot-wim` | "Mounting boot.wim index 2 / Applying bypass-sysreqs / Unmounting" | 92-94 | DISM `/mount-image` + hive ops + DISM `/unmount-image` |
| 22 | `export-install-esd` | "Exporting install.esd with /Compress:recovery" | 94-97 | NEW — `Invoke-Tiny11CoreImageExport -Compress recovery` |
| 23 | `iso-create` | "Creating bootable ISO with oscdimg" | 97-99 | existing oscdimg path from `Tiny11.Worker` |
| 24 | `complete` | (emits `build-complete` not `build-progress`) | 100 | — |

Notes:

- Percent values are time-spent estimates, not literal accuracy. UI users expect monotonic forward progress, which is preserved.
- Phase 6 (`net35-enable`) is conditionally skipped — when skipped, phase 7 starts at 25% directly; no gap-jumping that would look weird.
- Registry tweaks from `Get-Tiny11CoreRegistryTweaks` are categorized so the phase taxonomy stays informative across the ~3-5 minute registry-edit window.
- `cancel-build` works at every phase boundary — `Process.Kill(entireProcessTree)` semantics, kernel-level termination.

---

## 7. Error handling

### 7.1 Resource cleanup pattern

Every operation that mounts or loads state uses try/finally. Mirrors the existing `tiny11maker-from-config.ps1` pattern.

```powershell
$preflightMount = Mount-Tiny11Source -InputPath $Source
try { ... } finally { Dismount-Tiny11Source -ForceUnmount:$true ... }

# install.wim mount
& dism /mount-image ...
try {
    Invoke-Tiny11CoreBuildPipeline ...
    $pipelineSucceeded = $true
} finally {
    & dism /unmount-image $(if ($pipelineSucceeded) { '/commit' } else { '/discard' }) ...
}

# hive load (×5 hives)
foreach ($hive in @('zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM')) {
    Mount-Tiny11Hive -Hive $hive -ScratchDir $scratchDir
}
try { ... }
finally {
    foreach ($hive in @('zSYSTEM','zSOFTWARE','zNTUSER','zDEFAULT','zCOMPONENTS')) {
        Dismount-Tiny11Hive -Hive $hive -ErrorAction SilentlyContinue
    }
}

# boot.wim mount (later phase)
& dism /mount-image $bootWim ...
try { ... } finally { & dism /unmount-image /commit }
```

### 7.2 Subprocess-level error path

```powershell
try {
    Invoke-Tiny11CoreBuildPipeline ...
    Write-Marker 'build-complete' @{ outputPath = $OutputIso }
    exit 0
} catch {
    Write-Marker 'build-error' @{ message = $_.Exception.Message; stackTrace = $_.ScriptStackTrace }
    exit 1
}
```

`build-error` marker goes to STDOUT (BuildHandlers' forwarder is STDOUT-only — established pattern from `81f8880`).

### 7.3 Specific failure modes

| failure | handling |
|---|---|
| Source ISO doesn't mount | `Mount-Tiny11Source` throws → wrapper catch → `build-error` to JS |
| Edition resolution fails | `Resolve-Tiny11ImageIndex` throws "Unknown edition: X. Known editions: …" → `build-error` |
| install.wim mount fails | DISM exit code != 0 → wrapper checks `$LASTEXITCODE` → throws → `build-error` |
| Single appx package not found | logged, **non-fatal** — many of 32 packages may be conditionally present |
| Single system package pattern matches zero | logged, **non-fatal** — some packages may have been removed by language drift |
| `.NET 3.5 enable fails (sources\sxs missing)` | **fatal but recoverable** — throws "`.NET 3.5 source not found at <path>. Verify your Windows 11 ISO includes sources\sxs.` Either uncheck Enable .NET 3.5 in Step 1 and rebuild, or use a complete Win11 multi-edition ISO." → `build-error` |
| WinSxS `takeown` fails | throws → `build-error`; user manually clears scratch and retries |
| WinSxS keep-list zero matches across all patterns | throws "Architecture <X> WinSxS layout doesn't match expected — verify ISO is amd64 or arm64 Win11" → `build-error` |
| Hive load fails | throws → finally still attempts unload (silent) → `build-error` |
| `/Cleanup-Image /ResetBase` fails | fatal → `build-error`. Catch sets a flag so install.wim unmount uses `/discard` not `/commit`. |
| Image export fails | fatal → `build-error` |
| oscdimg.exe missing AND fallback download fails | fatal → `build-error` (3-tier acquisition reused from existing `Tiny11.Worker.psm1`) |
| User Cancel mid-WinSxS-wipe | `Process.Kill` → wrapper subprocess dies before catch → STDERR fallback in BuildHandlers fires `build-error {message: "Build cancelled by user."}`. Scratch dir remains in non-resumable state. **The pre-rendered cleanup command sequence in the build-details panel guides recovery.** |

### 7.4 No-catalog simplification

Core builds don't have a catalog or selections, so the entire reconcile / resolved-selections / runtimeDepsOn surface is absent. Failures unique to standard builds (catalog version mismatch, selection refers to unknown item, runtimeDepsOn cycle) cannot occur in Core mode — simpler error surface.

---

## 8. Testing

### 8.1 xUnit (`launcher/Tests/BuildHandlersTests.cs`)

Four new tests:

| test | assertion |
|---|---|
| `HandleAsync_RoutesToCoreScript_WhenCoreModeTrue` | payload `coreMode=true` → `Process.Start` invoked with args containing `tiny11Coremaker-from-config.ps1` |
| `HandleAsync_RoutesToStandardScript_WhenCoreModeFalse` | payload `coreMode=false` → args contain `tiny11maker-from-config.ps1` (existing behavior, regression-locked) |
| `HandleAsync_PassesEnableNet35_WhenCoreMode` | payload `{coreMode:true, enableNet35:true}` → args contain `-EnableNet35` |
| `HandleAsync_OmitsFastBuildAndSelections_WhenCoreMode` | payload `{coreMode:true, fastBuild:true, selections:{...}}` → args do NOT contain `-FastBuild` or `-ConfigPath` |

xUnit total after: **45** (was 41; +4).

### 8.2 Pester (`tests/Tiny11.Core.Tests.ps1`)

| Describe | tests | scope |
|---|---|---|
| `Get-Tiny11CoreAppxPrefixes` | 3 | array length, known entries, suffix wildcard convention |
| `Get-Tiny11CoreSystemPackagePatterns` | 3 | length, language-code substitution, non-templated pass-through |
| `Get-Tiny11CoreFilesystemTargets` | 2 | length, contains expected entries |
| `Get-Tiny11CoreScheduledTaskTargets` | 1 | 5 entries with expected paths |
| `Get-Tiny11CoreRegistryTweaks` | 5 | length, required fields, valid categories, bypass-sysreqs subset, defender-disable subset |
| `Get-Tiny11CoreWinSxsKeepList` | 3 | amd64 list, arm64 list, throws on unknown arch |
| `Invoke-Tiny11CoreWinSxsWipe` | 3 | mock-call ordering, arch-specific copy filtering, zero-keep-list-matches throws |
| `Invoke-Tiny11CoreSystemPackageRemoval` | 2 | mocked DISM calls per pattern match, non-fatal on zero matches |
| `Invoke-Tiny11CoreNet35Enable` | 3 | skipped when `-EnableNet35:$false`, invokes when true, throws when sxs missing |
| `Invoke-Tiny11CoreImageExport` | 2 | `-Compress max` arg flow, `-Compress recovery` arg flow |

Pester total after: **109** (was 85; +24 in new file).

`Invoke-Tiny11CoreBuildPipeline` (the orchestrator) is unit-untested — relies on Phase 7 smoke. 24-phase orchestration mocking is high-effort low-payoff, and the per-operation tests above already cover the Core-unique logic.

### 8.3 Test infrastructure pattern

Wrap external invocations (`& dism …`, `& takeown …`) in named module functions inside `Tiny11.Core.psm1`, mirroring the `Tiny11.Actions.Filesystem.psm1` precedent. Pester `Mock` then intercepts at the named-function level rather than at the `&` operator.

### 8.4 Drift test (`tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1`)

No new tests. Existing tests auto-pick-up new files via `Get-ChildItem` walks; the `$intentionallyNotEmbedded` exclusion list comment is updated:

```diff
 $script:intentionallyNotEmbedded = @(
-    'src\Tiny11.Bridge.psm1'
-    'src\Tiny11.WebView2.psm1'
-    'tiny11Coremaker.ps1'
+    'src\Tiny11.Bridge.psm1'         # legacy v0.1.0 per 2026-05-08 binding decision
+    'src\Tiny11.WebView2.psm1'       # same
+    'tiny11Coremaker.ps1'            # upstream original — kept as parity reference until Phase 7 smoke confirms wrapper. Deletion is a follow-up commit.
 )
```

Drift test count stays at 4.

### 8.5 Phase 7 manual smokes — Core tier

Five new smoke tiers extending the existing Phase 7 plan:

| # | smoke | what it verifies |
|---|---|---|
| **C1** | UI flow — toggle Core off/on/off | Checkbox toggles cleanly. Warning expands/collapses. .NET 3.5 checkbox appears/disappears. Fast-build row hides/restores. "Customize" breadcrumb pip dims/un-dims. Next from Step 1 with Core on jumps to Step 3. Back from Step 3 with Core on returns to Step 1. |
| **C2** | Core build end-to-end (real Win11 ISO, ~30-45 min) | Build completes. Output ISO < 50% the size of an equivalent standard tiny11 build from the same source. |
| **C3** | Core ISO install in Hyper-V Gen2 VM | ISO boots, Setup completes (with bypass), reaches desktop, no first-boot crashes. |
| **C4** | Core ISO non-serviceability check | Settings → Windows Update either hidden or service stopped. `dism /Add-Package` against a CU `.msu` fails. `lpksetup` (language pack installer) is absent. |
| **C5** | Cancel during destructive phase | Build, wait until phase enters `winsxs-wipe`. Open build-details panel, verify cleanup-command block is visible with correct path interpolation. Click Cancel. Verify build-failed screen renders with "Build cancelled by user." AND the same cleanup-command block (verifying both placements share the same renderer + paths stay correct). Run the cleanup commands in elevated PowerShell. Verify scratchdir is fully cleared. Verify next build attempt succeeds. |

C1 is runnable any time after the polish-bundle commit lands. C2-C5 are the Phase 7 release gate.

---

## 9. Out of scope

- **Customizing Core** (per-item toggles in a stripped-down Step 2) — Core is a fixed preset for v1.0.0. Customization is a v1.x feature.
- **Hybrid mode** (catalog-driven removals + WinSxS wipe) — possible v1.x feature; not v1.0.0.
- **Profile interaction with Core** — profiles store catalog selections, which Core doesn't have. Profile UI lives in Step 2 which is dimmed/skipped in Core mode; no additional handling needed.
- **Rollback / resumable WinSxS wipe** — upstream Coremaker doesn't atomicize this; we don't either. Cleanup-via-elevated-PowerShell guidance covers the user.
- **Localized warning copy** — string is hardcoded English. Localization is post-v1.x.
- **Estimated build time display** — Core takes ~30-45 min; a hint in Step 1 could improve UX but isn't blocking. Polish follow-up if user feedback warrants.
- **Output ISO size estimate** — Core ISO size depends on source ISO + which packages were present. Hardcoding a "Expected: ~3.5 GB" hint would mislead more than help. Skipped.

---

## 10. Implementation order

(Detailed plan to be produced by the writing-plans skill after this design is approved. High-level expected ordering:)

1. `src/Tiny11.Core.psm1` — data accessors first (Get-* functions; pure data, easy Pester coverage)
2. `tests/Tiny11.Core.Tests.ps1` — Pester tests for accessors
3. `Tiny11.Core.psm1` — operation orchestrators (Invoke-* functions; mock-tested)
4. `tests/Tiny11.Core.Tests.ps1` — Pester tests for orchestrators
5. `Tiny11.Core.psm1` — `Invoke-Tiny11CoreBuildPipeline` (composes the above)
6. `tiny11Coremaker-from-config.ps1` — wrapper script
7. `launcher/tiny11options.Launcher.csproj` — `<EmbeddedResource>` entries for new `.psm1` + `.ps1`
8. `launcher/Gui/Handlers/BuildHandlers.cs` — script-path branching
9. `launcher/Tests/BuildHandlersTests.cs` — 4 new xUnit tests
10. `ui/app.js` + `ui/style.css` — state additions (`coreMode`, `enableNet35`); `renderSourceStep` extension (Core checkbox + warning + .NET 3.5 conditional); breadcrumb pip dim CSS; `renderBuildStep` Core-mode summary; `renderProgress` build-details cleanup-cmd block; `build-error` handler cleanup-cmd block; shared `renderCoreCleanupBlock()` helper
11. CHANGELOG / README / drift-test exclusion comment updates
12. Manual smoke C1 (UI flow), then C2-C5 in Phase 7

Total estimated wall time from spec approval to commit-ready: **~5-6 hours of code** + **Phase 7 smoke** (user-driven, ~1 hour for C2 build alone given source-ISO scale).

---

## 11. Open questions

None. All design decisions captured in §2.

---

## 12. References

- Upstream: `ntdevlabs/tiny11builder` `tiny11Coremaker.ps1` (BETA 09-05-25)
- Existing wrapper precedent: `tiny11maker-from-config.ps1`
- Existing module precedents: `Tiny11.Iso`, `Tiny11.Hives`, `Tiny11.Actions.*`
- Binding decision context: 2026-05-08 (legacy v0.1.0 PS modules retained as canonical reference)
- Cache invalidation precedent: 2026-05-09 commit `9806500` (content-aware ui-cache hashing eliminates manual `Remove-Item ui-cache` from dev workflow)
