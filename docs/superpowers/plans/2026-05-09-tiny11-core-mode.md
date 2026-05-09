# tiny11 Core Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "tiny11 Core" build mode (smaller, non-serviceable Win11 image) to the launcher as an alternative to the standard tiny11 build, ported from upstream `tiny11Coremaker.ps1` into our existing module architecture.

**Architecture:** New `src/Tiny11.Core.psm1` module + `tiny11Coremaker-from-config.ps1` wrapper. Reuses `Tiny11.Iso`, `Tiny11.Hives`, `Tiny11.Actions.*`. Step 1 gets a Core checkbox (with inline warning + .NET 3.5 sub-checkbox); when checked, Step 2 dims and is skipped, fast-build hides, and BuildHandlers routes to the Core wrapper. Cancel during destructive WinSxS-wipe phase surfaces an elevated-PowerShell cleanup-command block in both build-progress and build-failed UIs via a shared `renderCoreCleanupBlock()` helper.

**Tech Stack:** PowerShell 5.1+ modules (Pester 5.x), C# 12 / .NET 10 WPF launcher (xUnit + Moq), WebView2-hosted JS UI (vanilla DOM), MSBuild csproj `<EmbeddedResource>` entries.

**Spec:** [docs/superpowers/specs/2026-05-09-tiny11-core-mode-design.md](../specs/2026-05-09-tiny11-core-mode-design.md)

**Branch:** `feat/path-c-launcher` (continues v1.0.0 development; same branch as recent polish + drift commits)

---

## Source-of-truth pre-read — MANDATORY for every porting task

**Why this section exists:** Path C Phase 3 was implemented by parallel agents writing against the abstract plan without reading `tiny11maker.ps1:186-end` (the legacy v0.1.0 polished inline handlers). That cost ~6 hours of audit-and-fix work in May 2026 to reconcile the drift. The lesson — *"Rewrites must list legacy file:line ranges; parallel-agent prompts embed them verbatim"* — is captured in `feedback_legacy_port_section.md` and is now a hard requirement for this plan.

**Rule for every subagent / implementer of a porting task in this plan:** before writing any code, you MUST open `tiny11Coremaker.ps1` (or whatever source-of-truth is cited at the top of the task) and read the cited line ranges. Then implement. The inlined data in the task is convenience, NOT replacement for the upstream reference. Subtle behaviors that the inline data may miss include:

- Exact argument order (dism / takeown / icacls accept args positionally + by switch — order can matter)
- The literal "Y" answer to takeown's confirmation prompt (`/D Y`)
- Edge cases in DISM `/Get-Packages` output parsing (skip header line, whitespace splits)
- Architectural subtleties (e.g., the upstream amd64 keep-list has a duplicate entry that we de-dupe via `Select-Object -Unique` — see Task 5)
- Hidden state changes (some upstream Write-Host messages double as state markers; ignoring them is fine but verify nothing else read them)
- Error/control flow (does upstream throw, write-host and continue, or silently skip on a given failure mode?)

**Required Step 0 in every porting task:**

> - [ ] **Step 0: Read upstream source-of-truth** — open `tiny11Coremaker.ps1` lines `<X-Y>` (cited at task top); read the actual upstream code; note any behaviors not captured in this plan's inlined data and flag them BEFORE writing the implementation. If you find a discrepancy between upstream and the plan's inline data, STOP and surface it — do not silently choose either side.

**For subagent-driven execution specifically:** when the lead dispatches a task to a subagent, the subagent's prompt MUST include the cited file:line ranges verbatim (per `feedback_legacy_port_section.md`). The lead reads the subagent's report and verifies the subagent actually performed Step 0 (e.g., quotes a line from upstream in their report) before approving the next task.

Tasks that do NOT port upstream behavior (Tasks 14, 15, 22-25 — config / docs / smoke) skip Step 0 since there's no upstream to read.

---

## Pre-flight

Before starting Task 1, confirm working state:

- [ ] Working directory: `C:\Users\jscha\source\repos\tiny11options`
- [ ] On branch `feat/path-c-launcher`, working tree clean (`git status --short` returns nothing)
- [ ] `dotnet build ./launcher/tiny11options.Launcher.csproj` clean: 0 warnings, 0 errors
- [ ] `dotnet test ./launcher/Tests/tiny11options.Launcher.Tests.csproj`: 41/41 green
- [ ] `Invoke-Pester -Path tests/`: 85/85 green

If any of these fail, stop and fix before proceeding.

---

## Task 1: Module scaffolding + Get-Tiny11CoreAppxPrefixes

**Files:**
- Create: `src/Tiny11.Core.psm1`
- Create: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` line 119 (the `$packagePrefixes` array literal).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read line 119 in full. The array contains 31 comma-separated string literals on a single physical line. Verify the count, the trailing-`_` convention (most entries end with `_` for prefix-match against DISM output, but `Microsoft.Windows.Copilot` is the documented exception with no trailing `_`). Note any cases the inline data below may have transcribed wrong.

- [ ] **Step 1: Write the failing test**

`tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Get-Tiny11CoreAppxPrefixes' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'returns 31 hardcoded provisioned-appx package prefixes' {
        $prefixes = Get-Tiny11CoreAppxPrefixes
        $prefixes.Count | Should -Be 31
    }

    It 'contains known consumer-app entries' {
        $prefixes = Get-Tiny11CoreAppxPrefixes
        $prefixes | Should -Contain 'Microsoft.BingNews_'
        $prefixes | Should -Contain 'Microsoft.BingWeather_'
        $prefixes | Should -Contain 'Microsoft.YourPhone_'
        $prefixes | Should -Contain 'Microsoft.ZuneMusic_'
    }

    It 'contains current-Win11 cruft (Copilot, Teams, Outlook)' {
        $prefixes = Get-Tiny11CoreAppxPrefixes
        $prefixes | Should -Contain 'Microsoft.Copilot_'
        $prefixes | Should -Contain 'MSTeams_'
        $prefixes | Should -Contain 'Microsoft.OutlookForWindows_'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: discovery error or "Get-Tiny11CoreAppxPrefixes is not recognized" — file doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

`src/Tiny11.Core.psm1`:

```powershell
# tiny11 Core build mode — data accessors + operation orchestrators.
# Backs tiny11Coremaker-from-config.ps1 (the launcher's Core build wrapper).
#
# Reuses these existing modules where operations overlap with the standard
# tiny11 build: Tiny11.Iso (mount/dismount), Tiny11.Hives (load/unload),
# Tiny11.Actions.{Registry,Filesystem,ProvisionedAppx,ScheduledTask}.
# Core-unique operations (WinSxS wipe, /Remove-Package loop, .NET 3.5
# enable, Compress:max + Compress:recovery export sequence) live here.
#
# Spec: docs/superpowers/specs/2026-05-09-tiny11-core-mode-design.md

Set-StrictMode -Version Latest

# Hardcoded provisioned-appx package prefixes that Core removes from every
# build. List ported verbatim from upstream tiny11Coremaker.ps1 line 119.
# Each entry is a wildcard-prefix used by DISM /Remove-ProvisionedAppxPackage
# match logic — most end with "_" (the appx-package-name version separator).
function Get-Tiny11CoreAppxPrefixes {
    @(
        'Clipchamp.Clipchamp_'
        'Microsoft.BingNews_'
        'Microsoft.BingWeather_'
        'Microsoft.GamingApp_'
        'Microsoft.GetHelp_'
        'Microsoft.Getstarted_'
        'Microsoft.MicrosoftOfficeHub_'
        'Microsoft.MicrosoftSolitaireCollection_'
        'Microsoft.People_'
        'Microsoft.PowerAutomateDesktop_'
        'Microsoft.Todos_'
        'Microsoft.WindowsAlarms_'
        'microsoft.windowscommunicationsapps_'
        'Microsoft.WindowsFeedbackHub_'
        'Microsoft.WindowsMaps_'
        'Microsoft.WindowsSoundRecorder_'
        'Microsoft.Xbox.TCUI_'
        'Microsoft.XboxGamingOverlay_'
        'Microsoft.XboxGameOverlay_'
        'Microsoft.XboxSpeechToTextOverlay_'
        'Microsoft.YourPhone_'
        'Microsoft.ZuneMusic_'
        'Microsoft.ZuneVideo_'
        'MicrosoftCorporationII.MicrosoftFamily_'
        'MicrosoftCorporationII.QuickAssist_'
        'MicrosoftTeams_'
        'Microsoft.549981C3F5F10_'
        'Microsoft.Windows.Copilot'
        'MSTeams_'
        'Microsoft.OutlookForWindows_'
        'Microsoft.Windows.Teams_'
        'Microsoft.Copilot_'
    )
}

Export-ModuleMember -Function Get-Tiny11CoreAppxPrefixes
```

- [ ] **Step 4: Run tests to verify they pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): scaffold Tiny11.Core module + Get-Tiny11CoreAppxPrefixes"
```

---

## Task 2: Get-Tiny11CoreSystemPackagePatterns

**Files:**
- Modify: `src/Tiny11.Core.psm1` (append function + export)
- Modify: `tests/Tiny11.Core.Tests.ps1` (append Describe block)

**Source-of-truth:** `tiny11Coremaker.ps1` lines 135-149 (the `$packagePatterns` array assignment).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 135-149. Note: 4 of the 12 entries embed `$languageCode` as a runtime substitution — those are the LanguageFeatures-{Handwriting,OCR,Speech,TextToSpeech} entries. Our function takes `-LanguageCode` as a parameter and uses string interpolation (`"...-$LanguageCode-..."`) to produce the same effect. Verify the inline data below matches upstream entry-for-entry.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Get-Tiny11CoreSystemPackagePatterns' {
    It 'returns 12 entries for any language code' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'en-US'
        $patterns.Count | Should -Be 12
    }

    It 'substitutes language code into LanguageFeatures templates' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'en-US'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-Handwriting-en-US-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-OCR-en-US-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-Speech-en-US-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-TextToSpeech-en-US-Package~31bf3856ad364e35'
    }

    It 'substitutes a different language code correctly' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'de-DE'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-Handwriting-de-DE-Package~31bf3856ad364e35'
        $patterns | Should -Not -Contain 'Microsoft-Windows-LanguageFeatures-Handwriting-en-US-Package~31bf3856ad364e35'
    }

    It 'passes through non-templated entries unchanged' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'en-US'
        $patterns | Should -Contain 'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Windows-Defender-Client-Package~31bf3856ad364e35~'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 4 new tests fail with "Get-Tiny11CoreSystemPackagePatterns is not recognized."

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1` (above `Export-ModuleMember`):

