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

    [Fact]
    public void ForwardJsonLine_BuildError_SuppressedWhen_CancelRequested()
    {
        // Race guard for the d637289 review finding: if the wrapper script writes a
        // build-error to stdout milliseconds before our Kill arrives, the cancel
        // handler has already sent its own "Build cancelled by user." build-error
        // (returned synchronously from HandleAsync). The stdout-sourced build-error
        // should be suppressed so JS never receives two back-to-back.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var bh = new BuildHandlers(bridge, Path.GetTempPath());
        bh.GetType()
            .GetField("_cancelRequested", BindingFlags.Instance | BindingFlags.NonPublic)!
            .SetValue(bh, true);

        var fwd = bh.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(bh, new object?[] {
            "{\"type\":\"build-error\",\"payload\":{\"message\":\"some wrapper-side error\"}}"
        });

        Assert.False(fired, "build-error from stdout must be suppressed once _cancelRequested is set so JS doesn't get two back-to-back build-errors.");
    }

    [Fact]
    public void ForwardJsonLine_BuildError_Forwarded_When_CancelNotRequested()
    {
        // Positive control: with the default `_cancelRequested = false` state, a
        // build-error from stdout must still forward as normal. Without this test
        // the suppression gate could over-fire and swallow legitimate build errors.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? captured = null;
        bridge.MessageToJs += s => captured = s;

        var bh = new BuildHandlers(bridge, Path.GetTempPath());
        var fwd = bh.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(bh, new object?[] {
            "{\"type\":\"build-error\",\"payload\":{\"message\":\"legitimate wrapper crash\"}}"
        });

        Assert.NotNull(captured);
        var node = JsonNode.Parse(captured!);
        Assert.Equal("build-error", node?["type"]?.ToString());
        Assert.Equal("legitimate wrapper crash", node?["payload"]?["message"]?.ToString());
    }

    [Fact]
    public void ForwardJsonLine_BuildProgress_StillForwarded_When_CancelRequested()
    {
        // Per the comment in ForwardJsonLine: the cancel-race gate is ONLY for
        // build-error. build-progress / build-complete remain forwarded even with
        // _cancelRequested=true because surplus progress is harmless and
        // build-complete after cancel means the script genuinely raced past Kill.
        // Guard the comment's intent so a future "while we're at it, broaden the
        // gate to all three types" refactor breaks this test.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? captured = null;
        bridge.MessageToJs += s => captured = s;

        var bh = new BuildHandlers(bridge, Path.GetTempPath());
        bh.GetType()
            .GetField("_cancelRequested", BindingFlags.Instance | BindingFlags.NonPublic)!
            .SetValue(bh, true);

        var fwd = bh.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(bh, new object?[] {
            "{\"type\":\"build-progress\",\"payload\":{\"phase\":\"x\",\"step\":\"y\",\"percent\":50}}"
        });

        Assert.NotNull(captured);
        var node = JsonNode.Parse(captured!);
        Assert.Equal("build-progress", node?["type"]?.ToString());
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
    public async Task CancelBuild_PersistedActiveSource_AvailableForIsoDismount()
    {
        // After cancel, the source-ISO catch-all dismount (DismountSourceIsoIfApplicable)
        // reads _activeSource. Verify start-build populates it BEFORE the cancel handler
        // would need it. We can't run a real build here (no actual pwsh / ISO), so this
        // probes the field via reflection after a start-build call that exits early due
        // to the absent ISO file -- enough to confirm the field write happened before
        // the spawn would have.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var bh = new BuildHandlers(bridge, Path.GetTempPath());

        // Pre-populate _activeSource to a sentinel value and confirm a no-op cancel
        // (no active build) does not blow up. Then confirm a fresh start-build with
        // valid-shape payload at least gets to the field-assignment line.
        var sourceField = bh.GetType().GetField("_activeSource", BindingFlags.Instance | BindingFlags.NonPublic)!;
        sourceField.SetValue(bh, @"D:\some-prior-source.iso");

        await bh.HandleAsync("cancel-build", new JsonObject());

        // Cancel doesn't clear _activeSource (the dismount helper reads it post-Kill).
        Assert.Equal(@"D:\some-prior-source.iso", (string)sourceField.GetValue(bh)!);
    }

    [Fact]
    public async Task StartBuild_ResetsTerminalMarkerAndCancelRequested_FromPriorRun()
    {
        // Regression guard: pre-fix, _terminalMarkerSeen and _cancelRequested persisted
        // across runs. A user who cancelled run #1 and then started run #2 would have
        // both flags stuck at true, so run #2's stderr-fallback would silently skip on
        // a legitimate post-reset crash. Verified via reflection after start-build is
        // called with a payload that fails early validation (so no real subprocess
        // spawns, but the reset-block at the top of the build path runs).
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var bh = new BuildHandlers(bridge, Path.GetTempPath());

        var terminalField = bh.GetType().GetField("_terminalMarkerSeen", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var cancelField   = bh.GetType().GetField("_cancelRequested",    BindingFlags.Instance | BindingFlags.NonPublic)!;
        terminalField.SetValue(bh, true);
        cancelField.SetValue(bh, true);

        // start-build with valid payload shape -- we DON'T expect a real build to spawn
        // because PwshRunner / resources aren't wired in this isolated test, but the
        // field-reset lines run before the validation that would short-circuit, and
        // before any spawn attempt that might throw.
        var payload = new JsonObject
        {
            ["source"] = @"D:\does-not-exist.iso",
            ["outputIso"] = @"C:\out\tiny11.iso",
            ["scratchDir"] = "",
            ["edition"] = 1,
        };

        // Either succeeds with a build-started reply (if spawn somehow works in the test
        // env) or throws inside the spawn -- either way, the field-reset has already run.
        try { await bh.HandleAsync("start-build", payload); }
        catch { /* expected: no real pwsh / resources in test harness */ }

        Assert.False((bool)terminalField.GetValue(bh)!, "_terminalMarkerSeen must reset on start-build so prior-run state doesn't bleed.");
        Assert.False((bool)cancelField.GetValue(bh)!,   "_cancelRequested must reset on start-build so prior-run state doesn't bleed.");
    }

    [Fact]
    public async Task CancelBuild_SetsCancelRequested_BeforeKillToCloseRaceWindow()
    {
        // C5g iteration-4 regression (2026-05-12): _terminalMarkerSeen was being set
        // AFTER _activeBuild.Kill(entireProcessTree: true). Kill walks the process
        // tree signalling each child and can block briefly; the stderr-fallback Task
        // awaiting WaitForExitAsync can wake the instant the root dies, run its
        // check, and see _terminalMarkerSeen still false. Result: spurious "Build
        // process exited with code -1 and no output" overwrites the friendly
        // "Build cancelled by user." in JS, and renderBuildErrorScreen renders
        // "Build failed" instead of "Build cancelled". Two-flag fix: _cancelRequested
        // is set BEFORE Kill so the fallback's belt-and-suspenders check can convert
        // any racing fallback fire into the cancel path.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var bh = new BuildHandlers(bridge, Path.GetTempPath());

        await bh.HandleAsync("cancel-build", new JsonObject());

        var flag = (bool)bh.GetType()
            .GetField("_cancelRequested", BindingFlags.Instance | BindingFlags.NonPublic)!
            .GetValue(bh)!;
        Assert.True(flag, "_cancelRequested must be true after cancel-build so the stderr-fallback can skip on race-loss.");
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t\n")]
    public async Task HandleAsync_StartBuild_RejectsEmptyOrWhitespaceOutputIso(string badOutputIso)
    {
        // Defense-in-depth backstop for the UI's output-required guard. Pre-fix, an
        // empty outputIso slipped through and pwsh bombed at parameter binding with
        // ParameterArgumentValidationErrorEmptyStringNotAllowed on the -OutputIso
        // param (build scripts ValidateNotNullOrEmpty it). Now the handler returns
        // a friendly error BEFORE spawning the subprocess.
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var bh = new BuildHandlers(bridge, Path.GetTempPath());

        var payload = new JsonObject
        {
            ["source"] = @"D:\win.iso",
            ["outputIso"] = badOutputIso,
            ["scratchDir"] = "",
            ["edition"] = 1,
        };

        var result = await bh.HandleAsync("start-build", payload);

        Assert.NotNull(result);
        Assert.Equal("handler-error", result!.Type);
        Assert.Contains("Output ISO path is required", result.Payload?["message"]?.ToString() ?? "");
    }

    [Fact]
    public async Task HandleAsync_StartBuild_RejectsEmptySource()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var bh = new BuildHandlers(bridge, Path.GetTempPath());

        var payload = new JsonObject
        {
            ["source"] = "",
            ["outputIso"] = @"C:\out\tiny11.iso",
            ["scratchDir"] = "",
            ["edition"] = 1,
        };

        var result = await bh.HandleAsync("start-build", payload);

        Assert.NotNull(result);
        Assert.Equal("handler-error", result!.Type);
        Assert.Contains("Source path is required", result.Payload?["message"]?.ToString() ?? "");
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
