Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Actions.psm1"        -Force -Global -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Hives.psm1"          -Force -Global -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Iso.psm1"            -Force -Global -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Autounattend.psm1"   -Force -Global -DisableNameChecking

function Get-Tiny11ApplyItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Catalog, [Parameter(Mandatory)][hashtable]$ResolvedSelections)
    $Catalog.Items | Where-Object { $ResolvedSelections[$_.id].EffectiveState -eq 'apply' }
}

function Invoke-Tiny11ApplyActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][hashtable]$ResolvedSelections,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][scriptblock]$ProgressCallback
    )
    $items = Get-Tiny11ApplyItems -Catalog $Catalog -ResolvedSelections $ResolvedSelections
    $total = $items.Count; $i = 0
    foreach ($item in $items) {
        $i++
        $displayName = if ($item -is [hashtable]) { $item['displayName'] } elseif ($item.PSObject.Properties['displayName']) { $item.displayName } else { $item.id }
        & $ProgressCallback @{ phase='apply'; step="$i of $total : $displayName"; percent=([int](($i / [math]::Max(1,$total)) * 100)); itemId=$item.id }
        foreach ($action in $item.actions) { Invoke-Tiny11Action -Action $action -ScratchDir $ScratchDir }
    }
}

function Invoke-Tiny11BuildPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][bool]$UnmountSource,
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][hashtable]$ResolvedSelections,
        [Parameter(Mandatory)][scriptblock]$ProgressCallback,
        [Parameter()]$CancellationToken = $null
    )

    function CheckCancel { if ($CancellationToken -and $CancellationToken.IsCancellationRequested) { throw "Build cancelled by user" } }

    $progress = { param($p) & $ProgressCallback $p }
    & $progress @{ phase='start'; step='Mounting source'; percent=0 }

    $source = Mount-Tiny11Source -InputPath $Source
    try {
        $sourceRoot = "$($source.DriveLetter):\"
        if (-not (Test-Path "$sourceRoot\sources\install.wim") -and -not (Test-Path "$sourceRoot\sources\install.esd")) {
            throw "No install.wim or install.esd at $sourceRoot\sources"
        }
        CheckCancel

        & $progress @{ phase='copy'; step='Copying ISO contents'; percent=5 }
        $tinyDir = Join-Path $ScratchDir 'tiny11'
        $scratchImg = Join-Path $ScratchDir 'scratchdir'
        New-Item -ItemType Directory -Force -Path "$tinyDir\sources" | Out-Null
        New-Item -ItemType Directory -Force -Path $scratchImg | Out-Null
        Copy-Item -Path "$sourceRoot*" -Destination $tinyDir -Recurse -Force | Out-Null
        CheckCancel

        if ((Test-Path "$tinyDir\sources\install.esd") -and -not (Test-Path "$tinyDir\sources\install.wim")) {
            & $progress @{ phase='convert'; step='Converting install.esd -> install.wim'; percent=10 }
            Export-WindowsImage -SourceImagePath "$tinyDir\sources\install.esd" -SourceIndex $ImageIndex -DestinationImagePath "$tinyDir\sources\install.wim" -CompressionType Maximum -CheckIntegrity | Out-Null
            Remove-Item "$tinyDir\sources\install.esd" -Force | Out-Null
        }
        CheckCancel

        & $progress @{ phase='mount'; step='Mounting install.wim'; percent=15 }
        Set-ItemProperty -Path "$tinyDir\sources\install.wim" -Name IsReadOnly -Value $false
        Mount-WindowsImage -ImagePath "$tinyDir\sources\install.wim" -Index $ImageIndex -Path $scratchImg | Out-Null

        & $progress @{ phase='hives'; step='Loading offline registry hives'; percent=20 }
        Mount-Tiny11AllHives -ScratchDir $scratchImg

        Invoke-Tiny11ApplyActions -Catalog $Catalog -ResolvedSelections $ResolvedSelections -ScratchDir $scratchImg -ProgressCallback $ProgressCallback
        CheckCancel

        & $progress @{ phase='hives-unload'; step='Unloading hives'; percent=70 }
        Dismount-Tiny11AllHives

        & $progress @{ phase='cleanup-image'; step='dism /Cleanup-Image /StartComponentCleanup /ResetBase'; percent=75 }
        & 'dism.exe' "/Image:$scratchImg" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' | Out-Null

        & $progress @{ phase='wim-save'; step='Dismounting install.wim (save)'; percent=80 }
        Dismount-WindowsImage -Path $scratchImg -Save | Out-Null

        & $progress @{ phase='export'; step='Exporting install.wim with recovery compression'; percent=85 }
        & 'dism.exe' '/Export-Image' "/SourceImageFile:$tinyDir\sources\install.wim" "/SourceIndex:$ImageIndex" "/DestinationImageFile:$tinyDir\sources\install2.wim" '/Compress:recovery' | Out-Null
        Remove-Item -Path "$tinyDir\sources\install.wim" -Force | Out-Null
        Rename-Item -Path "$tinyDir\sources\install2.wim" -NewName 'install.wim' | Out-Null

        & $progress @{ phase='bootwim'; step='Applying hardware-bypass tweaks to boot.wim'; percent=88 }
        $bootWim = "$tinyDir\sources\boot.wim"
        Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false
        Mount-WindowsImage -ImagePath $bootWim -Index 2 -Path $scratchImg | Out-Null
        Mount-Tiny11AllHives -ScratchDir $scratchImg
        $hwItems = $Catalog.Items | Where-Object { $_.category -eq 'hardware-bypass' -and $ResolvedSelections[$_.id].EffectiveState -eq 'apply' }
        foreach ($item in $hwItems) {
            foreach ($action in $item.actions) { Invoke-Tiny11Action -Action $action -ScratchDir $scratchImg }
        }
        Dismount-Tiny11AllHives
        Dismount-WindowsImage -Path $scratchImg -Save | Out-Null

        & $progress @{ phase='autounattend'; step='Rendering autounattend.xml'; percent=92 }
        $tplLocal = Join-Path (Split-Path $Catalog.Path) '..\autounattend.template.xml' | Resolve-Path | Select-Object -ExpandProperty Path
        $tplResult = Get-Tiny11AutounattendTemplate -LocalPath $tplLocal
        $bindings = Get-Tiny11AutounattendBindings -ResolvedSelections $ResolvedSelections -ImageIndex $ImageIndex
        $rendered = Render-Tiny11Autounattend -Template $tplResult.Content -Bindings $bindings
        Set-Content -Path "$tinyDir\autounattend.xml" -Value $rendered -Encoding UTF8

        & $progress @{ phase='oscdimg-resolve'; step='Resolving oscdimg.exe'; percent=94 }
        $oscdimgCache = Join-Path (Split-Path $Catalog.Path) '..\dependencies\oscdimg' | Resolve-Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path
        if (-not $oscdimgCache) {
            $oscdimgCache = (New-Item -ItemType Directory -Force -Path (Join-Path $ScratchDir 'oscdimg-cache')).FullName
        }
        $oscdimg = Resolve-Tiny11Oscdimg -CacheDir $oscdimgCache

        & $progress @{ phase='iso'; step='Building ISO'; percent=96 }
        & $oscdimg '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$tinyDir\boot\etfsboot.com#pEF,e,b$tinyDir\efi\microsoft\boot\efisys.bin" $tinyDir $OutputPath | Out-Null

        & $progress @{ phase='complete'; step='Build complete'; percent=100; outputPath=$OutputPath }
    } finally {
        if ($source.MountedByUs -and $UnmountSource) {
            & $progress @{ phase='unmount-source'; step='Unmounting source ISO'; percent=99 }
            Dismount-Tiny11Source -IsoPath $source.IsoPath -MountedByUs:$source.MountedByUs -ForceUnmount:$UnmountSource
        }
        $tinyDir = Join-Path $ScratchDir 'tiny11'
        $scratchImg = Join-Path $ScratchDir 'scratchdir'
        if (Test-Path $tinyDir)    { Remove-Item -Path $tinyDir    -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $scratchImg) { Remove-Item -Path $scratchImg -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-Tiny11Oscdimg {
    [CmdletBinding()]
    param([string]$CacheDir)
    $hostArch = $env:PROCESSOR_ARCHITECTURE
    $adkPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArch\Oscdimg\oscdimg.exe"
    if (Test-Path $adkPath) { return $adkPath }
    if (-not $CacheDir) { return $null }
    $local = Join-Path $CacheDir 'oscdimg.exe'
    if (Test-Path $local) { return $local }
    $url = 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe'
    Invoke-WebRequest -Uri $url -OutFile $local
    return $local
}

Export-ModuleMember -Function Get-Tiny11ApplyItems, Invoke-Tiny11ApplyActions, Invoke-Tiny11BuildPipeline, Resolve-Tiny11Oscdimg
