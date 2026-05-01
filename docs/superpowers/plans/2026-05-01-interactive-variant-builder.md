# Interactive Variant Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `tiny11maker.ps1` from a 535-line linear script into a catalog-driven, GUI-equipped image builder that lets users select which Windows 11 components to strip — shipping as v1.0.0 of `bilbospocketses/tiny11options`.

**Architecture:** Catalog (`catalog/catalog.json`) drives both the WebView2-hosted WPF GUI and a `-Config <json>` scripted mode. PowerShell modules under `src/` factor concerns (catalog, action handlers, hives, ISO, autounattend, worker). The orchestrator script (`tiny11maker.ps1`) wires them together. Pester unit tests cover dispatch logic; manual VM smoke tests cover end-to-end builds.

**Tech Stack:** PowerShell 7+ (Windows-only), Pester 5.x for tests, WPF (XAML hosted from PS) + WebView2 SDK 1.0.x for the GUI, vanilla HTML/CSS/JS for the wizard (DOM-built — no `innerHTML` for user-controlled content), DISM/reg/oscdimg for the actual image work.

**Phase boundaries — each phase produces working, testable software:**

- **Phase 1 (Foundation):** scripted mode works end-to-end without GUI. Engineer can run `tiny11maker.ps1 -Source X.iso -Config tiny11-classic.json -ImageIndex 6` and produce a working tiny11 ISO. Brittleness items closed. Pester suite passes.
- **Phase 2 (GUI):** WebView2 wizard works. Engineer can run `tiny11maker.ps1` with no args, see the GUI, configure interactively, and produce the same ISO. Pester suite still passes.
- **Phase 3 (Polish + Release):** README rewritten, CHANGELOG `[1.0.0]` cut, drift tests in place, multiple profile smoke tests pass, version tagged.

**Spec reference:** `docs/superpowers/specs/2026-05-01-interactive-variant-builder-design.md`. Read it first if you're picking up this plan cold.

---

## File Structure

The refactor decomposes the linear `tiny11maker.ps1` into focused modules.

### Created files

```
tiny11maker.ps1                                # orchestrator — small wrapper that loads modules and dispatches to interactive vs scripted
src/
  Tiny11.Catalog.psm1                          # catalog JSON loader + schema validation
  Tiny11.Selections.psm1                       # selection model + reconcile (runtimeDepsOn locking)
  Tiny11.Hives.psm1                            # offline registry hive load/unload helpers
  Tiny11.Actions.ProvisionedAppx.psm1          # provisioned-appx action handler
  Tiny11.Actions.Filesystem.psm1               # filesystem action handler
  Tiny11.Actions.Registry.psm1                 # registry action handler
  Tiny11.Actions.ScheduledTask.psm1            # scheduled-task action handler
  Tiny11.Actions.psm1                          # action dispatcher (routes by type)
  Tiny11.Iso.psm1                              # mount/unmount/edition enumeration
  Tiny11.Autounattend.psm1                     # template acquisition (3-tier) + render
  Tiny11.Worker.psm1                           # build pipeline orchestrator
  Tiny11.WebView2.psm1                         # WebView2 SDK fetch + WPF window setup (Phase 2)
  Tiny11.Bridge.psm1                           # PS↔WebView message dispatch (Phase 2)

catalog/
  catalog.json                                 # source-of-truth catalog (~63 items)

config/
  examples/
    tiny11-classic.json                        # reproduces today's tiny11 behavior
    keep-edge.json                             # sample: keep Edge browser
    minimal-removal.json                       # sample: trim only ad apps + telemetry

ui/
  index.html                                   # wizard shell (Phase 2)
  style.css                                    # styling (Phase 2)
  app.js                                       # render + selection logic (Phase 2; DOM-built, no innerHTML for user data)

autounattend.template.xml                      # template with placeholders (replaces today's autounattend.xml)

tests/
  Tiny11.Catalog.Tests.ps1
  Tiny11.Selections.Tests.ps1
  Tiny11.Hives.Tests.ps1
  Tiny11.Actions.ProvisionedAppx.Tests.ps1
  Tiny11.Actions.Filesystem.Tests.ps1
  Tiny11.Actions.Registry.Tests.ps1
  Tiny11.Actions.ScheduledTask.Tests.ps1
  Tiny11.Actions.Tests.ps1
  Tiny11.Iso.Tests.ps1
  Tiny11.Autounattend.Tests.ps1
  Tiny11.Autounattend.Drift.Tests.ps1          # asserts embedded fallback equals file
  Tiny11.Worker.Tests.ps1
  Tiny11.WebView2.Tests.ps1
  Tiny11.Bridge.Tests.ps1
  Tiny11.Orchestrator.Tests.ps1
  Tiny11.PesterConfig.ps1
  Tiny11.TestHelpers.psm1
  Run-Tests.ps1
```

### Modified / deleted

- `tiny11maker.ps1` — fully rewritten as a thin orchestrator (~150 lines).
- `autounattend.xml` — DELETED. Replaced by `autounattend.template.xml`.
- `CHANGELOG.md` — `[Unreleased]` entries become `[1.0.0]` at release time (Task 27).
- `README.md` — rewritten in Phase 3 (Task 26).

---

# Phase 1: Foundation

End state: `tiny11maker.ps1 -Source X.iso -Config tiny11-classic.json -ImageIndex 6 -NonInteractive` produces a working tiny11 ISO. Brittleness items closed. All Pester tests pass. No GUI yet.

---

## Task 1: Project structure + Pester scaffolding

**Files:**
- Create: `src/.gitkeep`, `tests/.gitkeep`
- Create: `tests/Tiny11.PesterConfig.ps1`, `tests/Tiny11.TestHelpers.psm1`, `tests/Run-Tests.ps1`, `tests/Tiny11.Harness.Tests.ps1`
- Modify: `.gitattributes` (add `.psm1`/`.psd1` rules)

- [ ] **Step 1: Create directories**

```powershell
New-Item -ItemType Directory -Path src,tests -Force | Out-Null
New-Item -ItemType File -Path src/.gitkeep,tests/.gitkeep | Out-Null
```

- [ ] **Step 2: Add Pester config**

Create `tests/Tiny11.PesterConfig.ps1`:

```powershell
$config = New-PesterConfiguration
$config.Run.Path = (Resolve-Path "$PSScriptRoot").Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $false
$config.CodeCoverage.Enabled = $false
$config
```

- [ ] **Step 3: Add test helpers module**

Create `tests/Tiny11.TestHelpers.psm1`:

```powershell
function Import-Tiny11Module {
    param([Parameter(Mandatory)][string]$Name)
    $modulePath = "$PSScriptRoot/../src/$Name.psm1"
    if (-not (Test-Path $modulePath)) { throw "Module not found: $modulePath" }
    Import-Module $modulePath -Force -DisableNameChecking
}
function New-TempScratchDir {
    $tmp = Join-Path $env:TEMP "tiny11test-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $tmp
}
function Remove-TempScratchDir {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue }
}
Export-ModuleMember -Function Import-Tiny11Module, New-TempScratchDir, Remove-TempScratchDir
```

- [ ] **Step 4: Add Run-Tests.ps1**

Create `tests/Run-Tests.ps1`:

```powershell
#Requires -Module @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
$config = & "$PSScriptRoot/Tiny11.PesterConfig.ps1"
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
```

- [ ] **Step 5: Update .gitattributes**

Edit `.gitattributes`. After `*.ps1   text eol=crlf`, append:

```
*.psm1  text eol=crlf
*.psd1  text eol=crlf
```

- [ ] **Step 6: Verify Pester is installed**

```powershell
Get-Module -ListAvailable -Name Pester | Where-Object Version -ge '5.0.0'
```

If empty: `Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck`.

- [ ] **Step 7: Smoke test the harness**

Create `tests/Tiny11.Harness.Tests.ps1`:

```powershell
Describe "Test harness" {
    It "loads helpers without error" {
        Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
        Get-Command New-TempScratchDir | Should -Not -BeNullOrEmpty
    }
}
```

Run: `pwsh -NoProfile -File tests/Run-Tests.ps1`. Expected: 1 test passes.

- [ ] **Step 8: Commit**

```powershell
git add .gitattributes src/ tests/
git commit -m "chore: add Pester test scaffolding and src/ tests/ structure"
```

---

## Task 2: Catalog loader + schema validation

**Files:**
- Create: `src/Tiny11.Catalog.psm1`
- Create: `tests/Tiny11.Catalog.Tests.ps1`
- Create: `catalog/catalog.json` (minimal seed; full catalog in Task 14)

- [ ] **Step 1: Write failing tests**

Create `tests/Tiny11.Catalog.Tests.ps1`:

```powershell
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Catalog'

Describe "Get-Tiny11Catalog" {
    BeforeAll  { $script:tmp = New-TempScratchDir }
    AfterAll   { Remove-TempScratchDir -Path $script:tmp }

    It "loads a minimal valid catalog" {
        $path = Join-Path $script:tmp 'catalog.json'
        Set-Content -Path $path -Value '{"version":1,"categories":[],"items":[]}' -Encoding UTF8
        $cat = Get-Tiny11Catalog -Path $path
        $cat.Version | Should -Be 1
        $cat.Categories.Count | Should -Be 0
        $cat.Items.Count | Should -Be 0
    }

    It "throws on missing version field" {
        $path = Join-Path $script:tmp 'bad.json'
        Set-Content -Path $path -Value '{"categories":[],"items":[]}' -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*version*"
    }

    It "throws on unknown action type" {
        $path = Join-Path $script:tmp 'badaction.json'
        $catalog = @{
            version = 1
            categories = @(@{ id='c1'; displayName='C1'; description='' })
            items = @(@{
                id='item1'; category='c1'; displayName='I1'; description='';
                default='apply'; runtimeDepsOn=@();
                actions=@(@{ type='invalid-type' })
            })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $path -Value $catalog -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*invalid-type*"
    }

    It "throws when item references unknown category" {
        $path = Join-Path $script:tmp 'badcat.json'
        $catalog = @{
            version = 1; categories = @()
            items = @(@{
                id='i1'; category='nonexistent'; displayName='X'; description='';
                default='apply'; runtimeDepsOn=@(); actions=@()
            })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $path -Value $catalog -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*category*nonexistent*"
    }

    It "throws when runtimeDepsOn references unknown item id" {
        $path = Join-Path $script:tmp 'baddeps.json'
        $catalog = @{
            version = 1
            categories = @(@{ id='c1'; displayName='C1'; description='' })
            items = @(@{
                id='i1'; category='c1'; displayName='X'; description='';
                default='apply'; runtimeDepsOn=@('ghost'); actions=@()
            })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $path -Value $catalog -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*ghost*"
    }
}
```

- [ ] **Step 2: Run; confirm fail**

```powershell
pwsh -NoProfile -File tests/Run-Tests.ps1
```

Expected: 5 failures with "Module not found: Tiny11.Catalog".

- [ ] **Step 3: Implement Tiny11.Catalog**

Create `src/Tiny11.Catalog.psm1`:

```powershell
Set-StrictMode -Version Latest

$ValidActionTypes = @('provisioned-appx','filesystem','registry','scheduled-task')
$ValidHives       = @('COMPONENTS','DEFAULT','NTUSER','SOFTWARE','SYSTEM')

function Get-Tiny11Catalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "Catalog file not found: $Path" }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    try { $obj = $raw | ConvertFrom-Json } catch { throw "Catalog JSON parse error: $_" }

    if (-not $obj.PSObject.Properties.Name.Contains('version')) {
        throw "Catalog missing required field: version"
    }
    if ($obj.version -ne 1) { throw "Catalog version unsupported: $($obj.version) (expected 1)" }

    $categoryIds = @{}
    foreach ($cat in @($obj.categories)) {
        foreach ($field in 'id','displayName','description') {
            if (-not $cat.PSObject.Properties.Name.Contains($field)) {
                throw "Catalog category missing required field: $field"
            }
        }
        $categoryIds[$cat.id] = $true
    }

    $itemIds = @{}
    foreach ($item in @($obj.items)) {
        foreach ($field in 'id','category','displayName','description','default','runtimeDepsOn','actions') {
            if (-not $item.PSObject.Properties.Name.Contains($field)) {
                throw "Catalog item '$($item.id)' missing required field: $field"
            }
        }
        if (-not $categoryIds.ContainsKey($item.category)) {
            throw "Catalog item '$($item.id)' references unknown category: $($item.category)"
        }
        if ($item.default -notin 'apply','skip') {
            throw "Catalog item '$($item.id)' has invalid default: $($item.default) (expected 'apply' or 'skip')"
        }
        foreach ($action in @($item.actions)) {
            if ($action.type -notin $ValidActionTypes) {
                throw "Catalog item '$($item.id)' has invalid action type: $($action.type) (expected one of $($ValidActionTypes -join ', '))"
            }
            if ($action.type -eq 'registry' -and ($action.PSObject.Properties.Name -contains 'hive') -and ($action.hive -notin $ValidHives)) {
                throw "Catalog item '$($item.id)' has invalid hive: $($action.hive)"
            }
        }
        $itemIds[$item.id] = $true
    }

    foreach ($item in @($obj.items)) {
        foreach ($dep in @($item.runtimeDepsOn)) {
            if (-not $itemIds.ContainsKey($dep)) {
                throw "Catalog item '$($item.id)' has unknown runtimeDepsOn target: $dep"
            }
        }
    }

    [pscustomobject]@{
        Version    = $obj.version
        Categories = @($obj.categories)
        Items      = @($obj.items)
        Path       = (Resolve-Path $Path).Path
    }
}

Export-ModuleMember -Function Get-Tiny11Catalog
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Create seed catalog.json**

Create `catalog/catalog.json`:

```json
{
  "version": 1,
  "categories": [
    {
      "id": "store-apps",
      "displayName": "Microsoft Store apps",
      "description": "Pre-installed Store apps that can be safely removed."
    }
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
    }
  ]
}
```

- [ ] **Step 6: Add real-file load test**

Append to `tests/Tiny11.Catalog.Tests.ps1`:

```powershell
Describe "Real catalog file" {
    It "loads catalog/catalog.json without errors" {
        $catPath = "$PSScriptRoot/../catalog/catalog.json"
        $cat = Get-Tiny11Catalog -Path $catPath
        $cat.Items.Count | Should -BeGreaterThan 0
    }
}
```

Run; pass.

- [ ] **Step 7: Commit**

```powershell
git add src/Tiny11.Catalog.psm1 tests/Tiny11.Catalog.Tests.ps1 catalog/catalog.json
git commit -m "feat(catalog): add catalog loader with schema validation"
```

---

## Task 3: Selection model + reconcile

**Files:**
- Create: `src/Tiny11.Selections.psm1`
- Create: `tests/Tiny11.Selections.Tests.ps1`

- [ ] **Step 1: Write failing tests**

Create `tests/Tiny11.Selections.Tests.ps1`:

```powershell
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Catalog'
Import-Tiny11Module -Name 'Tiny11.Selections'

