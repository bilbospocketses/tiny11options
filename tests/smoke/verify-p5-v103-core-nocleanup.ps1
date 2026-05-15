$out = 'C:\Temp\v103-p5-verify.txt'
Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue

function Section($name, $expected) {
    Add-Content -LiteralPath $out -Value ''
    Add-Content -LiteralPath $out -Value "=== $name ==="
    Add-Content -LiteralPath $out -Value "--- $expected ---"
    Add-Content -LiteralPath $out -Value ''
}

function Cmd($label, $scriptBlock) {
    Add-Content -LiteralPath $out -Value "> $label"
    $result = & $scriptBlock 2>&1
    if ($null -ne $result -and ($result | Measure-Object).Count -gt 0) {
        $result | Out-String -Stream | ForEach-Object { Add-Content -LiteralPath $out -Value $_ }
    } else {
        Add-Content -LiteralPath $out -Value '(empty result)'
    }
    Add-Content -LiteralPath $out -Value ''
}

Section 'Test 1: Core + -NoPostBootCleanup installs ONLY the Keep WU Disabled task' 'Expected: ONE row only, TaskName=Keep WU Disabled, State=Ready (no Post-Boot Cleanup task)'
Cmd 'Get-ScheduledTask tiny11options' { Get-ScheduledTask -TaskPath '\tiny11options\' | Format-Table -AutoSize TaskName, State }

Section 'Test 2: Windows Update service still disabled (Core mode unconditionally disables WU)' 'Expected: Status=Stopped, StartType=Disabled (cleanup-toggle does NOT affect WU disable)'
Cmd 'Get-Service wuauserv' { Get-Service wuauserv | Format-List Name, Status, StartType }

Section 'Test 3: SetupComplete.cmd self-deleted after first-boot Keep WU Disabled task registration' 'Expected: False (self-delete via `del /F /Q "%~f0"` in PostBoot.psm1:488 fires after task registration; presence of Keep WU Disabled task per Test 1 proves SetupComplete.cmd ran successfully before deleting itself; Core writes only ONE schtasks /create line in this mode for Keep WU Disabled, no Post-Boot Cleanup line)'
Cmd 'Test-Path SetupComplete.cmd (should be False)' { Test-Path 'C:\Windows\Setup\Scripts\SetupComplete.cmd' }

Section 'Test 4: cleanup script artifacts ABSENT (no Post-Boot Cleanup task means no script either)' 'Expected: both False'
Cmd 'Test-Path tiny11-cleanup.ps1' { Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1' }
Cmd 'Test-Path tiny11-cleanup.xml' { Test-Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.xml' }

Section 'Test 5: 4 new v1.0.3 catalog entries STILL applied at build time (proves -NoPostBootCleanup only affects runtime task, not offline build writes)' 'Expected: first 3 = 0x0, AutoDownload = 0x2'
Cmd 'RotatingLockScreenEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v RotatingLockScreenEnabled }
Cmd 'RotatingLockScreenOverlayEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v RotatingLockScreenOverlayEnabled }
Cmd 'SlideshowEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v SlideshowEnabled }
Cmd 'WindowsStore AutoDownload' { reg query 'HKLM\Software\Policies\Microsoft\WindowsStore' /v AutoDownload }

Section 'Test 6: Edge filesystem removal permanent (filesystem path survives without cleanup task; same as P3 Test 3)' 'Expected: False'
Cmd 'Test-Path msedge.exe' { Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }

Section 'Test 7: SubscribedContent-FAKE99 plant SURVIVES (negative cleanup test; opposite of P4 Test 7)' 'Expected: STILL 0x1 after 30s (no Post-Boot Cleanup task to zero it)'
Cmd 'Plant fabricated value' { reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' /t REG_DWORD /d 1 /f }
Add-Content -LiteralPath $out -Value '> Wait 30 seconds (no task should fire) ...'
Start-Sleep -Seconds 30
Cmd 'Re-query (should STILL be 0x1)' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' }

Write-Host ''
Write-Host "Done. Output written to $out"
Write-Host "Run: type $out  (or open in Notepad to copy/paste)"
