using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
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
        "src/Tiny11.PostBoot.psm1",
    };

    public static int Run(string[] args)
    {
        ConsoleAttach.AttachToParent();
        try
        {
            // A13 (v1.0.3): pull --log <path> and --append out of the arg array
            // before forwarding the remainder to tiny11maker.ps1. Headless logging
            // is opt-in -- no --log, no log file (unlike the GUI where the Step 1
            // "Log build output" checkbox is on by default).
            var parsed = HeadlessArgs.Extract(args);
            if (parsed.Error != null)
            {
                Console.Error.WriteLine(parsed.Error);
                return 12;
            }

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
            var argLine = BuildPwshArgLine(ps1Path, parsed.Remaining);

            // A13: open the log writer BEFORE Process.Start so we can fail-fast
            // with exit 13 if the path is unwritable, rather than starting a
            // multi-minute build that has nowhere to log to. Path is resolved
            // against Environment.CurrentDirectory before WorkingDirectory swap
            // (Path.GetFullPath uses CurrentDirectory implicitly).
            StreamWriter? logWriter = null;
            if (parsed.LogPath != null)
            {
                string resolvedLogPath;
                try
                {
                    resolvedLogPath = Path.GetFullPath(parsed.LogPath);
                    var dir = Path.GetDirectoryName(resolvedLogPath);
                    if (!string.IsNullOrEmpty(dir))
                        Directory.CreateDirectory(dir);
                    var mode = parsed.Append ? FileMode.Append : FileMode.Create;
                    var stream = new FileStream(resolvedLogPath, mode, FileAccess.Write, FileShare.Read);
                    logWriter = new StreamWriter(stream) { AutoFlush = true };
                    logWriter.WriteLine($"==== tiny11options headless build started {DateTime.Now:yyyy-MM-dd HH:mm:ss} ====");
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[tiny11options] Failed to open log file '{parsed.LogPath}': {ex.Message}");
                    logWriter?.Dispose();
                    TryCleanup(tempDir);
                    return 13;
                }
            }

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = argLine,
                UseShellExecute = false,
                // When logging is on, capture child output so we can tee to both
                // the console (best-effort -- AttachConsole may not have wired
                // Console.Out to a real handle in the piped case) and the log
                // file (authoritative record). When logging is off, retain the
                // pre-A13 inherited-handle path so attached-terminal users still
                // see live output without our line-by-line read loop in between.
                RedirectStandardOutput = logWriter != null,
                RedirectStandardError = logWriter != null,
                CreateNoWindow = true,
                WorkingDirectory = tempDir,
            };

            try
            {
                using var proc = Process.Start(psi)
                    ?? throw new InvalidOperationException("Process.Start returned null");

                if (logWriter != null)
                {
                    var logLock = new object();
                    var stdoutTask = TeeStreamToLog(proc.StandardOutput, Console.Out, logWriter, logLock);
                    var stderrTask = TeeStreamToLog(proc.StandardError, Console.Error, logWriter, logLock);
                    proc.WaitForExit();
                    // Drain the readers AFTER WaitForExit so any output buffered
                    // in the pipes at exit time still lands in the log.
                    Task.WaitAll(stdoutTask, stderrTask);
                    logWriter.WriteLine($"==== tiny11options headless build finished (exit {proc.ExitCode}) {DateTime.Now:yyyy-MM-dd HH:mm:ss} ====");
                }
                else
                {
                    proc.WaitForExit();
                }
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
                logWriter?.Dispose();
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

    // A13: stream a redirected child output handle line-by-line, teeing each
    // line to both the (possibly null-routed) attached console and the build
    // log file. The lock keeps stdout and stderr readers from interleaving
    // partial lines in the file; the inner try/catch keeps a transient write
    // failure on one stream from killing the whole reader.
    private static Task TeeStreamToLog(StreamReader source, TextWriter console, StreamWriter logFile, object logLock)
    {
        return Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await source.ReadLineAsync()) != null)
                {
                    try { console.WriteLine(line); } catch { /* attached console may not have a real handle */ }
                    lock (logLock)
                    {
                        try { logFile.WriteLine(line); } catch { /* log writer racing disposal */ }
                    }
                }
            }
            catch { /* read loop must not crash the launcher */ }
        });
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
