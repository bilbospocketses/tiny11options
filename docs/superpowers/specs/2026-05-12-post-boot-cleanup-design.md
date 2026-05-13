# Post-Boot Cleanup Scheduled Task — Design Spec (v1.0.1)

**Date:** 2026-05-12
**Target release:** v1.0.1
**Branch:** `feat/v1.0.1-post-boot-cleanup`
**Status:** design approved; pending implementation plan

## Problem

Microsoft cumulative updates silently restore inbox apps that tiny11 removed offline (Clipchamp, Copilot, Outlook, Edge folders, etc. observed reappearing on first full OS boot after auto-update) and reset hardening registry values (`ContentDeliveryManager` keys per the Microsoft Q&A confirmation). This is by-design behavior in Windows Update — confirmed by Microsoft Support specialist response on [learn.microsoft.com/en-us/answers/questions/4081909](https://learn.microsoft.com/en-us/answers/questions/4081909/windows-11-cumulative-update-changing-registry-com): *"Windows Update restores registry settings. This is by design."*

User intent: KEEP Windows Update running for security patches; only re-remove the items the user explicitly chose to remove at build time. The catalog selection is the source of truth — items the user chose to keep must NEVER be touched by the cleanup task.

No existing tiny11 fork addresses this. [chrisGrando/tiny11maker-reforged](https://github.com/chrisGrando/tiny11maker-reforged) README explicitly documents *"Outlook and Dev Home might reappear after some time"* with no mitigation. This is a differentiator for tiny11options.

## Load-bearing constraints

- **Per-build tailoring.** The cleanup script must be generated PER BUILD by iterating `ResolvedSelections` where `EffectiveState=='apply'`. User A who unchecks Edge → cleanup never touches Edge. User B who leaves Edge checked → cleanup re-removes Edge on every trigger.
- **Catalog is the list.** No empirical VM audit to "discover what comes back" — the catalog encodes the user's removal intent; cleanup re-applies that intent on the running OS.
- **Single source for action knowledge.** Each Actions module (`Tiny11.Actions.{Registry,Filesystem,ProvisionedAppx,ScheduledTask}.psm1`) owns BOTH its offline behavior AND its online-translation behavior via a sibling emitter function. No duplicate switch-on-action-type logic anywhere else.
- **Idempotent re-runs.** Every helper checks state first; "already-correct" is a logged no-op. Re-running on a clean machine produces zero mutations.
- **Reuse Core's proven scaffolding patterns.** The Core build's `SetupComplete.cmd` + `tiny11-wu-enforce.xml` + `tiny11-wu-enforce.ps1` triad has been validated empirically (Phase 7 C3 / C4 soak tests). Copy the encoding conventions, log-rotation, and idempotent-logging patterns verbatim.

## Decisions locked during brainstorming

| Decision | Outcome |
|---|---|
| Emitter return shape | Array of `[pscustomobject]@{ Kind, Args, Description }` — structured command objects, not raw PS strings |
| Relationship to Core's WU-enforce | Parallel + both run on Core (option A from clarifier 2). Worker gets ONE task; Core gets TWO (existing `Keep WU Disabled` untouched + new `Post-Boot Cleanup`) |
| Catalog content scope for v1.0.1 | Ship generator first; catalog stays exactly as-is. Partial CDM re-enforcement (4 of 11 CDM keys) is documented as known v1.0.1 limitation; full catalog expansion deferred to v1.0.2 |
| Trigger model | 3 triggers: BootTrigger PT10M + CalendarTrigger 03:00 daily + EventTrigger WU/Operational EventID 19. NOT Core's full 5-trigger model — PT1M repetition is overkill for monthly-CU cadence; SCM 7040 is irrelevant for appx restage |
| Scheduled-task online verb | `Remove-Item -Recurse -Force` against `$env:SystemRoot\System32\Tasks\<path>`. Matches offline file-delete semantics; matches Core's WU-enforce pattern; no `Unregister-ScheduledTask` / `Disable-ScheduledTask` complication |
| Edge handling | Falls out naturally — catalog already composes Edge removal as 3 filesystem actions + 2 registry actions across `remove-edge`, `remove-edge-webview`, `tweak-remove-edge-uninstall-keys`. No special-case code; no new action types |
| Build-option persistence | `state.installPostBootCleanup` is per-session, default `true`, NOT exported to profile JSON. Same category as Fast Build |
| Headless default | `-InstallPostBootCleanup:$true` by default (interactive and headless symmetric); `-NoPostBootCleanup` switch as opt-out sugar |
| COMPONENTS hive | Emitter throws `"COMPONENTS hive cleanup not supported online"`. No catalog item uses it today; regression-tested |

## Architecture

### New module

**`src/Tiny11.PostBoot.psm1`** (~250-350 lines).

Exports:

- `Install-Tiny11PostBootCleanup -MountDir -Catalog -ResolvedSelections -Enabled` — Worker entry point. Writes 3 files into `<mount>\Windows\Setup\Scripts\`. No-op when `-Enabled:$false`.
- `New-Tiny11PostBootCleanupScript -Catalog -ResolvedSelections` — pure generator. Returns the `tiny11-cleanup.ps1` content as a string. Stateless; testable in isolation.
- `New-Tiny11PostBootTaskXml` — returns the `tiny11-cleanup.xml` content. Static for v1.0.1 (same triggers regardless of catalog).
- `New-Tiny11PostBootSetupCompleteScript` — Worker-only. Returns the SetupComplete.cmd content that registers the cleanup task at first boot.

Internal:

- `$script:headerBlock` — static prelude (banner + logger + log-rotation block, ~30 lines, copied verbatim from Core's `tiny11-wu-enforce.ps1` pattern)
- `$script:helpersBlock` — static helper functions (~120 lines, see Section "Helper functions" below)
- `$script:footerBlock` — `Write-CleanupLog '==== tiny11-cleanup done ===='`

### Existing modules touched (additive only)

| File | Addition |
|---|---|
| `src/Tiny11.Actions.Registry.psm1` | `Get-Tiny11RegistryOnlineCommand -Action` |
| `src/Tiny11.Actions.Filesystem.psm1` | `Get-Tiny11FilesystemOnlineCommand -Action` |
| `src/Tiny11.Actions.ProvisionedAppx.psm1` | `Get-Tiny11ProvisionedAppxOnlineCommand -Action` |
| `src/Tiny11.Actions.ScheduledTask.psm1` | `Get-Tiny11ScheduledTaskOnlineCommand -Action` |
| `src/Tiny11.Actions.psm1` | `Get-Tiny11ActionOnlineCommand -Action` (dispatcher, mirrors `Invoke-Tiny11Action`) |
| `src/Tiny11.Worker.psm1` | Call `Install-Tiny11PostBootCleanup` in `Invoke-Tiny11BuildPipeline` after apply phase, before unmount. New progress marker `inject-postboot-cleanup` at ~95% |
| `src/Tiny11.Core.psm1` | `New-Tiny11CorePostBootCleanupScript` extended with `[switch]$IncludePostBootCleanupRegistration`; `Install-Tiny11CorePostBootCleanup` extended with `-PostBootCleanupCatalog`, `-PostBootCleanupResolvedSelections`, `-PostBootCleanupEnabled` params |

No offline-apply path behavior changes. Existing `Invoke-Tiny11Action` and the offline action handlers are untouched.

### Pipeline integration

**Worker pipeline (`Invoke-Tiny11BuildPipeline`):**

```
... apply phase ...
& $ProgressCallback @{ phase='inject-postboot-cleanup'; step='Installing post-boot cleanup task'; percent=95 }
Install-Tiny11PostBootCleanup -MountDir $scratchImg -Catalog $catalog `
    -ResolvedSelections $resolved -Enabled:$InstallPostBootCleanup
... dismount + ISO finalize ...
```

**Core pipeline (`Invoke-Tiny11CoreBuildPipeline`):** existing `Install-Tiny11CorePostBootCleanup` call gains the cleanup-related params; internally writes 2 more files (`tiny11-cleanup.xml`, `tiny11-cleanup.ps1`) when enabled, and passes `-IncludePostBootCleanupRegistration` when generating SetupComplete.cmd.

## Per-action emitter contracts

Each emitter returns an **array** of `[pscustomobject]` (usually 1 object; can be empty for skip-able cases — though no current action type produces empty). Schema:

```
[pscustomobject]@{
    Kind        = '<helper-name>'           # which helper in the script header to call
    Args        = @{ <param>=<value>; ... } # rendered as -Param Value pairs in the generated script
    Description = '<human-readable string>' # rendered as a # comment line above the call
}
```

The generator emits each command object as **named-parameter syntax** (NOT splat — PS splat requires a variable, not an inline hashtable):

```
# <Description>
<Kind> -<Param1> <Value1> -<Param2> <Value2> ...
```

Example rendered output for the NTUSER registry case below:

```powershell
# Set HKU:*\Software\...\AdvertisingInfo!Enabled = 0 (per-user, all loaded SIDs + .DEFAULT)
Set-RegistryValueForAllUsers -RelativeKeyPath 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Type 'DWord' -Value 0
```

Dispatcher (`src/Tiny11.Actions.psm1`):

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

### Registry emitter

Hive routing:

| Offline `hive` | Online emit |
|---|---|
| `SOFTWARE`   | `Set-RegistryValue` / `Remove-RegistryKey` against `HKLM:\Software\<key>` |
| `SYSTEM`     | `Set-RegistryValue` / `Remove-RegistryKey` against `HKLM:\SYSTEM\<key>` |
| `DEFAULT`    | `Set-RegistryValue` / `Remove-RegistryKey` against `HKU:\.DEFAULT\<key>` |
| `NTUSER`     | `Set-RegistryValueForAllUsers` / `Remove-RegistryKeyForAllUsers` — helper iterates `HKU:\*` filtering for SID-shaped names AND writes to `HKU:\.DEFAULT`. ONE command object; fan-out happens inside the helper at runtime |
| `COMPONENTS` | `throw "COMPONENTS hive cleanup not supported online"` — guarded; regression-tested |

`valueType` translation: `REG_DWORD` → `'DWord'`, `REG_SZ` → `'String'`, `REG_EXPAND_SZ` → `'ExpandString'`, `REG_BINARY` → `'Binary'`, `REG_MULTI_SZ` → `'MultiString'`, `REG_QWORD` → `'QWord'`.

For `op:'set'`, `REG_DWORD` values parse to `[int]`; `REG_QWORD` values parse to `[long]` (Int64 — int32 overflows for QWORD); `REG_BINARY` values parse from hex string to `[byte[]]`; `REG_MULTI_SZ` values parse from `|`-delimited string to `[string[]]`; other types stay as strings.

Example — input `{ type:'registry', hive:'NTUSER', key:'Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo', op:'set', name:'Enabled', valueType:'REG_DWORD', value:'0' }` emits:

```
[pscustomobject]@{
    Kind = 'Set-RegistryValueForAllUsers'
    Args = @{ RelativeKeyPath='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Type='DWord'; Value=0 }
    Description = 'Set HKU:*\Software\...\AdvertisingInfo!Enabled = 0 (per-user, all loaded SIDs + .DEFAULT)'
}
```

**Key-path convention by hive:**
- `NTUSER` emitter sends `RelativeKeyPath` (no `HKU:` prefix); `Set-RegistryValueForAllUsers` / `Remove-RegistryKeyForAllUsers` helpers prepend `HKU:\<sid>\` for each loaded user SID + `HKU:\.DEFAULT`.
- `SOFTWARE` / `SYSTEM` / `DEFAULT` emitters send absolute `KeyPath` (e.g. `HKLM:\Software\...`, `HKU:\.DEFAULT\...`); `Set-RegistryValue` / `Remove-RegistryKey` helpers use as-is.

The two parameter names (`KeyPath` vs `RelativeKeyPath`) make the convention explicit at the call site — readers know which helper is being invoked without consulting the helper body.

### Filesystem emitter

| `op` | Helper |
|---|---|
| `remove`             | `Remove-PathIfPresent -Path "$env:SystemDrive\<path>" -Recurse:$recurse` |
| `takeown-and-remove` | `Remove-PathWithOwnership -Path "$env:SystemDrive\<path>" -Recurse:$recurse` (helper does takeown + icacls + Remove-Item) |

Unknown `op` → `throw "Invalid filesystem op: $($Action.op)"` (mirrors offline strictness).

### Scheduled-task emitter

```
[pscustomobject]@{
    Kind = 'Remove-PathIfPresent'
    Args = @{ Path="$env:SystemRoot\System32\Tasks\<path>"; Recurse=$Action.recurse }
    Description = "Remove scheduled task XML '$($Action.path)'"
}
```

`Action.path` separator normalized: `/` → `\` (mirrors offline `Invoke-ScheduledTaskAction`).

Unknown `op` → `throw "Invalid scheduled-task op: $($Action.op)"`.

### Provisioned-appx emitter

```
[pscustomobject]@{
    Kind = 'Remove-AppxByPackagePrefix'
    Args = @{ Prefix=$Action.packagePrefix }
    Description = "Remove provisioned + installed appx matching '$($Action.packagePrefix)*'"
}
```

Helper at runtime executes BOTH operations:

```powershell
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "$Prefix*" |
    Remove-AppxProvisionedPackage -Online -ErrorAction Continue
Get-AppxPackage -AllUsers -Name "$Prefix*" -ErrorAction SilentlyContinue |
    Remove-AppxPackage -AllUsers -ErrorAction Continue
```

## Generated script anatomy

`tiny11-cleanup.ps1` structure:

```
[ header banner + meta + logger + log rotation ]
[ helpers block (all online-action functions) ]
[ body — one block per ResolvedSelection.EffectiveState=='apply' item ]
[ footer ]
```

### Header

```powershell
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
    } catch { }
}

