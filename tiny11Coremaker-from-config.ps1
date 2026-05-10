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

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutputIso,
    [int]$ImageIndex = 0,
    [string]$Edition,
    [string]$ScratchDir,
    [switch]$EnableNet35,
    [switch]$UnmountSource
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

try {
    # Locate bundled modules — same dir as this wrapper (extracted by EmbeddedResources at runtime).
    $RepoRoot = Split-Path -Parent $PSCommandPath
    $ModulesDir = Join-Path $RepoRoot 'src'

    Import-Module (Join-Path $ModulesDir 'Tiny11.Iso.psm1')   -Force
    Import-Module (Join-Path $ModulesDir 'Tiny11.Core.psm1')  -Force

    # Preflight: mount the source, enumerate editions, resolve -Edition to
    # -ImageIndex if needed. Same pattern as tiny11maker-from-config.ps1
    # (lines 77-91) — keeps the source-mount-then-dismount window short
    # before the heavy build phases.
    Write-Marker 'build-progress' @{ phase = 'preflight'; step = 'Mounting source for edition enumeration'; percent = 0 }
    $preflightMount = Mount-Tiny11Source -InputPath $Source
    try {
        $editions = @(Get-Tiny11Editions -DriveLetter $preflightMount.DriveLetter)
        if ($Edition -and $ImageIndex -le 0) {
            $ImageIndex = Resolve-Tiny11ImageIndex -Editions $editions -Edition $Edition
        }
    } finally {
        if ($preflightMount.MountedByUs) {
            Dismount-Tiny11Source -IsoPath $preflightMount.IsoPath -MountedByUs:$preflightMount.MountedByUs -ForceUnmount:$true
        }
    }

    if ($ImageIndex -le 0) {
        throw "Image index could not be resolved (Edition='$Edition', ImageIndex=$ImageIndex). Pass -Edition or -ImageIndex."
    }

    # Scratch dir resolution. Honour caller's -ScratchDir if provided
    # (matches BuildHandlers payload pass-through); fall back to process-
    # scoped temp dir so concurrent invocations don't collide.
    if (-not $ScratchDir) {
        $ScratchDir = Join-Path $env:TEMP "tiny11options-corebuild-$PID"
    }
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null

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
        -ProgressCallback {
            param($p)
            Write-Marker 'build-progress' @{ phase = $p.phase; step = $p.step; percent = $p.percent }
        }

    Write-Marker 'build-complete' @{ outputPath = $OutputIso }
    exit 0
}
catch {
    Write-Marker 'build-error' @{ message = $_.Exception.Message; stackTrace = $_.ScriptStackTrace }
    exit 1
}
