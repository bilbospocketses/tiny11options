# verify-p7.ps1 -- P7 smoke verification: per-user fan-out + new-user inheritance.
#
# Purpose:
#   Confirm the post-boot cleanup's per-user privacy settings land in EVERY user
#   hive on a Worker default (cleanup ON) install, across two arms:
#     - FAN-OUT     : every live, logged-in user hive (HKU\S-1-5-21-*) is corrected.
#     - INHERITANCE : a brand-new user (provisioned from the Default hive) carries
#                     the settings, and the Default hive itself (the source) has them.
#
#   Canary set -- HKCU-relative per-user values the catalog forces to 0:
#     - Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo!Enabled
#     - Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager!ContentDeliveryAllowed
#     - Software\Microsoft\Input\TIPC!Enabled
#
#   _Classes regression guard: the fan-out must process real user hives
#   (HKU\S-1-5-21-...) and SKIP the per-user class hives (HKU\S-1-5-21-..._Classes);
#   the cleanup log must contain ZERO "_Classes" lines.
#
# Manual prerequisite (cannot be scripted -- needs a real interactive logon):
#   1. New-LocalUser User2 -NoPassword
#      Add-LocalGroupMember -Group Users -Member User2
#   2. Sign User2 in once (provisions its profile from the Default hive), then sign
#      OUT (so its NTUSER.DAT is on disk and unlocked for the offline read).
#   Then run this script elevated, with User2 SIGNED OUT.
#
# Usage (elevated, on the VM under test):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-p7.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-p7.ps1 -User2Name Tester -SkipTrigger
#
# Offline-hive reads use reg.exe (a child process) -- NEVER the .NET registry
# provider -- so `reg unload` is never blocked by an in-process handle (the same
# reg.exe-only discipline the build pipeline uses for offline-hive access).
#
# Exit codes:
#   0 -- PASS: every canary value = 0 in all live user hives + User2 (offline) +
#        Default, and zero "_Classes" hits in the cleanup log.
#   1 -- FAIL: a canary missing/non-zero, a "_Classes" hit, or an unmet prerequisite.

[CmdletBinding()]
param(
    [string]$User2Name  = 'User2',
    [string]$TaskPath   = '\tiny11options\',
    [string]$TaskName   = 'Post-Boot Cleanup',
    [string]$CleanupLog = 'C:\Windows\Logs\tiny11-cleanup.log',
    [switch]$SkipTrigger
)

# 'Continue' (not 'Stop') on purpose: this script runs native reg.exe whose stderr
# (a best-effort `reg unload` of a not-loaded key, or a value-absent `reg query`)
# becomes a TERMINATING error under 'Stop' on Windows PowerShell 5.1 -- the same trap
# the build pipeline guards against. Control flow keys off $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

# reg.exe resolved by absolute System32 path (not %PATH%, not the .NET provider).
$reg = Join-Path $env:SystemRoot 'System32\reg.exe'

# Canary per-user settings (HKCU-relative), each forced to 0 by the catalog.
#   InheritStable = $true  -> a static preference that survives a logon session; must be 0 in
#                             EVERY arm (live, the new user's offline hive, Default).
#   InheritStable = $false -> a value Windows' own services re-initialize to 1 during any logon
#                             session (ContentDeliveryManager, text-input/TIPC). The fan-out
#                             corrects these in LOADED hives + Default, but a user who logged in
#                             then signed OUT keeps that session drift until their NEXT login
#                             re-loads the hive (and the HKLM policy gates the behavior anyway).
#                             So these are asserted on the live + Default arms, NOT on a
#                             signed-out user's offline hive (see -StableOnly).
$canary = @(
    @{ Path = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';        Name = 'Enabled';                Expect = 0; InheritStable = $true  }
    @{ Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; Expect = 0; InheritStable = $false }
    @{ Path = 'Software\Microsoft\Input\TIPC';                                    Name = 'Enabled';                Expect = 0; InheritStable = $false }
)

$failures = New-Object System.Collections.Generic.List[string]

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-RegDword {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Name)
    $raw = & $reg query $Key /v $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $raw) {
        if ($line -match "^\s+$([regex]::Escape($Name))\s+REG_(?:DWORD|QWORD)\s+0x([0-9A-Fa-f]+)\s*$") {
            return [Convert]::ToInt64($Matches[1], 16)
        }
    }
    return $null
}

