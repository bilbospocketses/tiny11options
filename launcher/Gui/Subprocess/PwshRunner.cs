using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Subprocess;

public record PwshResult(int ExitCode, string Stdout, string Stderr);

public class PwshRunner
{
    public virtual async Task<PwshResult> RunAsync(string ps1Path, string[] args, string workingDir)
    {
        var argLine = new StringBuilder("-ExecutionPolicy Bypass -NoProfile -File ");
        argLine.Append('"').Append(ps1Path).Append('"');
        foreach (var a in args)
        {
            argLine.Append(' ');
            if (a.Contains(' ') || a.Contains('"'))
                argLine.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
            else
                argLine.Append(a);
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = argLine.ToString(),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = workingDir,
        };

        using var proc = Process.Start(psi)!;
        var stdoutTask = proc.StandardOutput.ReadToEndAsync();
        var stderrTask = proc.StandardError.ReadToEndAsync();
        await proc.WaitForExitAsync();
        return new PwshResult(proc.ExitCode, await stdoutTask, await stderrTask);
    }
}
