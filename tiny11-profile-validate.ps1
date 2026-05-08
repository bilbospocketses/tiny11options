# Path C launcher profile-validation subscript — invoked by
# launcher/Gui/Handlers/ProfileHandlers.cs as a powershell.exe subprocess
# to validate a saved profile against the catalog and return the resolved
# selections in the {id: state} shape JS expects.
#
# AUDIT REFERENCE: tiny11maker.ps1:236 (legacy load-profile-request handler) —
# legacy uses Import-Tiny11Selections which validates against the catalog
# and rejects unknown item IDs / invalid 'apply'/'skip' values, then flattens
# the returned hashtable to {id: state}. Path C delegates the same logic to
# this script rather than re-implementing the validator in C#.

[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProfilePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $RepoRoot 'src\Tiny11.Catalog.psm1')    -Force
Import-Module (Join-Path $RepoRoot 'src\Tiny11.Selections.psm1') -Force

try {
    if (-not (Test-Path $ProfilePath)) { throw "Profile not found: $ProfilePath" }

    $catalogPath = Join-Path $RepoRoot 'catalog\catalog.json'
    $catalog = Get-Tiny11Catalog -Path $catalogPath

    $sel = Import-Tiny11Selections -Path $ProfilePath -Catalog $catalog

    # Flatten {id: pscustomobject{ItemId, State}} -> {id: state} so JS state.selections
    # can rehydrate directly. Mirrors tiny11maker.ps1:237-239 (legacy flatten loop).
    $flat = @{}
    foreach ($k in $sel.Keys) { $flat[$k] = $sel[$k].State }

    $obj = @{ ok = $true; selections = $flat }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
    exit 0
}
catch {
    $obj = @{ ok = $false; message = $_.Exception.Message }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
    exit 1
}