```powershell
# DISM /Remove-Package patterns for Core's aggressive system-package removal.
# 12 entries; 4 are language-code-templated (LanguageFeatures-* family).
# Ported from upstream tiny11Coremaker.ps1 lines 135-149.
function Get-Tiny11CoreSystemPackagePatterns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LanguageCode
    )
    @(
        'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35'
        'Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64'
        "Microsoft-Windows-LanguageFeatures-Handwriting-$LanguageCode-Package~31bf3856ad364e35"
        "Microsoft-Windows-LanguageFeatures-OCR-$LanguageCode-Package~31bf3856ad364e35"
        "Microsoft-Windows-LanguageFeatures-Speech-$LanguageCode-Package~31bf3856ad364e35"
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$LanguageCode-Package~31bf3856ad364e35"
        'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35'
        'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35'
        'Windows-Defender-Client-Package~31bf3856ad364e35~'
        'Microsoft-Windows-WordPad-FoD-Package~'
        'Microsoft-Windows-TabletPCMath-Package~'
        'Microsoft-Windows-StepsRecorder-Package~'
    )
}
```

Update `Export-ModuleMember` line:

```powershell
Export-ModuleMember -Function Get-Tiny11CoreAppxPrefixes, Get-Tiny11CoreSystemPackagePatterns
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 7 tests passed (3 from Task 1 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Get-Tiny11CoreSystemPackagePatterns with -LanguageCode templating"
```

---

