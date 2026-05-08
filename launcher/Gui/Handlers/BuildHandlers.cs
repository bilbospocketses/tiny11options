using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class BuildHandlers : IBridgeHandler
{
    private readonly Bridge.Bridge _bridge;
    private readonly string _resourcesDir;

    // SMOKE DIAGNOSTIC — REVERT BEFORE RELEASE. Passthrough log of every line
    // received from the pwsh build subprocess + every forward outcome. Lets us
    // see whether the wrapper emitted markers, whether they parsed, and whether
    // SendToJs threw silently inside the unobserved Task.Run reader.
    private static readonly string SmokeBuildLog = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tiny11options", "smoke-build.log");

    private static void LogSmoke(string text)
    {
        try { File.AppendAllText(SmokeBuildLog, $"[{DateTime.Now:HH:mm:ss.fff}] {text}\n"); }
        catch { /* diagnostic must never crash the bridge */ }
    }

    public BuildHandlers(Bridge.Bridge bridge, string resourcesDir)
    {
        _bridge = bridge;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "start-build", "cancel-build" };

    private Process? _activeBuild;

    public async Task<Bridge.BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "cancel-build")
        {
            // PORTED: tiny11maker.ps1:289 (legacy `cancel` handler). Legacy used a
            // CancellationTokenSource on the runspace worker; the worker observed
            // cancellation and posted build-error {message="...cancelled..."}, which
            // JS handles via its existing build-error path (renders error screen).
            // We emulate that by sending build-error directly here so JS doesn't
            // need a separate build-cancelled handler — and the wizard exits the
            // progress state cleanly. The Process.Kill stops the actual work; this
            // bridge message stops the UI hang.
            _activeBuild?.Kill(entireProcessTree: true);
            return new Bridge.BridgeMessage
            {
                Type = "build-error",
                Payload = new JsonObject { ["message"] = "Build cancelled by user." },
            };
        }

        if (_activeBuild is { HasExited: false })
            return Error("a build is already in progress");

        var configPath = Path.Combine(_resourcesDir, $"build-config-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(configPath, payload?.ToJsonString() ?? "{}");

        var script = Path.Combine(_resourcesDir, "tiny11maker-from-config.ps1");

        // PORTED: tiny11maker.ps1:271-278 (legacy `build` worker payload reads).
        // Legacy reads source / imageIndex / scratchDir / outputPath / unmountSource /
        // fastBuild / selections from the JS payload and passes them all to
        // Invoke-Tiny11BuildPipeline. Path C must do the same — the prior scaffold
        // forwarded only Source / OutputIso / Edition and dropped scratchDir,
        // unmountSource, fastBuild, imageIndex on the floor.
        var src = payload?["source"]?.ToString() ?? "";
        var outputIso = payload?["outputIso"]?.ToString() ?? "";
        var scratchDir = payload?["scratchDir"]?.ToString() ?? "";
        var unmountSource = payload?["unmountSource"]?.GetValue<bool>() ?? false;
        var fastBuild = payload?["fastBuild"]?.GetValue<bool>() ?? false;

        // JS-side `state.edition` is the integer ImageIndex (set in app.js:527
        // from p.editions[0].index). Treat it as ImageIndex by default; only fall
        // back to -Edition (the human-readable name) if the value isn't numeric.
        var editionRaw = payload?["edition"];
        int imageIndex = 0;
        string editionName = "";
        if (editionRaw is not null)
        {
            if (editionRaw.GetValueKind() == JsonValueKind.Number)
                imageIndex = editionRaw.GetValue<int>();
            else if (int.TryParse(editionRaw.ToString(), out var parsed))
                imageIndex = parsed;
            else
                editionName = editionRaw.ToString();
        }

        var args = new System.Text.StringBuilder("-ExecutionPolicy Bypass -NoProfile -File ");
        args.Append('"').Append(script).Append('"');
        args.Append(" -ConfigPath \"").Append(configPath).Append('"');
        args.Append(" -Source \"").Append(src).Append('"');
        args.Append(" -OutputIso \"").Append(outputIso).Append('"');
        if (imageIndex > 0) args.Append(" -ImageIndex ").Append(imageIndex);
        if (!string.IsNullOrEmpty(editionName)) args.Append(" -Edition \"").Append(editionName).Append('"');
        if (!string.IsNullOrEmpty(scratchDir)) args.Append(" -ScratchDir \"").Append(scratchDir).Append('"');
        if (unmountSource) args.Append(" -UnmountSource");
        if (fastBuild) args.Append(" -FastBuild");

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = args.ToString(),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = _resourcesDir,
        };

        _activeBuild = Process.Start(psi);
        if (_activeBuild is null) return Error("Failed to spawn pwsh for build");

        LogSmoke($"=== build subprocess started PID={_activeBuild.Id} args={args} ===");

        // Stream stdout line-by-line. The wrapper writes ALL bridge traffic
        // (build-progress, build-complete, build-error) to STDOUT — single forwarder
        // routes everything by `type`.
        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await _activeBuild.StandardOutput.ReadLineAsync()) is not null)
                {
                    LogSmoke($"STDOUT: {line}");
                    ForwardJsonLine(line);
                }
                LogSmoke("STDOUT closed (subprocess pipe ended)");
            }
            catch (Exception ex)
            {
                LogSmoke($"STDOUT reader threw: {ex.GetType().Name}: {ex.Message}");
            }
        });

        // STDERR fallback: if the wrapper crashes BEFORE its catch block (e.g. parse
        // error, ImportModule failure), it never writes a build-error JSON marker.
        // Capture stderr and emit build-error on non-zero exit only when no
        // build-error / build-complete has come through stdout.
        _ = Task.Run(async () =>
        {
            await _activeBuild.WaitForExitAsync();
            if (_activeBuild.ExitCode != 0 && !_terminalMarkerSeen)
            {
                var err = await _activeBuild.StandardError.ReadToEndAsync();
                _bridge.SendToJs(new Bridge.BridgeMessage
                {
                    Type = "build-error",
                    Payload = new JsonObject
                    {
                        ["message"] = string.IsNullOrWhiteSpace(err)
                            ? $"Build process exited with code {_activeBuild.ExitCode} and no output"
                            : err.Trim(),
                    },
                });
            }
        });

        return new Bridge.BridgeMessage { Type = "build-started", Payload = new JsonObject() };
    }

    private bool _terminalMarkerSeen;

    private void ForwardJsonLine(string line)
    {
        try
        {
            var node = JsonNode.Parse(line) as JsonObject;
            var t = node?["type"]?.ToString();
            if (t is "build-progress" or "build-complete" or "build-error")
            {
                if (t is "build-complete" or "build-error") _terminalMarkerSeen = true;
                // DeepClone the payload so the new BridgeMessage owns it cleanly.
                // Without the clone, node["payload"] is still parented under `node`
                // and System.Text.Json would throw "node already has a parent" when
                // re-serializing inside Bridge.SendToJs — and the throw is swallowed
                // by the unobserved Task.Run reader, which made the build markers
                // disappear silently into the same async-push black hole that hid
                // the update badge in the previous smoke (fixed in 81f8880 by
                // refactoring UpdateNotifier to pull-based; here we keep push and
                // fix the parent-ownership bug instead).
                var payloadClone = node!["payload"]?.DeepClone() as JsonObject;
                try
                {
                    _bridge.SendToJs(new Bridge.BridgeMessage { Type = t, Payload = payloadClone });
                    LogSmoke($"FORWARDED: type={t}");
                }
                catch (Exception ex)
                {
                    LogSmoke($"SendToJs threw: {ex.GetType().Name}: {ex.Message}");
                }
            }
            else
            {
                LogSmoke($"IGNORED non-marker JSON: type={t ?? "<null>"}");
            }
        }
        catch (Exception ex)
        {
            LogSmoke($"ForwardJsonLine threw on '{line}': {ex.GetType().Name}: {ex.Message}");
        }
    }

    private static Bridge.BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
