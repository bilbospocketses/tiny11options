# verify-p8.ps1 -- P8 non-appx action-type coverage on default-apply build.
#
# Purpose:
#   Validates the THREE action types beyond provisioned-appx that P6's appx-only
#   check did not cover, end-to-end on the existing P1d (Worker default + cleanup
#   ON) Hyper-V VM. No fresh build required.
#
# Action types under test:
#   1. filesystem -- Edge folders + OneDriveSetup.exe absent.
#   2. filesystem + takeown-and-remove -- Edge System32 WebView absent.
#   3. registry -- 5 spot-check HKLM values match catalog-expected state.
#   4. scheduled-task removal -- 5 task paths from telemetry category absent.
#
# Plus a cleanup-log tail to confirm the task is actively enforcing (idempotent
# "already" lines for items that were already in the correct state).
#
# Usage (run elevated on the P1d VM):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-p8.ps1
#
# Exit codes:
#   0 -- every assertion holds across all four arms.
#   1 -- at least one assertion failed (with per-arm detail above).

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]

# -----------------------------------------------------------------------------
# ARM 1: filesystem absence (Edge folders + OneDriveSetup.exe)
# -----------------------------------------------------------------------------
$filesystemPaths = @(
    'C:\Program Files (x86)\Microsoft\Edge',
    'C:\Program Files (x86)\Microsoft\EdgeUpdate',
    'C:\Program Files (x86)\Microsoft\EdgeCore',
    'C:\Windows\System32\OneDriveSetup.exe'
)