## Task 3: Get-Tiny11CoreFilesystemTargets

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 183-220 (Edge / WebView / OneDrive / WinRE removal block).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 183-220. Note that upstream handles WinRE.wim differently (replaces with empty file rather than deleting — see lines 213-216), and the WebView WinSxS dir is architecture-specific (lines 187-208). Our `Get-Tiny11CoreFilesystemTargets` covers ONLY the simple takeown+rm targets — WinRE replacement and WinSxS WebView dir are handled by `Invoke-Tiny11CoreBuildPipeline` and `Invoke-Tiny11CoreWinSxsWipe` separately. Confirm the 5 entries in our inline list match the simple-rm subset of upstream's behavior.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Get-Tiny11CoreFilesystemTargets' {
    It 'returns 5 filesystem deletion targets' {
        $targets = Get-Tiny11CoreFilesystemTargets
        $targets.Count | Should -Be 5
    }

    It 'includes Edge, EdgeUpdate, EdgeCore, OneDriveSetup, Microsoft-Edge-Webview' {
        $targets = Get-Tiny11CoreFilesystemTargets
        $rels = $targets | ForEach-Object { $_.RelPath }
        $rels | Should -Contain 'Program Files (x86)\Microsoft\Edge'
        $rels | Should -Contain 'Program Files (x86)\Microsoft\EdgeUpdate'
        $rels | Should -Contain 'Program Files (x86)\Microsoft\EdgeCore'
        $rels | Should -Contain 'Windows\System32\OneDriveSetup.exe'
        $rels | Should -Contain 'Windows\System32\Microsoft-Edge-Webview'
    }

    It 'every target has RelPath and Recurse fields' {
        $targets = Get-Tiny11CoreFilesystemTargets
        foreach ($t in $targets) {
            $t.PSObject.Properties.Name | Should -Contain 'RelPath'
            $t.PSObject.Properties.Name | Should -Contain 'Recurse'
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 new tests fail.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1`:

```powershell
# Filesystem paths Core deletes (relative to mounted scratchdir root).
# Each entry has RelPath (relative path from scratchdir) and Recurse
# (whether to recurse into directories — false for single-file targets).
# Ported from upstream tiny11Coremaker.ps1 lines 183-220.
# WinSxS architecture-specific WebView dir is handled separately by
# Invoke-Tiny11CoreWinSxsWipe (it's part of the WinSxS phase).
# WinRE.wim replacement is handled separately (delete+recreate empty file).
function Get-Tiny11CoreFilesystemTargets {
    @(
        [pscustomobject]@{ RelPath = 'Program Files (x86)\Microsoft\Edge';        Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Program Files (x86)\Microsoft\EdgeUpdate';  Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Program Files (x86)\Microsoft\EdgeCore';    Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Windows\System32\OneDriveSetup.exe';        Recurse = $false }
        [pscustomobject]@{ RelPath = 'Windows\System32\Microsoft-Edge-Webview';   Recurse = $true  }
    )
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 10 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Get-Tiny11CoreFilesystemTargets — Edge/OneDrive/WebView paths"
```

---

## Task 4: Get-Tiny11CoreScheduledTaskTargets

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 422-438 (scheduled-task delete block).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 422-438. Note that the CEIP entry (line 428) uses `-Recurse -Force` because it's a folder, while the others are single files using just `-Force`. Our `Recurse` field on the CEIP target captures this. Verify all 5 entries in inline data match upstream paths exactly (paths include exact spaces and capitalizations — Windows scheduled task names are case-insensitive but our path strings should be byte-identical to upstream for review clarity).

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Get-Tiny11CoreScheduledTaskTargets' {
    It 'returns 5 scheduled-task deletion targets' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $targets.Count | Should -Be 5
    }

    It 'includes Compatibility Appraiser, CEIP, ProgramDataUpdater, Chkdsk Proxy, QueueReporting' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $rels = $targets | ForEach-Object { $_.RelPath }
        $rels | Should -Contain 'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        $rels | Should -Contain 'Microsoft\Windows\Customer Experience Improvement Program'
        $rels | Should -Contain 'Microsoft\Windows\Application Experience\ProgramDataUpdater'
        $rels | Should -Contain 'Microsoft\Windows\Chkdsk\Proxy'
        $rels | Should -Contain 'Microsoft\Windows\Windows Error Reporting\QueueReporting'
    }

    It 'CEIP entry is marked as a folder (recurse-delete the entire folder)' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $ceip = $targets | Where-Object RelPath -eq 'Microsoft\Windows\Customer Experience Improvement Program'
        $ceip.Recurse | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 new tests fail.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1`:

```powershell
# Scheduled-task XML files Core deletes from the mounted image.
# Paths relative to <scratchdir>\Windows\System32\Tasks\.
# Ported from upstream tiny11Coremaker.ps1 lines 422-438.
function Get-Tiny11CoreScheduledTaskTargets {
    @(
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'; Recurse = $false }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Customer Experience Improvement Program';                    Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Application Experience\ProgramDataUpdater';                  Recurse = $false }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Chkdsk\Proxy';                                                Recurse = $false }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Windows Error Reporting\QueueReporting';                     Recurse = $false }
    )
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 13 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Get-Tiny11CoreScheduledTaskTargets"
```

---

## Task 5: Get-Tiny11CoreWinSxsKeepList

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 235-316 (the `$dirsToCopy` arrays for amd64 and arm64).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 235-316 in full. Two architecture-specific arrays: amd64 starts at line 236, arm64 starts at line 280-282. **Critical detail:** the upstream amd64 list has a duplicate entry at lines 267-268 (`x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*` appears twice). Our function de-dupes via `Select-Object -Unique`. **Also note:** the arm64 array literal at lines 282-316 uses an unusual mix of comma-separated and newline-separated entries (lines 284-291 have NO commas — they're separate statements that PowerShell tolerates but is non-idiomatic). Our inline data normalizes this to a clean array with explicit commas.

If the line counts in your reading differ from the test expectations (29 amd64, 28 arm64), STOP and reconcile — either the test count is wrong or the inline list is missing entries.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Get-Tiny11CoreWinSxsKeepList' {
    It 'returns the amd64 keep-list (29 entries) when -Architecture amd64' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'amd64'
        $list.Count | Should -Be 29
    }

    It 'returns the arm64 keep-list (28 entries) when -Architecture arm64' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'arm64'
        $list.Count | Should -Be 28
    }

    It 'amd64 list contains servicingstack and Manifests' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'amd64'
        $list | Should -Contain 'amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
        $list | Should -Contain 'Manifests'
    }

    It 'arm64 list contains arm64-specific servicingstack' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'arm64'
        $list | Should -Contain 'arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
    }

    It 'throws on unknown architecture with helpful message' {
        { Get-Tiny11CoreWinSxsKeepList -Architecture 'mips' } |
            Should -Throw -ExpectedMessage '*architecture*mips*'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 5 new tests fail.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1`:

```powershell
# WinSxS subdirs preserved during Core's destructive WinSxS wipe.
# Per architecture: amd64 (29 entries) or arm64 (28 entries).
# Patterns are Get-ChildItem -Filter wildcards — most end in `_*` to match
# version-suffixed dirs. Non-wildcarded entries (Catalogs, Manifests, etc.)
# are exact directory names that exist verbatim under WinSxS.
# Ported from upstream tiny11Coremaker.ps1 lines 235-316.
function Get-Tiny11CoreWinSxsKeepList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('amd64', 'arm64')]
        [string]$Architecture
    )

    if ($Architecture -eq 'amd64') {
        return @(
            'x86_microsoft.windows.common-controls_6595b64144ccf1df_*'
            'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*'
            'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
            'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
            'x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*'
            'x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*'
            'x86_microsoft-windows-servicingstack_31bf3856ad364e35_*'
            'x86_microsoft-windows-servicingstack-inetsrv_*'
            'x86_microsoft-windows-servicingstack-onecore_*'
            'amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
            'amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
            'amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
            'amd64_microsoft.windows.common-controls_6595b64144ccf1df_*'
            'amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*'
            'amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
            'amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
            'amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*'
            'amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*'
            'amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*'
            'amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
            'amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*'
            'amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*'
            'amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*'
            'Catalogs'
            'FileMaps'
            'Fusion'
            'InstallTemp'
            'Manifests'
            'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
            'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
            'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
        ) | Select-Object -Unique  # de-dupe (upstream listed x86_microsoft.windows.c..-controls.resources twice)
    }

    if ($Architecture -eq 'arm64') {
        return @(
            'arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*'
            'Catalogs'
            'FileMaps'
            'Fusion'
            'InstallTemp'
            'Manifests'
            'SettingsManifests'
            'Temp'
            'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
            'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
            'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
            'x86_microsoft.windows.common-controls_6595b64144ccf1df_*'
            'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*'
            'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
            'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
            'arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
            'arm_microsoft.windows.common-controls_6595b64144ccf1df_*'
            'arm_microsoft.windows.gdiplus_6595b64144ccf1df_*'
            'arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
            'arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
            'arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
            'arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
            'arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
            'arm64_microsoft.windows.common-controls_6595b64144ccf1df_*'
            'arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*'
            'arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
            'arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
            'arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*'
            'arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*'
            'arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*'
            'arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
            'arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*'
            'arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*'
        )
    }

    throw "Unknown architecture: $Architecture. Expected 'amd64' or 'arm64'."
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 18 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Get-Tiny11CoreWinSxsKeepList per architecture"
```

---

## Task 6: Get-Tiny11CoreRegistryTweaks (large data port)

This is the biggest data accessor — ~60 registry operations across 6 categories.

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 340-470 (install.wim hive edits) + 503-514 (boot.wim bypass-sysreqs subset, which we DO NOT include in the install.wim tweaks list — those are applied separately by the boot-wim phase in Task 12 using the same bypass-sysreqs subset).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 340-470 carefully. Categorize each `& 'reg' 'add' ...` or `& 'reg' 'delete' ...` line into one of: bypass-sysreqs (lines ~340-350), sponsored-apps (~351-380), local-account-OOBE / reserved-storage / bitlocker / chat (~381-390 — these go in `misc`), edge-uninstall / onedrive-backup (~391-395 — `misc`), telemetry (~396-406), DevHome/Outlook prevent (~407-411 — `misc`), Copilot/Teams/Outlook prevent (~412-419 — `misc`), update-disable (~440-456), defender-disable (~457-470).

**Critical to verify:** every `& 'reg' add` or `& 'reg' delete` upstream line maps to exactly one inline entry. If you find an upstream `reg` invocation that doesn't appear in the inline data below, flag it. If you find an inline entry that doesn't appear upstream, flag it. The expected count is 60+ entries; if your count differs by more than ±2, STOP and reconcile entry-by-entry.

Also note: lines 384-388 have a `Copy-Item ... autounattend.xml ... Sysprep` step. This is filesystem, NOT registry — DO NOT include it in the tweaks data. It belongs in `Tiny11.Autounattend.psm1` infrastructure (already exists) and gets called separately by `Invoke-Tiny11CoreBuildPipeline` if needed. The Core mode design defers autounattend handling to the same path the standard build uses.

Verify lines 503-514 (boot.wim bypass-sysreqs subset, plus the `Setup\CmdLine X:\sources\setup.exe` extra at line 514) — these are applied to the boot.wim during phase 21 in Task 12, not as part of the install.wim tweaks here. The boot-wim phase RE-USES the bypass-sysreqs category from this same data array (filtered by `Where-Object Category -eq 'bypass-sysreqs'`) plus one additional CmdLine entry inlined in Task 12's orchestrator code.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Get-Tiny11CoreRegistryTweaks' {
    BeforeAll {
        $script:tweaks = Get-Tiny11CoreRegistryTweaks
    }

    It 'returns at least 60 entries' {
        $script:tweaks.Count | Should -BeGreaterOrEqual 60
    }

    It 'every entry has Category, Op, Hive, Path fields' {
        foreach ($t in $script:tweaks) {
            $t.PSObject.Properties.Name | Should -Contain 'Category'
            $t.PSObject.Properties.Name | Should -Contain 'Op'
            $t.PSObject.Properties.Name | Should -Contain 'Hive'
            $t.PSObject.Properties.Name | Should -Contain 'Path'
        }
    }

    It 'every entry has a known category' {
        $known = @('bypass-sysreqs', 'sponsored-apps', 'telemetry', 'defender-disable', 'update-disable', 'misc')
        foreach ($t in $script:tweaks) {
            $known | Should -Contain $t.Category
        }
    }

    It 'every entry has a known op' {
        $known = @('add', 'delete')
        foreach ($t in $script:tweaks) {
            $known | Should -Contain $t.Op
        }
    }

    It 'bypass-sysreqs category contains BypassTPMCheck, BypassSecureBootCheck, BypassRAMCheck' {
        $bypass = $script:tweaks | Where-Object Category -eq 'bypass-sysreqs'
        $bypass | Where-Object { $_.Name -eq 'BypassTPMCheck' } | Should -Not -BeNullOrEmpty
        $bypass | Where-Object { $_.Name -eq 'BypassSecureBootCheck' } | Should -Not -BeNullOrEmpty
        $bypass | Where-Object { $_.Name -eq 'BypassRAMCheck' } | Should -Not -BeNullOrEmpty
    }

    It 'defender-disable category contains all 5 services with Start=4' {
        $defender = $script:tweaks | Where-Object Category -eq 'defender-disable'
        $services = @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'Sense')
        foreach ($svc in $services) {
            $entry = $defender | Where-Object { $_.Path -like "*Services\$svc" -and $_.Name -eq 'Start' }
            $entry | Should -Not -BeNullOrEmpty -Because "$svc service Start=4 entry expected"
            $entry.Value | Should -Be 4
        }
    }

    It 'add ops have Type and Value fields; delete ops do not require Value' {
        $adds = $script:tweaks | Where-Object Op -eq 'add'
        foreach ($a in $adds) {
            $a.PSObject.Properties.Name | Should -Contain 'Type'
            $a.PSObject.Properties.Name | Should -Contain 'Value'
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 7 new tests fail with "Get-Tiny11CoreRegistryTweaks is not recognized."

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1`:

```powershell
# Registry operations applied to the offline-mounted hives during a Core
# build. ~60 entries across 6 categories matching the build pipeline phases:
# bypass-sysreqs, sponsored-apps, telemetry, defender-disable,
# update-disable, misc.
#
# Schema: each entry is a hashtable with these fields:
#   Category : phase-tag for filtering (one of the 6 known values)
#   Op       : 'add' (REG ADD) or 'delete' (REG DELETE)
#   Hive     : hive prefix used in offline mount (e.g. 'zSOFTWARE')
#   Path     : registry path under the hive
#   Name     : value name (omit for delete-key ops on whole subkey)
#   Type     : REG_DWORD / REG_SZ etc. (add ops only)
#   Value    : the value to set (add ops only)
#
# Consumed by the registry-* phases in Invoke-Tiny11CoreBuildPipeline,
# which filters by Category and dispatches each entry to
# Tiny11.Actions.Registry.Invoke-RegistryAction.
#
# Ported from upstream tiny11Coremaker.ps1 lines 340-470 (install.wim hive
# edits) + 503-514 (boot.wim bypass-sysreqs subset, applied separately).
function Get-Tiny11CoreRegistryTweaks {
    @(
        # bypass-sysreqs (7 entries) — install.wim
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zDEFAULT'; Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV1'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zDEFAULT'; Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV2'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zNTUSER';  Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV1'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zNTUSER';  Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV2'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassCPUCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassRAMCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassSecureBootCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassStorageCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassTPMCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\MoSetup'; Name='AllowUpgradesWithUnsupportedTPMOrCPU'; Type='REG_DWORD'; Value=1 }

        # sponsored-apps (~20 entries — ContentDeliveryManager + CloudContent + PolicyManager)
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='OemPreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='ContentDeliveryAllowed'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\PolicyManager\current\device\Start'; Name='ConfigureStartPins'; Type='REG_SZ'; Value='{"pinnedList": [{}]}' }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='FeatureManagementEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='OemPreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEverEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SoftLandingEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContentEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-310093Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338388Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338389Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338393Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-353694Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-353696Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SystemPaneSuggestionsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\PushToInstall'; Name='DisablePushToInstall'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\MRT'; Name='DontOfferThroughWUAU'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='delete'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' }
        [pscustomobject]@{ Category='sponsored-apps'; Op='delete'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableConsumerAccountStateContent'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableCloudOptimizedContent'; Type='REG_DWORD'; Value=1 }

        # telemetry (~10 entries)
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name='HasAccepted'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Input\TIPC'; Name='Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitInkCollection'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitTextCollection'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\InputPersonalization\TrainedDataStore'; Name='HarvestContacts'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Personalization\Settings'; Name='AcceptedPrivacyPolicy'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zSYSTEM';  Path='ControlSet001\Services\dmwappushservice'; Name='Start'; Type='REG_DWORD'; Value=4 }

        # defender-disable (5 entries, one per service)
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WinDefend'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WdNisSvc'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WdNisDrv'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WdFilter'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\Sense'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name='SettingsPageVisibility'; Type='REG_SZ'; Value='hide:virus;windowsupdate' }

        # update-disable (~12 entries — RunOnce post-OOBE + service Start=4 + WaaS deletion)
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='StopWUPostOOBE1'; Type='REG_SZ'; Value='net stop wuauserv' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='StopWUPostOOBE2'; Type='REG_SZ'; Value='sc stop wuauserv' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='StopWUPostOOBE3'; Type='REG_SZ'; Value='sc config wuauserv start= disabled' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='DisbaleWUPostOOBE1'; Type='REG_SZ'; Value='reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='DisbaleWUPostOOBE2'; Type='REG_SZ'; Value='reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='DoNotConnectToWindowsUpdateInternetLocations'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='DisableWindowsUpdateAccess'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='WUServer'; Type='REG_SZ'; Value='localhost' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='WUStatusServer'; Type='REG_SZ'; Value='localhost' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='UpdateServiceUrlAlternate'; Type='REG_SZ'; Value='localhost' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='UseWUServer'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\OOBE'; Name='DisableOnline'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSYSTEM';  Path='ControlSet001\Services\wuauserv'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='update-disable'; Op='delete'; Hive='zSYSTEM';  Path='ControlSet001\Services\WaaSMedicSVC' }
        [pscustomobject]@{ Category='update-disable'; Op='delete'; Hive='zSYSTEM';  Path='ControlSet001\Services\UsoSvc' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='NoAutoUpdate'; Type='REG_DWORD'; Value=1 }

        # misc (BypassNRO, Reserved Storage, BitLocker, Chat, Edge uninstall, OneDrive backup, DevHome/Outlook, Copilot, Teams, Outlook)
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\OOBE'; Name='BypassNRO'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\ReserveManager'; Name='ShippedWithReserves'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSYSTEM';   Path='ControlSet001\Control\BitLocker'; Name='PreventDeviceEncryption'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\Windows Chat'; Name='ChatIcon'; Type='REG_DWORD'; Value=3 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zNTUSER';   Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarMn'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update' }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\OneDrive'; Name='DisableFileSyncNGSC'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'; Name='workCompleted'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'; Name='workCompleted'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Edge'; Name='HubsSidebarEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\Explorer'; Name='DisableSearchBoxSuggestions'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Teams'; Name='DisableInstallation'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\Windows Mail'; Name='PreventRun'; Type='REG_DWORD'; Value=1 }
    )
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 25 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Get-Tiny11CoreRegistryTweaks (~60 ops, 6 categories)"
```

---

## Checkpoint A — after Task 6

Confirm before continuing to Task 7:

- [ ] `Invoke-Pester -Path tests/`: 110/110 (was 85; +25 from Tiny11.Core)
- [ ] `git log --oneline -6` shows 6 distinct `feat(core):` commits
- [ ] `Get-Module Tiny11.Core | Format-List ExportedFunctions` shows 6 exported `Get-*` functions

---

## Task 7: External-command wrapper functions (testability shims)

`Tiny11.Core.psm1` will invoke `dism.exe`, `takeown.exe`, `icacls.exe` directly during the operation orchestrators. Wrapping each in a named module function lets Pester's `Mock` intercept cleanly during unit tests (instead of fighting with the `&` call operator).

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` for the canonical args used to invoke each tool (e.g. lines 80, 113, 152, 164, 182, 209-210, 213-214, 218-219, 225-226, 480, 483, 485, 496, 522-523 invoke `dism`; lines 72, 187-191, 200-204, 209, 213, 218, 225 invoke `takeown`; lines 73, 187-191, 200-204, 210, 214, 219, 226 invoke `icacls`). The wrappers must accept the same arg shapes upstream uses so callers in Tasks 8-12 produce byte-identical command lines to upstream's behavior.

- [ ] **Step 0: Read upstream source-of-truth**

Sample at least 3 upstream invocations of each tool and confirm the arg patterns. For dism, the canonical pattern is `& 'dism' '/English' '/image:...' '/Operation:...' '/Param:value'` — the `/English` flag forces English output for parsing. For takeown, the pattern is `& 'takeown' '/F' '<path>' '/R' '/D' 'Y'` — the `/D Y` answers the prompt for inaccessible items. For icacls, the pattern is `& 'icacls' '<path>' '/grant' "$($adminGroup.Value):(F)" '/T' '/C'` — note the Administrators SID lookup; we simplify to `Administrators:F` since that's a well-known builtin name that resolves locale-independently.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'External-command wrapper shims' {
    InModuleScope 'Tiny11.Core' {
        It 'Invoke-CoreDism passes args to dism.exe and surfaces exit code' {
            Mock Start-CoreProcess { @{ ExitCode = 0; Output = 'mock dism output' } }
            $result = Invoke-CoreDism -Arguments @('/English', '/image:C:\mount', '/Get-WimInfo')
            Should -Invoke Start-CoreProcess -Exactly 1 -ParameterFilter {
                $FileName -eq 'dism.exe' -and
                $Arguments -contains '/English' -and
                $Arguments -contains '/image:C:\mount'
            }
            $result.ExitCode | Should -Be 0
        }

        It 'Invoke-CoreTakeown passes args to takeown.exe' {
            Mock Start-CoreProcess { @{ ExitCode = 0 } }
            Invoke-CoreTakeown -Path 'C:\some\dir' -Recurse
            Should -Invoke Start-CoreProcess -Exactly 1 -ParameterFilter {
                $FileName -eq 'takeown.exe' -and
                $Arguments -contains '/F' -and
                $Arguments -contains 'C:\some\dir' -and
                $Arguments -contains '/R' -and
                $Arguments -contains '/D' -and
                $Arguments -contains 'Y'
            }
        }

        It 'Invoke-CoreIcacls passes args to icacls.exe with grant Administrators:F' {
            Mock Start-CoreProcess { @{ ExitCode = 0 } }
            Invoke-CoreIcacls -Path 'C:\some\dir' -Recurse
            Should -Invoke Start-CoreProcess -Exactly 1 -ParameterFilter {
                $FileName -eq 'icacls.exe' -and
                $Arguments -contains 'C:\some\dir' -and
                $Arguments -contains '/grant' -and
                ($Arguments -join ' ') -match 'Administrators:F' -and
                $Arguments -contains '/T' -and
                $Arguments -contains '/C'
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 new tests fail with "Start-CoreProcess is not recognized" or similar.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1` (above `Export-ModuleMember`):

```powershell
# Internal helper: invoke an external .exe with controlled args, capture
# exit code + output. Wrapped as a named function so Pester `Mock` can
# intercept cleanly during unit tests (the `&` call operator is harder
# to mock reliably). Not exported.
function Start-CoreProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$Arguments = @()
    )
    $output = & $FileName @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output -join "`n"
    }
}

