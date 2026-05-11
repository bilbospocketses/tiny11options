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
        int imageIndex, string editionName, bool unmountSource, bool enableNet35,
        bool fastBuild = false)
    {
        var method = typeof(BuildHandlers).GetMethod(
            "BuildCoreArgs",
            BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)!;
        return (string)method.Invoke(null, new object[]
        {
            resourcesDir, src, outputIso, scratchDir,
            imageIndex, editionName, unmountSource, enableNet35, fastBuild
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
    public async Task CancelBuild_SetsTerminalMarkerSeen_ToSuppressStderrFallback()
    {
        // Regression: without _terminalMarkerSeen=true on cancel, the stderr-
        // fallback Task fires "Build process exited with code -1 and no output"
        // after Process.Kill, overwriting the friendly "Build cancelled by user."
        // message in JS (each build-error clears and re-renders).
        //
        // No _activeBuild is set, so HandleAsync skips the Kill call and the
        // stderr-fallback Task isn't spawned -- but the _terminalMarkerSeen flag
        // assignment still runs. Probe it via reflection.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var bh = new BuildHandlers(bridge, Path.GetTempPath());

        await bh.HandleAsync("cancel-build", new JsonObject());

        var flag = (bool)bh.GetType()
            .GetField("_terminalMarkerSeen", BindingFlags.Instance | BindingFlags.NonPublic)!
            .GetValue(bh)!;
        Assert.True(flag, "_terminalMarkerSeen must be true after cancel-build to suppress the stderr-fallback duplicate build-error.");
    }

    [Fact]
    public void BuildCoreArgs_OmitsConfigPath_Always()
    {
        // Core mode has no catalog and so no -ConfigPath, regardless of any other flag.
        var resDir = @"C:\resources";
        var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false);

        Assert.DoesNotContain("-ConfigPath", result);
    }

    [Fact]
    public void BuildCoreArgs_PassesFastBuildFlag_WhenEnabled()
    {
        // As of 2026-05-11, Fast Build is supported in Core mode (Phase 20 /Compress:max
        // and Phase 22 /Compress:recovery skip when -FastBuild is set).
        var resDir = @"C:\resources";
        var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false, fastBuild: true);

        Assert.Contains("-FastBuild", result);
    }

    [Fact]
    public void BuildCoreArgs_OmitsFastBuild_WhenDisabled()
    {
        var resDir = @"C:\resources";
        var result = InvokeBuildCoreArgs(resDir, @"D:\win.iso", @"C:\out.iso", "", 0, "", false, false, fastBuild: false);

        Assert.DoesNotContain("-FastBuild", result);
    }
}
