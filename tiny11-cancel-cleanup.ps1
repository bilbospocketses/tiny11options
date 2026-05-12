# tiny11-cancel-cleanup.ps1 — Invoked by launcher/Gui/Handlers/CleanupHandlers.cs
# when the user clicks "Cancel build & clean up" or the cleanup button on the
# Build cancelled / Build failed screen. Runs the recovery commands documented
# in renderCleanupBlock (ui/app.js) against the mount/source directories where
# install.wim was being modified at cancel/failure time.
#
# Operation order is load-bearing (2026-05-11 incident):
#   1. Unload any registry hives the pipeline `reg load`-ed into HKLM\z* —
#      otherwise the host System process keeps NTUSER.DAT et al. open, which
#      blocks the subsequent Remove-Item even though no other tool obviously
#      holds the files.
#   2. dism /Unmount-Image /Discard against MountDir. Requires
#      source\sources\install.wim to still exist on disk — that's why we DO
#      NOT delete SourceDir until step 6.
#   3. dism /Cleanup-Mountpoints to sweep stale mount registrations.
#   4. dism /Get-MountedWimInfo verification — if MountDir is still listed
#      (typically as Status: Invalid), retry /Cleanup-Mountpoints once after
#      a 2 second sleep.
#   5. takeown + icacls + Remove-Item against MountDir, then verify the
#      directory is actually gone. If it isn't, emit cleanup-error with a
#      "reboot required" diagnostic and DO NOT proceed to step 6 — leaving
#      SourceDir intact lets a post-reboot retry use install.wim as the
#      reference for a clean DISM unmount.
#   6. Only after MountDir is confirmed removed: Remove-Item SourceDir.
#
# Each non-fatal step is best-effort: DISM may fail because nothing is
# mounted, takeown may fail because the dir was already removed, hive unload
# emits a non-zero exit for every "nothing to unload" key. We surface
# progress markers so the UI can narrate, but only abort the destructive
# Remove-Item SourceDir if the MountDir didn't actually delete (the
# foot-gun: deleting source before mount is properly released leaves the
# mount permanently Invalid until reboot).
#
# Emits JSON markers on STDOUT for line-by-line parsing in CleanupHandlers
# (same forwarder pattern used by BuildHandlers):
#   cleanup-progress {step, percent}
#   cleanup-complete {message}
#   cleanup-error    {message, stackTrace}

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MountDir,
    [Parameter(Mandatory)][string]$SourceDir,
    # Optional. When supplied (build-complete cleanup case), the script refuses to
    # run if the output ISO falls inside either cleanup target -- defensive guard
    # against deleting the user's deliverable. The cancel/error case can omit this
    # because there is no completed output ISO to protect at that point.
    [string]$OutputIso = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-Marker($Type, [hashtable]$Payload) {
    $obj = @{ type = $Type; payload = $Payload }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
}

