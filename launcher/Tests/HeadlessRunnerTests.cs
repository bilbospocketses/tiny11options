using System;
using Tiny11Options.Launcher.Headless;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class HeadlessRunnerTests
{
    [Fact]
    public void BuildPwshArgLine_QuotesPathWithSpaces()
    {
        var ps1 = @"C:\Temp\dir with spaces\tiny11maker.ps1";
        var userArgs = new[] { "-Source", @"C:\my iso\win11.iso", "-Edition", "Windows 11 Pro" };

        var argLine = HeadlessRunner.BuildPwshArgLine(ps1, userArgs);

        Assert.Contains(@"""C:\Temp\dir with spaces\tiny11maker.ps1""", argLine);
        Assert.Contains(@"""C:\my iso\win11.iso""", argLine);
        Assert.Contains(@"""Windows 11 Pro""", argLine);
    }

    [Fact]
    public void BuildPwshArgLine_PrependsBypassAndNoProfile()
    {
        var argLine = HeadlessRunner.BuildPwshArgLine(@"C:\foo.ps1", Array.Empty<string>());

        Assert.StartsWith("-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden", argLine);
        Assert.Contains("-File", argLine);
    }
}
