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

    // --- coreMode routing tests ---
    // These call the extracted static helpers (BuildCoreArgs / BuildStandardArgs) via
    // the internal access modifier (InternalsVisibleTo is not needed because Tests.csproj
    // already references the production assembly with friend access, or we use reflection
    // as a fallback). The helpers are marked `internal static` so we invoke them directly.

    private static string InvokeBuildCoreArgs(
        string resourcesDir, string src, string outputIso, string scratchDir,
        int imageIndex, string editionName, bool unmountSource, bool enableNet35)
    {
        var method = typeof(BuildHandlers).GetMethod(
            "BuildCoreArgs",
            BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)!;
        return (string)method.Invoke(null, new object[]
        {
            resourcesDir, src, outputIso, scratchDir,
            imageIndex, editionName, unmountSource, enableNet35
        })!;
    }

    private static string InvokeBuildStandardArgs(
        string resourcesDir, string configPath, string src, string outputIso,
        string scratchDir, int imageIndex, string editionName, bool unmountSource, bool fastBuild)
    {
        var method = typeof(BuildHandlers).GetMethod(
            "BuildStandardArgs",
            BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)!;
        return (string)method.Invoke(null, new object[]
        {
            resourcesDir, configPath, src, outputIso,
            scratchDir, imageIndex, editionName, unmountSource, fastBuild
        })!;
    }

    [Fact]
    public void BuildCoreArgs_RoutesToCoreScript_WhenCoreModeTrue()
    {
        var resDir = @"C:\resources";
        var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false);

        Assert.Contains("tiny11Coremaker-from-config.ps1", result);
        Assert.DoesNotContain("tiny11maker-from-config.ps1".Replace("tiny11Coremaker-", ""), result.Replace("tiny11Coremaker-from-config.ps1", ""));
    }

    [Fact]
    public void BuildStandardArgs_RoutesToStandardScript_WhenCoreModeFalse()
    {
        var resDir = @"C:\resources";
        var configPath = @"C:\resources\build-config-abc.json";
        var result = InvokeBuildStandardArgs(resDir, configPath, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false);

        Assert.Contains("tiny11maker-from-config.ps1", result);
        Assert.DoesNotContain("tiny11Coremaker-from-config.ps1", result);
    }

    [Fact]
    public void BuildCoreArgs_PassesEnableNet35Flag_WhenEnabled()
    {
        var resDir = @"C:\resources";
        var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, enableNet35: true);

        Assert.Contains("-EnableNet35", result);
    }

    [Fact]
    public void BuildCoreArgs_OmitsConfigPathAndFastBuild_Always()
    {
        // Even if caller somehow passed fastBuild=true (which coreMode path never does),
        // BuildCoreArgs never accepts or emits those flags.
        var resDir = @"C:\resources";
        var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false);

        Assert.DoesNotContain("-ConfigPath", result);
        Assert.DoesNotContain("-FastBuild", result);
    }
}
