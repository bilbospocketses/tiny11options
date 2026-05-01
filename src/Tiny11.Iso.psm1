Set-StrictMode -Version Latest

function Resolve-Tiny11Source {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InputPath)
    if ($InputPath -match '^[a-zA-Z]$') {
        return [pscustomobject]@{ Kind='DriveLetter'; DriveLetter=$InputPath.ToUpper(); IsoPath=$null }
    }
    if ($InputPath -match '^[a-zA-Z]:\\?$') {
        return [pscustomobject]@{ Kind='DriveLetter'; DriveLetter=$InputPath.Substring(0,1).ToUpper(); IsoPath=$null }
    }
    if ($InputPath -like '*.iso') {
        return [pscustomobject]@{ Kind='IsoFile'; DriveLetter=$null; IsoPath=$InputPath }
    }
    throw "Unrecognized source: '$InputPath'. Expected an .iso file path or a drive letter (E, E:, E:\)."
}

function Get-Tiny11VolumeForImage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $DiskImage)
    $DiskImage | Get-Volume
}

function Mount-Tiny11Source {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InputPath)
    $resolved = Resolve-Tiny11Source -InputPath $InputPath
    if ($resolved.Kind -eq 'DriveLetter') {
        return [pscustomobject]@{ DriveLetter = $resolved.DriveLetter; MountedByUs = $false; IsoPath = $null }
    }
    $img = Mount-DiskImage -ImagePath $resolved.IsoPath -PassThru
    $vol = Get-Tiny11VolumeForImage -DiskImage $img
    if (-not $vol -or -not $vol.DriveLetter) { throw "Mount succeeded but no drive letter assigned to $($resolved.IsoPath)" }
    [pscustomobject]@{ DriveLetter = "$($vol.DriveLetter)"; MountedByUs = $true; IsoPath = $resolved.IsoPath }
}

function Dismount-Tiny11Source {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][bool]$MountedByUs,
        [bool]$ForceUnmount
    )
    if (-not $MountedByUs -and -not $ForceUnmount) { return }
    if (-not $IsoPath) { return }
    $existing = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Attached) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
}

function Get-Tiny11Editions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)
    $wim = "${DriveLetter}:\sources\install.wim"
    $esd = "${DriveLetter}:\sources\install.esd"
    $imgPath = if (Test-Path $wim) { $wim } elseif (Test-Path $esd) { $esd } else {
        throw "Drive ${DriveLetter}: does not contain sources\install.wim or install.esd"
    }
    Get-WindowsImage -ImagePath $imgPath
}

Export-ModuleMember -Function Resolve-Tiny11Source, Mount-Tiny11Source, Dismount-Tiny11Source, Get-Tiny11Editions, Get-Tiny11VolumeForImage
