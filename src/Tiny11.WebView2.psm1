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

function Set-Tiny11WizardWindow { param($Window, $WebView) $script:wizardWindow = $Window; $script:wizardWebView = $WebView }
function Get-Tiny11WizardWindow  { $script:wizardWindow }
function Get-Tiny11WizardWebView { $script:wizardWebView }

function Show-Tiny11Wizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UiDir,
        [Parameter(Mandatory)][string]$CatalogJson,
        [Parameter(Mandatory)][hashtable]$MessageHandlers
    )

    if (-not (Test-Tiny11WebView2RuntimeInstalled)) {
        throw "Microsoft Edge WebView2 Runtime is required. On Windows 11 this is preinstalled; on Windows 10 install from https://developer.microsoft.com/microsoft-edge/webview2/."
    }

    $sdk = Test-Tiny11WebView2SdkPresent

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -Path $sdk.CoreDll
    Add-Type -Path $sdk.WpfDll

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;assembly=Microsoft.Web.WebView2.Wpf"
        Title="tiny11options" Width="900" Height="700"
        WindowStartupLocation="CenterScreen"
        MinWidth="700" MinHeight="500">
    <Grid>
        <wv2:WebView2 x:Name="WV"/>
    </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $wv = $window.FindName('WV')
    Set-Tiny11WizardWindow $window $wv

    $userdata = Join-Path $env:LOCALAPPDATA 'tiny11options\webview2-userdata'
    New-Item -ItemType Directory -Path $userdata -Force | Out-Null

    # Register WebMessageReceived on the WPF control BEFORE init. The control queues the subscription
    # and forwards events once CoreWebView2 init completes. Registering inside CoreWebView2InitializationCompleted
    # leaves the handler in a closure context that doesn't reliably wire up when the runspace is busy in ShowDialog.
    $wv.add_WebMessageReceived({
        param($msgSender, $eventArgs)
        try {
            $msg = $eventArgs.WebMessageAsJson | ConvertFrom-Json
            $reply = Invoke-Tiny11BridgeHandler -Registry $MessageHandlers -Message $msg
            if ($reply) {
                $window.Dispatcher.Invoke([action]{ $wv.CoreWebView2.PostWebMessageAsString($reply) })
            }
        } catch {
            $errReply = ConvertTo-Tiny11BridgeMessage -Type 'handler-error' -Payload @{ message = "$_" }
            $window.Dispatcher.Invoke([action]{ $wv.CoreWebView2.PostWebMessageAsString($errReply) })
        }
    }.GetNewClosure())

    # Post-init setup: virtual host mapping, catalog injection, IsWebMessageEnabled defensive set, navigation.
    $wv.add_CoreWebView2InitializationCompleted({
        param($initSender, $initEventArgs)
        if (-not $initEventArgs.IsSuccess) {
            Write-Warning "WebView2 initialization failed: $($initEventArgs.InitializationException)"
            return
        }
        $wv.CoreWebView2.Settings.IsWebMessageEnabled = $true
        $wv.CoreWebView2.SetVirtualHostNameToFolderMapping(
            'ui.tiny11options', $UiDir,
            [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::DenyCors
        )
        $injectScript = "window.__tinyCatalog = $CatalogJson;"
        $wv.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync($injectScript) | Out-Null
        $wv.Source = [Uri]'https://ui.tiny11options/index.html'
    }.GetNewClosure())

    # Defer EnsureCoreWebView2Async until the WPF dispatcher is running (after Loaded fires).
    # Calling it earlier throws "EnsureCoreWebView2Async cannot be used before the application's event loop has started running."
    $window.add_Loaded({
        $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $userdata)
        $coreEnv = $envTask.GetAwaiter().GetResult()
        $wv.EnsureCoreWebView2Async($coreEnv) | Out-Null
    }.GetNewClosure())

    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Get-Tiny11WebView2SdkPath, Test-Tiny11WebView2SdkPresent, Test-Tiny11WebView2RuntimeInstalled, Show-Tiny11Wizard, Set-Tiny11WizardWindow, Get-Tiny11WizardWindow, Get-Tiny11WizardWebView
