# verify-p9.ps1 -- P9 keep-list smoke verification (runtime arm, self-configuring).
#
# Purpose:
#   Validate the cleanup-task keep-list contract end-to-end on a freshly
#   installed VM: items the build KEPT are present post-install, items it
#   REMOVED are absent. Catches wire-up bugs between UI -> wrapper -> generator
#   that would silently ship a "removes everything regardless of selections" build.
#
# SELF-CONFIGURING -- no keep-list flags. The test reads the build's OWN baked
#   cleanup script (C:\Windows\Setup\Scripts\tiny11-cleanup.ps1) to learn what
#   THIS image kept vs removed. The generator emits an action ONLY for apply-state
#   (non-kept) items, so for every catalog item in scope:
#       signature present in baked script  => REMOVED => assert ABSENT
#       signature absent  from baked script => KEPT    => assert PRESENT
#   Run it bare on ANY keep profile and it adapts -- a kept Clipchamp/Edge is
#   asserted PRESENT, the rest asserted ABSENT, with no manual -KeptAppx list.
#
# Scope (the catalog surface this contract covers):
#   - the 52 provisioned-appx prefixes (same inventory as verify-p6.ps1)
#   - the Edge browser/WebView filesystem paths
#   - the Edge uninstall registry keys
#
# Re-stagers (notably Microsoft.Copilot) re-provision after first boot, so by
# default this drives the Post-Boot Cleanup task to completion FIRST, so the
# absence assertions reflect the post-enforcement steady state.
#
# Usage (run elevated on the VM under test):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-p9.ps1
#
# Exit codes:
#   0 -- every kept item PRESENT and every removed item ABSENT.
#   1 -- at least one assertion failed (kept item missing OR removed item present).

