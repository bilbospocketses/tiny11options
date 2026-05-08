using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class ProfileHandlers : IBridgeHandler
{
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

    private static async Task<BridgeMessage> SaveAsync(string path, JsonObject? selections)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        // PORTED: tiny11maker.ps1:227 (legacy save-profile-request) — writes
        // {version: 1, selections: <dict>} JSON. The version field is the
        // forward-compat marker; legacy-shipped profiles (v0.1.0/v0.2.0) all
        // carry it and Import-Tiny11Selections / future loaders rely on it
        // to detect schema drift. Path C scaffold dropped version, which would
        // produce profiles that legacy tools refuse to load.
        var doc = new JsonObject
        {
            ["version"] = 1,
            ["selections"] = selections?.DeepClone() ?? new JsonObject(),
        };
        await File.WriteAllTextAsync(path, doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return new BridgeMessage { Type = "profile-saved", Payload = new JsonObject { ["path"] = path } };
    }

    private static async Task<BridgeMessage> LoadAsync(string path)
    {
        if (!File.Exists(path)) return Error($"profile not found: {path}");
        try
        {
            var json = await File.ReadAllTextAsync(path);
            var node = JsonNode.Parse(json) as JsonObject ?? new JsonObject();

            // PORTED: tiny11maker.ps1:236 (legacy load-profile-request) —
            // Import-Tiny11Selections validates against the catalog and rejects
            // unknown shapes. C# can't reach the catalog here without spawning
            // pwsh, so we apply lighter validation: require a non-null
            // `selections` field. The build wrapper's New-Tiny11Selections call
            // is the eventual catalog-validation backstop. Tracked as audit
            // gap — full catalog validation in C# is post-v1.0.0 work.
            var selections = node["selections"]?.AsObject();
            if (selections is null)
            {
                return new BridgeMessage
                {
                    Type = "handler-error",
                    Payload = new JsonObject
                    {
                        ["message"] = $"Profile is missing 'selections' field: {path}",
                    },
                };
            }

            return new BridgeMessage
            {
                Type = "profile-loaded",
                Payload = new JsonObject
                {
                    ["path"] = path,
                    ["selections"] = selections.DeepClone(),
                },
            };
        }
        catch (Exception ex)
        {
            return Error($"profile load failed: {ex.Message}");
        }
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