Describe "New-Tiny11Selections" {
    BeforeAll {
        $script:catalog = [pscustomobject]@{
            Version = 1
            Categories = @(@{ id='c1'; displayName='C1'; description='' })
            Items = @(
                @{ id='a'; category='c1'; displayName='A'; default='apply'; runtimeDepsOn=@(); actions=@() },
                @{ id='b'; category='c1'; displayName='B'; default='skip';  runtimeDepsOn=@(); actions=@() },
                @{ id='c'; category='c1'; displayName='C'; default='apply'; runtimeDepsOn=@('a'); actions=@() }
            )
            Path = ''
        }
    }
    It "produces defaults when no overrides" {
        $sel = New-Tiny11Selections -Catalog $script:catalog
        $sel['a'].State | Should -Be 'apply'
        $sel['b'].State | Should -Be 'skip'
        $sel['c'].State | Should -Be 'apply'
    }
    It "applies overrides over defaults" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ a = 'skip' }
        $sel['a'].State | Should -Be 'skip'
        $sel['b'].State | Should -Be 'skip'
    }
}

Describe "Resolve-Tiny11Selections (reconcile)" {
    BeforeAll {
        $script:catalog = [pscustomobject]@{
            Version = 1
            Categories = @(@{ id='c1'; displayName='C1'; description='' })
            Items = @(
                @{ id='runtime';  category='c1'; displayName='Runtime';  default='apply'; runtimeDepsOn=@();          actions=@() },
                @{ id='consumer'; category='c1'; displayName='Consumer'; default='apply'; runtimeDepsOn=@('runtime'); actions=@() }
            )
            Path = ''
        }
    }
    It "leaves both apply when neither is kept" {
        $sel = New-Tiny11Selections -Catalog $script:catalog
        $resolved = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $sel
        $resolved['runtime'].EffectiveState | Should -Be 'apply'
        $resolved['runtime'].Locked | Should -BeFalse
        $resolved['consumer'].EffectiveState | Should -Be 'apply'
    }
    It "locks the prereq when consumer is kept" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ consumer = 'skip' }
        $resolved = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $sel
        $resolved['runtime'].EffectiveState | Should -Be 'skip'
        $resolved['runtime'].Locked | Should -BeTrue
        $resolved['runtime'].LockedBy | Should -Contain 'consumer'
    }
    It "unlocks when consumer returns to apply" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ consumer = 'apply' }
        $resolved = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $sel
        $resolved['runtime'].Locked | Should -BeFalse
    }
}

Describe "Export-/Import-Tiny11Selections" {
    BeforeAll {
        $script:catalog = [pscustomobject]@{
            Version = 1
            Categories = @(@{ id='c1'; displayName='C1'; description='' })
            Items = @(
                @{ id='a'; category='c1'; displayName='A'; default='apply'; runtimeDepsOn=@(); actions=@() },
                @{ id='b'; category='c1'; displayName='B'; default='apply'; runtimeDepsOn=@(); actions=@() }
            )
            Path = ''
        }
        $script:tmp = New-TempScratchDir
    }
    AfterAll { Remove-TempScratchDir -Path $script:tmp }

    It "writes only items that diverge from default" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ a = 'skip' }
        $path = Join-Path $script:tmp 'profile.json'
        Export-Tiny11Selections -Selections $sel -Catalog $script:catalog -Path $path
        $loaded = Get-Content $path -Raw | ConvertFrom-Json
        $loaded.version | Should -Be 1
        $loaded.selections.PSObject.Properties.Name | Should -Contain 'a'
        $loaded.selections.PSObject.Properties.Name | Should -Not -Contain 'b'
    }
    It "round-trips overrides through Export and Import" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ a='skip' }
        $path = Join-Path $script:tmp 'rt.json'
        Export-Tiny11Selections -Selections $sel -Catalog $script:catalog -Path $path
        $loaded = Import-Tiny11Selections -Path $path -Catalog $script:catalog
        $loaded['a'].State | Should -Be 'skip'
        $loaded['b'].State | Should -Be 'apply'
    }
}
```

- [ ] **Step 2: Run; confirm fail**

- [ ] **Step 3: Implement Tiny11.Selections**

Create `src/Tiny11.Selections.psm1`:

```powershell
Set-StrictMode -Version Latest

function New-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Catalog,
        [hashtable]$Overrides = @{}
    )
    $result = @{}
    foreach ($item in $Catalog.Items) {
        $state = if ($Overrides.ContainsKey($item.id)) { $Overrides[$item.id] } else { $item.default }
        if ($state -notin 'apply','skip') {
            throw "Selection state for '$($item.id)' must be 'apply' or 'skip', got: $state"
        }
        $result[$item.id] = [pscustomobject]@{ ItemId = $item.id; State = $state }
    }
    $result
}

function Resolve-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][hashtable]$Selections
    )
    $pinnedBy = @{}
    foreach ($item in $Catalog.Items) {
        if ($Selections[$item.id].State -eq 'skip') {
            foreach ($dep in $item.runtimeDepsOn) {
                if (-not $pinnedBy.ContainsKey($dep)) { $pinnedBy[$dep] = @() }
                $pinnedBy[$dep] += $item.id
            }
        }
    }
    $resolved = @{}
    foreach ($item in $Catalog.Items) {
        $userState = $Selections[$item.id].State
        $locked = $pinnedBy.ContainsKey($item.id)
        $effective = if ($locked) { 'skip' } else { $userState }
        $resolved[$item.id] = [pscustomobject]@{
            ItemId = $item.id; UserState = $userState
            EffectiveState = $effective; Locked = $locked
            LockedBy = if ($locked) { $pinnedBy[$item.id] } else { @() }
        }
    }
    $resolved
}

function Export-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Selections,
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][string]$Path
    )
    $diverged = @{}
    foreach ($item in $Catalog.Items) {
        if ($Selections[$item.id].State -ne $item.default) {
            $diverged[$item.id] = $Selections[$item.id].State
        }
    }
    $payload = [ordered]@{ version = 1; selections = $diverged }
    $json = $payload | ConvertTo-Json -Depth 5
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Import-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)] $Catalog
    )
    if (-not (Test-Path $Path)) { throw "Profile file not found: $Path" }
    $obj = Get-Content $Path -Raw | ConvertFrom-Json
    if ($obj.version -ne 1) { throw "Profile version unsupported: $($obj.version)" }
    $overrides = @{}
    if ($obj.PSObject.Properties.Name -contains 'selections') {
        foreach ($p in $obj.selections.PSObject.Properties) { $overrides[$p.Name] = $p.Value }
    }
    New-Tiny11Selections -Catalog $Catalog -Overrides $overrides
}

Export-ModuleMember -Function New-Tiny11Selections, Resolve-Tiny11Selections, Export-Tiny11Selections, Import-Tiny11Selections
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Selections.psm1 tests/Tiny11.Selections.Tests.ps1
git commit -m "feat(selections): add selection model with reconcile and roundtrip"
```

---

## Task 4: Hive load/unload helpers

**Files:**
- Create: `src/Tiny11.Hives.psm1`
- Create: `tests/Tiny11.Hives.Tests.ps1`

- [ ] **Step 1: Write failing tests**

Create `tests/Tiny11.Hives.Tests.ps1`:

```powershell
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Hives'

Describe "Resolve-Tiny11HivePath" {
    It "maps SOFTWARE to scratchdir/Windows/System32/config/SOFTWARE" {
        Resolve-Tiny11HivePath -Hive 'SOFTWARE' -ScratchDir 'C:\scratch' | Should -Be 'C:\scratch\Windows\System32\config\SOFTWARE'
    }
    It "maps NTUSER to Users/Default/ntuser.dat" {
        Resolve-Tiny11HivePath -Hive 'NTUSER' -ScratchDir 'C:\scratch' | Should -Be 'C:\scratch\Users\Default\ntuser.dat'
    }
    It "maps DEFAULT to config/default" {
        Resolve-Tiny11HivePath -Hive 'DEFAULT' -ScratchDir 'C:\scratch' | Should -Be 'C:\scratch\Windows\System32\config\default'
    }
    It "maps COMPONENTS and SYSTEM" {
        (Resolve-Tiny11HivePath -Hive 'COMPONENTS' -ScratchDir 'C:\s').EndsWith('config\COMPONENTS') | Should -BeTrue
        (Resolve-Tiny11HivePath -Hive 'SYSTEM' -ScratchDir 'C:\s').EndsWith('config\SYSTEM') | Should -BeTrue
    }
    It "throws on unknown hive" {
        { Resolve-Tiny11HivePath -Hive 'BOGUS' -ScratchDir 'C:\s' } | Should -Throw
    }
}

Describe "Mount-/Dismount-Tiny11Hive" {
    BeforeEach { Mock -CommandName 'Invoke-RegCommand' -MockWith { 0 } -ModuleName 'Tiny11.Hives' }
    It "calls reg load with HKLM\\zSOFTWARE and the resolved path" {
        Mount-Tiny11Hive -Hive 'SOFTWARE' -ScratchDir 'C:\scratch'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -ParameterFilter {
            $Args -contains 'load' -and $Args -contains 'HKLM\zSOFTWARE' -and ($Args -join ' ') -like '*Windows\System32\config\SOFTWARE*'
        }
    }
    It "calls reg unload with HKLM\\zNTUSER" {
        Dismount-Tiny11Hive -Hive 'NTUSER'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Hives' -ParameterFilter {
            $Args -contains 'unload' -and $Args -contains 'HKLM\zNTUSER'
        }
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Hives.psm1`:

```powershell
Set-StrictMode -Version Latest

$HiveMap = @{
    'COMPONENTS' = 'Windows\System32\config\COMPONENTS'
    'DEFAULT'    = 'Windows\System32\config\default'
    'NTUSER'     = 'Users\Default\ntuser.dat'
    'SOFTWARE'   = 'Windows\System32\config\SOFTWARE'
    'SYSTEM'     = 'Windows\System32\config\SYSTEM'
}

function Resolve-Tiny11HivePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$ScratchDir)
    if (-not $HiveMap.ContainsKey($Hive)) {
        throw "Unknown hive: $Hive (expected one of $($HiveMap.Keys -join ', '))"
    }
    Join-Path $ScratchDir $HiveMap[$Hive]
}

function Get-Tiny11HiveMountKey {
    param([Parameter(Mandatory)][string]$Hive)
    "HKLM\z$Hive"
}

function Invoke-RegCommand {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    $exit = (& reg.exe @Args) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg.exe failed (exit $LASTEXITCODE): $($Args -join ' ')`n$exit" }
    $LASTEXITCODE
}

function Mount-Tiny11Hive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$ScratchDir)
    $path = Resolve-Tiny11HivePath -Hive $Hive -ScratchDir $ScratchDir
    Invoke-RegCommand 'load' (Get-Tiny11HiveMountKey -Hive $Hive) $path
}

function Dismount-Tiny11Hive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive)
    Invoke-RegCommand 'unload' (Get-Tiny11HiveMountKey -Hive $Hive)
}

function Mount-Tiny11AllHives {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScratchDir)
    foreach ($h in $HiveMap.Keys) { Mount-Tiny11Hive -Hive $h -ScratchDir $ScratchDir }
}

function Dismount-Tiny11AllHives {
    [CmdletBinding()] param()
    foreach ($h in $HiveMap.Keys) {
        try { Dismount-Tiny11Hive -Hive $h } catch { Write-Warning "Failed to unload hive ${h}: $_" }
    }
}

Export-ModuleMember -Function Resolve-Tiny11HivePath, Get-Tiny11HiveMountKey, Invoke-RegCommand, Mount-Tiny11Hive, Dismount-Tiny11Hive, Mount-Tiny11AllHives, Dismount-Tiny11AllHives
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Hives.psm1 tests/Tiny11.Hives.Tests.ps1
git commit -m "feat(hives): add offline registry hive load/unload helpers"
```

---

## Task 5: Action handler — registry

**Files:**
- Create: `src/Tiny11.Actions.Registry.psm1`
- Create: `tests/Tiny11.Actions.Registry.Tests.ps1`

- [ ] **Step 1: Write failing tests**

Create `tests/Tiny11.Actions.Registry.Tests.ps1`:

```powershell
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Hives'
Import-Tiny11Module -Name 'Tiny11.Actions.Registry'

Describe "Invoke-RegistryAction" {
    BeforeEach { Mock -CommandName 'Invoke-RegCommand' -MockWith { 0 } -ModuleName 'Tiny11.Actions.Registry' }
    It "issues 'reg add' for op=set with all fields" {
        $action = @{
            type='registry'; op='set'; hive='SOFTWARE'
            key='Policies\Microsoft\Windows\DataCollection'
            name='AllowTelemetry'; valueType='REG_DWORD'; value='0'
        }
        Invoke-RegistryAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            $Args[0] -eq 'add' -and
            $Args[1] -eq 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' -and
            $Args -contains '/v' -and $Args -contains 'AllowTelemetry' -and
            $Args -contains '/t' -and $Args -contains 'REG_DWORD' -and
            $Args -contains '/d' -and $Args -contains '0' -and
            $Args -contains '/f'
        }
    }
    It "issues 'reg delete' for op=remove" {
        $action = @{ type='registry'; op='remove'; hive='SOFTWARE'; key='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' }
        Invoke-RegistryAction -Action $action -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-RegCommand' -ModuleName 'Tiny11.Actions.Registry' -ParameterFilter {
            $Args[0] -eq 'delete' -and
            $Args[1] -eq 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' -and
            $Args -contains '/f'
        }
    }
    It "throws on invalid op" {
        $action = @{ type='registry'; op='nope'; hive='SOFTWARE'; key='X' }
        { Invoke-RegistryAction -Action $action -ScratchDir 'C:\s' } | Should -Throw "*op*"
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Actions.Registry.psm1`:

```powershell
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Hives.psm1" -Force -DisableNameChecking

function Invoke-RegistryAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)

    $mountKey = Get-Tiny11HiveMountKey -Hive $Action.hive
    $fullKey  = "$mountKey\$($Action.key)"

    switch ($Action.op) {
        'set' {
            Invoke-RegCommand 'add' $fullKey '/v' $Action.name '/t' $Action.valueType '/d' $Action.value '/f' | Out-Null
        }
        'remove' {
            Invoke-RegCommand 'delete' $fullKey '/f' | Out-Null
        }
        default { throw "Invalid registry op: $($Action.op)" }
    }
}

Export-ModuleMember -Function Invoke-RegistryAction
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.Registry.psm1 tests/Tiny11.Actions.Registry.Tests.ps1
git commit -m "feat(actions): add registry action handler"
```

---

## Task 6: Action handler — provisioned-appx

**Files:**
- Create: `src/Tiny11.Actions.ProvisionedAppx.psm1`
- Create: `tests/Tiny11.Actions.ProvisionedAppx.Tests.ps1`

- [ ] **Step 1: Write failing tests**

```powershell
# tests/Tiny11.Actions.ProvisionedAppx.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions.ProvisionedAppx'

Describe "Invoke-ProvisionedAppxAction" {
    BeforeEach {
        Mock -CommandName 'Get-ProvisionedAppxPackagesFromImage' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -MockWith {
            @(
                'Clipchamp.Clipchamp_3.1.13190.0_neutral_~_yxz26nhyzhsrt',
                'Microsoft.BingNews_4.55.1.0_x64__8wekyb3d8bbwe',
                'Microsoft.WindowsTerminal_1.18.3181.0_x64__8wekyb3d8bbwe'
            )
        }
        Mock -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -MockWith { }
    }
    It "removes all packages whose name contains the prefix" {
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='Microsoft.BingNews' } -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 1 -ParameterFilter {
            $PackageName -like 'Microsoft.BingNews_*'
        }
    }
    It "is idempotent on no matches" {
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='NotPresent.Anywhere' } -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 0
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Actions.ProvisionedAppx.psm1`:

```powershell
Set-StrictMode -Version Latest

function Get-ProvisionedAppxPackagesFromImage {
    param([Parameter(Mandatory)][string]$ScratchDir)
    & 'dism.exe' '/English' "/image:$ScratchDir" '/Get-ProvisionedAppxPackages' |
        ForEach-Object {
            if ($_ -match '^PackageName\s*:\s*(.+)$') { $matches[1].Trim() }
        }
}

function Invoke-DismRemoveAppx {
    param([Parameter(Mandatory)][string]$ScratchDir, [Parameter(Mandatory)][string]$PackageName)
    & 'dism.exe' '/English' "/image:$ScratchDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$PackageName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dism /Remove-ProvisionedAppxPackage failed for $PackageName (exit $LASTEXITCODE)" }
}

function Invoke-ProvisionedAppxAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)
    $packages = Get-ProvisionedAppxPackagesFromImage -ScratchDir $ScratchDir
    $matches = $packages | Where-Object { $_ -like "*$($Action.packagePrefix)*" }
    foreach ($pkg in $matches) { Invoke-DismRemoveAppx -ScratchDir $ScratchDir -PackageName $pkg }
}

Export-ModuleMember -Function Invoke-ProvisionedAppxAction, Get-ProvisionedAppxPackagesFromImage, Invoke-DismRemoveAppx
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.ProvisionedAppx.psm1 tests/Tiny11.Actions.ProvisionedAppx.Tests.ps1
git commit -m "feat(actions): add provisioned-appx action handler"
```

---

## Task 7: Action handler — filesystem

**Files:**
- Create: `src/Tiny11.Actions.Filesystem.psm1`
- Create: `tests/Tiny11.Actions.Filesystem.Tests.ps1`

- [ ] **Step 1: Write failing tests**

```powershell
# tests/Tiny11.Actions.Filesystem.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions.Filesystem'

Describe "Invoke-FilesystemAction" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }

    It "removes a single file (op=remove)" {
        $f = Join-Path $script:tmp 'subdir\file.txt'
        New-Item -ItemType File -Path $f -Force | Out-Null
        Invoke-FilesystemAction -Action @{ type='filesystem'; op='remove'; path='subdir\file.txt'; recurse=$false } -ScratchDir $script:tmp
        Test-Path $f | Should -BeFalse
    }
    It "removes a directory recursively" {
        $d = Join-Path $script:tmp 'recdir'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'a.txt') -Force | Out-Null
        Invoke-FilesystemAction -Action @{ type='filesystem'; op='remove'; path='recdir'; recurse=$true } -ScratchDir $script:tmp
        Test-Path $d | Should -BeFalse
    }
    It "is idempotent on missing path" {
        { Invoke-FilesystemAction -Action @{ type='filesystem'; op='remove'; path='ghost\nope.txt'; recurse=$false } -ScratchDir $script:tmp } | Should -Not -Throw
    }
    It "calls takeown+icacls before remove for op=takeown-and-remove" {
        Mock -CommandName 'Invoke-Takeown' -MockWith { } -ModuleName 'Tiny11.Actions.Filesystem'
        Mock -CommandName 'Invoke-Icacls'  -MockWith { } -ModuleName 'Tiny11.Actions.Filesystem'
        $f = Join-Path $script:tmp 'protected'
        New-Item -ItemType Directory -Path $f -Force | Out-Null
        Invoke-FilesystemAction -Action @{ type='filesystem'; op='takeown-and-remove'; path='protected'; recurse=$true } -ScratchDir $script:tmp
        Should -Invoke -CommandName 'Invoke-Takeown' -ModuleName 'Tiny11.Actions.Filesystem' -Times 1
        Should -Invoke -CommandName 'Invoke-Icacls'  -ModuleName 'Tiny11.Actions.Filesystem' -Times 1
        Test-Path $f | Should -BeFalse
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Actions.Filesystem.psm1`:

```powershell
Set-StrictMode -Version Latest

function Invoke-Takeown {
    param([Parameter(Mandatory)][string]$Path, [bool]$Recurse)
    $args = @('/f', $Path)
    if ($Recurse) { $args += '/r'; $args += '/d'; $args += 'Y' }
    & 'takeown.exe' @args | Out-Null
}

function Invoke-Icacls {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AdminGroup)
    & 'icacls.exe' $Path '/grant' "$AdminGroup`:(F)" '/T' '/C' | Out-Null
}

