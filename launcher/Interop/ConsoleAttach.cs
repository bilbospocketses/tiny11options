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
    private static extern bool FreeConsole();

    public static void AttachToParent()
    {
        // Best-effort: when launched from a console (cmd, pwsh, terminal), attach
        // so child stdout/stderr stream to the user's shell. Failures (e.g. launched
        // from Explorer with no parent console) are non-fatal — we just lose console output.
        AttachConsole(ATTACH_PARENT_PROCESS);
    }

    public static void Detach() => FreeConsole();
}
