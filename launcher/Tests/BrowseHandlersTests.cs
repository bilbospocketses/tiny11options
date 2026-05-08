using System;
using System.IO;
using System.Text.Json.Nodes;
using Moq;
using Tiny11Options.Launcher.Gui.Handlers;
using Tiny11Options.Launcher.Gui.Settings;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BrowseHandlersTests
{
    [Fact]
    public async Task BrowseFile_ReturnsBrowseResult_WithSelectedPath()
    {
        var picker = new Mock<IFilePicker>();
        picker.Setup(p => p.PickOpen(It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>()))
              .Returns("C:\\test\\win11.iso");

        var handler = new BrowseHandlers(picker.Object, new UserSettings());
        var resp = await handler.HandleAsync("browse-file",
            JsonNode.Parse("{\"context\":\"iso\",\"filter\":\"ISO|*.iso\"}")!.AsObject());

        Assert.NotNull(resp);
        Assert.Equal("browse-result", resp!.Type);
        Assert.Equal("iso", resp.Payload!["context"]?.ToString());
        Assert.Equal("C:\\test\\win11.iso", resp.Payload["path"]?.ToString());
    }

    [Fact]
    public async Task BrowseFile_ReturnsBrowseResult_WithNullPath_WhenCancelled()
    {
        var picker = new Mock<IFilePicker>();
        picker.Setup(p => p.PickOpen(It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>()))
              .Returns((string?)null);

        var handler = new BrowseHandlers(picker.Object, new UserSettings());
        var resp = await handler.HandleAsync("browse-file",
            JsonNode.Parse("{\"context\":\"iso\"}")!.AsObject());

        Assert.NotNull(resp);
        Assert.Equal("browse-result", resp!.Type);
        Assert.Null(resp.Payload!["path"]);
    }

    [Fact]
    public async Task ProfileSaveContext_PassesLastProfileDirToPicker_WhenSettingPresent()
    {
        // Use a real existing directory so Directory.Exists() check inside the handler
        // accepts the value — tests pass on any dev box without per-host fixtures.
        var realDir = Path.GetTempPath().TrimEnd('\\', '/');
        var lastFullPath = Path.Combine(realDir, "previous.json");

        var picker = new Mock<IFilePicker>();
        string? observed = null;
        picker.Setup(p => p.PickSaveFile(It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>()))
              .Callback<string?, string?, string?, string?>((_, _, _, dir) => observed = dir)
              .Returns("X:\\new.json");

        var settings = new UserSettings { LastProfilePath = lastFullPath };
        var handler = new BrowseHandlers(picker.Object, settings);

        await handler.HandleAsync("browse-save-file",
            JsonNode.Parse("{\"context\":\"profile-save\"}")!.AsObject());

        Assert.Equal(realDir, observed);
    }

    [Fact]
    public async Task ProfileSaveContext_FallsBackToMyDocuments_WhenNoLastPath()
    {
        var picker = new Mock<IFilePicker>();
        string? observed = null;
        picker.Setup(p => p.PickSaveFile(It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>()))
              .Callback<string?, string?, string?, string?>((_, _, _, dir) => observed = dir)
              .Returns((string?)null);

        var handler = new BrowseHandlers(picker.Object, new UserSettings());

        await handler.HandleAsync("browse-save-file",
            JsonNode.Parse("{\"context\":\"profile-save\"}")!.AsObject());

        Assert.Equal(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), observed);
    }

    [Fact]
    public async Task NonProfileContext_PassesNullInitialDir_WhenNotInPayload()
    {
        var picker = new Mock<IFilePicker>();
        string? observed = "sentinel";
        picker.Setup(p => p.PickOpen(It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>()))
              .Callback<string?, string?, string?>((_, _, dir) => observed = dir)
              .Returns((string?)null);

        var handler = new BrowseHandlers(picker.Object, new UserSettings());

        await handler.HandleAsync("browse-file",
            JsonNode.Parse("{\"context\":\"source\"}")!.AsObject());

        Assert.Null(observed);
    }
}
