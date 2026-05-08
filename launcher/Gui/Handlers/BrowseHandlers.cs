using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Settings;

namespace Tiny11Options.Launcher.Gui.Handlers;

public interface IFilePicker
{
    string? PickOpen(string? title, string? filter, string? initialDir);
    string? PickFolder(string? title, string? initialDir);
    string? PickSaveFile(string? title, string? filter, string? defaultName, string? initialDir);
}

public class WpfFilePicker : IFilePicker
{
    // PORTED: tiny11maker.ps1:203, 217 (legacy browse-iso + browse-output) —
    // legacy passes (Get-Tiny11WizardWindow) as ShowDialog owner so pickers are
    // anchored to the wizard (correct screen + modal blocking). We use
    // Application.Current.MainWindow which WPF tracks automatically.
    private static Window? OwnerWindow => Application.Current?.MainWindow;

    public string? PickOpen(string? title, string? filter, string? initialDir)
    {
        var dlg = new OpenFileDialog { Title = title, Filter = filter ?? "All files|*.*" };
        if (!string.IsNullOrEmpty(initialDir) && Directory.Exists(initialDir))
            dlg.InitialDirectory = initialDir;
        return dlg.ShowDialog(OwnerWindow) == true ? dlg.FileName : null;
    }

    public string? PickFolder(string? title, string? initialDir)
    {
        var dlg = new OpenFolderDialog { Title = title };
        if (!string.IsNullOrEmpty(initialDir) && Directory.Exists(initialDir))
            dlg.InitialDirectory = initialDir;
        return dlg.ShowDialog(OwnerWindow) == true ? dlg.FolderName : null;
    }

    public string? PickSaveFile(string? title, string? filter, string? defaultName, string? initialDir)
    {
        var dlg = new SaveFileDialog { Title = title, Filter = filter ?? "All files|*.*", FileName = defaultName ?? "" };
        if (!string.IsNullOrEmpty(initialDir) && Directory.Exists(initialDir))
            dlg.InitialDirectory = initialDir;
        return dlg.ShowDialog(OwnerWindow) == true ? dlg.FileName : null;
    }
}

public class BrowseHandlers : IBridgeHandler
{
    private readonly IFilePicker _picker;
    private readonly UserSettings _settings;

    public BrowseHandlers(IFilePicker picker, UserSettings settings)
    {
        _picker = picker;
        _settings = settings;
    }

    public IEnumerable<string> HandledTypes => new[] { "browse-file", "browse-folder", "browse-save-file" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var context = payload?["context"]?.ToString();
        var title = payload?["title"]?.ToString();
        var filter = payload?["filter"]?.ToString();
        var defaultName = payload?["defaultName"]?.ToString();

        // Initial-directory resolution: explicit JS payload wins; otherwise context
        // drives a sensible default. Profile contexts remember the user's last
        // location via UserSettings.LastProfilePath; everything else gets no default
        // (matches legacy interactive handlers' behavior at tiny11maker.ps1:200-220
        // which set InitialDirectory only for save-profile-request).
        var initialDir = payload?["initialDir"]?.ToString();
        if (string.IsNullOrEmpty(initialDir))
            initialDir = ResolveDefaultInitialDir(context);

        string? path = type switch
        {
            "browse-file" => _picker.PickOpen(title, filter, initialDir),
            "browse-folder" => _picker.PickFolder(title, initialDir),
            "browse-save-file" => _picker.PickSaveFile(title, filter, defaultName, initialDir),
            _ => null,
        };

        var resultPayload = new JsonObject
        {
            ["context"] = context,
            ["path"] = path,
        };
        return Task.FromResult<BridgeMessage?>(new BridgeMessage { Type = "browse-result", Payload = resultPayload });
    }

    private string? ResolveDefaultInitialDir(string? context)
    {
        if (context is "profile-save" or "profile-load")
        {
            if (!string.IsNullOrEmpty(_settings.LastProfilePath))
            {
                var dir = Path.GetDirectoryName(_settings.LastProfilePath);
                if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir)) return dir;
            }
            return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        }
        return null;
    }
}
