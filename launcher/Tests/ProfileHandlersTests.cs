using System;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Moq;
using Tiny11Options.Launcher.Gui.Handlers;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Subprocess;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ProfileHandlersTests
{
    private static (Mock<PwshRunner> runner, ProfileHandlers handler, UserSettings settings, string resourcesDir) Build()
    {
        var resourcesDir = Path.Combine(Path.GetTempPath(), $"tiny11-resources-{Guid.NewGuid():N}");
        Directory.CreateDirectory(resourcesDir);
        // tests don't actually run the script (PwshRunner is mocked); just need the
        // resourcesDir to be a real path the handler can compose against.
        var runner = new Mock<PwshRunner>();
        var settings = new UserSettings();
        var handler = new ProfileHandlers(settings, runner.Object, resourcesDir);
        return (runner, handler, settings, resourcesDir);
    }

    [Fact]
    public async Task SaveProfile_WritesVersionedShape_AndUpdatesLastProfilePath()
    {
        var (_, handler, settings, _) = Build();
        var path = Path.Combine(Path.GetTempPath(), $"tiny11-profile-{Guid.NewGuid():N}.json");
        try
        {
            var resp = await handler.HandleAsync("save-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\",\"selections\":{{\"remove-edge\":\"apply\"}}}}")!.AsObject());

            Assert.Equal("profile-saved", resp!.Type);

            var written = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
            Assert.Equal(1, written["version"]!.GetValue<int>());
            Assert.Equal("apply", written["selections"]!["remove-edge"]!.ToString());

            Assert.Equal(path, settings.LastProfilePath);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task LoadProfile_ReturnsHandlerError_WhenFileMissing()
    {
        var (_, handler, _, _) = Build();
        var resp = await handler.HandleAsync("load-profile",
            JsonNode.Parse("{\"path\":\"C:\\\\nonexistent\\\\path.json\"}")!.AsObject());
        Assert.Equal("handler-error", resp!.Type);
    }

    [Fact]
    public async Task LoadProfile_ReturnsProfileLoaded_WhenValidatorReportsOk()
    {
        var (runner, handler, settings, _) = Build();
        var path = Path.Combine(Path.GetTempPath(), $"tiny11-profile-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, "{}"); // existence check only — validator is mocked
        try
        {
            runner.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string[]>(), It.IsAny<string>()))
                  .ReturnsAsync(new PwshResult(0, "{\"ok\":true,\"selections\":{\"remove-edge\":\"apply\",\"remove-clipchamp\":\"skip\"}}", ""));

            var resp = await handler.HandleAsync("load-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\"}}")!.AsObject());

            Assert.Equal("profile-loaded", resp!.Type);
            Assert.Equal(path, resp.Payload!["path"]?.ToString());
            Assert.Equal("apply", resp.Payload["selections"]!["remove-edge"]!.ToString());
            Assert.Equal("skip", resp.Payload["selections"]!["remove-clipchamp"]!.ToString());

            Assert.Equal(path, settings.LastProfilePath);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task LoadProfile_ReturnsHandlerError_WhenValidatorReportsFailure()
    {
        var (runner, handler, settings, _) = Build();
        var path = Path.Combine(Path.GetTempPath(), $"tiny11-profile-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, "{}");
        try
        {
            runner.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string[]>(), It.IsAny<string>()))
                  .ReturnsAsync(new PwshResult(1, "{\"ok\":false,\"message\":\"Selection state for 'remove-edge' must be 'apply' or 'skip', got: aplly\"}", ""));

            var resp = await handler.HandleAsync("load-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\"}}")!.AsObject());

            Assert.Equal("handler-error", resp!.Type);
            Assert.Contains("aplly", resp.Payload!["message"]!.ToString());

            // LastProfilePath must NOT update on validation failure.
            Assert.Equal("", settings.LastProfilePath);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task LoadProfile_FallsBackToStderr_WhenStdoutIsNotJson()
    {
        var (runner, handler, _, _) = Build();
        var path = Path.Combine(Path.GetTempPath(), $"tiny11-profile-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, "{}");
        try
        {
            runner.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string[]>(), It.IsAny<string>()))
                  .ReturnsAsync(new PwshResult(1, "ParseError: unexpected token at line 3", "Import-Module : module not found"));

            var resp = await handler.HandleAsync("load-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\"}}")!.AsObject());

            Assert.Equal("handler-error", resp!.Type);
            Assert.Contains("module not found", resp.Payload!["message"]!.ToString());
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }
}
