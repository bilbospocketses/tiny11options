using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

// Handles the "Run cleanup automatically" button on the Build cancelled /
// Build failed UI. Spawns powershell.exe against tiny11-cancel-cleanup.ps1
// with -MountDir and -SourceDir from the JS payload (which JS got from the
// mount-state build-progress marker the pipeline emits at install.wim mount).
//
// Mirrors BuildHandlers' forwarder pattern: stdout is parsed line-by-line as
// JSON markers (cleanup-progress / cleanup-complete / cleanup-error) and
// forwarded via Bridge.SendToJs. No cancel flow -- the cleanup script is
// bounded (10-30 seconds typical), so we don't expose a "cancel the cleanup"
// path. The script itself is one-shot per the design decision documented in
// the v1.0.0 feature spec: button disables on click and never re-enables.
public class CleanupHandlers : IBridgeHandler
{
    private readonly Bridge.Bridge _bridge;
    private readonly string _resourcesDir;

    public CleanupHandlers(Bridge.Bridge bridge, string resourcesDir)
    {
        _bridge = bridge;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "start-cleanup" };

    public async Task<Bridge.BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var mountDir = payload?["mountDir"]?.ToString() ?? "";
        var sourceDir = payload?["sourceDir"]?.ToString() ?? "";
        // Optional: build-complete cleanup carries the output ISO path so the
        // PS script can refuse to wipe a target that contains the deliverable.
        // Cancel/error cleanup omits it (no completed ISO to protect).
        var outputIso = payload?["outputIso"]?.ToString() ?? "";

        if (string.IsNullOrWhiteSpace(mountDir) || string.IsNullOrWhiteSpace(sourceDir))
        {
            return new Bridge.BridgeMessage
            {
                Type = "cleanup-error",
                Payload = new JsonObject { ["message"] = "start-cleanup requires mountDir and sourceDir in the payload." },
            };
        }

        var psArgs = BuildCleanupArgs(_resourcesDir, mountDir, sourceDir, outputIso);
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = psArgs,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = _resourcesDir,
        };

        var proc = Process.Start(psi);
        if (proc is null) return Error("Failed to spawn pwsh for cleanup");

        // Stream stdout line-by-line; forward known marker types via Bridge.SendToJs.
        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await proc.StandardOutput.ReadLineAsync()) is not null)
                {
                    ForwardJsonLine(line);
                }
            }
            catch { /* read loop must not crash bridge */ }
        });

        // STDERR fallback for the "script crashed before its catch block" case
        // (same shape as BuildHandlers): if the process exited non-zero and no
        // terminal marker was forwarded, surface stderr as cleanup-error.
        _ = Task.Run(async () =>
        {
            await proc.WaitForExitAsync();
            if (proc.ExitCode != 0 && !_terminalMarkerSeen)
            {
                var err = await proc.StandardError.ReadToEndAsync();
                _bridge.SendToJs(new Bridge.BridgeMessage
                {
                    Type = "cleanup-error",
                    Payload = new JsonObject
                    {
                        ["message"] = string.IsNullOrWhiteSpace(err)
                            ? $"Cleanup process exited with code {proc.ExitCode} and no output"
                            : err.Trim(),
                    },
                });
            }
        });

        return new Bridge.BridgeMessage { Type = "cleanup-started", Payload = new JsonObject() };
    }

    private bool _terminalMarkerSeen;

    private void ForwardJsonLine(string line)
    {
        try
        {
            var node = JsonNode.Parse(line) as JsonObject;
            var t = node?["type"]?.ToString();
            if (t is "cleanup-progress" or "cleanup-complete" or "cleanup-error")
            {
                if (t is "cleanup-complete" or "cleanup-error") _terminalMarkerSeen = true;
                // DeepClone the payload so the new BridgeMessage owns it cleanly
                // (same reason as BuildHandlers.ForwardJsonLine -- otherwise
                // System.Text.Json throws "node already has a parent" when the
                // payload is re-serialized inside SendToJs).
                var payloadClone = node!["payload"]?.DeepClone() as JsonObject;
                try { _bridge.SendToJs(new Bridge.BridgeMessage { Type = t, Payload = payloadClone }); }
                catch { /* SendToJs must not crash the read loop */ }
            }
        }
        catch { /* malformed line -- ignore */ }
    }

    // Extracted for testability: builds the powershell.exe -Arguments string.
    // Callers that need to unit-test the routing can invoke this directly via
    // reflection without spawning a real process.
    internal static string BuildCleanupArgs(string resourcesDir, string mountDir, string sourceDir, string outputIso = "")
    {
        var script = Path.Combine(resourcesDir, "tiny11-cancel-cleanup.ps1");
        var args = new System.Text.StringBuilder("-ExecutionPolicy Bypass -NoProfile -File ");
        args.Append('"').Append(script).Append('"');
        args.Append(" -MountDir \"").Append(mountDir).Append('"');
        args.Append(" -SourceDir \"").Append(sourceDir).Append('"');
        if (!string.IsNullOrWhiteSpace(outputIso))
        {
            args.Append(" -OutputIso \"").Append(outputIso).Append('"');
        }
        return args.ToString();
    }

    private static Bridge.BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
