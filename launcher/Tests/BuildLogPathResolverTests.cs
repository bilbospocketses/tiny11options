using System.IO;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BuildLogPathResolverTests
{
    [Fact]
    public void Resolve_WithScratchDir_ReturnsLogUnderScratchDir()
    {
        var scratch = @"C:\my-scratch";

        var path = BuildLogPathResolver.Resolve(scratch);

        Assert.Equal(Path.Combine(scratch, "tiny11build.log"), path);
    }

    [Fact]
    public void Resolve_NullOrWhitespaceScratchDir_FallsBackToTemp()
    {
        var path = BuildLogPathResolver.Resolve(null);

        Assert.Equal(Path.Combine(Path.GetTempPath(), "tiny11build.log"), path);

        var pathFromEmpty = BuildLogPathResolver.Resolve("");
        Assert.Equal(Path.Combine(Path.GetTempPath(), "tiny11build.log"), pathFromEmpty);

        var pathFromWhitespace = BuildLogPathResolver.Resolve("   ");
        Assert.Equal(Path.Combine(Path.GetTempPath(), "tiny11build.log"), pathFromWhitespace);
    }
}
