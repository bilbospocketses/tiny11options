using System;
using System.Collections.Generic;

namespace Tiny11Options.Launcher.Headless;

// A13 (v1.0.3): pre-parses launcher-level flags out of the headless arg array
// before HeadlessRunner forwards the remainder to tiny11maker.ps1. Two flags
// today: --log <path> and --append. Both lowercase only -- mixed-case forms
// pass through to the wrapper script, which will surface its own
// "parameter not found" error.
internal readonly record struct HeadlessArgsResult(
    string? LogPath,
    bool Append,
    string[] Remaining,
    string? Error);

internal static class HeadlessArgs
{
    private const string LogFlag = "--log";
    private const string LogFlagEqPrefix = "--log=";
    private const string AppendFlag = "--append";

    // Strips --log <path> / --log=<path> / --append from `args`, returning the
    // extracted log path (if any), append-mode bool, and remaining args in
    // their original relative order. Error semantics:
    //   --log with no following arg     -> Error set, exit 12 at call site
    //   --log= with empty value         -> Error set
    //   --append without --log present  -> Error set (can't append to nothing)
    // Last-wins on duplicate --log occurrences. Case-sensitive match so the
    // wrapper script's own --Log / --LOG / etc. handling (or lack thereof)
    // remains the source of truth on mixed-case rejection.
    public static HeadlessArgsResult Extract(string[] args)
    {
        string? logPath = null;
        bool append = false;
        var remaining = new List<string>(args.Length);

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];

            if (a.StartsWith(LogFlagEqPrefix, StringComparison.Ordinal))
            {
                var value = a.Substring(LogFlagEqPrefix.Length);
                if (value.Length == 0)
                {
                    return new HeadlessArgsResult(null, false, Array.Empty<string>(),
                        "[tiny11options] --log= requires a non-empty path");
                }
                logPath = value;
                continue;
            }

            if (a == LogFlag)
            {
                if (i + 1 >= args.Length)
                {
                    return new HeadlessArgsResult(null, false, Array.Empty<string>(),
                        "[tiny11options] --log requires a file path argument");
                }
                logPath = args[++i];
                continue;
            }

            if (a == AppendFlag)
            {
                append = true;
                continue;
            }

            remaining.Add(a);
        }

        if (append && logPath == null)
        {
            return new HeadlessArgsResult(null, false, Array.Empty<string>(),
                "[tiny11options] --append requires --log <path> to also be present");
        }

        return new HeadlessArgsResult(logPath, append, remaining.ToArray(), null);
    }
}
