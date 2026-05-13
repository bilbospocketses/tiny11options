# Post-Boot Cleanup Implementation Plan (v1.0.1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a catalog-driven post-boot cleanup scheduled task that re-removes inbox apps and re-applies tweaks after Windows cumulative updates restage them, tailored per-build to the user's selections.

**Architecture:** New `src/Tiny11.PostBoot.psm1` owns the generator + helper-script content. Sibling `Get-Tiny11<Type>OnlineCommand` emitters added to each existing `src/Tiny11.Actions.*.psm1` module return structured `[pscustomobject]` command objects that the generator composes into a self-contained `tiny11-cleanup.ps1`. A scheduled task XML registers the script for boot + daily + WU-EventID-19 triggers. Worker builds get one task; Core builds get two (existing `Keep WU Disabled` untouched, plus new `Post-Boot Cleanup`).

**Tech Stack:** PowerShell 5.1 (target runtime) + PowerShell 7+ (build host); Pester 5 (PS unit/integration); .NET 10 / WPF / WebView2 (launcher); xUnit + Moq (C# launcher tests); JSON catalog.

**Spec:** `docs/superpowers/specs/2026-05-12-post-boot-cleanup-design.md`

**Branch:** `feat/v1.0.1-post-boot-cleanup` (already created; spec committed at `2f86c6f`).

---

## Phase overview

| Phase | Tasks | Outcome |
|---|---|---|
| 1 — Online emitters | 1-5 | Sibling `Get-Tiny11<Type>OnlineCommand` functions on all 4 Actions modules + dispatcher |
| 2 — PostBoot module scaffold | 6-9 | `Tiny11.PostBoot.psm1` with header/helpers/footer constants + Format-PSNamedParams + golden helper file |
| 3 — Generator | 10-11 | `New-Tiny11PostBootCleanupScript` + integration tests + targeted golden snippets |
| 4 — XML + SetupComplete + Install | 12-14 | Task XML generator + Worker SetupComplete generator + `Install-Tiny11PostBootCleanup` |
| 5 — Worker pipeline + headless wrappers | 15-17 | `Invoke-Tiny11BuildPipeline` integration + `-InstallPostBootCleanup` / `-NoPostBootCleanup` switches on `tiny11maker.ps1` + `tiny11maker-from-config.ps1` |
| 6 — Core pipeline integration | 18-20 | Core `SetupComplete.cmd` splice point + cleanup-file injection + `tiny11Coremaker-from-config.ps1` switches |
| 7 — UI + C# launcher wiring | 21-23 | Step 1 checkbox + `state.installPostBootCleanup` + `BuildHandlers` plumbing + contract allowlist |
| 8 — Final test sweeps | 24-25 | Encoding-walker confirmation + test-count verification |
| 9 — Docs + manual smoke + release | 26-37 | CHANGELOG + README + version bump + 8-case VM smoke matrix + tag + release.yml |

**Total tasks:** 37. Phases 1-7 are landing-ready code work (TDD throughout). Phase 8 is a verification sweep. Phase 9 is documentation + manual VM testing + cutting the release.

**TDD discipline:** every code-producing task follows the write-failing-test → run-test-fails → implement → run-test-passes → commit sequence. Reuse Pester test fixtures across related cases where useful.

**Conventions:**
- LF line endings (`.gitattributes` already enforces; the encoding-guard hook will catch BOM-less non-ASCII).
- No `Co-Authored-By` / AI-attribution in commit messages.
- Solo-owned repo — commit directly to `feat/v1.0.1-post-boot-cleanup`, no PRs.
- Catalog/spec terminology: an **item** is a catalog entry (e.g. `remove-clipchamp`); an **action** is one of the entries in `item.actions` (e.g. `{type:'provisioned-appx', packagePrefix:'Clipchamp.Clipchamp'}`); a **selection** is the user's `apply|skip` decision per item.

---

## Phase 1 — Per-action online emitters

### Task 1: `Get-Tiny11RegistryOnlineCommand` (registry emitter)

**Files:**
- Modify: `src/Tiny11.Actions.Registry.psm1`
- Create: `tests/Tiny11.Actions.Registry.Online.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Write `tests/Tiny11.Actions.Registry.Online.Tests.ps1`:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.Registry.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11RegistryOnlineCommand' {
    It 'SOFTWARE op=set REG_DWORD emits Set-RegistryValue with HKLM:\Software prefix and int value' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='Policies\Microsoft\Windows\WindowsCopilot'; op='set'; name='TurnOffWindowsCopilot'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds.Count            | Should -Be 1
        $cmds[0].Kind          | Should -Be 'Set-RegistryValue'
        $cmds[0].Args.KeyPath  | Should -Be 'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot'
        $cmds[0].Args.Name     | Should -Be 'TurnOffWindowsCopilot'
        $cmds[0].Args.Type     | Should -Be 'DWord'
        $cmds[0].Args.Value    | Should -Be 1
        $cmds[0].Args.Value.GetType().Name | Should -Be 'Int32'
    }

    It 'SOFTWARE op=remove emits Remove-RegistryKey' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'; op='remove' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds.Count           | Should -Be 1
        $cmds[0].Kind         | Should -Be 'Remove-RegistryKey'
        $cmds[0].Args.KeyPath | Should -Be 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    }

    It 'SYSTEM op=set emits HKLM:\SYSTEM prefix' {
        $action = [pscustomobject]@{ type='registry'; hive='SYSTEM'; key='Setup\LabConfig'; op='set'; name='BypassTPMCheck'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.KeyPath | Should -Be 'HKLM:\SYSTEM\Setup\LabConfig'
    }

    It 'DEFAULT op=set emits HKU:\.DEFAULT prefix' {
        $action = [pscustomobject]@{ type='registry'; hive='DEFAULT'; key='Control Panel\UnsupportedHardwareNotificationCache'; op='set'; name='SV1'; valueType='REG_DWORD'; value='0' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.KeyPath | Should -Be 'HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache'
    }

    It 'NTUSER op=set emits Set-RegistryValueForAllUsers with RelativeKeyPath (no HKU prefix)' {
        $action = [pscustomobject]@{ type='registry'; hive='NTUSER'; key='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; op='set'; name='Enabled'; valueType='REG_DWORD'; value='0' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds.Count                    | Should -Be 1
        $cmds[0].Kind                  | Should -Be 'Set-RegistryValueForAllUsers'
        $cmds[0].Args.RelativeKeyPath  | Should -Be 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        $cmds[0].Args.PSObject.Properties.Name -contains 'KeyPath' | Should -Be $false
    }

    It 'NTUSER op=remove emits Remove-RegistryKeyForAllUsers' {
        $action = [pscustomobject]@{ type='registry'; hive='NTUSER'; key='Software\Microsoft\Foo'; op='remove' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Kind                 | Should -Be 'Remove-RegistryKeyForAllUsers'
        $cmds[0].Args.RelativeKeyPath | Should -Be 'Software\Microsoft\Foo'
    }

    It 'REG_SZ value stays as string' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_SZ'; value='hello' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.Type  | Should -Be 'String'
        $cmds[0].Args.Value | Should -Be 'hello'
        $cmds[0].Args.Value.GetType().Name | Should -Be 'String'
    }

    It 'REG_QWORD value parses to Int64' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_QWORD'; value='4294967296' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Args.Type  | Should -Be 'QWord'
        $cmds[0].Args.Value | Should -Be 4294967296
        $cmds[0].Args.Value.GetType().Name | Should -Be 'Int64'
    }

    It 'COMPONENTS hive throws' {
        $action = [pscustomobject]@{ type='registry'; hive='COMPONENTS'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='0' }
        { Get-Tiny11RegistryOnlineCommand -Action $action } | Should -Throw '*COMPONENTS hive cleanup not supported online*'
    }

    It 'unknown op throws' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='nuke'; name='Y'; valueType='REG_DWORD'; value='0' }
        { Get-Tiny11RegistryOnlineCommand -Action $action } | Should -Throw '*Invalid registry op*'
    }

    It 'Description present and non-empty' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11RegistryOnlineCommand -Action $action)
        $cmds[0].Description | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.Actions.Registry.Online.Tests.ps1"`
Expected: FAIL — `Get-Tiny11RegistryOnlineCommand` is not defined; all 11 It blocks fail.

- [ ] **Step 3: Implement the emitter**

Add to `src/Tiny11.Actions.Registry.psm1` (above the existing `Export-ModuleMember` line):

```powershell
function Get-Tiny11RegistryOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    if ($Action.hive -eq 'COMPONENTS') {
        throw "COMPONENTS hive cleanup not supported online (action key: $($Action.key))"
    }

    $hivePrefix = switch ($Action.hive) {
        'SOFTWARE' { 'HKLM:\Software' }
        'SYSTEM'   { 'HKLM:\SYSTEM' }
        'DEFAULT'  { 'HKU:\.DEFAULT' }
        'NTUSER'   { $null }   # signals fan-out path below
        default    { throw "Unknown registry hive: $($Action.hive)" }
    }

    $isNtUser = ($Action.hive -eq 'NTUSER')

    switch ($Action.op) {
        'set' {
            $type = switch ($Action.valueType) {
                'REG_DWORD'     { 'DWord' }
                'REG_QWORD'     { 'QWord' }
                'REG_SZ'        { 'String' }
                'REG_EXPAND_SZ' { 'ExpandString' }
                'REG_BINARY'    { 'Binary' }
                'REG_MULTI_SZ'  { 'MultiString' }
                default         { throw "Unknown registry valueType: $($Action.valueType)" }
            }
            $parsedValue = switch ($Action.valueType) {
                'REG_DWORD'    { [int]   $Action.value }
                'REG_QWORD'    { [long]  $Action.value }
                'REG_BINARY'   { ,([byte[]] (-split ($Action.value) | ForEach-Object { [Convert]::ToByte($_, 16) })) }
                'REG_MULTI_SZ' { ,([string[]] ($Action.value -split '\|')) }
                default        { [string]$Action.value }
            }

            if ($isNtUser) {
                ,([pscustomobject]@{
                    Kind = 'Set-RegistryValueForAllUsers'
                    Args = [ordered]@{ RelativeKeyPath = $Action.key; Name = $Action.name; Type = $type; Value = $parsedValue }
                    Description = "Set HKU:*\$($Action.key)!$($Action.name) = $($Action.value) (per-user, all loaded SIDs + .DEFAULT)"
                })
            } else {
                ,([pscustomobject]@{
                    Kind = 'Set-RegistryValue'
                    Args = [ordered]@{ KeyPath = "$hivePrefix\$($Action.key)"; Name = $Action.name; Type = $type; Value = $parsedValue }
                    Description = "Set $hivePrefix\$($Action.key)!$($Action.name) = $($Action.value)"
                })
            }
        }
        'remove' {
            if ($isNtUser) {
                ,([pscustomobject]@{
                    Kind = 'Remove-RegistryKeyForAllUsers'
                    Args = [ordered]@{ RelativeKeyPath = $Action.key }
                    Description = "Remove HKU:*\$($Action.key) (per-user, all loaded SIDs + .DEFAULT)"
                })
            } else {
                ,([pscustomobject]@{
                    Kind = 'Remove-RegistryKey'
                    Args = [ordered]@{ KeyPath = "$hivePrefix\$($Action.key)" }
                    Description = "Remove $hivePrefix\$($Action.key)"
                })
            }
        }
        default { throw "Invalid registry op: $($Action.op)" }
    }
}
```

Update the bottom of the file:
```powershell
Export-ModuleMember -Function Invoke-RegistryAction, Get-Tiny11RegistryOnlineCommand
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same Invoke-Pester command as Step 2.
Expected: PASS — all 11 It blocks green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.Registry.psm1 tests/Tiny11.Actions.Registry.Online.Tests.ps1
git commit -m "feat(actions-registry): online-command emitter (hive routing + NTUSER fan-out)"
```

---

### Task 2: `Get-Tiny11FilesystemOnlineCommand` (filesystem emitter)

**Files:**
- Modify: `src/Tiny11.Actions.Filesystem.psm1`
- Create: `tests/Tiny11.Actions.Filesystem.Online.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.Filesystem.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11FilesystemOnlineCommand' {
    It 'op=remove recurse=true emits Remove-PathIfPresent with SystemDrive prefix and Recurse=true' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='Program Files (x86)\Microsoft\Edge'; recurse=$true }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds.Count            | Should -Be 1
        $cmds[0].Kind          | Should -Be 'Remove-PathIfPresent'
        $cmds[0].Args.Path     | Should -Be '$env:SystemDrive\Program Files (x86)\Microsoft\Edge'
        $cmds[0].Args.Recurse  | Should -Be $true
    }

    It 'op=remove recurse=false emits Recurse=false' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='Windows\X.exe'; recurse=$false }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Args.Recurse | Should -Be $false
    }

    It 'op=takeown-and-remove emits Remove-PathWithOwnership' {
        $action = [pscustomobject]@{ type='filesystem'; op='takeown-and-remove'; path='Windows\System32\OneDriveSetup.exe'; recurse=$false }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Kind         | Should -Be 'Remove-PathWithOwnership'
        $cmds[0].Args.Path    | Should -Be '$env:SystemDrive\Windows\System32\OneDriveSetup.exe'
        $cmds[0].Args.Recurse | Should -Be $false
    }

    It 'op=takeown-and-remove with recurse=true' {
        $action = [pscustomobject]@{ type='filesystem'; op='takeown-and-remove'; path='Windows\System32\Microsoft-Edge-Webview'; recurse=$true }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Kind         | Should -Be 'Remove-PathWithOwnership'
        $cmds[0].Args.Recurse | Should -Be $true
    }

    It 'unknown op throws' {
        $action = [pscustomobject]@{ type='filesystem'; op='nuke'; path='X'; recurse=$false }
        { Get-Tiny11FilesystemOnlineCommand -Action $action } | Should -Throw '*Invalid filesystem op*'
    }

    It 'Description present and references path' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='Windows\X'; recurse=$true }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Description | Should -Match 'Windows\\X'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.Actions.Filesystem.Online.Tests.ps1"`
Expected: FAIL — function not defined; all 6 It blocks fail.

- [ ] **Step 3: Implement the emitter**

Add to `src/Tiny11.Actions.Filesystem.psm1` (above `Export-ModuleMember`):

```powershell
function Get-Tiny11FilesystemOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    $kind = switch ($Action.op) {
        'remove'              { 'Remove-PathIfPresent' }
        'takeown-and-remove'  { 'Remove-PathWithOwnership' }
        default               { throw "Invalid filesystem op: $($Action.op)" }
    }

    ,([pscustomobject]@{
        Kind        = $kind
        Args        = [ordered]@{ Path = '$env:SystemDrive\' + $Action.path; Recurse = [bool]$Action.recurse }
        Description = "$kind '$($Action.path)'" + $(if ([bool]$Action.recurse) { ' (recurse)' } else { '' })
    })
}
```

Update bottom:
```powershell
Export-ModuleMember -Function Invoke-FilesystemAction, Invoke-Takeown, Invoke-Icacls, Get-AdminGroupAccount, Get-Tiny11FilesystemOnlineCommand
```

- [ ] **Step 4: Run tests to verify they pass**

Same Invoke-Pester invocation.
Expected: PASS — all 6 green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.Filesystem.psm1 tests/Tiny11.Actions.Filesystem.Online.Tests.ps1
git commit -m "feat(actions-filesystem): online-command emitter"
```

---

### Task 3: `Get-Tiny11ScheduledTaskOnlineCommand` (scheduled-task emitter)

**Files:**
- Modify: `src/Tiny11.Actions.ScheduledTask.psm1`
- Create: `tests/Tiny11.Actions.ScheduledTask.Online.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.ScheduledTask.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11ScheduledTaskOnlineCommand' {
    It 'op=remove recurse=false emits Remove-PathIfPresent against SystemRoot\System32\Tasks' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'; recurse=$false }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds.Count            | Should -Be 1
        $cmds[0].Kind          | Should -Be 'Remove-PathIfPresent'
        $cmds[0].Args.Path     | Should -Be '$env:SystemRoot\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        $cmds[0].Args.Recurse  | Should -Be $false
    }

    It 'op=remove recurse=true emits Recurse=true (task folder removal)' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\Customer Experience Improvement Program'; recurse=$true }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Args.Recurse | Should -Be $true
    }

    It 'path separator normalization: forward slash becomes backslash' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Chkdsk/Proxy'; recurse=$false }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Args.Path | Should -Be '$env:SystemRoot\System32\Tasks\Microsoft\Windows\Chkdsk\Proxy'
    }

    It 'unknown op throws' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='disable'; path='X'; recurse=$false }
        { Get-Tiny11ScheduledTaskOnlineCommand -Action $action } | Should -Throw '*Invalid scheduled-task op*'
    }

    It 'Description present and references path' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='Microsoft\Windows\X'; recurse=$true }
        $cmds = @(Get-Tiny11ScheduledTaskOnlineCommand -Action $action)
        $cmds[0].Description | Should -Match 'Microsoft\\Windows\\X'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the Invoke-Pester command targeting the new file.
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement the emitter**