function Get-AdminGroupAccount {
    $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $sid.Translate([System.Security.Principal.NTAccount]).Value
}

function Invoke-FilesystemAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)

    $full = Join-Path $ScratchDir $Action.path
    if (-not (Test-Path $full)) { return }

    if ($Action.op -eq 'takeown-and-remove') {
        $admin = Get-AdminGroupAccount
        Invoke-Takeown -Path $full -Recurse:([bool]$Action.recurse)
        Invoke-Icacls -Path $full -AdminGroup $admin
    } elseif ($Action.op -ne 'remove') {
        throw "Invalid filesystem op: $($Action.op)"
    }

    if ($Action.recurse) { Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue }
    else                 { Remove-Item -Path $full -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function Invoke-FilesystemAction, Invoke-Takeown, Invoke-Icacls, Get-AdminGroupAccount
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.Filesystem.psm1 tests/Tiny11.Actions.Filesystem.Tests.ps1
git commit -m "feat(actions): add filesystem action handler"
```

---

## Task 8: Action handler — scheduled-task

**Files:**
- Create: `src/Tiny11.Actions.ScheduledTask.psm1`
- Create: `tests/Tiny11.Actions.ScheduledTask.Tests.ps1`

- [ ] **Step 1: Write failing tests**

```powershell
# tests/Tiny11.Actions.ScheduledTask.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions.ScheduledTask'

Describe "Invoke-ScheduledTaskAction" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }

    It "deletes a single task XML file" {
        $tasksRoot = Join-Path $script:tmp 'Windows\System32\Tasks'
        $taskPath = Join-Path $tasksRoot 'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        New-Item -ItemType File -Path $taskPath -Force | Out-Null
        Invoke-ScheduledTaskAction -Action @{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Application Experience/Microsoft Compatibility Appraiser'; recurse=$false } -ScratchDir $script:tmp
        Test-Path $taskPath | Should -BeFalse
    }
    It "deletes a folder recursively" {
        $tasksRoot = Join-Path $script:tmp 'Windows\System32\Tasks'
        $folder = Join-Path $tasksRoot 'Microsoft\Windows\Customer Experience Improvement Program'
        New-Item -ItemType File -Path (Join-Path $folder 'subtask') -Force | Out-Null
        Invoke-ScheduledTaskAction -Action @{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Customer Experience Improvement Program'; recurse=$true } -ScratchDir $script:tmp
        Test-Path $folder | Should -BeFalse
    }
    It "is idempotent on missing path" {
        { Invoke-ScheduledTaskAction -Action @{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Ghost'; recurse=$false } -ScratchDir $script:tmp } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Actions.ScheduledTask.psm1`:

```powershell
Set-StrictMode -Version Latest

function Invoke-ScheduledTaskAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)

    if ($Action.op -ne 'remove') { throw "Invalid scheduled-task op: $($Action.op)" }

    $tasksRoot = Join-Path $ScratchDir 'Windows\System32\Tasks'
    $relPath = $Action.path -replace '/','\'
    $full = Join-Path $tasksRoot $relPath

    if (-not (Test-Path $full)) { return }
    if ($Action.recurse) { Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue }
    else                 { Remove-Item -Path $full -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function Invoke-ScheduledTaskAction
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.ScheduledTask.psm1 tests/Tiny11.Actions.ScheduledTask.Tests.ps1
git commit -m "feat(actions): add scheduled-task action handler"
```

---

## Task 9: Action dispatcher

**Files:**
- Create: `src/Tiny11.Actions.psm1`
- Create: `tests/Tiny11.Actions.Tests.ps1`

- [ ] **Step 1: Write failing tests**

```powershell
# tests/Tiny11.Actions.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions'

Describe "Invoke-Tiny11Action" {
    BeforeEach {
        Mock -CommandName 'Invoke-RegistryAction'         -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-FilesystemAction'        -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-ScheduledTaskAction'     -ModuleName 'Tiny11.Actions' -MockWith { }
        Mock -CommandName 'Invoke-ProvisionedAppxAction'   -ModuleName 'Tiny11.Actions' -MockWith { }
    }
    It "routes registry"         { Invoke-Tiny11Action -Action @{ type='registry'; op='set'; hive='SOFTWARE'; key='K'; name='N'; valueType='REG_DWORD'; value='0' } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-RegistryAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes filesystem"       { Invoke-Tiny11Action -Action @{ type='filesystem'; op='remove'; path='X'; recurse=$false } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-FilesystemAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes scheduled-task"   { Invoke-Tiny11Action -Action @{ type='scheduled-task'; op='remove'; path='Y'; recurse=$false } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-ScheduledTaskAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "routes provisioned-appx" { Invoke-Tiny11Action -Action @{ type='provisioned-appx'; packagePrefix='X' } -ScratchDir 'C:\s'; Should -Invoke -CommandName 'Invoke-ProvisionedAppxAction' -ModuleName 'Tiny11.Actions' -Times 1 }
    It "throws on unknown type"  { { Invoke-Tiny11Action -Action @{ type='ghost' } -ScratchDir 'C:\s' } | Should -Throw }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Actions.psm1`:

```powershell
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Actions.Registry.psm1"        -Force -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Actions.Filesystem.psm1"      -Force -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Actions.ScheduledTask.psm1"   -Force -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Actions.ProvisionedAppx.psm1" -Force -DisableNameChecking

function Invoke-Tiny11Action {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)
    switch ($Action.type) {
        'registry'         { Invoke-RegistryAction         -Action $Action -ScratchDir $ScratchDir }
        'filesystem'       { Invoke-FilesystemAction        -Action $Action -ScratchDir $ScratchDir }
        'scheduled-task'   { Invoke-ScheduledTaskAction     -Action $Action -ScratchDir $ScratchDir }
        'provisioned-appx' { Invoke-ProvisionedAppxAction   -Action $Action -ScratchDir $ScratchDir }
        default            { throw "Unknown action type: $($Action.type)" }
    }
}

Export-ModuleMember -Function Invoke-Tiny11Action
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.psm1 tests/Tiny11.Actions.Tests.ps1
git commit -m "feat(actions): add action dispatcher routing by type"
```

---

## Task 10: ISO mount/unmount + edition enumeration

**Files:**
- Create: `src/Tiny11.Iso.psm1`
- Create: `tests/Tiny11.Iso.Tests.ps1`

- [ ] **Step 1: Write failing tests**

```powershell
# tests/Tiny11.Iso.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Iso'

Describe "Resolve-Tiny11Source" {
    It "treats single-letter input as drive letter"  { (Resolve-Tiny11Source -InputPath 'E').Kind | Should -Be 'DriveLetter' }
    It "treats E: as drive letter"                    { (Resolve-Tiny11Source -InputPath 'E:').DriveLetter | Should -Be 'E' }
    It "treats E:\\ as drive letter"                  { (Resolve-Tiny11Source -InputPath 'E:\').Kind | Should -Be 'DriveLetter' }
    It "treats path ending in .iso as iso file"       {
        $r = Resolve-Tiny11Source -InputPath 'C:\foo.iso'
        $r.Kind | Should -Be 'IsoFile'; $r.IsoPath | Should -Be 'C:\foo.iso'
    }
    It "throws on unrecognized input"                 { { Resolve-Tiny11Source -InputPath 'C:\not-an-iso.txt' } | Should -Throw }
}

Describe "Mount-Tiny11Source / Get-Tiny11Editions" {
    BeforeEach {
        Mock -CommandName 'Mount-DiskImage' -MockWith { [pscustomobject]@{ ImagePath = $ImagePath; Attached = $true } } -ModuleName 'Tiny11.Iso'
        Mock -CommandName 'Get-Volume'      -MockWith { [pscustomobject]@{ DriveLetter = 'F' } } -ModuleName 'Tiny11.Iso'
        Mock -CommandName 'Get-DiskImage'   -MockWith { [pscustomobject]@{ Attached = $false } } -ModuleName 'Tiny11.Iso'
        Mock -CommandName 'Get-WindowsImage' -MockWith {
            @(
                [pscustomobject]@{ ImageIndex=1; ImageName='Windows 11 Home'; Architecture='x64'; Languages=@('en-US') }
                [pscustomobject]@{ ImageIndex=6; ImageName='Windows 11 Pro';  Architecture='x64'; Languages=@('en-US') }
            )
        } -ModuleName 'Tiny11.Iso'
    }
    It "mounts an ISO file and returns drive letter + mountedByUs=true" {
        $r = Mount-Tiny11Source -InputPath 'C:\Win11.iso'
        $r.DriveLetter | Should -Be 'F'; $r.MountedByUs | Should -BeTrue
    }
    It "skips mount when input is a drive letter; mountedByUs=false" {
        $r = Mount-Tiny11Source -InputPath 'E:'
        $r.DriveLetter | Should -Be 'E'; $r.MountedByUs | Should -BeFalse
    }
    It "enumerates editions from install.wim" {
        Mock -CommandName 'Test-Path' -MockWith { $true } -ModuleName 'Tiny11.Iso'
        $editions = Get-Tiny11Editions -DriveLetter 'F'
        $editions.Count | Should -Be 2
        $editions[1].ImageIndex | Should -Be 6; $editions[1].ImageName | Should -Be 'Windows 11 Pro'
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Iso.psm1`:

```powershell
Set-StrictMode -Version Latest

function Resolve-Tiny11Source {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InputPath)
    if ($InputPath -match '^[a-zA-Z]$') {
        return [pscustomobject]@{ Kind='DriveLetter'; DriveLetter=$InputPath.ToUpper(); IsoPath=$null }
    }
    if ($InputPath -match '^[a-zA-Z]:\\?$') {
        return [pscustomobject]@{ Kind='DriveLetter'; DriveLetter=$InputPath.Substring(0,1).ToUpper(); IsoPath=$null }
    }
    if ($InputPath -like '*.iso') {
        return [pscustomobject]@{ Kind='IsoFile'; DriveLetter=$null; IsoPath=$InputPath }
    }
    throw "Unrecognized source: '$InputPath'. Expected an .iso file path or a drive letter (E, E:, E:\)."
}

function Mount-Tiny11Source {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InputPath)
    $resolved = Resolve-Tiny11Source -InputPath $InputPath
    if ($resolved.Kind -eq 'DriveLetter') {
        return [pscustomobject]@{ DriveLetter = $resolved.DriveLetter; MountedByUs = $false; IsoPath = $null }
    }
    $img = Mount-DiskImage -ImagePath $resolved.IsoPath -PassThru
    $vol = $img | Get-Volume
    if (-not $vol -or -not $vol.DriveLetter) { throw "Mount succeeded but no drive letter assigned to $($resolved.IsoPath)" }
    [pscustomobject]@{ DriveLetter = "$($vol.DriveLetter)"; MountedByUs = $true; IsoPath = $resolved.IsoPath }
}

function Dismount-Tiny11Source {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][bool]$MountedByUs,
        [bool]$ForceUnmount
    )
    if (-not $MountedByUs -and -not $ForceUnmount) { return }
    if (-not $IsoPath) { return }
    $existing = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Attached) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
}

function Get-Tiny11Editions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)
    $wim = "${DriveLetter}:\sources\install.wim"
    $esd = "${DriveLetter}:\sources\install.esd"
    $imgPath = if (Test-Path $wim) { $wim } elseif (Test-Path $esd) { $esd } else {
        throw "Drive ${DriveLetter}: does not contain sources\install.wim or install.esd"
    }
    Get-WindowsImage -ImagePath $imgPath
}

Export-ModuleMember -Function Resolve-Tiny11Source, Mount-Tiny11Source, Dismount-Tiny11Source, Get-Tiny11Editions
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Iso.psm1 tests/Tiny11.Iso.Tests.ps1
git commit -m "feat(iso): add source mount/unmount and edition enumeration"
```

---

## Task 11: autounattend template + 3-tier acquisition

**Files:**
- Create: `autounattend.template.xml`
- Create: `src/Tiny11.Autounattend.psm1`
- Create: `tests/Tiny11.Autounattend.Tests.ps1`
- Delete: `autounattend.xml`

- [ ] **Step 1: Create the template file**

Create `autounattend.template.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideOnlineAccountScreens>{{HIDE_ONLINE_ACCOUNT_SCREENS}}</HideOnlineAccountScreens>
            </OOBE>
        </component>
    </settings>
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        <ConfigureChatAutoInstall>{{CONFIGURE_CHAT_AUTO_INSTALL}}</ConfigureChatAutoInstall>
    </component>
    <settings pass="windowsPE">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <DynamicUpdate>
                <WillShowUI>OnError</WillShowUI>
            </DynamicUpdate>
            <ImageInstall>
                <OSImage>
                    <Compact>{{COMPACT_INSTALL}}</Compact>
                    <WillShowUI>OnError</WillShowUI>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>{{IMAGE_INDEX}}</Value>
                        </MetaData>
                    </InstallFrom>
                </OSImage>
            </ImageInstall>
            <UserData>
                <ProductKey>
                    <Key/>
                </ProductKey>
            </UserData>
        </component>
    </settings>
</unattend>
```

- [ ] **Step 2: Delete the legacy file**

```powershell
Remove-Item -Path autounattend.xml -Force
```

- [ ] **Step 3: Write failing tests**

```powershell
# tests/Tiny11.Autounattend.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Autounattend'

Describe "Render-Tiny11Autounattend" {
    It "substitutes placeholders" {
        $template = "A={{HIDE_ONLINE_ACCOUNT_SCREENS}};B={{CONFIGURE_CHAT_AUTO_INSTALL}};C={{COMPACT_INSTALL}};D={{IMAGE_INDEX}}"
        $bindings = @{
            HIDE_ONLINE_ACCOUNT_SCREENS='true'
            CONFIGURE_CHAT_AUTO_INSTALL='false'
            COMPACT_INSTALL='true'; IMAGE_INDEX='6'
        }
        Render-Tiny11Autounattend -Template $template -Bindings $bindings | Should -Be "A=true;B=false;C=true;D=6"
    }
    It "throws on unknown placeholder" {
        { Render-Tiny11Autounattend -Template "X={{UNKNOWN}}" -Bindings @{} } | Should -Throw '*UNKNOWN*'
    }
}

Describe "Get-Tiny11AutounattendBindings" {
    It "maps tweak-bypass-nro=apply to HIDE_ONLINE_ACCOUNT_SCREENS=true" {
        $resolved = @{
            'tweak-bypass-nro'        = [pscustomobject]@{ EffectiveState='apply' }
            'tweak-disable-chat-icon' = [pscustomobject]@{ EffectiveState='skip' }
            'tweak-compact-install'   = [pscustomobject]@{ EffectiveState='apply' }
        }
        $b = Get-Tiny11AutounattendBindings -ResolvedSelections $resolved -ImageIndex 6
        $b['HIDE_ONLINE_ACCOUNT_SCREENS'] | Should -Be 'true'
        $b['CONFIGURE_CHAT_AUTO_INSTALL'] | Should -Be 'true'
        $b['COMPACT_INSTALL']             | Should -Be 'true'
        $b['IMAGE_INDEX']                 | Should -Be '6'
    }
}

Describe "Get-Tiny11AutounattendTemplate (3-tier)" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }

    It "uses the local file when present" {
        $local = Join-Path $script:tmp 'autounattend.template.xml'
        Set-Content -Path $local -Value '<unattend>local</unattend>' -Encoding UTF8
        $r = Get-Tiny11AutounattendTemplate -LocalPath $local
        $r.Source | Should -Be 'Local'
        $r.Content | Should -Be '<unattend>local</unattend>'
    }
    It "falls back to embedded when local missing and network mocked to fail" {
        Mock -CommandName 'Invoke-RestMethod' -ModuleName 'Tiny11.Autounattend' -MockWith { throw "no network" }
        $r = Get-Tiny11AutounattendTemplate -LocalPath (Join-Path $script:tmp 'nope.xml')
        $r.Source | Should -Be 'Embedded'
        $r.Content | Should -Match '<unattend'
    }
}
```

- [ ] **Step 4: Confirm fail**

- [ ] **Step 5: Implement**

Create `src/Tiny11.Autounattend.psm1`. The `$EmbeddedTemplate` here-string MUST stay byte-equivalent to `autounattend.template.xml` (drift test in Task 25):

```powershell
Set-StrictMode -Version Latest

$EmbeddedTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideOnlineAccountScreens>{{HIDE_ONLINE_ACCOUNT_SCREENS}}</HideOnlineAccountScreens>
            </OOBE>
        </component>
    </settings>
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        <ConfigureChatAutoInstall>{{CONFIGURE_CHAT_AUTO_INSTALL}}</ConfigureChatAutoInstall>
    </component>
    <settings pass="windowsPE">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <DynamicUpdate>
                <WillShowUI>OnError</WillShowUI>
            </DynamicUpdate>
            <ImageInstall>
                <OSImage>
                    <Compact>{{COMPACT_INSTALL}}</Compact>
                    <WillShowUI>OnError</WillShowUI>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>{{IMAGE_INDEX}}</Value>
                        </MetaData>
                    </InstallFrom>
                </OSImage>
            </ImageInstall>
            <UserData>
                <ProductKey>
                    <Key/>
                </ProductKey>
            </UserData>
        </component>
    </settings>
</unattend>
'@

$ForkTemplateUrl = 'https://raw.githubusercontent.com/bilbospocketses/tiny11options/refs/heads/main/autounattend.template.xml'

function Render-Tiny11Autounattend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Bindings
    )
    $remaining = [regex]::Matches($Template, '\{\{([A-Z_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    foreach ($key in $remaining) {
        if (-not $Bindings.ContainsKey($key)) { throw "Autounattend template has unknown placeholder: $key" }
    }
    $output = $Template
    foreach ($k in $Bindings.Keys) { $output = $output.Replace("{{$k}}", [string]$Bindings[$k]) }
    $output
}

function Get-Tiny11AutounattendBindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ResolvedSelections, [Parameter(Mandatory)][int]$ImageIndex)
    function State($id) { if ($ResolvedSelections.ContainsKey($id)) { $ResolvedSelections[$id].EffectiveState } else { 'apply' } }
    @{
        HIDE_ONLINE_ACCOUNT_SCREENS = (if ((State 'tweak-bypass-nro') -eq 'apply') { 'true' } else { 'false' })
        CONFIGURE_CHAT_AUTO_INSTALL = (if ((State 'tweak-disable-chat-icon') -eq 'apply') { 'false' } else { 'true' })
        COMPACT_INSTALL             = (if ((State 'tweak-compact-install') -eq 'apply') { 'true' } else { 'false' })
        IMAGE_INDEX                 = "$ImageIndex"
    }
}

function Get-Tiny11AutounattendTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LocalPath)

    if (Test-Path $LocalPath) {
        return [pscustomobject]@{ Source='Local'; Content=(Get-Content -Path $LocalPath -Raw -Encoding UTF8) }
    }
    try {
        $content = Invoke-RestMethod -Uri $ForkTemplateUrl -ErrorAction Stop
        Set-Content -Path $LocalPath -Value $content -Encoding UTF8
        return [pscustomobject]@{ Source='Network'; Content=$content }
    } catch {
        Write-Warning "autounattend template fetch from $ForkTemplateUrl failed; using embedded fallback. ($_)"
        return [pscustomobject]@{ Source='Embedded'; Content=$EmbeddedTemplate }
    }
}

function Get-Tiny11EmbeddedAutounattend { $EmbeddedTemplate }

Export-ModuleMember -Function Render-Tiny11Autounattend, Get-Tiny11AutounattendBindings, Get-Tiny11AutounattendTemplate, Get-Tiny11EmbeddedAutounattend
```

- [ ] **Step 6: Run; pass**

- [ ] **Step 7: Commit**

```powershell
git add autounattend.template.xml src/Tiny11.Autounattend.psm1 tests/Tiny11.Autounattend.Tests.ps1
git rm autounattend.xml
git commit -m "feat(autounattend): add template + 3-tier acquisition + render"
```

---

## Task 12: Worker engine

**Files:**
- Create: `src/Tiny11.Worker.psm1`
- Create: `tests/Tiny11.Worker.Tests.ps1`

The worker drives the full build; it uses a progress callback so the GUI's bridge can subscribe (Phase 2). Cancellation token is checked at phase boundaries.

- [ ] **Step 1: Write tests**

```powershell
# tests/Tiny11.Worker.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Worker'

Describe "Get-Tiny11ApplyItems" {
    It "returns only items with EffectiveState=apply" {
        $resolved = @{
            'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' }
            'b' = [pscustomobject]@{ ItemId='b'; EffectiveState='skip' }
            'c' = [pscustomobject]@{ ItemId='c'; EffectiveState='apply' }
        }
        $catalog = [pscustomobject]@{ Items = @( @{ id='a'; actions=@() }, @{ id='b'; actions=@() }, @{ id='c'; actions=@() } ) }
        $items = Get-Tiny11ApplyItems -Catalog $catalog -ResolvedSelections $resolved
        $items.Count | Should -Be 2
        $items[0].id | Should -Be 'a'; $items[1].id | Should -Be 'c'
    }
}

Describe "Invoke-Tiny11ApplyActions" {
    BeforeEach { Mock -CommandName 'Invoke-Tiny11Action' -MockWith { } -ModuleName 'Tiny11.Worker' }
    It "calls dispatcher once per action across apply items" {
        $catalog = [pscustomobject]@{
            Items = @(
                @{ id='a'; actions=@(@{type='registry'; op='set'; hive='SOFTWARE'; key='K1'; name='N'; valueType='REG_DWORD'; value='0'}) }
                @{ id='b'; actions=@(@{type='filesystem'; op='remove'; path='X'; recurse=$false}, @{type='filesystem'; op='remove'; path='Y'; recurse=$false}) }
            )
        }
        $resolved = @{ 'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' }; 'b' = [pscustomobject]@{ ItemId='b'; EffectiveState='apply' } }
        Invoke-Tiny11ApplyActions -Catalog $catalog -ResolvedSelections $resolved -ScratchDir 'C:\s' -ProgressCallback {}
        Should -Invoke -CommandName 'Invoke-Tiny11Action' -ModuleName 'Tiny11.Worker' -Times 3
    }
    It "invokes the progress callback per item" {
        $catalog = [pscustomobject]@{ Items = @(@{ id='a'; actions=@() }) }
        $resolved = @{ 'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' } }
        $script:calls = 0
        Invoke-Tiny11ApplyActions -Catalog $catalog -ResolvedSelections $resolved -ScratchDir 'C:\s' -ProgressCallback { $script:calls++ }
        $script:calls | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement worker**

Create `src/Tiny11.Worker.psm1`:

```powershell
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Actions.psm1"        -Force -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Hives.psm1"          -Force -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Iso.psm1"            -Force -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Autounattend.psm1"   -Force -DisableNameChecking

function Get-Tiny11ApplyItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Catalog, [Parameter(Mandatory)][hashtable]$ResolvedSelections)
    $Catalog.Items | Where-Object { $ResolvedSelections[$_.id].EffectiveState -eq 'apply' }
}

function Invoke-Tiny11ApplyActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][hashtable]$ResolvedSelections,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][scriptblock]$ProgressCallback
    )
    $items = Get-Tiny11ApplyItems -Catalog $Catalog -ResolvedSelections $ResolvedSelections
    $total = $items.Count; $i = 0
    foreach ($item in $items) {
        $i++
        & $ProgressCallback @{ phase='apply'; step="$i of $total : $($item.displayName)"; percent=([int](($i / [math]::Max(1,$total)) * 100)); itemId=$item.id }
        foreach ($action in $item.actions) { Invoke-Tiny11Action -Action $action -ScratchDir $ScratchDir }
    }
}

