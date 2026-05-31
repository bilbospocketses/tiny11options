# WIM-integrity Gate + `-Save` Retry + Synthetic-WIM E2E Harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a corrupt `install.wim`/`boot.wim` abort the build instead of silently shipping, retry a transient dismount-save lock, and prove both automatically in CI against a real (tiny) WIM.

**Architecture:** A new leaf module `src/Tiny11.Wim.psm1` exports two helpers — `Assert-Tiny11WimIntegrity` (verify-or-throw) and `Invoke-Tiny11WimDismountSave` (bounded retry-with-backoff). `Tiny11.Worker.psm1` routes both WIM commits through them and gates each saved/exported image. A tagged, admin-gated Pester suite validates the helpers against a synthetic WIM; deterministic control-flow is covered by mocked offline tests; structural source-regex guards protect the Worker wiring on non-admin boxes.

**Tech Stack:** PowerShell 5.1/7 modules, Pester 5.x, DISM cmdlets (`Get-WindowsImage`/`Mount-WindowsImage`/`Dismount-WindowsImage`/`New-WindowsImage`), .NET 10 WPF launcher (csproj `<EmbeddedResource>` + `HeadlessRunner.StaticResources`), xUnit drift guards.

**Spec:** `docs/superpowers/specs/2026-05-30-wim-integrity-gate-e2e-design.md`

---

## Conventions for this plan

- **`REPO`** = the isolated worktree created in Setup, or `C:/Users/jscha/source/repos/tiny11options` if not using one. All `git` commands use `git -C "<REPO>"`; all file paths are under `<REPO>`.
- **No AI attribution in commit messages** (per user global instructions) — no `Co-Authored-By` trailer.
- Run a single Pester file with: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/<file>' -Output Detailed"`.
- Run the full Pester suite with: `pwsh -NoProfile -File "<REPO>/tests/Run-Tests.ps1"`.
- Run xUnit with: `dotnet test "<REPO>/launcher/Tests/tiny11options.Launcher.Tests.csproj" -c Release`.

---

## Pre-flight (main agent, before any repo edit)

These are memory-vault edits (outside the repo) and a compliance prerequisite. **Do the waiver edit before Task 3** (which modifies a `dism.exe` invocation), so the Local-Dependencies-Only per-edit rule is satisfied when that line is touched.

- [ ] **P1: Update the dependency-policy waiver.** Edit `C:/Users/jscha/.claude/projects/C--Users-jscha/memory/project_tiny11options_dependency_policy.md`: add `dism.exe` and `robocopy.exe` to the waiver scope (OS-intrinsic — can't vendor a portable DISM/robocopy matching an arbitrary host's servicing stack), noting `Get/Mount/Dismount/New-WindowsImage` are the cmdlet face of the same DISM OS component. Update the frontmatter `description` to reflect the broadened scope.

---

## Setup

- [ ] **S1: Create the isolated worktree + branch.** Invoke the `superpowers:using-git-worktrees` skill. Target branch `feat/wim-integrity-gate` off `main`. Record the worktree path as `REPO` for all subsequent steps.

```powershell
git -C "C:/Users/jscha/source/repos/tiny11options" worktree add "C:/Users/jscha/source/repos/tiny11options-wim" -b feat/wim-integrity-gate main
```

- [ ] **S2: Confirm a clean baseline.** Run the full suite once before changes.

Run: `pwsh -NoProfile -File "<REPO>/tests/Run-Tests.ps1"` → Expected: all green.
Run: `dotnet test "<REPO>/launcher/Tests/tiny11options.Launcher.Tests.csproj" -c Release` → Expected: all green.

---

## Task 1: New module `Tiny11.Wim.psm1` — `Assert-Tiny11WimIntegrity` + launcher wiring

**Files:**
- Create: `src/Tiny11.Wim.psm1`
- Create: `tests/Tiny11.Wim.Tests.ps1`
- Modify: `launcher/tiny11options.Launcher.csproj` (add `<EmbeddedResource>`)
- Modify: `launcher/Headless/HeadlessRunner.cs` (add to `StaticResources`)

