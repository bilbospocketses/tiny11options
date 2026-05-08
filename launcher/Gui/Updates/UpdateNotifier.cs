using System;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Updates;

public class UpdateNotifier
{
    private readonly IUpdateSource _source;
    private readonly Bridge.Bridge _bridge;
    public UpdateInfo? PendingUpdate { get; private set; }

    public UpdateNotifier(IUpdateSource source, Bridge.Bridge bridge)
    {
        _source = source;
        _bridge = bridge;
    }

    public async Task CheckAsync()
    {
        try
        {
            var info = await _source.CheckAsync();
            if (info is null) return;
            PendingUpdate = info;
            _bridge.SendToJs(new Bridge.BridgeMessage
            {
                Type = "update-available",
                Payload = new JsonObject
                {
                    ["version"] = info.Version,
                    ["changelog"] = info.Changelog,
                },
            });
        }
        catch
        {
            // Silent — network down, GitHub 503, etc.
        }
    }

    public Task ApplyAsync() => _source.ApplyAndRestartAsync();
}
