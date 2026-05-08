# Path C launcher build wrapper — invoked by launcher/Gui/Handlers/BuildHandlers.cs
# as a powershell.exe subprocess. The launcher writes the full JS-side build
# payload to a JSON file and passes it via -ConfigPath; CLI args carry the
# scalar fields that don't fit naturally in the config (and let the wrapper
# stay greppable from the launcher side).
#
# AUDIT REFERENCE: tiny11maker.ps1:131-175 (legacy non-interactive branch +
# preflight) and tiny11maker.ps1:242-296 (legacy `build` handler in the
# interactive dispatch table). This wrapper matches both: it does the
# legacy preflight (mount + enumerate + VL check + Edition/ImageIndex
# resolve) and then calls Invoke-Tiny11BuildPipeline with the same shape
# the legacy build worker did. Progress markers + completion + error are
# emitted as JSON lines on STDOUT for line-by-line parsing in BuildHandlers.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutputIso,
    [int]$ImageIndex = 0,
    [string]$Edition,
    [string]$ScratchDir,
    [switch]$AllowVLSource,
    [switch]$FastBuild,
    [switch]$UnmountSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Helper: write a JSON marker to STDOUT for the launcher's line-by-line forwarder.
# All bridge-traffic — progress, complete, error — goes through STDOUT so
# BuildHandlers' single forwarder routes it consistently. (Legacy used a
# Dispatcher-marshal-back-to-WebView pattern; the launcher equivalent is line
# parsing in C#, but the JSON shape is identical: {type, payload}.)
function Write-Marker($Type, [hashtable]$Payload) {
    $obj = @{ type = $Type; payload = $Payload }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
}

try {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $ConfigJson = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

    # Locate bundled modules — same dir as this wrapper (extracted by EmbeddedResources at runtime).
    $RepoRoot = Split-Path -Parent $PSCommandPath
    $ModulesDir = Join-Path $RepoRoot 'src'

    Import-Module (Join-Path $ModulesDir 'Tiny11.Catalog.psm1')    -Force
    Import-Module (Join-Path $ModulesDir 'Tiny11.Selections.psm1') -Force
    Import-Module (Join-Path $ModulesDir 'Tiny11.Iso.psm1')        -Force
    Import-Module (Join-Path $ModulesDir 'Tiny11.Worker.psm1')     -Force

    # PORTED: tiny11maker.ps1:127 — load catalog from bundled catalog/ directory.
    $catalogPath = Join-Path $RepoRoot 'catalog'
    $catalog = Get-Tiny11Catalog -Path $catalogPath

    # PORTED: tiny11maker.ps1:242-248 (legacy `build` handler) — selections shape.
    # JS sends `selections` as a dict {itemId: 'apply'|'skip'} (state.selections in
    # ui/app.js). New-Tiny11Selections expects an Overrides hashtable of the same
    # shape, but ConvertFrom-Json deserializes JSON objects to PSCustomObject in
    # PS 5.1 — so we have to walk the property bag, not iterate keys.
    $overrides = @{}
    if ($ConfigJson.PSObject.Properties.Name -contains 'selections' -and $ConfigJson.selections) {
        foreach ($prop in $ConfigJson.selections.PSObject.Properties) {
            $overrides[[string]$prop.Name] = [string]$prop.Value
        }
    }
    $rawSelections      = New-Tiny11Selections -Catalog $catalog -Overrides $overrides
    $resolvedSelections = Resolve-Tiny11Selections -Catalog $catalog -Selections $rawSelections

    # PORTED: tiny11maker.ps1:131-157 — non-interactive preflight is UNCONDITIONAL.
    # Mount, enumerate, run VL/MSDN check, resolve -Edition to -ImageIndex if needed.
    # Path C scaffold gated this on `-Edition` being set, which silently skipped VL
    # detection when the launcher passed -ImageIndex directly. VL ISOs would then
    # fail Setup product-key validation at install time with no upstream warning.
    Write-Marker 'build-progress' @{ phase = 'preflight'; step = 'Mounting source for edition + VL check'; percent = 0 }
    $preflightMount = Mount-Tiny11Source -InputPath $Source
    try {
        $editions = @(Get-Tiny11Editions -DriveLetter $preflightMount.DriveLetter)
        $isConsumer = Test-Tiny11SourceIsConsumer -Editions $editions
        if (-not $isConsumer) {
            $editionsList = ($editions | ForEach-Object { $_.ImageName }) -join '; '
            $vlMsg = "Source ISO appears to be VL/MSDN (more than 4 editions or contains Enterprise/Education/Server variants). tiny11 targets the consumer Win11 ISO; build will probably fail at install time with `"Setup has failed to validate the product key`". Editions found: $editionsList"
            if (-not $AllowVLSource) {
                throw "$vlMsg`nOverride with -AllowVLSource to proceed anyway."
            }
            Write-Marker 'build-progress' @{ phase = 'preflight'; step = "VL/MSDN source allowed by override: $vlMsg"; percent = 0 }
        }
        if ($Edition -and $ImageIndex -le 0) {
            $ImageIndex = Resolve-Tiny11ImageIndex -Editions $editions -Edition $Edition
        }
    } finally {
        if ($preflightMount.MountedByUs) {
            # PORTED: tiny11maker.ps1:155 — legacy uses -ForceUnmount:$true here.
            # Critical for clean retry after preflight; without it the source can
            # remain mount-locked when the user re-runs the build immediately.
            Dismount-Tiny11Source -IsoPath $preflightMount.IsoPath -MountedByUs:$preflightMount.MountedByUs -ForceUnmount:$true
        }
    }

    if ($ImageIndex -le 0) {
        throw "Image index could not be resolved (Edition='$Edition', ImageIndex=$ImageIndex). Pass -Edition or -ImageIndex."
    }

    # Scratch dir resolution. Honour caller's -ScratchDir if provided (matches
    # legacy parity — the GUI lets the user pick scratch); fall back to a
    # process-scoped temp dir so concurrent invocations don't collide.
    if (-not $ScratchDir) {
        $ScratchDir = Join-Path $env:TEMP "tiny11options-build-$PID"
    }
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null

    # PORTED: tiny11maker.ps1:166-171 (non-interactive build pipeline call) +
    # tiny11maker.ps1:271-278 (interactive build worker). Same shape; UnmountSource
    # toggle from JS payload, FastBuild from JS payload, ProgressCallback streams
    # JSON markers via Write-Marker.
    Invoke-Tiny11BuildPipeline `
        -Source $Source `
        -ImageIndex $ImageIndex `
        -ScratchDir $ScratchDir `
        -OutputPath $OutputIso `
        -UnmountSource $UnmountSource.IsPresent `
        -Catalog $catalog `
        -ResolvedSelections $resolvedSelections `
        -FastBuild $FastBuild.IsPresent `
        -ProgressCallback {
            param($p)
            Write-Marker 'build-progress' @{ phase = $p.phase; step = $p.step; percent = $p.percent }
        }

    # PORTED: tiny11maker.ps1:279 — legacy emits build-complete with {outputPath}.
    # JS reads `state.completed = msg.payload` then `c.outputPath` in renderComplete
    # (app.js:238). Match that exact field name.
    Write-Marker 'build-complete' @{ outputPath = $OutputIso }
    exit 0
}
catch {
    # PORTED: tiny11maker.ps1:282 — legacy emits build-error on STDOUT via the
    # bridge marshal. We use STDOUT (not STDERR) so BuildHandlers' single
    # line-by-line forwarder routes it like every other marker.
    Write-Marker 'build-error' @{ message = $_.Exception.Message; stackTrace = $_.ScriptStackTrace }
    exit 1
}
