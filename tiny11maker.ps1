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
    Edition index inside install.wim (e.g. 6 for Pro on consumer ISO). One of -ImageIndex or -Edition is required in -NonInteractive mode.

.PARAMETER Edition
    Edition name (case-insensitive exact match) e.g. 'Windows 11 Pro'. Resolved to ImageIndex by enumerating the source. Cleaner alternative to -ImageIndex which varies by ISO source.

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
    [string]$Edition,
    [string]$ScratchDir,
    [string]$OutputPath,
    [switch]$NonInteractive,
    [switch]$FastBuild,
    [switch]$Internal
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($mod in @('Tiny11.Catalog','Tiny11.Selections','Tiny11.Hives','Tiny11.Actions','Tiny11.Iso','Tiny11.Autounattend','Tiny11.Worker')) {
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

# Block pwsh-from-pwsh: this combination deterministically produces ISOs that fail Setup product-key validation on Win11 25H2 (mechanism unknown; build output is content-identical to working invocations).
if ($PSVersionTable.PSEdition -eq 'Core') {
    $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
    $parentName = $null
    if ($parentId) {
        $proc = Get-Process -Id $parentId -ErrorAction SilentlyContinue
        if ($proc) { $parentName = $proc.ProcessName }
    }
    if ($parentName -eq 'pwsh') {
        Write-Error @'
pwsh-from-pwsh invocation is not supported. This combination produces ISOs that fail
Setup product-key validation on Windows 11 25H2 (mechanism unknown; build output is
content-identical to working invocations).

Workarounds:
  1. Run from cmd.exe:               cmd /c pwsh -ExecutionPolicy Bypass -NoProfile -File tiny11maker.ps1 [args]
  2. Run from Windows PowerShell:    powershell -ExecutionPolicy Bypass -NoProfile -File tiny11maker.ps1 [args]
  3. Run via tiny11maker.ps1 directly from a cmd.exe or PowerShell 5.1 console.

Path C (post-v1.0.0) will eliminate this caveat via a bundled .exe launcher.
'@
        exit 1
    }
}

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
    if (-not $Source) { throw "-NonInteractive requires -Source" }
    if ($ImageIndex -and $Edition) { throw "-ImageIndex and -Edition are mutually exclusive; pick one." }
    if (-not $ImageIndex -and -not $Edition) { throw "-NonInteractive requires either -ImageIndex or -Edition." }

    # Preflight: enumerate source editions and resolve -Edition to -ImageIndex if needed.
    $preflightMount = Mount-Tiny11Source -InputPath $Source
    try {
        $editions = @(Get-Tiny11Editions -DriveLetter $preflightMount.DriveLetter)
        if ($Edition) {
            $ImageIndex = Resolve-Tiny11ImageIndex -Editions $editions -Edition $Edition
            Write-Output "Resolved -Edition '$Edition' to ImageIndex $ImageIndex."
        }
    } finally {
        if ($preflightMount.MountedByUs) {
            Dismount-Tiny11Source -IsoPath $preflightMount.IsoPath -MountedByUs:$preflightMount.MountedByUs -ForceUnmount:$true
        }
    }

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
        -ProgressCallback { param($p) Write-Output "[$($p.phase)] $($p.step) ($($p.percent)%)" }

    Write-Output "Build complete: $OutputPath"
    exit 0
}

# Interactive (GUI) mode.
Import-Module "$srcDir\Tiny11.WebView2.psm1" -Force -DisableNameChecking
Import-Module "$srcDir\Tiny11.Bridge.psm1"   -Force -DisableNameChecking

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

$state = @{ CancelToken = $null }

