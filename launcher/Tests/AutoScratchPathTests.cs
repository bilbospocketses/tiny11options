using System;
using System.IO;
using Tiny11Options.Launcher.Gui;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class AutoScratchPathTests
{
    [Fact]
    public void Generate_ReturnsAbsolutePathUnderTempDirectory()
    {
        var path = AutoScratchPath.Generate();
        Assert.True(Path.IsPathFullyQualified(path), $"Expected fully qualified path; got '{path}'");
        var tempDir = Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        Assert.StartsWith(tempDir, path, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Generate_TwoConsecutiveCallsProduceDifferentSuffixes()
    {
        var first = AutoScratchPath.Generate();
        var second = AutoScratchPath.Generate();
        Assert.NotEqual(first, second);
    }

    [Fact]
    public void Generate_DoesNotCreateDirectoryOnDisk()
    {
        var path = AutoScratchPath.Generate();
        Assert.False(Directory.Exists(path), $"AutoScratchPath should return a candidate path only; directory '{path}' was created");
    }
}