- [ ] **Step 1: Write the failing test** — `tests/Tiny11.Wim.Tests.ps1`

```powershell
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Wim'

Describe 'Assert-Tiny11WimIntegrity' {
    It 'passes -Index and -CheckIntegrity to Get-WindowsImage and does not throw on success' {
        Mock -CommandName Get-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { [pscustomobject]@{ ImageIndex = 2 } }
        { Assert-Tiny11WimIntegrity -ImagePath 'X:\install.wim' -Index 2 } | Should -Not -Throw
        Should -Invoke -CommandName Get-WindowsImage -ModuleName 'Tiny11.Wim' -Times 1 `
            -ParameterFilter { $CheckIntegrity -eq $true -and $Index -eq 2 -and $ImagePath -eq 'X:\install.wim' }
    }

    It 'throws an actionable error when Get-WindowsImage fails' {
        Mock -CommandName Get-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { throw 'cannot read WIM resource table' }
        { Assert-Tiny11WimIntegrity -ImagePath 'X:\install.wim' -Index 1 } |
            Should -Throw -ExpectedMessage '*failed its post-save integrity check*'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Wim.Tests.ps1' -Output Detailed"`
Expected: FAIL — `Module not found: .../src/Tiny11.Wim.psm1`.

- [ ] **Step 3: Create the module with `Assert-Tiny11WimIntegrity`** — `src/Tiny11.Wim.psm1`

```powershell
Set-StrictMode -Version Latest

function Assert-Tiny11WimIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index
    )
    # Verify a saved/exported WIM is structurally sound before it can ship. A silent
    # partial commit from Dismount-WindowsImage -Save (transient host interference:
    # AV scan, Search indexer, Controlled Folder Access, a stray handle) is exactly
    # what this catches -- before oscdimg wraps a broken install.wim into an ISO that
    # then fails Windows Setup at the file-copy step.
    try {
        Get-WindowsImage -ImagePath $ImagePath -Index $Index -CheckIntegrity -ErrorAction Stop | Out-Null
    } catch {
        throw ("Build aborted -- '$ImagePath' (index $Index) failed its post-save integrity check; " +
               "the image was NOT shipped. Likely transient host interference (AV real-time scan / " +
               "Windows Search indexer / Controlled Folder Access / a stray file handle). Re-run the build. " +
               "Underlying error: $($_.Exception.Message)")
    }
}

Export-ModuleMember -Function Assert-Tiny11WimIntegrity
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Wim.Tests.ps1' -Output Detailed"`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire the module into the launcher packaging.** A new `src/Tiny11.*.psm1` triggers the Pester drift test (`Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1`) and the xUnit drift tests until embedded + listed.

In `launcher/tiny11options.Launcher.csproj`, add this line immediately after the `Tiny11.PostBoot.psm1` `<EmbeddedResource>` line:

```xml
    <EmbeddedResource Include="..\src\Tiny11.Wim.psm1"><LogicalName>src/Tiny11.Wim.psm1</LogicalName></EmbeddedResource>
```

In `launcher/Headless/HeadlessRunner.cs`, add to the `StaticResources` array immediately after the `"src/Tiny11.PostBoot.psm1",` entry:

```csharp
        "src/Tiny11.Wim.psm1",
```

- [ ] **Step 6: Run the drift guards to verify wiring**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1' -Output Detailed"`
Expected: PASS.
Run: `dotnet test "<REPO>/launcher/Tests/tiny11options.Launcher.Tests.csproj" -c Release --filter "FullyQualifiedName~EmbeddedResourcesTests"`
Expected: PASS (`StaticResources_AllExistAsEmbeddedResources`, `EveryCsprojSingleFileResource_IsEitherStaticOrGuiOnlyAllowlisted`).

- [ ] **Step 7: Commit**

```powershell
git -C "<REPO>" add src/Tiny11.Wim.psm1 tests/Tiny11.Wim.Tests.ps1 launcher/tiny11options.Launcher.csproj launcher/Headless/HeadlessRunner.cs
git -C "<REPO>" commit -m "feat(wim): add Assert-Tiny11WimIntegrity gate helper + launcher wiring"
```

---

## Task 2: `Invoke-Tiny11WimDismountSave` — bounded retry with backoff

**Files:**
- Modify: `src/Tiny11.Wim.psm1`
- Modify: `tests/Tiny11.Wim.Tests.ps1`

- [ ] **Step 1: Write the failing tests** — append to `tests/Tiny11.Wim.Tests.ps1`

```powershell
Describe 'Invoke-Tiny11WimDismountSave' {
    It 'succeeds on the first attempt and calls Dismount-WindowsImage once' {
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\scratch' -DelaySeconds 0 } | Should -Not -Throw
        Should -Invoke -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -Times 1 `
            -ParameterFilter { $Save -eq $true -and $Path -eq 'C:\scratch' }
    }

    It 'retries after a transient failure and then succeeds' {
        $script:n = 0
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith {
            $script:n++
            if ($script:n -lt 2) { throw 'the process cannot access the file because it is being used by another process' }
        }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\scratch' -Attempts 3 -DelaySeconds 0 } | Should -Not -Throw
        Should -Invoke -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -Times 2
    }

    It 'gives up after N attempts and throws with the path and attempt count' {
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { throw 'sharing violation' }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\scratch' -Attempts 3 -DelaySeconds 0 } |
            Should -Throw -ExpectedMessage "*failed for 'C:\scratch' after 3 attempt(s)*"
        Should -Invoke -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -Times 3
    }

    It 'does not sleep when DelaySeconds is 0' {
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { throw 'x' }
        Mock -CommandName Start-Sleep -ModuleName 'Tiny11.Wim' -MockWith { }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\s' -Attempts 2 -DelaySeconds 0 } | Should -Throw
        Should -Invoke -CommandName Start-Sleep -ModuleName 'Tiny11.Wim' -Times 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Wim.Tests.ps1' -Output Detailed"`
Expected: FAIL — `Invoke-Tiny11WimDismountSave` not recognized.

- [ ] **Step 3: Implement the helper** — in `src/Tiny11.Wim.psm1`, add the function before `Export-ModuleMember`, and update the export line.

```powershell
function Invoke-Tiny11WimDismountSave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter()][int]$Attempts = 3,
        [Parameter()][int]$DelaySeconds = 2
    )
    # Dismount-WindowsImage -Save is the big, slow write that commits every offline
    # modification back into the WIM. Under a transient lock (Defender real-time scan,
    # Search indexer, Controlled Folder Access, a lingering handle) it can fail. Retry
    # a bounded number of times with exponential backoff (base $DelaySeconds, x2 each
    # attempt) before giving up. Retry-on-any: the cost of retrying a genuine
    # (non-transient) dism error is just the backoff before the same failure resurfaces
    # -- acceptable for a step this critical.
    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Dismount-WindowsImage -Path $MountPath -Save -ErrorAction Stop | Out-Null
            return
        } catch {
            $lastError = $_
            if ($attempt -lt $Attempts) {
                $backoff = [int]($DelaySeconds * [math]::Pow(2, $attempt - 1))
                if ($backoff -gt 0) { Start-Sleep -Seconds $backoff }
            }
        }
    }
    throw "Dismount-WindowsImage -Save failed for '$MountPath' after $Attempts attempt(s): $($lastError.Exception.Message)"
}
```

Update the final line to:

```powershell
Export-ModuleMember -Function Assert-Tiny11WimIntegrity, Invoke-Tiny11WimDismountSave
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Wim.Tests.ps1' -Output Detailed"`
Expected: PASS (6 tests total).

- [ ] **Step 5: Commit**

```powershell
git -C "<REPO>" add src/Tiny11.Wim.psm1 tests/Tiny11.Wim.Tests.ps1
git -C "<REPO>" commit -m "feat(wim): add Invoke-Tiny11WimDismountSave bounded-retry helper"
```

---

## Task 3: Wire the gate + retry into `Tiny11.Worker.psm1`

**Files:**
- Modify: `src/Tiny11.Worker.psm1`
- Modify: `tests/Tiny11.Worker.Tests.ps1` (update structural guards; add gate guards)

> **Local-Dependencies-Only check:** Step 4 adds `/CheckIntegrity` to an existing `dism.exe` PATH invocation. Confirm Pre-flight **P1** (waiver update) is done before this task lands. No *new* PATH-binary dependency is introduced.

- [ ] **Step 1: Update the structural guards (failing test first)** — in `tests/Tiny11.Worker.Tests.ps1`, replace the install.wim `-Save` assertion (currently `Should -Match 'Dismount-WindowsImage -Path \$scratchImg -Save'`) with the helper assertion, and replace the boot.wim `-Save` assertion likewise.

Replace (install.wim block):
```powershell
        $script:workerSource | Should -Match 'Dismount-WindowsImage -Path \$scratchImg -Save'
```
with:
```powershell
        $script:workerSource | Should -Match 'Invoke-Tiny11WimDismountSave -MountPath \$scratchImg'
```

Replace (boot.wim block):
```powershell
        $script:workerSource | Should -Match '(?ms)if \(\$bootPipelineSucceeded\) \{\s*Dismount-WindowsImage -Path \$scratchImg -Save'
```
with:
```powershell
        $script:workerSource | Should -Match '(?ms)if \(\$bootPipelineSucceeded\) \{\s*Invoke-Tiny11WimDismountSave -MountPath \$scratchImg'
```

Then add a new `Describe` block at the end of the file:
```powershell
Describe 'Invoke-Tiny11BuildPipeline WIM-integrity gate' {
    BeforeAll {
        $script:workerSource = Get-Content (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.Worker.psm1') -Raw
    }
    It 'imports the Tiny11.Wim module' {
        $script:workerSource | Should -Match 'Import-Module[^\r\n]*Tiny11\.Wim\.psm1'
    }
    It 'routes both WIM commits through Invoke-Tiny11WimDismountSave' {
        ([regex]::Matches($script:workerSource, 'Invoke-Tiny11WimDismountSave -MountPath \$scratchImg')).Count |
            Should -BeGreaterOrEqual 2
    }
    It 'verifies install.wim integrity post-save and post-export, and boot.wim post-save' {
        $script:workerSource | Should -Match 'Assert-Tiny11WimIntegrity -ImagePath "\$tinyDir\\sources\\install\.wim" -Index \$ImageIndex'
        $script:workerSource | Should -Match 'Assert-Tiny11WimIntegrity -ImagePath "\$tinyDir\\sources\\install\.wim" -Index 1'
        $script:workerSource | Should -Match 'Assert-Tiny11WimIntegrity -ImagePath \$bootWim -Index 2'
    }
    It 'adds /CheckIntegrity to the install.wim export' {
        $script:workerSource | Should -Match "'/Export-Image'[\s\S]*?'/CheckIntegrity'"
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Worker.Tests.ps1' -Output Detailed"`
Expected: FAIL — the new gate assertions fail; the updated `-Save` assertions fail (source still has the old literal).

- [ ] **Step 3: Import the module + route the install.wim commit through the helper + add the post-save gate.**

In `src/Tiny11.Worker.psm1`, add to the import block at the top (after the `Tiny11.PostBoot.psm1` import):
```powershell
Import-Module "$PSScriptRoot/Tiny11.Wim.psm1"          -Force -Global -DisableNameChecking
```

In the install.wim `finally` block, replace:
```powershell
                if ($installPipelineSucceeded) {
                    Dismount-WindowsImage -Path $scratchImg -Save | Out-Null
                } else {
```
with:
```powershell
                if ($installPipelineSucceeded) {
                    Invoke-Tiny11WimDismountSave -MountPath $scratchImg
                } else {
```

Immediately after the existing `if (-not $installPipelineSucceeded) { throw 'Worker build pipeline failed mid-flight ...' }` block, insert the post-save gate:
```powershell

        # WIM-integrity gate (post-save). On the FastBuild path (export skipped below)
        # this is the gate on the shipped artifact; on the normal path the export adds
        # a second, full-resource verify.
        & $progress @{ phase='integrity-check'; step='Verifying install.wim integrity (post-save)'; percent=82 }
        Assert-Tiny11WimIntegrity -ImagePath "$tinyDir\sources\install.wim" -Index $ImageIndex
```

- [ ] **Step 4: Add `/CheckIntegrity` to the export + post-export gate.**

In the `else` (non-FastBuild) export branch, replace:
```powershell
            & 'dism.exe' '/Export-Image' "/SourceImageFile:$tinyDir\sources\install.wim" "/SourceIndex:$ImageIndex" "/DestinationImageFile:$tinyDir\sources\install2.wim" '/Compress:recovery' | Out-Null
            Remove-Item -Path "$tinyDir\sources\install.wim" -Force | Out-Null
            Rename-Item -Path "$tinyDir\sources\install2.wim" -NewName 'install.wim' | Out-Null
```
with:
```powershell
            & 'dism.exe' '/Export-Image' "/SourceImageFile:$tinyDir\sources\install.wim" "/SourceIndex:$ImageIndex" "/DestinationImageFile:$tinyDir\sources\install2.wim" '/Compress:recovery' '/CheckIntegrity' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Build aborted -- dism /Export-Image failed (exit $LASTEXITCODE) for install.wim; the image was NOT shipped. Likely WIM corruption or transient host interference. Re-run the build." }
            Remove-Item -Path "$tinyDir\sources\install.wim" -Force | Out-Null
            Rename-Item -Path "$tinyDir\sources\install2.wim" -NewName 'install.wim' | Out-Null
            & $progress @{ phase='integrity-check'; step='Verifying exported install.wim integrity'; percent=86 }
            Assert-Tiny11WimIntegrity -ImagePath "$tinyDir\sources\install.wim" -Index 1
```

- [ ] **Step 5: Route the boot.wim commit through the helper + add the boot.wim gate.**

In the boot.wim `finally` block, replace:
```powershell
                if ($bootPipelineSucceeded) {
                    Dismount-WindowsImage -Path $scratchImg -Save | Out-Null
                } else {
```
with:
```powershell
                if ($bootPipelineSucceeded) {
                    Invoke-Tiny11WimDismountSave -MountPath $scratchImg
                } else {
```

Immediately after the existing `if (-not $bootPipelineSucceeded) { throw 'Worker boot.wim pipeline failed mid-flight ...' }` block, insert:
```powershell

        # WIM-integrity gate (boot.wim, post-save). Smaller blast radius than
        # install.wim, but boot.wim corruption fails WinPE -- gate it for symmetry.
        & $progress @{ phase='integrity-check'; step='Verifying boot.wim integrity (post-save)'; percent=91 }
        Assert-Tiny11WimIntegrity -ImagePath $bootWim -Index 2
```

- [ ] **Step 6: Run the Worker structural tests + the module-load integration test**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Worker.Tests.ps1' -Output Detailed"`
Expected: PASS (updated `-Save` guards + new gate guards).
Run: `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Worker.PostBootImport.IntegrationTests.ps1' -Output Detailed"`
Expected: PASS — confirms the new `Import-Module Tiny11.Wim.psm1` doesn't break the module-load cascade.

- [ ] **Step 7: Commit**

```powershell
git -C "<REPO>" add src/Tiny11.Worker.psm1 tests/Tiny11.Worker.Tests.ps1
git -C "<REPO>" commit -m "feat(worker): gate install.wim/boot.wim integrity + retry dismount-save"
```

---

## Task 4: Synthetic-WIM harness + tag passthrough

**Files:**
- Modify: `tests/Run-Tests.ps1` (add `-Tag`/`-ExcludeTag`)
- Create: `tests/Tiny11.Wim.Synthetic.Tests.ps1`

- [ ] **Step 1: Add tag passthrough to the runner** — replace the body of `tests/Run-Tests.ps1` (keep the `#Requires` line and the exit-code comment block) with:

```powershell
[CmdletBinding()]
param(
    [string[]]$Tag,
    [string[]]$ExcludeTag
)
$config = & "$PSScriptRoot/Tiny11.PesterConfig.ps1"
if ($Tag)        { $config.Filter.Tag = $Tag }
if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { [System.Environment]::Exit(1) }
[System.Environment]::Exit(0)
```

(The `#Requires -Module @{ ModuleName='Pester'; ... }` line stays at the very top, above `param`.)

- [ ] **Step 2: Verify the runner still works and honors exclusion**

Run: `pwsh -NoProfile -File "<REPO>/tests/Run-Tests.ps1" -ExcludeTag Synthetic`
Expected: full suite runs and passes (no `Synthetic` file exists yet, so this is just a no-op exclusion sanity check).

- [ ] **Step 3: Write the synthetic-WIM harness** — `tests/Tiny11.Wim.Synthetic.Tests.ps1`

```powershell
# Synthetic-WIM harness for the WIM-commit mechanics (integrity gate + -Save retry).
# Tag 'Synthetic' (implies RequiresAdmin + Slow): New-WindowsImage / Mount-WindowsImage
# require elevation, and capture+mount+save take real seconds. The BeforeDiscovery guard
# skips the whole file on a non-elevated host so local non-admin runs stay green; CI
# (admin runner) executes it for real.
#
# Scope note: a synthetic WIM is content-agnostic -- it validates the WIM CONTAINER
# mechanics (mount/save/integrity/retry), NOT the real apply handlers (registry/
# filesystem/appx), which need a real Windows image (deferred Hyper-V tier).

Set-StrictMode -Version Latest

BeforeDiscovery {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $script:IsAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
}

Describe 'Tiny11.Wim synthetic-WIM harness' -Tag 'Synthetic' -Skip:(-not $script:IsAdmin) {
    BeforeAll {
        Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
        Import-Tiny11Module -Name 'Tiny11.Wim'

        $script:work    = Join-Path $env:TEMP "tiny11wim-$([guid]::NewGuid())"
        $script:capture = Join-Path $script:work 'capture'
        $script:mount   = Join-Path $script:work 'mount'
        $script:wim     = Join-Path $script:work 'test.wim'
        New-Item -ItemType Directory -Force -Path $script:capture, $script:mount | Out-Null
        Set-Content -Path (Join-Path $script:capture 'hello.txt') -Value 'synthetic wim payload' -Encoding UTF8
        New-Item -ItemType Directory -Force -Path (Join-Path $script:capture 'sub') | Out-Null
        Set-Content -Path (Join-Path $script:capture 'sub\data.txt') -Value 'more payload' -Encoding UTF8
        # Real .wim via the DISM cmdlet; -CheckIntegrity writes integrity data.
        New-WindowsImage -CapturePath $script:capture -ImagePath $script:wim -Name 'tiny11-test' -CompressionType Fast -CheckIntegrity | Out-Null
    }

    AfterAll {
        Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $script:mount } |
            ForEach-Object { Dismount-WindowsImage -Path $script:mount -Discard -ErrorAction SilentlyContinue | Out-Null }
        if (Test-Path $script:work) { Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue }
    }

    It 'happy round-trip: mount -> modify -> dismount-save -> integrity passes (real DISM)' {
        Set-ItemProperty -Path $script:wim -Name IsReadOnly -Value $false
        Mount-WindowsImage -ImagePath $script:wim -Index 1 -Path $script:mount | Out-Null
        Set-Content -Path (Join-Path $script:mount 'added.txt') -Value 'added during servicing' -Encoding UTF8
        { Invoke-Tiny11WimDismountSave -MountPath $script:mount -DelaySeconds 0 } | Should -Not -Throw
        { Assert-Tiny11WimIntegrity -ImagePath $script:wim -Index 1 } | Should -Not -Throw
    }

    It 'best-effort: a corrupted WIM is detected by the integrity gate' {
        # Copy + corrupt the middle bytes, then assert the gate throws. Best-effort:
        # if Get-WindowsImage -CheckIntegrity does not flag this corruption, mark
        # Inconclusive (a signal to revisit the FastBuild integrity mechanism) rather
        # than fail CI.
        $corrupt = Join-Path $script:work 'corrupt.wim'
        Copy-Item $script:wim $corrupt -Force
        $bytes = [System.IO.File]::ReadAllBytes($corrupt)
        for ($i = [int]($bytes.Length * 0.4); $i -lt [int]($bytes.Length * 0.6); $i++) { $bytes[$i] = $bytes[$i] -bxor 0xFF }
        [System.IO.File]::WriteAllBytes($corrupt, $bytes)
        try {
            Assert-Tiny11WimIntegrity -ImagePath $corrupt -Index 1
            Set-ItResult -Inconclusive -Because 'Get-WindowsImage -CheckIntegrity did not flag the injected corruption; revisit the FastBuild integrity mechanism (see spec section 5.1).'
        } catch {
            $_.Exception.Message | Should -BeLike '*failed its post-save integrity check*'
        }
    }
}
```

- [ ] **Step 4: Run the synthetic harness (elevated)**

Run (in an elevated pwsh): `pwsh -NoProfile -Command "Invoke-Pester -Path '<REPO>/tests/Tiny11.Wim.Synthetic.Tests.ps1' -Output Detailed"`
Expected: the happy round-trip PASSES; the corruption test PASSES or is INCONCLUSIVE (not failed). If run non-elevated: the whole Describe is SKIPPED (still green).

- [ ] **Step 5: Run the full suite both ways**

Run: `pwsh -NoProfile -File "<REPO>/tests/Run-Tests.ps1" -ExcludeTag Synthetic` → Expected: green, Synthetic excluded.
Run: `pwsh -NoProfile -File "<REPO>/tests/Run-Tests.ps1"` → Expected: green (Synthetic runs if elevated, skips otherwise).

- [ ] **Step 6: Commit**

```powershell
git -C "<REPO>" add tests/Run-Tests.ps1 tests/Tiny11.Wim.Synthetic.Tests.ps1
git -C "<REPO>" commit -m "test(wim): synthetic-WIM harness + Run-Tests tag passthrough"
```

---

## Task 5: CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add entries under `## [Unreleased]`.** Under the existing `### Added` in `[Unreleased]`, append:

```markdown
- **WIM-integrity gate — a corrupt image can no longer ship silently.** After the offline-servicing save, the build verifies `install.wim` (post-`-Save`, and again post-`/Export-Image`) and `boot.wim` via `Get-WindowsImage -CheckIntegrity` / `dism /Export-Image /CheckIntegrity`, and **aborts the build** with an actionable error if verification fails. Closes the silent-partial-commit class behind the v1.0.26 "Windows installation has failed" file-copy failure (a transient dismount-save lock leaving `install.wim` partially committed). New module `src/Tiny11.Wim.psm1`.
- **Synthetic-WIM E2E test harness.** `tests/Tiny11.Wim.Synthetic.Tests.ps1` (tag `Synthetic`, admin-gated, auto-skips non-elevated) validates the integrity gate + dismount-save retry against a real, tiny `New-WindowsImage`-captured WIM in CI. `tests/Run-Tests.ps1` now accepts `-Tag`/`-ExcludeTag`.
```

Add a `### Changed` block under `[Unreleased]` (after `### Added`) if one does not exist:

```markdown
### Changed

- **`Dismount-WindowsImage -Save` is now retried** (3 attempts, exponential backoff) for both `install.wim` and `boot.wim`, recovering from transient locks (AV real-time scan, Search indexer, Controlled Folder Access, stray handles) instead of failing the build. The `/Export-Image` step now passes `/CheckIntegrity`.
```

- [ ] **Step 2: Commit**

```powershell
git -C "<REPO>" add CHANGELOG.md
git -C "<REPO>" commit -m "docs(changelog): record WIM-integrity gate + retry + synthetic harness"
```

---

## Final verification (before PR)

- [ ] **V1: Full Pester suite green (elevated, so Synthetic runs for real).**
Run: `pwsh -NoProfile -File "<REPO>/tests/Run-Tests.ps1"` → Expected: 0 failed; confirm the `Synthetic` tests **executed** (not skipped) — proves the gate + helpers work against a real WIM.

- [ ] **V2: xUnit green.**
Run: `dotnet test "<REPO>/launcher/Tests/tiny11options.Launcher.Tests.csproj" -c Release` → Expected: 0 failed (drift guards confirm csproj ↔ StaticResources sync).

- [ ] **V3: Launcher builds.**
Run: `dotnet build "<REPO>/tiny11options.sln" -c Release` → Expected: success.

- [ ] **V4: Open the PR (squash; signed-repo policy).**

```powershell
git -C "<REPO>" push -u origin feat/wim-integrity-gate
gh pr create --repo bilbospocketses/tiny11options --base main --head feat/wim-integrity-gate --title "WIM-integrity gate + -Save retry + synthetic-WIM E2E harness" --body "Implements docs/superpowers/specs/2026-05-30-wim-integrity-gate-e2e-design.md"
```

Wait for CI green, then: `gh pr merge --squash --delete-branch <N>` (NEVER `--rebase` — signed-repo policy).

---

## Wrap-up (main agent, after merge)

- [ ] **W1: Reconcile the todo.** In `todo_tiny11options.md`: promote the STAGING block to a single active grouped item marked shipped → move to `archive/todo_tiny11options_shipped.md`; remove the superseded "WIM integrity gate + Dismount-WindowsImage -Save retry" active item and the "Automated end-to-end test harness — DEFERRED" item; delete the STAGING block. Note the Hyper-V VM tier + real-apply-handler coverage remain deferred.
- [ ] **W2: Release decision.** This ships a runtime gate → a patch release is warranted. Surface **v1.0.29** to the user: bump `launcher/tiny11options.Launcher.csproj` `<Version>` + `app.manifest`, rename CHANGELOG `[Unreleased]` → `[1.0.29]`, tag, verify the Velopack pipeline + `releases.win.json` upload. Do NOT auto-bump — confirm first.
- [ ] **W3: Remove the worktree** (if used): `git -C "C:/Users/jscha/source/repos/tiny11options" worktree remove "C:/Users/jscha/source/repos/tiny11options-wim"`.

---

## Self-review (plan ↔ spec)

- **Spec §5.1 helpers** → Tasks 1–2. ✓
- **Spec §5.2 Worker integration (both WIMs, post-save + post-export gates, `/CheckIntegrity`)** → Task 3. ✓
- **Spec §5.3 FastBuild** → Task 3 Step 3 (post-save gate runs on both paths, before the export branch). ✓
- **Spec §5.4 error UX (throw → existing failed-build path; `integrity-check` phase)** → Task 3 Steps 3–5 progress markers + throwing helpers. ✓
- **Spec §6.1 synthetic harness (tagged, admin-gated, happy round-trip real DISM, best-effort corruption)** → Task 4. ✓
- **Spec §6.1 retry recovers / gives up (deterministic)** → Task 2 mocked tests. ✓
- **Spec §6.2 source-regex structural guard** → Task 3 Step 1. ✓
- **Spec §6.3 Run-Tests/PesterConfig tag passthrough + verify CI runs Synthetic** → Task 4 Step 1 + V1. ✓
- **Spec §7 compliance waiver** → Pre-flight P1. ✓
- **Spec §8 rollout (branch, squash PR, CHANGELOG, version)** → Setup + Task 5 + V4 + W2. ✓
- **Launcher wiring (csproj + StaticResources, the B9 four-edit trap)** → Task 1 Steps 5–6 (covered by existing drift tests). ✓
- **Placeholder scan:** none — all steps carry real code/commands.
- **Type/name consistency:** `Assert-Tiny11WimIntegrity(-ImagePath,-Index)` and `Invoke-Tiny11WimDismountSave(-MountPath,-Attempts,-DelaySeconds)` used identically across Tasks 1–4. ✓
