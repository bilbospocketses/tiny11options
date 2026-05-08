using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public interface IFilePicker
{
    string? PickOpen(string? title, string? filter);
    string? PickFolder(string? title);
    string? PickSaveFile(string? title, string? filter, string? defaultName);
}

public class WpfFilePicker : IFilePicker
{
    // PORTED: tiny11maker.ps1:203, 217 (legacy browse-iso + browse-output) —
    // legacy passes (Get-Tiny11WizardWindow) as ShowDialog owner so pickers are
    // anchored to the wizard (correct screen + modal blocking). We use
    // Application.Current.MainWindow which WPF tracks automatically.
    private static Window? OwnerWindow => Application.Current?.MainWindow;

    public string? PickOpen(string? title, string? filter)
    {
        var dlg = new OpenFileDialog { Title = title, Filter = filter ?? "All files|*.*" };
        return dlg.ShowDialog(OwnerWindow) == true ? dlg.FileName : null;
    }

    public string? PickFolder(string? title)
    {
        var dlg = new OpenFolderDialog { Title = title };
        return dlg.ShowDialog(OwnerWindow) == true ? dlg.FolderName : null;
    }

    public string? PickSaveFile(string? title, string? filter, string? defaultName)
    {
        var dlg = new SaveFileDialog { Title = title, Filter = filter ?? "All files|*.*", FileName = defaultName ?? "" };
        return dlg.ShowDialog(OwnerWindow) == true ? dlg.FileName : null;
    }
}

public class BrowseHandlers : IBridgeHandler
{
    private readonly IFilePicker _picker;
    public BrowseHandlers(IFilePicker picker) { _picker = picker; }

    public IEnumerable<string> HandledTypes => new[] { "browse-file", "browse-folder", "browse-save-file" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var context = payload?["context"]?.ToString();
        var title = payload?["title"]?.ToString();
        var filter = payload?["filter"]?.ToString();
        var defaultName = payload?["defaultName"]?.ToString();

        string? path = type switch
        {
            "browse-file" => _picker.PickOpen(title, filter),
            "browse-folder" => _picker.PickFolder(title),
            "browse-save-file" => _picker.PickSaveFile(title, filter, defaultName),
            _ => null,
        };

        var resultPayload = new JsonObject
        {
            ["context"] = context,
            ["path"] = path,
        };
        return Task.FromResult<BridgeMessage?>(new BridgeMessage { Type = "browse-result", Payload = resultPayload });
    }
}