# Wrapper for dism.exe invocations (mounting, removing packages, exporting,
# cleanup, etc.). Returns @{ExitCode, Output}; callers check ExitCode and
# throw on non-zero with descriptive context.
function Invoke-CoreDism {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Start-CoreProcess -FileName 'dism.exe' -Arguments $Arguments
}

# Wrapper for takeown.exe — assigns Administrators ownership of $Path.
# /D Y answers the confirmation prompt for inaccessible directories.
function Invoke-CoreTakeown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )
    $args = @('/F', $Path)
    if ($Recurse) { $args += '/R' }
    $args += @('/D', 'Y')
    Start-CoreProcess -FileName 'takeown.exe' -Arguments $args
}

# Wrapper for icacls.exe — grants Administrators full control. /T recurses,
# /C continues on errors.
function Invoke-CoreIcacls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )
    $args = @($Path, '/grant', 'Administrators:F')
    if ($Recurse) { $args += @('/T', '/C') }
    Start-CoreProcess -FileName 'icacls.exe' -Arguments $args
}
```

(Note: these are internal helpers — do NOT add them to `Export-ModuleMember`. They're accessible inside the module via `InModuleScope` in tests.)

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 28 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): external-command wrapper shims for testability"
```

---

## Task 8: Invoke-Tiny11CoreSystemPackageRemoval

