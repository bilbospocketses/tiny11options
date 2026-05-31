# verify-p8.ps1 -- P8 non-appx action-type coverage (self-configuring).
#
# Purpose:
#   Validates the THREE action types beyond provisioned-appx that P6's appx-only
#   check did not cover: filesystem remove, filesystem takeown-and-remove,
#   registry tweaks, and scheduled-task removal.
#
# SELF-CONFIGURING -- no keep-list flags. The test reads the build's OWN baked
#   cleanup script (C:\Windows\Setup\Scripts\tiny11-cleanup.ps1) to learn what
#   THIS image removes vs keeps, then asserts the matching on-disk state. The
#   generator (New-Tiny11PostBootCleanupScript) emits an action ONLY for
#   apply-state (non-kept) catalog items, so:
#       signature present in baked script  => item was REMOVED  => assert ABSENT
#       signature absent  from baked script => item was KEPT     => assert PRESENT
#   (This is the same baked-script artifact P9-static trusts.) Run it bare on ANY
#   build -- default-apply OR keep-list -- and it adapts: a kept Edge is asserted
#   PRESENT, never failed; OneDrive (removed on these builds) is asserted ABSENT.
#
# Usage (run elevated on the VM under test):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-p8.ps1
#
# Exit codes:
#   0 -- every assertion holds across all four arms.
#   1 -- at least one assertion failed (with per-arm detail above).

[CmdletBinding()]
param(
    # The build's baked cleanup script -- the authoritative record of what this
    # image removes (apply-state items appear) vs keeps (skip-state items are
    # omitted). Present on cleanup-ON builds; P8 is one.
    [string] $CleanupScriptPath = 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1'
)

$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]

# --- Load the build's intent from its baked cleanup script -------------------
$script:CleanupText = $null
if (Test-Path -LiteralPath $CleanupScriptPath) {
    $script:CleanupText = Get-Content -LiteralPath $CleanupScriptPath -Raw
}