function Write-CleanupLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-CleanupLog '==== tiny11-cleanup triggered ===='
```

### Helper functions (static block)

All helpers use the "already-correct vs CORRECTED" idempotent-logging pattern from Core (`Tiny11.Core.psm1:760-768`). Mounted as a single string constant `$script:helpersBlock` inside `Tiny11.PostBoot.psm1` and emitted verbatim.

```powershell
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
```

### Body composition

Generator iterates `$Catalog.Items` IN ORDER (stable iteration). For each item where `$ResolvedSelections[$item.id].EffectiveState -eq 'apply'`:

```
# --- Item: <displayName> (<id>) ---
# <Description of action 1>
<Kind1> -<Param> <Value> -<Param> <Value> ...
# <Description of action 2>
<Kind2> -<Param> <Value> -<Param> <Value> ...
```

For action argument serialization, the generator uses a small `Format-PSNamedParams` helper that emits named-parameter syntax (not splat — PS splat requires a variable, not an inline hashtable). Per-value-type rules:

- `[string]` → single-quoted with `'` doubling for escapes (e.g. `'Program Files (x86)\Microsoft\Edge'`)
- `[int]` / `[long]` → unquoted (e.g. `0`, `4`)
- `[bool]` → `$true` / `$false` unquoted PS literals; switch-style params render as `-Recurse:$true` / `-Recurse:$false`
- `[byte[]]` (REG_BINARY) → `([byte[]](0x1,0x2,0x3))` form (not currently used by any catalog item; reserved)
- `[string[]]` (REG_MULTI_SZ) → `@('a','b')` form (not currently used; reserved)

