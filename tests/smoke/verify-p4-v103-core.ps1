$out = 'C:\Temp\v103-p4-verify.txt'
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

Section 'Test 1: Core mode installs TWO scheduled tasks' 'Expected: Keep WU Disabled + Post-Boot Cleanup, both Ready'
Cmd 'Get-ScheduledTask tiny11options' { Get-ScheduledTask -TaskPath '\tiny11options\' | Format-Table -AutoSize TaskName, State }

Section 'Test 2: Windows Update service disabled' 'Expected: Status=Stopped, StartType=Disabled'
Cmd 'Get-Service wuauserv' { Get-Service wuauserv | Format-List Name, Status, StartType }

Section 'Test 3: SetupComplete.cmd self-deleted after first-boot task registration' 'Expected: False (self-delete via `del /F /Q "%~f0"` in PostBoot.psm1:488 fires after task registration; presence of both tasks per Test 1 proves SetupComplete.cmd ran successfully before deleting itself)'
Cmd 'Test-Path SetupComplete.cmd (should be False)' { Test-Path 'C:\Windows\Setup\Scripts\SetupComplete.cmd' }

Section 'Test 4: 4 new v1.0.3 catalog entries present (offline registry writes)' 'Expected: first 3 = 0x0, AutoDownload = 0x2'
Cmd 'RotatingLockScreenEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v RotatingLockScreenEnabled }
Cmd 'RotatingLockScreenOverlayEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v RotatingLockScreenOverlayEnabled }
Cmd 'SlideshowEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v SlideshowEnabled }
Cmd 'WindowsStore AutoDownload' { reg query 'HKLM\Software\Policies\Microsoft\WindowsStore' /v AutoDownload }

Section 'Test 5: Generated cleanup script contains pattern-zero call + 4 new entries' 'Expected: 1 pattern-zero call line, 1 each for the 4 new entries'
Cmd 'pattern-zero call' { Select-String -Pattern 'Set-RegistryValuePatternToZeroForAllUsers.*RelativeKeyPath' -Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1' | ForEach-Object { "Line $($_.LineNumber): $($_.Line.Trim())" } }
Cmd '4 new CDM/store entries' { Select-String -Pattern 'RotatingLockScreenEnabled|RotatingLockScreenOverlayEnabled|SlideshowEnabled|AutoDownload' -Path 'C:\Windows\Setup\Scripts\tiny11-cleanup.ps1' | Where-Object { $_.Line -notmatch '^# ' } | ForEach-Object { "Line $($_.LineNumber): $($_.Line.Trim())" } }

Section 'Test 6: Edge filesystem removal permanent' 'Expected: False'
Cmd 'Test-Path msedge.exe' { Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }

Section 'Test 7: A11-I3-S2 (Core SetupComplete path) -- pattern-zero zeros a fabricated value' 'Expected: 0x0 after task fires'
Cmd 'Plant SubscribedContent-FAKE99Enabled = 1' { reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' /t REG_DWORD /d 1 /f }
Cmd 'Pre-trigger value' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' }
Cmd 'Trigger Post-Boot Cleanup task' { Start-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup' }
Add-Content -LiteralPath $out -Value '> Wait 15 seconds for task to complete ...'
Start-Sleep -Seconds 15
Cmd 'Post-trigger value (should be 0x0)' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' }
Cmd 'Cleanup-log entry for the fabricated value' { Select-String -Pattern 'SubscribedContent-FAKE99Enabled' -Path 'C:\Windows\Logs\tiny11-cleanup.log' | Select-Object -Last 3 | ForEach-Object { $_.Line } }

Section 'Test 8: PROOF OF FIX -- offline catalog write happened (NOT just runtime correction)' 'Expected: cleanup-log lines for the 4 new entries say `already`, NOT `CORRECTED: 1 -> 0`. If they say CORRECTED, the offline build did not write them and we are still relying on the post-boot cleanup task as the sole enforcement mechanism (pre-a91991b behavior).'
Cmd 'cleanup-log entries for 4 new v1.0.3 entries (first SetupComplete-time run)' {
    Select-String -Pattern 'RotatingLockScreenEnabled|RotatingLockScreenOverlayEnabled|SlideshowEnabled|AutoDownload' -Path 'C:\Windows\Logs\tiny11-cleanup.log' |
        Select-Object -First 8 |
        ForEach-Object { $_.Line }
}

Write-Host ''
Write-Host "Done. Output written to $out"
Write-Host "Run: type $out  (or open in Notepad to copy/paste)"
