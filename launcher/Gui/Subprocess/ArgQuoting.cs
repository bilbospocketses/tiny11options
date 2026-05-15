namespace Tiny11Options.Launcher.Gui.Subprocess;

/// <summary>
/// Shared path-arg quoting for powershell.exe command lines.
/// Mirrors the existing logic in HeadlessRunner.QuoteIfNeeded but factored
/// so BuildHandlers/CleanupHandlers/DismountSourceIsoIfApplicable can use
/// the same escaping discipline. v1.0.8 audit WARNING launcher B3.
///
/// Behavior:
/// - Empty / null input returns <c>""</c> (a quoted empty string -- pwsh sees an
///   empty arg, not a missing arg).
/// - If the input contains a space or a literal <c>"</c>, the input is wrapped in
///   <c>"..."</c> with embedded <c>"</c> escaped to <c>\"</c> (the Win32 cmdline rule that
///   powershell.exe's argument parsing follows).
/// - Otherwise the input is returned as-is (no quotes added). Single-token
///   args don't need them.
/// </summary>
internal static class ArgQuoting
{
    public static string QuoteIfNeeded(string? s)
    {
        if (string.IsNullOrEmpty(s)) return "\"\"";
        if (s.Contains(' ') || s.Contains('"'))
            return "\"" + s.Replace("\"", "\\\"") + "\"";
        return s;
    }
}
