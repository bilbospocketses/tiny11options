using Tiny11Options.Launcher.Gui;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class AppVersionTests
{
    [Theory]
    [InlineData(1, 0, 7, "v1.0.7")]
    [InlineData(1, 0, 0, "v1.0.0")]
    [InlineData(2, 13, 5, "v2.13.5")]
    [InlineData(0, 0, 0, "v0.0.0")]
    [InlineData(99, 99, 99, "v99.99.99")]
    public void Format_ReturnsThreeSegmentForm(int major, int minor, int build, string expected)
    {
        Assert.Equal(expected, AppVersion.Format(new System.Version(major, minor, build)));
    }

    [Fact]
    public void Format_DropsRevisionSegment()
    {
        // csproj <Version>1.0.7</Version> auto-populates Revision as 0; we drop it.
        Assert.Equal("v1.0.7", AppVersion.Format(new System.Version(1, 0, 7, 0)));
        // Non-zero Revision is also dropped (would only happen on artisan builds).
        Assert.Equal("v1.0.7", AppVersion.Format(new System.Version(1, 0, 7, 42)));
    }

    [Fact]
    public void Format_NullVersion_ReturnsPlaceholder()
    {
        Assert.Equal("v?.?.?", AppVersion.Format(null));
    }

    [Fact]
    public void Current_ReturnsThreeSegmentFormFromExecutingAssembly()
    {
        var v = AppVersion.Current();
        Assert.Matches(@"^v\d+\.\d+\.\d+$", v);
    }
}
