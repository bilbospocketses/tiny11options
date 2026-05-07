Set-StrictMode -Version Latest

$PinnedVersion = '1.0.2535.41'

function Get-Tiny11WebView2SdkPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $verDir = Join-Path $RepoRoot "dependencies\webview2\$PinnedVersion"
    [pscustomobject]@{
        VersionDir = $verDir
        CoreDll    = Join-Path $verDir 'Microsoft.Web.WebView2.Core.dll'
        WpfDll     = Join-Path $verDir 'Microsoft.Web.WebView2.Wpf.dll'
        NativeDll  = Join-Path $verDir 'WebView2Loader.dll'
    }
}

function Test-Tiny11WebView2SdkPresent {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $resolveArgs = @{}
    if ($RepoRoot) { $resolveArgs.RepoRoot = $RepoRoot }
    $paths = Get-Tiny11WebView2SdkPath @resolveArgs
    foreach ($p in @($paths.CoreDll, $paths.WpfDll, $paths.NativeDll)) {
        if (-not (Test-Path $p)) {
            throw "WebView2 SDK DLL missing: $p. Expected vendored at $($paths.VersionDir). The repo ships these DLLs under dependencies/webview2/$PinnedVersion/."
        }
    }
    $paths
}

function Test-Tiny11WebView2RuntimeInstalled {
    $key64   = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $key32   = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $userKey = 'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach ($k in @($key64, $key32, $userKey)) {
        if (Test-Path $k) {
            $item = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
            if ($item -and $item.PSObject.Properties['pv'] -and $item.pv) { return $true }
        }
    }
    $false
}

Export-ModuleMember -Function Get-Tiny11WebView2SdkPath, Test-Tiny11WebView2SdkPresent, Test-Tiny11WebView2RuntimeInstalled