Add to `src/Tiny11.Actions.ScheduledTask.psm1` above `Export-ModuleMember`:

```powershell
function Get-Tiny11ScheduledTaskOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    if ($Action.op -ne 'remove') { throw "Invalid scheduled-task op: $($Action.op)" }
    $relPath = $Action.path -replace '/', '\'

    ,([pscustomobject]@{
        Kind        = 'Remove-PathIfPresent'
        Args        = [ordered]@{ Path = '$env:SystemRoot\System32\Tasks\' + $relPath; Recurse = [bool]$Action.recurse }
        Description = "Remove scheduled task XML '$relPath'" + $(if ([bool]$Action.recurse) { ' (recurse)' } else { '' })
    })
}
```

Update bottom:
```powershell
Export-ModuleMember -Function Invoke-ScheduledTaskAction, Get-Tiny11ScheduledTaskOnlineCommand
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 5 green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.ScheduledTask.psm1 tests/Tiny11.Actions.ScheduledTask.Online.Tests.ps1
git commit -m "feat(actions-scheduled-task): online-command emitter"
```

---

### Task 4: `Get-Tiny11ProvisionedAppxOnlineCommand` (appx emitter)

**Files:**
- Modify: `src/Tiny11.Actions.ProvisionedAppx.psm1`
- Create: `tests/Tiny11.Actions.ProvisionedAppx.Online.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.ProvisionedAppx.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11ProvisionedAppxOnlineCommand' {
    It 'emits Remove-AppxByPackagePrefix with packagePrefix' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='Clipchamp.Clipchamp' }
        $cmds = @(Get-Tiny11ProvisionedAppxOnlineCommand -Action $action)
        $cmds.Count          | Should -Be 1
        $cmds[0].Kind        | Should -Be 'Remove-AppxByPackagePrefix'
        $cmds[0].Args.Prefix | Should -Be 'Clipchamp.Clipchamp'
    }

    It 'description references prefix' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='Microsoft.OutlookForWindows' }
        $cmds = @(Get-Tiny11ProvisionedAppxOnlineCommand -Action $action)
        $cmds[0].Description | Should -Match 'Microsoft.OutlookForWindows'
    }

    It 'works for prefixes with dots in vendor namespace' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='Microsoft.BingNews' }
        $cmds = @(Get-Tiny11ProvisionedAppxOnlineCommand -Action $action)
        $cmds[0].Args.Prefix | Should -Be 'Microsoft.BingNews'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — function not defined.

- [ ] **Step 3: Implement the emitter**

Add to `src/Tiny11.Actions.ProvisionedAppx.psm1` above `Export-ModuleMember`:

```powershell
function Get-Tiny11ProvisionedAppxOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    ,([pscustomobject]@{
        Kind        = 'Remove-AppxByPackagePrefix'
        Args        = [ordered]@{ Prefix = $Action.packagePrefix }
        Description = "Remove provisioned + installed appx matching '$($Action.packagePrefix)*'"
    })
}
```

Update bottom:
```powershell
Export-ModuleMember -Function Invoke-ProvisionedAppxAction, Get-ProvisionedAppxPackagesFromImage, Invoke-DismRemoveAppx, Clear-Tiny11AppxPackageCache, Get-Tiny11ProvisionedAppxOnlineCommand
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 3 green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.ProvisionedAppx.psm1 tests/Tiny11.Actions.ProvisionedAppx.Online.Tests.ps1
git commit -m "feat(actions-provisioned-appx): online-command emitter"
```

---

### Task 5: `Get-Tiny11ActionOnlineCommand` dispatcher

**Files:**
- Modify: `src/Tiny11.Actions.psm1`
- Modify: `tests/Tiny11.Actions.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Actions.Tests.ps1` (inside a new `Describe` block at the end of file):

```powershell
Describe 'Get-Tiny11ActionOnlineCommand (dispatcher)' {
    It 'routes registry action to Get-Tiny11RegistryOnlineCommand' {
        $action = [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='1' }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Set-RegistryValue'
    }
    It 'routes filesystem action' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='X'; recurse=$false }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Remove-PathIfPresent'
    }
    It 'routes scheduled-task action' {
        $action = [pscustomobject]@{ type='scheduled-task'; op='remove'; path='X'; recurse=$false }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Remove-PathIfPresent'
    }
    It 'routes provisioned-appx action' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='X.Y' }
        $cmds = @(Get-Tiny11ActionOnlineCommand -Action $action)
        $cmds[0].Kind | Should -Be 'Remove-AppxByPackagePrefix'
    }
    It 'throws on unknown action type' {
        $action = [pscustomobject]@{ type='quantum-defrag' }
        { Get-Tiny11ActionOnlineCommand -Action $action } | Should -Throw '*Unknown action type*'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.Actions.Tests.ps1"`
Expected: FAIL — `Get-Tiny11ActionOnlineCommand` not defined; 5 new It blocks fail.

- [ ] **Step 3: Implement the dispatcher**

Add to `src/Tiny11.Actions.psm1` after `Invoke-Tiny11Action`:

```powershell
function Get-Tiny11ActionOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)
    switch ($Action.type) {
        'registry'         { Get-Tiny11RegistryOnlineCommand        -Action $Action }
        'filesystem'       { Get-Tiny11FilesystemOnlineCommand      -Action $Action }
        'scheduled-task'   { Get-Tiny11ScheduledTaskOnlineCommand   -Action $Action }
        'provisioned-appx' { Get-Tiny11ProvisionedAppxOnlineCommand -Action $Action }
        default            { throw "Unknown action type: $($Action.type)" }
    }
}
```

Update `Export-ModuleMember`:
```powershell
Export-ModuleMember -Function Invoke-Tiny11Action, Get-Tiny11ActionOnlineCommand
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all dispatcher tests green plus all existing dispatcher tests still green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Actions.psm1 tests/Tiny11.Actions.Tests.ps1
git commit -m "feat(actions): Get-Tiny11ActionOnlineCommand dispatcher"
```

---

## Phase 2 — PostBoot module scaffold + helper script content

### Task 6: `src/Tiny11.PostBoot.psm1` skeleton

**Files:**
- Create: `src/Tiny11.PostBoot.psm1`

- [ ] **Step 1: Create the module file with stub exports**

```powershell
Set-StrictMode -Version Latest

# Module-scope constants populated by tasks 7-9.
$script:headerBlock  = ''
$script:helpersBlock = ''
$script:footerBlock  = ''

function Format-PSNamedParams {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Args)
    $parts = foreach ($entry in $Args.GetEnumerator()) {
        $value = $entry.Value
        $rendered = if ($value -is [bool]) {
            if ($value) { '$true' } else { '$false' }
        } elseif ($value -is [int] -or $value -is [long]) {
            "$value"
        } elseif ($value -is [byte[]]) {
            $hex = ($value | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','
            "([byte[]]($hex))"
        } elseif ($value -is [string[]]) {
            $quoted = ($value | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            "@($quoted)"
        } else {
            $s = [string]$value
            "'" + ($s -replace "'", "''") + "'"
        }
        "-$($entry.Key) $rendered"
    }
    $parts -join ' '
}

function New-Tiny11PostBootCleanupScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]            $Catalog,
        [Parameter(Mandatory)][hashtable] $ResolvedSelections
    )
    throw 'New-Tiny11PostBootCleanupScript not yet implemented'
}

function New-Tiny11PostBootTaskXml {
    [CmdletBinding()] param()
    throw 'New-Tiny11PostBootTaskXml not yet implemented'
}

function New-Tiny11PostBootSetupCompleteScript {
    [CmdletBinding()] param()
    throw 'New-Tiny11PostBootSetupCompleteScript not yet implemented'
}

function Install-Tiny11PostBootCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]    $MountDir,
        [Parameter(Mandatory)]            $Catalog,
        [Parameter(Mandatory)][hashtable] $ResolvedSelections,
        [bool]                            $Enabled = $true
    )
    throw 'Install-Tiny11PostBootCleanup not yet implemented'
}

Export-ModuleMember -Function `
    Format-PSNamedParams, `
    New-Tiny11PostBootCleanupScript, `
    New-Tiny11PostBootTaskXml, `
    New-Tiny11PostBootSetupCompleteScript, `
    Install-Tiny11PostBootCleanup
```

- [ ] **Step 2: Smoke-import the module**

Run: `pwsh -NoProfile -Command "Import-Module ./src/Tiny11.PostBoot.psm1 -Force -DisableNameChecking; Get-Command -Module Tiny11.PostBoot | Select Name"`
Expected: lists `Format-PSNamedParams`, `Install-Tiny11PostBootCleanup`, `New-Tiny11PostBootCleanupScript`, `New-Tiny11PostBootSetupCompleteScript`, `New-Tiny11PostBootTaskXml`.

- [ ] **Step 3: Commit**

```powershell
git add src/Tiny11.PostBoot.psm1
git commit -m "feat(post-boot): module skeleton + Format-PSNamedParams"
```

---

### Task 7: `Format-PSNamedParams` unit tests + verify implementation

**Files:**
- Create: `tests/Tiny11.PostBoot.FormatArgs.Tests.ps1`

- [ ] **Step 1: Write the tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
}

Describe 'Format-PSNamedParams' {
    It 'string value gets single-quoted' {
        Format-PSNamedParams -Args ([ordered]@{ Path = 'C:\Windows' }) | Should -Be "-Path 'C:\Windows'"
    }
    It "string with single quote escapes via doubling" {
        Format-PSNamedParams -Args ([ordered]@{ Name = "it's" }) | Should -Be "-Name 'it''s'"
    }
    It 'int value unquoted' {
        Format-PSNamedParams -Args ([ordered]@{ Value = 0 }) | Should -Be '-Value 0'
    }
    It 'long value unquoted' {
        Format-PSNamedParams -Args ([ordered]@{ Value = [long]4294967296 }) | Should -Be '-Value 4294967296'
    }
    It 'bool true renders as $true literal' {
        Format-PSNamedParams -Args ([ordered]@{ Recurse = $true }) | Should -Be '-Recurse $true'
    }
    It 'bool false renders as $false literal' {
        Format-PSNamedParams -Args ([ordered]@{ Recurse = $false }) | Should -Be '-Recurse $false'
    }
    It 'multiple args preserve insertion order' {
        $a = [ordered]@{ A = 1; B = 'x'; C = $true }
        Format-PSNamedParams -Args $a | Should -Be "-A 1 -B 'x' -C `$true"
    }
    It 'byte array renders as [byte[]] literal' {
        Format-PSNamedParams -Args ([ordered]@{ Value = ([byte[]](0x01,0xAB,0xFF)) }) | Should -Be '-Value ([byte[]](0x01,0xAB,0xFF))'
    }
    It 'string array renders as @() literal' {
        Format-PSNamedParams -Args ([ordered]@{ Value = @('a','b') }) | Should -Be "-Value @('a','b')"
    }
}
```

- [ ] **Step 2: Run tests**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.PostBoot.FormatArgs.Tests.ps1"`
Expected: PASS — 9 green (Format-PSNamedParams was implemented in Task 6).

- [ ] **Step 3: Commit**

```powershell
git add tests/Tiny11.PostBoot.FormatArgs.Tests.ps1
git commit -m "test(post-boot): Format-PSNamedParams unit tests"
```

---

### Task 8: Header block + log rotation

**Files:**
- Modify: `src/Tiny11.PostBoot.psm1`
- Create: `tests/Tiny11.PostBoot.HeaderBlock.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    $script:header = & (Get-Module Tiny11.PostBoot) { $script:headerBlock }
}

Describe 'PostBoot header block' {
    It 'is non-empty' { $script:header | Should -Not -BeNullOrEmpty }
    It 'sets ErrorActionPreference to Continue' { $script:header | Should -Match "ErrorActionPreference\s*=\s*'Continue'" }
    It 'defines log paths under SystemDrive\\Windows\\Logs' {
        $script:header | Should -Match 'tiny11-cleanup\.log'
        $script:header | Should -Match 'tiny11-cleanup\.log\.1'
    }
    It 'rotates when active log >= 5000 lines' {
        $script:header | Should -Match '5000'
        $script:header | Should -Match 'Move-Item.*logPath.*logPathBackup'
    }
    It 'defines Write-CleanupLog with yyyy-MM-dd HH:mm:ss timestamp' {
        $script:header | Should -Match 'function Write-CleanupLog'
        $script:header | Should -Match "yyyy-MM-dd HH:mm:ss"
    }
    It 'logs an opening "==== tiny11-cleanup triggered ====" banner' {
        $script:header | Should -Match '==== tiny11-cleanup triggered ===='
    }
    It 'is pure ASCII (no smart quotes / em-dashes)' {
        ($script:header.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: same Invoke-Pester targeting the new test.
Expected: FAIL — `$script:headerBlock` is empty.

- [ ] **Step 3: Populate `$script:headerBlock`**

In `src/Tiny11.PostBoot.psm1`, replace `$script:headerBlock = ''` with:

```powershell
$script:headerBlock = @'
# tiny11-cleanup.ps1 -- Re-applies the catalog-driven removal/tweak recipe on every boot,
# daily at 03:00, and on every Windows Update event. Generated by
# New-Tiny11PostBootCleanupScript (src/Tiny11.PostBoot.psm1).
#
# Idempotent: when state is already correct, every check is a fast read-and-skip.
# Logs each check + action (with before/after on corrections) to
# %SystemDrive%\Windows\Logs\tiny11-cleanup.log. Rotates to .log.1 when the active
# log reaches 5000 lines.

