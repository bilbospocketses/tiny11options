using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Tiny11Options.Launcher.Gui.Bridge;

public class BridgeMessage
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "";

    [JsonPropertyName("payload")]
    public JsonObject? Payload { get; set; }
}
