# verify-p9-static.ps1 -- P9 keep-list smoke verification (static arm).
#
# Purpose:
#   Empirically prove the cleanup-task generator scoped its output to apply-only
#   items by reading the actual tiny11-cleanup.ps1 baked into a built ISO and
#   asserting it does NOT contain references to the items the user chose to
#   keep. Stronger evidence than any runtime check -- if the code isn't in the
#   script, the script CANNOT touch the kept items, period.
#
# Usage (run elevated on the build host):
#   .\verify-p9-static.ps1 -IsoPath C:\Temp\p9-worker-keeplist.iso
#
#   ... or, if you've already extracted the cleanup script:
#   .\verify-p9-static.ps1 -CleanupScriptPath C:\path\to\tiny11-cleanup.ps1
#
# Default forbidden patterns match the P9 build (Edge + Clipchamp KEPT).
# Override via -ForbiddenPatterns for future keep-list smokes.
#
# Exit codes:
#   0 -- zero forbidden matches AND non-zero control matches (script is properly
#        scoped to apply-only items and is non-empty).
#   1 -- at least one forbidden match OR all control matches missing.

[CmdletBinding(DefaultParameterSetName = 'FromIso')]
param(
    [Parameter(ParameterSetName = 'FromIso', Mandatory)]
    [string] $IsoPath,

    [Parameter(ParameterSetName = 'FromExtracted', Mandatory)]
    [string] $CleanupScriptPath,

    # Edition selection -- which install.wim image to mount. By default the script
    # AUTO-TARGETS the index that autounattend.xml installs (FastBuild modifies
    # only that index; the rest are pristine source editions with no baked
    # cleanup script). Precedence: -ImageIndex (explicit) > explicit -ImageEdition
    # > autounattend.xml /IMAGE/INDEX > the -ImageEdition default below.
    [string] $ImageEdition = 'Windows 11 Pro',

    [int] $ImageIndex = 0,

    [string[]] $ForbiddenPatterns = @(
        # Filesystem paths from catalog `remove-edge` and `remove-edge-webview`.
        # Use 'Program Files (x86)\Microsoft\Edge\b' (word boundary) rather than
        # the bare 'Microsoft\Edge' to avoid false-positives on legitimate uses
        # like `HKLM\SOFTWARE\Policies\Microsoft\Edge!HubsSidebarEnabled` -- the
        # Copilot Edge sidebar policy from `tweak-disable-copilot` which is
        # APPLY in keep-Edge builds.
        'Clipchamp\.Clipchamp',
        'Program Files \(x86\)\\Microsoft\\Edge\b',
        'Program Files \(x86\)\\Microsoft\\EdgeUpdate\b',
        'Program Files \(x86\)\\Microsoft\\EdgeCore\b',
        'System32\\Microsoft-Edge-Webview',
        'Uninstall\\Microsoft Edge'
    ),

    [string[]] $ControlPatterns = @(
        'Microsoft\.BingNews',
        'Microsoft\.Copilot',
        'MSTeams',
        'Microsoft\.XboxApp',
        'Microsoft\.WindowsTerminal'
    )
)

$ErrorActionPreference = 'Stop'

