using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Handlers;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Subprocess;
using Tiny11Options.Launcher.Gui.Theme;
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

        // Apply an initial title-bar theme based on the system setting BEFORE JS boots.
        // JS will report the actual in-app theme via the `theme-changed` bridge message
        // a moment after WebView2 finishes navigating (~200ms); the system-theme guess
        // bridges the gap so the window doesn't briefly show a default-light title bar
        // on a dark-mode system.
        Loaded += (_, _) => TitleBarThemeApplier.Apply(this, TitleBarThemeApplier.IsSystemDark());
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
                //
                // Outer try/catch: Bridge.DispatchJsonAsync wraps handler dispatch errors
                // internally and returns a handler-error JSON, but anything thrown OUTSIDE
                // that path (Serialize failures inside SendToJs, MessageToJs subscriber
                // throws, WebView2 disposal mid-dispatch) would land here as an unobserved
                // event-handler exception. Surfacing it to JS as handler-error keeps the
                // failure visible instead of disappearing into the WebView2 event pump.
                try
                {
                    string json;
                    try { json = e.WebMessageAsJson; }
                    catch { return; }
                    if (string.IsNullOrEmpty(json)) return;
                    var resp = await _bridge.DispatchJsonAsync(json);
                    if (!string.IsNullOrEmpty(resp)) SendJsonToJs(resp);
                }
                catch (Exception ex)
                {
                    var errJson = System.Text.Json.JsonSerializer.Serialize(new BridgeMessage
                    {
                        Type = "handler-error",
                        Payload = new System.Text.Json.Nodes.JsonObject
                        {
                            ["message"] = $"WebMessageReceived top-level: {ex.GetType().Name}: {ex.Message}",
                        },
                    });
                    SendJsonToJs(errJson);
                }
            };

            // PORTED: Tiny11.WebView2.psm1:173-175 — inject the catalog as a
            // document-created script so window.__tinyCatalog is set before any
            // page script runs. Without this, ui/app.js:68 reads undefined into
            // state.catalog and Step 2 throws on state.catalog.items the moment
            // the user clicks Next. Must fire BEFORE WebView.Source = navigation.
            var catalogPath = Path.Combine(_resourcesDir!, "catalog", "catalog.json");
            var catalogJson = await File.ReadAllTextAsync(catalogPath);
            await WebView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                $"window.__tinyCatalog = {catalogJson};");

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
        // The WebView field is a generated XAML name pointing at a WPF DependencyObject.
        // Touching .CoreWebView2 here is a property access on the DependencyObject which
        // checks thread affinity and throws "The calling thread cannot access this object
        // because a different thread owns it" when called from any non-UI thread (e.g.
        // BuildHandlers' stdout forwarder Task.Run, UpdateNotifier's old async push path,
        // etc). Move the entire property+method-call chain INSIDE Dispatcher.Invoke so
        // the marshal happens before we dereference the DependencyObject.
        Dispatcher.Invoke(() =>
        {
            if (WebView?.CoreWebView2 is null) return;
            WebView.CoreWebView2.PostWebMessageAsString(json);
        });
    }

    private (Bridge bridge, UpdateNotifier notifier) BuildBridge()
    {
        // Construct empty Bridge first so handlers that need a Bridge reference
        // (BuildHandlers, UpdateNotifier) can capture it.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());

        var notifier = new UpdateNotifier(
            new VelopackUpdateSource(GithubRepoForUpdates));

        var pwshRunner = new PwshRunner();

        bridge.Register(new BrowseHandlers(new WpfFilePicker(), _settings));
        bridge.Register(new ProfileHandlers(_settings, pwshRunner, _resourcesDir!));
        bridge.Register(new WindowHandlers());
        // theme-changed routes here from JS initTheme() + theme-toggle click; applies
        // DWMWA_USE_IMMERSIVE_DARK_MODE to the title bar. Distinct from the old
        // ThemeHandlers (deleted 2026-05-08, audit A8) that owned theme state in C#.
        // Callback marshals to UI thread before touching the window handle.
        bridge.Register(new TitleBarThemeHandlers(isDark =>
            Dispatcher.Invoke(() => TitleBarThemeApplier.Apply(this, isDark))));
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
        => ExtractIfManifestChanged(targetDir, n => n.StartsWith("ui/", StringComparison.OrdinalIgnoreCase),
            n => n.Substring("ui/".Length));

    /// Extract PS scripts + modules + catalog + autounattend template to the runtime
    /// resources cache so the GUI handlers (IsoHandlers, BuildHandlers) can spawn pwsh
    /// against on-disk paths. Excludes ui/* — that has its own cache dir.
    private static void ExtractRuntimeResourcesIfNeeded(string targetDir)
        => ExtractIfManifestChanged(targetDir,
            n => !n.StartsWith("ui/", StringComparison.OrdinalIgnoreCase)
                 && !n.Equals("test-fixture.txt", StringComparison.OrdinalIgnoreCase),
            n => n);

    /// Hash-based extraction: marker file contains a SHA256 over the sorted resource-name
    /// list AND each resource's bytes. If the hash matches, skip extraction. If it differs
    /// — new resource added, resource removed, first run, OR existing resource's content
    /// changed — wipe the dir contents and re-extract everything. Content-aware hashing
    /// makes "edit ui/app.js then relaunch" Just Work without a manual cache wipe or a
    /// version bump. The whole `ui/` + `resources/` tree is well under 1 MB; SHA256-ing it
    /// on every launch is single-digit milliseconds, comfortably under perception threshold.
    private static void ExtractIfManifestChanged(string targetDir, Func<string, bool> include, Func<string, string> mapDestRelPath)
    {
        var asm = typeof(MainWindow).Assembly;
        var marker = Path.Combine(targetDir, ".extracted");
        var names = asm.GetManifestResourceNames().Where(include).OrderBy(n => n, StringComparer.Ordinal).ToArray();
        var currentHash = ComputeManifestHash(names, n => asm.GetManifestResourceStream(n));

        if (File.Exists(marker))
        {
            try
            {
                var existing = File.ReadAllText(marker).Trim();
                if (existing == currentHash) return;
            }
            catch { /* fall through to re-extract */ }
        }

        // Stale or missing marker. Wipe everything in targetDir except the marker file
        // (the marker gets rewritten at the end). Best-effort — locked files are skipped
        // and overwritten in the loop below.
        if (Directory.Exists(targetDir))
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(targetDir))
            {
                try
                {
                    if (string.Equals(path, marker, StringComparison.OrdinalIgnoreCase)) continue;
                    if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
                    else File.Delete(path);
                }
                catch { /* best effort */ }
            }
        }
        else
        {
            Directory.CreateDirectory(targetDir);
        }

        foreach (var name in names)
        {
            var relPath = mapDestRelPath(name);
            var dest = Path.Combine(targetDir, relPath);
            var destDir = Path.GetDirectoryName(dest);
            if (!string.IsNullOrEmpty(destDir)) Directory.CreateDirectory(destDir);

            using var stream = asm.GetManifestResourceStream(name)!;
            using var fs = File.Create(dest);
            stream.CopyTo(fs);
        }

        File.WriteAllText(marker, currentHash);
    }

    /// SHA256 over the sorted resource-name list AND each resource's byte stream,
    /// interleaved with NUL separators so a name boundary can't collide with content
    /// bytes (e.g. a file containing the next file's name). Streamed via IncrementalHash
    /// so embedded resources never have to fully materialize in memory.
    /// `openResource` is injected so unit tests can supply MemoryStream-based fakes
    /// without building a real assembly.
    internal static string ComputeManifestHash(string[] sortedNames, Func<string, Stream?> openResource)
    {
        using var sha = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
        var sep = new byte[] { 0 };
        foreach (var name in sortedNames)
        {
            sha.AppendData(System.Text.Encoding.UTF8.GetBytes(name));
            sha.AppendData(sep);
            using var stream = openResource(name);
            if (stream is not null)
            {
                var buf = new byte[8192];
                int read;
                while ((read = stream.Read(buf, 0, buf.Length)) > 0)
                {
                    sha.AppendData(buf, 0, read);
                }
            }
            sha.AppendData(sep);
        }
        return Convert.ToHexString(sha.GetHashAndReset());
    }
}
