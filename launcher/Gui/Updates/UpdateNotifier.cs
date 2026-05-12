using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Updates;

public class UpdateNotifier
{
    private readonly IUpdateSource _source;
    public UpdateInfo? PendingUpdate { get; private set; }

    public UpdateNotifier(IUpdateSource source)
    {
        _source = source;
    }

    // Pull-based: returns the BridgeMessage instead of pushing via Bridge.SendToJs.
    // UpdateHandlers routes the return value through DispatchJsonAsync's response
    // path (the same path validate-iso uses). Avoids the async-push delivery race
    // where a Task.Run-driven SendToJs could reach the JS listener before
    // addEventListener had registered.
    public async Task<Bridge.BridgeMessage?> CheckAsync()
    {
        var info = await _source.CheckAsync();
        if (info is null) return null;
        PendingUpdate = info;
        return new Bridge.BridgeMessage
        {
            Type = "update-available",
            Payload = new JsonObject
            {
                ["version"] = info.Version,
                ["changelog"] = info.Changelog,
            },
        };
    }

    public Task ApplyAsync() => _source.ApplyAndRestartAsync();
}
