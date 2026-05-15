Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Actions.psm1"        -Force -Global -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Hives.psm1"          -Force -Global -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Iso.psm1"            -Force -Global -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.Autounattend.psm1"   -Force -Global -DisableNameChecking
Import-Module "$PSScriptRoot/Tiny11.PostBoot.psm1"       -Force -Global -DisableNameChecking

# A11/v1.0.3: Get-Tiny11ApplyItems and Invoke-Tiny11ApplyActions moved to
# Tiny11.Actions.psm1 (their natural home alongside the Invoke-Tiny11Action
# dispatcher). Both Worker and Core build pipelines now share the same
# catalog-iteration helpers via that module.

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
        [Parameter()]$CancellationToken = $null,
        [Parameter()][bool]$FastBuild = $false,
        [Parameter()][bool]$InstallPostBootCleanup = $true
    )

    function CheckCancel { if ($CancellationToken -and $CancellationToken.IsCancellationRequested) { throw "Build cancelled by user" } }

    $progress = { param($p) & $ProgressCallback $p }
    & $progress @{ phase='start'; step='Mounting source'; percent=0 }

    $mountResult = Mount-Tiny11Source -InputPath $Source
    try {
        $sourceRoot = "$($mountResult.DriveLetter):\"
        if (-not (Test-Path "$sourceRoot\sources\install.wim") -and -not (Test-Path "$sourceRoot\sources\install.esd")) {
            throw "No install.wim or install.esd at $sourceRoot\sources"
        }
        CheckCancel

        & $progress @{ phase='copy'; step='Copying ISO contents (robocopy /MT:8)'; percent=5 }
        $tinyDir = Join-Path $ScratchDir 'tiny11'
        $scratchImg = Join-Path $ScratchDir 'scratchdir'
        New-Item -ItemType Directory -Force -Path "$tinyDir\sources" | Out-Null
        New-Item -ItemType Directory -Force -Path $scratchImg | Out-Null
        & 'robocopy.exe' $sourceRoot.TrimEnd('\') $tinyDir '/MIR' '/MT:8' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' '/NS' '/NC' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE) copying $sourceRoot to $tinyDir" }
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
        # mount-state marker for the UI cleanup button. Worker layout differs from Core:
        # mount dir is <scratch>\scratchdir (not \mount), copied source is <scratch>\tiny11 (not \source).
        & $progress @{ phase='mount-state'; step="install.wim mounted at $scratchImg"; percent=16; mountActive=$true; mountDir=$scratchImg; sourceDir=$tinyDir }

        # B6/B7: commit-on-success / discard-on-failure wrapper for the install.wim mount
        # window. Mirrors Core's $pipelineSucceeded pattern (Tiny11.Core.psm1). If any
        # step between Mount-WindowsImage and Install-Tiny11PostBootCleanup throws
        # (B7's phase context comes from the most-recent `& $progress` marker), the
        # finally branch unmounts with -Discard so we never commit a partially-mutated
        # install.wim. Pre-fix, an Install throw left the WIM mounted with no
        # Dismount-WindowsImage call in any outer finally -- the outer scratch-dir
        # cleanup ran first and the abandoned mount survived until reboot.
        $installPipelineSucceeded = $false
        try {
            & $progress @{ phase='autounattend-render'; step='Rendering autounattend.xml'; percent=18 }
            $tplLocal = Join-Path (Split-Path $Catalog.Path) '..\autounattend.template.xml' | Resolve-Path | Select-Object -ExpandProperty Path
            $tplResult = Get-Tiny11AutounattendTemplate -LocalPath $tplLocal
            $bindings = Get-Tiny11AutounattendBindings -ResolvedSelections $ResolvedSelections -ImageIndex $ImageIndex
            $renderedAutounattend = Render-Tiny11Autounattend -Template $tplResult.Content -Bindings $bindings

            & $progress @{ phase='autounattend-sysprep'; step='Injecting autounattend.xml into install.wim Sysprep'; percent=19 }
            $sysprepDir = Join-Path $scratchImg 'Windows\System32\Sysprep'
            New-Item -ItemType Directory -Force -Path $sysprepDir | Out-Null
            Set-Content -Path (Join-Path $sysprepDir 'autounattend.xml') -Value $renderedAutounattend -Encoding UTF8

            & $progress @{ phase='hives'; step='Loading offline registry hives'; percent=20 }
            Mount-Tiny11AllHives -ScratchDir $scratchImg

            Invoke-Tiny11ApplyActions -Catalog $Catalog -ResolvedSelections $ResolvedSelections -ScratchDir $scratchImg -ProgressCallback $ProgressCallback
            CheckCancel

            & $progress @{ phase='hives-unload'; step='Unloading hives'; percent=70 }
            Dismount-Tiny11AllHives

            if ($FastBuild) {
                & $progress @{ phase='cleanup-image-skip'; step='Skipping /Cleanup-Image (FastBuild)'; percent=75 }
            } else {
                & $progress @{ phase='cleanup-image'; step='dism /Cleanup-Image /StartComponentCleanup /ResetBase'; percent=75 }
                & 'dism.exe' "/Image:$scratchImg" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' | Out-Null
            }

            & $progress @{ phase='inject-postboot-cleanup'; step='Installing post-boot cleanup task'; percent=78 }
            Install-Tiny11PostBootCleanup -MountDir $scratchImg -Catalog $Catalog -ResolvedSelections $ResolvedSelections -Enabled:$InstallPostBootCleanup

            $installPipelineSucceeded = $true
        }
        finally {
            $dismountVerb = if ($installPipelineSucceeded) { 'save' } else { 'discard' }
            & $progress @{ phase='wim-save'; step="Dismounting install.wim ($dismountVerb)"; percent=80 }
            try {
                if ($installPipelineSucceeded) {
                    Dismount-WindowsImage -Path $scratchImg -Save | Out-Null
                } else {
                    Dismount-WindowsImage -Path $scratchImg -Discard | Out-Null
                }
            } catch {
                # Finally-context: only re-throw if pipeline succeeded (no in-flight exception to replace).
                # On the failure path we Write-Warning so the original cause is preserved.
                if ($installPipelineSucceeded) { throw }
                Write-Warning "Dismount-WindowsImage -Discard (install.wim) failed during cleanup: $($_.Exception.Message)"
            }
            & $progress @{ phase='mount-state'; step="install.wim unmounted ($dismountVerb)"; percent=81; mountActive=$false }
        }

        if (-not $installPipelineSucceeded) {
            throw 'Worker build pipeline failed mid-flight (see preceding error). install.wim unmounted with /Discard.'
        }

        if ($FastBuild) {
            & $progress @{ phase='export-skip'; step='Skipping /Export-Image recovery compression (FastBuild)'; percent=85 }
        } else {
            & $progress @{ phase='export'; step='Exporting install.wim with recovery compression'; percent=85 }
            & 'dism.exe' '/Export-Image' "/SourceImageFile:$tinyDir\sources\install.wim" "/SourceIndex:$ImageIndex" "/DestinationImageFile:$tinyDir\sources\install2.wim" '/Compress:recovery' | Out-Null
            Remove-Item -Path "$tinyDir\sources\install.wim" -Force | Out-Null
            Rename-Item -Path "$tinyDir\sources\install2.wim" -NewName 'install.wim' | Out-Null
        }

        & $progress @{ phase='bootwim'; step='Applying hardware-bypass tweaks to boot.wim'; percent=88 }
        $bootWim = "$tinyDir\sources\boot.wim"
        Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false
        Mount-WindowsImage -ImagePath $bootWim -Index 2 -Path $scratchImg | Out-Null
        & $progress @{ phase='mount-state'; step="boot.wim mounted at $scratchImg"; percent=89; mountActive=$true; mountDir=$scratchImg; sourceDir=$tinyDir }
        # B6-class structural sibling for boot.wim. Before this wrap, a throw
        # inside Mount-Tiny11AllHives / Invoke-Tiny11Action / Dismount-Tiny11AllHives
        # left boot.wim mounted with no Dismount-WindowsImage call -- identical
        # failure mode to the install.wim B6 fix on the block above. Smaller
        # blast radius (boot.wim is only touched by hardware-bypass catalog
        # items) but worth closing for structural consistency. Hive cleanup
        # follows the install.wim convention: best-effort on the success path,
        # left for next-run recovery on the failure path.
        $bootPipelineSucceeded = $false
        try {
            Mount-Tiny11AllHives -ScratchDir $scratchImg
            $hwItems = $Catalog.Items | Where-Object { $_.category -eq 'hardware-bypass' -and $ResolvedSelections[$_.id].EffectiveState -eq 'apply' }
            foreach ($item in $hwItems) {
                foreach ($action in $item.actions) { Invoke-Tiny11Action -Action $action -ScratchDir $scratchImg }
            }
            Dismount-Tiny11AllHives
            $bootPipelineSucceeded = $true
        }
        finally {
            $dismountVerb = if ($bootPipelineSucceeded) { 'save' } else { 'discard' }
            & $progress @{ phase='bootwim-save'; step="Dismounting boot.wim ($dismountVerb)"; percent=90 }
            try {
                if ($bootPipelineSucceeded) {
                    Dismount-WindowsImage -Path $scratchImg -Save | Out-Null
                } else {
                    Dismount-WindowsImage -Path $scratchImg -Discard | Out-Null
                }
            } catch {
                if ($bootPipelineSucceeded) { throw }
                Write-Warning "Dismount-WindowsImage -Discard (boot.wim) failed during cleanup: $($_.Exception.Message)"
            }
            & $progress @{ phase='mount-state'; step="boot.wim unmounted ($dismountVerb)"; percent=91; mountActive=$false }
        }
        if (-not $bootPipelineSucceeded) {
            throw 'Worker boot.wim pipeline failed mid-flight (see preceding error). boot.wim unmounted with /Discard.'
        }

        & $progress @{ phase='autounattend-iso'; step='Writing autounattend.xml to ISO root'; percent=92 }
        Set-Content -Path "$tinyDir\autounattend.xml" -Value $renderedAutounattend -Encoding UTF8

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
        if ($mountResult.MountedByUs -and $UnmountSource) {
            & $progress @{ phase='unmount-source'; step='Unmounting source ISO'; percent=99 }
            Dismount-Tiny11Source -IsoPath $mountResult.IsoPath -MountedByUs:$mountResult.MountedByUs -ForceUnmount:$UnmountSource
        }
        # v1.0.8 audit WARNING ps-modules A6: track and surface scratch-cleanup
        # failures instead of silently swallowing via -EA SilentlyContinue.
        # Locked files (robocopy delete-on-close shares; in-flight handles) leave
        # stale partial trees that confuse subsequent builds. Lock release
        # typically happens on next reboot.
        $tinyDir = Join-Path $ScratchDir 'tiny11'
        $scratchImg = Join-Path $ScratchDir 'scratchdir'
        $cleanupFailures = @()
        foreach ($path in @($tinyDir, $scratchImg)) {
            if (Test-Path $path) {
                try { Remove-Item -Path $path -Recurse -Force -ErrorAction Stop }
                catch { $cleanupFailures += $path }
            }
        }
        if ($cleanupFailures.Count -gt 0) {
            & $progress @{
                phase   = 'cleanup-warn'
                step    = "Some scratch files could not be deleted (rmdir-locked): $($cleanupFailures -join '; '). Lock release typically happens at next reboot; the next build's cleanup will retry."
                percent = 100
            }
        }
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

Export-ModuleMember -Function Invoke-Tiny11BuildPipeline, Resolve-Tiny11Oscdimg
