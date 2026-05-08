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

        // The script writes a structured JSON object to STDOUT in BOTH branches:
        //   success: {"ok": true,  "editions": [...]}
        //   failure: {"ok": false, "message": "..."}
        // Parse stdout first; only fall back to stderr/exit-code text if stdout
        // isn't parseable (script crashed before writing JSON, e.g. Import-Module
        // error, syntax error, etc.).
        JsonObject? parsed = null;
        try { parsed = JsonNode.Parse(result.Stdout.Trim()) as JsonObject; }
        catch { /* fall through to stderr fallback */ }

        if (parsed is not null)
        {
            var ok = parsed["ok"]?.GetValue<bool>() ?? false;
            if (ok)
            {
                // PORTED: tiny11maker.ps1:195 (legacy validate-iso) — emits
                // {editions, path}. JS-side reads p.path with `|| state.source`
                // fallback (app.js:528), so the path round-trip is defensive
                // rather than load-bearing, but match legacy contract for parity.
                return new BridgeMessage
                {
                    Type = "iso-validated",
                    Payload = new JsonObject
                    {
                        ["editions"] = parsed["editions"]?.DeepClone(),
                        ["path"] = iso,
                    },
                };
            }
            return new BridgeMessage
            {
                Type = "iso-error",
                Payload = new JsonObject
                {
                    ["message"] = parsed["message"]?.ToString() ?? "Validation failed (no message)",
                },
            };
        }

        // Stdout unparseable — script crashed before writing its JSON contract.
        // Surface stderr if present, otherwise stdout-as-text, otherwise exit code.
        var fallback =
            !string.IsNullOrWhiteSpace(result.Stderr) ? result.Stderr.Trim() :
            !string.IsNullOrWhiteSpace(result.Stdout) ? result.Stdout.Trim() :
            $"Script failed with exit code {result.ExitCode} and no output";
        return new BridgeMessage
        {
            Type = "iso-error",
            Payload = new JsonObject { ["message"] = fallback },
        };
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