Iteration order matches catalog item order in `catalog.json` so output is deterministic across runs with identical inputs.

### Footer

```powershell
Write-CleanupLog '==== tiny11-cleanup done ===='
```

## Scheduled task XML

`tiny11-cleanup.xml` (UTF-16 LE + BOM, static across all builds in v1.0.1):

```xml
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
```

Trigger rationale:

- **BootTrigger PT10M** — let WU + start-of-day services settle before our pass runs.
- **CalendarTrigger 03:00 daily** — catches CU-induced restoration in the gap between boot and the next CU event.
- **EventTrigger WU EventID 19** — reactive trigger on "Installation Successful: Windows successfully installed the following update". Most valuable for whack-a-mole; fires within seconds of CU completion.

**Not included** (relative to Core's 5-trigger model):

- **TimeTrigger PT1M repetition** — Core uses this as a proven safety net for SCM-7040 unreliability. For the cleanup case, our triggers are CU-cadence (monthly), not service-state-change-cadence. PT1M is wasteful; if it's later proven necessary, add it then.
- **EventTrigger SCM 7040** — service-state-change. Not relevant to appx restage or registry reset; doesn't help our use case.

`PT30M` execution time limit — longer than Core's `PT10M` because per-user appx removal across multiple SIDs can be slow (each `Remove-AppxPackage` call against a user hive can take 1-5 sec; with 5-10 users × 10+ appx items, low end is 50-500 sec).

## SetupComplete.cmd

### Worker

`New-Tiny11PostBootSetupCompleteScript` returns (ASCII + CRLF; encoded by the install function):

```cmd
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
```

### Core extension

`New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration`. Implementation pattern: split the existing Core SetupComplete.cmd heredoc into a base block + a closing self-delete block. When the switch is true, concatenate a middle block:

```cmd
echo [tiny11options] Registering Post-Boot Cleanup scheduled task >> "%TINY11_LOG%"
schtasks /create /xml "%SystemDrive%\Windows\Setup\Scripts\tiny11-cleanup.xml" /tn "tiny11options\Post-Boot Cleanup" /f >> "%TINY11_LOG%" 2>&1
echo [tiny11options] cleanup-task schtasks exited with %ERRORLEVEL% >> "%TINY11_LOG%"
```

Inserted just before the `del /F /Q "%~f0"` line. Core's existing WU-enforce registration + immediate-run lines stay unchanged.

## Install function flow

### Worker

```powershell
function Install-Tiny11PostBootCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $MountDir,
        [Parameter(Mandatory)]         $Catalog,
        [Parameter(Mandatory)][hashtable] $ResolvedSelections,
        [bool] $Enabled = $true
    )
    if (-not $Enabled) { return }

    $scriptsDir = Join-Path $MountDir 'Windows\Setup\Scripts'
    if (-not (Test-Path -LiteralPath $scriptsDir)) {
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    }

    # 1. SetupComplete.cmd  (ASCII + CRLF)
    $cmdContent = New-Tiny11PostBootSetupCompleteScript
    $cmdContentCRLF = ($cmdContent -split "`r?`n") -join "`r`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $scriptsDir 'SetupComplete.cmd'),
        $cmdContentCRLF, [System.Text.Encoding]::ASCII)

    # 2. tiny11-cleanup.ps1  (UTF-8 + BOM)
    $psContent = New-Tiny11PostBootCleanupScript -Catalog $Catalog -ResolvedSelections $ResolvedSelections
    [System.IO.File]::WriteAllText(
        (Join-Path $scriptsDir 'tiny11-cleanup.ps1'),
        $psContent, [System.Text.UTF8Encoding]::new($true))

    # 3. tiny11-cleanup.xml  (UTF-16 LE + BOM)
    $xmlContent = New-Tiny11PostBootTaskXml
    [System.IO.File]::WriteAllText(
        (Join-Path $scriptsDir 'tiny11-cleanup.xml'),
        $xmlContent, [System.Text.Encoding]::Unicode)
}
```

### Core

`Install-Tiny11CorePostBootCleanup` extended:

```powershell
function Install-Tiny11CorePostBootCleanup {
    param(
        [Parameter(Mandatory)][string] $MountDir,
        # NEW:
        $PostBootCleanupCatalog,
        [hashtable] $PostBootCleanupResolvedSelections,
        [bool] $PostBootCleanupEnabled = $true
    )
    # ... existing logic: create scriptsDir, write WU-enforce trio ...

    # SetupComplete.cmd content depends on cleanup-enabled
    $cmdContent = New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration:$PostBootCleanupEnabled

    # NEW: write cleanup files when enabled
    if ($PostBootCleanupEnabled -and $PostBootCleanupCatalog -and $PostBootCleanupResolvedSelections) {
        $psContent = New-Tiny11PostBootCleanupScript `
            -Catalog $PostBootCleanupCatalog `
            -ResolvedSelections $PostBootCleanupResolvedSelections
        [System.IO.File]::WriteAllText(
            (Join-Path $scriptsDir 'tiny11-cleanup.ps1'),
            $psContent, [System.Text.UTF8Encoding]::new($true))

        $xmlContent = New-Tiny11PostBootTaskXml
        [System.IO.File]::WriteAllText(
            (Join-Path $scriptsDir 'tiny11-cleanup.xml'),
            $xmlContent, [System.Text.Encoding]::Unicode)
    }
    # ... existing SetupComplete.cmd write happens with the conditionally-extended content ...
}
```

## UI + build-option wiring

### Step 1 UI

New checkbox in Step 1 options panel, below Fast Build:

```
[x] Install post-boot cleanup task
    Re-removes apps and re-applies tweaks if Windows Update brings them back.
    Adds a scheduled task (~30 sec daily, plus when CUs install).
```

Default: checked. Bound to `state.installPostBootCleanup` (default `true`).

### State + payload flow

| Layer | Field |
|---|---|
| `state.installPostBootCleanup` | `true \| false`, default `true` |
| `start-build` payload | `installPostBootCleanup: state.installPostBootCleanup` |
| `BridgeMessage.payload` (C#) | new property `installPostBootCleanup: bool?` (nullable for backward compat; treated as `true` if missing) |
| `BuildHandlers.cs` → wrapper invocation | `-InstallPostBootCleanup:$true` / `-InstallPostBootCleanup:$false` |
| `tiny11maker-from-config.ps1` parameter | `[bool]$InstallPostBootCleanup = $true` |
| `tiny11maker.ps1` parameter (headless) | `[bool]$InstallPostBootCleanup = $true` |
| `Invoke-Tiny11BuildPipeline` parameter | `[bool]$InstallPostBootCleanup = $true` |
| `Install-Tiny11PostBootCleanup -Enabled` | flows through |

### Headless CLI

New switches on `tiny11maker.ps1` and `tiny11Coremaker-from-config.ps1`:

- `-InstallPostBootCleanup` (default `$true`)
- `-NoPostBootCleanup` (sugar for `-InstallPostBootCleanup:$false`)

Help text documents both.

### Persistence policy

**NOT** exported to profile JSON. Per-session build preference, same category as Fast Build. Profile import/export does not touch this field.

## Error handling + logging

### Three log files

| File | Owner | Rotation |
|---|---|---|
| `%SystemDrive%\Windows\Logs\tiny11-cleanup-setup.log` | SetupComplete.cmd | None — single first-boot run |
| `%SystemDrive%\Windows\Logs\tiny11-cleanup.log` | tiny11-cleanup.ps1 (active) | 5000 lines → rotates to `.log.1`, prior `.log.1` dropped |
| `%SystemDrive%\Windows\Logs\tiny11-cleanup.log.1` | tiny11-cleanup.ps1 (rolled) | Replaced on rotation |

At ~31 runs/month × ~50 lines/run, the active log holds ~3.2 months of history. Comfortable for diagnostics.

### Failure handling

- **SetupComplete.cmd failures** (first boot only) — `schtasks /create` exit code is logged; SetupComplete continues to immediate-run line regardless. Immediate-run catches first enforcement pass even if recurring task registration failed. Subsequent Setup passes (rare) retry registration.
- **Recurring-run failures** — `$ErrorActionPreference = 'Continue'`; each helper wraps destructive ops in try/catch with explicit failure logging. Pattern: `Write-CleanupLog "  X correction FAILED: $($_.Exception.Message)"`. Script never aborts mid-run.
- **Already-correct logging** — each helper INFO-logs the no-op case, so the log distinguishes "ran but nothing to do" from "ran and corrected" from "ran and failed".
- **Build-time generator failures** — `throw` for unknown action types, unknown hives, unknown ops. Surfaces in build log; prevents shipping a partially-broken ISO.

## Testing strategy

### Pester unit tests (new files)

| File | Coverage |
|---|---|
| `tests/Tiny11.Actions.Registry.Online.Tests.ps1` | Every hive × every op for `Get-Tiny11RegistryOnlineCommand` (~10 It blocks) |
| `tests/Tiny11.Actions.Filesystem.Online.Tests.ps1` | Both ops × recurse true/false (~5 It blocks) |
| `tests/Tiny11.Actions.ProvisionedAppx.Online.Tests.ps1` | Single shape with sample prefixes (~3 It blocks) |
| `tests/Tiny11.Actions.ScheduledTask.Online.Tests.ps1` | Recurse true/false, path separator normalization (~5 It blocks) |

All use structured assertions — `Should -Be` against `.Kind` / `.Args.X` / `.Description`. No string-matching against generated PS.

### Pester integration tests (new files)

| File | Coverage |
|---|---|
| `tests/Tiny11.PostBoot.Generator.Tests.ps1` | Body structure assertions (item ordering, EffectiveState='skip' filtering, empty selections). Targeted golden snippets for tricky cases (NTUSER fan-out, takeown-and-remove, REG_DWORD vs REG_SZ serialization) |
| `tests/Tiny11.PostBoot.Helpers.Golden.Tests.ps1` | Byte-equal comparison of helpers-block against `tests/golden/tiny11-cleanup-helpers.txt` (detects helper-content drift) |
| `tests/Tiny11.PostBoot.TaskXml.Tests.ps1` | XML parseable; 3 triggers present; BootTrigger PT10M; EventTrigger contains EventID=19; Principal S-1-5-18; ExecutionTimeLimit PT30M |
| `tests/Tiny11.PostBoot.SetupComplete.Tests.ps1` | Worker output structure; Core output with/without `-IncludePostBootCleanupRegistration` switch |
| `tests/Tiny11.PostBoot.Install.Tests.ps1` | `-Enabled:$false` writes nothing; `-Enabled:$true` writes 3 files with correct BOM/encoding; creates Scripts dir if missing |

### Existing test extensions

- `tests/Tiny11.Actions.Tests.ps1` — extend dispatcher tests to cover `Get-Tiny11ActionOnlineCommand` mirroring `Invoke-Tiny11Action`
- `tests/Tiny11.Worker.Tests.ps1` — assert `Invoke-Tiny11BuildPipeline` calls `Install-Tiny11PostBootCleanup` (mock + verify-called)
- `tests/Tiny11.Core.Tests.ps1` — extend to assert Core's SetupComplete.cmd output contains the new schtasks line when switch is true, NOT when false
- `tests/Tiny11.ScriptEncoding.Tests.ps1` — new files auto-picked-up by walker; generated `tiny11-cleanup.ps1` golden fixture must be ASCII-or-BOM

### xUnit C# tests

- `BuildHandlersTests.cs` — `installPostBootCleanup` payload deserialized correctly when present; defaults to `true` when missing
- `BuildHandlersTests.cs` — wrapper invocation includes `-InstallPostBootCleanup:$true` / `-InstallPostBootCleanup:$false` based on payload
- `BridgeMessageContractTests.cs` — add `installPostBootCleanup` to the contract allowlist

### Manual VM smoke matrix

| ID | Build | Cleanup | Test | Pass criteria |
|---|---|---|---|---|
| P1 | Worker | yes | Fresh install → first boot → `Get-ScheduledTask -TaskPath '\tiny11options\'` | Task `Post-Boot Cleanup` registered |
| P2 | Worker | yes | Examine `tiny11-cleanup.log` after P1 | Immediate-run + BootTrigger entries logged; clean image shows all "already" entries |
| P3 | Worker | no  | Fresh install with `-NoPostBootCleanup` | NO task registered; NO files in `Windows\Setup\Scripts\` |
| P4 | Core   | yes | Fresh install → first boot | BOTH `Keep WU Disabled` AND `Post-Boot Cleanup` tasks registered; both logs populated |
| P5 | Core   | no  | Fresh install with `-NoPostBootCleanup` | Only `Keep WU Disabled` task registered |
| P6 | Worker | yes | Real CU cycle: baseline `Get-AppxPackage`, install latest CU, wait for cleanup to fire on EventID 19 | Restaged provisioned packages re-removed within 10 min of CU completion |
| P7 | Worker | yes | Per-user fan-out: build with `tweak-disable-telemetry`, install, create 2nd user account, verify `HKU:\<sid>\Software\...\AdvertisingInfo!Enabled` = 0 | Both user hives carry the NTUSER values |
| P8 | Worker | yes | Edge specific: build with all edge-and-webview items, install, run CU, observe Edge re-stage behavior, verify cleanup acts | Edge stays gone after CU (best-effort; documents real-world behavior) |

Total wall-clock budget: ~1 day (P6 + P8 require real CU install ~2-3 hrs each; P1-P5 + P7 ~30-45 min each on Hyper-V Gen2 Fast Build).

### Test count target

- Pester: +35-45 tests across 5 new files + 4 extensions. Current 283 → ~325 post-v1.0.1.
- xUnit: +3-5 tests. Current 80 → ~85 post-v1.0.1.

## Known limitations (v1.0.1)

- **Partial CDM re-enforcement.** The catalog's `tweak-disable-sponsored-apps` item covers 4 of 11 CDM registry values per the Microsoft Q&A confirmation. The cleanup task re-enforces ONLY what the catalog has — so 7 of 11 CDM values restored by CUs remain restored after cleanup. Documented in CHANGELOG + README. Full catalog expansion deferred to v1.0.2.
- **Catalog ceiling.** If a CU introduces a brand-new app the catalog doesn't know about, it stays installed. The catalog needs to keep up with Microsoft's app additions; that's a maintenance ongoing concern, not a v1.0.1 gap.
- **COMPONENTS hive not supported online.** Regression-tested via emitter throw. No catalog item uses this hive currently.
- **User-initiated disable.** No in-OS UI to disable the cleanup task after install. Users can manually `Disable-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup'` or `Unregister-ScheduledTask` if they change their minds. Not a blocking gap for v1.0.1.

## Out of scope (deferred)

- Catalog expansion to cover full CDM hardening + audit other items for CU-reset gaps (v1.0.2 scope).
- Automated end-to-end test harness for the cleanup script against a real install (still gated on the broader E2E-test-harness deferred item).
- Telemetry on what CUs are restaging across the install base (would help drive catalog updates but adds privacy/infra burden).
- An in-OS uninstaller for the cleanup task.
- Code signing of the generated ps1/xml files (v1.0.2 bucket).

## File summary

**New:**

- `src/Tiny11.PostBoot.psm1`
- `tests/Tiny11.Actions.Registry.Online.Tests.ps1`
- `tests/Tiny11.Actions.Filesystem.Online.Tests.ps1`
- `tests/Tiny11.Actions.ProvisionedAppx.Online.Tests.ps1`
- `tests/Tiny11.Actions.ScheduledTask.Online.Tests.ps1`
- `tests/Tiny11.PostBoot.Generator.Tests.ps1`
- `tests/Tiny11.PostBoot.Helpers.Golden.Tests.ps1`
- `tests/Tiny11.PostBoot.TaskXml.Tests.ps1`
- `tests/Tiny11.PostBoot.SetupComplete.Tests.ps1`
- `tests/Tiny11.PostBoot.Install.Tests.ps1`
- `tests/golden/tiny11-cleanup-helpers.txt`
- `tests/golden/tiny11-cleanup-<targeted-snippet>.txt` files as needed

**Modified:**

- `src/Tiny11.Actions.Registry.psm1` (+`Get-Tiny11RegistryOnlineCommand`)
- `src/Tiny11.Actions.Filesystem.psm1` (+`Get-Tiny11FilesystemOnlineCommand`)
- `src/Tiny11.Actions.ProvisionedAppx.psm1` (+`Get-Tiny11ProvisionedAppxOnlineCommand`)
- `src/Tiny11.Actions.ScheduledTask.psm1` (+`Get-Tiny11ScheduledTaskOnlineCommand`)
- `src/Tiny11.Actions.psm1` (+`Get-Tiny11ActionOnlineCommand` dispatcher)
- `src/Tiny11.Worker.psm1` (+`Install-Tiny11PostBootCleanup` call in `Invoke-Tiny11BuildPipeline`; `-InstallPostBootCleanup` param)
- `src/Tiny11.Core.psm1` (`New-Tiny11CorePostBootCleanupScript` + `Install-Tiny11CorePostBootCleanup` extensions)
- `tiny11maker.ps1` (`-InstallPostBootCleanup`/`-NoPostBootCleanup` switches)
- `tiny11maker-from-config.ps1` (same)
- `tiny11Coremaker-from-config.ps1` (same)
- `ui/index.html` (Step 1 checkbox)
- `ui/app.js` (`state.installPostBootCleanup`; payload field)
- `launcher/BuildHandlers.cs` (payload field; wrapper invocation)
- `launcher/BridgeMessage.cs` (`installPostBootCleanup: bool?` field)
- `tests/Tiny11.Actions.Tests.ps1` (dispatcher coverage extension)
- `tests/Tiny11.Worker.Tests.ps1` (pipeline call verification)
- `tests/Tiny11.Core.Tests.ps1` (SetupComplete output extension)
- `tests/Tiny11.ScriptEncoding.Tests.ps1` (no code changes; new files auto-included by walker)
- `tests/BuildHandlersTests.cs` (payload + wrapper invocation)
- `tests/BridgeMessageContractTests.cs` (contract allowlist)
- `CHANGELOG.md`
- `README.md` (document feature + known CDM limitation)

## Scope estimate

| Phase | Estimate |
|---|---|
| `Tiny11.PostBoot.psm1` module + per-action emitters | ~1 day |
| Worker pipeline integration + Core extension | ~0.5 day |
| UI checkbox + payload + wrapper plumbing | ~0.5 day |
| Pester + xUnit tests | ~0.5 day |
| Manual VM smoke matrix (P1-P5 + P7) | ~0.5 day |
| Real CU-cycle observation (P6 + P8) | ~0.5 day |
| Documentation + CHANGELOG + release | ~0.5 day |
| **Total** | **~3-3.5 days** |

Matches the breadcrumb's "~3 days" estimate.
