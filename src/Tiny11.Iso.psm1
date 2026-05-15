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
    # v1.0.8 audit WARNING ps-modules A1: poll for drive-letter assignment
    # with 100ms increments up to ~5s ceiling. Mount-DiskImage -PassThru
    # returns as soon as the kernel reports the image attached, but the
    # SCSI bus rescan + drive-letter assignment happens asynchronously.
    # On a busy box, an immediate Get-Volume can return a null DriveLetter.
    $vol = $null
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $vol = Get-Tiny11VolumeForImage -DiskImage $img
        if ($vol -and $vol.DriveLetter) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if (-not $vol -or -not $vol.DriveLetter) {
        throw "Mount succeeded but no drive letter assigned to $($resolved.IsoPath) within 5 seconds"
    }
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

function Resolve-Tiny11ImageIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Editions,
        [Parameter(Mandatory)][string]$Edition
    )
    $list = @($Editions)
    $match = @($list | Where-Object { $_.ImageName -ieq $Edition })
    if ($match.Count -eq 0) {
        $known = ($list | ForEach-Object { "$($_.ImageName) (index $($_.ImageIndex))" }) -join '; '
        throw "Edition '$Edition' not found in source. Available editions: $known"
    }
    if ($match.Count -gt 1) {
        throw "Edition '$Edition' matched multiple images (case-insensitive). Use -ImageIndex with the specific index instead."
    }
    [int]$match[0].ImageIndex
}

Export-ModuleMember -Function Resolve-Tiny11Source, Mount-Tiny11Source, Dismount-Tiny11Source, Get-Tiny11Editions, Get-Tiny11VolumeForImage, Resolve-Tiny11ImageIndex
