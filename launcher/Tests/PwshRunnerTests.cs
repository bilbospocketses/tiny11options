using System;
using System.IO;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Subprocess;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class PwshRunnerTests
{
    [Fact]
    public async Task RunAsync_ReturnsStdoutAndExitZero_OnTrivialScript()
    {
        var script = Path.Combine(Path.GetTempPath(), $"echo-{Guid.NewGuid():N}.ps1");
        File.WriteAllText(script, "Write-Output 'hello'");
        try
        {
            var runner = new PwshRunner();
            var result = await runner.RunAsync(script, Array.Empty<string>(), Path.GetTempPath());

            Assert.Equal(0, result.ExitCode);
            Assert.Contains("hello", result.Stdout);
        }
        finally { File.Delete(script); }
    }

    [Fact]
    public async Task RunAsync_ReturnsNonZeroExit_OnFailure()
    {
        var script = Path.Combine(Path.GetTempPath(), $"fail-{Guid.NewGuid():N}.ps1");
        File.WriteAllText(script, "exit 7");
        try
        {
            var runner = new PwshRunner();
            var result = await runner.RunAsync(script, Array.Empty<string>(), Path.GetTempPath());
            Assert.Equal(7, result.ExitCode);
        }
        finally { File.Delete(script); }
    }
}
