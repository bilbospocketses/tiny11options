using System;
using System.Threading.Tasks;
using Moq;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Updates;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class UpdateNotifierTests
{
    [Fact]
    public async Task CheckAsync_SendsUpdateAvailable_WhenNewerVersionFound()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync())
              .ReturnsAsync(new UpdateInfo("0.3.0", "* New feature"));

        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? sent = null;
        bridge.MessageToJs += s => sent = s;

        var notifier = new UpdateNotifier(source.Object, bridge);
        await notifier.CheckAsync();

        Assert.NotNull(sent);
        Assert.Contains("update-available", sent!);
        Assert.Contains("0.3.0", sent);
    }

    [Fact]
    public async Task CheckAsync_SendsNothing_WhenNoUpdate()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync()).ReturnsAsync((UpdateInfo?)null);

        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var notifier = new UpdateNotifier(source.Object, bridge);
        await notifier.CheckAsync();

        Assert.False(fired);
    }

    [Fact]
    public async Task CheckAsync_Silent_WhenSourceThrows()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync()).ThrowsAsync(new System.Net.Http.HttpRequestException("network down"));

        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var notifier = new UpdateNotifier(source.Object, bridge);
        await notifier.CheckAsync();

        Assert.False(fired);
    }
}