function Invoke-Tiny11BuildPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][bool]$UnmountSource,
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][hashtable]$ResolvedSelections,
        [Parameter(Mandatory)][scriptblock]$ProgressCallback,
        [Parameter()]$CancellationToken = $null
    )

    function CheckCancel { if ($CancellationToken -and $CancellationToken.IsCancellationRequested) { throw "Build cancelled by user" } }

    $progress = { param($p) & $ProgressCallback $p }
    & $progress @{ phase='start'; step='Mounting source'; percent=0 }

    $source = Mount-Tiny11Source -InputPath $Source
    try {
        $sourceRoot = "$($source.DriveLetter):\"
        if (-not (Test-Path "$sourceRoot\sources\install.wim") -and -not (Test-Path "$sourceRoot\sources\install.esd")) {
            throw "No install.wim or install.esd at $sourceRoot\sources"
        }
        CheckCancel

        & $progress @{ phase='copy'; step='Copying ISO contents'; percent=5 }
        $tinyDir = Join-Path $ScratchDir 'tiny11'
        $scratchImg = Join-Path $ScratchDir 'scratchdir'
        New-Item -ItemType Directory -Force -Path "$tinyDir\sources" | Out-Null
        New-Item -ItemType Directory -Force -Path $scratchImg | Out-Null
        Copy-Item -Path "$sourceRoot*" -Destination $tinyDir -Recurse -Force | Out-Null
        CheckCancel

        if ((Test-Path "$tinyDir\sources\install.esd") -and -not (Test-Path "$tinyDir\sources\install.wim")) {
            & $progress @{ phase='convert'; step='Converting install.esd -> install.wim'; percent=10 }
            Export-WindowsImage -SourceImagePath "$tinyDir\sources\install.esd" -SourceIndex $ImageIndex -DestinationImagePath "$tinyDir\sources\install.wim" -CompressionType Maximum -CheckIntegrity | Out-Null
            Remove-Item "$tinyDir\sources\install.esd" -Force | Out-Null
        }
        CheckCancel

        & $progress @{ phase='mount'; step='Mounting install.wim'; percent=15 }
        Set-ItemProperty -Path "$tinyDir\sources\install.wim" -Name IsReadOnly -Value $false
        Mount-WindowsImage -ImagePath "$tinyDir\sources\install.wim" -Index $ImageIndex -Path $scratchImg | Out-Null

        & $progress @{ phase='hives'; step='Loading offline registry hives'; percent=20 }
        Mount-Tiny11AllHives -ScratchDir $scratchImg

        Invoke-Tiny11ApplyActions -Catalog $Catalog -ResolvedSelections $ResolvedSelections -ScratchDir $scratchImg -ProgressCallback $ProgressCallback
        CheckCancel

        & $progress @{ phase='hives-unload'; step='Unloading hives'; percent=70 }
        Dismount-Tiny11AllHives

        & $progress @{ phase='cleanup-image'; step='dism /Cleanup-Image /StartComponentCleanup /ResetBase'; percent=75 }
        & 'dism.exe' "/Image:$scratchImg" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' | Out-Null

        & $progress @{ phase='wim-save'; step='Dismounting install.wim (save)'; percent=80 }
        Dismount-WindowsImage -Path $scratchImg -Save | Out-Null

        & $progress @{ phase='export'; step='Exporting install.wim with recovery compression'; percent=85 }
        & 'dism.exe' '/Export-Image' "/SourceImageFile:$tinyDir\sources\install.wim" "/SourceIndex:$ImageIndex" "/DestinationImageFile:$tinyDir\sources\install2.wim" '/Compress:recovery' | Out-Null
        Remove-Item -Path "$tinyDir\sources\install.wim" -Force | Out-Null
        Rename-Item -Path "$tinyDir\sources\install2.wim" -NewName 'install.wim' | Out-Null

        & $progress @{ phase='bootwim'; step='Applying hardware-bypass tweaks to boot.wim'; percent=88 }
        $bootWim = "$tinyDir\sources\boot.wim"
        Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false
        Mount-WindowsImage -ImagePath $bootWim -Index 2 -Path $scratchImg | Out-Null
        Mount-Tiny11AllHives -ScratchDir $scratchImg
        $hwItems = $Catalog.Items | Where-Object { $_.category -eq 'hardware-bypass' -and $ResolvedSelections[$_.id].EffectiveState -eq 'apply' }
        foreach ($item in $hwItems) {
            foreach ($action in $item.actions) { Invoke-Tiny11Action -Action $action -ScratchDir $scratchImg }
        }
        Dismount-Tiny11AllHives
        Dismount-WindowsImage -Path $scratchImg -Save | Out-Null

        & $progress @{ phase='autounattend'; step='Rendering autounattend.xml'; percent=92 }
        $tplLocal = Join-Path (Split-Path $Catalog.Path) '..\autounattend.template.xml' | Resolve-Path | Select-Object -ExpandProperty Path
        $tplResult = Get-Tiny11AutounattendTemplate -LocalPath $tplLocal
        $bindings = Get-Tiny11AutounattendBindings -ResolvedSelections $ResolvedSelections -ImageIndex $ImageIndex
        $rendered = Render-Tiny11Autounattend -Template $tplResult.Content -Bindings $bindings
        Set-Content -Path "$tinyDir\autounattend.xml" -Value $rendered -Encoding UTF8

        & $progress @{ phase='oscdimg-resolve'; step='Resolving oscdimg.exe'; percent=94 }
        $oscdimgCache = Join-Path (Split-Path $Catalog.Path) '..\dependencies\oscdimg' | Resolve-Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path
        if (-not $oscdimgCache) {
            $oscdimgCache = (New-Item -ItemType Directory -Force -Path (Join-Path $ScratchDir 'oscdimg-cache')).FullName
        }
        $oscdimg = Resolve-Tiny11Oscdimg -CacheDir $oscdimgCache

        & $progress @{ phase='iso'; step='Building ISO'; percent=96 }
        & $oscdimg '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$tinyDir\boot\etfsboot.com#pEF,e,b$tinyDir\efi\microsoft\boot\efisys.bin" $tinyDir $OutputPath | Out-Null

        & $progress @{ phase='complete'; step='Build complete'; percent=100; outputPath=$OutputPath }
    } finally {
        if ($source.MountedByUs -and $UnmountSource) {
            & $progress @{ phase='unmount-source'; step='Unmounting source ISO'; percent=99 }
            Dismount-Tiny11Source -IsoPath $source.IsoPath -MountedByUs:$source.MountedByUs -ForceUnmount:$UnmountSource
        }
        $tinyDir = Join-Path $ScratchDir 'tiny11'
        $scratchImg = Join-Path $ScratchDir 'scratchdir'
        if (Test-Path $tinyDir)    { Remove-Item -Path $tinyDir    -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $scratchImg) { Remove-Item -Path $scratchImg -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-Tiny11Oscdimg {
    [CmdletBinding()]
    param([string]$CacheDir)
    $hostArch = $env:PROCESSOR_ARCHITECTURE
    $adkPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArch\Oscdimg\oscdimg.exe"
    if (Test-Path $adkPath) { return $adkPath }
    if (-not $CacheDir) { return $null }
    $local = Join-Path $CacheDir 'oscdimg.exe'
    if (Test-Path $local) { return $local }
    $url = 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe'
    Invoke-WebRequest -Uri $url -OutFile $local
    return $local
}

Export-ModuleMember -Function Get-Tiny11ApplyItems, Invoke-Tiny11ApplyActions, Invoke-Tiny11BuildPipeline, Resolve-Tiny11Oscdimg
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Worker.psm1 tests/Tiny11.Worker.Tests.ps1
git commit -m "feat(worker): add build pipeline orchestrator with progress callbacks"
```

---

## Task 13: Param surface + self-elevation fix + scripted entry point

**Files:**
- Modify: `tiny11maker.ps1` (full rewrite)
- Create: `tests/Tiny11.Orchestrator.Tests.ps1`

- [ ] **Step 1: Write tests for the elevation arg-forwarding helper**

Create `tests/Tiny11.Orchestrator.Tests.ps1`:

```powershell
Describe "Build-RelaunchArgs" {
    It "forwards bound parameters with proper quoting" {
        . "$PSScriptRoot/../tiny11maker.ps1" -Internal
        $bound = [System.Management.Automation.PSBoundParametersDictionary]::new()
        $bound.Add('Source', 'C:\some path\Win11.iso')
        $bound.Add('Config', 'profile.json')
        $bound.Add('NonInteractive', [switch]$true)
        $args = Build-RelaunchArgs -Bound $bound -ScriptPath 'C:\foo\tiny11maker.ps1'
        $args | Should -Match '-Source "C:\\some path\\Win11.iso"'
        $args | Should -Match '-Config "profile.json"'
        $args | Should -Match '-NonInteractive'
        $args | Should -Match '-File "C:\\foo\\tiny11maker.ps1"'
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Rewrite tiny11maker.ps1**

Replace `tiny11maker.ps1` content with:

```powershell
<#
.SYNOPSIS
    tiny11options — interactive variant builder for Windows 11.

.DESCRIPTION
    Builds a customized Windows 11 ISO. Each removable component and tweak is a
    catalog item; the user selects which to apply. Two modes:
      Interactive: tiny11maker.ps1            (launches GUI)
      Scripted:    tiny11maker.ps1 -Source X.iso -Config profile.json [-OutputPath ...]

.PARAMETER Source
    Path to a Windows 11 .iso file, or a drive letter for an already-mounted ISO/DVD.

.PARAMETER Config
    Path to a selection profile JSON. If omitted in interactive mode, GUI runs;
    if omitted in -NonInteractive mode, defaults are used.

.PARAMETER ImageIndex
    Edition index inside install.wim (e.g. 6 for Pro). Required in -NonInteractive mode.

.PARAMETER ScratchDir
    Working directory; needs ~10 GB free. Defaults to $PSScriptRoot.

.PARAMETER OutputPath
    Where to write the resulting ISO. Defaults to <ScratchDir>\tiny11.iso.

.PARAMETER NonInteractive
    Suppresses the GUI. Implied if both -Source and -Config are passed.

.PARAMETER Internal
    For testing — when set, the script defines functions and exits without running the orchestrator.
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Config,
    [int]$ImageIndex,
    [string]$ScratchDir,
    [string]$OutputPath,
    [switch]$NonInteractive,
    [switch]$Internal
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($mod in @('Tiny11.Catalog','Tiny11.Selections','Tiny11.Hives','Tiny11.Actions','Tiny11.Iso','Tiny11.Autounattend','Tiny11.Worker')) {
    Import-Module "$srcDir\$mod.psm1" -Force -DisableNameChecking
}

function Build-RelaunchArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Bound, [Parameter(Mandatory)][string]$ScriptPath)
    $parts = @("-NoProfile","-File","`"$ScriptPath`"")
    foreach ($entry in $Bound.GetEnumerator()) {
        if ($entry.Key -eq 'Internal') { continue }
        $val = $entry.Value
        if ($val -is [switch]) {
            if ($val.IsPresent) { $parts += "-$($entry.Key)" }
        } else {
            $parts += "-$($entry.Key)"
            $parts += "`"$val`""
        }
    }
    $parts -join ' '
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    param([Parameter(Mandatory)] $Bound)
    $argString = Build-RelaunchArgs -Bound $Bound -ScriptPath $PSCommandPath
    Write-Output "Restarting tiny11options as admin..."
    Start-Process -FilePath 'pwsh' -ArgumentList $argString -Verb RunAs
}

if ($Internal) { return }

if (-not (Test-IsAdmin)) {
    Invoke-SelfElevate -Bound $PSBoundParameters
    exit
}

if (-not $ScratchDir) { $ScratchDir = $PSScriptRoot }
if (-not $OutputPath) { $OutputPath = Join-Path $ScratchDir 'tiny11.iso' }
$catalogPath = Join-Path $PSScriptRoot 'catalog\catalog.json'
$catalog = Get-Tiny11Catalog -Path $catalogPath

$nonInteractive = $NonInteractive -or ($Source -and $Config)

if ($nonInteractive) {
    if (-not $Source)     { throw "-NonInteractive requires -Source" }
    if (-not $ImageIndex) { throw "-NonInteractive requires -ImageIndex" }

    $selections = if ($Config) {
        Import-Tiny11Selections -Path $Config -Catalog $catalog
    } else {
        New-Tiny11Selections -Catalog $catalog
    }
    $resolved = Resolve-Tiny11Selections -Catalog $catalog -Selections $selections

    Invoke-Tiny11BuildPipeline `
        -Source $Source -ImageIndex $ImageIndex -ScratchDir $ScratchDir `
        -OutputPath $OutputPath -UnmountSource $true `
        -Catalog $catalog -ResolvedSelections $resolved `
        -ProgressCallback { param($p) Write-Output "[$($p.phase)] $($p.step) ($($p.percent)%)" }

    Write-Output "Build complete: $OutputPath"
    exit 0
}

Write-Warning "Interactive GUI not implemented yet (Phase 2). Use -Source -Config -ImageIndex for scripted mode, or wait for Phase 2."
exit 1
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add tiny11maker.ps1 tests/Tiny11.Orchestrator.Tests.ps1
git commit -m "feat(orchestrator): rewrite tiny11maker.ps1 as catalog-driven orchestrator"
```

---

## Task 14: Build the full catalog (~63 items)

**Files:**
- Modify: `catalog/catalog.json` (replace seed with full content)
- Create: `config/examples/tiny11-classic.json`, `keep-edge.json`, `minimal-removal.json`

- [ ] **Step 1: Build the full catalog.json**

Replace `catalog/catalog.json` with the complete catalog. Categories:
- `store-apps`, `xbox-and-gaming`, `communication`, `edge-and-webview`, `onedrive`, `telemetry`, `sponsored`, `copilot-ai`, `hardware-bypass`, `oobe`.

Removal items derived from the legacy `$packagePrefixes` array. Each AppX prefix becomes one item with category assigned by name. Tweak items group the legacy reg-set blocks: telemetry, sponsored apps (~15 reg keys), hardware-bypass (~8 reg keys), copilot-ai, onedrive folder backup, oobe (BypassNRO + DevHome/Outlook prevention), reserved-storage, bitlocker-auto-encryption, chat-icon, edge-uninstall-keys, teams-install-prevention, new-outlook-prevention. Plus a new `tweak-compact-install` controlling autounattend's `<Compact>` flag.

Source-of-truth: cross-reference each entry against the legacy `tiny11maker.ps1` lines 205-388 in git history. Every reg set/delete and every package prefix in the legacy script must have a catalog item that produces it when default-applied.

- [ ] **Step 2: Add completeness Pester test**

Append to `tests/Tiny11.Catalog.Tests.ps1`:

```powershell
Describe "Catalog completeness" {
    BeforeAll { $script:cat = Get-Tiny11Catalog -Path "$PSScriptRoot/../catalog/catalog.json" }
    It "has the expected 10 categories" {
        $expected = @('store-apps','xbox-and-gaming','communication','edge-and-webview','onedrive','telemetry','sponsored','copilot-ai','hardware-bypass','oobe')
        ($script:cat.Categories | ForEach-Object id) | Should -Be $expected
    }
    It "covers every package prefix from the legacy script" {
        $legacyPrefixes = @(
            'AppUp.IntelManagementandSecurityStatus','Clipchamp.Clipchamp','DolbyLaboratories.DolbyAccess',
            'DolbyLaboratories.DolbyDigitalPlusDecoderOEM','Microsoft.BingNews','Microsoft.BingSearch',
            'Microsoft.BingWeather','Microsoft.Copilot','Microsoft.Windows.CrossDevice','Microsoft.GamingApp',
            'Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.Microsoft3DViewer','Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftStickyNotes','Microsoft.MixedReality.Portal',
            'Microsoft.MSPaint','Microsoft.Office.OneNote','Microsoft.OfficePushNotificationUtility',
            'Microsoft.OutlookForWindows','Microsoft.Paint','Microsoft.People','Microsoft.PowerAutomateDesktop',
            'Microsoft.SkypeApp','Microsoft.StartExperiencesApp','Microsoft.Todos','Microsoft.Wallet',
            'Microsoft.Windows.DevHome','Microsoft.Windows.Copilot','Microsoft.Windows.Teams',
            'Microsoft.WindowsAlarms','Microsoft.WindowsCamera','microsoft.windowscommunicationsapps',
            'Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.WindowsSoundRecorder',
            'Microsoft.WindowsTerminal','Microsoft.Xbox.TCUI','Microsoft.XboxApp','Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay','Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay',
            'Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
            'MicrosoftCorporationII.MicrosoftFamily','MicrosoftCorporationII.QuickAssist',
            'MSTeams','MicrosoftTeams','Microsoft.549981C3F5F10'
        )
        $catalogPrefixes = @()
        foreach ($item in $script:cat.Items) {
            foreach ($a in $item.actions) {
                if ($a.type -eq 'provisioned-appx') { $catalogPrefixes += $a.packagePrefix }
            }
        }
        foreach ($legacy in $legacyPrefixes) {
            $catalogPrefixes | Should -Contain $legacy
        }
    }
}
```

- [ ] **Step 3: Run; pass**

If a prefix is missing, add it to `catalog.json` until the test passes.

- [ ] **Step 4: Build example profiles**

Create `config/examples/tiny11-classic.json`:

```json
{ "version": 1, "selections": {} }
```

Create `config/examples/keep-edge.json`:

```json
{
  "version": 1,
  "selections": { "remove-edge": "skip" }
}
```

Create `config/examples/minimal-removal.json`:

```json
{
  "version": 1,
  "selections": {
    "remove-clipchamp": "skip",
    "remove-windowsterminal": "skip",
    "remove-msteams": "skip",
    "remove-onedrive-setup": "skip"
  }
}
```

(Adjust item IDs to match those in the actual catalog.)

- [ ] **Step 5: Commit**

```powershell
git add catalog/catalog.json config/examples/
git commit -m "feat(catalog): build full catalog (63 items, 10 categories) + example profiles"
```

---

## Task 15: Phase 1 VM smoke test

Manual; no code changes unless issues are found.

- [ ] **Step 1: Prepare a Windows 11 ISO**

Download from Microsoft if needed.

- [ ] **Step 2: Run scripted build with classic profile**

```powershell
pwsh -NoProfile -File tiny11maker.ps1 `
    -Source 'C:\path\to\Win11.iso' `
    -Config 'config\examples\tiny11-classic.json' `
    -ImageIndex 6 `
    -OutputPath 'C:\out\tiny11-classic.iso' `
    -NonInteractive
```

Expected: completes in 15-30 min; `tiny11-classic.iso` exists; scratch is cleaned up.

- [ ] **Step 3: Boot in Hyper-V Gen2**

4 GB RAM, 60 GB dynamic disk, attach ISO, boot. Expected: install completes, desktop appears, Start menu opens, **Start menu search returns results** (validates WebView2 Runtime survived), **Widgets pane opens** (further Runtime validation).

- [ ] **Step 4: Verify catalog claims**

In the VM:
- Search "edge" — no Edge browser.
- Settings → Apps → Installed apps — no Clipchamp, no Cortana, no Xbox apps, no OneDrive setup, no Teams, no Mail+Calendar.
- Settings → Privacy & security → Diagnostics & feedback — telemetry minimal.
- `Get-AppxProvisionedPackage -Online | Where-Object PackageName -like '*Clipchamp*'` returns nothing.

- [ ] **Step 5: Run keep-edge profile**

```powershell
pwsh -NoProfile -File tiny11maker.ps1 -Source 'C:\path\to\Win11.iso' -Config 'config\examples\keep-edge.json' -ImageIndex 6 -OutputPath 'C:\out\tiny11-keep-edge.iso' -NonInteractive
```

- [ ] **Step 6: Boot keep-edge ISO; verify Edge present**

Edge browser is installed and launches normally; otherwise same expectations.

- [ ] **Step 7: Document any issues found**

If anything fails, capture in todo file, fix in separate commits before tagging Phase 1 done.

---

# Phase 2: GUI

End state: `tiny11maker.ps1` with no args opens a WebView2-hosted wizard; same ISO is produced as the equivalent scripted run.

---

## Task 16: WebView2 SDK fetch + Runtime detection

**Files:**
- Create: `src/Tiny11.WebView2.psm1`
- Create: `tests/Tiny11.WebView2.Tests.ps1`

- [ ] **Step 1: Write failing tests**

```powershell
# tests/Tiny11.WebView2.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.WebView2'

Describe "Get-Tiny11WebView2SdkPath" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }
    It "returns paths under cache dir" {
        $r = Get-Tiny11WebView2SdkPath -CacheRoot $script:tmp
        $r.CoreDll   | Should -Match 'Microsoft\.Web\.WebView2\.Core\.dll$'
        $r.WpfDll    | Should -Match 'Microsoft\.Web\.WebView2\.Wpf\.dll$'
        $r.NativeDll | Should -Match 'WebView2Loader\.dll$'
    }
}

Describe "Install-Tiny11WebView2Sdk" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }
    It "no-ops when files already present" {
        $r = Get-Tiny11WebView2SdkPath -CacheRoot $script:tmp
        New-Item -ItemType File -Path $r.CoreDll, $r.WpfDll, $r.NativeDll -Force | Out-Null
        Mock -CommandName 'Invoke-WebRequest' -MockWith { } -ModuleName 'Tiny11.WebView2'
        Install-Tiny11WebView2Sdk -CacheRoot $script:tmp
        Should -Invoke -CommandName 'Invoke-WebRequest' -ModuleName 'Tiny11.WebView2' -Times 0
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.WebView2.psm1`:

```powershell
Set-StrictMode -Version Latest

$PinnedVersion = '1.0.2535.41'
$NupkgUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$PinnedVersion"

function Get-Tiny11WebView2SdkPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CacheRoot)
    $verDir = Join-Path $CacheRoot $PinnedVersion
    [pscustomobject]@{
        VersionDir = $verDir
        CoreDll    = Join-Path $verDir 'Microsoft.Web.WebView2.Core.dll'
        WpfDll     = Join-Path $verDir 'Microsoft.Web.WebView2.Wpf.dll'
        NativeDll  = Join-Path $verDir 'WebView2Loader.dll'
    }
}

function Install-Tiny11WebView2Sdk {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CacheRoot)
    $paths = Get-Tiny11WebView2SdkPath -CacheRoot $CacheRoot
    if ((Test-Path $paths.CoreDll) -and (Test-Path $paths.WpfDll) -and (Test-Path $paths.NativeDll)) {
        return $paths
    }
    New-Item -ItemType Directory -Force -Path $paths.VersionDir | Out-Null
    $nupkg = Join-Path $paths.VersionDir 'webview2.nupkg'
    Invoke-WebRequest -Uri $NupkgUrl -OutFile $nupkg
    $extractDir = Join-Path $paths.VersionDir '_extract'
    Expand-Archive -Path $nupkg -DestinationPath $extractDir -Force
    Copy-Item -Path "$extractDir\lib\netstandard2.0\Microsoft.Web.WebView2.Core.dll" -Destination $paths.CoreDll -Force
    Copy-Item -Path "$extractDir\lib\netstandard2.0\Microsoft.Web.WebView2.Wpf.dll"  -Destination $paths.WpfDll  -Force
    Copy-Item -Path "$extractDir\runtimes\win-x64\native\WebView2Loader.dll"          -Destination $paths.NativeDll -Force
    Remove-Item -Path $extractDir -Recurse -Force
    Remove-Item -Path $nupkg -Force
    $paths
}

function Test-Tiny11WebView2RuntimeInstalled {
    $key64 = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $key32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $userKey = 'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach ($k in @($key64, $key32, $userKey)) {
        if (Test-Path $k) {
            $val = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).pv
            if ($val) { return $true }
        }
    }
    $false
}

