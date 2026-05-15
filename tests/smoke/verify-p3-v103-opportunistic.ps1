$out = 'C:\Temp\v103-p3-opportunistic.txt'
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

Section 'Test 1: v1.0.3 catalog entries applied at build time' 'Expected: first 3 = 0x0, AutoDownload = 0x2'
Cmd 'RotatingLockScreenEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v RotatingLockScreenEnabled }
Cmd 'RotatingLockScreenOverlayEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v RotatingLockScreenOverlayEnabled }
Cmd 'SlideshowEnabled' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v SlideshowEnabled }
Cmd 'WindowsStore AutoDownload' { reg query 'HKLM\Software\Policies\Microsoft\WindowsStore' /v AutoDownload }

Section 'Test 2: BingNews removed at build (provisioned-appx action path)' 'Expected: empty / no rows'
Cmd 'Get-AppxProvisionedPackage BingNews' { Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like 'Microsoft.BingNews*' | Format-List DisplayName, PackageName }

Section 'Test 3: Edge removed at build (filesystem action path)' 'Expected: False'
Cmd 'Test-Path msedge.exe' { Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }

Section 'Test 4: SubscribedContent-FAKE99 plant survives (negative cleanup test)' 'Expected: STILL 0x1 (no cleanup task to zero it; opposite of A11-I3-S2)'
Cmd 'Plant fabricated value' { reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' /t REG_DWORD /d 1 /f }
Add-Content -LiteralPath $out -Value '> Wait 30 seconds (no task should fire in this window) ...'
Start-Sleep -Seconds 30
Cmd 'Re-query after 30s wait' { reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SubscribedContent-FAKE99Enabled' }

Write-Host ''
Write-Host "Done. Output written to $out"
Write-Host "Run: type $out  (or open in Notepad to copy/paste)"
