using System;
using System.IO;

namespace Tiny11Options.Launcher.Gui;

// Returns a candidate scratch-directory path under <UserDocuments>\tiny11_outputs
// with an 8-char random hex suffix. Used by the WebView2 UI to pre-populate the
// scratch field on Step 1 so the "all required fields filled" gate is satisfied
// out of the box without breaking today's no-typing convenience. Does NOT create
// the directory — the build pipeline creates it at build time, or the user
// replaces the path with their own choice before that point.
//
// v1.0.11: relocated from %TEMP% to <UserDocuments>\tiny11_outputs. The launcher
// runs elevated (UAC consent) and historically %TEMP% resolution can surprise
// when the elevated session's TEMP differs from the interactive shell's TEMP.
// Anchoring to UserDocuments (an SHGetKnownFolderPath lookup tied to the user
// SID, stable across elevation under the same account) gives a predictable,
// user-visible location. Pairs with buildAutoOutputPath in ui/app.js, which
// derives the output ISO from the PARENT of scratchDir — so the default scratch
// "<Documents>\tiny11_outputs\tiny11-<hex>" yields output "<Documents>\tiny11_outputs\tiny11.iso".
//
// Pattern parallels AppVersion.Current(): pure static helper, injected once at
// app launch via MainWindow.xaml.cs AddScriptToExecuteOnDocumentCreatedAsync
// into window.__autoScratchPath.
internal static class AutoScratchPath
{
    public const string DefaultParentFolderName = "tiny11_outputs";

    public static string Generate()
    {
        var suffix = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(4)).ToLowerInvariant();
        var docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        return Path.Combine(docs, DefaultParentFolderName, $"tiny11-{suffix}");
    }
}