# Defensive: if the caller supplied an OutputIso path and it falls inside one of
# the cleanup target dirs, refuse rather than delete the user's freshly-built
# ISO. The launcher UI also gates this client-side, but the script-side guard
# protects against direct CLI invocations and against future UI bugs.
if ($OutputIso) {
    $normalizedOutput = [System.IO.Path]::GetFullPath($OutputIso)
    foreach ($target in @($MountDir, $SourceDir)) {
        if (-not $target) { continue }
        $normalizedTarget = [System.IO.Path]::GetFullPath($target).TrimEnd('\') + '\'
        if ($normalizedOutput.StartsWith($normalizedTarget, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Marker 'cleanup-error' @{
                message = "Refusing to clean up: output ISO '$OutputIso' is inside cleanup target '$target'. Move the ISO out of the scratch subdirectories first, or run cleanup manually."
            }
            exit 1
        }
    }
}

try {
    # Step 1 — Unload any pipeline-loaded registry hives. The build pipeline
    # `reg load`-s these into HKLM\z* via Mount-Tiny11AllHives (src/Tiny11.Hives.psm1).
    # If the build was cancelled before Dismount-Tiny11AllHives ran, the host
    # System process holds NTUSER.DAT / SOFTWARE / SYSTEM / DEFAULT / COMPONENTS
    # open inside MountDir and Remove-Item silently fails on those files.
    Write-Marker 'cleanup-progress' @{ step = 'Unloading host registry hives (zCOMPONENTS / zDEFAULT / zNTUSER / zSOFTWARE / zSYSTEM)'; percent = 5 }
    foreach ($mountKey in @('zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM')) {
        & 'reg.exe' 'unload' "HKLM\$mountKey" 2>&1 | Out-Null
        # Non-fatal: hive may not be loaded. reg.exe returns non-zero for "not loaded".
    }

    # Step 2 — Unmount the image. Needs install.wim still present in SourceDir.
    Write-Marker 'cleanup-progress' @{ step = "DISM /Unmount-Image /Discard on $MountDir"; percent = 15 }
    & 'dism.exe' '/Unmount-Image' "/MountDir:$MountDir" '/Discard' 2>&1 | Out-Null
    # Exit code intentionally not checked -- mount may not be present, or may be Invalid.

    # Step 3 — Sweep stale mount registrations.
    Write-Marker 'cleanup-progress' @{ step = 'DISM /Cleanup-Mountpoints'; percent = 30 }
    & 'dism.exe' '/Cleanup-Mountpoints' 2>&1 | Out-Null

    # Step 4 — Verify the mount is no longer registered. If it still shows up
    # (Status: Invalid is the typical leftover state when source.wim is gone),
    # retry /Cleanup-Mountpoints once after a short pause to give the wimmount
    # driver a chance to flush.
    Write-Marker 'cleanup-progress' @{ step = 'Verifying DISM mount registry is clear'; percent = 40 }
    $mountInfo = & 'dism.exe' '/Get-MountedWimInfo' 2>&1
    if ($mountInfo -match [regex]::Escape($MountDir)) {
        Start-Sleep -Seconds 2
        & 'dism.exe' '/Cleanup-Mountpoints' 2>&1 | Out-Null
    }

    # Step 5 — Take ownership + grant Administrators + remove MountDir.
    if (Test-Path -LiteralPath $MountDir) {
        Write-Marker 'cleanup-progress' @{ step = "takeown /F `"$MountDir`" /R /D Y"; percent = 50 }
        & 'takeown.exe' '/F' $MountDir '/R' '/D' 'Y' 2>&1 | Out-Null

        Write-Marker 'cleanup-progress' @{ step = "icacls `"$MountDir`" /grant Administrators:F /T /C"; percent = 60 }
        & 'icacls.exe' $MountDir '/grant' 'Administrators:F' '/T' '/C' 2>&1 | Out-Null

        Write-Marker 'cleanup-progress' @{ step = "Remove-Item $MountDir"; percent = 70 }
        Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Marker 'cleanup-progress' @{ step = "Mount dir $MountDir absent (already clean); skipping takeown/icacls/Remove"; percent = 70 }
    }

    # Step 5b — Verify MountDir is actually gone. If it isn't, the wimmount
    # driver is still holding kernel handles on the contents (typical when
    # the mount went Invalid because a prior cleanup deleted source\install.wim
    # before unmount completed). DO NOT proceed to delete SourceDir — leaving
    # it intact lets a post-reboot retry use install.wim as the reference for
    # a clean unmount. Emit a reboot-required cleanup-error and exit 1.
    if (Test-Path -LiteralPath $MountDir) {
        Write-Marker 'cleanup-error' @{
            message = "Cleanup partial — could not remove '$MountDir' because the wimmount driver still holds kernel file handles (likely a DISM mount in 'Invalid' state). REBOOT REQUIRED: after reboot the kernel releases the handles and Remove-Item succeeds. SourceDir '$SourceDir' has been preserved so a post-reboot retry can use install.wim to complete a clean DISM /Unmount-Image."
        }
        exit 1
    }

    # Step 6 — Mount confirmed gone; safe to remove SourceDir.
    if (Test-Path -LiteralPath $SourceDir) {
        Write-Marker 'cleanup-progress' @{ step = "Remove-Item $SourceDir"; percent = 90 }
        Remove-Item -LiteralPath $SourceDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Marker 'cleanup-progress' @{ step = "Source dir $SourceDir absent (already clean); skipping Remove"; percent = 90 }
    }

    Write-Marker 'cleanup-complete' @{ message = 'Cleanup complete. Scratch directories were removed (or were already absent).' }
    exit 0
} catch {
    Write-Marker 'cleanup-error' @{
        message    = $_.Exception.Message
        stackTrace = $_.ScriptStackTrace
    }
    exit 1
}