DISM `/Remove-Package` loop — for each pattern from `Get-Tiny11CoreSystemPackagePatterns`, enumerate matching installed packages and remove each one.

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 152-166 (the `Get-Packages` enumeration + per-pattern `Where-Object` filter + `Remove-Package` loop).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 152-166. Note the upstream parsing pattern: line 152 captures `dism /Get-Packages /Format:Table` output, line 153 splits on `\n` and skips the header (`Select-Object -Skip 1`), line 161 extracts the first whitespace-delimited token as the package identity. The `-like "$packagePattern*"` match on line 157 is what makes this prefix-matching. Verify our implementation captures all of these behaviors. The non-fatal-on-empty-match behavior (no `throw` if zero packages match a pattern) is implicit in upstream — there's no error check. Our Write-Verbose log preserves the same intent but adds traceability.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Invoke-Tiny11CoreSystemPackageRemoval' {
    InModuleScope 'Tiny11.Core' {
        It 'invokes dism /Get-Packages once and /Remove-Package once per matching package' {
            $script:dismCalls = @()
            Mock Invoke-CoreDism {
                $script:dismCalls += , @($Arguments)
                if ($Arguments -contains '/Get-Packages') {
                    return @{ ExitCode = 0; Output = "Package Identity : Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35~amd64~~10.0.22621.1" }
                }
                return @{ ExitCode = 0; Output = '' }
            }

            Invoke-Tiny11CoreSystemPackageRemoval `
                -ScratchDir 'C:\mount' `
                -Patterns @('Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35') `
                -LanguageCode 'en-US'

            # First call enumerates; second call removes the matching one
            $script:dismCalls.Count | Should -BeGreaterOrEqual 2
            ($script:dismCalls[0] -join ' ') | Should -Match '/Get-Packages'
            ($script:dismCalls[1] -join ' ') | Should -Match '/Remove-Package'
        }

        It 'is non-fatal when zero packages match a pattern' {
            Mock Invoke-CoreDism {
                if ($Arguments -contains '/Get-Packages') {
                    return @{ ExitCode = 0; Output = '' }   # no packages reported
                }
                return @{ ExitCode = 0; Output = '' }
            }

            { Invoke-Tiny11CoreSystemPackageRemoval `
                -ScratchDir 'C:\mount' `
                -Patterns @('Definitely-Does-Not-Exist-Package~') `
                -LanguageCode 'en-US' } | Should -Not -Throw
        }

        It 'is fatal when dism /Get-Packages itself fails' {
            Mock Invoke-CoreDism {
                if ($Arguments -contains '/Get-Packages') {
                    return @{ ExitCode = 50; Output = 'DISM error 50' }
                }
                return @{ ExitCode = 0; Output = '' }
            }

            { Invoke-Tiny11CoreSystemPackageRemoval `
                -ScratchDir 'C:\mount' `
                -Patterns @('foo') `
                -LanguageCode 'en-US' } | Should -Throw -ExpectedMessage '*Get-Packages*'
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 new tests fail.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1` (above `Export-ModuleMember`):

```powershell
# DISM /Remove-Package loop. Enumerates installed packages once, then
# removes any whose identity matches one of the supplied patterns
# (prefix-matched). Non-fatal on zero matches per pattern (a pattern
# matching nothing means the source ISO didn't include that component).
# Fatal if DISM /Get-Packages itself errors.
function Invoke-Tiny11CoreSystemPackageRemoval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string]$LanguageCode
    )

    $enumResult = Invoke-CoreDism -Arguments @('/English', "/image:$ScratchDir", '/Get-Packages', '/Format:Table')
    if ($enumResult.ExitCode -ne 0) {
        throw "dism /Get-Packages failed (exit $($enumResult.ExitCode)): $($enumResult.Output)"
    }

    # Extract package identities from the table output. Lines like:
    #   Microsoft-Windows-Foo-Package~31bf3856ad364e35~amd64~~10.0.22621.1   Installed   ...
    # First whitespace-delimited token on each row is the identity.
    $allIdentities = $enumResult.Output -split "`n" |
        Select-Object -Skip 1 |
        ForEach-Object { ($_ -split '\s+')[0] } |
        Where-Object { $_ -match 'Package~' }   # filter to package-identity-shaped lines

    foreach ($pattern in $Patterns) {
        $matches = $allIdentities | Where-Object { $_ -like "$pattern*" }
        if (-not $matches) {
            Write-Verbose "No matches for pattern: $pattern (non-fatal — package may be absent in this ISO version)"
            continue
        }
        foreach ($identity in $matches) {
            $removeResult = Invoke-CoreDism -Arguments @('/English', "/image:$ScratchDir", '/Remove-Package', "/PackageName:$identity")
            if ($removeResult.ExitCode -ne 0) {
                Write-Verbose "dism /Remove-Package $identity failed (exit $($removeResult.ExitCode)) — non-fatal, continuing"
            }
        }
    }
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks, `
    Invoke-Tiny11CoreSystemPackageRemoval
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 31 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Invoke-Tiny11CoreSystemPackageRemoval (DISM /Remove-Package loop)"
```

---

## Task 9: Invoke-Tiny11CoreNet35Enable

Conditional .NET 3.5 enable via DISM `/enable-feature /featurename:NetFX3 /All /source:<path>`.

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 168-181 (the .NET 3.5 prompt + `dism /enable-feature` invocation).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 168-181. Upstream's exact DISM invocation (line 173) is `& 'dism' "/image:$scratchDir" '/enable-feature' '/featurename:NetFX3' '/All' "/source:$($env:SystemDrive)\tiny11\sources\sxs"`. Our wrapper takes `-SourcePath` as a parameter (since our scratch layout is `<scratchDir>\source\sources\sxs` not `$env:SystemDrive\tiny11\sources\sxs`), but the DISM args are identical. Note our function adds the `/English` flag (unlike upstream) to keep output parsing locale-independent — verify this is fine since we don't parse the output anyway.

The "throw if sources\sxs is missing" failure mode is NEW in our implementation — upstream would fail at runtime with a DISM error. We surface it as a clearer, build-time error per spec §7.3. Verify this matches the user's expectation in spec §4.1 (.NET 3.5 checkbox copy mentions "Adds ~100 MB" — implies the source must exist).

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Invoke-Tiny11CoreNet35Enable' {
    InModuleScope 'Tiny11.Core' {
        It 'does not invoke DISM when -EnableNet35:$false' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }
            Mock Test-Path { $true }

            Invoke-Tiny11CoreNet35Enable -ScratchDir 'C:\mount' -SourcePath 'C:\source\sxs' -EnableNet35:$false

            Should -Invoke Invoke-CoreDism -Times 0
        }

        It 'invokes DISM /enable-feature /featurename:NetFX3 when -EnableNet35:$true and source exists' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }
            Mock Test-Path { $true }

            Invoke-Tiny11CoreNet35Enable -ScratchDir 'C:\mount' -SourcePath 'C:\source\sxs' -EnableNet35:$true

            Should -Invoke Invoke-CoreDism -Exactly 1 -ParameterFilter {
                ($Arguments -join ' ') -match '/enable-feature' -and
                ($Arguments -join ' ') -match '/featurename:NetFX3' -and
                ($Arguments -join ' ') -match '/All' -and
                ($Arguments -join ' ') -match '/source:C:\\source\\sxs'
            }
        }

        It 'throws when source path is missing' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }
            Mock Test-Path { $false }

            { Invoke-Tiny11CoreNet35Enable -ScratchDir 'C:\mount' -SourcePath 'C:\source\sxs' -EnableNet35:$true } |
                Should -Throw -ExpectedMessage '*sxs*'
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 new tests fail.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1`:

```powershell
# Enable .NET 3.5 in the offline image via DISM. Only invoked when the
# user checked the .NET 3.5 box in Step 1 (-EnableNet35:$true). Source
# path is the sources\sxs directory inside the copied ISO contents
# (typically <scratch>\source\sources\sxs). Throws if the sxs directory
# is missing — usually means the user's ISO doesn't bundle SxS payloads.
function Invoke-Tiny11CoreNet35Enable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][bool]$EnableNet35
    )

    if (-not $EnableNet35) {
        Write-Verbose '.NET 3.5 enable skipped (-EnableNet35:$false)'
        return
    }

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw ".NET 3.5 source not found at $SourcePath. Verify your Windows 11 ISO includes sources\sxs. Either uncheck Enable .NET 3.5 in Step 1 and rebuild, or use a complete Win11 multi-edition ISO."
    }

    $result = Invoke-CoreDism -Arguments @(
        '/English',
        "/image:$ScratchDir",
        '/enable-feature',
        '/featurename:NetFX3',
        '/All',
        "/source:$SourcePath"
    )
    if ($result.ExitCode -ne 0) {
        throw "DISM /enable-feature NetFX3 failed (exit $($result.ExitCode)): $($result.Output)"
    }
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks, `
    Invoke-Tiny11CoreSystemPackageRemoval, `
    Invoke-Tiny11CoreNet35Enable
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 34 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Invoke-Tiny11CoreNet35Enable (gated on -EnableNet35)"
```

---

## Task 10: Invoke-Tiny11CoreImageExport

DISM `/Export-Image` with `/Compress:max` or `/Compress:recovery`.

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 484-487 (install.wim → install2.wim with /Compress:max) and 525-527 (install.wim → install.esd with /Compress:recovery).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 484-487 (the first export, /Compress:max) and 525-527 (the second export, /Compress:recovery). Note that upstream's first export uses `/SourceIndex:$index` (the user-selected edition index, captured earlier), and the second export uses `/SourceIndex:1` (always index 1, because after the first export the WIM only has the one image). The caller in Task 12 will pass these index values explicitly. Our wrapper takes `-SourceIndex` as a parameter and doesn't second-guess the caller.

Also note: upstream's first export is followed by `Remove-Item ...install.wim` + `Rename-Item ...install2.wim → install.wim` (lines 486-487). This rename-after-export is part of the orchestrator pipeline (Task 12), not this wrapper. Confirm the wrapper does NOT perform any rename — it only invokes DISM.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Invoke-Tiny11CoreImageExport' {
    InModuleScope 'Tiny11.Core' {
        It 'invokes DISM /Export-Image with /Compress:max' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }

            Invoke-Tiny11CoreImageExport `
                -SourceImageFile 'C:\source\install.wim' `
                -DestinationImageFile 'C:\source\install2.wim' `
                -SourceIndex 6 `
                -Compress 'max'

            Should -Invoke Invoke-CoreDism -Exactly 1 -ParameterFilter {
                ($Arguments -join ' ') -match '/Export-Image' -and
                ($Arguments -join ' ') -match '/SourceImageFile:C:\\source\\install.wim' -and
                ($Arguments -join ' ') -match '/DestinationImageFile:C:\\source\\install2.wim' -and
                ($Arguments -join ' ') -match '/SourceIndex:6' -and
                ($Arguments -join ' ') -match '/Compress:max'
            }
        }

        It 'invokes DISM /Export-Image with /Compress:recovery' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }

            Invoke-Tiny11CoreImageExport `
                -SourceImageFile 'C:\source\install.wim' `
                -DestinationImageFile 'C:\source\install.esd' `
                -SourceIndex 1 `
                -Compress 'recovery'

            Should -Invoke Invoke-CoreDism -Exactly 1 -ParameterFilter {
                ($Arguments -join ' ') -match '/Compress:recovery'
            }
        }

        It 'throws on DISM exit code != 0' {
            Mock Invoke-CoreDism { @{ ExitCode = 5; Output = 'mock dism error' } }

            { Invoke-Tiny11CoreImageExport `
                -SourceImageFile 'C:\src.wim' `
                -DestinationImageFile 'C:\dest.wim' `
                -SourceIndex 1 `
                -Compress 'max' } | Should -Throw -ExpectedMessage '*Export-Image*'
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 new tests fail.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1`:

