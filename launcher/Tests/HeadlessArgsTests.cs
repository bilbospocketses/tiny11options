using System;
using Tiny11Options.Launcher.Headless;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class HeadlessArgsTests
{
    [Fact]
    public void Extract_NoFlags_ReturnsAllArgsWithNoLog()
    {
        var args = new[] { "-Source", "C:\\win.iso", "-Edition", "Windows 11 Pro" };

        var result = HeadlessArgs.Extract(args);

        Assert.Null(result.LogPath);
        Assert.False(result.Append);
        Assert.Null(result.Error);
        Assert.Equal(args, result.Remaining);
    }

    [Fact]
    public void Extract_LogFlagSpaceForm_ExtractsPathAndStripsFlag()
    {
        var args = new[] { "-Source", "C:\\win.iso", "--log", "C:\\out\\build.log", "-Edition", "Windows 11 Pro" };

        var result = HeadlessArgs.Extract(args);

        Assert.Equal(@"C:\out\build.log", result.LogPath);
        Assert.False(result.Append);
        Assert.Null(result.Error);
        Assert.Equal(new[] { "-Source", "C:\\win.iso", "-Edition", "Windows 11 Pro" }, result.Remaining);
    }

    [Fact]
    public void Extract_LogFlagEqualsForm_ExtractsPath()
    {
        var args = new[] { "-Source", "C:\\win.iso", "--log=C:\\out\\build.log" };

        var result = HeadlessArgs.Extract(args);

        Assert.Equal(@"C:\out\build.log", result.LogPath);
        Assert.False(result.Append);
        Assert.Null(result.Error);
        Assert.Equal(new[] { "-Source", "C:\\win.iso" }, result.Remaining);
    }

    [Fact]
    public void Extract_LogFlagAtEndWithNoFollowingArg_ReturnsError()
    {
        var args = new[] { "-Source", "C:\\win.iso", "--log" };

        var result = HeadlessArgs.Extract(args);

        Assert.Null(result.LogPath);
        Assert.NotNull(result.Error);
        Assert.Contains("--log requires a file path argument", result.Error);
    }

    [Fact]
    public void Extract_LogFlagWithEmptyEqualsValue_ReturnsError()
    {
        var args = new[] { "--log=" };

        var result = HeadlessArgs.Extract(args);

        Assert.Null(result.LogPath);
        Assert.NotNull(result.Error);
        Assert.Contains("--log= requires a non-empty path", result.Error);
    }

    [Fact]
    public void Extract_LogFlagAndAppendFlag_BothExtracted()
    {
        var args = new[] { "--log", "C:\\out\\build.log", "--append", "-Source", "C:\\win.iso" };

        var result = HeadlessArgs.Extract(args);

        Assert.Equal(@"C:\out\build.log", result.LogPath);
        Assert.True(result.Append);
        Assert.Null(result.Error);
        Assert.Equal(new[] { "-Source", "C:\\win.iso" }, result.Remaining);
    }

    [Fact]
    public void Extract_AppendFlagWithoutLogFlag_ReturnsError()
    {
        var args = new[] { "--append", "-Source", "C:\\win.iso" };

        var result = HeadlessArgs.Extract(args);

        Assert.Null(result.LogPath);
        Assert.NotNull(result.Error);
        Assert.Contains("--append requires --log", result.Error);
    }

    [Fact]
    public void Extract_MultipleLogFlags_LastWins()
    {
        var args = new[] { "--log", "C:\\first.log", "-Source", "C:\\win.iso", "--log=C:\\second.log" };

        var result = HeadlessArgs.Extract(args);

        Assert.Equal(@"C:\second.log", result.LogPath);
        Assert.Null(result.Error);
        Assert.Equal(new[] { "-Source", "C:\\win.iso" }, result.Remaining);
    }

    [Fact]
    public void Extract_LogFlagUppercase_PassesThroughCaseSensitiveMatchOnly()
    {
        // Lowercase-only requirement: --Log / --LOG / --LoG are NOT recognized.
        // They fall through to the wrapper script's arg surface, which has its
        // own handling (will surface a parameter-not-found error from pwsh).
        var args = new[] { "--Log", "C:\\out\\build.log", "-Source", "C:\\win.iso" };

        var result = HeadlessArgs.Extract(args);

        Assert.Null(result.LogPath);
        Assert.Null(result.Error);
        Assert.Equal(args, result.Remaining);
    }

    [Fact]
    public void Extract_PreservesWrapperArgOrderAroundFlagStrip()
    {
        // --log in the middle: surrounding args must keep their order after
        // the flag pair is stripped.
        var args = new[]
        {
            "-Source", "C:\\win.iso",
            "--log", "build.log",
            "-Edition", "Windows 11 Pro",
            "--append",
            "-OutputIso", "C:\\out.iso",
        };

        var result = HeadlessArgs.Extract(args);

        Assert.Equal("build.log", result.LogPath);
        Assert.True(result.Append);
        Assert.Null(result.Error);
        Assert.Equal(new[]
        {
            "-Source", "C:\\win.iso",
            "-Edition", "Windows 11 Pro",
            "-OutputIso", "C:\\out.iso",
        }, result.Remaining);
    }
}
