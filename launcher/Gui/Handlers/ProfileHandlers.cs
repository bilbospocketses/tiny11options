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

        var doc = new JsonObject { ["selections"] = selections?.DeepClone() ?? new JsonObject() };
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
            return new BridgeMessage
            {
                Type = "profile-loaded",
                Payload = new JsonObject
                {
                    ["path"] = path,
                    ["selections"] = node["selections"]?.DeepClone() ?? new JsonObject(),
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
