using System.Reflection;
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class CleanupHandlersTests
{
    [Fact]
    public void ForwardJsonLine_RoutesProgressMarker_ViaBridge()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? captured = null;
        bridge.MessageToJs += s => captured = s;

        var ch = new CleanupHandlers(bridge, Path.GetTempPath());
        var fwd = ch.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(ch, new object?[] { "{\"type\":\"cleanup-progress\",\"payload\":{\"step\":\"foo\",\"percent\":42}}" });

        Assert.NotNull(captured);
        var node = JsonNode.Parse(captured!);
        Assert.Equal("cleanup-progress", node?["type"]?.ToString());
        Assert.Equal(42, (int?)node?["payload"]?["percent"]);
    }

    [Fact]
    public void ForwardJsonLine_RoutesCompleteMarker_ViaBridge()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? captured = null;
        bridge.MessageToJs += s => captured = s;

        var ch = new CleanupHandlers(bridge, Path.GetTempPath());
        var fwd = ch.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(ch, new object?[] { "{\"type\":\"cleanup-complete\",\"payload\":{\"message\":\"done\"}}" });

        Assert.NotNull(captured);
        var node = JsonNode.Parse(captured!);
        Assert.Equal("cleanup-complete", node?["type"]?.ToString());
        Assert.Equal("done", node?["payload"]?["message"]?.ToString());
    }

    [Fact]
    public void ForwardJsonLine_RoutesErrorMarker_ViaBridge()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? captured = null;
        bridge.MessageToJs += s => captured = s;

        var ch = new CleanupHandlers(bridge, Path.GetTempPath());
        var fwd = ch.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(ch, new object?[] { "{\"type\":\"cleanup-error\",\"payload\":{\"message\":\"boom\"}}" });

        Assert.NotNull(captured);
        var node = JsonNode.Parse(captured!);
        Assert.Equal("cleanup-error", node?["type"]?.ToString());
        Assert.Equal("boom", node?["payload"]?["message"]?.ToString());
    }

    [Fact]
    public void ForwardJsonLine_IgnoresUnrelatedTypes()
    {
        // build-progress / build-complete / build-error belong to BuildHandlers
        // and must not be re-emitted by CleanupHandlers' forwarder (would cause
        // double-routing and confuse the JS state machine).
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var ch = new CleanupHandlers(bridge, Path.GetTempPath());
        var fwd = ch.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(ch, new object?[] { "{\"type\":\"build-progress\",\"payload\":{}}" });
        fwd.Invoke(ch, new object?[] { "{\"type\":\"some-other-type\",\"payload\":{}}" });

        Assert.False(fired);
    }

    [Fact]
    public void ForwardJsonLine_IgnoresMalformedJson()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var ch = new CleanupHandlers(bridge, Path.GetTempPath());
        var fwd = ch.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(ch, new object?[] { "this is not json" });

        Assert.False(fired);
    }

    [Fact]
    public void BuildCleanupArgs_EmitsExpectedFlags()
    {
        var method = typeof(CleanupHandlers).GetMethod(
            "BuildCleanupArgs",
            BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)!;
        var result = (string)method.Invoke(null, new object[]
        {
            @"C:\resources", @"C:\Temp\scratch\mount", @"C:\Temp\scratch\source", ""
        })!;

        Assert.Contains("tiny11-cancel-cleanup.ps1", result);
        Assert.Contains("-MountDir \"C:\\Temp\\scratch\\mount\"", result);
        Assert.Contains("-SourceDir \"C:\\Temp\\scratch\\source\"", result);
        Assert.Contains("-NoProfile", result);
        Assert.Contains("-ExecutionPolicy Bypass", result);
    }

    [Fact]
    public void BuildCleanupArgs_OmitsOutputIso_WhenEmpty()
    {
        // Cancel/error case: outputIso isn't known yet, so the param must not
        // be emitted (PS script's [string]$OutputIso = '' default takes over).
        var method = typeof(CleanupHandlers).GetMethod(
            "BuildCleanupArgs",
            BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)!;
        var result = (string)method.Invoke(null, new object[]
        {
            @"C:\resources", @"C:\Temp\scratch\mount", @"C:\Temp\scratch\source", ""
        })!;

        Assert.DoesNotContain("-OutputIso", result);
    }

    [Fact]
    public void BuildCleanupArgs_EmitsOutputIso_WhenSupplied()
    {
        // Build-complete cleanup carries the output ISO path so the PS script
        // can refuse to wipe a target containing the deliverable.
        var method = typeof(CleanupHandlers).GetMethod(
            "BuildCleanupArgs",
            BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)!;
        var result = (string)method.Invoke(null, new object[]
        {
            @"C:\resources", @"C:\Temp\scratch\mount", @"C:\Temp\scratch\source", @"D:\out\tiny11.iso"
        })!;

        Assert.Contains("-OutputIso \"D:\\out\\tiny11.iso\"", result);
    }

    [Fact]
    public void HandledTypes_DeclaresStartCleanup()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var ch = new CleanupHandlers(bridge, Path.GetTempPath());

        Assert.Contains("start-cleanup", ch.HandledTypes);
    }

    [Fact]
    public async Task HandleAsync_ReturnsCleanupError_WhenMountDirMissing()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var ch = new CleanupHandlers(bridge, Path.GetTempPath());

        var result = await ch.HandleAsync("start-cleanup", new JsonObject
        {
            ["sourceDir"] = @"C:\some\source"
            // mountDir intentionally omitted
        });

        Assert.NotNull(result);
        Assert.Equal("cleanup-error", result!.Type);
        Assert.Contains("mountDir", result.Payload?["message"]?.ToString() ?? "");
    }
}