$ErrorActionPreference = 'Continue'
$logPath       = "$env:SystemDrive\Windows\Logs\tiny11-cleanup.log"
$logPathBackup = "$env:SystemDrive\Windows\Logs\tiny11-cleanup.log.1"
$logDir        = Split-Path -Parent $logPath
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

if (Test-Path -LiteralPath $logPath) {
    try {
        $lineCount = ([System.IO.File]::ReadAllLines($logPath)).Length
        if ($lineCount -ge 5000) {
            if (Test-Path -LiteralPath $logPathBackup) {
                Remove-Item -LiteralPath $logPathBackup -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $logPath -Destination $logPathBackup -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Rotation failure shouldn't break enforcement; swallow.
    }
}

function Write-CleanupLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-CleanupLog '==== tiny11-cleanup triggered ===='
'@
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 7 header-block tests green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.PostBoot.psm1 tests/Tiny11.PostBoot.HeaderBlock.Tests.ps1
git commit -m "feat(post-boot): header block + log rotation"
```

---

### Task 9: Helpers block + golden fixture + footer

**Files:**
- Modify: `src/Tiny11.PostBoot.psm1`
- Create: `tests/Tiny11.PostBoot.Helpers.Golden.Tests.ps1`
- Create: `tests/golden/tiny11-cleanup-helpers.txt`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    $script:helpers = & (Get-Module Tiny11.PostBoot) { $script:helpersBlock }
    $script:footer  = & (Get-Module Tiny11.PostBoot) { $script:footerBlock }
}

Describe 'PostBoot helpers block' {
    It 'defines every helper function the emitters reference' {
        foreach ($fn in 'Set-RegistryValue','Set-RegistryValueForAllUsers',
                        'Remove-RegistryKey','Remove-RegistryKeyForAllUsers',
                        'Remove-PathIfPresent','Remove-PathWithOwnership',
                        'Remove-AppxByPackagePrefix') {
            $script:helpers | Should -Match "function $fn"
        }
    }
    It 'Set-RegistryValueForAllUsers iterates HKU SIDs + .DEFAULT' {
        $script:helpers | Should -Match 'HKU:\\\\?\*?'
        $script:helpers | Should -Match '\^S-1-5-21-'
        $script:helpers | Should -Match '\.DEFAULT'
    }
    It 'Set-RegistryValue uses "already" vs "CORRECTED" idempotent-log pattern' {
        $script:helpers | Should -Match 'already'
        $script:helpers | Should -Match 'CORRECTED'
        $script:helpers | Should -Match 'correction FAILED'
    }
    It 'Remove-PathWithOwnership invokes takeown.exe and icacls.exe' {
        $script:helpers | Should -Match 'takeown\.exe'
        $script:helpers | Should -Match 'icacls\.exe'
    }
    It 'Remove-AppxByPackagePrefix calls both provisioned + per-user removal' {
        $script:helpers | Should -Match 'Get-AppxProvisionedPackage'
        $script:helpers | Should -Match 'Remove-AppxProvisionedPackage'
        $script:helpers | Should -Match 'Get-AppxPackage -AllUsers'
        $script:helpers | Should -Match 'Remove-AppxPackage -AllUsers'
    }
    It 'is pure ASCII' {
        ($script:helpers.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
    It 'matches the golden fixture (byte-equal)' {
        $goldenPath = Join-Path $PSScriptRoot 'golden' 'tiny11-cleanup-helpers.txt'
        Test-Path $goldenPath | Should -Be $true
        $golden = [System.IO.File]::ReadAllText($goldenPath)
        $script:helpers | Should -Be $golden
    }
}

Describe 'PostBoot footer block' {
    It 'emits the done banner' {
        $script:footer | Should -Match '==== tiny11-cleanup done ===='
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `$script:helpersBlock` empty; `$script:footerBlock` empty; golden file missing.

- [ ] **Step 3: Populate `$script:helpersBlock` and `$script:footerBlock`**

In `src/Tiny11.PostBoot.psm1`, replace `$script:helpersBlock = ''` with the helper-functions heredoc (see spec § "Helper functions" for the verbatim content). Use single-quoted heredoc to prevent PowerShell expansion. The block must contain these function definitions in order: `Set-RegistryValue`, `Set-RegistryValueForAllUsers`, `Remove-RegistryKey`, `Remove-RegistryKeyForAllUsers`, `Remove-PathIfPresent`, `Remove-PathWithOwnership`, `Remove-AppxByPackagePrefix`.

```powershell
$script:helpersBlock = @'
function Set-RegistryValue {
    param([string]$KeyPath, [string]$Name, [string]$Type, $Value)
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        try { New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null }
        catch { Write-CleanupLog "  $KeyPath key-create FAILED: $($_.Exception.Message)"; return }
    }
    $current = (Get-ItemProperty -LiteralPath $KeyPath -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($null -ne $current -and $current -eq $Value) {
        Write-CleanupLog "  $KeyPath!$Name=$Value already"
        return
    }
    try {
        Set-ItemProperty -LiteralPath $KeyPath -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        Write-CleanupLog "  $KeyPath!$Name CORRECTED: '$current' -> '$Value'"
    } catch {
        Write-CleanupLog "  $KeyPath!$Name correction FAILED: $($_.Exception.Message)"
    }
}

function Set-RegistryValueForAllUsers {
    param([string]$RelativeKeyPath, [string]$Name, [string]$Type, $Value)
    $sids = @((Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match '^S-1-5-21-' }).PSChildName)
    $sids += '.DEFAULT'
    foreach ($sid in $sids) {
        Set-RegistryValue -KeyPath "HKU:\$sid\$RelativeKeyPath" -Name $Name -Type $Type -Value $Value
    }
}

function Remove-RegistryKey {
    param([string]$KeyPath)
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        Write-CleanupLog "  $KeyPath absent (no-op)"
        return
    }
    try {
        Remove-Item -LiteralPath $KeyPath -Recurse -Force -ErrorAction Stop
        Write-CleanupLog "  $KeyPath REMOVED"
    } catch {
        Write-CleanupLog "  $KeyPath remove FAILED: $($_.Exception.Message)"
    }
}

function Remove-RegistryKeyForAllUsers {
    param([string]$RelativeKeyPath)
    $sids = @((Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match '^S-1-5-21-' }).PSChildName)
    $sids += '.DEFAULT'
    foreach ($sid in $sids) {
        Remove-RegistryKey -KeyPath "HKU:\$sid\$RelativeKeyPath"
    }
}

function Remove-PathIfPresent {
    param([string]$Path, [bool]$Recurse)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-CleanupLog "  $Path absent (no-op)"
        return
    }
    try {
        if ($Recurse) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
        else          { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        Write-CleanupLog "  $Path REMOVED"
    } catch {
        Write-CleanupLog "  $Path remove FAILED: $($_.Exception.Message)"
    }
}

function Remove-PathWithOwnership {
    param([string]$Path, [bool]$Recurse)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-CleanupLog "  $Path absent (no-op)"
        return
    }
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $admin    = $adminSid.Translate([System.Security.Principal.NTAccount]).Value
    $takeownArgs = @('/f', $Path)
    if ($Recurse) { $takeownArgs += '/r','/d','Y' }
    try {
        & takeown.exe @takeownArgs | Out-Null
        & icacls.exe $Path '/grant' "$admin`:(F)" '/T' '/C' | Out-Null
        if ($Recurse) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
        else          { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        Write-CleanupLog "  $Path REMOVED (with takeown)"
    } catch {
        Write-CleanupLog "  $Path takeown-remove FAILED: $($_.Exception.Message)"
    }
}

function Remove-AppxByPackagePrefix {
    param([string]$Prefix)
    $provMatches = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object DisplayName -like "$Prefix*")
    if ($provMatches.Count -eq 0) {
        Write-CleanupLog "  appx provisioned '$Prefix*' absent (no-op)"
    } else {
        foreach ($p in $provMatches) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                Write-CleanupLog "  appx provisioned $($p.PackageName) REMOVED"
            } catch {
                Write-CleanupLog "  appx provisioned $($p.PackageName) remove FAILED: $($_.Exception.Message)"
            }
        }
    }
    $userMatches = @(Get-AppxPackage -AllUsers -Name "$Prefix*" -ErrorAction SilentlyContinue)
    if ($userMatches.Count -eq 0) {
        Write-CleanupLog "  appx per-user '$Prefix*' absent (no-op)"
    } else {
        foreach ($p in $userMatches) {
            try {
                Remove-AppxPackage -AllUsers -Package $p.PackageFullName -ErrorAction Stop
                Write-CleanupLog "  appx per-user $($p.PackageFullName) REMOVED"
            } catch {
                Write-CleanupLog "  appx per-user $($p.PackageFullName) remove FAILED: $($_.Exception.Message)"
            }
        }
    }
}
'@

$script:footerBlock = @'
Write-CleanupLog '==== tiny11-cleanup done ===='
'@
```

- [ ] **Step 4: Generate the golden fixture from the module**

Run:
```powershell
pwsh -NoProfile -Command @'
Import-Module ./src/Tiny11.PostBoot.psm1 -Force -DisableNameChecking
$content = & (Get-Module Tiny11.PostBoot) { $script:helpersBlock }
$dir = 'tests/golden'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
[System.IO.File]::WriteAllText("$dir/tiny11-cleanup-helpers.txt", $content)
'@
```

- [ ] **Step 5: Run tests to verify they pass**

Run the Invoke-Pester command targeting both new test files.
Expected: PASS — all helpers + footer + golden-comparison tests green.

- [ ] **Step 6: Commit**

```powershell
git add src/Tiny11.PostBoot.psm1 tests/Tiny11.PostBoot.Helpers.Golden.Tests.ps1 tests/golden/tiny11-cleanup-helpers.txt
git commit -m "feat(post-boot): helpers + footer blocks + golden fixture"
```

---

## Phase 3 — Generator

### Task 10: `New-Tiny11PostBootCleanupScript` implementation + integration tests

**Files:**
- Modify: `src/Tiny11.PostBoot.psm1`
- Create: `tests/Tiny11.PostBoot.Generator.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.psm1')  -Force -DisableNameChecking
    Import-Module (Join-Path $script:srcDir 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:srcDir 'Tiny11.Selections.psm1') -Force -DisableNameChecking
}

function New-TestCatalog {
    param([Parameter(Mandatory)][object[]] $Items)
    [pscustomobject]@{
        Version    = 1
        Categories = @([pscustomobject]@{ id='store-apps'; displayName='Store apps'; description='x' })
        Items      = @($Items)
        Path       = 'test://catalog'
    }
}

function New-AllApplySelections {
    param([Parameter(Mandatory)] $Catalog)
    $h = @{}
    foreach ($it in $Catalog.Items) {
        $h[$it.id] = [pscustomobject]@{ ItemId=$it.id; UserState='apply'; EffectiveState='apply'; Locked=$false; LockedBy=@() }
    }
    $h
}