Write-Host ''
Write-Host 'P8 non-appx action-type coverage'
Write-Host '================================='
Write-Host ''
Write-Host "[1/4] filesystem (op=remove) -- $($filesystemPaths.Count) paths must be ABSENT ..."
foreach ($p in $filesystemPaths) {
    if (Test-Path -LiteralPath $p) {
        Write-Host "      FAIL $p PRESENT (cleanup task did not remove)" -ForegroundColor Red
        $failures.Add("filesystem path '$p' should be absent but is present")
    } else {
        Write-Host "      OK   $p absent" -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# ARM 2: filesystem + takeown-and-remove (Edge System32 WebView)
# -----------------------------------------------------------------------------
$takeownPaths = @(
    'C:\Windows\System32\Microsoft-Edge-Webview'
)

Write-Host ''
Write-Host "[2/4] filesystem (op=takeown-and-remove) -- $($takeownPaths.Count) path(s) must be ABSENT ..."
foreach ($p in $takeownPaths) {
    if (Test-Path -LiteralPath $p) {
        Write-Host "      FAIL $p PRESENT (cleanup task did not takeown+remove)" -ForegroundColor Red
        $failures.Add("takeown path '$p' should be absent but is present")
    } else {
        Write-Host "      OK   $p absent" -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# ARM 3: registry tweaks applied (HKLM spot-checks, 5 values)
# -----------------------------------------------------------------------------
# Each row: KeyPath, ValueName, ExpectedValue, CatalogItemId
$registryChecks = @(
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';        Name = 'AllowTelemetry';              Expected = 0; Item = 'tweak-disable-telemetry' }
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';        Name = 'TurnOffWindowsCopilot';       Expected = 1; Item = 'tweak-disable-copilot' }
    @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE';            Name = 'BypassNRO';                   Expected = 1; Item = 'tweak-bypass-nro' }
    @{ Key = 'HKLM:\SYSTEM\Setup\LabConfig';                                    Name = 'BypassTPMCheck';              Expected = 1; Item = 'tweak-bypass-hardware-checks' }
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';          Name = 'DisableWindowsConsumerFeatures'; Expected = 1; Item = 'tweak-disable-sponsored-apps' }
)

Write-Host ''
Write-Host "[3/4] registry -- $($registryChecks.Count) HKLM spot-checks must match catalog-expected ..."
foreach ($r in $registryChecks) {
    $actual = $null
    try {
        $actual = (Get-ItemProperty -Path $r.Key -Name $r.Name -ErrorAction Stop).$($r.Name)
    } catch {
        Write-Host "      FAIL $($r.Key)!$($r.Name) NOT FOUND (item '$($r.Item)' did not apply)" -ForegroundColor Red
        $failures.Add("registry value '$($r.Key)!$($r.Name)' not found (expected $($r.Expected), item $($r.Item))")
        continue
    }
    if ($actual -eq $r.Expected) {
        Write-Host "      OK   $($r.Key)!$($r.Name) = $actual  (item: $($r.Item))" -ForegroundColor Green
    } else {
        Write-Host "      FAIL $($r.Key)!$($r.Name) = $actual (expected $($r.Expected), item: $($r.Item))" -ForegroundColor Red
        $failures.Add("registry value '$($r.Key)!$($r.Name)' = $actual, expected $($r.Expected)")
    }
}

# -----------------------------------------------------------------------------
# ARM 4: scheduled-task removal (5 task paths absent)
# -----------------------------------------------------------------------------
# Each row: TaskPath (trailing slash matters), optional TaskName for leaf entries.
# Catalog items expect either a full task DELETION (leaf path) or a recursive
# FOLDER deletion (recurse: true). In both cases, Get-ScheduledTask against
# the path should return zero matches.
$scheduledTaskChecks = @(
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser'; Item = 'disable-task-compat-appraiser' }
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater';                Item = 'disable-task-program-data-updater' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = $null;             Item = 'disable-task-ceip (folder recurse)' }
    @{ Path = '\Microsoft\Windows\Chkdsk\';                 Name = 'Proxy';                            Item = 'disable-task-chkdsk-proxy' }
    @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting';                  Item = 'disable-task-werqueue' }
)

Write-Host ''
Write-Host "[4/4] scheduled-task -- $($scheduledTaskChecks.Count) catalog removals must be ABSENT ..."
foreach ($t in $scheduledTaskChecks) {
    # -ErrorAction SilentlyContinue + @() array wrap works uniformly for both
    # the leaf-task and folder-recurse forms: Get-ScheduledTask emits a
    # CimException to the error stream when the task/path is absent, but
    # SilentlyContinue redirects that to $Error and the cmdlet returns nothing.
    # @($null) is an empty array, so .Count == 0 cleanly means "task absent".
    if ($t.Name) {
        $found = @(Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue)
    } else {
        $found = @(Get-ScheduledTask -TaskPath "$($t.Path)*" -ErrorAction SilentlyContinue)
    }

    if ($found.Count -eq 0) {
        $label = if ($t.Name) { "$($t.Path)$($t.Name)" } else { "$($t.Path) (folder)" }
        Write-Host "      OK   $label absent  (item: $($t.Item))" -ForegroundColor Green
    } else {
        $label = if ($t.Name) { "$($t.Path)$($t.Name)" } else { "$($t.Path) (folder, $($found.Count) tasks)" }
        Write-Host "      FAIL $label PRESENT (item: $($t.Item))" -ForegroundColor Red
        $failures.Add("scheduled-task '$label' should be absent but is present (item $($t.Item))")
    }
}

# -----------------------------------------------------------------------------
# Cleanup log tail -- informational, confirms task is actively enforcing
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host 'Cleanup log evidence (last 30 lines, filtered to interesting markers):'
Write-Host '-----------------------------------------------------------------------'
$logPath = 'C:\Windows\Logs\tiny11-cleanup.log'
if (Test-Path -LiteralPath $logPath) {
    Get-Content -LiteralPath $logPath -Tail 200 |
        Select-String -Pattern '==== |REMOVED|CORRECTED|already|FAILED' |
        Select-Object -Last 30 |
        ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "  (log not found at $logPath)" -ForegroundColor Yellow
    $failures.Add("cleanup log not found at $logPath -- task may never have run")
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host 'Summary:'
Write-Host '--------'
if ($failures.Count -eq 0) {
    Write-Host '  PASS -- all four non-appx action types validated end-to-end.' -ForegroundColor Green
    Write-Host "         filesystem ($($filesystemPaths.Count) paths absent), takeown-and-remove ($($takeownPaths.Count) paths absent),"
    Write-Host "         registry ($($registryChecks.Count) HKLM values match), scheduled-task ($($scheduledTaskChecks.Count) catalog removals absent)."
    Write-Host ''
    exit 0
} else {
    Write-Host "  FAIL -- $($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" }
    Write-Host ''
    exit 1
}
