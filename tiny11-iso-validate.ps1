[CmdletBinding()]
param([Parameter(Mandatory)][string]$IsoPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $RepoRoot 'src\Tiny11.Iso.psm1') -Force

try {
    if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }

    $mountResult = Mount-Tiny11Source -InputPath $IsoPath
    try {
        $rawEditions = Get-Tiny11Editions -DriveLetter $mountResult.DriveLetter
        # PORTED: tiny11maker.ps1:191-193 (legacy validate-iso handler).
        # Emit ONLY index + name. Architecture is unreliable across Windows ISOs
        # and trips Set-StrictMode -Version Latest (v0.1.0 polish-bundle fix in
        # commit cf80091). ImageSize is also omitted to match legacy exactly --
        # JS-side only consumes `index` per ui/app.js.
        $editions = @($rawEditions | ForEach-Object {
            @{
                index = $_.ImageIndex
                name  = $_.ImageName
            }
        })

        $obj = @{ ok = $true; editions = $editions }
        [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
        exit 0
    }
    finally {
        if ($mountResult.MountedByUs) {
            # PORTED: tiny11maker.ps1:194 -- legacy uses -ForceUnmount:$true on
            # the post-validate dismount. Critical for clean retry: without it,
            # the source ISO can remain mount-locked when the user re-validates
            # the same path immediately.
            # v1.0.8 audit WARNING scripts A4: forward from $mountResult to
            # match the GUI handler pattern (tiny11maker.ps1:191). Functionally
            # equivalent today (outer if-guard makes -MountedByUs:$true safe;
            # $IsoPath == $mountResult.IsoPath for .iso file inputs) but the
            # symmetry prevents a future loosening of the outer guard from
            # surfacing as a contract violation.
            Dismount-Tiny11Source -IsoPath $mountResult.IsoPath -MountedByUs:$mountResult.MountedByUs -ForceUnmount:$true
        }
    }
}
catch {
    $obj = @{ ok = $false; message = $_.Exception.Message }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
    exit 1
}