Export-ModuleMember -Function Get-Tiny11WebView2SdkPath, Install-Tiny11WebView2Sdk, Test-Tiny11WebView2RuntimeInstalled
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.WebView2.psm1 tests/Tiny11.WebView2.Tests.ps1
git commit -m "feat(webview2): add SDK fetch + Runtime detection"
```

---

## Task 17: Bridge module (PS↔WebView message dispatch)

**Files:**
- Create: `src/Tiny11.Bridge.psm1`
- Create: `tests/Tiny11.Bridge.Tests.ps1`

- [ ] **Step 1: Write tests**

```powershell
# tests/Tiny11.Bridge.Tests.ps1
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Bridge'

Describe "ConvertTo-Tiny11BridgeMessage" {
    It "round-trips type + payload" {
        $json = ConvertTo-Tiny11BridgeMessage -Type 'iso-validated' -Payload @{ editions = @(1,2,3) }
        $obj = $json | ConvertFrom-Json
        $obj.type | Should -Be 'iso-validated'
        $obj.editions.Count | Should -Be 3
    }
}

Describe "Invoke-Tiny11BridgeHandler" {
    It "dispatches by type" {
        $registry = @{ 'ping' = { param($msg) "pong:$($msg.value)" } }
        Invoke-Tiny11BridgeHandler -Registry $registry -Message ([pscustomobject]@{ type='ping'; value=42 }) | Should -Be 'pong:42'
    }
    It "throws on unknown type" {
        { Invoke-Tiny11BridgeHandler -Registry @{} -Message ([pscustomobject]@{ type='ghost' }) } | Should -Throw "*ghost*"
    }
}
```

- [ ] **Step 2: Confirm fail**

- [ ] **Step 3: Implement**

Create `src/Tiny11.Bridge.psm1`:

```powershell
Set-StrictMode -Version Latest

