using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Updates;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class UpdateHandlers : IBridgeHandler
{
    private readonly UpdateNotifier _notifier;
    public UpdateHandlers(UpdateNotifier notifier) { _notifier = notifier; }

    public IEnumerable<string> HandledTypes => new[] { "apply-update" };

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        try
        {
            await _notifier.ApplyAsync();
            return new BridgeMessage { Type = "update-applying", Payload = new JsonObject() };
        }
        catch (System.Exception ex)
        {
            return new BridgeMessage
            {
                Type = "update-error",
                Payload = new JsonObject { ["message"] = ex.Message },
            };
        }
    }
}
