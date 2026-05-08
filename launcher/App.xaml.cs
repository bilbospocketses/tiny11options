using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace Tiny11Options.Launcher;

public partial class App : Application
{
    // SMOKE DIAGNOSTIC — REVERT BEFORE COMMIT. Funnels every unhandled exception
    // (UI thread, background threads, unobserved tasks) to a log file under
    // %LOCALAPPDATA%\tiny11options\smoke-crash.log so we can see what kills
    // the process during bridge dispatch.
    private static readonly string CrashLogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tiny11options", "smoke-crash.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(CrashLogPath)!);
        File.WriteAllText(CrashLogPath, $"=== Launch {DateTime.Now:O} ===\n");

        DispatcherUnhandledException += (_, ex) =>
        {
            LogException("DispatcherUnhandledException", ex.Exception);
            ex.Handled = true; // keep window alive so we can read the log
            MessageBox.Show($"Unhandled exception logged to:\n{CrashLogPath}\n\n{ex.Exception.GetType().Name}: {ex.Exception.Message}",
                "tiny11options (smoke crash)", MessageBoxButton.OK, MessageBoxImage.Error);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
            LogException("AppDomain.UnhandledException", ex.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            LogException("TaskScheduler.UnobservedTaskException", ex.Exception);
            ex.SetObserved();
        };

        base.OnStartup(e);
    }

    private static void LogException(string source, Exception? ex)
    {
        if (ex is null) return;
        try
        {
            File.AppendAllText(CrashLogPath,
                $"\n[{source}] {DateTime.Now:O}\n" +
                $"  Type: {ex.GetType().FullName}\n" +
                $"  Message: {ex.Message}\n" +
                $"  Stack: {ex.StackTrace}\n" +
                (ex.InnerException is null ? "" : $"  Inner: {ex.InnerException.GetType().FullName} / {ex.InnerException.Message}\n"));
        }
        catch { /* never let logging itself crash */ }
    }
}
