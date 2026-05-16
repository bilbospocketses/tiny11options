using System;
using System.IO;

namespace Tiny11Options.Launcher.Gui;

// Returns a candidate scratch-directory path under %TEMP% with an 8-char
// random hex suffix. Used by the WebView2 UI to pre-populate the scratch
// field on Step 1 so the "all required fields filled" gate is satisfied
// out of the box without breaking today's no-typing convenience. Does NOT
// create the directory — the build pipeline creates it at build time, or
// the user replaces the path with their own choice before that point.
//
// Pattern parallels AppVersion.Current(): pure static helper, injected
// once at app launch via MainWindow.xaml.cs AddScriptToExecuteOnDocument-
// CreatedAsync into window.__autoScratchPath.
internal static class AutoScratchPath
{
    public static string Generate()
    {
        var suffix = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(4)).ToLowerInvariant();
        return Path.Combine(Path.GetTempPath(), $"tiny11-{suffix}");
    }
}
