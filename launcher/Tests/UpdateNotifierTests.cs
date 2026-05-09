using System.Threading.Tasks;
using Moq;
using Tiny11Options.Launcher.Gui.Updates;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class UpdateNotifierTests
{
    [Fact]
    public async Task CheckAsync_ReturnsUpdateAvailableMessage_WhenNewerVersionFound()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync())
              .ReturnsAsync(new UpdateInfo("0.3.0", "* New feature"));

        var notifier = new UpdateNotifier(source.Object);
        var msg = await notifier.CheckAsync();

        Assert.NotNull(msg);
        Assert.Equal("update-available", msg!.Type);
        Assert.Equal("0.3.0", msg.Payload?["version"]?.ToString());
        Assert.Equal("* New feature", msg.Payload?["changelog"]?.ToString());
        Assert.NotNull(notifier.PendingUpdate);
        Assert.Equal("0.3.0", notifier.PendingUpdate!.Version);
    }

    [Fact]
    public async Task CheckAsync_ReturnsNull_WhenNoUpdate()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync()).ReturnsAsync((UpdateInfo?)null);

        var notifier = new UpdateNotifier(source.Object);
        var msg = await notifier.CheckAsync();

        Assert.Null(msg);
        Assert.Null(notifier.PendingUpdate);
    }

    [Fact]
    public async Task CheckAsync_PropagatesException_WhenSourceThrows()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync()).ThrowsAsync(new System.Net.Http.HttpRequestException("network down"));

        var notifier = new UpdateNotifier(source.Object);

        await Assert.ThrowsAsync<System.Net.Http.HttpRequestException>(() => notifier.CheckAsync());
        Assert.Null(notifier.PendingUpdate);
    }
}
