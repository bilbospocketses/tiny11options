[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutputIso,
    [string]$Edition,
    [int]$ImageIndex = 0,
    [switch]$AllowVLSource,
    [switch]$FastBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

$ConfigJson = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Locate bundled modules - same dir as this wrapper (extracted by EmbeddedResources at runtime)
$RepoRoot = Split-Path -Parent $PSCommandPath
$ModulesDir = Join-Path $RepoRoot 'src'

Import-Module (Join-Path $ModulesDir 'Tiny11.Catalog.psm1')   -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Selections.psm1') -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Iso.psm1')        -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Worker.psm1')     -Force

# Stream JSON progress markers — launcher parses these line-by-line
function Write-ProgressJson($phase, $step, $percent) {
    $obj = @{ type = 'build-progress'; payload = @{ phase = $phase; step = $step; percent = $percent } }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
}

try {
    # Load catalog from bundled catalog/ directory
    $catalogPath = Join-Path $RepoRoot 'catalog'
    $catalog = Get-Tiny11Catalog -Path $catalogPath

    # Convert selections array (list of item IDs the user explicitly selected to apply) into the
    # Overrides hashtable shape that New-Tiny11Selections expects: @{ itemId = 'apply' }
    $overrides = @{}
    if ($ConfigJson.PSObject.Properties.Name -contains 'selections' -and $ConfigJson.selections) {
        foreach ($id in $ConfigJson.selections) {
            $overrides[[string]$id] = 'apply'
        }
    }

    # Build the full selections hashtable, then resolve dependencies
    $rawSelections      = New-Tiny11Selections -Catalog $catalog -Overrides $overrides
    $resolvedSelections = Resolve-Tiny11Selections -Catalog $catalog -Selections $rawSelections

    # Resolve edition → ImageIndex if needed. Brief mount to enumerate editions.
    if ($Edition -and $ImageIndex -le 0) {
        Write-ProgressJson 'preflight' 'Resolving edition to image index' 0
        $probeMount = Mount-Tiny11Source -InputPath $Source
        try {
            $editions   = Get-Tiny11Editions -DriveLetter $probeMount.DriveLetter
            $ImageIndex = Resolve-Tiny11ImageIndex -Editions $editions -Edition $Edition

            if (-not $AllowVLSource -and -not (Test-Tiny11SourceIsConsumer -Editions $editions)) {
                throw "Source appears to be VL/MSDN. Pass -AllowVLSource to override."
            }
        }
        finally {
            if ($probeMount.MountedByUs) {
                try { Dismount-Tiny11Source -IsoPath $Source -MountedByUs $true -ForceUnmount $false } catch { }
            }
        }
    }

    if ($ImageIndex -le 0) {
        throw "Image index could not be resolved (Edition='$Edition', ImageIndex=$ImageIndex)"
    }

    # Scratch dir for the build pipeline
    $scratchDir = Join-Path $env:TEMP "tiny11options-build-$PID"
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null

    # The pipeline mounts $Source itself; pass the ISO path verbatim
    Invoke-Tiny11BuildPipeline `
        -Source $Source `
        -ImageIndex $ImageIndex `
        -ScratchDir $scratchDir `
        -OutputPath $OutputIso `
        -UnmountSource $true `
        -Catalog $catalog `
        -ResolvedSelections $resolvedSelections `
        -FastBuild $FastBuild.IsPresent `
        -ProgressCallback {
            param($p)
            Write-ProgressJson $p.phase $p.step $p.percent
        }

    $obj = @{ type = 'build-complete'; payload = @{ outputIso = $OutputIso } }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
    exit 0
}
catch {
    $obj = @{ type = 'build-error'; payload = @{ message = $_.Exception.Message; stackTrace = $_.ScriptStackTrace } }
    [Console]::Error.WriteLine(($obj | ConvertTo-Json -Compress))
    exit 1
}
