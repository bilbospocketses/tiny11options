# verify-p9.ps1 -- P9 keep-list smoke verification (runtime arm).
#
# Purpose:
#   Validate the cleanup-task keep-list contract end-to-end on a freshly
#   installed VM. Asserts that items the user chose to KEEP at build time are
#   actually present post-install AND that the items they chose to REMOVE are
#   actually absent. Catches wire-up bugs between UI -> wrapper -> generator
#   that would silently ship a "removes everything regardless of selections"
#   build.
#
# Default parameter values match the P9 build profile
# (C:\Temp\p9-keep-edge-clipchamp.json): Clipchamp + Edge + Edge WebView +
# Edge uninstall registry keys all KEPT. Override with -KeptAppx /
# -KeptPaths / -KeptRegistryKeys for future keep-list smokes.
#
# Source of truth for the "must be absent" list:
#   catalog/catalog.json -- the 52 prefixes that match tests/smoke/verify-p6.ps1,
#   minus any prefixes in -KeptAppx (so the partition is exhaustive).
#
# Usage (run elevated on the VM under test):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-p9.ps1
#
# Exit codes:
#   0 -- every kept item PRESENT and every non-kept catalog item ABSENT.
#   1 -- at least one assertion failed (kept item missing OR removed item still present).

[CmdletBinding()]
param(
    [string[]] $KeptAppx = @(
        'Clipchamp.Clipchamp'
    ),
    [string[]] $KeptPaths = @(
        'C:\Program Files (x86)\Microsoft\Edge',
        'C:\Program Files (x86)\Microsoft\EdgeUpdate',
        'C:\Program Files (x86)\Microsoft\EdgeCore',
        'C:\Windows\System32\Microsoft-Edge-Webview'
    ),
    [string[]] $KeptRegistryKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
    ),

    # Re-stagers (notably Microsoft.Copilot) get re-provisioned by Windows after
    # the first-boot cleanup, so a snapshot taken in that window shows them back.
    # By default this drives the Post-Boot Cleanup task to completion FIRST, so
    # the absence assertions (Arm 4) reflect the post-enforcement steady state.
    # Pass -NoTriggerCleanup to assert the current state without re-running it.
    [switch] $NoTriggerCleanup,
    [string] $TaskPath = '\tiny11options\',
    [string] $TaskName = 'Post-Boot Cleanup',
    [int]    $TriggerTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

# Full 52-prefix catalog inventory (same as verify-p6.ps1).
$catalogAppx = @(
    'AppUp.IntelManagementandSecurityStatus',
    'Clipchamp.Clipchamp',
    'DolbyLaboratories.DolbyAccess',
    'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
    'Microsoft.BingNews',
    'Microsoft.BingSearch',
    'Microsoft.BingWeather',
    'Microsoft.Windows.CrossDevice',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.MixedReality.Portal',
    'Microsoft.MSPaint',
    'Microsoft.Office.OneNote',
    'Microsoft.OfficePushNotificationUtility',
    'Microsoft.Paint',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.StartExperiencesApp',
    'Microsoft.Todos',
    'Microsoft.Wallet',
    'Microsoft.Windows.DevHome',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.WindowsTerminal',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'Microsoft.GamingApp',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.549981C3F5F10',
    'Microsoft.OutlookForWindows',
    'Microsoft.People',
    'Microsoft.SkypeApp',
    'Microsoft.Windows.Teams',
    'microsoft.windowscommunicationsapps',
    'Microsoft.YourPhone',
    'MSTeams',
    'MicrosoftTeams',
    'Microsoft.Copilot',
    'Microsoft.Windows.Copilot'
)

if ($catalogAppx.Count -ne 52) {
    throw "verify-p9.ps1: expected 52 catalog appx prefixes, got $($catalogAppx.Count) -- inventory drifted, resync against catalog/catalog.json."
}

# Partition: anything in KeptAppx must be PRESENT; everything else in catalogAppx must be ABSENT.
$expectedAbsent = @($catalogAppx | Where-Object { $KeptAppx -notcontains $_ })

Write-Host ''
Write-Host 'P9 keep-list smoke verification'
Write-Host '================================'
Write-Host "Kept appx:       $($KeptAppx.Count)"
Write-Host "Kept paths:      $($KeptPaths.Count)"
Write-Host "Kept reg keys:   $($KeptRegistryKeys.Count)"
Write-Host "Expected absent: $($expectedAbsent.Count) (of $($catalogAppx.Count) catalog items)"
Write-Host ''

$failures = New-Object System.Collections.Generic.List[string]