[CmdletBinding()]
param(
    # The build's baked cleanup script -- authoritative record of kept vs removed.
    [string] $CleanupScriptPath = 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1',

    # Drive the Post-Boot Cleanup task to completion before asserting, so
    # re-stagers (Microsoft.Copilot et al.) are in their post-enforcement steady
    # state. -NoTriggerCleanup asserts the current state without re-running it.
    [switch] $NoTriggerCleanup,
    [string] $TaskPath = '\tiny11options\',
    [string] $TaskName = 'Post-Boot Cleanup',
    [int]    $TriggerTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

# --- Load the build's intent from its baked cleanup script -------------------
$script:CleanupText = $null
if (Test-Path -LiteralPath $CleanupScriptPath) {
    $script:CleanupText = Get-Content -LiteralPath $CleanupScriptPath -Raw
}

function Test-EmittedByBuild {
    # TRUE  -> the item's action signature is baked into the cleanup script => the
    #          build APPLIED it (removed the path/appx, set the tweak).
    # FALSE -> absent => the item was KEPT (skip-state, omitted by the generator).
    # Signature matched as a COMPLETE token (followed by the generator's closing
    # quote -- " for $env:-expanded paths, ' for prefixes/keypaths/comments) so
    # '...\Edge' is not a false hit in '...\EdgeUpdate', nor 'Microsoft Edge' in
    # 'Microsoft Edge Update'.
    # No cleanup script (cleanup-OFF build) => cannot self-derive => fall back to
    # default-apply (TRUE = removed) and warn up front.
    param([Parameter(Mandatory)][string] $Signature)
    if ($null -eq $script:CleanupText) { return $true }
    $t = $script:CleanupText
    return ($t.IndexOf($Signature + '"', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
           ($t.IndexOf($Signature + "'", [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Assert-KeptOrRemoved {
    # For a path/registry key: derive remove-vs-keep from the build, assert state.
    param([Parameter(Mandatory)][string] $TestPath, [Parameter(Mandatory)][string] $Signature)
    $removed = Test-EmittedByBuild -Signature $Signature
    $present = Test-Path -LiteralPath $TestPath
    if ($removed) {
        if (-not $present) {
            Write-Host "      OK   $TestPath absent (removed-by-build)" -ForegroundColor Green
        } else {
            Write-Host "      FAIL $TestPath PRESENT (build removes it)" -ForegroundColor Red
            $failures.Add("removed item '$TestPath' should be absent but is present")
        }
    } else {
        if ($present) {
            Write-Host "      OK   $TestPath (kept-by-build)" -ForegroundColor Green
        } else {
            Write-Host "      FAIL $TestPath MISSING (kept-by-build but absent)" -ForegroundColor Red
            $failures.Add("kept item '$TestPath' should be present but is absent")
        }
    }
}

# Full 52-prefix catalog inventory (same as verify-p6.ps1). Drift-guarded below.
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

# Edge filesystem paths + uninstall reg keys (keep-list surface beyond appx).
# Sig = the substring the generator bakes for the REMOVE of that item.
$edgePaths = @(
    @{ Path = 'C:\Program Files (x86)\Microsoft\Edge';       Sig = 'Program Files (x86)\Microsoft\Edge' }
    @{ Path = 'C:\Program Files (x86)\Microsoft\EdgeUpdate'; Sig = 'Program Files (x86)\Microsoft\EdgeUpdate' }
    @{ Path = 'C:\Program Files (x86)\Microsoft\EdgeCore';   Sig = 'Program Files (x86)\Microsoft\EdgeCore' }
    @{ Path = 'C:\Windows\System32\Microsoft-Edge-Webview';  Sig = 'Windows\System32\Microsoft-Edge-Webview' }
)
$edgeRegKeys = @(
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge';        Sig = 'Uninstall\Microsoft Edge' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'; Sig = 'Uninstall\Microsoft Edge Update' }
)

$failures = New-Object System.Collections.Generic.List[string]

# Derive the appx partition from the build.
$keptAppx       = @($catalogAppx | Where-Object { -not (Test-EmittedByBuild -Signature $_) })
$expectedAbsent = @($catalogAppx | Where-Object {      (Test-EmittedByBuild -Signature $_) })

Write-Host ''
Write-Host 'P9 keep-list smoke verification (self-configuring)'
Write-Host '=================================================='
if ($null -eq $script:CleanupText) {
    Write-Host "WARNING: no baked cleanup script at $CleanupScriptPath -- cannot self-derive" -ForegroundColor Yellow
    Write-Host "         keep-vs-remove. Falling back to default-apply (all items REMOVED)." -ForegroundColor Yellow
} else {
    Write-Host "Build intent derived from: $CleanupScriptPath ($($script:CleanupText.Length) bytes)"
}
Write-Host "Kept appx (derived):   $($keptAppx.Count)  [$($keptAppx -join ', ')]"
Write-Host "Removed appx (derived): $($expectedAbsent.Count) (of $($catalogAppx.Count) catalog items)"
Write-Host ''

# --- Pre-step: drive the cleanup task to completion (re-stager steady state) ---
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

# Snapshot appx state once (after the cleanup trigger).
$installedNames = Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name -Unique
$provNames      = Get-AppxProvisionedPackage -Online | Select-Object -ExpandProperty DisplayName -Unique

# --- ARM 1: kept appx MUST be present ---
Write-Host "[1/4] $($keptAppx.Count) kept appx must be PRESENT ..."
if ($keptAppx.Count -eq 0) { Write-Host '      (none kept by this build)' -ForegroundColor DarkGray }
foreach ($prefix in $keptAppx) {
    $inInstalled   = $installedNames -match [regex]::Escape($prefix)
    $inProvisioned = $provNames -match [regex]::Escape($prefix)
    if ($inInstalled -and $inProvisioned) {
        Write-Host "      OK   $prefix (installed + provisioned)" -ForegroundColor Green
    } elseif ($inInstalled -or $inProvisioned) {
        Write-Host "      WARN $prefix (only $(if($inInstalled){'installed'}else{'provisioned'}); other half MISSING)" -ForegroundColor Yellow
        $failures.Add("kept appx '$prefix' present in only one of (installed, provisioned)")
    } else {
        Write-Host "      FAIL $prefix MISSING from both installed AND provisioned" -ForegroundColor Red
        $failures.Add("kept appx '$prefix' MISSING (cleanup removed it despite being kept)")
    }
}

# --- ARM 2: Edge filesystem paths (kept => present, removed => absent) ---
Write-Host ''
Write-Host "[2/4] $($edgePaths.Count) Edge filesystem paths (expectation derived) ..."
foreach ($e in $edgePaths) { Assert-KeptOrRemoved -TestPath $e.Path -Signature $e.Sig }

# --- ARM 3: Edge uninstall registry keys (kept => present, removed => absent) ---
Write-Host ''
Write-Host "[3/4] $($edgeRegKeys.Count) Edge uninstall registry keys (expectation derived) ..."
foreach ($k in $edgeRegKeys) { Assert-KeptOrRemoved -TestPath $k.Path -Signature $k.Sig }

# --- ARM 4: removed appx MUST be absent ---
Write-Host ''
Write-Host "[4/4] $($expectedAbsent.Count) removed catalog appx must be ABSENT ..."
$stillInstalled   = @($expectedAbsent | Where-Object { $installedNames -match [regex]::Escape($_) })
$stillProvisioned = @($expectedAbsent | Where-Object { $provNames -match [regex]::Escape($_) })

if ($stillInstalled.Count -eq 0) {
    Write-Host '      OK   0 of removed-set present in installed.' -ForegroundColor Green
} else {
    Write-Host "      FAIL $($stillInstalled.Count) still installed (cleanup did not remove these):" -ForegroundColor Red
    $stillInstalled | ForEach-Object {
        Write-Host "             $_"
        $failures.Add("removed appx '$_' still installed")
    }
}
if ($stillProvisioned.Count -eq 0) {
    Write-Host '      OK   0 of removed-set present in provisioned.' -ForegroundColor Green
} else {
    Write-Host "      FAIL $($stillProvisioned.Count) still provisioned:" -ForegroundColor Red
    $stillProvisioned | ForEach-Object {
        Write-Host "             $_"
        $failures.Add("removed appx '$_' still provisioned")
    }
}

# --- Summary ---
Write-Host ''
Write-Host 'Summary:'
Write-Host '--------'
if ($failures.Count -eq 0) {
    Write-Host '  PASS -- keep-list contract holds end-to-end (kept vs removed self-derived' -ForegroundColor Green
    Write-Host "         from the build's own baked cleanup script)." -ForegroundColor Green
    Write-Host "         $($keptAppx.Count) kept appx PRESENT; $($expectedAbsent.Count) removed appx ABSENT; Edge paths + reg keys per build." -ForegroundColor Green
    Write-Host ''
    exit 0
} else {
    Write-Host "  FAIL -- $($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" }
    Write-Host ''
    exit 1
}
