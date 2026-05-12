using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

/// <summary>
/// Static regression guard for the bridge payload-shape contract.
///
/// Catches the bug class fixed in commit `743680f`, where JS `onPs` handlers
/// read fields directly off the BridgeMessage envelope (`msg.foo`) instead of
/// the payload (`msg.payload.foo`). C#-side emits went through fine; JS
/// silently read undefined values; per-side unit tests both passed; the bug
/// was only caught during manual smoke. This test asserts the structural
/// patterns that prevent that class of bug.
///
/// Limitations (intentionally lightweight, ~1-hr scope per todo):
/// - Doesn't validate field-by-field that every C#-emitted JsonObject field
///   is consumed by JS. The per-field check would require parsing C# expression
///   trees for `["foo"] = bar` initializer syntax.
/// - Doesn't catch dynamic dispatch like `msg[someKey]`. Our code doesn't use
///   that pattern; if it ever did, this test wouldn't see it.
/// - Doesn't catch type-name typos (JS `msg.type === 'iso-validatd'`).
///
/// To extend with per-field contracts, add a third test that parses C# emit
/// blocks and asserts JS `p.<field>` is referenced inside the matching
/// `if (msg.type === '<type>')` branch.
/// </summary>
public class BridgePayloadContractTests
{
    private static readonly Lazy<string> RepoRoot = new(FindRepoRoot);

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, ".git")))
            dir = dir.Parent;
        if (dir is null)
            throw new InvalidOperationException(
                ".git directory not found walking up from " + AppContext.BaseDirectory +
                ". This test relies on running from inside the repo tree.");
        return dir.FullName;
    }

    [Fact]
    public void OnPsHandlersInAppJs_OnlyAccess_MsgType_AndMsgPayload_NeverBareFields()
    {
        // The 743680f bug: JS read `msg.foo` when C# emits payload field `foo`.
        // Fix: always go through `msg.payload.foo`. Allowed envelope accesses
        // are exactly `msg.type` (dispatch discriminator) and `msg.payload`
        // (the wrapped fields).
        var appJsPath = Path.Combine(RepoRoot.Value, "ui", "app.js");
        Assert.True(File.Exists(appJsPath), $"ui/app.js not found at {appJsPath}");
        var content = File.ReadAllText(appJsPath);

        var allowed = new HashSet<string> { "type", "payload" };
        var bareAccess = new Regex(@"\bmsg\.([a-zA-Z_][a-zA-Z0-9_]*)\b");
        var offenders = bareAccess.Matches(content)
            .Cast<Match>()
            .Select(m => m.Groups[1].Value)
            .Where(name => !allowed.Contains(name))
            .Distinct()
            .OrderBy(s => s)
            .ToList();

        Assert.True(offenders.Count == 0,
            "JS reads bare envelope fields (`msg.<field>`) other than `msg.type` " +
            "and `msg.payload`. This is the 743680f bug class — these reads will " +
            "always return undefined since C# emits payload fields under `payload`. " +
            "Found bare reads of: " + string.Join(", ", offenders));
    }

    [Fact]
    public void EveryCSharpEmittedType_HasJsHandlerBranch()
    {
        // For every `Type = "kebab-case"` emitted by C# code under launcher/
        // (excluding Tests/), there must be at least one `msg.type === 'kebab-case'`
        // branch in ui/app.js. Catches the "C# adds a new emit, JS forgot to
        // wire up the consumer" case.
        var appJsPath = Path.Combine(RepoRoot.Value, "ui", "app.js");
        var appJs = File.ReadAllText(appJsPath);

        var emittedTypes = ScanCSharpEmittedTypes();
        var handledTypes = new Regex(@"msg\.type\s*===\s*'([a-z-]+)'")
            .Matches(appJs)
            .Cast<Match>()
            .Select(m => m.Groups[1].Value)
            .ToHashSet();

        // The orphans-allowlist below is intentionally tiny. Add a name here ONLY
        // for types that are deliberately ACK-only (returned from HandleAsync to
        // confirm a request was received) and carry no semantic info JS needs to
        // process. Every other emitted type MUST have a `msg.type === '...'`
        // branch in app.js — that's the regression we're guarding.
        var orphansAllowlist = new HashSet<string>
        {
            // build-started: returned from BuildHandlers.HandleAsync as the
            // immediate response to a start-build request. Pure ACK. JS UI
            // has already transitioned to the build-in-progress state before
            // sending start-build (see app.js around line 315: ps() call is
            // fire-and-forget; the actual progress stream comes via the
            // separately-broadcast build-progress events).
            "build-started",
        };

        var orphans = emittedTypes
            .Except(handledTypes)
            .Except(orphansAllowlist)
            .OrderBy(s => s)
            .ToList();

        Assert.True(orphans.Count == 0,
            "C# emits BridgeMessage Type(s) that ui/app.js does not handle in any " +
            "`msg.type === '...'` branch. Either add a handler, or add the name to " +
            "the orphansAllowlist with a comment explaining the alternate consumer. " +
            "Orphans: " + string.Join(", ", orphans));
    }

    private static HashSet<string> ScanCSharpEmittedTypes()
    {
        // Walk launcher/ for *.cs files, excluding the Tests/ subdir to avoid
        // counting fixtures + mocks as production emits.
        var launcherDir = Path.Combine(RepoRoot.Value, "launcher");
        var testsDirSegment = Path.DirectorySeparatorChar + "Tests" + Path.DirectorySeparatorChar;

        // BridgeMessage construction: `Type = "kebab-case"` (object initializer
        // syntax). Sometimes wrapped in `new() { Type = "...", ... }` or
        // `new BridgeMessage { Type = "...", ... }` — both match.
        var typeEmit = new Regex(@"Type\s*=\s*""([a-z-]+)""");

        var types = new HashSet<string>();
        foreach (var file in Directory.EnumerateFiles(launcherDir, "*.cs", SearchOption.AllDirectories))
        {
            if (file.Contains(testsDirSegment, StringComparison.OrdinalIgnoreCase)) continue;
            var content = File.ReadAllText(file);
            foreach (Match m in typeEmit.Matches(content))
                types.Add(m.Groups[1].Value);
        }
        return types;
    }
}
