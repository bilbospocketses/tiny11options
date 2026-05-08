using System;
using System.IO;
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ProfileHandlersTests
{
    [Fact]
    public async Task SaveAndLoadProfile_RoundTripsSelections()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tiny11-profile-{Guid.NewGuid():N}.json");
        try
        {
            var handler = new ProfileHandlers();

            var saveResp = await handler.HandleAsync("save-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\",\"selections\":{{\"items\":[\"a\",\"b\"]}}}}")!.AsObject());
            Assert.Equal("profile-saved", saveResp!.Type);

            var loadResp = await handler.HandleAsync("load-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\"}}")!.AsObject());
            Assert.Equal("profile-loaded", loadResp!.Type);
            var items = loadResp.Payload!["selections"]?["items"]?.AsArray();
            Assert.NotNull(items);
            Assert.Equal(2, items!.Count);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task LoadProfile_ReturnsHandlerError_WhenFileMissing()
    {
        var handler = new ProfileHandlers();
        var resp = await handler.HandleAsync("load-profile",
            JsonNode.Parse("{\"path\":\"C:\\\\nonexistent\\\\path.json\"}")!.AsObject());
        Assert.Equal("handler-error", resp!.Type);
    }
}
