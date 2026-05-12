using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Bridge;

public interface IBridgeHandler
{
    IEnumerable<string> HandledTypes { get; }
    Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload);
}
