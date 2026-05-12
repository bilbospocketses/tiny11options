using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Subprocess;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class ProfileHandlers : IBridgeHandler
{
    private readonly UserSettings _settings;
    private readonly PwshRunner _runner;
    private readonly string _resourcesDir;

    public ProfileHandlers(UserSettings settings, PwshRunner runner, string resourcesDir)
    {
        _settings = settings;
        _runner = runner;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "save-profile", "load-profile" };

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var path = payload?["path"]?.ToString();
        if (string.IsNullOrEmpty(path))
            return Error("path required");

        return type switch
        {
            "save-profile" => await SaveAsync(path, payload!["selections"]?.AsObject()),
            "load-profile" => await LoadAsync(path),
            _ => Error($"unknown type {type}"),
        };
    }

    private async Task<BridgeMessage> SaveAsync(string path, JsonObject? selections)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        // PORTED: tiny11maker.ps1:227 (legacy save-profile-request) — writes
        // {version: 1, selections: <dict>} JSON. The version field is the
        // forward-compat marker; legacy-shipped profiles (v0.1.0/v0.2.0) all
        // carry it and Import-Tiny11Selections / future loaders rely on it
        // to detect schema drift.
        var doc = new JsonObject
        {
            ["version"] = 1,
            ["selections"] = selections?.DeepClone() ?? new JsonObject(),
        };
        await File.WriteAllTextAsync(path, doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

        // Persist last-used path so the next save/load dialog opens here.
        _settings.LastProfilePath = path;
        TrySaveSettings();

        return new BridgeMessage { Type = "profile-saved", Payload = new JsonObject { ["path"] = path } };
    }

    private async Task<BridgeMessage> LoadAsync(string path)
    {
        if (!File.Exists(path)) return Error($"profile not found: {path}");

        // PORTED: tiny11maker.ps1:236 (legacy load-profile-request) —
        // Import-Tiny11Selections validates against the catalog (rejects unknown
        // item IDs and invalid 'apply'/'skip' values) before returning. Path C
        // delegates to the PS validator via tiny11-profile-validate.ps1 rather
        // than reimplementing the catalog walker in C#: keeps validation logic
        // single-sourced in Tiny11.Selections.psm1 / Tiny11.Catalog.psm1.
        var script = Path.Combine(_resourcesDir, "tiny11-profile-validate.ps1");
        var result = await _runner.RunAsync(script, new[] { "-ProfilePath", path }, _resourcesDir);

        // The script writes a structured JSON object to STDOUT in BOTH branches:
        //   success: {"ok": true,  "selections": {<id>: <state>, ...}}
        //   failure: {"ok": false, "message": "..."}
        // Parse stdout first; only fall back to stderr/exit-code text if stdout
        // isn't parseable (script crashed before writing JSON).
        JsonObject? parsed = null;
        try { parsed = JsonNode.Parse(result.Stdout.Trim()) as JsonObject; }
        catch { /* fall through */ }

        if (parsed is not null)
        {
            var ok = parsed["ok"]?.GetValue<bool>() ?? false;
            if (ok)
            {
                _settings.LastProfilePath = path;
                TrySaveSettings();

                return new BridgeMessage
                {
                    Type = "profile-loaded",
                    Payload = new JsonObject
                    {
                        ["path"] = path,
                        ["selections"] = parsed["selections"]?.DeepClone() ?? new JsonObject(),
                    },
                };
            }

            return Error(parsed["message"]?.ToString() ?? "Profile validation failed (no message)");
        }

        var fallback =
            !string.IsNullOrWhiteSpace(result.Stderr) ? result.Stderr.Trim() :
            !string.IsNullOrWhiteSpace(result.Stdout) ? result.Stdout.Trim() :
            $"Profile validator failed with exit code {result.ExitCode} and no output";
        return Error(fallback);
    }

    private void TrySaveSettings()
    {
        // Settings persistence is best-effort; a save failure must never break
        // a successful profile save/load. The MainWindow.Closing handler will
        // also flush settings on next close.
        try { _settings.Save(); } catch { /* swallowed by design */ }
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
