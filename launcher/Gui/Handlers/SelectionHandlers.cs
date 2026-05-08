using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Catalog;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class SelectionHandlers : IBridgeHandler
{
    public IEnumerable<string> HandledTypes => new[] { "reconcile-selections" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var catalogJson = payload?["catalog"]?.ToJsonString();
        if (string.IsNullOrEmpty(catalogJson))
            return Task.FromResult<BridgeMessage?>(Error("catalog required"));

        var catalog = JsonSerializer.Deserialize<global::Tiny11Options.Launcher.Gui.Catalog.Catalog>(catalogJson) ?? new global::Tiny11Options.Launcher.Gui.Catalog.Catalog();

        var selected = (payload?["selected"]?.AsArray() ?? new JsonArray())
            .Select(n => n!.ToString())
            .ToHashSet();

        var byId = catalog.Items.ToDictionary(i => i.Id);

        // Always include locked items
        foreach (var item in catalog.Items.Where(i => i.Locked))
            selected.Add(item.Id);

        // Iteratively add runtime deps (transitive)
        bool changed;
        do
        {
            changed = false;
            foreach (var id in selected.ToList())
            {
                if (!byId.TryGetValue(id, out var item)) continue;
                foreach (var dep in item.RuntimeDepsOn ?? new List<string>())
                {
                    if (selected.Add(dep)) changed = true;
                }
            }
        } while (changed);

        var resultArr = new JsonArray();
        foreach (var id in selected) resultArr.Add(id);

        return Task.FromResult<BridgeMessage?>(new Bridge.BridgeMessage
        {
            Type = "selections-reconciled",
            Payload = new JsonObject { ["effective"] = resultArr },
        });
    }

    private static Bridge.BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
