using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using Tiny11Options.Launcher.Interop;

namespace Tiny11Options.Launcher.Headless;

internal static class HeadlessRunner
{
    // Resources the headless wrapper needs at runtime alongside tiny11maker.ps1.
    // catalog/** entries are added dynamically from the assembly manifest.
    private static readonly string[] StaticResources = new[]
    {
        "tiny11maker.ps1",
        "autounattend.template.xml",
        "src/Tiny11.Iso.psm1",
        "src/Tiny11.Worker.psm1",
        "src/Tiny11.Catalog.psm1",
        "src/Tiny11.Hives.psm1",
        "src/Tiny11.Selections.psm1",
        "src/Tiny11.Autounattend.psm1",
        "src/Tiny11.Actions.psm1",
        "src/Tiny11.Actions.Registry.psm1",
        "src/Tiny11.Actions.Filesystem.psm1",
        "src/Tiny11.Actions.ProvisionedAppx.psm1",
        "src/Tiny11.Actions.ScheduledTask.psm1",
    };

    public static int Run(string[] args)
    {
        ConsoleAttach.AttachToParent();
        try
        {
            string tempDir;
            try
            {
                tempDir = ResolveExtractionDir();
                EmbeddedResources.ExtractTo(tempDir, AllResources());
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[tiny11options] Failed to extract runtime resources: {ex.Message}");
                return 10;
            }

            var ps1Path = Path.Combine(tempDir, "tiny11maker.ps1");
            var argLine = BuildPwshArgLine(ps1Path, args);

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = argLine,
                UseShellExecute = false,
                RedirectStandardOutput = false,  // inherit from attached console
                RedirectStandardError = false,
                CreateNoWindow = true,
                WorkingDirectory = tempDir,
            };

            try
            {
                using var proc = Process.Start(psi)
                    ?? throw new InvalidOperationException("Process.Start returned null");
                proc.WaitForExit();
                return proc.ExitCode;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                Console.Error.WriteLine(
                    "[tiny11options] powershell.exe is required but was not found on PATH. " +
                    "Install Windows PowerShell 5.1 (built into Windows) or PowerShell 7+.");
                return 11;
            }
            finally
            {
                TryCleanup(tempDir);
            }
        }
        finally
        {
            ConsoleAttach.Detach();
        }
    }

    public static string BuildPwshArgLine(string ps1Path, string[] userArgs)
    {
        var sb = new StringBuilder();
        sb.Append("-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ");
        sb.Append(QuoteIfNeeded(ps1Path));
        foreach (var a in userArgs)
        {
            sb.Append(' ');
            sb.Append(QuoteIfNeeded(a));
        }
        return sb.ToString();
    }

    private static string QuoteIfNeeded(string s)
    {
        if (string.IsNullOrEmpty(s)) return "\"\"";
        if (s.Contains(' ') || s.Contains('"'))
            return "\"" + s.Replace("\"", "\\\"") + "\"";
        return s;
    }

    private static string ResolveExtractionDir()
    {
        var tempPath = Path.Combine(Path.GetTempPath(), $"tiny11options-{Environment.ProcessId}");
        try
        {
            Directory.CreateDirectory(tempPath);
            var probe = Path.Combine(tempPath, ".write-probe");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return tempPath;
        }
        catch
        {
            // %TEMP% non-writable - fall back to %LOCALAPPDATA%
            var fallback = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "tiny11options", "runtime", $"{Environment.ProcessId}");
            Directory.CreateDirectory(fallback);
            return fallback;
        }
    }

    private static void TryCleanup(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch { /* non-fatal: %TEMP% reaped at reboot */ }
    }

    private static IEnumerable<string> AllResources()
    {
        foreach (var r in StaticResources) yield return r;

        var asm = typeof(HeadlessRunner).Assembly;
        foreach (var name in asm.GetManifestResourceNames()
                                 .Where(n => n.StartsWith("catalog/", StringComparison.OrdinalIgnoreCase)))
        {
            yield return name;
        }
    }
}