```powershell
# DISM /Export-Image wrapper. Used twice during a Core build:
#   1. install.wim -> install2.wim with /Compress:max (intermediate)
#   2. install2.wim (renamed install.wim) -> install.esd with /Compress:recovery (final)
# Throws on non-zero exit. Caller is responsible for the rename + cleanup.
function Invoke-Tiny11CoreImageExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceImageFile,
        [Parameter(Mandatory)][string]$DestinationImageFile,
        [Parameter(Mandatory)][int]$SourceIndex,
        [Parameter(Mandatory)][ValidateSet('max', 'recovery')][string]$Compress
    )

    $result = Invoke-CoreDism -Arguments @(
        '/English',
        '/Export-Image',
        "/SourceImageFile:$SourceImageFile",
        "/SourceIndex:$SourceIndex",
        "/DestinationImageFile:$DestinationImageFile",
        "/Compress:$Compress"
    )
    if ($result.ExitCode -ne 0) {
        throw "DISM /Export-Image $SourceImageFile -> $DestinationImageFile (Compress:$Compress) failed (exit $($result.ExitCode)): $($result.Output)"
    }
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks, `
    Invoke-Tiny11CoreSystemPackageRemoval, `
    Invoke-Tiny11CoreNet35Enable, `
    Invoke-Tiny11CoreImageExport
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 37 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Invoke-Tiny11CoreImageExport (max + recovery compression)"
```

---

## Task 11: Invoke-Tiny11CoreWinSxsWipe

The destructive WinSxS wipe sequence. takeown → copy retained subdirs → delete WinSxS → rename WinSxS_edit. ~10 minutes wall-time on a real ISO.

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 224-332 (the entire WinSxS wipe sequence — takeown, icacls, create _edit, copy keep-list dirs, delete WinSxS, rename _edit).

- [ ] **Step 0: Read upstream source-of-truth**

Open `tiny11Coremaker.ps1` and read lines 224-332 in full. The sequence to verify:

1. Lines 225-226: `takeown /f WinSxS /r` + `icacls WinSxS /grant Administrators:F /T /C` (recursive ownership transfer)
2. Lines 230-234: prepare `WinSxS_edit` directory + `New-Item -ItemType Directory`
3. Lines 235-279 (amd64) / 280-316 (arm64): the `$dirsToCopy` array literals
4. Lines 318-325 (amd64-only-loop AND a generic loop just below — note the structure split: the foreach at line 318 runs only inside the `if ($architecture -eq "amd64")` block (closes at 279); but a SECOND foreach at lines 318-325 outside that block also runs, ostensibly for the arm64 case but actually for whichever `$dirsToCopy` was last assigned. **This is a structural bug in upstream** — the arm64 list isn't iterated through its own foreach, it falls through to the same shared foreach at 318. Our implementation puts the foreach INSIDE each architecture branch's loop body, fixing the upstream bug. Verify our test correctly exercises the arm64 path.
5. Line 328-329: `Remove-Item WinSxS -Recurse -Force`
6. Line 331: `Rename-Item WinSxS_edit -NewName WinSxS`

If you read line 318 and the surrounding control flow and think the upstream behavior is intentional rather than a bug, STOP and surface that — our implementation differs in arm64 handling and that needs to be a deliberate decision.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Invoke-Tiny11CoreWinSxsWipe' {
    InModuleScope 'Tiny11.Core' {
        BeforeEach {
            $script:callOrder = @()
            Mock Invoke-CoreTakeown { $script:callOrder += "takeown:$Path"; @{ ExitCode = 0 } }
            Mock Invoke-CoreIcacls  { $script:callOrder += "icacls:$Path";  @{ ExitCode = 0 } }
            Mock Get-ChildItem {
                # Return at least one fake match per filter so loops don't trip the empty-keep-list throw
                @([pscustomobject]@{ Name = "$Filter-fake"; FullName = "$Path\$Filter-fake" })
            }
            Mock New-Item { }
            Mock Copy-Item { $script:callOrder += "copy:$Path->$Destination" }
            Mock Remove-Item { $script:callOrder += "remove:$Path" }
            Mock Rename-Item { $script:callOrder += "rename:$Path->$NewName" }
        }

        It 'orchestrates takeown -> copy retained -> delete WinSxS -> rename WinSxS_edit' {
            Invoke-Tiny11CoreWinSxsWipe -ScratchDir 'C:\mount' -Architecture 'amd64'

            # Sanity: takeown happens before the copy phase
            $script:callOrder[0] | Should -Match '^takeown:'
            # Find the deletion of WinSxS itself (not WinSxS_edit)
            $deleteIdx = ($script:callOrder | ForEach-Object { $i = 0 } { if ($_ -match 'remove:.*\\WinSxS$') { $i }; $i++ })
            # Rename happens after delete
            $renameIdx = ($script:callOrder | ForEach-Object { $i = 0 } { if ($_ -match 'rename:.*WinSxS_edit') { $i }; $i++ })
            ($script:callOrder -join '|') | Should -Match 'remove:.*\\WinSxS\|.*rename:.*WinSxS_edit'
        }

        It 'throws when zero keep-list patterns match (architecture mismatch)' {
            Mock Get-ChildItem { @() }   # nothing matches anywhere

            { Invoke-Tiny11CoreWinSxsWipe -ScratchDir 'C:\mount' -Architecture 'amd64' } |
                Should -Throw -ExpectedMessage '*WinSxS*amd64*'
        }

        It 'uses arm64 keep-list when -Architecture arm64' {
            $script:filterCalls = @()
            Mock Get-ChildItem {
                $script:filterCalls += $Filter
                @([pscustomobject]@{ Name = "$Filter-fake"; FullName = "$Path\$Filter-fake" })
            }

            Invoke-Tiny11CoreWinSxsWipe -ScratchDir 'C:\mount' -Architecture 'arm64'

            # arm64 list contains specific patterns that amd64 doesn't
            ($script:filterCalls -join '|') | Should -Match 'arm64_microsoft.vc80.crt'
            ($script:filterCalls -join '|') | Should -Not -Match '^amd64_'
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 3 new tests fail.

- [ ] **Step 3: Write the implementation**

Append to `src/Tiny11.Core.psm1`:

```powershell
# The destructive WinSxS wipe — Core's signature operation.
# Sequence:
#   1. takeown + icacls on <scratch>\Windows\WinSxS (recursive, ~5 min)
#   2. Create <scratch>\Windows\WinSxS_edit
#   3. For each pattern in the architecture-specific keep-list, copy
#      matching subdirs (or top-level dirs like Catalogs/Manifests) from
#      WinSxS into WinSxS_edit
#   4. Delete <scratch>\Windows\WinSxS recursively
#   5. Rename <scratch>\Windows\WinSxS_edit to WinSxS
#
# Failure modes:
#   - Zero patterns matched anywhere in WinSxS -> throw (architecture
#     mismatch or unexpected ISO layout; better to fail loudly than
#     produce a corrupted image)
#   - Mid-flight cancel -> non-resumable state; cleanup-command UI guides
#     user recovery (documented in build-progress + build-failed UIs)
function Invoke-Tiny11CoreWinSxsWipe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Architecture
    )

    $winSxs = Join-Path $ScratchDir 'Windows\WinSxS'
    $winSxsEdit = Join-Path $ScratchDir 'Windows\WinSxS_edit'
    $keepList = Get-Tiny11CoreWinSxsKeepList -Architecture $Architecture

    Write-Verbose "Taking ownership of $winSxs (recursive)..."
    Invoke-CoreTakeown -Path $winSxs -Recurse | Out-Null
    Invoke-CoreIcacls  -Path $winSxs -Recurse | Out-Null

    Write-Verbose "Creating $winSxsEdit..."
    New-Item -Path $winSxsEdit -ItemType Directory -Force | Out-Null

    $totalMatches = 0
    foreach ($pattern in $keepList) {
        $matches = Get-ChildItem -Path $winSxs -Filter $pattern -Directory -ErrorAction SilentlyContinue
        if (-not $matches) {
            Write-Verbose "Keep-list pattern '$pattern' matched zero entries (non-fatal per-pattern)"
            continue
        }
        foreach ($match in $matches) {
            $totalMatches++
            $dest = Join-Path $winSxsEdit $match.Name
            Copy-Item -Path $match.FullName -Destination $dest -Recurse -Force
        }
    }

    if ($totalMatches -eq 0) {
        throw "WinSxS wipe: zero keep-list patterns matched any subdirectory under $winSxs (Architecture=$Architecture). Source ISO may not be a $Architecture Win11 image, or its WinSxS layout differs from the expected layout."
    }

    Write-Verbose "Deleting original WinSxS..."
    Remove-Item -Path $winSxs -Recurse -Force

    Write-Verbose "Renaming WinSxS_edit -> WinSxS..."
    Rename-Item -Path $winSxsEdit -NewName 'WinSxS'
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks, `
    Invoke-Tiny11CoreSystemPackageRemoval, `
    Invoke-Tiny11CoreNet35Enable, `
    Invoke-Tiny11CoreImageExport, `
    Invoke-Tiny11CoreWinSxsWipe
```

- [ ] **Step 4: Run tests to verify all pass**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 40 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Invoke-Tiny11CoreWinSxsWipe (destructive selective preservation)"
```

---

## Checkpoint B — after Task 11

Confirm before continuing to Task 12:

- [ ] `Invoke-Pester -Path tests/`: 125/125 (was 110; +15 from new orchestrator tests)
- [ ] `Get-Module Tiny11.Core | Format-List ExportedFunctions` shows 6 `Get-*` + 4 `Invoke-*` (10 total)
- [ ] `git log --oneline -11 feat/path-c-launcher` shows 11 distinct `feat(core):` commits since Task 1

The remaining tasks (12-25) follow a similar TDD shape. Tasks 12-13 finish the Core PowerShell layer (orchestrator + wrapper script), Tasks 14-17 wire the C# launcher side, Tasks 18-22 implement the UI changes, Tasks 23-25 finish docs + smoke. Each task ships an independently committable + reviewable change.

The remaining tasks are documented in this same plan file in subsequent sections. Continue to Task 12 below.

---

## Task 12: Invoke-Tiny11CoreBuildPipeline orchestrator

The top-level orchestrator. Composes all Invoke-* functions plus calls to Tiny11.Iso, Tiny11.Hives, Tiny11.Actions.* into the 24-phase pipeline. **No unit test** per design spec §8.2 — relies on Phase 7 manual smoke for end-to-end verification.

**Files:**
- Modify: `src/Tiny11.Core.psm1`

**Source-of-truth:** `tiny11Coremaker.ps1` lines 27-571 (the entire main script body — every phase of our orchestrator maps to a contiguous range of upstream lines).

Phase-to-line map (read each range when implementing the corresponding phase):

| our phase | upstream lines | what to verify |
|---|---|---|
| preflight: copy + mount | 41-80 | source copy pattern, install.esd → install.wim conversion, takeown of wim, mount-image args |
| preflight: detect language + arch | 82-104 | `dism /Get-Intl` parse for `Default system UI language : <code>`, image-info parse for architecture (x64 → amd64 mapping) |
| appx-removal | 111-128 | `dism /Get-ProvisionedAppxPackages` parse + per-prefix removal loop |
| system-package-removal | 130-166 | already covered in Task 8 source-read; verify caller invokes once with patterns from `Get-Tiny11CoreSystemPackagePatterns -LanguageCode <detected>` |
| net35-enable | 168-181 | already covered in Task 9 source-read |
| filesystem-removal | 182-220 | Edge / OneDrive / WinRE / WebView paths — note WinRE replacement (lines 213-216) is a DELETE-then-CREATE-empty pattern, NOT a simple delete |
| winsxs-wipe | 222-332 | already covered in Task 11 source-read |
| registry-load + registry-* + registry-unload | 334-477 | hive load/edit/unload sequence; categorized tweaks via `Get-Tiny11CoreRegistryTweaks` |
| scheduled-task-cleanup | 420-438 | task XML path delete; note CEIP recurse vs others non-recurse |
| cleanup-image | 478-480 | `dism /Cleanup-Image /StartComponentCleanup /ResetBase` |
| unmount-install (commit) | 482-483 | `dism /unmount-image /commit` (or /discard on failure path) |
| export-install + rename | 484-488 | export with /Compress:max, delete original, rename `install2.wim` → `install.wim` |
| boot-wim | 491-523 | mount boot.wim index 2, takeown + icacls, hive load, bypass-sysreqs subset + the `Setup\CmdLine` extra at line 514, hive unload, unmount /commit |
| export-install-esd | 525-527 | export with /Compress:recovery, delete `install.wim` |
| iso-create | 529-559 | oscdimg invocation — REUSE existing `Tiny11.Worker.psm1` helper, do NOT reimplement |

- [ ] **Step 0: Read upstream source-of-truth**

This task spans the entire upstream main script. Read lines 27-571 in `tiny11Coremaker.ps1` end-to-end before writing any code. Use the phase-to-line map above as your reading order. While reading, validate each of these claims:

1. Does upstream's mount-image error path matter? (Spoiler: upstream doesn't error-handle it; we wrap in try/finally with /discard on failure.)
2. Are there any phases / steps in upstream that we DON'T capture in our 24-phase taxonomy? (e.g., the `$adminGroup` SID lookup at line 14, the `Start-Transcript` at line 27 — we deliberately skip both because the launcher's existing logging captures their output.)
3. Does upstream's `Read-Host "Press Enter to continue"` (line 563) need replicating? (No — we exit cleanly via `build-complete` marker; the pause is only for users running upstream interactively.)
4. Does upstream's cleanup at lines 564-566 (`Remove-Item -Path "$mainOSDrive\tiny11" -Recurse -Force`) apply to our scratch layout? (Conditionally — only if `-UnmountSource` is true and the scratch is auto-managed; the user's explicit `-ScratchDir` should NOT be auto-deleted by us.)

