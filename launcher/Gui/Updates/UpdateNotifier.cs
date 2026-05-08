using System;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Updates;

public class UpdateNotifier
{
    private readonly IUpdateSource _source;
    private readonly Bridge.Bridge _bridge;
    public UpdateInfo? PendingUpdate { get; private set; }

    public UpdateNotifier(IUpdateSource source, Bridge.Bridge bridge)
    {
        _source = source;
        _bridge = bridge;
    }

    public async Task CheckAsync()
    {
        // SMOKE STUB — REVERT BEFORE PHASE 5. Bypasses Velopack/GitHub and
        // fakes an update-available so check 6 can verify the badge layout
        // + confirm() flow without a real release in the wild. Do NOT click
        // OK on the confirm — that posts apply-update and Velopack will
        // error against missing GitHub release artifacts.
        var fake = new UpdateInfo(
            "1.0.0-smoke",
            "Smoke-test changelog.\n\n- pulsing dot layout\n- confirm() copy\n- click flow");
        PendingUpdate = fake;
        _bridge.SendToJs(new Bridge.BridgeMessage
        {
            Type = "update-available",
            Payload = new JsonObject
            {
                ["version"] = fake.Version,
                ["changelog"] = fake.Changelog,
            },
        });
        await Task.CompletedTask;
    }

    public Task ApplyAsync() => _source.ApplyAndRestartAsync();
}
