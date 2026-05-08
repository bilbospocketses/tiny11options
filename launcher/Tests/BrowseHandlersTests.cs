using System.Text.Json.Nodes;
using Moq;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BrowseHandlersTests
{
    [Fact]
    public async Task BrowseFile_ReturnsBrowseResult_WithSelectedPath()
    {
        var picker = new Mock<IFilePicker>();
        picker.Setup(p => p.PickOpen(It.IsAny<string?>(), It.IsAny<string?>()))
              .Returns("C:\\test\\win11.iso");

        var handler = new BrowseHandlers(picker.Object);
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
        picker.Setup(p => p.PickOpen(It.IsAny<string?>(), It.IsAny<string?>()))
              .Returns((string?)null);

        var handler = new BrowseHandlers(picker.Object);
        var resp = await handler.HandleAsync("browse-file",
            JsonNode.Parse("{\"context\":\"iso\"}")!.AsObject());

        Assert.NotNull(resp);
        Assert.Equal("browse-result", resp!.Type);
        Assert.Null(resp.Payload!["path"]);
    }
}