# Resolve the script content -- either from an extracted file or by mounting the ISO.
function Get-CleanupScriptFromIso {
    param([string] $Iso)

    if (-not (Test-Path -LiteralPath $Iso)) {
        throw "ISO not found: $Iso"
    }

    # 1. Mount the ISO as a virtual drive.
    Write-Host "  Mounting ISO: $Iso"
    $mountResult = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $driveLetter = ($mountResult | Get-Volume).DriveLetter
        if (-not $driveLetter) {
            throw "ISO mount succeeded but no drive letter assigned"
        }
        Write-Host "  ISO mounted at $($driveLetter):\"

        # 2. Find install.wim inside the ISO.
        $installWim = Join-Path "$($driveLetter):\" 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $installWim)) {
            throw "install.wim not found at $installWim"
        }

        # 3. Pick the image to mount. FastBuild keeps every source edition in
        # install.wim but modifies ONLY the build-targeted index (the one
        # autounattend.xml installs); the rest are pristine and carry no baked
        # tiny11-cleanup.ps1. So auto-target the autounattend index. Precedence:
        #   1. -ImageIndex (explicit)         2. explicit -ImageEdition
        #   3. autounattend.xml /IMAGE/INDEX  4. -ImageEdition default
        # (The old name-match-only default picked Pro=idx 6 and threw on a Home
        # build whose autounattend installs idx 1 -- the only modified index.)
        $images = Get-WindowsImage -ImagePath $installWim

        # Read the build-targeted index straight from the ISO's answer file.
        $autoIdx = $null
        foreach ($name in 'autounattend.xml', 'Autounattend.xml', 'AutoUnattend.xml') {
            $au = Join-Path "$($driveLetter):\" $name
            if (Test-Path -LiteralPath $au) {
                $m = [regex]::Match((Get-Content -LiteralPath $au -Raw), '(?is)/IMAGE/INDEX\s*</Key>\s*<Value>\s*([0-9]+)')
                if ($m.Success) { $autoIdx = [int]$m.Groups[1].Value }
                break
            }
        }

        $avail = ($images | ForEach-Object { '  ' + $_.ImageIndex + ': ' + $_.ImageName } | Out-String)
        if ($ImageIndex -gt 0) {
            $targetIdx = $ImageIndex
            $matchedName = ($images | Where-Object ImageIndex -eq $targetIdx).ImageName
            if (-not $matchedName) { throw "ImageIndex $ImageIndex not present in install.wim. Available:`n$avail" }
        } elseif ($PSBoundParameters.ContainsKey('ImageEdition')) {
            $matched = $images | Where-Object ImageName -eq $ImageEdition
            if (-not $matched) { throw "No image with ImageName='$ImageEdition' in install.wim. Available:`n$avail`nPass -ImageEdition or -ImageIndex to override." }
            $targetIdx = $matched.ImageIndex
            $matchedName = $matched.ImageName
        } elseif ($null -ne $autoIdx) {
            $targetIdx = $autoIdx
            $matchedName = ($images | Where-Object ImageIndex -eq $targetIdx).ImageName
            if (-not $matchedName) { throw "autounattend.xml targets index $autoIdx but install.wim has no such index. Available:`n$avail" }
            Write-Host "  autounattend.xml installs index $autoIdx -- auto-targeting it"
        } else {
            $matched = $images | Where-Object ImageName -eq $ImageEdition
            if (-not $matched) { throw "No image with ImageName='$ImageEdition' in install.wim, and no autounattend.xml /IMAGE/INDEX found. Available:`n$avail`nPass -ImageEdition or -ImageIndex to override." }
            $targetIdx = $matched.ImageIndex
            $matchedName = $matched.ImageName
        }
        Write-Host "  install.wim contains $($images.Count) image(s); using index $targetIdx ($matchedName)"

        # 4. Mount install.wim ReadOnly to a temp dir.
        $wimMount = Join-Path $env:TEMP "verify-p9-wim-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $wimMount -Force | Out-Null
        try {
            Write-Host "  Mounting install.wim index $targetIdx ReadOnly to $wimMount ..."
            Mount-WindowsImage -ImagePath $installWim -Index $targetIdx -Path $wimMount -ReadOnly | Out-Null

            $scriptPath = Join-Path $wimMount 'Windows\Setup\Scripts\tiny11-cleanup.ps1'
            if (-not (Test-Path -LiteralPath $scriptPath)) {
                throw "tiny11-cleanup.ps1 not found at expected path inside install.wim: $scriptPath"
            }

            $content = Get-Content -LiteralPath $scriptPath -Raw
            return $content
        }
        finally {
            Write-Host "  Unmounting install.wim ..."
            Dismount-WindowsImage -Path $wimMount -Discard -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $wimMount -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    finally {
        Write-Host "  Dismounting ISO ..."
        Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-Host ''
Write-Host 'P9 keep-list smoke verification (static arm)'
Write-Host '============================================='

if ($PSCmdlet.ParameterSetName -eq 'FromIso') {
    $content = Get-CleanupScriptFromIso -Iso $IsoPath
    $source  = "install.wim extract from $IsoPath"
} else {
    if (-not (Test-Path -LiteralPath $CleanupScriptPath)) {
        throw "Cleanup script not found: $CleanupScriptPath"
    }
    $content = Get-Content -LiteralPath $CleanupScriptPath -Raw
    $source  = $CleanupScriptPath
}

Write-Host ''
Write-Host "Script source: $source"
Write-Host "Script length: $($content.Length) bytes, $((($content -split "`r?`n").Count)) lines"
Write-Host ''

$failures = New-Object System.Collections.Generic.List[string]

# --- Arm A: forbidden patterns must be ABSENT ---
Write-Host "[1/2] $($ForbiddenPatterns.Count) forbidden patterns must be ABSENT (kept items) ..."
foreach ($pat in $ForbiddenPatterns) {
    $matches = [regex]::Matches($content, $pat)
    if ($matches.Count -eq 0) {
        Write-Host "      OK   '$pat' -- 0 matches" -ForegroundColor Green
    } else {
        Write-Host "      FAIL '$pat' -- $($matches.Count) matches (cleanup script references a kept item)" -ForegroundColor Red
        $failures.Add("forbidden pattern '$pat' matched $($matches.Count) time(s) -- generator scoping is broken")
    }
}

# --- Arm B: control patterns must be PRESENT ---
Write-Host ''
Write-Host "[2/2] $($ControlPatterns.Count) control patterns must be PRESENT (script not empty) ..."
foreach ($pat in $ControlPatterns) {
    $matches = [regex]::Matches($content, $pat)
    if ($matches.Count -gt 0) {
        Write-Host "      OK   '$pat' -- $($matches.Count) matches" -ForegroundColor Green
    } else {
        Write-Host "      FAIL '$pat' -- 0 matches (script may be empty or missing apply-state items)" -ForegroundColor Red
        $failures.Add("control pattern '$pat' missing -- generator may have emitted an empty script")
    }
}

# --- Summary ---
Write-Host ''
Write-Host 'Summary:'
Write-Host '--------'
if ($failures.Count -eq 0) {
    Write-Host '  PASS -- generator scoping holds.' -ForegroundColor Green
    Write-Host "         Zero forbidden (kept-item) matches; $($ControlPatterns.Count) control patterns all present."
    Write-Host ''
    exit 0
} else {
    Write-Host "  FAIL -- $($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" }
    Write-Host ''
    exit 1
}
