<#
.SYNOPSIS
    tiny11options — interactive variant builder for Windows 11.

.DESCRIPTION
    Builds a customized Windows 11 ISO. Each removable component and tweak is a
    catalog item; the user selects which to apply. Two modes:
      Interactive: tiny11maker.ps1            (launches GUI)
      Scripted:    tiny11maker.ps1 -Source X.iso -Config profile.json [-OutputPath ...]

.PARAMETER Source
    Path to a Windows 11 .iso file, or a drive letter for an already-mounted ISO/DVD.

.PARAMETER Config
    Path to a selection profile JSON. If omitted in interactive mode, GUI runs;
    if omitted in -NonInteractive mode, defaults are used.

.PARAMETER ImageIndex
    Edition index inside install.wim (e.g. 6 for Pro). Required in -NonInteractive mode.

.PARAMETER ScratchDir
    Working directory; needs ~10 GB free. Defaults to $PSScriptRoot.

.PARAMETER OutputPath
    Where to write the resulting ISO. Defaults to <ScratchDir>\tiny11.iso.

.PARAMETER NonInteractive
    Suppresses the GUI. Implied if both -Source and -Config are passed.

.PARAMETER Internal
    For testing — when set, the script defines functions and exits without running the orchestrator.
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Config,
    [int]$ImageIndex,
    [string]$ScratchDir,
    [string]$OutputPath,
    [switch]$NonInteractive,
    [switch]$FastBuild,
    [switch]$NoProductKey,
    [switch]$Internal
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($mod in @('Tiny11.Catalog','Tiny11.Selections','Tiny11.Hives','Tiny11.Actions','Tiny11.Iso','Tiny11.Autounattend','Tiny11.GenericKeys','Tiny11.Worker')) {
    Import-Module "$srcDir\$mod.psm1" -Force -DisableNameChecking
}

function Build-RelaunchArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Bound, [Parameter(Mandatory)][string]$ScriptPath)
    $parts = @("-NoProfile","-File","`"$ScriptPath`"")
    foreach ($entry in $Bound.GetEnumerator()) {
        if ($entry.Key -eq 'Internal') { continue }
        $val = $entry.Value
        if ($val -is [switch]) {
            if ($val.IsPresent) { $parts += "-$($entry.Key)" }
        } else {
            $parts += "-$($entry.Key)"
            $parts += "`"$val`""
        }
    }
    $parts -join ' '
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    param([Parameter(Mandatory)] $Bound)
    $argString = Build-RelaunchArgs -Bound $Bound -ScriptPath $PSCommandPath
    $pwshPath = (Get-Process -Id $PID).Path
    Write-Output "Restarting tiny11options as admin..."
    Start-Process -FilePath $pwshPath -ArgumentList $argString -Verb RunAs
}

if ($Internal) { return }

if (-not (Test-IsAdmin)) {
    Invoke-SelfElevate -Bound $PSBoundParameters
    exit
}

if (-not $ScratchDir) { $ScratchDir = $PSScriptRoot }
if (-not $OutputPath) { $OutputPath = Join-Path $ScratchDir 'tiny11.iso' }
$catalogPath = Join-Path $PSScriptRoot 'catalog\catalog.json'
$catalog = Get-Tiny11Catalog -Path $catalogPath

$nonInteractive = $NonInteractive -or ($Source -and $Config)

if ($nonInteractive) {
    if (-not $Source)     { throw "-NonInteractive requires -Source" }
    if (-not $ImageIndex) { throw "-NonInteractive requires -ImageIndex" }

    $selections = if ($Config) {
        Import-Tiny11Selections -Path $Config -Catalog $catalog
    } else {
        New-Tiny11Selections -Catalog $catalog
    }
    $resolved = Resolve-Tiny11Selections -Catalog $catalog -Selections $selections

    Invoke-Tiny11BuildPipeline `
        -Source $Source -ImageIndex $ImageIndex -ScratchDir $ScratchDir `
        -OutputPath $OutputPath -UnmountSource $true `
        -Catalog $catalog -ResolvedSelections $resolved `
        -FastBuild ([bool]$FastBuild) `
        -NoProductKey ([bool]$NoProductKey) `
        -ProgressCallback { param($p) Write-Output "[$($p.phase)] $($p.step) ($($p.percent)%)" }

    Write-Output "Build complete: $OutputPath"
    exit 0
}

Write-Warning "Interactive GUI not implemented yet (Phase 2). Use -Source -Config -ImageIndex for scripted mode, or wait for Phase 2."
exit 1