function ConvertTo-Tiny11BridgeMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Type, [hashtable]$Payload = @{})
    $combined = [ordered]@{ type = $Type }
    foreach ($k in $Payload.Keys) { $combined[$k] = $Payload[$k] }
    $combined | ConvertTo-Json -Depth 10 -Compress
}

function Invoke-Tiny11BridgeHandler {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Registry, [Parameter(Mandatory)] $Message)
    if (-not $Registry.ContainsKey($Message.type)) {
        throw "No handler registered for message type: $($Message.type)"
    }
    & $Registry[$Message.type] $Message
}

Export-ModuleMember -Function ConvertTo-Tiny11BridgeMessage, Invoke-Tiny11BridgeHandler
```

- [ ] **Step 4: Run; pass**

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Bridge.psm1 tests/Tiny11.Bridge.Tests.ps1
git commit -m "feat(bridge): add message-protocol helpers"
```

---

## Task 18: WPF window host + Show-Tiny11Wizard

**Files:**
- Modify: `src/Tiny11.WebView2.psm1` (append `Show-Tiny11Wizard`, `Set-Tiny11WizardWindow`, getters)

- [ ] **Step 1: Append Show-Tiny11Wizard**

Append to `src/Tiny11.WebView2.psm1`:

```powershell
function Set-Tiny11WizardWindow { param($Window, $WebView) $script:wizardWindow = $Window; $script:wizardWebView = $WebView }
function Get-Tiny11WizardWindow  { $script:wizardWindow }
function Get-Tiny11WizardWebView { $script:wizardWebView }

function Show-Tiny11Wizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UiDir,
        [Parameter(Mandatory)][string]$CatalogJson,
        [Parameter(Mandatory)][hashtable]$MessageHandlers,
        [Parameter(Mandatory)][string]$SdkCacheRoot
    )

    if (-not (Test-Tiny11WebView2RuntimeInstalled)) {
        throw "Microsoft Edge WebView2 Runtime is required. On Windows 11 this is preinstalled; on Windows 10 install from https://developer.microsoft.com/microsoft-edge/webview2/."
    }

    $sdk = Install-Tiny11WebView2Sdk -CacheRoot $SdkCacheRoot

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -Path $sdk.CoreDll
    Add-Type -Path $sdk.WpfDll

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;assembly=Microsoft.Web.WebView2.Wpf"
        Title="tiny11options" Width="900" Height="700"
        WindowStartupLocation="CenterScreen"
        MinWidth="700" MinHeight="500">
    <Grid>
        <wv2:WebView2 x:Name="WV"/>
    </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $wv = $window.FindName('WV')
    Set-Tiny11WizardWindow $window $wv

    $userdata = Join-Path $sdk.VersionDir 'userdata'
    New-Item -ItemType Directory -Path $userdata -Force | Out-Null
    $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $userdata)
    $env = $envTask.GetAwaiter().GetResult()
    $wv.EnsureCoreWebView2Async($env).GetAwaiter().GetResult()

    $wv.CoreWebView2.SetVirtualHostNameToFolderMapping(
        'ui.tiny11options', $UiDir,
        [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::DenyCors
    )

    $initScript = "window.__tinyCatalog = $CatalogJson;"
    $wv.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync($initScript) | Out-Null

    $wv.add_WebMessageReceived({
        param($sender, $eventArgs)
        $msg = $eventArgs.WebMessageAsJson | ConvertFrom-Json
        try {
            $reply = Invoke-Tiny11BridgeHandler -Registry $MessageHandlers -Message $msg
            if ($reply) {
                $window.Dispatcher.Invoke([action]{ $wv.CoreWebView2.PostWebMessageAsString($reply) })
            }
        } catch {
            $errReply = ConvertTo-Tiny11BridgeMessage -Type 'handler-error' -Payload @{ message = "$_" }
            $window.Dispatcher.Invoke([action]{ $wv.CoreWebView2.PostWebMessageAsString($errReply) })
        }
    })

    $wv.Source = [Uri]'https://ui.tiny11options/index.html'
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Show-Tiny11Wizard, Set-Tiny11WizardWindow, Get-Tiny11WizardWindow, Get-Tiny11WizardWebView
```

- [ ] **Step 2: Manual smoke test**

Create a temporary `ui/index.html` with `<h1>tiny11options</h1>` and run:

```powershell
Import-Module ./src/Tiny11.WebView2.psm1 -Force
Import-Module ./src/Tiny11.Bridge.psm1 -Force
Show-Tiny11Wizard -UiDir (Resolve-Path ./ui).Path -CatalogJson '{}' -MessageHandlers @{ close = { ConvertTo-Tiny11BridgeMessage -Type 'noop' } } -SdkCacheRoot (New-Item -ItemType Directory -Force -Path ./dependencies/webview2).FullName
```

Expected: window opens with the H1, close window, PS returns.

- [ ] **Step 3: Commit**

```powershell
git add src/Tiny11.WebView2.psm1
git commit -m "feat(webview2): host WPF window with WebView2 control"
```

---

## Task 19: HTML/CSS/JS scaffold + DOM helpers (no innerHTML for user data)

**Files:**
- Create: `ui/index.html`, `ui/style.css`, `ui/app.js`

The JS uses `document.createElement` + `textContent` for all user-controlled content. A small `el(tag, attrs, ...children)` helper handles construction. No `innerHTML` is used at all.

- [ ] **Step 1: Create the wizard shell HTML**

Create `ui/index.html`:

```html
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
    <meta charset="UTF-8">
    <title>tiny11options</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <header class="breadcrumb">
        <span data-step="source"    class="active">1. Source</span>
        <span data-step="customize">2. Customize</span>
        <span data-step="build">3. Build</span>
    </header>
    <main id="content"></main>
    <footer class="actions">
        <button id="back-btn" disabled>&lt; Back</button>
        <button id="next-btn" disabled>Next &gt;</button>
    </footer>
    <script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create style.css**

Create `ui/style.css` with the modern flat / Fluent-inspired styling described in the spec (Section 5). Cover: light + dark themes via `data-theme`, breadcrumb highlight (current step), card grid for categories, drill-in list, buttons (primary/secondary/disabled), error banner, locked state for checkboxes (greyed + 🔒 icon), progress bar. ~150 lines. Use system fonts (`Segoe UI Variable`); no web-font load.

- [ ] **Step 3: Create app.js — scaffold + DOM helpers**

Create `ui/app.js`:

```javascript
"use strict";