function Test-EmittedByBuild {
    # TRUE  -> the item's action signature is baked into the cleanup script, i.e.
    #          the build APPLIED it (removed a path/appx/task, set a tweak).
    # FALSE -> absent from the script => the item was KEPT (skip-state, omitted by
    #          the generator).
    # The signature is matched as a COMPLETE token (followed by the closing quote
    # the generator emits -- a double-quote for $env:-expanded paths, a single
    # quote for names/relpaths/Description comments) so e.g. '...\Edge' is not a
    # false hit inside '...\EdgeUpdate', and 'Microsoft Edge' not inside
    # 'Microsoft Edge Update'.
    # No cleanup script (cleanup-OFF build) => cannot self-derive => fall back to
    # the default-apply assumption (TRUE = removed) and warn up front.
    param([Parameter(Mandatory)][string] $Signature)
    if ($null -eq $script:CleanupText) { return $true }
    $t = $script:CleanupText
    return ($t.IndexOf($Signature + '"', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
           ($t.IndexOf($Signature + "'", [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Assert-PathState {
    # Derive remove-vs-keep from the build, then assert the matching disk state.
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Signature)
    $removed = Test-EmittedByBuild -Signature $Signature
    $present = Test-Path -LiteralPath $Path
    if ($removed) {
        if ($present) {
            Write-Host "      FAIL $Path PRESENT (build removes it; cleanup did not)" -ForegroundColor Red
            $failures.Add("removed path '$Path' should be absent but is present")
        } else {
            Write-Host "      OK   $Path absent (removed-by-build)" -ForegroundColor Green
        }
    } else {
        if ($present) {
            Write-Host "      KEEP $Path PRESENT (kept-by-build, expected)" -ForegroundColor Cyan
        } else {
            Write-Host "      FAIL $Path MISSING (kept-by-build but absent -- over-removed)" -ForegroundColor Red
            $failures.Add("kept path '$Path' should be present but is absent")
        }
    }
}

Write-Host ''
Write-Host 'P8 non-appx action-type coverage (self-configuring)'
Write-Host '==================================================='
if ($null -eq $script:CleanupText) {
    Write-Host "WARNING: no baked cleanup script at $CleanupScriptPath -- cannot self-derive" -ForegroundColor Yellow
    Write-Host "         keep-vs-remove. Falling back to default-apply (all items REMOVED)." -ForegroundColor Yellow
    Write-Host "         (This test targets cleanup-ON builds; P3/P5 cover cleanup-OFF.)" -ForegroundColor Yellow
} else {
    Write-Host "Build intent derived from: $CleanupScriptPath ($($script:CleanupText.Length) bytes)"
}
Write-Host ''

# -----------------------------------------------------------------------------
# ARM 1: filesystem (op=remove) -- Edge browser folders + OneDrive setup binary.
# -----------------------------------------------------------------------------
$filesystemPaths = @(
    @{ Path = 'C:\Program Files (x86)\Microsoft\Edge';       Sig = 'Program Files (x86)\Microsoft\Edge' }
    @{ Path = 'C:\Program Files (x86)\Microsoft\EdgeUpdate'; Sig = 'Program Files (x86)\Microsoft\EdgeUpdate' }
    @{ Path = 'C:\Program Files (x86)\Microsoft\EdgeCore';   Sig = 'Program Files (x86)\Microsoft\EdgeCore' }
    @{ Path = 'C:\Windows\System32\OneDriveSetup.exe';       Sig = 'Windows\System32\OneDriveSetup.exe' }
)

Write-Host "[1/4] filesystem -- $($filesystemPaths.Count) paths (expectation derived from build) ..."
foreach ($e in $filesystemPaths) { Assert-PathState -Path $e.Path -Signature $e.Sig }

# -----------------------------------------------------------------------------
# ARM 2: filesystem + takeown-and-remove -- Edge System32 WebView host.
# -----------------------------------------------------------------------------
$takeownPaths = @(
    @{ Path = 'C:\Windows\System32\Microsoft-Edge-Webview'; Sig = 'Windows\System32\Microsoft-Edge-Webview' }
)

Write-Host ''
Write-Host "[2/4] filesystem (takeown-and-remove) -- $($takeownPaths.Count) path(s) ..."
foreach ($e in $takeownPaths) { Assert-PathState -Path $e.Path -Signature $e.Sig }

# -----------------------------------------------------------------------------
# ARM 3: registry tweaks (HKLM spot-checks). Asserted only when the build applied
# the tweak (signature present); a kept/skipped tweak is reported SKIP, not failed.
# -----------------------------------------------------------------------------
$registryChecks = @(
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';        Name = 'AllowTelemetry';                 Expected = 0; Item = 'tweak-disable-telemetry' }
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';        Name = 'TurnOffWindowsCopilot';          Expected = 1; Item = 'tweak-disable-copilot' }
    @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE';            Name = 'BypassNRO';                      Expected = 1; Item = 'tweak-bypass-nro' }
    @{ Key = 'HKLM:\SYSTEM\Setup\LabConfig';                                    Name = 'BypassTPMCheck';                 Expected = 1; Item = 'tweak-bypass-hardware-checks' }
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';          Name = 'DisableWindowsConsumerFeatures'; Expected = 1; Item = 'tweak-disable-sponsored-apps' }
)

Write-Host ''
Write-Host "[3/4] registry -- $($registryChecks.Count) HKLM tweaks (assert value when applied) ..."
foreach ($r in $registryChecks) {
    if (-not (Test-EmittedByBuild -Signature $r.Name)) {
        Write-Host "      SKIP $($r.Key)!$($r.Name) (kept-by-build; tweak not applied)" -ForegroundColor Cyan
        continue
    }
    $actual = $null
    try {
        $actual = (Get-ItemProperty -Path $r.Key -Name $r.Name -ErrorAction Stop).$($r.Name)
    } catch {
        Write-Host "      FAIL $($r.Key)!$($r.Name) NOT FOUND (item '$($r.Item)' applied but value missing)" -ForegroundColor Red
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
# ARM 4: scheduled-task removal. Removed-by-build => absent; kept-by-build => present.
# -----------------------------------------------------------------------------
$scheduledTaskChecks = @(
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser'; Item = 'disable-task-compat-appraiser' }
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater';                Item = 'disable-task-program-data-updater' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = $null;             Item = 'disable-task-ceip (folder recurse)' }
    @{ Path = '\Microsoft\Windows\Chkdsk\';                 Name = 'Proxy';                            Item = 'disable-task-chkdsk-proxy' }
    @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting';                  Item = 'disable-task-werqueue' }
)

Write-Host ''
Write-Host "[4/4] scheduled-task -- $($scheduledTaskChecks.Count) catalog tasks (expectation derived) ..."
foreach ($t in $scheduledTaskChecks) {
    # Catalog relpath signature -- matches the generator's Description comment
    # (e.g. "Unregister scheduled task 'Microsoft\Windows\...\<leaf>'").
    $rel = ($t.Path).Trim('\')
    if ($t.Name) { $rel = "$rel\$($t.Name)" }
    $removed = Test-EmittedByBuild -Signature $rel

    if ($t.Name) {
        $found = @(Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue)
    } else {
        $found = @(Get-ScheduledTask -TaskPath "$($t.Path)*" -ErrorAction SilentlyContinue)
    }
    $label = if ($t.Name) { "$($t.Path)$($t.Name)" } else { "$($t.Path) (folder)" }

    if ($removed) {
        if ($found.Count -eq 0) {
            Write-Host "      OK   $label absent (removed-by-build, item: $($t.Item))" -ForegroundColor Green
        } else {
            Write-Host "      FAIL $label PRESENT (build removes it; item: $($t.Item))" -ForegroundColor Red
            $failures.Add("scheduled-task '$label' should be absent but is present (item $($t.Item))")
        }
    } else {
        if ($found.Count -gt 0) {
            Write-Host "      KEEP $label present (kept-by-build, item: $($t.Item))" -ForegroundColor Cyan
        } else {
            Write-Host "      FAIL $label ABSENT (kept-by-build but missing; item: $($t.Item))" -ForegroundColor Red
            $failures.Add("kept scheduled-task '$label' should be present but is absent (item $($t.Item))")
        }
    }
}

# -----------------------------------------------------------------------------
# Cleanup log tail -- informational, confirms the task is actively enforcing.
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
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host 'Summary:'
Write-Host '--------'
if ($failures.Count -eq 0) {
    Write-Host '  PASS -- all four non-appx action types validated end-to-end against the' -ForegroundColor Green
    Write-Host "         build's own baked cleanup script (remove-vs-keep self-derived)." -ForegroundColor Green
    Write-Host ''
    exit 0
} else {
    Write-Host "  FAIL -- $($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" }
    Write-Host ''
    exit 1
}