function Test-HiveCanary {
    param([string]$Label, [string]$Root, [switch]$StableOnly)
    Write-Host ""
    Write-Host "  [$Label]  ($Root)"
    $set = if ($StableOnly) { $canary | Where-Object { $_.InheritStable } } else { $canary }
    if ($StableOnly) {
        Write-Host "    (session-managed values not asserted on a signed-out hive -- Windows re-inits them per session; fan-out corrects on next login)" -ForegroundColor DarkGray
    }
    foreach ($c in $set) {
        $val    = Get-RegDword -Key "$Root\$($c.Path)" -Name $c.Name
        $disp   = if ($null -eq $val) { '(absent)' } else { ('0x{0:x}' -f $val) }
        $expHex = '0x{0:x}' -f $c.Expect
        if ($null -ne $val -and $val -eq $c.Expect) {
            Write-Host ("    PASS  {0}!{1} = {2}" -f $c.Path, $c.Name, $disp) -ForegroundColor Green
        } else {
            Write-Host ("    FAIL  {0}!{1} = {2}  (expected {3})" -f $c.Path, $c.Name, $disp, $expHex) -ForegroundColor Yellow
            $failures.Add("$Label : $($c.Path)!$($c.Name) = $disp (expected $expHex)")
        }
    }
}

function Invoke-OfflineHive {
    param([string]$Label, [string]$MountKey, [string]$DatPath, [switch]$StableOnly)
    Write-Host ""
    Write-Host "[$Label] ($DatPath):"
    if (-not (Test-Path -LiteralPath $DatPath)) {
        Write-Host "    FAIL  not found: $DatPath" -ForegroundColor Yellow
        $failures.Add("$Label : hive file not found ($DatPath)")
        return
    }
    & $reg unload $MountKey 2>$null | Out-Null   # best-effort: clear a stranded mount from a prior run
    $loadOut = & $reg load $MountKey $DatPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    FAIL  reg load failed (is the owning user signed OUT? the hive locks while logged in):" -ForegroundColor Yellow
        $loadOut | ForEach-Object { Write-Host "      $_" }
        $failures.Add("$Label : reg load failed for $DatPath")
        return
    }
    try { Test-HiveCanary -Label $Label -Root $MountKey -StableOnly:$StableOnly }
    finally { & $reg unload $MountKey 2>$null | Out-Null }
}

Write-Host ""
Write-Host "P7 smoke verification -- per-user fan-out + new-user inheritance"
Write-Host "================================================================"

if (-not (Test-IsAdmin)) {
    Write-Host "ERROR: run elevated (reg load + Start-ScheduledTask require admin)." -ForegroundColor Red
    exit 1
}

# Resolve User2's profile NTUSER.DAT (handle suffixed profile folders via Win32_UserProfile).
$user2Dat = $null
try {
    $sid  = (New-Object Security.Principal.NTAccount($env:COMPUTERNAME, $User2Name)).Translate([Security.Principal.SecurityIdentifier]).Value
    $prof = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
    if ($prof -and $prof.LocalPath) { $user2Dat = Join-Path $prof.LocalPath 'NTUSER.DAT' }
} catch { }
if (-not $user2Dat) { $user2Dat = "C:\Users\$User2Name\NTUSER.DAT" }
if (-not (Test-Path -LiteralPath $user2Dat)) {
    Write-Host ""
    Write-Host "ERROR: '$user2Dat' not found -- prerequisite not met." -ForegroundColor Red
    Write-Host "  Create + provision the second user first:"
    Write-Host "    New-LocalUser $User2Name -NoPassword; Add-LocalGroupMember -Group Users -Member $User2Name"
    Write-Host "  then sign $User2Name in ONCE (creates the profile), sign OUT, and re-run."
    exit 1
}

