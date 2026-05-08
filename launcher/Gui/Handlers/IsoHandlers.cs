using System.Collections.Generic;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Subprocess;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class IsoHandlers : IBridgeHandler
{
    private readonly PwshRunner _runner;
    private readonly string _resourcesDir;

    public IsoHandlers(PwshRunner runner, string resourcesDir)
    {
        _runner = runner;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "validate-iso" };

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        // JS posts {type:'validate-iso', path:'<...>'} per ui/app.js — the field
        // is named `path`, not `isoPath`. Plan-document used isoPath; JS shipped
        // with `path`; this handler now matches the JS-side contract.
        var iso = payload?["path"]?.ToString();
        if (string.IsNullOrEmpty(iso))
            return Error("path required");

        var script = Path.Combine(_resourcesDir, "tiny11-iso-validate.ps1");
        var result = await _runner.RunAsync(script, new[] { "-IsoPath", iso }, _resourcesDir);

        if (result.ExitCode != 0)
            return new BridgeMessage
            {
                Type = "iso-error",
                Payload = new JsonObject { ["message"] = result.Stderr.Trim() },
            };

        var parsed = JsonNode.Parse(result.Stdout) as JsonObject ?? new JsonObject();
        return new BridgeMessage
        {
            Type = "iso-validated",
            Payload = new JsonObject { ["editions"] = parsed["editions"]?.DeepClone() },
        };
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
