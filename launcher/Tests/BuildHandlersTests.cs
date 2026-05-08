using System.Reflection;
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BuildHandlersTests
{
    [Fact]
    public void ForwardJsonLine_RoutesProgressMarkers_ViaBridge()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? captured = null;
        bridge.MessageToJs += s => captured = s;

        var bh = new BuildHandlers(bridge, Path.GetTempPath());
        var fwd = bh.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(bh, new object?[] { "{\"type\":\"build-progress\",\"payload\":{\"phase\":\"foo\",\"step\":\"bar\",\"percent\":42}}" });

        Assert.NotNull(captured);
        var node = JsonNode.Parse(captured!);
        Assert.Equal("build-progress", node?["type"]?.ToString());
        Assert.Equal(42, (int?)node?["payload"]?["percent"]);
    }

    [Fact]
    public void ForwardJsonLine_IgnoresNonJsonLines()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var bh = new BuildHandlers(bridge, Path.GetTempPath());
        var fwd = bh.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(bh, new object?[] { "this is just a log line, not JSON" });

        Assert.False(fired);
    }
}
