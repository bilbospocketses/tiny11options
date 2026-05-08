using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Settings;

namespace Tiny11Options.Launcher;

public partial class MainWindow : Window
{
    private string? _uiCacheDir;
    private readonly UserSettings _settings;
    private Bridge? _bridge;

    public MainWindow()
    {
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

            _bridge = BuildBridge();
            _bridge.MessageToJs += SendJsonToJs;
            WebView.CoreWebView2.WebMessageReceived += async (_, e) =>
            {
                var json = e.TryGetWebMessageAsString();
                if (string.IsNullOrEmpty(json)) return;
                var resp = await _bridge.DispatchJsonAsync(json);
                if (!string.IsNullOrEmpty(resp)) SendJsonToJs(resp);
            };

            WebView.Source = new Uri("http://app.local/index.html");
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

    private Bridge BuildBridge()
    {
        // Handlers are registered as Tasks 16-22 land. Empty for now means JS calls
        // get a 'handler-error: Unknown message type' response.
        var handlers = new List<IBridgeHandler>();
        return new Bridge(handlers);
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
}
