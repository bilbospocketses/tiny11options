using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class WindowHandlers : IBridgeHandler
{
    public IEnumerable<string> HandledTypes => new[] { "close", "open-folder" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "close")
        {
            // PORTED: tiny11maker.ps1:290 (legacy 'close' handler). JS posts this
            // from renderComplete (Close button after build success, app.js:240)
            // and renderBuildError's Close button (app.js:572). Dispatcher.Invoke
            // because the bridge dispatch may be on a Task.Run thread.
            Application.Current?.Dispatcher.Invoke(() =>
                Application.Current?.MainWindow?.Close());
            return Task.FromResult<BridgeMessage?>(null);
        }

        // open-folder — PORTED: tiny11maker.ps1:291-295. Legacy launches explorer.exe
        // pointing at Split-Path $msg.path (the parent dir of the output ISO) so the
        // user can locate the freshly-built file. explorer.exe via system PATH is
        // covered by the tiny11options dependency-policy waiver alongside powershell.exe.
        var path = payload?["path"]?.ToString();
        if (string.IsNullOrEmpty(path))
            return Task.FromResult<BridgeMessage?>(Error("open-folder: path required"));

        var dir = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir))
            return Task.FromResult<BridgeMessage?>(Error($"open-folder: directory does not exist: {dir}"));

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"\"{dir}\"",
                UseShellExecute = false,
            });
        }
        catch (Exception ex)
        {
            return Task.FromResult<BridgeMessage?>(Error($"open-folder failed: {ex.Message}"));
        }

        return Task.FromResult<BridgeMessage?>(null);
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