If you find any phase that requires upstream behavior we haven't captured, STOP and surface it before writing code. Adding the missed behavior is fine; silently dropping it (or silently inferring our own version) is exactly the failure mode this Step 0 exists to prevent.

- [ ] **Step 1: Write the implementation**

Append to `src/Tiny11.Core.psm1` (above `Export-ModuleMember`):

```powershell
# Top-level Core build orchestrator. Composes the 24 phases per spec §6.
# Emits build-progress markers to the supplied -ProgressCallback (the
# wrapper script wires this to Write-Marker JSON to STDOUT for the
# launcher's BuildHandlers forwarder).
#
# Reuses these existing modules: Tiny11.Iso (mount/dismount), Tiny11.Hives
# (load/unload), Tiny11.Actions.{ProvisionedAppx,Filesystem,Registry,
# ScheduledTask}. Core-unique work routes to the Invoke-Tiny11Core* helpers.
#
# NOT unit-tested — 24-phase orchestration mocking is high-effort low-payoff.
# End-to-end verification via Phase 7 manual smoke C2-C5.
function Invoke-Tiny11CoreBuildPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$OutputIso,
        [Parameter(Mandatory)][bool]$EnableNet35,
        [Parameter(Mandatory)][bool]$UnmountSource,
        [Parameter(Mandatory)][scriptblock]$ProgressCallback
    )

    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Iso.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Hives.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Actions.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Actions.Registry.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Actions.Filesystem.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Actions.ProvisionedAppx.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Actions.ScheduledTask.psm1') -Force

    $sourceDir = Join-Path $ScratchDir 'source'
    $mountDir  = Join-Path $ScratchDir 'mount'
    $sxsSourcePath = Join-Path $sourceDir 'sources\sxs'

    & $ProgressCallback @{ phase='preflight'; step='Copying Windows image to scratch'; percent=5 }
    New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
    Copy-Item -Path "$Source\*" -Destination $sourceDir -Recurse -Force

    & $ProgressCallback @{ phase='preflight'; step='Mounting install.wim for offline edit'; percent=10 }
    New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
    $installWim = Join-Path $sourceDir 'sources\install.wim'
    $mountResult = Invoke-CoreDism -Arguments @('/English', '/Mount-Image', "/ImageFile:$installWim", "/Index:$ImageIndex", "/MountDir:$mountDir")
    if ($mountResult.ExitCode -ne 0) { throw "DISM /Mount-Image failed: $($mountResult.Output)" }

    $pipelineSucceeded = $false
    try {
        # Detect language code from the mounted image (used by system-package patterns)
        $intl = Invoke-CoreDism -Arguments @('/English', "/Image:$mountDir", '/Get-Intl')
        $languageCode = 'en-US'
        if ($intl.Output -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})') {
            $languageCode = $Matches[1]
        }

        # Detect architecture
        $imageInfo = Invoke-CoreDism -Arguments @('/English', '/Get-WimInfo', "/wimFile:$installWim", "/index:$ImageIndex")
        $architecture = 'amd64'
        if ($imageInfo.Output -match 'Architecture : (\S+)') {
            $arch = $Matches[1]
            if ($arch -eq 'x64') { $architecture = 'amd64' }
            elseif ($arch -eq 'ARM64' -or $arch -eq 'arm64') { $architecture = 'arm64' }
            else { throw "Unsupported architecture: $arch (Core mode requires amd64 or arm64)" }
        }

        # Phase 4: appx-removal
        & $ProgressCallback @{ phase='appx-removal'; step="Removing $((Get-Tiny11CoreAppxPrefixes).Count) provisioned apps"; percent=15 }
        $appxPrefixes = Get-Tiny11CoreAppxPrefixes
        Invoke-ProvisionedAppxAction -ScratchDir $mountDir -PackagePrefixes $appxPrefixes

        # Phase 5: system-package-removal
        & $ProgressCallback @{ phase='system-package-removal'; step='Removing system packages (IE, MediaPlayer, Defender, etc.)'; percent=20 }
        $sysPatterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode $languageCode
        Invoke-Tiny11CoreSystemPackageRemoval -ScratchDir $mountDir -Patterns $sysPatterns -LanguageCode $languageCode

        # Phase 6: net35-enable (conditional)
        if ($EnableNet35) {
            & $ProgressCallback @{ phase='net35-enable'; step='Enabling .NET 3.5 from offline source'; percent=27 }
            Invoke-Tiny11CoreNet35Enable -ScratchDir $mountDir -SourcePath $sxsSourcePath -EnableNet35:$true
        }

        # Phase 7: filesystem-removal
        & $ProgressCallback @{ phase='filesystem-removal'; step='Removing Edge / OneDrive / WebView'; percent=32 }
        $fsTargets = Get-Tiny11CoreFilesystemTargets
        foreach ($t in $fsTargets) {
            $abs = Join-Path $mountDir $t.RelPath
            if (Test-Path -LiteralPath $abs) {
                Invoke-FilesystemAction -Op 'takeown-and-remove' -Path $abs
            }
        }

        # WinRE.wim — replace with empty file (allows boot.wim to still reference the path)
        $winreWim = Join-Path $mountDir 'Windows\System32\Recovery\winre.wim'
        if (Test-Path -LiteralPath $winreWim) {
            $recoveryDir = Join-Path $mountDir 'Windows\System32\Recovery'
            Invoke-CoreTakeown -Path $recoveryDir -Recurse | Out-Null
            Invoke-CoreIcacls  -Path $recoveryDir -Recurse | Out-Null
            Remove-Item -Path $winreWim -Force
            New-Item -Path $winreWim -ItemType File -Force | Out-Null
        }

        # Phase 8: winsxs-wipe (longest single phase, ~30% of time)
        & $ProgressCallback @{ phase='winsxs-wipe'; step='Taking ownership and wiping WinSxS (slowest phase, ~5-10 min)'; percent=35 }
        Invoke-Tiny11CoreWinSxsWipe -ScratchDir $mountDir -Architecture $architecture

        # Phase 9: registry-load
        & $ProgressCallback @{ phase='registry-load'; step='Loading hives'; percent=66 }
        foreach ($hive in @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM')) {
            Mount-Tiny11Hive -Hive $hive -ScratchDir $mountDir
        }

        try {
            $allTweaks = Get-Tiny11CoreRegistryTweaks
            $phaseMap = @{
                'bypass-sysreqs'   = @{ phase='registry-bypass';            step='Applying system-requirement bypass keys'; percent=68 }
                'sponsored-apps'   = @{ phase='registry-sponsored-apps';    step='Disabling sponsored apps + ContentDeliveryManager'; percent=71 }
                'telemetry'        = @{ phase='registry-telemetry';         step='Disabling telemetry'; percent=73 }
                'defender-disable' = @{ phase='registry-defender-disable';  step='Disabling Windows Defender services'; percent=75 }
                'update-disable'   = @{ phase='registry-update-disable';    step='Disabling Windows Update'; percent=77 }
                'misc'             = @{ phase='registry-misc';              step='BitLocker / Chat / Copilot / Teams / Outlook / etc.'; percent=79 }
            }
            foreach ($cat in @('bypass-sysreqs', 'sponsored-apps', 'telemetry', 'defender-disable', 'update-disable', 'misc')) {
                & $ProgressCallback $phaseMap[$cat]
                $catTweaks = $allTweaks | Where-Object Category -eq $cat
                foreach ($t in $catTweaks) {
                    Invoke-RegistryAction -Op $t.Op -Hive $t.Hive -Path $t.Path -Name $t.Name -Type $t.Type -Value $t.Value
                }
            }
        }
        finally {
            & $ProgressCallback @{ phase='registry-unload'; step='Unloading hives'; percent=81 }
            foreach ($hive in @('zSYSTEM', 'zSOFTWARE', 'zNTUSER', 'zDEFAULT', 'zCOMPONENTS')) {
                Dismount-Tiny11Hive -Hive $hive -ErrorAction SilentlyContinue
            }
        }

        # Phase 17: scheduled-task-cleanup
        & $ProgressCallback @{ phase='scheduled-task-cleanup'; step='Removing 5 scheduled task definitions'; percent=82 }
        $taskTargets = Get-Tiny11CoreScheduledTaskTargets
        foreach ($t in $taskTargets) {
            $abs = Join-Path $mountDir "Windows\System32\Tasks\$($t.RelPath)"
            if (Test-Path -LiteralPath $abs) {
                Invoke-FilesystemAction -Op 'remove' -Path $abs -Recurse:$t.Recurse
            }
        }

        # Phase 18: cleanup-image
        & $ProgressCallback @{ phase='cleanup-image'; step='DISM /Cleanup-Image /StartComponentCleanup /ResetBase'; percent=84 }
        $cleanResult = Invoke-CoreDism -Arguments @('/English', "/image:$mountDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
        if ($cleanResult.ExitCode -ne 0) { throw "DISM /Cleanup-Image failed: $($cleanResult.Output)" }

        $pipelineSucceeded = $true
    }
    finally {
        # Phase 19: unmount-install (commit on success, discard on failure)
        $unmountFlag = if ($pipelineSucceeded) { '/Commit' } else { '/Discard' }
        & $ProgressCallback @{ phase='unmount-install'; step="Unmounting install.wim with $unmountFlag"; percent=86 }
        Invoke-CoreDism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", $unmountFlag) | Out-Null
    }

    if (-not $pipelineSucceeded) {
        throw 'Core build pipeline failed mid-flight (see preceding error). install.wim unmounted with /Discard.'
    }

    # Phase 20: export-install with /Compress:max -> install2.wim, then rename install2.wim -> install.wim
    & $ProgressCallback @{ phase='export-install'; step='Exporting install.wim with /Compress:max'; percent=89 }
    $installWim2 = Join-Path $sourceDir 'sources\install2.wim'
    Invoke-Tiny11CoreImageExport -SourceImageFile $installWim -DestinationImageFile $installWim2 -SourceIndex $ImageIndex -Compress 'max'
    Remove-Item -Path $installWim -Force
    Rename-Item -Path $installWim2 -NewName 'install.wim'

    # Phase 21: boot-wim (mount index 2, apply bypass-sysreqs to setup image, unmount)
    & $ProgressCallback @{ phase='boot-wim'; step='Mounting boot.wim index 2 + applying bypass-sysreqs'; percent=93 }
    $bootWim = Join-Path $sourceDir 'sources\boot.wim'
    Invoke-CoreTakeown -Path $bootWim | Out-Null
    Invoke-CoreIcacls  -Path $bootWim | Out-Null
    Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    Invoke-CoreDism -Arguments @('/English', '/Mount-Image', "/ImageFile:$bootWim", '/Index:2', "/MountDir:$mountDir") | Out-Null
    try {
        foreach ($hive in @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM')) {
            Mount-Tiny11Hive -Hive $hive -ScratchDir $mountDir
        }
        try {
            # Apply only the bypass-sysreqs subset to the setup image
            $bootTweaks = Get-Tiny11CoreRegistryTweaks | Where-Object Category -eq 'bypass-sysreqs'
            foreach ($t in $bootTweaks) {
                Invoke-RegistryAction -Op $t.Op -Hive $t.Hive -Path $t.Path -Name $t.Name -Type $t.Type -Value $t.Value
            }
            # Plus the setup-image-only CmdLine override (ports tiny11Coremaker.ps1:514)
            Invoke-RegistryAction -Op 'add' -Hive 'zSYSTEM' -Path 'Setup' -Name 'CmdLine' -Type 'REG_SZ' -Value 'X:\sources\setup.exe'
        }
        finally {
            foreach ($hive in @('zSYSTEM', 'zSOFTWARE', 'zNTUSER', 'zDEFAULT', 'zCOMPONENTS')) {
                Dismount-Tiny11Hive -Hive $hive -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        Invoke-CoreDism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Commit') | Out-Null
    }

    # Phase 22: export-install-esd with /Compress:recovery, then delete the install.wim
    & $ProgressCallback @{ phase='export-install-esd'; step='Exporting install.esd with /Compress:recovery'; percent=96 }
    $installEsd = Join-Path $sourceDir 'sources\install.esd'
    Invoke-Tiny11CoreImageExport -SourceImageFile $installWim -DestinationImageFile $installEsd -SourceIndex 1 -Compress 'recovery'
    Remove-Item -Path $installWim -Force

    # Phase 23: iso-create — reuse Tiny11.Worker's oscdimg path
    & $ProgressCallback @{ phase='iso-create'; step='Creating bootable ISO with oscdimg'; percent=98 }
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Worker.psm1') -Force
    Invoke-OscdimgIsoCreate -SourceDir $sourceDir -OutputIso $OutputIso

    # Optional source-ISO unmount
    if ($UnmountSource) {
        Import-Module (Join-Path $PSScriptRoot 'Tiny11.Iso.psm1') -Force
        try { Dismount-DiskImage -ImagePath $Source -ErrorAction SilentlyContinue } catch { }
    }
}
```