# --- Pre-step: drive the cleanup task to completion (re-stager steady state) ---
# Microsoft.Copilot (and friends) re-provision after first boot; the snapshot
# below must be taken AFTER the enforcer runs, or a re-staged package reads as a
# removal failure. Trigger + wait-for-completion, then snapshot.
if (-not $NoTriggerCleanup) {
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "NOTE: task '$TaskPath$TaskName' not found -- asserting current state without a cleanup trigger." -ForegroundColor Yellow
    } else {
        Write-Host "Triggering '$TaskName' and waiting for completion (re-stager steady state) ..."
        Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
        Start-Sleep -Seconds 2
        $deadline = (Get-Date).AddSeconds($TriggerTimeoutSeconds)
        do {
            Start-Sleep -Seconds 3
            $state = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
        $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        $lr   = if ($info) { '0x{0:x}' -f [int]$info.LastTaskResult } else { 'n/a' }
        Write-Host "  task state=$state lastResult=$lr"
        Start-Sleep -Seconds 3   # settle: let deprovision changes surface to Get-AppxProvisionedPackage
        Write-Host ''
    }
}

# --- ARM 1: kept appx MUST be present ---
Write-Host '[1/4] Kept appx must be PRESENT ...'
$installedNames = Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name -Unique
$provNames      = Get-AppxProvisionedPackage -Online | Select-Object -ExpandProperty DisplayName -Unique
foreach ($prefix in $KeptAppx) {
    $inInstalled = $installedNames -match [regex]::Escape($prefix)
    $inProvisioned = $provNames -match [regex]::Escape($prefix)
    if ($inInstalled -and $inProvisioned) {
        Write-Host "      OK   $prefix (installed + provisioned)" -ForegroundColor Green
    } elseif ($inInstalled -or $inProvisioned) {
        Write-Host "      WARN $prefix (only $(if($inInstalled){'installed'}else{'provisioned'}); other half MISSING)" -ForegroundColor Yellow
        $failures.Add("kept appx '$prefix' present in only one of (installed, provisioned)")
    } else {
        Write-Host "      FAIL $prefix MISSING from both installed AND provisioned" -ForegroundColor Red
        $failures.Add("kept appx '$prefix' MISSING (cleanup task removed it despite skip)")
    }
}

# --- ARM 2: kept filesystem paths MUST be present ---
Write-Host ''
Write-Host '[2/4] Kept filesystem paths must be PRESENT ...'
foreach ($p in $KeptPaths) {
    if (Test-Path -LiteralPath $p) {
        Write-Host "      OK   $p" -ForegroundColor Green
    } else {
        Write-Host "      FAIL $p MISSING" -ForegroundColor Red
        $failures.Add("kept path '$p' MISSING")
    }
}

# --- ARM 3: kept registry keys MUST be present ---
Write-Host ''
Write-Host '[3/4] Kept registry keys must be PRESENT ...'
foreach ($k in $KeptRegistryKeys) {
    if (Test-Path -LiteralPath $k) {
        Write-Host "      OK   $k" -ForegroundColor Green
    } else {
        Write-Host "      FAIL $k MISSING" -ForegroundColor Red
        $failures.Add("kept registry key '$k' MISSING")
    }
}

# --- ARM 4: removed appx MUST be absent ---
Write-Host ''
Write-Host "[4/4] $($expectedAbsent.Count) non-kept catalog appx items must be ABSENT ..."
$stillInstalled = @($expectedAbsent | Where-Object { $installedNames -match [regex]::Escape($_) })
$stillProvisioned = @($expectedAbsent | Where-Object { $provNames -match [regex]::Escape($_) })

if ($stillInstalled.Count -eq 0) {
    Write-Host '      OK   0 of expected-absent present in installed.' -ForegroundColor Green
} else {
    Write-Host "      FAIL $($stillInstalled.Count) still installed (cleanup did not remove these):" -ForegroundColor Red
    $stillInstalled | ForEach-Object {
        Write-Host "             $_"
        $failures.Add("expected-absent appx '$_' still installed")
    }
}

if ($stillProvisioned.Count -eq 0) {
    Write-Host '      OK   0 of expected-absent present in provisioned.' -ForegroundColor Green
} else {
    Write-Host "      FAIL $($stillProvisioned.Count) still provisioned:" -ForegroundColor Red
    $stillProvisioned | ForEach-Object {
        Write-Host "             $_"
        $failures.Add("expected-absent appx '$_' still provisioned")
    }
}

# --- Summary ---
Write-Host ''
Write-Host 'Summary:'
Write-Host '--------'
if ($failures.Count -eq 0) {
    Write-Host '  PASS -- keep-list contract holds end-to-end.' -ForegroundColor Green
    Write-Host "         $($KeptAppx.Count) kept appx PRESENT, $($KeptPaths.Count) kept paths PRESENT, $($KeptRegistryKeys.Count) kept reg keys PRESENT."
    Write-Host "         $($expectedAbsent.Count) non-kept catalog appx ABSENT (in both installed and provisioned)."
    Write-Host ''
    exit 0
} else {
    Write-Host "  FAIL -- $($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" }
    Write-Host ''
    exit 1
}