const ps   = (msg) => window.chrome.webview.postMessage(JSON.stringify(msg));
const onPs = (cb)  => window.chrome.webview.addEventListener('message', e => cb(JSON.parse(e.data)));

// DOM construction helper. children may be strings (textContent) or DOM nodes.
function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    if (attrs) {
        for (const [k, v] of Object.entries(attrs)) {
            if (v == null || v === false) continue;
            if (k === 'class')          e.className = v;
            else if (k === 'data')       Object.entries(v).forEach(([dk, dv]) => e.dataset[dk] = dv);
            else if (k === 'checked')    e.checked = !!v;
            else if (k === 'disabled')   e.disabled = !!v;
            else if (k === 'value')      e.value = v;
            else if (k.startsWith('on')) e.addEventListener(k.slice(2).toLowerCase(), v);
            else                          e.setAttribute(k, v);
        }
    }
    for (const c of children.flat()) {
        if (c == null || c === false) continue;
        if (typeof c === 'string' || typeof c === 'number') {
            e.appendChild(document.createTextNode(String(c)));
        } else {
            e.appendChild(c);
        }
    }
    return e;
}

function clear(parent) {
    while (parent.firstChild) parent.removeChild(parent.firstChild);
}

const state = {
    catalog: window.__tinyCatalog,
    selections: {},
    step: 'source',
    source: null,
    edition: null,
    editions: null,
    scratchDir: null,
    outputPath: null,
    unmountSource: true,
    drilledCategory: null,
    building: false,
    completed: null,
    progress: null,
};

function renderStep() {
    const root = document.getElementById('content');
    clear(root);
    document.querySelectorAll('.breadcrumb span').forEach(s => {
        s.classList.toggle('active', s.dataset.step === state.step);
    });
    if (state.step === 'source')    root.appendChild(renderSourceStep());
    if (state.step === 'customize') root.appendChild(renderCustomizeStep());
    if (state.step === 'build')     root.appendChild(renderBuildStep());
    updateNav();
}

function updateNav() {
    document.getElementById('back-btn').disabled = state.step === 'source' || state.building || !!state.completed;
    document.getElementById('next-btn').disabled = !canAdvance() || state.building || !!state.completed;
}

function canAdvance() {
    if (state.step === 'source')    return !!state.source && state.edition !== null;
    if (state.step === 'customize') return true;
    return false;
}

document.getElementById('back-btn').addEventListener('click', () => {
    if (state.step === 'customize') state.step = 'source';
    else if (state.step === 'build') state.step = 'customize';
    state.drilledCategory = null;
    renderStep();
});
document.getElementById('next-btn').addEventListener('click', () => {
    if (state.step === 'source')    state.step = 'customize';
    else if (state.step === 'customize') state.step = 'build';
    renderStep();
});

// Stubs replaced in tasks 20-22:
function renderSourceStep()    { return el('p', null, 'Source step (task 20)'); }
function renderCustomizeStep() { return el('p', null, 'Customize step (tasks 21)'); }
function renderBuildStep()     { return el('p', null, 'Build step (task 22)'); }

document.addEventListener('DOMContentLoaded', renderStep);
```

- [ ] **Step 4: Commit**

```powershell
git add ui/
git commit -m "feat(ui): scaffold wizard shell with DOM-builder helpers (no innerHTML)"
```

---

## Task 20: Step 1 — source picker

**Files:**
- Modify: `ui/app.js` (replace `renderSourceStep`)

- [ ] **Step 1: Replace renderSourceStep**

In `ui/app.js`, replace the `renderSourceStep` stub with:

```javascript
function renderSourceStep() {
    const editionsOptions = (state.editions || []).map(e =>
        el('option', { value: e.index, selected: state.edition === e.index }, `${e.name} (index ${e.index})`)
    );

    const errorBanner = el('div', { id: 'src-error', class: 'error hidden' });

    const section = el('section', { class: 'form' },
        el('label', null, 'Windows 11 ISO'),
        el('div', { class: 'row' },
            el('input', {
                id: 'src-input', type: 'text', value: state.source || '',
                placeholder: 'C:\\path\\to\\Win11.iso or drive letter (E:)',
                onchange: e => {
                    state.source = e.target.value;
                    state.editions = null;
                    state.edition = null;
                    ps({ type: 'validate-iso', path: state.source });
                    renderStep();
                }
            }),
            el('button', { id: 'src-browse', onclick: () => ps({ type: 'browse-iso' }) }, 'Browse...')
        ),
        errorBanner,
        el('label', null, 'Edition'),
        el('select', {
            id: 'edition-select',
            disabled: !state.editions,
            onchange: e => { state.edition = parseInt(e.target.value, 10); updateNav(); }
        }, editionsOptions),
        el('label', null, 'Scratch directory'),
        el('div', { class: 'row' },
            el('input', {
                id: 'scratch-input', type: 'text', value: state.scratchDir || '',
                onchange: e => state.scratchDir = e.target.value
            }),
            el('button', { onclick: () => ps({ type: 'browse-scratch' }) }, 'Browse...')
        ),
        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'unmount-source', type: 'checkbox',
                checked: state.unmountSource,
                onchange: e => state.unmountSource = e.target.checked
            }),
            'Unmount source ISO when build finishes'
        )
    );
    return section;
}
```

- [ ] **Step 2: Add the global onPs handler for source-step messages**

Add at the end of `ui/app.js`:

```javascript
onPs(msg => {
    if (msg.type === 'iso-validated') {
        state.editions = msg.editions;
        state.edition = (msg.editions[0] && msg.editions[0].index) || null;
        state.source = msg.path || state.source;
        renderStep();
    } else if (msg.type === 'iso-error') {
        const banner = document.getElementById('src-error');
        if (banner) {
            banner.classList.remove('hidden');
            banner.textContent = msg.message;
        }
    } else if (msg.type === 'browse-result') {
        if (msg.field === 'source')  { state.source = msg.path; renderStep(); ps({ type: 'validate-iso', path: msg.path }); }
        if (msg.field === 'scratch') { state.scratchDir = msg.path; renderStep(); }
        if (msg.field === 'output')  { state.outputPath = msg.path; renderStep(); }
    } else if (msg.type === 'profile-loaded') {
        state.selections = {};
        for (const [k, v] of Object.entries(msg.selections)) state.selections[k] = v;
        renderStep();
    }
});
```

- [ ] **Step 3: Commit**

```powershell
git add ui/app.js
git commit -m "feat(ui): implement Step 1 source picker"
```

---

## Task 21: Step 2 — categories + drill-in + reconcile/lock

**Files:**
- Modify: `ui/app.js` (replace `renderCustomizeStep`)

- [ ] **Step 1: Add reconcile + render**

Replace the `renderCustomizeStep` stub and add helpers:

```javascript
function buildSelectionsIfEmpty() {
    if (Object.keys(state.selections).length > 0) return;
    state.catalog.items.forEach(it => state.selections[it.id] = it.default);
}

function reconcile() {
    const pinnedBy = {};
    state.catalog.items.forEach(it => {
        if (state.selections[it.id] === 'skip') {
            (it.runtimeDepsOn || []).forEach(dep => {
                if (!pinnedBy[dep]) pinnedBy[dep] = [];
                pinnedBy[dep].push(it.id);
            });
        }
    });
    const resolved = {};
    state.catalog.items.forEach(it => {
        const locked = !!pinnedBy[it.id];
        resolved[it.id] = {
            user: state.selections[it.id],
            effective: locked ? 'skip' : state.selections[it.id],
            locked,
            lockedBy: pinnedBy[it.id] || [],
        };
    });
    return resolved;
}

function countsByCategory(resolved) {
    const out = {};
    state.catalog.categories.forEach(c => {
        const items = state.catalog.items.filter(i => i.category === c.id);
        out[c.id] = {
            applied: items.filter(i => resolved[i.id].effective === 'apply').length,
            total: items.length
        };
    });
    return out;
}

function renderCustomizeStep() {
    buildSelectionsIfEmpty();
    const resolved = reconcile();
    if (state.drilledCategory) return renderDrillin(state.drilledCategory, resolved);

    const counts = countsByCategory(resolved);
    const totalApplied = state.catalog.items.filter(i => resolved[i.id].effective === 'apply').length;

    const cards = state.catalog.categories.map(c => {
        const cnt = counts[c.id];
        const indicator = cnt.applied === cnt.total ? '[✓]' : cnt.applied === 0 ? '[ ]' : '[~]';
        return el('div', {
            class: 'card',
            data: { cat: c.id },
            onclick: () => { state.drilledCategory = c.id; renderStep(); }
        },
            el('h3', null, c.displayName),
            el('p',  null, c.description),
            el('span', { class: 'cat-count' }, `${indicator} ${cnt.applied}/${cnt.total}`)
        );
    });

    return el('section', { class: 'customize' },
        el('div', { class: 'row' },
            el('input', { id: 'search', type: 'text', placeholder: 'Search...' }),
            el('span', { class: 'counter' }, `Items applied: ${totalApplied}/${state.catalog.items.length}`)
        ),
        el('div', { class: 'row' },
            el('button', { onclick: () => ps({ type: 'save-profile-request', selections: state.selections }) }, 'Save profile...'),
            el('button', { onclick: () => ps({ type: 'load-profile-request' }) }, 'Load profile...'),
            el('button', { onclick: () => { state.selections = {}; renderStep(); } }, 'Reset to defaults')
        ),
        el('div', { class: 'card-grid' }, cards)
    );
}

function renderDrillin(catId, resolved) {
    const cat = state.catalog.categories.find(c => c.id === catId);
    const items = state.catalog.items.filter(i => i.category === catId);

    const itemElements = items.map(it => {
        const r = resolved[it.id];
        const liChildren = [
            el('input', {
                type: 'checkbox',
                checked: r.effective === 'apply',
                disabled: r.locked,
                data: { id: it.id },
                onchange: ev => {
                    state.selections[it.id] = ev.target.checked ? 'apply' : 'skip';
                    renderStep();
                }
            }),
            el('span', { class: 'item-name' }, it.displayName),
            el('p', { class: 'item-desc' }, it.description)
        ];
        if (r.locked) {
            liChildren.push(el('p', { class: 'lock' }, `🔒 Locked — kept because: ${r.lockedBy.join(', ')}`));
        }
        return el('li', { class: r.locked ? 'locked' : '' }, ...liChildren);
    });

    return el('section', { class: 'drill' },
        el('button', {
            onclick: () => { state.drilledCategory = null; renderStep(); }
        }, '< Back to categories'),
        el('h2', null, cat.displayName),
        el('ul', { class: 'item-list' }, itemElements)
    );
}
```

- [ ] **Step 2: Commit**

```powershell
git add ui/app.js
git commit -m "feat(ui): implement Step 2 categories + drill-in + reconcile UI"
```

---

## Task 22: Step 3 — build summary + output picker + progress

**Files:**
- Modify: `ui/app.js` (replace `renderBuildStep`)

- [ ] **Step 1: Replace renderBuildStep + add progress/complete views**

```javascript
function renderBuildStep() {
    if (state.building) return renderProgress();
    if (state.completed) return renderComplete();

    const resolved = reconcile();
    const totalApplied = state.catalog.items.filter(i => resolved[i.id].effective === 'apply').length;
    const editionLabel = (state.editions || []).find(e => e.index === state.edition);

    return el('section', { class: 'build' },
        el('h2', null, 'Ready to build'),
        el('dl', null,
            el('dt', null, 'Source'),     el('dd', null, state.source || ''),
            el('dt', null, 'Edition'),    el('dd', null, editionLabel ? editionLabel.name : String(state.edition || '')),
            el('dt', null, 'Scratch'),    el('dd', null, state.scratchDir || ''),
            el('dt', null, 'Output ISO'),
            el('dd', { class: 'row' },
                el('input', {
                    id: 'out-input', type: 'text', value: state.outputPath || '',
                    onchange: e => state.outputPath = e.target.value
                }),
                el('button', { onclick: () => ps({ type: 'browse-output' }) }, 'Browse...')
            ),
            el('dt', null, 'Changes'), el('dd', null, `${totalApplied} items applied`)
        ),
        el('button', {
            class: 'primary',
            onclick: () => {
                state.building = true;
                renderStep();
                ps({
                    type: 'build',
                    source: state.source,
                    imageIndex: state.edition,
                    scratchDir: state.scratchDir,
                    outputPath: state.outputPath,
                    unmountSource: state.unmountSource,
                    selections: state.selections,
                });
            }
        }, 'Build ISO')
    );
}

function renderProgress() {
    const p = state.progress || {};
    const progressBar = el('progress', { max: 100, value: p.percent || 0 });
    return el('section', { class: 'progress' },
        el('h2', null, 'Building tiny11 image...'),
        progressBar,
        el('p', null, `Phase: ${p.phase || '—'}`),
        el('p', null, `Step: ${p.step || '—'}`),
        el('button', { onclick: () => ps({ type: 'cancel' }) }, 'Cancel build')
    );
}

function renderComplete() {
    const c = state.completed;
    return el('section', { class: 'complete' },
        el('h2', null, 'Build complete'),
        el('p', null, `Output: ${c.outputPath}`),
        el('button', { onclick: () => ps({ type: 'open-folder', path: c.outputPath }) }, 'Open output folder'),
        el('button', { onclick: () => ps({ type: 'close' }) }, 'Close')
    );
}

// Extend the onPs handler from Task 20.
onPs(msg => {
    if (msg.type === 'build-progress') {
        state.progress = msg;
        renderStep();
    } else if (msg.type === 'build-complete') {
        state.building = false;
        state.completed = msg;
        renderStep();
    } else if (msg.type === 'build-error') {
        state.building = false;
        const root = document.getElementById('content');
        clear(root);
        root.appendChild(el('section', { class: 'error' },
            el('h2', null, 'Build failed'),
            el('p', null, msg.message || 'Unknown error'),
            el('button', { onclick: () => ps({ type: 'close' }) }, 'Close')
        ));
    } else if (msg.type === 'profile-saved') {
        // Optional: show a transient toast. v1 just logs.
        console.log('Profile saved:', msg.path);
    } else if (msg.type === 'handler-error') {
        console.error('Handler error:', msg.message);
    }
});
```

- [ ] **Step 2: Commit**

```powershell
git add ui/app.js
git commit -m "feat(ui): implement Step 3 build summary + progress + complete"
```

---

## Task 23: Wire bridge handlers in tiny11maker.ps1 + runspace build worker

**Files:**
- Modify: `tiny11maker.ps1` (replace the interactive stub)

- [ ] **Step 1: Replace the interactive section**

Replace the bottom of `tiny11maker.ps1` (everything after the scripted-mode `exit 0`) with:

```powershell
# Interactive (GUI) mode.
Import-Module "$srcDir\Tiny11.WebView2.psm1" -Force -DisableNameChecking
Import-Module "$srcDir\Tiny11.Bridge.psm1"   -Force -DisableNameChecking

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

$state = @{ Window = $null; Wv = $null; CancelToken = $null }