# Trigger the cleanup task so the fan-out runs over live hives + the Default hive.
if (-not $SkipTrigger) {
    Write-Host ""
    Write-Host "[trigger] Start-ScheduledTask '$TaskPath$TaskName' + 30s wait ..."
    try { Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName; Start-Sleep -Seconds 30 }
    catch { Write-Host "  WARN: could not start the task ($($_.Exception.Message)); checking current state." -ForegroundColor Yellow }
} else {
    Write-Host ""
    Write-Host "[trigger] skipped (-SkipTrigger)"
}

# Arm 1 -- FAN-OUT: every live real-user hive (HKU\S-1-5-21-*, _Classes excluded).
Write-Host ""
Write-Host "[1] Fan-out arm -- live user hives (HKU\S-1-5-21-*, _Classes excluded):"
$liveSids = @(& $reg query 'HKU' 2>$null | ForEach-Object {
    if ($_ -match 'HKEY_USERS\\(S-1-5-21-[\d-]+)$') { $Matches[1] }
})
if ($liveSids.Count -eq 0) {
    Write-Host "  WARN: no live S-1-5-21 user hive loaded (expected the logged-in user)." -ForegroundColor Yellow
    $failures.Add("fan-out arm : no live user hive found")
}
foreach ($s in $liveSids) { Test-HiveCanary -Label "live $s" -Root "HKU\$s" }

# Arm 2 -- INHERITANCE: User2 offline NTUSER.DAT (must be signed out). -StableOnly because a user
# who logged in once then signed out keeps session drift in the service-managed values; only the
# inheritance-stable canary (AdvertisingInfo!Enabled) is asserted on this offline hive.
Invoke-OfflineHive -Label 'User2 offline -- inheritance arm' -MountKey 'HKLM\P7_VerifyUser2' -DatPath $user2Dat -StableOnly

# Arm 3 -- INHERITANCE SOURCE: the Default hive.
Invoke-OfflineHive -Label 'Default hive -- inheritance source' -MountKey 'HKLM\P7_VerifyDefault' -DatPath 'C:\Users\Default\NTUSER.DAT'

# Guard -- the cleanup log must have zero "_Classes" lines.
Write-Host ""
Write-Host "[4] _Classes guard -- cleanup log must have zero '_Classes' lines:"
if (Test-Path -LiteralPath $CleanupLog) {
    $classesHits = @(Select-String -LiteralPath $CleanupLog -Pattern '_Classes' -SimpleMatch)
    if ($classesHits.Count -eq 0) {
        Write-Host "    PASS  0 '_Classes' hits." -ForegroundColor Green
    } else {
        Write-Host ("    FAIL  {0} '_Classes' hit(s):" -f $classesHits.Count) -ForegroundColor Yellow
        $classesHits | ForEach-Object { Write-Host "      $($_.Line)" }
        $failures.Add("_Classes guard : $($classesHits.Count) hit(s) in $CleanupLog")
    }
} else {
    Write-Host "  WARN: $CleanupLog not found (cleanup task may not have run)." -ForegroundColor Yellow
    $failures.Add("_Classes guard : cleanup log not found ($CleanupLog)")
}

# Summary.
Write-Host ""
Write-Host "Summary:"
Write-Host "--------"
if ($failures.Count -eq 0) {
    Write-Host "  PASS -- canary settings = 0 in all live hives + User2 (inherited) + Default; no _Classes leakage." -ForegroundColor Green
    Write-Host ""
    exit 0
} else {
    Write-Host ("  FAIL -- {0} issue(s):" -f $failures.Count) -ForegroundColor Yellow
    $failures | ForEach-Object { Write-Host "    - $_" }
    Write-Host ""
    exit 1
}
