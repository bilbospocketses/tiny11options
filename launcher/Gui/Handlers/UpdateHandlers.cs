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

    // request-update-check is the JS-initiated handshake that fires CheckAsync.
    // We need this because PostWebMessageAsString from C# can race with the JS
    // addEventListener registration if fired purely from a NavigationCompleted
    // hook — JS-initiated guarantees the listener exists before the response comes.
    public IEnumerable<string> HandledTypes => new[] { "apply-update", "request-update-check" };

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "request-update-check")
        {
            // Fire-and-forget. CheckAsync swallows its own exceptions and posts
            // update-available / update-error directly through the bridge.
            _ = System.Threading.Tasks.Task.Run(() => _notifier.CheckAsync());
            return null; // no synchronous response
        }

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
