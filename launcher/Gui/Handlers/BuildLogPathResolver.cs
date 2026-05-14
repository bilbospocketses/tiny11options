using System.IO;

namespace Tiny11Options.Launcher.Gui.Handlers;

// A13 (v1.0.3): resolves the GUI build-log file path. When the user picks a
// scratch directory on Step 1, the build log lives alongside the build
// artifacts there; when they leave it blank, the wrapper script defaults
// scratch to a fresh folder under %TEMP%, so the log falls back to %TEMP%
// proper (we don't know the wrapper's fresh-folder path at this layer, so
// we put the log directly under %TEMP% as a stable, find-able location).
internal static class BuildLogPathResolver
{
    public const string LogFilename = "tiny11build.log";

    public static string Resolve(string? scratchDir)
    {
        if (!string.IsNullOrWhiteSpace(scratchDir))
            return Path.Combine(scratchDir, LogFilename);
        return Path.Combine(Path.GetTempPath(), LogFilename);
    }
}