> **Note for the implementer:** `Invoke-OscdimgIsoCreate` is the existing oscdimg invocation already present in `Tiny11.Worker.psm1`. If the function name doesn't match exactly, locate the equivalent helper in that module and adjust the call here. If no such helper exists yet (it's inlined elsewhere), extract it as a small refactor commit BEFORE this Task — keep the surface change focused.

- [ ] **Step 2: Verify the file compiles (Pester discovery)**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1 -Output None -PassThru | Format-List PassedCount, FailedCount
```

Expected: 40/40 unchanged (no new tests added; just verifying the new function loads without parse errors).

- [ ] **Step 3: Update Export-ModuleMember**

```powershell
Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks, `
    Invoke-Tiny11CoreSystemPackageRemoval, `
    Invoke-Tiny11CoreNet35Enable, `
    Invoke-Tiny11CoreImageExport, `
    Invoke-Tiny11CoreWinSxsWipe, `
    Invoke-Tiny11CoreBuildPipeline
```

- [ ] **Step 4: Re-run tests to confirm no regressions**

```
Invoke-Pester -Path tests/Tiny11.Core.Tests.ps1
```

Expected: 40 tests passed.

- [ ] **Step 5: Commit**

```bash
git add src/Tiny11.Core.psm1
git commit -m "feat(core): Invoke-Tiny11CoreBuildPipeline orchestrator (24 phases)"
```

---

## Tasks 13-25 — overview and remaining structure

The next tasks complete the feature. Each follows the same TDD shape as Tasks 1-11 (failing test → implement → passing test → commit) where applicable. Tasks marked **(no TDD)** are config / docs / smoke and have a verify-and-commit shape.

| # | task | files | shape |
|---|---|---|---|
| 13 | `tiny11Coremaker-from-config.ps1` wrapper script | new file at repo root | TDD via end-to-end script invocation test |
| 14 | csproj `<EmbeddedResource>` entries for new module + wrapper | `launcher/tiny11options.Launcher.csproj` | (no TDD) — verify drift test still green |
| 15 | Drift test exclusion comment update | `tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1` | (no TDD) — only the `$intentionallyNotEmbedded` rationale changes |
| 16 | BuildHandlers script-path branching + `coreMode` payload routing + `enableNet35` pass-through | `launcher/Gui/Handlers/BuildHandlers.cs`, `launcher/Tests/BuildHandlersTests.cs` | TDD with 4 new xUnit tests |
| 17 | UI: state additions + Step 1 Core checkbox + warning panel + .NET 3.5 conditional render | `ui/app.js`, `ui/style.css` | UI sub-task — manual verification via launcher |
| 18 | UI: fastBuild hide + breadcrumb pip dim CSS | `ui/style.css` | UI sub-task |
| 19 | UI: navigation routing (skip 'customize' when coreMode) | `ui/app.js` | UI sub-task |
| 20 | UI: Step 3 Core summary + output ISO filename default | `ui/app.js` | UI sub-task |
| 21 | UI: `renderCoreCleanupBlock()` helper | `ui/app.js`, `ui/style.css` | UI sub-task |
| 22 | UI: render cleanup block in build-progress + build-failed | `ui/app.js` | UI sub-task |
| 23 | CHANGELOG entry under [Unreleased] | `CHANGELOG.md` | (no TDD) |
| 24 | README "## Build modes" section | `README.md` | (no TDD) |
| 25 | Manual smoke C1 (UI flow) — instructional, not implementation | (no files modified) | (no TDD) — user-driven |

**Tasks 13-25 are intentionally outlined here rather than fully expanded** — the data-portion of the work (Tasks 1-12) is the bulk of the spec-to-code surface, and the remaining tasks each follow patterns already established in this codebase (csproj entries match existing style; UI changes match `renderSourceStep` / `renderProgress` patterns; CHANGELOG matches the previous polish-bundle entry shape; xUnit BuildHandlersTests match the existing test style).

When the implementer reaches Task 13, **expand each remaining task in-place using the same TDD/verify-and-commit shape as Tasks 1-12**, referencing the spec doc (§3-9) for exact behaviors. Do NOT skip the failing-test step for Tasks 13 and 16; the others (config / UI / docs / smoke) follow the verify-and-commit pattern.

**Source-of-truth pre-read still applies for Tasks 13, 16, 17-22:**

- **Task 13 (`tiny11Coremaker-from-config.ps1`):** read existing `tiny11maker-from-config.ps1` for the wrapper-script template (param block, Write-Marker helper, try/catch envelope). Do NOT reinvent — the Path C polish session already established this template and any divergence is suspect.
- **Task 16 (BuildHandlers C# routing):** read existing `launcher/Gui/Handlers/BuildHandlers.cs` for the script-path resolution, args-builder pattern, and the existing `coreMode=false` standard-build path (which must remain regression-locked). Read `launcher/Tests/BuildHandlersTests.cs` for the existing test style — the new tests must follow the same `Mock<...>` + reflection-into-private-method pattern the existing tests use.
- **Tasks 17-22 (UI changes):** read existing `ui/app.js` for `renderSourceStep`, `renderProgress`, `renderBuildStep`, `renderComplete`, the `el()` helper, the `state` object, and the `onPs` handler patterns. Match style precisely. Read `ui/style.css` for the existing class naming (`.row`, `.form`, `.error`, `.cleanup-cmd` already exists from spec section 4.6 — verify it does and re-use it; do NOT introduce duplicate class names).

For each of these tasks, the implementer should add their own Step 0 to read the cited existing-codebase files before writing code, following the same pattern as Tasks 1-11.

---

## Final checkpoint — after Task 25

Confirm the v1.0.0 Core mode feature is shipping-ready:

- [ ] `dotnet build ./launcher/tiny11options.Launcher.csproj` clean: 0 warnings, 0 errors
- [ ] `dotnet test ./launcher/Tests/tiny11options.Launcher.Tests.csproj`: 45/45 (was 41; +4 from BuildHandlers Core routing)
- [ ] `Invoke-Pester -Path tests/`: 109+/109+ (Pester +24 from Tiny11.Core; total depends on whether Task 13 wrapper-test counts)
- [ ] CHANGELOG `[Unreleased]` includes the new Core mode section
- [ ] README has the "## Build modes" section
- [ ] Manual smoke C1 (UI flow) verified by user
- [ ] Commit graph shows ~25 distinct commits since the spec landed at `938c4de`
- [ ] Branch tip pushed to origin

Phase 7 manual smokes C2-C5 are user-driven and follow the v1.0.0 release-readiness gate (after Phase 6 build pipeline lands).

---

## Self-review (executed during plan-writing)

**Spec coverage:** Every section of the spec maps to at least one task:

- §3.1 file layout → Tasks 1, 13, 14
- §3.2 Tiny11.Core.psm1 API → Tasks 1-12
- §3.3 wrapper script → Task 13
- §4.1-4.9 UI specification → Tasks 17-22
- §5 bridge contract → Task 16
- §6 build pipeline phases → Task 12
- §7 error handling → embedded throughout (Tasks 8-12)
- §8 testing → embedded (xUnit Task 16; Pester Tasks 1-11; drift Task 15)
- §9 out of scope → not in plan (correct)

**Placeholder scan:** No "TBD"/"TODO" inline. Tasks 13-25 are intentionally outlined rather than fully expanded — this is by design and is documented in the explanatory note. The plan flags this as a transition point so the implementer expands those tasks themselves rather than discovering a placeholder mid-execution.

**Type consistency:** Function names match across tasks (`Get-Tiny11CoreAppxPrefixes` consistent in Tasks 1, 12). Parameter names match (`-ScratchDir`, `-Architecture`, `-EnableNet35`). Bridge payload field names match the spec (`coreMode`, `enableNet35`). xUnit test names match xUnit naming convention.

**Scope check:** Tasks 1-12 are a single implementation sub-plan (Core PowerShell layer). Tasks 13-25 form the integration sub-plan. Both sub-plans are coherent within the same plan file. Total wall-time estimate ~5-6 hours per spec §10.

No fixes needed.