$handlers = @{
    'validate-iso' = {
        param($msg)
        try {
            $r = Mount-Tiny11Source -InputPath $msg.path
            $editions = Get-Tiny11Editions -DriveLetter $r.DriveLetter | ForEach-Object {
                @{ index = $_.ImageIndex; name = $_.ImageName; architecture = $_.Architecture; languageCode = ($_.Languages -join ',') }
            }
            Dismount-Tiny11Source -IsoPath $r.IsoPath -MountedByUs:$r.MountedByUs -ForceUnmount:$true
            ConvertTo-Tiny11BridgeMessage -Type 'iso-validated' -Payload @{ editions = $editions; path = $msg.path }
        } catch {
            ConvertTo-Tiny11BridgeMessage -Type 'iso-error' -Payload @{ message = "$_" }
        }
    }
    'browse-iso' = {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'ISO files (*.iso)|*.iso'
        if ($dlg.ShowDialog($state.Window)) {
            ConvertTo-Tiny11BridgeMessage -Type 'browse-result' -Payload @{ field='source'; path=$dlg.FileName }
        }
    }
    'browse-scratch' = {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') {
            ConvertTo-Tiny11BridgeMessage -Type 'browse-result' -Payload @{ field='scratch'; path=$dlg.SelectedPath }
        }
    }
    'browse-output' = {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'ISO files (*.iso)|*.iso'
        $dlg.FileName = 'tiny11.iso'
        if ($dlg.ShowDialog($state.Window)) {
            ConvertTo-Tiny11BridgeMessage -Type 'browse-result' -Payload @{ field='output'; path=$dlg.FileName }
        }
    }
    'save-profile-request' = {
        param($msg)
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'tiny11options profile (*.json)|*.json'
        $dlg.InitialDirectory = (Join-Path $PSScriptRoot 'config\examples')
        if ($dlg.ShowDialog($state.Window)) {
            $payload = [ordered]@{ version = 1; selections = $msg.selections } | ConvertTo-Json -Depth 5
            Set-Content -Path $dlg.FileName -Value $payload -Encoding UTF8
            ConvertTo-Tiny11BridgeMessage -Type 'profile-saved' -Payload @{ path = $dlg.FileName }
        }
    }
    'load-profile-request' = {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'tiny11options profile (*.json)|*.json'
        if ($dlg.ShowDialog($state.Window)) {
            $sel = Import-Tiny11Selections -Path $dlg.FileName -Catalog $catalog
            $obj = @{}
            foreach ($k in $sel.Keys) { $obj[$k] = $sel[$k].State }
            ConvertTo-Tiny11BridgeMessage -Type 'profile-loaded' -Payload @{ selections = $obj }
        }
    }
    'build' = {
        param($msg)
        $state.CancelToken = [System.Threading.CancellationTokenSource]::new()
        $overrides = @{}
        foreach ($k in $msg.selections.PSObject.Properties.Name) { $overrides[$k] = $msg.selections.$k }
        $sel = New-Tiny11Selections -Catalog $catalog -Overrides $overrides
        $resolved = Resolve-Tiny11Selections -Catalog $catalog -Selections $sel

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('__catalog', $catalog)
        $rs.SessionStateProxy.SetVariable('__resolved', $resolved)
        $rs.SessionStateProxy.SetVariable('__msg', $msg)
        $rs.SessionStateProxy.SetVariable('__token', $state.CancelToken.Token)
        $rs.SessionStateProxy.SetVariable('__window', $state.Window)
        $rs.SessionStateProxy.SetVariable('__wv', $state.Wv)
        $rs.SessionStateProxy.SetVariable('__src', $PSScriptRoot)

        $psWorker = [PowerShell]::Create()
        $psWorker.Runspace = $rs
        $psWorker.AddScript({
            Import-Module "$__src\src\Tiny11.Worker.psm1" -Force -DisableNameChecking
            Import-Module "$__src\src\Tiny11.Bridge.psm1" -Force -DisableNameChecking
            $cb = {
                param($p)
                $j = ConvertTo-Tiny11BridgeMessage -Type 'build-progress' -Payload $p
                $__window.Dispatcher.Invoke([action]{ $__wv.CoreWebView2.PostWebMessageAsString($j) })
            }
            try {
                $scratch = if ($__msg.scratchDir) { $__msg.scratchDir } else { $__src }
                Invoke-Tiny11BuildPipeline `
                    -Source $__msg.source -ImageIndex $__msg.imageIndex `
                    -ScratchDir $scratch -OutputPath $__msg.outputPath `
                    -UnmountSource ([bool]$__msg.unmountSource) `
                    -Catalog $__catalog -ResolvedSelections $__resolved `
                    -ProgressCallback $cb -CancellationToken $__token
                $j = ConvertTo-Tiny11BridgeMessage -Type 'build-complete' -Payload @{ outputPath = $__msg.outputPath }
                $__window.Dispatcher.Invoke([action]{ $__wv.CoreWebView2.PostWebMessageAsString($j) })
            } catch {
                $j = ConvertTo-Tiny11BridgeMessage -Type 'build-error' -Payload @{ message = "$_" }
                $__window.Dispatcher.Invoke([action]{ $__wv.CoreWebView2.PostWebMessageAsString($j) })
            }
        }) | Out-Null
        $psWorker.BeginInvoke() | Out-Null
        $null
    }
    'cancel'      = { if ($state.CancelToken) { $state.CancelToken.Cancel() }; $null }
    'close'       = { $state.Window.Close(); $null }
    'open-folder' = {
        param($msg)
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Split-Path $msg.path)
        $null
    }
}

$catalogJson = Get-Content (Join-Path $PSScriptRoot 'catalog\catalog.json') -Raw
$sdkCache = Join-Path $PSScriptRoot 'dependencies\webview2'
New-Item -ItemType Directory -Force -Path $sdkCache | Out-Null

Show-Tiny11Wizard -UiDir (Join-Path $PSScriptRoot 'ui') -CatalogJson $catalogJson -MessageHandlers $handlers -SdkCacheRoot $sdkCache

# Window-set hook: Show-Tiny11Wizard calls Set-Tiny11WizardWindow internally; pull them into $state for handlers.
$state.Window = Get-Tiny11WizardWindow
$state.Wv     = Get-Tiny11WizardWebView

exit 0
```

- [ ] **Step 2: Reorder so $state is populated BEFORE Show-Tiny11Wizard**

The above has a chicken-and-egg: handlers reference `$state.Window` but the window doesn't exist until `Show-Tiny11Wizard` returns. Fix: have `Show-Tiny11Wizard` call `Set-Tiny11WizardWindow` *during* construction (it already does — see Task 18), and modify the handler closures to lazy-fetch via `Get-Tiny11WizardWindow` instead of using `$state.Window` directly. Update the handlers above:

- Replace every `$state.Window` with `(Get-Tiny11WizardWindow)`.
- Replace every `$state.Wv` with `(Get-Tiny11WizardWebView)`.

- [ ] **Step 3: Smoke test the GUI wiring**

```powershell
pwsh -NoProfile -File tiny11maker.ps1
```

Expected: window opens; all 3 wizard steps render; Browse... opens dialogs; edition populates after picking an ISO. Don't run the build yet — just verify navigation + dialogs.

- [ ] **Step 4: Commit**

```powershell
git add tiny11maker.ps1
git commit -m "feat(orchestrator): wire GUI handlers + runspace build worker"
```

---

## Task 24: Phase 2 VM smoke test

Manual.

- [ ] **Step 1: Run interactive build with default selections**

```powershell
pwsh -NoProfile -File tiny11maker.ps1
```

Step through: pick Win11 ISO, accept defaults, set output path, click Build. Verify build completes.

- [ ] **Step 2: Boot resulting ISO in Hyper-V Gen2** — Same expectations as Task 15 (Start search works, Widgets work).

- [ ] **Step 3: Run interactive build with "keep Edge"** — drill into Edge & WebView, uncheck `remove-edge`. Build. Boot. Verify Edge present.

- [ ] **Step 4: Save a profile from the GUI** — click "Save profile...", save. Open the file; confirm `keep-edge.json`-shaped content.

- [ ] **Step 5: Re-run with -Config** — confirm same ISO output (modulo compression non-determinism).

- [ ] **Step 6: Document any issues; fix in separate commits.**

---

# Phase 3: Polish + Release

End state: README rewritten, CHANGELOG `[1.0.0]` cut, drift tests in place, multiple smoke tests pass, `v1.0.0` tagged.

---

## Task 25: Drift test for embedded autounattend

**Files:**
- Create: `tests/Tiny11.Autounattend.Drift.Tests.ps1`

- [ ] **Step 1: Add drift test**

Create the file:

```powershell
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Autounattend'

Describe "Embedded autounattend template drift" {
    It "embedded constant equals autounattend.template.xml byte-for-byte" {
        $filePath = "$PSScriptRoot/../autounattend.template.xml"
        $fileContent = Get-Content $filePath -Raw -Encoding UTF8
        Get-Tiny11EmbeddedAutounattend | Should -Be $fileContent
    }
}
```

- [ ] **Step 2: Run; expect pass**

If fails, sync the embedded constant in `Tiny11.Autounattend.psm1` to the file content.

- [ ] **Step 3: Commit**

```powershell
git add tests/Tiny11.Autounattend.Drift.Tests.ps1
git commit -m "test(autounattend): add drift test for embedded fallback"
```

---

## Task 26: README rewrite

**Files:**
- Modify: `README.md` (full rewrite)

- [ ] **Step 1: Write the README**

Replace `README.md` with content covering:

1. **Project description** — fork of `ntdevlabs/tiny11builder`, standalone, not contributed upstream.
2. **What's different from upstream** — interactive GUI; you choose what to keep.
3. **Two modes:**
   - Interactive: `pwsh tiny11maker.ps1`. Wizard walks you through ISO → customize → build.
   - Scripted: `pwsh tiny11maker.ps1 -Source X.iso -Config profile.json -ImageIndex 6 -OutputPath out.iso`.
4. **WebView2 boundary** — explicit section: we strip Edge browser but NOT the WebView2 Runtime, because Runtime powers Start menu search results, Widgets, and other Win11 shell surfaces. Removing it would break the OS in subtle ways.
5. **Catalog structure** — point at `catalog/catalog.json`. Brief schema overview. How to add a new item.
6. **Profile examples** — list `config/examples/*.json` and what each does.
7. **System requirements** — Windows 11 host, PowerShell 7+, ~10 GB free for scratch, WebView2 Runtime (preinstalled on Win11).
8. **Running tests** — `pwsh tests/Run-Tests.ps1`.
9. **VM testing recommendations** — Hyper-V Gen2, VirtualBox; what to verify after install.
10. **Contribution / fork boundary** — issues/PRs not pushed upstream; this fork is standalone.
11. **License / credits** — point at upstream license + tiny11builder credits.

- [ ] **Step 2: Commit**

```powershell
git add README.md
git commit -m "docs: rewrite README for v1.0.0 catalog-driven workflow"
```

---

## Task 27: Final smoke pass + CHANGELOG cut + tag v1.0.0

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run full smoke matrix**

For each profile in `config/examples/`:
1. Build via scripted mode.
2. Boot in Hyper-V Gen2.
3. Boot in VirtualBox.
4. Verify per-profile expected behaviors (Start search works, Widgets work, expected apps present/absent).

If anything fails, fix in separate commits before tagging.

- [ ] **Step 2: Cut CHANGELOG**

Edit `CHANGELOG.md`. Move all `[Unreleased]` entries under a new heading `## [1.0.0] - YYYY-MM-DD` (use today's date). Add a new empty `## [Unreleased]` heading at the top.

The 1.0.0 entry should summarize:

- Interactive WebView2-hosted WPF GUI with 3-step wizard (Source / Customize / Build).
- Catalog-driven removable items + tweaks (~63 items, 10 categories) — single source of truth in `catalog/catalog.json`.
- Scripted mode via `-Source`, `-Config`, `-ImageIndex`, `-OutputPath`, `-NonInteractive`.
- `runtimeDepsOn` reconcile machinery (zero edges in v1.0.0; rails for future deps).
- autounattend.xml templated from selections; 3-tier acquisition (local → fork URL → embedded fallback).
- Brittleness items closed (self-elevation arg-forwarding, image-index dropdown, Get-WindowsImage architecture detection, no Read-Host blocker).
- WebView2 Runtime explicitly preserved (Start search/Widgets keep working).
- Pester unit-test suite covering catalog parsing, selections, hives, action handlers, dispatcher, ISO mounting, autounattend templating, worker dispatch, bridge protocol.
- Example profiles: `tiny11-classic.json`, `keep-edge.json`, `minimal-removal.json`.

- [ ] **Step 3: Run the full Pester suite once more**

```powershell
pwsh -NoProfile -File tests/Run-Tests.ps1
```

Expected: all pass.

- [ ] **Step 4: Commit + tag**

```powershell
git add CHANGELOG.md
git commit -m "release: cut v1.0.0"
git tag -a v1.0.0 -m "tiny11options v1.0.0 — interactive variant builder"
```

- [ ] **Step 5: Push**

```powershell
git push origin main
git push origin v1.0.0
```

- [ ] **Step 6: Update todo file**

In `C:/Users/jscha/.claude/projects/C--Users-jscha/memory/todo_tiny11options.md`, move items #1 and #3 to a "Shipped — 2026-XX-XX — v1.0.0" section, summarize what landed, and remove the now-completed brittleness sub-bullets. Item #2 (VM test harness) stays Active (only manual smoke is in v1.0.0).

---

## Self-Review Notes

- **Spec coverage:** Each spec section maps to at least one task — schema → Task 2; selections/reconcile → Task 3; hives → Task 4; action handlers → Tasks 5-9; ISO → Task 10; autounattend templating → Task 11; worker → Task 12; param surface + brittleness → Task 13; full catalog + profiles → Task 14; VM smoke → Task 15; WebView2 SDK + Runtime → Task 16; bridge → Task 17; window host → Task 18; UI scaffold → Task 19; Steps 1/2/3 → Tasks 20/21/22; handler wiring → Task 23; GUI smoke → Task 24; drift test → Task 25; README → Task 26; release/tag → Task 27.
- **Type consistency:** `EffectiveState` / `Locked` / `LockedBy` shape used everywhere downstream of `Resolve-Tiny11Selections`. Action shape (`type`/`op`/`hive`/etc.) consistent across catalog, dispatcher, and handlers. Bridge messages enumerated in spec Section 6 all have handler implementations in Task 23.
- **No `innerHTML` in user-controlled rendering:** all UI render functions return DOM nodes constructed via `el()`, which uses `createTextNode` for strings.
- **No placeholders:** every code-changing step includes the actual code. The catalog-build step (14) acknowledges mechanical translation but enforces completeness via the prefix-coverage test.

---

## Phase boundary checks

**After Task 15 (Phase 1 done):** `pwsh tests/Run-Tests.ps1` green; scripted-mode produces working ISOs for `tiny11-classic.json` and `keep-edge.json`; brittleness items closed.

**After Task 24 (Phase 2 done):** `pwsh tiny11maker.ps1` opens GUI; 3-step wizard works end-to-end; profile save/load round-trips; build progress streams live.

**After Task 27 (Phase 3 done):** `git tag -l` shows `v1.0.0`; README + CHANGELOG describe the release; full Pester suite green; smoke matrix passed.
