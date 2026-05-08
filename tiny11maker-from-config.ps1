[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutputIso,
    [int]$ImageIndex = 0,
    [string]$Edition,
    [switch]$AllowVLSource,
    [switch]$FastBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

$ConfigJson = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Locate the bundled modules - same dir as this wrapper
$RepoRoot = Split-Path -Parent $PSCommandPath
$ModulesDir = Join-Path $RepoRoot 'src'

Import-Module (Join-Path $ModulesDir 'Tiny11.Catalog.psm1')   -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Selections.psm1') -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Iso.psm1')        -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Worker.psm1')     -Force

# Build the selection list from the config and reconcile against catalog
$catalogPath = Join-Path $RepoRoot 'catalog'
$catalog = Import-Tiny11Catalog -Path $catalogPath
$selections = Resolve-Tiny11Selections -Catalog $catalog -Selected $ConfigJson.selections

# Stream JSON progress markers - launcher parses these line-by-line
function Write-ProgressJson($phase, $step, $percent) {
    $obj = @{ type = 'build-progress'; payload = @{ phase = $phase; step = $step; percent = $percent } }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
}

try {
    Write-ProgressJson 'preflight' 'Validating source ISO' 0
    $imageInfo = Get-Tiny11VolumeForImage -ImagePath $Source
    if ($Edition) { $ImageIndex = Resolve-Tiny11ImageIndex -ImageInfo $imageInfo -EditionName $Edition }
    if ($ImageIndex -le 0) { throw "Image index could not be resolved (Edition=$Edition)" }

    if (-not $AllowVLSource -and -not (Test-Tiny11SourceIsConsumer -ImageInfo $imageInfo -ImageIndex $ImageIndex)) {
        throw "Source appears to be VL/MSDN. Pass -AllowVLSource to override."
    }

    Invoke-Tiny11Build `
        -SourceIso $Source `
        -ImageIndex $ImageIndex `
        -OutputIso $OutputIso `
        -Selections $selections `
        -FastBuild:$FastBuild `
        -ProgressHook { param($phase, $step, $percent) Write-ProgressJson $phase $step $percent }

    $obj = @{ type = 'build-complete'; payload = @{ outputIso = $OutputIso } }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
    exit 0
}
catch {
    $obj = @{ type = 'build-error'; payload = @{ message = $_.Exception.Message; stackTrace = $_.ScriptStackTrace } }
    [Console]::Error.WriteLine(($obj | ConvertTo-Json -Compress))
    exit 1
}
