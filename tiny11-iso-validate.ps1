[CmdletBinding()]
param([Parameter(Mandatory)][string]$IsoPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $RepoRoot 'src' 'Tiny11.Iso.psm1') -Force

try {
    if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }

    $mountResult = Mount-Tiny11Source -InputPath $IsoPath
    try {
        $rawEditions = Get-Tiny11Editions -DriveLetter $mountResult.DriveLetter
        $editions = @($rawEditions | ForEach-Object {
            @{
                index = $_.ImageIndex
                name  = $_.ImageName
                size  = $_.ImageSize
                arch  = $_.Architecture
            }
        })

        $obj = @{ ok = $true; editions = $editions }
        [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
        exit 0
    }
    finally {
        if ($mountResult.MountedByUs) {
            Dismount-Tiny11Source -IsoPath $IsoPath -MountedByUs $true -ForceUnmount $false
        }
    }
}
catch {
    $obj = @{ ok = $false; message = $_.Exception.Message }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
    exit 1
}