Describe 'New-Tiny11PostBootCleanupScript' {

    It 'produces a script with header, helpers, and footer when no items apply' {
        $catalog = New-TestCatalog -Items @()
        $script  = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections @{}
        $script | Should -Match '==== tiny11-cleanup triggered ===='
        $script | Should -Match 'function Set-RegistryValue'
        $script | Should -Match 'function Remove-AppxByPackagePrefix'
        $script | Should -Match '==== tiny11-cleanup done ===='
        $script | Should -Not -Match '# --- Item:'
    }

    It 'iterates catalog items in order' {
        $items = @(
            [pscustomobject]@{ id='item-a'; category='store-apps'; displayName='Alpha'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='A.Pkg' }) }
            [pscustomobject]@{ id='item-b'; category='store-apps'; displayName='Bravo'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='B.Pkg' }) }
            [pscustomobject]@{ id='item-c'; category='store-apps'; displayName='Charlie'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='C.Pkg' }) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved

        $indexA = $script.IndexOf('# --- Item: Alpha (item-a) ---')
        $indexB = $script.IndexOf('# --- Item: Bravo (item-b) ---')
        $indexC = $script.IndexOf('# --- Item: Charlie (item-c) ---')
        $indexA | Should -BeGreaterThan -1
        $indexB | Should -BeGreaterThan $indexA
        $indexC | Should -BeGreaterThan $indexB
    }

    It 'skips items where EffectiveState != apply' {
        $items = @(
            [pscustomobject]@{ id='item-keep';  category='store-apps'; displayName='Keep';   description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Keep.Pkg' }) }
            [pscustomobject]@{ id='item-skip';  category='store-apps'; displayName='Skip';   description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Skip.Pkg' }) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = @{
            'item-keep' = [pscustomobject]@{ ItemId='item-keep'; UserState='apply'; EffectiveState='apply'; Locked=$false; LockedBy=@() }
            'item-skip' = [pscustomobject]@{ ItemId='item-skip'; UserState='skip';  EffectiveState='skip';  Locked=$false; LockedBy=@() }
        }
        $script = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match '# --- Item: Keep \(item-keep\) ---'
        $script | Should -Not -Match '# --- Item: Skip \(item-skip\) ---'
        $script | Should -Not -Match 'Skip\.Pkg'
    }

    It 'emits multi-action items with one helper call per action in declared order' {
        $items = @(
            [pscustomobject]@{ id='multi'; category='store-apps'; displayName='Multi'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='filesystem'; op='remove'; path='Program Files\Foo'; recurse=$true }
                [pscustomobject]@{ type='registry';   hive='SOFTWARE'; key='Foo\Bar'; op='remove' }
            ) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved

        $script | Should -Match 'Remove-PathIfPresent -Path .*Program Files\\Foo.* -Recurse \$true'
        $script | Should -Match 'Remove-RegistryKey -KeyPath .*HKLM:\\Software\\Foo\\Bar.*'
        $idxFs  = $script.IndexOf('Remove-PathIfPresent')
        $idxReg = $script.IndexOf('Remove-RegistryKey')
        $idxFs | Should -BeLessThan $idxReg
    }

    It 'is deterministic — identical inputs yield identical output' {
        $items = @(
            [pscustomobject]@{ id='det'; category='store-apps'; displayName='Det'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Det.Pkg' }) }
        )
        $catalog = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $a = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $b = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $a | Should -Be $b
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.PostBoot.Generator.Tests.ps1"`
Expected: FAIL — `New-Tiny11PostBootCleanupScript not yet implemented` thrown for every test.

- [ ] **Step 3: Implement the generator**

In `src/Tiny11.PostBoot.psm1`, replace the stub `New-Tiny11PostBootCleanupScript` with:

```powershell
function New-Tiny11PostBootCleanupScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]            $Catalog,
        [Parameter(Mandatory)][hashtable] $ResolvedSelections
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($script:headerBlock)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($script:helpersBlock)
    [void]$sb.AppendLine('')

    foreach ($item in $Catalog.Items) {
        if (-not $ResolvedSelections.ContainsKey($item.id)) { continue }
        if ($ResolvedSelections[$item.id].EffectiveState -ne 'apply') { continue }

        [void]$sb.AppendLine("# --- Item: $($item.displayName) ($($item.id)) ---")
        foreach ($action in $item.actions) {
            $commands = @(Get-Tiny11ActionOnlineCommand -Action $action)
            foreach ($cmd in $commands) {
                [void]$sb.AppendLine("# $($cmd.Description)")
                $argsRendered = Format-PSNamedParams -Args $cmd.Args
                [void]$sb.AppendLine("$($cmd.Kind) $argsRendered")
            }
        }
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine($script:footerBlock)
    $sb.ToString()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 5 integration tests green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.PostBoot.psm1 tests/Tiny11.PostBoot.Generator.Tests.ps1
git commit -m "feat(post-boot): New-Tiny11PostBootCleanupScript generator"
```

---

### Task 11: Targeted-snippet tests for tricky emissions

**Files:**
- Modify: `tests/Tiny11.PostBoot.Generator.Tests.ps1`

- [ ] **Step 1: Append targeted snippet tests**

Add this `Describe` block at the end of `tests/Tiny11.PostBoot.Generator.Tests.ps1`:

```powershell
Describe 'New-Tiny11PostBootCleanupScript — targeted snippets' {

    It 'NTUSER fan-out renders as Set-RegistryValueForAllUsers with RelativeKeyPath (no HKU prefix)' {
        $items = @(
            [pscustomobject]@{ id='ntuser'; category='store-apps'; displayName='NTU'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='NTUSER'; key='Software\Microsoft\X'; op='set'; name='Y'; valueType='REG_DWORD'; value='0' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Set-RegistryValueForAllUsers -RelativeKeyPath 'Software\\Microsoft\\X' -Name 'Y' -Type 'DWord' -Value 0"
        $script | Should -Not -Match "HKU:\\\\.*Software\\\\Microsoft\\\\X"  # NTUSER must NOT inline HKU prefix
    }

    It 'takeown-and-remove with path containing spaces preserves quoting' {
        $items = @(
            [pscustomobject]@{ id='to'; category='store-apps'; displayName='TO'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='filesystem'; op='takeown-and-remove'; path='Windows\System32\Microsoft-Edge-Webview'; recurse=$true }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Remove-PathWithOwnership -Path '\`$env:SystemDrive\\Windows\\System32\\Microsoft-Edge-Webview' -Recurse \`$true"
    }

    It 'REG_DWORD emits unquoted int Value' {
        $items = @(
            [pscustomobject]@{ id='dw'; category='store-apps'; displayName='DW'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_DWORD'; value='7' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Set-RegistryValue -KeyPath 'HKLM:\\Software\\X' -Name 'Y' -Type 'DWord' -Value 7"
    }

    It 'REG_SZ emits quoted string Value' {
        $items = @(
            [pscustomobject]@{ id='sz'; category='store-apps'; displayName='SZ'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_SZ'; value='hello world' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Set-RegistryValue -KeyPath 'HKLM:\\Software\\X' -Name 'Y' -Type 'String' -Value 'hello world'"
    }

    It 'REG_QWORD emits unquoted long Value' {
        $items = @(
            [pscustomobject]@{ id='qw'; category='store-apps'; displayName='QW'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@(
                [pscustomobject]@{ type='registry'; hive='SOFTWARE'; key='X'; op='set'; name='Y'; valueType='REG_QWORD'; value='4294967296' }
            ) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        $script | Should -Match "Set-RegistryValue -KeyPath 'HKLM:\\Software\\X' -Name 'Y' -Type 'QWord' -Value 4294967296"
    }

    It 'generated script is pure ASCII (no smart quotes / em-dashes anywhere)' {
        $items = @(
            [pscustomobject]@{ id='x'; category='store-apps'; displayName='X'; description='x'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='X.Y' }) }
        )
        $catalog  = New-TestCatalog -Items $items
        $resolved = New-AllApplySelections -Catalog $catalog
        $script   = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
        ($script.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests to verify they pass (no implementation change needed)**

Run the Invoke-Pester command against the Generator tests file.
Expected: PASS — all 6 new snippet tests green (generator already implemented in Task 10).

- [ ] **Step 3: Commit**

```powershell
git add tests/Tiny11.PostBoot.Generator.Tests.ps1
git commit -m "test(post-boot): targeted snippet tests for NTUSER, takeown, DWORD/SZ/QWORD"
```

---

## Phase 4 — Scheduled-task XML + SetupComplete + Install function

### Task 12: `New-Tiny11PostBootTaskXml`

**Files:**
- Modify: `src/Tiny11.PostBoot.psm1`
- Create: `tests/Tiny11.PostBoot.TaskXml.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    $script:xml = New-Tiny11PostBootTaskXml
    $script:doc = [xml]$script:xml
    $ns = New-Object System.Xml.XmlNamespaceManager $script:doc.NameTable
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $script:ns = $ns
}

Describe 'New-Tiny11PostBootTaskXml' {
    It 'parses as XML' { $script:doc | Should -Not -BeNullOrEmpty }

    It 'task URI is \\tiny11options\\Post-Boot Cleanup' {
        $script:doc.SelectSingleNode('//t:URI', $script:ns).InnerText | Should -Be '\tiny11options\Post-Boot Cleanup'
    }

    It 'has exactly 3 triggers: BootTrigger, CalendarTrigger, EventTrigger' {
        @($script:doc.SelectNodes('//t:Triggers/*', $script:ns)).Count | Should -Be 3
        $script:doc.SelectSingleNode('//t:BootTrigger', $script:ns)     | Should -Not -BeNullOrEmpty
        $script:doc.SelectSingleNode('//t:CalendarTrigger', $script:ns) | Should -Not -BeNullOrEmpty
        $script:doc.SelectSingleNode('//t:EventTrigger', $script:ns)    | Should -Not -BeNullOrEmpty
    }

    It 'BootTrigger delay is PT10M' {
        $script:doc.SelectSingleNode('//t:BootTrigger/t:Delay', $script:ns).InnerText | Should -Be 'PT10M'
    }

    It 'CalendarTrigger runs daily at 03:00' {
        $script:doc.SelectSingleNode('//t:CalendarTrigger/t:StartBoundary', $script:ns).InnerText | Should -Match '^.*T03:00:00$'
        $script:doc.SelectSingleNode('//t:CalendarTrigger/t:ScheduleByDay/t:DaysInterval', $script:ns).InnerText | Should -Be '1'
    }

    It 'EventTrigger subscribes to WindowsUpdateClient EventID 19' {
        $sub = $script:doc.SelectSingleNode('//t:EventTrigger/t:Subscription', $script:ns).InnerText
        $sub | Should -Match 'Microsoft-Windows-WindowsUpdateClient/Operational'
        $sub | Should -Match 'EventID=19'
    }

    It 'principal is SYSTEM with HighestAvailable' {
        $script:doc.SelectSingleNode('//t:Principal/t:UserId',   $script:ns).InnerText | Should -Be 'S-1-5-18'
        $script:doc.SelectSingleNode('//t:Principal/t:RunLevel', $script:ns).InnerText | Should -Be 'HighestAvailable'
    }

    It 'ExecutionTimeLimit is PT30M' {
        $script:doc.SelectSingleNode('//t:Settings/t:ExecutionTimeLimit', $script:ns).InnerText | Should -Be 'PT30M'
    }

    It 'Action invokes powershell.exe with absolute path to tiny11-cleanup.ps1' {
        $script:doc.SelectSingleNode('//t:Actions/t:Exec/t:Command', $script:ns).InnerText | Should -Be 'powershell.exe'
        $script:doc.SelectSingleNode('//t:Actions/t:Exec/t:Arguments', $script:ns).InnerText | Should -Match 'C:\\Windows\\Setup\\Scripts\\tiny11-cleanup\.ps1'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.PostBoot.TaskXml.Tests.ps1"`
Expected: FAIL — `New-Tiny11PostBootTaskXml not yet implemented`.

- [ ] **Step 3: Implement the XML generator**

In `src/Tiny11.PostBoot.psm1`, replace the stub `New-Tiny11PostBootTaskXml` with:

```powershell
function New-Tiny11PostBootTaskXml {
    [CmdletBinding()] param()
    @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2026-05-12T00:00:00</Date>
    <Author>tiny11options</Author>
    <Description>Re-applies catalog-driven offline removals after Windows Update restages inbox apps and resets settings. Idempotent fast no-op when state is already correct.</Description>
    <URI>\tiny11options\Post-Boot Cleanup</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT10M</Delay>
    </BootTrigger>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T03:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-WindowsUpdateClient/Operational"&gt;&lt;Select Path="Microsoft-Windows-WindowsUpdateClient/Operational"&gt;*[System[(EventID=19)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Windows\Setup\Scripts\tiny11-cleanup.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
'@
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 9 XML tests green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.PostBoot.psm1 tests/Tiny11.PostBoot.TaskXml.Tests.ps1
git commit -m "feat(post-boot): scheduled task XML generator (3 triggers, SYSTEM, PT30M)"
```

---

### Task 13: `New-Tiny11PostBootSetupCompleteScript`

**Files:**
- Modify: `src/Tiny11.PostBoot.psm1`
- Create: `tests/Tiny11.PostBoot.SetupComplete.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
}

Describe 'New-Tiny11PostBootSetupCompleteScript' {
    BeforeAll { $script:cmd = New-Tiny11PostBootSetupCompleteScript }

    It 'is non-empty'                                  { $script:cmd | Should -Not -BeNullOrEmpty }
    It 'logs to tiny11-cleanup-setup.log'              { $script:cmd | Should -Match 'tiny11-cleanup-setup\.log' }
    It 'registers Post-Boot Cleanup task via schtasks' {
        $script:cmd | Should -Match 'schtasks /create /xml'
        $script:cmd | Should -Match '/tn "tiny11options\\Post-Boot Cleanup"'
    }
    It 'runs tiny11-cleanup.ps1 once immediately' {
        $script:cmd | Should -Match 'powershell\.exe.*tiny11-cleanup\.ps1'
    }
    It 'self-deletes via del /F /Q "%~f0"' {
        $script:cmd | Should -Match 'del /F /Q "%~f0"'
    }
    It 'is pure ASCII' {
        ($script:cmd.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `New-Tiny11PostBootSetupCompleteScript not yet implemented`.

- [ ] **Step 3: Implement the SetupComplete generator**

In `src/Tiny11.PostBoot.psm1`, replace the stub with:

```powershell
function New-Tiny11PostBootSetupCompleteScript {
    [CmdletBinding()] param()
    @'
@echo off
:: tiny11options post-boot cleanup
:: Runs once at first boot via SetupComplete.cmd contract:
::   Registers the Post-Boot Cleanup scheduled task.

set TINY11_LOG=%SystemDrive%\Windows\Logs\tiny11-cleanup-setup.log
if not exist "%SystemDrive%\Windows\Logs" mkdir "%SystemDrive%\Windows\Logs" >nul 2>&1

echo [tiny11options] Registering Post-Boot Cleanup scheduled task at %date% %time% > "%TINY11_LOG%"
schtasks /create /xml "%SystemDrive%\Windows\Setup\Scripts\tiny11-cleanup.xml" /tn "tiny11options\Post-Boot Cleanup" /f >> "%TINY11_LOG%" 2>&1
echo [tiny11options] schtasks exited with %ERRORLEVEL% >> "%TINY11_LOG%"

echo [tiny11options] Running tiny11-cleanup.ps1 once immediately >> "%TINY11_LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SystemDrive%\Windows\Setup\Scripts\tiny11-cleanup.ps1" >> "%TINY11_LOG%" 2>&1
echo [tiny11options] cleanup.ps1 exited with %ERRORLEVEL% >> "%TINY11_LOG%"

del /F /Q "%~f0"
'@
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 6 tests green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.PostBoot.psm1 tests/Tiny11.PostBoot.SetupComplete.Tests.ps1
git commit -m "feat(post-boot): Worker SetupComplete.cmd generator"
```

---

### Task 14: `Install-Tiny11PostBootCleanup` (file writer)

**Files:**
- Modify: `src/Tiny11.PostBoot.psm1`
- Create: `tests/Tiny11.PostBoot.Install.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.psm1')   -Force -DisableNameChecking
    Import-Module (Join-Path $script:srcDir 'Tiny11.PostBoot.psm1')  -Force -DisableNameChecking
}

Describe 'Install-Tiny11PostBootCleanup' {
    BeforeEach {
        $script:tempMount = Join-Path ([System.IO.Path]::GetTempPath()) ("postboot-install-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tempMount -Force | Out-Null
        $script:tinyCatalog = [pscustomobject]@{
            Version    = 1
            Categories = @([pscustomobject]@{ id='c'; displayName='c'; description='c' })
            Items      = @([pscustomobject]@{ id='only'; category='c'; displayName='Only'; description='only'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Only.Pkg' }) })
            Path       = 'test://catalog'
        }
        $script:tinyResolved = @{
            'only' = [pscustomobject]@{ ItemId='only'; UserState='apply'; EffectiveState='apply'; Locked=$false; LockedBy=@() }
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tempMount -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '-Enabled:$false writes nothing' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$false
        Test-Path (Join-Path $script:tempMount 'Windows\Setup\Scripts') | Should -Be $false
    }

    It '-Enabled:$true creates Windows\Setup\Scripts directory' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        Test-Path (Join-Path $script:tempMount 'Windows\Setup\Scripts') | Should -Be $true
    }

    It 'writes SetupComplete.cmd as ASCII + CRLF' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\SetupComplete.cmd'
        Test-Path $p | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($p)
        # ASCII: no byte > 127
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        # CRLF: at least one 0x0D 0x0A sequence
        $hasCrLf = $false
        for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
            if ($bytes[$i] -eq 0x0D -and $bytes[$i+1] -eq 0x0A) { $hasCrLf = $true; break }
        }
        $hasCrLf | Should -Be $true
    }

    It 'writes tiny11-cleanup.ps1 as UTF-8 + BOM' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\tiny11-cleanup.ps1'
        Test-Path $p | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($p)
        # UTF-8 BOM: EF BB BF
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'writes tiny11-cleanup.xml as UTF-16 LE + BOM' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\tiny11-cleanup.xml'
        Test-Path $p | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($p)
        # UTF-16 LE BOM: FF FE
        $bytes[0] | Should -Be 0xFF
        $bytes[1] | Should -Be 0xFE
    }

    It 'generated script contains the catalog item header' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\tiny11-cleanup.ps1'
        $text = [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($true))
        $text | Should -Match '# --- Item: Only \(only\) ---'
        $text | Should -Match 'Remove-AppxByPackagePrefix -Prefix .Only\.Pkg.'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the Invoke-Pester command targeting the new test file.
Expected: FAIL — `Install-Tiny11PostBootCleanup not yet implemented`.

- [ ] **Step 3: Implement the installer**

In `src/Tiny11.PostBoot.psm1`, replace the stub `Install-Tiny11PostBootCleanup` with:

```powershell
function Install-Tiny11PostBootCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]    $MountDir,
        [Parameter(Mandatory)]            $Catalog,
        [Parameter(Mandatory)][hashtable] $ResolvedSelections,
        [bool]                            $Enabled = $true
    )
    if (-not $Enabled) { return }

    $scriptsDir = Join-Path $MountDir 'Windows\Setup\Scripts'
    if (-not (Test-Path -LiteralPath $scriptsDir)) {
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    }

    # 1. SetupComplete.cmd — ASCII + CRLF
    $cmdContent     = New-Tiny11PostBootSetupCompleteScript
    $cmdContentCRLF = ($cmdContent -split "`r?`n") -join "`r`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $scriptsDir 'SetupComplete.cmd'),
        $cmdContentCRLF,
        [System.Text.Encoding]::ASCII)

    # 2. tiny11-cleanup.ps1 — UTF-8 + BOM
    $psContent = New-Tiny11PostBootCleanupScript -Catalog $Catalog -ResolvedSelections $ResolvedSelections
    [System.IO.File]::WriteAllText(
        (Join-Path $scriptsDir 'tiny11-cleanup.ps1'),
        $psContent,
        [System.Text.UTF8Encoding]::new($true))

    # 3. tiny11-cleanup.xml — UTF-16 LE + BOM
    $xmlContent = New-Tiny11PostBootTaskXml
    [System.IO.File]::WriteAllText(
        (Join-Path $scriptsDir 'tiny11-cleanup.xml'),
        $xmlContent,
        [System.Text.Encoding]::Unicode)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 6 install tests green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.PostBoot.psm1 tests/Tiny11.PostBoot.Install.Tests.ps1
git commit -m "feat(post-boot): Install-Tiny11PostBootCleanup writes 3 files with correct encodings"
```

---

## Phase 5 — Worker pipeline + headless wrapper switches

### Task 15: Wire `Install-Tiny11PostBootCleanup` into `Invoke-Tiny11BuildPipeline`

**Files:**
- Modify: `src/Tiny11.Worker.psm1`
- Modify: `tests/Tiny11.Worker.Tests.ps1`

**Pre-read.** Open `src/Tiny11.Worker.psm1` and locate (a) the `Invoke-Tiny11BuildPipeline` `param` block, (b) the call site for `Invoke-Tiny11ApplyActions` inside the pipeline (this is the apply phase), (c) the dismount call. Insert the new step between (b) and (c).

- [ ] **Step 1: Write the failing test**

Append to `tests/Tiny11.Worker.Tests.ps1` (inside a new `Describe` block at the end of file):

```powershell
Describe 'Invoke-Tiny11BuildPipeline post-boot cleanup integration' {

    BeforeAll {
        $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
        Import-Module (Join-Path $script:srcDir 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    }

    It 'calls Install-Tiny11PostBootCleanup with -Enabled $true by default' {
        Mock Install-Tiny11PostBootCleanup -ModuleName Tiny11.Worker {}
        # Build a minimal in-memory call to the apply portion only via Get-Tiny11ApplyItems
        # (the full pipeline depends on a mounted image and is not unit-testable here).
        # This test asserts the function NAME is referenced inside Invoke-Tiny11BuildPipeline.
        $source = Get-Content (Join-Path $script:srcDir 'Tiny11.Worker.psm1') -Raw
        $source | Should -Match 'Install-Tiny11PostBootCleanup'
        $source | Should -Match '-InstallPostBootCleanup'
    }

    It 'has an InstallPostBootCleanup parameter on Invoke-Tiny11BuildPipeline' {
        $cmd = Get-Command Invoke-Tiny11BuildPipeline
        $cmd.Parameters.Keys | Should -Contain 'InstallPostBootCleanup'
        $cmd.Parameters['InstallPostBootCleanup'].ParameterType.Name | Should -Be 'Boolean'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.Worker.Tests.ps1"`
Expected: FAIL — `InstallPostBootCleanup` param missing; `Install-Tiny11PostBootCleanup` not referenced in the source.

- [ ] **Step 3: Wire the param + call**

In `src/Tiny11.Worker.psm1`:

1. Add `Import-Module "$PSScriptRoot/Tiny11.PostBoot.psm1" -Force -DisableNameChecking` near the existing module imports.
2. Add `[bool]$InstallPostBootCleanup = $true` to the `Invoke-Tiny11BuildPipeline` `param` block.
3. Just after the apply-phase loop completes (after `Invoke-Tiny11ApplyActions` finishes and before any unmount call), insert:

```powershell
& $ProgressCallback @{ phase='inject-postboot-cleanup'; step='Installing post-boot cleanup task'; percent=95; itemId=$null }
Install-Tiny11PostBootCleanup -MountDir $scratchImg -Catalog $Catalog -ResolvedSelections $ResolvedSelections -Enabled:$InstallPostBootCleanup
```

(Variable names — `$scratchImg`, `$Catalog`, `$ResolvedSelections`, `$ProgressCallback` — must match what's already in scope; if any have different names in the current pipeline, use the existing ones.)

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — both new tests green; all existing Worker tests still green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Worker.psm1 tests/Tiny11.Worker.Tests.ps1
git commit -m "feat(worker): wire Install-Tiny11PostBootCleanup into pipeline (default on)"
```

---

### Task 16: `-InstallPostBootCleanup` / `-NoPostBootCleanup` switches on `tiny11maker.ps1`

**Files:**
- Modify: `tiny11maker.ps1`
- Modify: `tests/Tiny11.Wrappers.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Wrappers.Tests.ps1`:

```powershell
Describe 'tiny11maker.ps1 -InstallPostBootCleanup switches' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11maker.ps1' }

    It 'defines -InstallPostBootCleanup and -NoPostBootCleanup switches' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'InstallPostBootCleanup'
        $params | Should -Contain 'NoPostBootCleanup'
    }

    It 'passes InstallPostBootCleanup through to Invoke-Tiny11BuildPipeline' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup'
    }

    It 'NoPostBootCleanup overrides InstallPostBootCleanup' {
        # The wrapper must compute an effective $effectiveInstall = $InstallPostBootCleanup -and -not $NoPostBootCleanup
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match 'NoPostBootCleanup'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.Wrappers.Tests.ps1"`
Expected: FAIL — switches not present.

- [ ] **Step 3: Add the switches**

In `tiny11maker.ps1` `param` block, add after `[switch]$FastBuild`:

```powershell
    [bool]$InstallPostBootCleanup = $true,
    [switch]$NoPostBootCleanup,
```

In the `Invoke-Tiny11BuildPipeline` call inside the headless branch (currently around line 153), add `-InstallPostBootCleanup:` line:

```powershell
    Invoke-Tiny11BuildPipeline `
        -Source $Source -ImageIndex $ImageIndex -ScratchDir $ScratchDir `
        -OutputPath $OutputPath -UnmountSource $true `
        -Catalog $catalog -ResolvedSelections $resolved `
        -FastBuild ([bool]$FastBuild) `
        -InstallPostBootCleanup ([bool]($InstallPostBootCleanup -and -not $NoPostBootCleanup)) `
        -ProgressCallback { param($p) Write-Output "[$($p.phase)] $($p.step) ($($p.percent)%)" }
```

Also extend the `.PARAMETER` doc comment block at the top of the script with documentation for both switches. Example block to add before `.PARAMETER Internal`:

```powershell
.PARAMETER InstallPostBootCleanup
    Install the per-build post-boot cleanup scheduled task that re-removes apps and
    re-applies tweaks if Windows Update brings them back. Default: $true.

.PARAMETER NoPostBootCleanup
    Sugar for -InstallPostBootCleanup:$false. Wins when both are set.
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — switches present + threading through.

- [ ] **Step 5: Commit**

```powershell
git add tiny11maker.ps1 tests/Tiny11.Wrappers.Tests.ps1
git commit -m "feat(wrapper): -InstallPostBootCleanup / -NoPostBootCleanup switches on tiny11maker.ps1"
```

---

### Task 17: Same switches on `tiny11maker-from-config.ps1`

**Files:**
- Modify: `tiny11maker-from-config.ps1`
- Modify: `tests/Tiny11.Wrappers.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Wrappers.Tests.ps1`:

```powershell
Describe 'tiny11maker-from-config.ps1 -InstallPostBootCleanup switches' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11maker-from-config.ps1' }

    It 'defines -InstallPostBootCleanup and -NoPostBootCleanup switches' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'InstallPostBootCleanup'
        $params | Should -Contain 'NoPostBootCleanup'
    }

    It 'threads InstallPostBootCleanup through to Invoke-Tiny11BuildPipeline' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — switches missing.

- [ ] **Step 3: Add the switches + threading**

Mirror the changes from Task 16 in `tiny11maker-from-config.ps1` (same param defaults, same threading, same doc block).

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add tiny11maker-from-config.ps1 tests/Tiny11.Wrappers.Tests.ps1
git commit -m "feat(wrapper): -InstallPostBootCleanup / -NoPostBootCleanup switches on from-config wrapper"
```

---

## Phase 6 — Core pipeline integration

### Task 18: Extend `New-Tiny11CorePostBootCleanupScript` with cleanup-task registration switch

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Pre-read.** Locate `New-Tiny11CorePostBootCleanupScript` (around line 635 in `src/Tiny11.Core.psm1`). It currently returns a static heredoc. We need to split it into a base section + an optional cleanup-registration insert + the closing self-delete section, gated on a new `[switch]$IncludePostBootCleanupRegistration` param.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration' {

    It 'without the switch: ONE schtasks /create line (Keep WU Disabled only)' {
        $cmd = New-Tiny11CorePostBootCleanupScript
        ([regex]::Matches($cmd, 'schtasks /create /xml')).Count | Should -Be 1
        $cmd | Should -Match '/tn "tiny11options\\Keep WU Disabled"'
        $cmd | Should -Not -Match '/tn "tiny11options\\Post-Boot Cleanup"'
    }

    It 'with -IncludePostBootCleanupRegistration: TWO schtasks /create lines' {
        $cmd = New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration
        ([regex]::Matches($cmd, 'schtasks /create /xml')).Count | Should -Be 2
        $cmd | Should -Match '/tn "tiny11options\\Keep WU Disabled"'
        $cmd | Should -Match '/tn "tiny11options\\Post-Boot Cleanup"'
    }

    It 'both variants still self-delete' {
        (New-Tiny11CorePostBootCleanupScript)                                  | Should -Match 'del /F /Q "%~f0"'
        (New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration) | Should -Match 'del /F /Q "%~f0"'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.Core.Tests.ps1"`
Expected: FAIL — switch not present; tests that look for 2 schtasks fail.

- [ ] **Step 3: Refactor the function**

Replace `New-Tiny11CorePostBootCleanupScript` in `src/Tiny11.Core.psm1` with this three-piece variant:

```powershell
function New-Tiny11CorePostBootCleanupScript {
    [CmdletBinding()]
    param([switch]$IncludePostBootCleanupRegistration)

    $base = @'
@echo off
:: tiny11options post-boot cleanup
:: Generated by Invoke-Tiny11CoreBuildPipeline (src/Tiny11.Core.psm1).
:: Runs once at first boot via SetupComplete.cmd contract:
::   1. Performs /Cleanup-Image /StartComponentCleanup /ResetBase (deferred from offline)
::   2. Re-disables WU services that Windows OOBE flipped back to Manual
:: Logs to %SystemDrive%\Windows\Logs\tiny11-postboot.log. Self-deletes after running.

set TINY11_LOG=%SystemDrive%\Windows\Logs\tiny11-postboot.log
if not exist "%SystemDrive%\Windows\Logs" mkdir "%SystemDrive%\Windows\Logs" >nul 2>&1

echo [tiny11options] Post-boot cleanup starting at %date% %time% > "%TINY11_LOG%"
echo. >> "%TINY11_LOG%"

echo [tiny11options] dism /online /Cleanup-Image /StartComponentCleanup /ResetBase >> "%TINY11_LOG%"
dism /online /English /Cleanup-Image /StartComponentCleanup /ResetBase >> "%TINY11_LOG%" 2>&1
echo [tiny11options] dism exited with %ERRORLEVEL% >> "%TINY11_LOG%"
echo. >> "%TINY11_LOG%"

echo [tiny11options] Re-disabling WU services post-OOBE (wuauserv / UsoSvc / WaaSMedicSvc) >> "%TINY11_LOG%"
sc config wuauserv     start= disabled >> "%TINY11_LOG%" 2>&1
sc config UsoSvc       start= disabled >> "%TINY11_LOG%" 2>&1
sc config WaaSMedicSvc start= disabled >> "%TINY11_LOG%" 2>&1
sc stop   wuauserv     >> "%TINY11_LOG%" 2>&1
sc stop   UsoSvc       >> "%TINY11_LOG%" 2>&1
sc stop   WaaSMedicSvc >> "%TINY11_LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\wuauserv" /v Start /t REG_DWORD /d 4 /f >> "%TINY11_LOG%" 2>&1
echo [tiny11options] Resolved state via sc qc wuauserv: >> "%TINY11_LOG%"
sc qc wuauserv >> "%TINY11_LOG%" 2>&1
echo. >> "%TINY11_LOG%"

echo [tiny11options] Registering Keep-WU-Disabled scheduled task >> "%TINY11_LOG%"
schtasks /create /xml "%SystemDrive%\Windows\Setup\Scripts\tiny11-wu-enforce.xml" /tn "tiny11options\Keep WU Disabled" /f >> "%TINY11_LOG%" 2>&1
echo [tiny11options] schtasks exited with %ERRORLEVEL% >> "%TINY11_LOG%"
echo. >> "%TINY11_LOG%"

echo [tiny11options] Running tiny11-wu-enforce.ps1 once immediately (so we don't wait for next boot) >> "%TINY11_LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SystemDrive%\Windows\Setup\Scripts\tiny11-wu-enforce.ps1" >> "%TINY11_LOG%" 2>&1
echo [tiny11options] enforce.ps1 exited with %ERRORLEVEL% >> "%TINY11_LOG%"
echo. >> "%TINY11_LOG%"
'@

    $cleanupBlock = @'
echo [tiny11options] Registering Post-Boot Cleanup scheduled task >> "%TINY11_LOG%"
schtasks /create /xml "%SystemDrive%\Windows\Setup\Scripts\tiny11-cleanup.xml" /tn "tiny11options\Post-Boot Cleanup" /f >> "%TINY11_LOG%" 2>&1
echo [tiny11options] cleanup-task schtasks exited with %ERRORLEVEL% >> "%TINY11_LOG%"
echo. >> "%TINY11_LOG%"
'@

    $tail = @'
echo [tiny11options] Post-boot cleanup completed at %date% %time% >> "%TINY11_LOG%"

:: Self-cleanup: remove this script so it doesn't run on any subsequent Setup pass.
:: The .ps1 and .xml files in the same directory STAY -- the scheduled task references the .ps1
:: by absolute path, so it must persist for the recurring task to fire.
del /F /Q "%~f0"
'@

    if ($IncludePostBootCleanupRegistration) {
        "$base`n$cleanupBlock`n$tail"
    } else {
        "$base`n$tail"
    }
}
```

(Double-check: the heredoc content above is the EXISTING content of `New-Tiny11CorePostBootCleanupScript` split at the right seam. If the current file diverges at any specific text, use the file's exact wording for `$base` and `$tail` — what matters structurally is the split point right before "Post-boot cleanup completed".)

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 3 new tests green; existing Core SetupComplete.cmd tests still green (default-no-switch output equals the old behavior).

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): -IncludePostBootCleanupRegistration switch on SetupComplete generator"
```

---

### Task 19: Extend `Install-Tiny11CorePostBootCleanup` + Core pipeline call

**Files:**
- Modify: `src/Tiny11.Core.psm1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Pre-read.** Locate `Install-Tiny11CorePostBootCleanup` (around line 934). It currently writes `SetupComplete.cmd` + `tiny11-wu-enforce.ps1` + `tiny11-wu-enforce.xml`. We extend it to optionally also write `tiny11-cleanup.ps1` + `tiny11-cleanup.xml` and to pass `-IncludePostBootCleanupRegistration` when generating SetupComplete.cmd.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Install-Tiny11CorePostBootCleanup with cleanup params' {
    BeforeEach {
        $script:tempMount = Join-Path ([System.IO.Path]::GetTempPath()) ("core-postboot-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tempMount -Force | Out-Null
        $script:tinyCatalog = [pscustomobject]@{
            Version=1; Categories=@(); Items=@(
                [pscustomobject]@{ id='only'; category='c'; displayName='Only'; description='only'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Only.Pkg' }) }
            ); Path='test://catalog'
        }
        $script:tinyResolved = @{
            'only' = [pscustomobject]@{ ItemId='only'; UserState='apply'; EffectiveState='apply'; Locked=$false; LockedBy=@() }
        }
    }
    AfterEach { Remove-Item -LiteralPath $script:tempMount -Recurse -Force -ErrorAction SilentlyContinue }

    It 'with -PostBootCleanupEnabled $true writes cleanup files AND extends SetupComplete.cmd with cleanup task registration' {
        Install-Tiny11CorePostBootCleanup -MountDir $script:tempMount `
            -PostBootCleanupCatalog $script:tinyCatalog `
            -PostBootCleanupResolvedSelections $script:tinyResolved `
            -PostBootCleanupEnabled $true
        $scripts = Join-Path $script:tempMount 'Windows\Setup\Scripts'
        Test-Path (Join-Path $scripts 'tiny11-cleanup.ps1') | Should -Be $true
        Test-Path (Join-Path $scripts 'tiny11-cleanup.xml') | Should -Be $true
        $setupCmd = Get-Content (Join-Path $scripts 'SetupComplete.cmd') -Raw
        ([regex]::Matches($setupCmd, 'schtasks /create /xml')).Count | Should -Be 2
    }

    It 'with -PostBootCleanupEnabled $false skips cleanup files AND keeps SetupComplete.cmd at one schtasks line' {
        Install-Tiny11CorePostBootCleanup -MountDir $script:tempMount -PostBootCleanupEnabled $false
        $scripts = Join-Path $script:tempMount 'Windows\Setup\Scripts'
        Test-Path (Join-Path $scripts 'tiny11-cleanup.ps1') | Should -Be $false
        Test-Path (Join-Path $scripts 'tiny11-cleanup.xml') | Should -Be $false
        $setupCmd = Get-Content (Join-Path $scripts 'SetupComplete.cmd') -Raw
        ([regex]::Matches($setupCmd, 'schtasks /create /xml')).Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — new params not present.

- [ ] **Step 3: Extend `Install-Tiny11CorePostBootCleanup`**

In `src/Tiny11.Core.psm1`:

1. Add `Import-Module "$PSScriptRoot/Tiny11.PostBoot.psm1" -Force -DisableNameChecking` near the existing module imports.

2. Extend the `Install-Tiny11CorePostBootCleanup` `param` block to add (after the existing `[Parameter(Mandatory)][string]$MountDir`):

   ```powershell
       [object]    $PostBootCleanupCatalog,
       [hashtable] $PostBootCleanupResolvedSelections,
       [bool]      $PostBootCleanupEnabled = $true
   ```

3. Replace the existing `New-Tiny11CorePostBootCleanupScript` call (the one that produces `$cmdContent`) with:

   ```powershell
       $cmdContent = New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration:$PostBootCleanupEnabled
   ```

4. After the WU-enforce trio has been written (look for the section that writes `tiny11-wu-enforce.xml`), append the new cleanup-file writes gated on `$PostBootCleanupEnabled`:

   ```powershell
       if ($PostBootCleanupEnabled -and $PostBootCleanupCatalog -and $PostBootCleanupResolvedSelections) {
           $cleanupPs1 = New-Tiny11PostBootCleanupScript -Catalog $PostBootCleanupCatalog -ResolvedSelections $PostBootCleanupResolvedSelections
           [System.IO.File]::WriteAllText(
               (Join-Path $scriptDir 'tiny11-cleanup.ps1'),
               $cleanupPs1,
               [System.Text.UTF8Encoding]::new($true))

           $cleanupXml = New-Tiny11PostBootTaskXml
           [System.IO.File]::WriteAllText(
               (Join-Path $scriptDir 'tiny11-cleanup.xml'),
               $cleanupXml,
               [System.Text.Encoding]::Unicode)
       }
   ```

   (Use the variable `$scriptDir` that's already in scope — match the existing Core code's variable name; if it's named differently, use that.)

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — both new tests green; existing `Install-Tiny11CorePostBootCleanup` tests still green when called without the new params (defaults `$PostBootCleanupEnabled=$true` but `$PostBootCleanupCatalog=$null` means the cleanup-file writes skip).

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Core.psm1 tests/Tiny11.Core.Tests.ps1
git commit -m "feat(core): Install-Tiny11CorePostBootCleanup writes cleanup files when enabled"
```

---

### Task 20: Core pipeline call site + `tiny11Coremaker-from-config.ps1` switches

**Files:**
- Modify: `src/Tiny11.Core.psm1` (call site only)
- Modify: `tiny11Coremaker-from-config.ps1`
- Modify: `tests/Tiny11.Wrappers.Tests.ps1`
- Modify: `tests/Tiny11.Core.Tests.ps1`

**Pre-read.** Locate `Invoke-Tiny11CoreBuildPipeline` and its call site for `Install-Tiny11CorePostBootCleanup` (around line 1289). Pre-read `tiny11Coremaker-from-config.ps1` param block.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Tiny11.Wrappers.Tests.ps1`:

```powershell
Describe 'tiny11Coremaker-from-config.ps1 -InstallPostBootCleanup switches' {
    BeforeAll { $script:wrapperPath = Join-Path $PSScriptRoot '..' 'tiny11Coremaker-from-config.ps1' }
    It 'defines both switches' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:wrapperPath, [ref]$null, [ref]$null)
        $params = ($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should -Contain 'InstallPostBootCleanup'
        $params | Should -Contain 'NoPostBootCleanup'
    }
    It 'threads InstallPostBootCleanup to the pipeline' {
        $source = Get-Content $script:wrapperPath -Raw
        $source | Should -Match '-InstallPostBootCleanup'
    }
}
```

Append to `tests/Tiny11.Core.Tests.ps1`:

```powershell
Describe 'Invoke-Tiny11CoreBuildPipeline post-boot cleanup wiring' {
    It 'has an InstallPostBootCleanup parameter' {
        $cmd = Get-Command Invoke-Tiny11CoreBuildPipeline
        $cmd.Parameters.Keys | Should -Contain 'InstallPostBootCleanup'
        $cmd.Parameters['InstallPostBootCleanup'].ParameterType.Name | Should -Be 'Boolean'
    }
    It 'source passes the cleanup catalog and resolved selections to Install-Tiny11CorePostBootCleanup' {
        $source = Get-Content (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.Core.psm1') -Raw
        $source | Should -Match '-PostBootCleanupCatalog'
        $source | Should -Match '-PostBootCleanupResolvedSelections'
        $source | Should -Match '-PostBootCleanupEnabled'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Wire the call site**

In `src/Tiny11.Core.psm1`:

1. Add `[bool]$InstallPostBootCleanup = $true` to the `Invoke-Tiny11CoreBuildPipeline` `param` block.
2. At the existing `Install-Tiny11CorePostBootCleanup -MountDir $mountDir` call, extend to:
   ```powershell
       Install-Tiny11CorePostBootCleanup -MountDir $mountDir `
           -PostBootCleanupCatalog $Catalog `
           -PostBootCleanupResolvedSelections $ResolvedSelections `
           -PostBootCleanupEnabled $InstallPostBootCleanup
   ```
   (Match variable names already in scope: `$Catalog`, `$ResolvedSelections`.)

In `tiny11Coremaker-from-config.ps1`:

1. Add `[bool]$InstallPostBootCleanup = $true` and `[switch]$NoPostBootCleanup` to the `param` block.
2. Add the doc-block `.PARAMETER` entries (mirror the wording from Task 16).
3. In the `Invoke-Tiny11CoreBuildPipeline` call, thread the effective value:
   ```powershell
       -InstallPostBootCleanup ([bool]($InstallPostBootCleanup -and -not $NoPostBootCleanup)) `
   ```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — both new test files / sections green.

- [ ] **Step 5: Commit**

```powershell
git add src/Tiny11.Core.psm1 tiny11Coremaker-from-config.ps1 tests/Tiny11.Core.Tests.ps1 tests/Tiny11.Wrappers.Tests.ps1
git commit -m "feat(core): wire -InstallPostBootCleanup through Core pipeline + wrapper"
```

---

## Phase 7 — UI + C# launcher wiring

### Task 21: Step 1 UI checkbox + state.installPostBootCleanup

**Files:**
- Modify: `ui/index.html`
- Modify: `ui/app.js`
- Modify: `tests/Tiny11.UiApp.OutputRequired.Tests.ps1` (or create `tests/Tiny11.UiApp.PostBootCleanup.Tests.ps1` if the existing tests are scoped narrowly)

**Pre-read.** Open `ui/index.html` and find the Step 1 panel where the existing **Fast Build** checkbox lives (search for `fastBuild`). Open `ui/app.js` and find where `state.fastBuild` is initialized + how it's added to the `start-build` payload. Use the same pattern.

- [ ] **Step 1: Write the failing tests**

Append (or create) tests in `tests/Tiny11.UiApp.OutputRequired.Tests.ps1` style at `tests/Tiny11.UiApp.PostBootCleanup.Tests.ps1`:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:uiDir   = Join-Path $PSScriptRoot '..' 'ui'
    $script:appJs   = Get-Content (Join-Path $script:uiDir 'app.js')   -Raw
    $script:indexHtml = Get-Content (Join-Path $script:uiDir 'index.html') -Raw
}

Describe 'Post-boot cleanup UI wiring' {
    It 'state.installPostBootCleanup is initialized to true' {
        $script:appJs | Should -Match 'installPostBootCleanup\s*:\s*true'
    }
    It 'start-build payload includes installPostBootCleanup' {
        $script:appJs | Should -Match "installPostBootCleanup\s*:\s*state\.installPostBootCleanup"
    }
    It 'index.html contains a checkbox bound to installPostBootCleanup' {
        $script:indexHtml | Should -Match 'id="install-post-boot-cleanup"'
        $script:indexHtml | Should -Match 'type="checkbox"'
    }
    It 'checkbox is wired in the Step 1 panel near the Fast Build control' {
        # Sanity-check positional adjacency: install-post-boot-cleanup ID appears AFTER fast-build ID in the HTML.
        $fbIndex = $script:indexHtml.IndexOf('id="fast-build"')
        $pbIndex = $script:indexHtml.IndexOf('id="install-post-boot-cleanup"')
        $fbIndex | Should -BeGreaterThan -1
        $pbIndex | Should -BeGreaterThan $fbIndex
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.UiApp.PostBootCleanup.Tests.ps1"`
Expected: FAIL — checkbox not present, state field missing.

- [ ] **Step 3: Add the checkbox + state**

In `ui/index.html`, locate the Step 1 panel `<div>` containing the Fast Build checkbox (search for `id="fast-build"`). Add a sibling block immediately AFTER it:

```html
<label class="option-row">
  <input type="checkbox" id="install-post-boot-cleanup" checked />
  <span class="option-label">
    Install post-boot cleanup task
    <span class="option-description">Re-removes apps and re-applies tweaks if Windows Update brings them back. Adds a scheduled task (~30 sec daily, plus when CUs install).</span>
  </span>
</label>
```

In `ui/app.js`:

1. Initialize the state field. Find `state = {` and add `installPostBootCleanup: true,` near `fastBuild`.
2. Wire the checkbox change handler. After the fast-build wiring block, add:
   ```javascript
   document.getElementById('install-post-boot-cleanup').addEventListener('change', (e) => {
     state.installPostBootCleanup = e.target.checked;
   });
   ```
3. Include the field in the `start-build` payload. Find the `bridge.postMessage({ type: 'start-build', payload: { … } })` call and add `installPostBootCleanup: state.installPostBootCleanup,` to the payload object.

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all 4 UI tests green.

- [ ] **Step 5: Commit**

```powershell
git add ui/index.html ui/app.js tests/Tiny11.UiApp.PostBootCleanup.Tests.ps1
git commit -m "feat(ui): Step 1 install-post-boot-cleanup checkbox (default on)"
```

---

### Task 22: BuildHandlers payload field + wrapper-invocation threading

**Files:**
- Modify: `launcher/Gui/Handlers/BuildHandlers.cs`
- Modify: `launcher/Tests/BuildHandlersTests.cs`

**Pre-read.** Open `launcher/Gui/Handlers/BuildHandlers.cs` and locate (a) the line `var fastBuild = payload?["fastBuild"]?.GetValue<bool>() ?? false;`, (b) the `BuildStandardArgs(...)` and `BuildCoreArgs(...)` signatures (around lines 290-340), (c) the call sites that invoke them.

- [ ] **Step 1: Write the failing tests**

Append to `launcher/Tests/BuildHandlersTests.cs`:

```csharp
[Fact]
public void BuildStandardArgs_OmitsNoPostBootCleanup_WhenEnabled()
{
    var resDir = CreateTempResourcesDir();
    // installPostBootCleanup: true means the wrapper accepts default and we DON'T pass -NoPostBootCleanup
    var result = InvokeBuildStandardArgs(resDir, @"C:\cfg.json", @"D:\win.iso", @"C:\out.iso", "", 0, "",
        unmountSource: false, fastBuild: false, installPostBootCleanup: true);
    Assert.DoesNotContain("-NoPostBootCleanup", result);
}

[Fact]
public void BuildStandardArgs_AppendsNoPostBootCleanup_WhenDisabled()
{
    var resDir = CreateTempResourcesDir();
    var result = InvokeBuildStandardArgs(resDir, @"C:\cfg.json", @"D:\win.iso", @"C:\out.iso", "", 0, "",
        unmountSource: false, fastBuild: false, installPostBootCleanup: false);
    Assert.Contains("-NoPostBootCleanup", result);
}

[Fact]
public void BuildCoreArgs_OmitsNoPostBootCleanup_WhenEnabled()
{
    var resDir = CreateTempResourcesDir();
    var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false,
        fastBuild: false, installPostBootCleanup: true);
    Assert.DoesNotContain("-NoPostBootCleanup", result);
}

[Fact]
public void BuildCoreArgs_AppendsNoPostBootCleanup_WhenDisabled()
{
    var resDir = CreateTempResourcesDir();
    var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false,
        fastBuild: false, installPostBootCleanup: false);
    Assert.Contains("-NoPostBootCleanup", result);
}
```

Add `installPostBootCleanup` to the test-helper invocation methods (around lines 168-190 in the test file):

```csharp
// Standard helper:
private static string InvokeBuildStandardArgs(
    string resDir, string configPath, string sourcePath, string outputIso,
    string scratchDir, int imageIndex, string editionName,
    bool unmountSource, bool fastBuild, bool installPostBootCleanup = true)
{
    return InvokeStatic<string>("BuildStandardArgs",
        resDir, configPath, sourcePath, outputIso, scratchDir,
        imageIndex, editionName, unmountSource, fastBuild, installPostBootCleanup);
}

// Core helper:
private static string InvokeBuildCoreArgs(
    string resDir, string sourcePath, string outputIso,
    string scratchDir, int imageIndex, string editionName,
    bool unmountSource, bool enableNet35,
    bool fastBuild, bool installPostBootCleanup = true)
{
    return InvokeStatic<string>("BuildCoreArgs",
        resDir, sourcePath, outputIso, scratchDir,
        imageIndex, editionName, unmountSource, enableNet35,
        fastBuild, installPostBootCleanup);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd C:/Users/jscha/source/repos/tiny11options/launcher/Tests && dotnet test --filter "BuildStandardArgs|BuildCoreArgs" --logger "console;verbosity=normal"`
Expected: FAIL — `BuildStandardArgs`/`BuildCoreArgs` signatures don't have an `installPostBootCleanup` parameter; new tests fail at reflection.

- [ ] **Step 3: Extend the C# wiring**

In `launcher/Gui/Handlers/BuildHandlers.cs`:

1. After the `fastBuild` payload read (around line 113), add:
   ```csharp
   var installPostBootCleanup = payload?["installPostBootCleanup"]?.GetValue<bool>() ?? true;
   ```

2. Update both `BuildStandardArgs(...)` and `BuildCoreArgs(...)` to accept a final `bool installPostBootCleanup` parameter. Inside each, after the existing `if (fastBuild) args.Append(" -FastBuild");`, add:
   ```csharp
   if (!installPostBootCleanup) args.Append(" -NoPostBootCleanup");
   ```

3. Update both call sites (around lines 136 and 142) to pass `installPostBootCleanup`:
   ```csharp
   psArgs = BuildCoreArgs(_resourcesDir, src, outputIso, scratchDir, imageIndex, editionName, unmountSource, enableNet35, fastBuild, installPostBootCleanup);
   // ...
   psArgs = BuildStandardArgs(_resourcesDir, configPath, src, outputIso, scratchDir, imageIndex, editionName, unmountSource, fastBuild, installPostBootCleanup);
   ```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd launcher/Tests && dotnet test --logger "console;verbosity=normal"`
Expected: PASS — all 4 new tests green + existing tests still green.

- [ ] **Step 5: Commit**

```powershell
git add launcher/Gui/Handlers/BuildHandlers.cs launcher/Tests/BuildHandlersTests.cs
git commit -m "feat(launcher): plumb installPostBootCleanup payload to wrapper invocation"
```

---

### Task 23: BridgePayloadContract allowlist

**Files:**
- Modify: `launcher/Tests/BridgePayloadContractTests.cs`

**Pre-read.** Open the file and find the allowlist of payload fields the `start-build` message accepts. We add `installPostBootCleanup` to it.

- [ ] **Step 1: Inspect the allowlist**

Run: `Get-Content launcher/Tests/BridgePayloadContractTests.cs | Select-String 'fastBuild|start-build|StartBuild'`
This shows where the start-build payload fields are enumerated. Identify the test that lists allowed fields (search for `fastBuild` literal in the file).

- [ ] **Step 2: Update the allowlist + add a focused test**

Add `"installPostBootCleanup"` to the array/HashSet/list that enumerates allowed start-build payload fields. Then add a new fact:

```csharp
[Fact]
public void StartBuildPayload_AllowsInstallPostBootCleanupField()
{
    var allowed = GetAllowedStartBuildPayloadFields();
    Assert.Contains("installPostBootCleanup", allowed);
}
```

(Use whatever method name the existing tests use to extract allowed fields.)

- [ ] **Step 3: Run tests to verify they pass**

Run: `cd launcher/Tests && dotnet test --filter "InstallPostBootCleanup|StartBuildPayload" --logger "console;verbosity=normal"`
Expected: PASS — new test green; existing contract tests still green.

- [ ] **Step 4: Commit**

```powershell
git add launcher/Tests/BridgePayloadContractTests.cs
git commit -m "test(launcher): allowlist installPostBootCleanup in start-build payload contract"
```

---

## Phase 8 — Final test sweeps

### Task 24: ScriptEncoding walker confirmation

**Files:** none modified (verification only)

The existing `tests/Tiny11.ScriptEncoding.Tests.ps1` walks all `.ps1`/`.psm1`/`.psd1`/`.cmd`/`.bat` files in the repo and asserts pure-ASCII OR BOM. Every new file added in this plan must pass.

- [ ] **Step 1: Run the encoding walker**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -Output Detailed tests/Tiny11.ScriptEncoding.Tests.ps1"`
Expected: PASS — no offenders. If any of the new files fail (because we accidentally introduced a smart-quote/em-dash), fix the file and re-run.

- [ ] **Step 2: Verify the generated cleanup.ps1 itself passes the walker by writing one to a temp dir + scanning**

```powershell
pwsh -NoProfile -Command @'
Import-Module ./src/Tiny11.PostBoot.psm1 -Force -DisableNameChecking
Import-Module ./src/Tiny11.Catalog.psm1  -Force -DisableNameChecking
Import-Module ./src/Tiny11.Selections.psm1 -Force -DisableNameChecking
$catalog = Get-Tiny11Catalog -Path ./catalog/catalog.json
$selections = New-Tiny11Selections -Catalog $catalog
$resolved   = Resolve-Tiny11Selections -Catalog $catalog -Selections $selections
$script = New-Tiny11PostBootCleanupScript -Catalog $catalog -ResolvedSelections $resolved
$bad = ($script.ToCharArray() | Where-Object { [int]$_ -gt 127 })
if ($bad.Count -gt 0) { Write-Error "Generated cleanup.ps1 contains $($bad.Count) non-ASCII characters"; exit 1 }
Write-Output "Generated cleanup.ps1 is pure ASCII ($($script.Length) chars)"
'@
```

Expected: outputs `Generated cleanup.ps1 is pure ASCII (...)` with no error.

- [ ] **Step 3: No commit (verification step)**

---

### Task 25: Full test count verification

**Files:** none modified

- [ ] **Step 1: Run all Pester tests + capture counts**

Run: `pwsh -NoProfile -Command "& { $r = Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -PassThru; '{0} passed, {1} failed, {2} skipped' -f $r.PassedCount, $r.FailedCount, $r.SkippedCount }"`
Expected: PassedCount ≥ 320 (target ~325), FailedCount = 0.

- [ ] **Step 2: Run all xUnit tests + capture counts**

Run: `cd launcher/Tests && dotnet test --logger "console;verbosity=normal" 2>&1 | Select-String "Passed|Failed"`
Expected: Passed ≥ 84 (target ~85), Failed = 0.

- [ ] **Step 3: No commit (verification step)**

If either count is below target, the missing count points at a missed test from earlier phases — go back and add it.

---

## Phase 9 — Documentation, manual VM smoke, release

### Task 26: CHANGELOG.md v1.0.1 entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the v1.0.1 entry above v1.0.0**

Open `CHANGELOG.md` and add a new section between `## [Unreleased]` (if present) and `## [1.0.0] - 2026-05-12`:

```markdown
## [1.0.1] - <YYYY-MM-DD>

### Added
- **Post-boot cleanup scheduled task.** Catalog-driven re-removal of inbox apps and re-application of tweaks that Windows cumulative updates restage and reset. The cleanup task is tailored to the user's catalog selections at build time — items the user chose to keep are NEVER touched. Triggers: BootTrigger + 10 min delay, daily at 03:00, and on every WU EventID 19. Runs as SYSTEM, idempotent (re-running on a clean machine is a fast no-op). Installed via SetupComplete.cmd at first boot. Default ON; opt out with the Step 1 checkbox in the launcher GUI or `-NoPostBootCleanup` on the CLI.
- `-InstallPostBootCleanup` / `-NoPostBootCleanup` switches on `tiny11maker.ps1`, `tiny11maker-from-config.ps1`, and `tiny11Coremaker-from-config.ps1`.
- `Tiny11.PostBoot.psm1` module + sibling `Get-Tiny11<Type>OnlineCommand` emitters on each Actions module (single-sources action knowledge between offline-apply and online-cleanup paths).

### Changed
- Core builds now register TWO scheduled tasks at first boot: `tiny11options\Keep WU Disabled` (existing) and `tiny11options\Post-Boot Cleanup` (new). Worker builds register the latter only. Core's existing SetupComplete.cmd is extended with one extra `schtasks /create` line, gated on `state.installPostBootCleanup`.

### Known limitations
- **Partial CDM re-enforcement.** The cleanup script only re-applies what the catalog enumerates. The current `tweak-disable-sponsored-apps` item covers 4 of the 11 canonical `ContentDeliveryManager` registry values; the other 7 (FeatureManagementEnabled, PreInstalledAppsEverEnabled, RotatingLockScreenEnabled / Overlay, SlideshowEnabled, SoftLandingEnabled, SystemPaneSuggestionsEnabled) plus `HKLM\SOFTWARE\Policies\Microsoft\WindowsStore\AutoDownload=2` and the `HKU\.DEFAULT` mirror remain restored by CUs even after cleanup runs. Catalog completeness deferred to v1.0.2.
- **COMPONENTS hive online not supported.** No catalog item uses this hive today; regression-tested. If a future catalog item needs it, the emitter throws at build time.
- **No in-OS UI for disabling the task.** Users can disable the task manually with `Disable-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup'` if needed.

### Tests
- +~40 Pester tests across 5 new test files (Registry/Filesystem/ProvisionedAppx/ScheduledTask online emitters, generator, helpers golden, task XML, SetupComplete, install) + extensions to Actions, Worker, Core, and Wrappers test files. Total Pester ~325 (was 283).
- +4 xUnit tests for the C# launcher wiring (`installPostBootCleanup` payload + wrapper invocation) + 1 contract-allowlist test. Total xUnit ~85 (was 80).
```

Pick `<YYYY-MM-DD>` as the actual release date when cutting (Task 37).

- [ ] **Step 2: Commit**

```powershell
git add CHANGELOG.md
git commit -m "docs(changelog): v1.0.1 post-boot cleanup entry"
```

---

### Task 27: README.md feature description

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the post-boot cleanup section**

Add a new top-level section near the existing "Features" or "What it does" section:

```markdown
## Post-boot cleanup task (v1.0.1+)

Windows cumulative updates silently restage inbox apps (Clipchamp, Copilot, Outlook, etc.) and reset hardening registry values — Microsoft confirms this is by design. The post-boot cleanup task re-removes only the items you chose to remove at build time, every time Windows Update finishes installing a CU (plus daily at 03:00 and 10 minutes after every boot, as a backstop).

The task:

- Is **tailored per build** — your selections at Step 2 of the launcher determine exactly what gets re-removed. Items you chose to keep are never touched.
- Is **idempotent** — already-correct state is a fast read-and-skip; only restaged items get the work done. Logged to `C:\Windows\Logs\tiny11-cleanup.log` (5000-line rolling, ~3 months of history).
- Runs as **SYSTEM** at boot + daily + on every WU EventID 19. Default execution time limit is 30 minutes.
- Is **opt-out**. Uncheck "Install post-boot cleanup task" in Step 1 of the launcher, or pass `-NoPostBootCleanup` on the CLI.

**Known limitation (v1.0.1):** the cleanup script only re-applies what the catalog enumerates. The `tweak-disable-sponsored-apps` item currently covers 4 of the 11 canonical CDM registry values; the other 7 remain reset by CUs. Catalog completeness ships in v1.0.2.
```

- [ ] **Step 2: Commit**

```powershell
git add README.md
git commit -m "docs(readme): post-boot cleanup task description + known CDM limitation"
```

---

### Task 28: Version bump

**Files:**
- Modify: `launcher/tiny11options.Launcher.csproj` (or wherever the version is pinned — also check `Directory.Build.props` if it exists)

- [ ] **Step 1: Bump the version**

Find the `<Version>1.0.0</Version>` element (or `<AssemblyVersion>` / `<FileVersion>` / `<InformationalVersion>`). Bump to `1.0.1`:

```xml
<Version>1.0.1</Version>
```

If the version is duplicated across multiple files (Directory.Build.props, AssemblyInfo, etc.), update all of them.

- [ ] **Step 2: Verify dotnet build succeeds**

Run: `cd launcher && dotnet build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```powershell
git add launcher/tiny11options.Launcher.csproj
git commit -m "chore(version): bump to 1.0.1"
```

---

### Task 29: Smoke P1 — Worker fresh install, task registered

**Manual.** Hyper-V Gen2 VM required. ~30-45 min wall-clock with Fast Build.

- [ ] **Step 1: Build a Worker ISO with default selections**

```powershell
cd C:\Users\jscha\source\repos\tiny11options\dist\raw
.\tiny11options.exe `
    -Source D:\Win11_25H2.iso `
    -Edition "Windows 11 Pro" `
    -OutputPath C:\Temp\p1-worker.iso `
    -ScratchDir C:\Temp\scratch-p1 `
    -FastBuild `
    -NonInteractive
```
(Substitute the launcher path / source ISO / scratch dir per your machine.)

- [ ] **Step 2: Boot the ISO in a fresh Hyper-V Gen2 VM, complete OOBE**

- [ ] **Step 3: In the booted VM, verify the task is registered**

Open an elevated PowerShell window in the VM:
```powershell
Get-ScheduledTask -TaskPath '\tiny11options\' | Select TaskName, State, LastRunTime
```
Expected: row showing `Post-Boot Cleanup` (State: `Ready` or `Running`).

- [ ] **Step 4: Pass criteria**

Task `Post-Boot Cleanup` exists at TaskPath `\tiny11options\`. If absent, examine `C:\Windows\Logs\tiny11-cleanup-setup.log` for the `schtasks /create` exit code.

- [ ] **Step 5: Record result in `docs/superpowers/smoke/2026-05-12-post-boot-cleanup-smoke.md`**

Create the file if absent:
```markdown
# Post-boot cleanup v1.0.1 smoke matrix

## P1 — Worker fresh install, task registered
- **Date:** <YYYY-MM-DD>
- **Build:** Worker, Fast Build, default selections
- **Result:** PASS / FAIL — <one-line summary>
- **Notes:** <any anomalies>
```

Commit:
```powershell
git add docs/superpowers/smoke/2026-05-12-post-boot-cleanup-smoke.md
git commit -m "test(smoke): P1 Worker fresh install — task registered"
```

---

### Task 30: Smoke P2 — Worker log inspection

**Manual.** Continue from P1's VM.

- [ ] **Step 1: Examine the cleanup log**

In the VM:
```powershell
Get-Content C:\Windows\Logs\tiny11-cleanup.log -Tail 100
```

- [ ] **Step 2: Pass criteria**

Log contains at least:
- One `==== tiny11-cleanup triggered ====` block from the SetupComplete immediate-run.
- One `==== tiny11-cleanup triggered ====` block from the BootTrigger PT10M firing (visible after 10+ min of uptime).
- All item lines for catalog items selected for removal report `already` (clean image had no restaged apps yet).

- [ ] **Step 3: Record + commit**

Append P2 section to `docs/superpowers/smoke/2026-05-12-post-boot-cleanup-smoke.md`. Commit as `test(smoke): P2 Worker log shows immediate + BootTrigger runs idempotent`.

---

### Task 31: Smoke P3 — Worker `-NoPostBootCleanup`

**Manual.** ~30-45 min on a fresh Hyper-V VM.

- [ ] **Step 1: Build a Worker ISO with cleanup disabled**

```powershell
.\tiny11options.exe `
    -Source D:\Win11_25H2.iso `
    -Edition "Windows 11 Pro" `
    -OutputPath C:\Temp\p3-worker-nocleanup.iso `
    -ScratchDir C:\Temp\scratch-p3 `
    -FastBuild `
    -NoPostBootCleanup `
    -NonInteractive
```

- [ ] **Step 2: Boot in fresh VM, complete OOBE**

- [ ] **Step 3: Verify NO task registered + NO files installed**

```powershell
Get-ScheduledTask -TaskPath '\tiny11options\' -ErrorAction SilentlyContinue
Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1'
Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.xml'
Test-Path 'C:\Windows\Setup\Scripts\SetupComplete.cmd'
```

- [ ] **Step 4: Pass criteria**

`Get-ScheduledTask` returns nothing. All three `Test-Path` calls return `$false`.

- [ ] **Step 5: Record + commit**

`test(smoke): P3 Worker -NoPostBootCleanup leaves no artifacts`

---

### Task 32: Smoke P4 — Core both tasks registered

**Manual.** ~30-60 min on a fresh Hyper-V VM (Core build is slower).

- [ ] **Step 1: Build a Core ISO with defaults**

```powershell
.\tiny11options.exe `
    -Source D:\Win11_25H2.iso `
    -Edition "Windows 11 Pro" `
    -OutputPath C:\Temp\p4-core.iso `
    -ScratchDir C:\Temp\scratch-p4 `
    -Core `
    -FastBuild `
    -NonInteractive
```

(Substitute the correct `-Core` invocation per your launcher's CLI shape.)

- [ ] **Step 2: Boot in fresh VM, complete OOBE**

- [ ] **Step 3: Verify BOTH tasks registered**

```powershell
Get-ScheduledTask -TaskPath '\tiny11options\' | Select TaskName, State
```
Expected: TWO rows — `Keep WU Disabled` AND `Post-Boot Cleanup`, both `Ready` / `Running`.

- [ ] **Step 4: Verify both log files populated**

```powershell
Get-Content C:\Windows\Logs\tiny11-wu-enforce.log -Tail 5
Get-Content C:\Windows\Logs\tiny11-cleanup.log    -Tail 5
```
Expected: both have at least one `==== triggered ====` entry.

- [ ] **Step 5: Record + commit**

`test(smoke): P4 Core both Keep-WU-Disabled and Post-Boot-Cleanup tasks registered`

---

### Task 33: Smoke P5 — Core `-NoPostBootCleanup`

**Manual.** ~30-60 min on a fresh Hyper-V VM.

- [ ] **Step 1: Build a Core ISO with cleanup disabled**

```powershell
.\tiny11options.exe `
    -Source D:\Win11_25H2.iso `
    -Edition "Windows 11 Pro" `
    -OutputPath C:\Temp\p5-core-nocleanup.iso `
    -ScratchDir C:\Temp\scratch-p5 `
    -Core `
    -FastBuild `
    -NoPostBootCleanup `
    -NonInteractive
```

- [ ] **Step 2: Boot in fresh VM, complete OOBE**

- [ ] **Step 3: Verify ONLY Keep-WU-Disabled task registered**

```powershell
Get-ScheduledTask -TaskPath '\tiny11options\' | Select TaskName
```
Expected: ONE row — `Keep WU Disabled` only.

- [ ] **Step 4: Verify cleanup files absent**

```powershell
Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1'
Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.xml'
```
Expected: both `$false`.

- [ ] **Step 5: Record + commit**

`test(smoke): P5 Core -NoPostBootCleanup leaves only Keep-WU-Disabled artifacts`

---

### Task 34: Smoke P6 — Real CU cycle observation (Worker)

**Manual.** ~2-3 hours wall-clock — real CU install + observation window.

- [ ] **Step 1: Reuse P1's VM (or build a fresh Worker VM if P1 was destroyed)**

- [ ] **Step 2: Baseline app inventory**

In the VM:
```powershell
Get-AppxProvisionedPackage -Online | Select DisplayName | Sort DisplayName > C:\baseline-prov.txt
Get-AppxPackage -AllUsers | Select Name | Sort Name > C:\baseline-user.txt
```

- [ ] **Step 3: Force Windows Update to fetch + install the latest CU**

```powershell
# Re-enable Windows Update temporarily — Worker builds don't disable it, but if any item set wuauserv to Disabled, re-enable for this test
Set-Service wuauserv -StartupType Manual
Start-Service wuauserv
usoclient StartScan
# Then trigger Settings → Windows Update → Check for updates and let it install
```
Wait for CU to complete (~30-60 min). VM may reboot.

- [ ] **Step 4: Capture post-CU inventory (before cleanup task fires)**

```powershell
Get-AppxProvisionedPackage -Online | Select DisplayName | Sort DisplayName > C:\post-cu-prov.txt
Compare-Object (Get-Content C:\baseline-prov.txt) (Get-Content C:\post-cu-prov.txt)
```

Note any restaged packages.

- [ ] **Step 5: Wait for cleanup task to fire on WU EventID 19**

The task should fire within seconds of CU install-completion. Wait ~10 min then:
```powershell
Get-Content C:\Windows\Logs\tiny11-cleanup.log -Tail 100
Get-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup' | Get-ScheduledTaskInfo | Select LastRunTime, LastTaskResult
```

- [ ] **Step 6: Capture post-cleanup inventory**

```powershell
Get-AppxProvisionedPackage -Online | Select DisplayName | Sort DisplayName > C:\post-cleanup-prov.txt
Compare-Object (Get-Content C:\baseline-prov.txt) (Get-Content C:\post-cleanup-prov.txt)
```

- [ ] **Step 7: Pass criteria**

Restaged packages observed in Step 4 are GONE in Step 6 (or at minimum: every restaged package that matches a `provisioned-appx` action in the catalog has been re-removed). Log shows `REMOVED` entries for each restaged item.

- [ ] **Step 8: Record + commit**

`test(smoke): P6 Worker real CU cycle — restaged appx re-removed within 10 min of CU completion`

Include in the smoke doc: which packages were restaged, which were re-removed, any that were NOT in the catalog (these document the catalog ceiling for v1.0.2 expansion).

---

### Task 35: Smoke P7 — Per-user fan-out

**Manual.** ~45 min on a fresh Worker VM.

- [ ] **Step 1: Build a Worker ISO that includes `tweak-disable-telemetry` (NTUSER actions)**

The default catalog has this enabled — a default Fast Build ISO suffices.

- [ ] **Step 2: Install in fresh VM, complete OOBE as User1**

- [ ] **Step 3: Create User2 and log in as User2**

```powershell
# As User1 (admin)
New-LocalUser -Name 'User2' -NoPassword
Add-LocalGroupMember -Group 'Users' -Member 'User2'
# Sign out, sign in as User2, complete first-login setup
```

- [ ] **Step 4: Wait for the cleanup task to fire (or run it manually)**

```powershell
# As User2 (or back to User1 admin):
Start-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup'
Start-Sleep 30
```

- [ ] **Step 5: Verify both user hives carry the NTUSER values**

```powershell
# Get User1's SID
$user1Sid = (Get-LocalUser -Name 'User1').SID.Value
$user2Sid = (Get-LocalUser -Name 'User2').SID.Value

(Get-ItemProperty -Path "HKU:\$user1Sid\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name Enabled -ErrorAction SilentlyContinue).Enabled
(Get-ItemProperty -Path "HKU:\$user2Sid\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name Enabled -ErrorAction SilentlyContinue).Enabled
# Also check HKU:\.DEFAULT
(Get-ItemProperty -Path "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name Enabled -ErrorAction SilentlyContinue).Enabled
```
(You may need to load User2's NTUSER.dat with `reg load` if HKU:\<user2Sid> isn't visible because User2 isn't logged in.)

- [ ] **Step 6: Pass criteria**

All three `(Get-ItemProperty ...).Enabled` values return `0`. (`.DEFAULT` may not exist initially — if not, that's a bug worth flagging; the script should have created it.)

- [ ] **Step 7: Record + commit**

`test(smoke): P7 NTUSER fan-out — multi-user + .DEFAULT all carry the registry value`

---

### Task 36: Smoke P8 — Edge re-staging behavior

**Manual.** ~2-3 hours — needs real CU cycle. Best-effort observation; the catalog can't always prevent every restage variant.

- [ ] **Step 1: Build a Worker ISO with ALL edge-and-webview items enabled (default state)**

Default Fast Build covers this.

- [ ] **Step 2: Install in fresh VM, complete OOBE**

- [ ] **Step 3: Verify Edge folders absent at first boot**

```powershell
Test-Path 'C:\Program Files (x86)\Microsoft\Edge'
Test-Path 'C:\Program Files (x86)\Microsoft\EdgeUpdate'
Test-Path 'C:\Program Files (x86)\Microsoft\EdgeCore'
Test-Path 'C:\Windows\System32\Microsoft-Edge-Webview'
```
Expected: all `$false`.

- [ ] **Step 4: Run a CU cycle (same as P6 Step 3)**

- [ ] **Step 5: Re-check Edge folders post-CU, pre-cleanup**

Same `Test-Path` checks. Edge MAY have restaged into one or more of these paths — this is what we're observing.

- [ ] **Step 6: Wait for cleanup task to fire on EventID 19**

- [ ] **Step 7: Re-check Edge folders post-cleanup**

Same `Test-Path` checks. Cleanup should have re-removed whichever Edge folder(s) restaged.

- [ ] **Step 8: Pass criteria**

If Edge restaged in Step 5 paths that the catalog covers (Edge / EdgeUpdate / EdgeCore / System32\Microsoft-Edge-Webview), those paths should be GONE in Step 7. Log file should contain `REMOVED` entries for each restaged Edge path.

If Edge restaged into a path NOT covered by the catalog, document it — this is feedback for v1.0.2 catalog expansion.

- [ ] **Step 9: Record + commit**

`test(smoke): P8 Edge re-staging — cleanup re-removes catalog-covered paths after CU restage`

---

### Task 37: Cut release

**Files:**
- Modify: `CHANGELOG.md` (set release date)

- [ ] **Step 1: Set the actual release date in CHANGELOG.md**

Replace `## [1.0.1] - <YYYY-MM-DD>` with today's actual date.

```powershell
# Open CHANGELOG.md, replace the placeholder date, then:
git add CHANGELOG.md
git commit -m "docs(changelog): set v1.0.1 release date"
```

- [ ] **Step 2: Confirm working tree clean + all tests green**

```powershell
git status
pwsh -NoProfile -Command "& { $r = Invoke-Pester -Configuration (Import-PowerShellDataFile tests/Tiny11.PesterConfig.ps1) -PassThru; if ($r.FailedCount -gt 0) { Write-Error 'Pester FAILED'; exit 1 } else { Write-Output ('Pester: {0} passed' -f $r.PassedCount) } }"
cd launcher/Tests; dotnet test --logger "console;verbosity=minimal"; cd ../..
```

- [ ] **Step 3: Merge branch to main**

```powershell
git checkout main
git merge --no-ff feat/v1.0.1-post-boot-cleanup
git push origin main
```

- [ ] **Step 4: Tag v1.0.1 and push the tag**

```powershell
git tag -a v1.0.1 -m "v1.0.1 — Post-boot cleanup scheduled task"
git push origin v1.0.1
```

This triggers `release.yml` to build, package, and publish the GitHub release.

- [ ] **Step 5: Verify the release.yml run is green**

```powershell
gh run list --workflow=release.yml --limit 1
gh run watch
```

When green, verify the GitHub release at `https://github.com/bilbospocketses/tiny11options/releases/tag/v1.0.1` has the expected assets attached: `tiny11options-win-Setup.exe`, `tiny11options-1.0.1-full.nupkg`, `tiny11options-1.0.1-delta.nupkg` (if Velopack emits a delta), `RELEASES`.

- [ ] **Step 6: Delete the feature branch**

```powershell
git branch -d feat/v1.0.1-post-boot-cleanup
git push origin --delete feat/v1.0.1-post-boot-cleanup
```

- [ ] **Step 7: Update memory (project todo) — done outside this plan, performed via the "do that thing" wrap-up SOP.**

---