$handlers = @{
    'validate-iso' = {
        param($msg)
        try {
            $r = Mount-Tiny11Source -InputPath $msg.path
            $editions = Get-Tiny11Editions -DriveLetter $r.DriveLetter | ForEach-Object {
                @{ index = $_.ImageIndex; name = $_.ImageName }
            }
            Dismount-Tiny11Source -IsoPath $r.IsoPath -MountedByUs:$r.MountedByUs -ForceUnmount:$true
            ConvertTo-Tiny11BridgeMessage -Type 'iso-validated' -Payload @{ editions = $editions; path = $msg.path }
        } catch {
            ConvertTo-Tiny11BridgeMessage -Type 'iso-error' -Payload @{ message = "$_" }
        }
    }
    'browse-iso' = {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'ISO files (*.iso)|*.iso'
        if ($dlg.ShowDialog((Get-Tiny11WizardWindow))) {
            ConvertTo-Tiny11BridgeMessage -Type 'browse-result' -Payload @{ field='source'; path=$dlg.FileName }
        }
    }
    'browse-scratch' = {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') {
            ConvertTo-Tiny11BridgeMessage -Type 'browse-result' -Payload @{ field='scratch'; path=$dlg.SelectedPath }
        }
    }
    'browse-output' = {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'ISO files (*.iso)|*.iso'
        $dlg.FileName = 'tiny11.iso'
        if ($dlg.ShowDialog((Get-Tiny11WizardWindow))) {
            ConvertTo-Tiny11BridgeMessage -Type 'browse-result' -Payload @{ field='output'; path=$dlg.FileName }
        }
    }
    'save-profile-request' = {
        param($msg)
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'tiny11options profile (*.json)|*.json'
        $dlg.InitialDirectory = (Join-Path $PSScriptRoot 'config\examples')
        if ($dlg.ShowDialog((Get-Tiny11WizardWindow))) {
            $payload = [ordered]@{ version = 1; selections = $msg.selections } | ConvertTo-Json -Depth 5
            Set-Content -Path $dlg.FileName -Value $payload -Encoding UTF8
            ConvertTo-Tiny11BridgeMessage -Type 'profile-saved' -Payload @{ path = $dlg.FileName }
        }
    }
    'load-profile-request' = {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'tiny11options profile (*.json)|*.json'
        if ($dlg.ShowDialog((Get-Tiny11WizardWindow))) {
            $sel = Import-Tiny11Selections -Path $dlg.FileName -Catalog $catalog
            $obj = @{}
            foreach ($k in $sel.Keys) { $obj[$k] = $sel[$k].State }
            ConvertTo-Tiny11BridgeMessage -Type 'profile-loaded' -Payload @{ selections = $obj }
        }
    }
    'build' = {
        param($msg)
        $state.CancelToken = [System.Threading.CancellationTokenSource]::new()
        $overrides = @{}
        foreach ($k in $msg.selections.PSObject.Properties.Name) { $overrides[$k] = $msg.selections.$k }
        $sel = New-Tiny11Selections -Catalog $catalog -Overrides $overrides
        $resolved = Resolve-Tiny11Selections -Catalog $catalog -Selections $sel

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('__catalog', $catalog)
        $rs.SessionStateProxy.SetVariable('__resolved', $resolved)
        $rs.SessionStateProxy.SetVariable('__msg', $msg)
        $rs.SessionStateProxy.SetVariable('__token', $state.CancelToken.Token)
        $rs.SessionStateProxy.SetVariable('__window', (Get-Tiny11WizardWindow))
        $rs.SessionStateProxy.SetVariable('__wv', (Get-Tiny11WizardWebView))
        $rs.SessionStateProxy.SetVariable('__src', $PSScriptRoot)

        $psWorker = [PowerShell]::Create()
        $psWorker.Runspace = $rs
        $psWorker.AddScript({
            Import-Module "$__src\src\Tiny11.Worker.psm1" -Force -DisableNameChecking
            Import-Module "$__src\src\Tiny11.Bridge.psm1" -Force -DisableNameChecking
            $cb = {
                param($p)
                $j = ConvertTo-Tiny11BridgeMessage -Type 'build-progress' -Payload $p
                $__window.Dispatcher.Invoke([action]{ $__wv.CoreWebView2.PostWebMessageAsString($j) })
            }
            try {
                $scratch = if ($__msg.scratchDir) { $__msg.scratchDir } else { $__src }
                Invoke-Tiny11BuildPipeline `
                    -Source $__msg.source -ImageIndex $__msg.imageIndex `
                    -ScratchDir $scratch -OutputPath $__msg.outputPath `
                    -UnmountSource ([bool]$__msg.unmountSource) `
                    -FastBuild ([bool]$__msg.fastBuild) `
                    -Catalog $__catalog -ResolvedSelections $__resolved `
                    -ProgressCallback $cb -CancellationToken $__token
                $j = ConvertTo-Tiny11BridgeMessage -Type 'build-complete' -Payload @{ outputPath = $__msg.outputPath }
                $__window.Dispatcher.Invoke([action]{ $__wv.CoreWebView2.PostWebMessageAsString($j) })
            } catch {
                $j = ConvertTo-Tiny11BridgeMessage -Type 'build-error' -Payload @{ message = "$_" }
                $__window.Dispatcher.Invoke([action]{ $__wv.CoreWebView2.PostWebMessageAsString($j) })
            }
        }) | Out-Null
        $psWorker.BeginInvoke() | Out-Null
        $null
    }
    'cancel'      = { if ($state.CancelToken) { $state.CancelToken.Cancel() }; $null }
    'close'       = { (Get-Tiny11WizardWindow).Close(); $null }
    'open-folder' = {
        param($msg)
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Split-Path $msg.path)
        $null
    }
}

$catalogJson = Get-Content (Join-Path $PSScriptRoot 'catalog\catalog.json') -Raw

Show-Tiny11Wizard -UiDir (Join-Path $PSScriptRoot 'ui') -CatalogJson $catalogJson -MessageHandlers $handlers

exit 0
