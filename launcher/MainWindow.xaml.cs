using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Handlers;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Subprocess;
using Tiny11Options.Launcher.Gui.Updates;

namespace Tiny11Options.Launcher;

public partial class MainWindow : Window
{
    // GitHub repo URL Velopack queries for update manifests. Velopack's GithubSource
    // ctor calls new Uri(repoUrl) and enforces Host == "github.com" — must be a full
    // https URL, NOT a "owner/repo" slug.
    private const string GithubRepoForUpdates = "https://github.com/bilbospocketses/tiny11options";

    private string? _uiCacheDir;
    private string? _resourcesDir;
    private readonly UserSettings _settings;
    private Bridge? _bridge;
    private UpdateNotifier? _updateNotifier;

    public MainWindow()
    {
        // Theme handling is JS-owned (localStorage 'tiny11-theme' in
        // ui/app.js + CSS data-theme attribute). C# does not coordinate.
        // _settings.Theme field is retained for back-compat with old
        // settings.json files but no longer consumed.
        _settings = UserSettings.Load();
        InitializeComponent();
        Width = _settings.WindowWidth;
        Height = _settings.WindowHeight;

        Closing += (_, _) =>
        {
            _settings.WindowWidth = (int)Width;
            _settings.WindowHeight = (int)Height;
            _settings.Save();
        };

        Loaded += async (_, _) => await InitializeWebViewAsync();
    }

    private async System.Threading.Tasks.Task InitializeWebViewAsync()
    {
        try
        {
            _uiCacheDir = ResolveUiCacheDir();
            ExtractUiResourcesIfNeeded(_uiCacheDir);

            _resourcesDir = ResolveResourcesDir();
            ExtractRuntimeResourcesIfNeeded(_resourcesDir);

            var userDataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "tiny11options", "webview2-userdata");
            Directory.CreateDirectory(userDataDir);

            var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            await WebView.EnsureCoreWebView2Async(env);

            WebView.CoreWebView2.SetVirtualHostNameToFolderMapping(
                "app.local",
                _uiCacheDir,
                CoreWebView2HostResourceAccessKind.Allow);

            WebView.CoreWebView2.Settings.IsWebMessageEnabled = true;

            (_bridge, _updateNotifier) = BuildBridge();
            _bridge.MessageToJs += SendJsonToJs;
            WebView.CoreWebView2.WebMessageReceived += async (_, e) =>
            {
                // JS calls window.chrome.webview.postMessage(<object>) — WebMessageAsJson
                // gives us the serialized JSON. TryGetWebMessageAsString throws if the JS
                // side didn't pre-stringify, which it doesn't. JS passing the object is
                // idiomatic and round-trips cleanly through WebView2's serializer.
                string json;
                try { json = e.WebMessageAsJson; }
                catch { return; }
                if (string.IsNullOrEmpty(json)) return;
                var resp = await _bridge.DispatchJsonAsync(json);
                if (!string.IsNullOrEmpty(resp)) SendJsonToJs(resp);
            };

            WebView.Source = new Uri("http://app.local/index.html");
            // No post-navigation update-check fire here — JS sends `request-update-check`
            // on its DOMContentLoaded, UpdateHandlers receives that and triggers
            // _updateNotifier.CheckAsync. JS-initiated handshake guarantees the JS-side
            // chrome.webview message listener is registered before update-available
            // is posted. Avoids the WebView2 race where PostWebMessageAsString lands
            // before addEventListener is wired.
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"WebView2 Runtime is required but could not be initialized.\n\n{ex.Message}\n\n" +
                "Install from https://developer.microsoft.com/microsoft-edge/webview2/",
                "tiny11options",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Close();
        }
    }

    private void SendJsonToJs(string json)
    {
        if (WebView?.CoreWebView2 is null) return;
        Dispatcher.Invoke(() => WebView.CoreWebView2.PostWebMessageAsString(json));
    }

    private (Bridge bridge, UpdateNotifier notifier) BuildBridge()
    {
        // Construct empty Bridge first so handlers that need a Bridge reference
        // (BuildHandlers, UpdateNotifier) can capture it.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());

        var notifier = new UpdateNotifier(
            new VelopackUpdateSource(GithubRepoForUpdates),
            bridge);

        var pwshRunner = new PwshRunner();

        bridge.Register(new BrowseHandlers(new WpfFilePicker()));
        bridge.Register(new ProfileHandlers());
        // SelectionHandlers + reconcile-selections type intentionally not
        // registered — JS does its own client-side reconcile() at app.js:249
        // mirroring Tiny11.Selections.psm1 skip-cascade semantics. C# handler
        // was scaffolded with inverted (apply-cascade) semantics and never
        // wired from JS. Audit 2026-05-08 confirmed dead code; deleted.
        bridge.Register(new IsoHandlers(pwshRunner, _resourcesDir!));
        // ThemeHandlers + apply-theme/get-theme types intentionally not
        // registered — JS owns theme via localStorage. Audit 2026-05-08.
        bridge.Register(new BuildHandlers(bridge, _resourcesDir!));
        bridge.Register(new UpdateHandlers(notifier));

        return (bridge, notifier);
    }

    private static string ResolveUiCacheDir()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "dev";
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tiny11options", "ui-cache", version);
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string ResolveResourcesDir()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "dev";
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tiny11options", "resources-cache", version);
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static void ExtractUiResourcesIfNeeded(string targetDir)
    {
        var marker = Path.Combine(targetDir, ".extracted");
        if (File.Exists(marker)) return;

        var asm = typeof(MainWindow).Assembly;
        foreach (var name in asm.GetManifestResourceNames())
        {
            if (!name.StartsWith("ui/", StringComparison.OrdinalIgnoreCase)) continue;

            var relPath = name.Substring("ui/".Length);
            var dest = Path.Combine(targetDir, relPath);
            var destDir = Path.GetDirectoryName(dest);
            if (!string.IsNullOrEmpty(destDir)) Directory.CreateDirectory(destDir);

            using var stream = asm.GetManifestResourceStream(name)!;
            using var fs = File.Create(dest);
            stream.CopyTo(fs);
        }

        File.WriteAllText(marker, "");
    }

    /// Extract PS scripts + modules + catalog + autounattend template to the runtime
    /// resources cache so the GUI handlers (IsoHandlers, BuildHandlers) can spawn pwsh
    /// against on-disk paths. Excludes ui/* — that has its own cache dir.
    private static void ExtractRuntimeResourcesIfNeeded(string targetDir)
    {
        var marker = Path.Combine(targetDir, ".extracted");
        if (File.Exists(marker)) return;

        var asm = typeof(MainWindow).Assembly;
        foreach (var name in asm.GetManifestResourceNames())
        {
            if (name.StartsWith("ui/", StringComparison.OrdinalIgnoreCase)) continue;
            if (name.Equals("test-fixture.txt", StringComparison.OrdinalIgnoreCase)) continue;

            var dest = Path.Combine(targetDir, name);
            var destDir = Path.GetDirectoryName(dest);
            if (!string.IsNullOrEmpty(destDir)) Directory.CreateDirectory(destDir);

            using var stream = asm.GetManifestResourceStream(name)!;
            using var fs = File.Create(dest);
            stream.CopyTo(fs);
        }

        File.WriteAllText(marker, "");
    }
}
