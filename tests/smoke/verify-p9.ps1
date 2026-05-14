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
    )
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
