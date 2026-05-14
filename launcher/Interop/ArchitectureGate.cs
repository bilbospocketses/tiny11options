using System.Runtime.InteropServices;

namespace Tiny11Options.Launcher.Interop;

/// <summary>
/// A2 (v1.0.3): early startup gate that rejects non-x64 host architectures.
///
/// tiny11options.exe is published with <c>-r win-x64</c> only (see release.yml).
/// On Windows-on-ARM64 (Surface Pro X, Surface Pro 9/11 SQ3/X Elite, Copilot+ PCs
/// with Snapdragon X Elite/Plus), Windows 11 24H2's PRISM emulator will happily
/// launch this exe under x64 emulation -- but WebView2's CoreWebView2 host pipeline,
/// the elevated child <c>powershell.exe</c> spawn, and the Velopack updater all
/// have edge cases under emulation that we explicitly haven't smoke-tested.
///
/// Rather than silently "work mostly" and surface as mysterious WebView2 / pwsh /
/// auto-update failures three minutes into a build, we fail loudly at startup
/// with a clear "you're on arm64, run pwsh -File tiny11maker.ps1 directly" pointer.
/// The legacy entry-point path (tiny11maker.ps1 via Windows PowerShell 5.1) is
/// arch-neutral and has no known arm64 issues -- the build pipeline itself
/// handles arm64 source ISOs correctly via Core's arch detection.
///
/// Note: <see cref="RuntimeInformation.OSArchitecture"/> reports the OS's NATIVE
/// architecture (Arm64 on a Snapdragon-X laptop) even when the calling process is
/// running under x64 emulation. That's the correct surface to gate on -- a user on
/// real arm64 hardware gets the message regardless of whether their EXE is
/// emulated. <see cref="RuntimeInformation.ProcessArchitecture"/> would report X64
/// under PRISM, which is the wrong gate.
/// </summary>
internal static class ArchitectureGate
{
    /// <summary>
    /// Returns null if the host OS architecture is supported (x64). Otherwise
    /// returns a human-readable rejection message ready to surface to the user.
    /// </summary>
    public static string? CheckSupportedHost(Architecture osArch)
    {
        if (osArch == Architecture.X64)
        {
            return null;
        }
        return BuildUnsupportedMessage(osArch);
    }

    /// <summary>Build the rejection message for a given OS architecture.</summary>
    public static string BuildUnsupportedMessage(Architecture osArch)
    {
        return
            $"tiny11options.exe is win-x64 only and cannot run on a {osArch} host.\n\n" +
            "The build pipeline itself supports arm64 source ISOs (Core mode detects\n" +
            "the source ISO's architecture and selects the right WinSxS keep list).\n" +
            "To use it on this host, invoke the PowerShell entry-point directly:\n\n" +
            "    pwsh -NoProfile -File tiny11maker.ps1 -Source <iso> -Edition '<edition>' " +
            "-OutputPath <iso-out>\n\n" +
            "Run the command from cmd.exe or Windows PowerShell 5.1, NOT from pwsh,\n" +
            "to avoid the pwsh-from-pwsh product-key-validation issue on Win11 25H2.\n\n" +
            "Native arm64 launcher support is tracked as a deferred v1.0.3+ item.";
    }

    /// <summary>Convenience: gate against the current host. Returns null when supported.</summary>
    public static string? CheckCurrentHost() => CheckSupportedHost(RuntimeInformation.OSArchitecture);
}
