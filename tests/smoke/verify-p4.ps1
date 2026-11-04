$out = 'C:\Temp\p4-verify.txt'
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

Section 'Test 4: 4 catalog entries present (offline registry writes)' 'Expected: first 3 = 0x0, AutoDownload = 0x2'
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
# LastRunTime is whole seconds: back the mark off 1s so this run's own start time counts.
$triggeredAt = (Get-Date).AddSeconds(-1)
Cmd 'Trigger Post-Boot Cleanup task' { Start-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup' }
# Wait for the task to actually finish (deterministic) instead of a fixed sleep:
# poll until THIS run has started (LastRunTime) and left Running/Queued, then a
# short settle. Removes the race where a slow pattern-zero pass hadn't completed
# within a hard-coded sleep, and the one where a late-starting task read as
# already finished. A run that never finishes is reported as HUNG, not as a
# wrong value.
# Guard past the task's own 30-min ExecutionTimeLimit (src/Tiny11.PostBoot.psm1), so a
# slow-but-correct run is never reported as HUNG: the scheduler stops a stuck run first.
$triggerTimeoutSeconds = 1860
Add-Content -LiteralPath $out -Value "> Waiting for Post-Boot Cleanup to complete (up to ${triggerTimeoutSeconds}s) ..."
$deadline = (Get-Date).AddSeconds($triggerTimeoutSeconds)
do {
    Start-Sleep -Seconds 3
    # LastRunTime first, then State: a launch between the two reads can then only
    # pair an OLD LastRunTime with Running (not done), never a fresh one with a stale Ready.
    $taskInfo  = Get-ScheduledTaskInfo -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup' -ErrorAction SilentlyContinue
    $taskState = (Get-ScheduledTask -TaskPath '\tiny11options\' -TaskName 'Post-Boot Cleanup' -ErrorAction SilentlyContinue).State
    $taskDone  = $taskInfo -and $taskInfo.LastRunTime -ge $triggeredAt -and $null -ne $taskState -and $taskState -ne 'Running' -and $taskState -ne 'Queued'
} while (-not $taskDone -and $taskState -ne 'Disabled' -and (Get-Date) -lt $deadline)   # a Disabled task never runs: stop waiting
if ($taskDone) {
    Add-Content -LiteralPath $out -Value "  (task state after wait: $taskState)"
} else {
    Add-Content -LiteralPath $out -Value "  HUNG: Post-Boot Cleanup did not finish its triggered run (waited up to ${triggerTimeoutSeconds}s on Get-ScheduledTask State / Get-ScheduledTaskInfo LastRunTime; last state=$taskState). The post-trigger value below is NOT a valid result."
}
Start-Sleep -Seconds 2
Cmd 'Post-trigger value (should be 0x0)' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' }
Cmd 'Cleanup-log entry for the fabricated value' { Select-String -Pattern 'SubscribedContent-FAKE99Enabled' -Path 'C:\Windows\Logs\tiny11-cleanup.log' | Select-Object -Last 3 | ForEach-Object { $_.Line } }

Section 'Test 8: PROOF OF FIX -- offline catalog write happened (NOT just runtime correction)' 'Expected: cleanup-log lines for the 4 new entries say `already`, NOT `CORRECTED: 1 -> 0`. If they say CORRECTED, the offline build did not write them and we are still relying on the post-boot cleanup task as the sole enforcement mechanism (pre-a91991b behavior).'
Cmd 'cleanup-log entries for the 4 catalog entries (first SetupComplete-time run)' {
    Select-String -Pattern 'RotatingLockScreenEnabled|RotatingLockScreenOverlayEnabled|SlideshowEnabled|AutoDownload' -Path 'C:\Windows\Logs\tiny11-cleanup.log' |
        Select-Object -First 8 |
        ForEach-Object { $_.Line }
}

Write-Host ''
Write-Host "Done. Output written to $out"
Write-Host "Run: type $out  (or open in Notepad to copy/paste)"
