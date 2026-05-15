using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Tiny11Options.Launcher.Interop;

internal static class ConsoleAttach
{
    private const int ATTACH_PARENT_PROCESS = -1;

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllocConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeConsole();

    public static void AttachToParent()
    {
        // v1.0.1 audit A13 Option C / v1.0.8 audit B5: check AttachConsole's
        // return value. AttachConsole returns false when parent has no console
        // (piped scenarios like `tiny11options.exe ... | Tee-Object out.log`).
        // Fall back to AllocConsole so the un-flagged-pipe case still produces
        // output. --log remains the documented preferred path for scripted use.
        bool attached = AttachConsole(ATTACH_PARENT_PROCESS);
        if (!attached)
        {
            AllocConsole();
        }

        // Refresh Console.Out and Console.Error so .NET writes target the
        // just-attached (or just-allocated) console handles. Without this,
        // Console.WriteLine still uses the pre-attach handles (which were
        // file descriptors pointing nowhere). AutoFlush on so callers don't
        // need to manage flushing.
        try
        {
            var stdout = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
            Console.SetOut(stdout);
            var stderr = new StreamWriter(Console.OpenStandardError()) { AutoFlush = true };
            Console.SetError(stderr);
        }
        catch { /* best-effort; do not crash startup on stream attach */ }
    }

    public static void Detach() => FreeConsole();
}
