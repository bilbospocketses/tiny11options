using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class BuildHandlers : IBridgeHandler
{
    private readonly Bridge _bridge;
    private readonly string _resourcesDir;

    public BuildHandlers(Bridge bridge, string resourcesDir)
    {
        _bridge = bridge;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "start-build", "cancel-build" };

    private Process? _activeBuild;

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "cancel-build")
        {
            _activeBuild?.Kill(entireProcessTree: true);
            return new BridgeMessage { Type = "build-cancelled", Payload = new JsonObject() };
        }

        if (_activeBuild is { HasExited: false })
            return Error("a build is already in progress");

        var configPath = Path.Combine(_resourcesDir, $"build-config-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(configPath, payload?.ToJsonString() ?? "{}");

        var script = Path.Combine(_resourcesDir, "tiny11maker-from-config.ps1");
        var src = payload?["source"]?.ToString() ?? "";
        var iso = payload?["outputIso"]?.ToString() ?? "";
        var edition = payload?["edition"]?.ToString() ?? "";

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-ExecutionPolicy Bypass -NoProfile -File \"{script}\" " +
                        $"-ConfigPath \"{configPath}\" -Source \"{src}\" -OutputIso \"{iso}\" -Edition \"{edition}\"",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = _resourcesDir,
        };

        _activeBuild = Process.Start(psi);
        if (_activeBuild is null) return Error("Failed to spawn pwsh for build");

        // Stream stdout line-by-line, forwarding JSON markers as bridge messages
        _ = Task.Run(async () =>
        {
            string? line;
            while ((line = await _activeBuild.StandardOutput.ReadLineAsync()) is not null)
            {
                ForwardJsonLine(line);
            }
        });

        _ = Task.Run(async () =>
        {
            await _activeBuild.WaitForExitAsync();
            if (_activeBuild.ExitCode != 0)
            {
                var err = await _activeBuild.StandardError.ReadToEndAsync();
                _bridge.SendToJs(new BridgeMessage
                {
                    Type = "build-error",
                    Payload = new JsonObject { ["message"] = err.Trim() },
                });
            }
        });

        return new BridgeMessage { Type = "build-started", Payload = new JsonObject() };
    }

    private void ForwardJsonLine(string line)
    {
        try
        {
            var node = JsonNode.Parse(line) as JsonObject;
            if (node?["type"]?.ToString() is string t && (t == "build-progress" || t == "build-complete"))
            {
                _bridge.SendToJs(new BridgeMessage
                {
                    Type = t,
                    Payload = node["payload"]?.AsObject(),
                });
            }
        }
        catch { /* non-JSON lines ignored */ }
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
