# tiny11 Core build wrapper — invoked by launcher/Gui/Handlers/BuildHandlers.cs
# as a powershell.exe subprocess when the user picks Core mode in the Step 1
# wizard. Differs from tiny11maker-from-config.ps1: no -ConfigPath / no
# selections payload (Core has no catalog), and adds -EnableNet35 (the
# Step 1 .NET 3.5 sub-checkbox).
#
# Hands off to Invoke-Tiny11CoreBuildPipeline (src/Tiny11.Core.psm1) which
# orchestrates the 24-phase Core build. Progress markers + completion +
# error are emitted as JSON lines on STDOUT for line-by-line parsing in
# BuildHandlers (same forwarder used by tiny11maker-from-config.ps1).
#
# Persistent log: this wrapper writes a comprehensive on-disk log to
# $ScratchDir\tiny11-core-build.log covering every phase, every external
# command (DISM/takeown/icacls/reg/oscdimg) with full output + exit code,
# and any caught exception. Survives the WinSxS-cancel cleanup commands
# (those only nuke `mount/` and `source/` subdirs of the scratch root).

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutputIso,
    [int]$ImageIndex = 0,
    [string]$Edition,
    [string]$ScratchDir,
    [switch]$EnableNet35,
    [switch]$UnmountSource,
    [switch]$FastBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Helper: write a JSON marker to STDOUT for the launcher's line-by-line forwarder.
# Matches tiny11maker-from-config.ps1's Write-Marker exactly so the launcher's
# BuildHandlers forwarder routes Core markers identically to standard markers.
function Write-Marker($Type, [hashtable]$Payload) {
    $obj = @{ type = $Type; payload = $Payload }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
}

# Declared outside the try block so the catch can reference it even if the
# failure fires before the log path is initialized.
$logPath = $null

try {
    # Locate bundled modules — same dir as this wrapper (extracted by EmbeddedResources at runtime).
    $RepoRoot = Split-Path -Parent $PSCommandPath
    $ModulesDir = Join-Path $RepoRoot 'src'

    Import-Module (Join-Path $ModulesDir 'Tiny11.Iso.psm1')   -Force
    Import-Module (Join-Path $ModulesDir 'Tiny11.Core.psm1')  -Force

    # Scratch dir resolution. Honour caller's -ScratchDir if provided
    # (matches BuildHandlers payload pass-through); fall back to process-
    # scoped temp dir so concurrent invocations don't collide.
    if (-not $ScratchDir) {
        $ScratchDir = Join-Path $env:TEMP "tiny11options-corebuild-$PID"
    }
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null

    # Initialize the persistent log NOW, before any operation that could fail.
    # Set-Tiny11CoreLogPath truncates any prior log so each run starts clean.
    $logPath = Join-Path $ScratchDir 'tiny11-core-build.log'
    Set-Tiny11CoreLogPath -Path $logPath
    Write-CoreLog '==== Tiny11 Core build wrapper start ===='
    Write-CoreLog "PSVersion=$($PSVersionTable.PSVersion) Architecture=$env:PROCESSOR_ARCHITECTURE OS=$([Environment]::OSVersion.VersionString)"
    Write-CoreLog "Wrapper params: Source='$Source' OutputIso='$OutputIso' ImageIndex=$ImageIndex Edition='$Edition' ScratchDir='$ScratchDir' EnableNet35=$($EnableNet35.IsPresent) UnmountSource=$($UnmountSource.IsPresent) FastBuild=$($FastBuild.IsPresent)"

    # Preflight: mount the source, enumerate editions, resolve -Edition to
    # -ImageIndex if needed. Same pattern as tiny11maker-from-config.ps1
    # (lines 77-91) — keeps the source-mount-then-dismount window short
    # before the heavy build phases.
    Write-Marker 'build-progress' @{ phase = 'preflight'; step = 'Mounting source for edition enumeration'; percent = 0 }
    Write-CoreLog 'PREFLIGHT: Mount-Tiny11Source for edition enumeration'
    $preflightMount = Mount-Tiny11Source -InputPath $Source
    try {
        $editions = @(Get-Tiny11Editions -DriveLetter $preflightMount.DriveLetter)
        Write-CoreLog "PREFLIGHT: discovered $($editions.Count) edition(s)"
        if ($Edition -and $ImageIndex -le 0) {
            $ImageIndex = Resolve-Tiny11ImageIndex -Editions $editions -Edition $Edition
            Write-CoreLog "PREFLIGHT: resolved Edition='$Edition' to ImageIndex=$ImageIndex"
        }
    } finally {
        if ($preflightMount.MountedByUs) {
            Dismount-Tiny11Source -IsoPath $preflightMount.IsoPath -MountedByUs:$preflightMount.MountedByUs -ForceUnmount:$true
            Write-CoreLog 'PREFLIGHT: Dismount-Tiny11Source done'
        }
    }

    if ($ImageIndex -le 0) {
        throw "Image index could not be resolved (Edition='$Edition', ImageIndex=$ImageIndex). Pass -Edition or -ImageIndex."
    }

    # Hand off to Tiny11.Core's orchestrator. Progress markers stream via
    # the callback, terminating with build-complete or throwing on error
    # (caught by the outer try/catch and emitted as build-error).
    Invoke-Tiny11CoreBuildPipeline `
        -Source $Source `
        -ImageIndex $ImageIndex `
        -ScratchDir $ScratchDir `
        -OutputIso $OutputIso `
        -EnableNet35 $EnableNet35.IsPresent `
        -UnmountSource $UnmountSource.IsPresent `
        -FastBuild $FastBuild.IsPresent `
        -ProgressCallback {
            param($p)
            # Forward the entire payload, not just phase/step/percent. The Core
            # pipeline emits mount-state markers with extra fields (mountActive,
            # mountDir, sourceDir) that the launcher's auto-cleanup button
            # depends on. Per-key whitelisting drops those fields silently, so
            # JS never sees state.mountActive=true and the cleanup section
            # self-gates off. Pass $p through directly — Write-Marker already
            # declares [hashtable]$Payload so any keys present flow through to
            # ConvertTo-Json verbatim.
            Write-Marker 'build-progress' $p
        }

    Write-CoreLog '==== Tiny11 Core build SUCCESS ===='
    Write-Marker 'build-complete' @{ outputPath = $OutputIso }
    exit 0
}
catch {
    # Mirror the exception into the persistent log first (best-effort — Write-CoreLog
    # is a no-op if Set-Tiny11CoreLogPath was never called or the module didn't load).
    if (Get-Command -Name Write-CoreLog -ErrorAction SilentlyContinue) {
        Write-CoreLog '==== Tiny11 Core build FAILED ===='
        Write-CoreLog "Exception.Message: $($_.Exception.Message)"
        Write-CoreLog "ScriptStackTrace:`n$($_.ScriptStackTrace)"
    }
    Write-Marker 'build-error' @{
        message    = $_.Exception.Message
        stackTrace = $_.ScriptStackTrace
        logPath    = $logPath
    }
    exit 1
}
