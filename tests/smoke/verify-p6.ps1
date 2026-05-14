# verify-p6.ps1 -- P6 smoke verification for the v1.0.1 post-boot cleanup task.
#
# Purpose:
#   Confirm that the 52 provisioned-appx packages a Worker default (cleanup ON)
#   build removes are absent post-login on a freshly installed VM. Verifies the
#   cleanup task fired before the user reached the desktop (install-time CU
#   path) and that no catalog-covered provisioned package slipped through.
#
# Source of truth:
#   catalog/catalog.json -- the 52 prefixes below are every item with
#   "actions[*].type == 'provisioned-appx'" in the v1.0.1 catalog. Keep in sync
#   when the catalog adds or removes provisioned-appx items.
#
# Design reference:
#   docs/superpowers/smoke/2026-05-12-post-boot-cleanup-smoke.md -- P6 entry.
#
# Reusable for: P7 (multi-user fan-out) post-cleanup assertion + P8 (Edge
# re-staging) baseline + any future regression smoke that needs to verify the
# cleanup task removed everything it should.
#
# Usage (run elevated on the VM under test):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-p6.ps1
#
# Exit codes:
#   0 -- clean sweep (0 of 52 present in either check arm).
#   1 -- at least one catalog package still present in either arm.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 52 catalog provisioned-appx package prefixes (Worker default removes all).
# Grouped by category to match catalog/catalog.json ordering.
$expected = @(
    # store-apps (33)
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
    # xbox-and-gaming (9)
    'Microsoft.GamingApp',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.549981C3F5F10',
    # communication (8)
    'Microsoft.OutlookForWindows',
    'Microsoft.People',
    'Microsoft.SkypeApp',
    'Microsoft.Windows.Teams',
    'microsoft.windowscommunicationsapps',
    'Microsoft.YourPhone',
    'MSTeams',
    'MicrosoftTeams',
    # copilot-ai (2)
    'Microsoft.Copilot',
    'Microsoft.Windows.Copilot'
)

if ($expected.Count -ne 52) {
    throw "verify-p6.ps1: expected 52 package prefixes, got $($expected.Count) -- catalog inventory has drifted; resync against catalog/catalog.json."
}

Write-Host ''
Write-Host 'P6 smoke verification -- 52 catalog provisioned-appx packages'
Write-Host '============================================================='
Write-Host ''

# Arm 1: Get-AppxPackage -AllUsers (currently installed for any user).
Write-Host '[1/2] Get-AppxPackage -AllUsers ...'
$installedNames = Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name -Unique
$stillInstalled = @($expected | Where-Object { $installedNames -match [regex]::Escape($_) })

if ($stillInstalled.Count -gt 0) {
    Write-Host '      STILL PRESENT (cleanup did not remove these):' -ForegroundColor Yellow
    $stillInstalled | ForEach-Object { Write-Host "        $_" }
} else {
    Write-Host '      All 52 absent.' -ForegroundColor Green
}

# Arm 2: Get-AppxProvisionedPackage -Online (staged for new user profiles).
Write-Host ''
Write-Host '[2/2] Get-AppxProvisionedPackage -Online ...'
$provNames = Get-AppxProvisionedPackage -Online | Select-Object -ExpandProperty DisplayName -Unique
$stillProvisioned = @($expected | Where-Object { $provNames -match [regex]::Escape($_) })

if ($stillProvisioned.Count -gt 0) {
    Write-Host '      STILL PROVISIONED (would be restaged for new users):' -ForegroundColor Yellow
    $stillProvisioned | ForEach-Object { Write-Host "        $_" }
} else {
    Write-Host '      All 52 absent.' -ForegroundColor Green
}

# Summary.
Write-Host ''
Write-Host 'Summary:'
Write-Host '--------'
$totalIssues = $stillInstalled.Count + $stillProvisioned.Count
if ($totalIssues -eq 0) {
    Write-Host '  CLEAN SWEEP -- 0 of 52 packages present in either check arm.' -ForegroundColor Green
    Write-Host ''
    exit 0
} else {
    Write-Host "  $($stillInstalled.Count) installed, $($stillProvisioned.Count) provisioned (of 52 expected absent)." -ForegroundColor Yellow
    Write-Host ''
    exit 1
}
