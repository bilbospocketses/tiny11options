# tiny11-cancel-cleanup.ps1 — Invoked by launcher/Gui/Handlers/CleanupHandlers.cs
# when the user clicks "Run cleanup automatically" on the Build cancelled / Build
# failed UI. Runs the 6 recovery commands documented in renderCleanupBlock
# (ui/app.js) against the mount/source directories where install.wim was being
# modified at cancel/failure time.
#
# Each step is best-effort: DISM may fail because nothing is mounted, takeown
# may fail because the dir was already removed, Remove-Item is wrapped in
# -ErrorAction SilentlyContinue. We surface progress markers so the UI can
# narrate, but we DO NOT abort on intermediate-step failure -- the goal is
# "return the system to a clean state," which is satisfied even if some
# steps are no-ops because the underlying state was already clean.
#
# Emits JSON markers on STDOUT for line-by-line parsing in CleanupHandlers
# (same forwarder pattern used by BuildHandlers):
#   cleanup-progress {step, percent}
#   cleanup-complete {message}
#   cleanup-error    {message, stackTrace}

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MountDir,
    [Parameter(Mandatory)][string]$SourceDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-Marker($Type, [hashtable]$Payload) {
    $obj = @{ type = $Type; payload = $Payload }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
}

try {
    Write-Marker 'cleanup-progress' @{ step = "DISM /Unmount-Image /Discard on $MountDir"; percent = 10 }
    & 'dism.exe' '/Unmount-Image' "/MountDir:$MountDir" '/Discard' 2>&1 | Out-Null
    # Exit code intentionally not checked -- mount may not be present.

    Write-Marker 'cleanup-progress' @{ step = 'DISM /Cleanup-Mountpoints'; percent = 30 }
    & 'dism.exe' '/Cleanup-Mountpoints' 2>&1 | Out-Null

    if (Test-Path -LiteralPath $MountDir) {
        Write-Marker 'cleanup-progress' @{ step = "takeown /F `"$MountDir`" /R /D Y"; percent = 45 }
        & 'takeown.exe' '/F' $MountDir '/R' '/D' 'Y' 2>&1 | Out-Null

        Write-Marker 'cleanup-progress' @{ step = "icacls `"$MountDir`" /grant Administrators:F /T /C"; percent = 60 }
        & 'icacls.exe' $MountDir '/grant' 'Administrators:F' '/T' '/C' 2>&1 | Out-Null

        Write-Marker 'cleanup-progress' @{ step = "Remove-Item $MountDir"; percent = 75 }
        Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Marker 'cleanup-progress' @{ step = "Mount dir $MountDir absent (already clean); skipping takeown/icacls/Remove"; percent = 75 }
    }

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
