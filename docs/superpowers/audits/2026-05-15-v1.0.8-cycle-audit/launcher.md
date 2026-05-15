# Audit: C# launcher (v1.0.8 cycle)

**Date:** 2026-05-15
**Scope:** `launcher/**/*.cs` + `launcher/*.csproj` + `launcher/app.manifest` + `launcher/Tests/*.cs`
**Branch:** main at `285f7b6` (post-v1.0.7)
**Auditor:** parallel subagent (no session context)

## Summary

- BLOCKER: 0
- WARNING: 5
- INFO: 9

WARNING headlines:

- B1 — `BuildHandlers.CloseActiveLog` reads `Process.HasExited` / `ExitCode` after the Process has been disposed in the immediately preceding line.
- B2 — `start-build` race: a second `start-build` arriving while the first build is shutting down can have its log writer / per-run flags clobbered by the still-pending stderr-fallback finally block.
- B3 — `BuildHandlers` builds `powershell.exe` arg strings without escaping caller-controlled paths; an output ISO or scratch dir containing `"` lets a JS-side caller inject pwsh tokens.
- B4 — `Bridge.DispatchJsonAsync` returns `handler-error` on null deserialization but does not pass the original request `type` back, so JS state machines that key cleanup off `msg.type` cannot route the error.
- B5 — `tiny11maker.ps1` does not declare a `-OutputIso` parameter; the GUI wrappers do, but headless `tiny11options.exe` forwards `-Source/-Edition/-Config/-OutputPath` (README contract) — naming drift means `--log` users following the documented invocation are fine, but the launcher Web GUI uses `-OutputIso` against the wrapper and Headless uses `-OutputPath` against `tiny11maker.ps1`. (Documentation drift, not a code defect — flagged here for the docs-consistency agent.)

---

## B1 — `CloseActiveLog` accesses `Process` properties after `Dispose`

**Severity:** WARNING
**File:** `launcher/Gui/Handlers/BuildHandlers.cs:301-311`

```csharp
try { capturedBuild.Dispose(); } catch { /* dispose must not throw out of finally */ }
if (ReferenceEquals(_activeBuild, capturedBuild))
{
    _activeBuild = null;
    _activeSource = "";
    CloseActiveLog(capturedBuild.HasExited ? capturedBuild.ExitCode : (int?)null);
}
```

What's wrong: `capturedBuild.Dispose()` runs first; the immediately following `capturedBuild.HasExited` and `capturedBuild.ExitCode` reads are property accesses on a disposed Process. `System.Diagnostics.Process` documents these properties as throwing `InvalidOperationException` if the underlying handle has been released. In practice .NET caches `ExitCode` after `WaitForExitAsync`, so this usually appears to work — but the contract is undefined and a future .NET upgrade or a code path that races `Dispose` against the property read can throw an unobserved exception inside the `finally` block.

Why it matters: the exception is caught only by the outer `try { capturedBuild.Dispose(); } catch { }` (which doesn't cover lines 311) — there is no outer try around the entire finally. An ObjectDisposedException here propagates out of `Task.Run`, lands as an unobserved task exception, and (depending on `TaskScheduler.UnobservedTaskException` wiring) can be silently swallowed. The visible symptom would be the build-end footer never being written to the log.

Suggested fix direction: cache `HasExited` / `ExitCode` into locals BEFORE `Dispose`, then call `CloseActiveLog(localExit)` after Dispose.

---

## B2 — `start-build` race against still-running stderr-fallback finally

**Severity:** WARNING
**File:** `launcher/Gui/Handlers/BuildHandlers.cs:117-204` (reset + log open) vs `:295-313` (fallback finally)

What's wrong: `HandleAsync("start-build", ...)` resets `_terminalMarkerSeen`, `_cancelRequested`, sets `_activeSource`, opens `_activeLogWriter`, and assigns `_activeBuild` at line 219. The stderr-fallback Task from the PRIOR build can be running its `finally` block concurrently: it does `_activeBuild = null; _activeSource = "";` and `CloseActiveLog(...)` (lines 304-311).

The race: there is a `ReferenceEquals(_activeBuild, capturedBuild)` guard around the prior fallback's nulling — that protects against the SECOND build's `_activeBuild` getting wiped, BUT:

1. `_activeLogWriter` is NOT guarded by `ReferenceEquals` — it's an instance field with no per-run identity. If start-build #2 sets `_activeLogWriter` to writer-B at line 182 BEFORE start-build #1's fallback runs its finally block, `CloseActiveLog(...)` will close and dispose writer-B (the freshly opened writer for the new build), writing build-#1's "completed successfully" footer into build-#2's brand-new log file.
2. `_activeSource = "";` at line 305 is also not guarded — it's inside the `ReferenceEquals` guard at line 302, but a start-build #2 that wrote `_activeSource = src;` between the prior `WaitForExitAsync` returning and the `if (ReferenceEquals…)` evaluating will be silently overwritten back to empty string.

Why it matters: Log file corruption (build-#2 log opens with a "completed successfully" footer line at top); `_activeSource` cleared mid-build can cause a subsequent `DismountSourceIsoIfApplicable` to no-op when it should have run. The window is small (post-Kill to post-Dispose, milliseconds) but the user-visible path is "cancel then immediately start again" — which is exactly the scenario the existing `_activeSource` documentation warns about as a known race (lines 524-530 of the same file). The race is partially documented but the log-writer angle isn't.

Suggested fix direction: gate `_activeLogWriter` close on a per-run identity (capture the writer reference at start-build time the same way `capturedBuild` captures the Process); explicitly serialize the start-build path against any pending fallback Task (e.g., await any prior fallback Task before allowing a new build to start, OR move log-writer ownership onto the captured-build identity).

---

## B3 — Command-line injection via unescaped paths in `Build*Args`

**Severity:** WARNING
**File:** `launcher/Gui/Handlers/BuildHandlers.cs:446-503` (`BuildStandardArgs` + `BuildCoreArgs`); also `launcher/Gui/Handlers/CleanupHandlers.cs:143-155` (`BuildCleanupArgs`)

What's wrong: Every path-bearing parameter is wrapped in literal double quotes without escaping embedded `"` characters:

```csharp
args.Append(" -Source \"").Append(src).Append('"');
args.Append(" -OutputIso \"").Append(outputIso).Append('"');
args.Append(" -ScratchDir \"").Append(scratchDir).Append('"');
```

If `src`, `outputIso`, `scratchDir`, `mountDir`, `sourceDir`, `editionName`, or `configPath` contains a `"` character, the resulting command line breaks pwsh argument parsing in a caller-controlled way:

```
-Source "C:\evil"; & calc.exe; #.iso"
```

…would close the quote, terminate the argument, and let an attacker append arbitrary pwsh statements before the closing `#"` rejoins the original quote. The user-facing entry point is the JS payload (`payload?["source"]?.ToString()`), so an attacker can land this through:

1. A maliciously-crafted profile JSON that smuggles a quoted path into one of the load-profile-restored fields.
2. A future feature where any of these strings flows from URL parameters / clipboard paste.
3. Any callers that round-trip a path through the browser before sending it back.

Today's threat model is single-user-local-only (the EXE is admin-elevated and there's no remote attack surface), so the practical risk is LOW. But the launcher already shells out with admin privileges; an exploit chain here would be SYSTEM-level RCE through a path the JS validator accepts.

`PwshRunner` (`launcher/Gui/Subprocess/PwshRunner.cs:18-23`) DOES escape `"` to `\"`. The wrapper-argument builders in `BuildHandlers`/`CleanupHandlers` do NOT. Inconsistent escaping discipline across two sibling subprocess paths.

Suggested fix direction: factor the `QuoteIfNeeded` logic from `HeadlessRunner.cs:190-196` (which does escape `"`) into a shared helper and use it from all three argument builders. Add an xUnit test that asserts a path with embedded `"` is escaped, not passed through verbatim.

### B3-W1 — `DismountSourceIsoIfApplicable` only escapes `'`, not `"`

**File:** `launcher/Gui/Handlers/BuildHandlers.cs:564-571`

`var escaped = src.Replace("'", "''")` doubles single quotes (correct for the inner PS string literal) but the outer `-Command "..."` wrapper at line 570 is a Win32 command-line argument that uses double quotes. A source path containing `"` would close the outer Win32 string and let the rest of the path land outside any quotes. Compounds the same injection class as B3.

---

## B4 — `Bridge.DispatchJsonAsync` discards the original request `type` on malformed payload

**Severity:** WARNING
**File:** `launcher/Gui/Bridge/Bridge.cs:32-39, 50-52`

What's wrong: `handler-error` payloads carry only `{message: "..."}`. The original request `type` is not echoed back. JS state machines that key recovery off the request type (e.g., "the validate-iso I just sent failed, drop back to Step 1") can't distinguish a malformed-JSON / unknown-type / handler-threw error originating from a `validate-iso` request from one originating from a `start-build` request — both arrive as `{type: 'handler-error', payload: {message: '...'}}`.

Mitigation today: error messages start with the original type name (e.g., `"Unknown message type: validate-iso"`, `"Handler validate-iso threw: ..."`), so JS can sometimes substring-match. That's fragile and culture-sensitive.

Why it matters: makes JS-side error routing harder than it should be; encourages substring matching on user-facing message text.

Suggested fix direction: include `requestType: msg.Type` in every `handler-error` payload so JS can route by request type, not by string-grepping the message.

---

## B5 — `ConsoleAttach.AttachToParent` ignores the `AttachConsole` return value

**Severity:** WARNING
**File:** `launcher/Interop/ConsoleAttach.cs:17-23`

What's wrong: This is the v1.0.1 audit's A13 WARNING-1, partially fixed by the `--log` flag in v1.0.3 but still present in the code. `AttachConsole(ATTACH_PARENT_PROCESS)` returns FALSE when the parent has no console (piped scenario). The current implementation discards the return value and never falls back to `AllocConsole`. The v1.0.3 `--log` flag papers over this for headless users who know to pass it, but `tiny11options.exe -NonInteractive | Tee-Object out.log` (the form a CI user might naturally try) still silently drops output if `--log` isn't passed.

Why it matters: documented limitation in the v1.0.1 audit, deferred as "Option C" — still deferred. README does say "headless logging is opt-in" so the constraint is acknowledged, but a user pasting a `| Tee-Object` example from web search will get no output and no error.

Suggested fix direction: implement audit Option C (the long-term recommendation) — check `AttachConsole`'s return value, refresh `Console.Out` via `Console.SetOut(new StreamWriter(Console.OpenStandardOutput()))`, and fall back to `AllocConsole` if attach fails. Pair with the existing `--log` flag.

---

## A1 — `BridgeMessage.Payload` typed as `JsonObject?` everywhere, blocks schema evolution

**Severity:** INFO
**File:** `launcher/Gui/Bridge/BridgeMessage.cs:11-12`

Every handler does `payload?["fieldname"]?.ToString()` or `.GetValue<bool>()` against a raw `JsonObject`. There are no DTO types for the `start-build` / `validate-iso` / `theme-changed` / etc. payloads. Field-name typos compile cleanly; missing required fields silently become null/false defaults.

`BridgePayloadContractTests` catches the JS-vs-C# emit drift (every emitted Type has a JS handler branch) but doesn't catch C# read-side typos. A future maintenance pass might consider DTOs with `JsonPropertyName` attributes per request type (the cost is per-handler bloat, the benefit is compile-time field-name safety).

No fix required — flagged for future cycles.

---

## A2 — Velopack init order vs ArchitectureGate is correct (per v1.0.3 A2)

**Severity:** INFO (passes the load-bearing check)
**File:** `launcher/Program.cs:17-36`

Verified: `ArchitectureGate.CheckCurrentHost()` runs FIRST, returns its rejection message and exits with code 2 before any other startup code. `VelopackApp.Build().Run()` runs AFTER the arch check, BEFORE any other launcher work. This matches the v1.0.3 A2 commit's explicit ordering requirement and the docstring at `Program.cs:35-36` documents the constraint.

CHANGELOG v1.0.3 A2 entry: "The gate runs BEFORE `VelopackApp.Build().Run()` so no Velopack-side init fires in the rejection case." Code matches the claim. ✅

OSArchitecture-vs-ProcessArchitecture verified: `ArchitectureGate.CheckCurrentHost() => CheckSupportedHost(RuntimeInformation.OSArchitecture)` — correct per the v1.0.3 PRISM-emulation reasoning at `ArchitectureGate.cs:22-27`. ✅

---

## A3 — `MainWindow.SendJsonToJs` correctly marshals to UI thread

**Severity:** INFO (load-bearing check passes)
**File:** `launcher/MainWindow.xaml.cs:160-174`

The `Dispatcher.Invoke` wrapping `WebView.CoreWebView2.PostWebMessageAsString(json)` is correct — the WPF `WebView` field is a DependencyObject with thread affinity. Touching `.CoreWebView2` from a non-UI thread (e.g., `BuildHandlers`' Task.Run stdout reader) would throw the canonical WPF cross-thread exception.

The XML comment at lines 162-168 documents why this matters and references the historical async-push path that triggered the fix. Good documentation discipline.

`Dispatcher.Invoke` (synchronous, blocking) rather than `Dispatcher.BeginInvoke` (fire-and-forget) is the correct choice here — the JS-side handshake expects `request-update-check` to elicit a `update-available` response before the message pump unwinds, and the read-loop tasks already throttle naturally on the stdout pipe rate. No deadlock risk because no caller holds the UI thread blocked while a Task tries to `Invoke` back to it (the read loops run on thread-pool workers and the UI thread is idle in its message pump between dispatches).

---

## A4 — `MainWindow.InitializeWebViewAsync` swallows extraction failures with vague error text

**Severity:** INFO
**File:** `launcher/MainWindow.xaml.cs:148-157`

The catch block surfaces every failure as "WebView2 Runtime is required but could not be initialized." A file extraction failure in `ExtractRuntimeResourcesIfNeeded` (e.g., LOCALAPPDATA path read-only, disk full, AV blocking) will display the same WebView2-Runtime-blame message — sending the user down the wrong troubleshooting path (installing WebView2 won't help).

Suggested fix direction: split the catch into two — distinguish `CoreWebView2Environment.CreateAsync` / `EnsureCoreWebView2Async` failures (true WebView2-Runtime case) from IO failures (resource extraction case). Or surface the exception type / message verbatim and rely on the message for diagnosis.

No fix urgent; flagged for posterity.

---

## A5 — `MainWindow.ExtractIfManifestChanged` wipes target dir on EVERY manifest mismatch

**Severity:** INFO
**File:** `launcher/MainWindow.xaml.cs:268-302`

When the marker hash changes (first run, resource added, content edited), the entire target directory is wiped before re-extraction. Files inside that the user may have legitimately customized (e.g., `ui-cache/<version>/app.js` if they were debugging) are lost without warning.

For ui-cache and resources-cache (per-version subdirs under `%LOCALAPPDATA%\tiny11options`), this is intentional — they're a launcher-owned cache. But the wipe loop's `catch { /* best effort */ }` at line 281 means a locked file silently survives, leaving the cache in an inconsistent state where some files are old-version and some are new-version. The marker is rewritten at line 301 regardless, so the next launch trusts the half-old cache.

Suggested fix direction: if any file fails to delete during wipe, do not write the new marker at line 301 — leave the marker stale so the next launch retries the wipe. Or surface the partial-wipe failure as a startup warning.

---

## A6 — `BuildLogPathResolver` does not normalize or validate paths

**Severity:** INFO
**File:** `launcher/Gui/Handlers/BuildLogPathResolver.cs:15-20`

`Path.Combine(scratchDir, "tiny11build.log")` returns whatever scratchDir is. If scratchDir contains `..` segments (`C:\Temp\..\Windows`), the log writes to `C:\Windows\tiny11build.log`. The directory exists check in `BuildHandlers.HandleAsync` at line 178 (`Directory.CreateDirectory(logDir)`) will silently succeed since the parent is a real dir.

This is GUI-only (the user picks scratchDir via the file browser, which doesn't typically yield `..`), but the input is user-controlled.

Suggested fix direction: `Path.GetFullPath` to canonicalize before logging, and consider rejecting absolute paths outside scratchDir if defense-in-depth is desired. Today's risk is LOW.

---

## A7 — `UserSettings.Load` swallows ALL exceptions, masks corruption signal

**Severity:** INFO
**File:** `launcher/Gui/Settings/UserSettings.cs:36-47`

```csharp
catch { return new UserSettings(); }
```

A corrupted settings.json silently regenerates as defaults on next save. Users who hand-edited settings (LastProfilePath, WindowWidth/Height) and made a typo will see their settings reset to defaults without explanation. The `UserSettingsTests.Load_ReturnsDefaults_WhenJsonCorrupt` test enshrines this behavior.

Defensible per "settings persistence is best-effort" comment at `ProfileHandlers.cs:120`. Flagged here only because the behavior is invisible to the user — a one-line `Debug.WriteLine` on the catch path would aid diagnosis without changing user-visible behavior.

---

## A8 — `WindowHandlers.HandleAsync` close path uses `Application.Current?.Dispatcher.Invoke`, not `MainWindow.Dispatcher`

**Severity:** INFO
**File:** `launcher/Gui/Handlers/WindowHandlers.cs:23-27`

This works in practice because the application has a single `MainWindow` and `Application.Current.Dispatcher` resolves to the same one as `MainWindow.Dispatcher`. If a future change introduces a second window or per-window dispatchers, this becomes a subtle bug source.

Sibling handler `TitleBarThemeHandlers` (`MainWindow.xaml.cs:194-195`) captures the window via closure and uses `Dispatcher.Invoke` on the captured `this`. That's the correct pattern; `WindowHandlers` could mirror it.

No fix urgent.

---

## A9 — `HeadlessRunner.TryCleanup` swallows directory-delete failures

**Severity:** INFO
**File:** `launcher/Headless/HeadlessRunner.cs:220-224`

`try { Directory.Delete(dir, recursive: true); } catch { }` is intentional ("%TEMP% reaped at reboot") but means a locked file inside the extraction dir leaves the entire dir behind every run. Over time `%TEMP%\tiny11options-<pid>` directories accumulate. The reboot-reap is a real mechanism but %TEMP%-reaping is not aggressive — old PIDs can sit there indefinitely.

For a one-shot CLI invocation that's fine. For a CI loop running `tiny11options.exe` repeatedly without rebooting, this is a minor disk-space leak.

Suggested fix direction: sweep stale `tiny11options-*` dirs whose PID is not a live process at the start of `Run()`. Low priority.

---

## I1 — Test quality: BuildHandlers tests rely heavily on reflection

**Severity:** INFO
**File:** `launcher/Tests/BuildHandlersTests.cs:19-65, 89-103, 226-269, 309-331`

Many tests poke at `_cancelRequested`, `_terminalMarkerSeen`, `_activeSource`, and `ForwardJsonLine` via reflection because the SUT is a class with private state and no abstraction seam. The tests work, but:

1. Refactoring (rename the field, change the access modifier, convert to property) silently breaks tests that look like they should be insulated.
2. The reflection-driven tests assert on field shape rather than observable behavior. A consumer-driven test would be "after cancel-build, the next stdout-side build-error does not leak through" — instead we assert "_cancelRequested is true."
3. `InternalsVisibleTo` is wired (csproj:64) but the relevant fields are `private`, not `internal`.

The tradeoff is between simulating real subprocess behavior (high-fidelity, slow, hard-to-mock pwsh) and behavioral assertions. The current approach is pragmatic given the constraint, but the tests are tightly coupled to the implementation. Flagged for future cycles — a `IBuildOrchestrator` abstraction with a fake implementation would let the tests assert behavior without reflection.

---

## I2 — `BridgePayloadContractTests.OnPsHandlersInAppJs_OnlyAccess_MsgType_AndMsgPayload_NeverBareFields` regex is over-broad

**Severity:** INFO
**File:** `launcher/Tests/BridgePayloadContractTests.cs:60-67`

The regex `\bmsg\.([a-zA-Z_][a-zA-Z0-9_]*)\b` matches any identifier named `msg` followed by `.`. If `app.js` ever uses a variable named `msg` outside the bridge handler (e.g., a local variable in an unrelated function), the test fires a false positive. The test's allowlist is exactly `{type, payload}` — it has no scoping awareness.

Currently passes because `app.js` uses `msg` only inside the ps handler. A future refactor could trip this.

Suggested fix direction: scope the regex to the `function onPs(msg)` body (or to lines matching `msg.type === '...'` branches). Low priority.

---

## I3 — `EmbeddedResources.ExtractTo` reads-and-writes-without-buffering

**Severity:** INFO
**File:** `launcher/Headless/EmbeddedResources.cs:18-31`

`stream.CopyTo(fs)` uses the .NET default buffer (81920 bytes). For the small text/script resources here (largest is `tiny11maker.ps1` at ~20 KB), the buffer is bigger than the payloads. No perf issue; flagged only because `MainWindow.ExtractIfManifestChanged` uses an 8192-byte buffer in `ComputeManifestHash` (line 321) — minor inconsistency.

---

## I4 — `MainWindow.WebView2 SetVirtualHostNameToFolderMapping` security implications

**Severity:** INFO
**File:** `launcher/MainWindow.xaml.cs:75-78`

`SetVirtualHostNameToFolderMapping("app.local", _uiCacheDir, CoreWebView2HostResourceAccessKind.Allow)` exposes the entire `_uiCacheDir` tree as `http://app.local/*`. Since `_uiCacheDir` is `%LOCALAPPDATA%\tiny11options\ui-cache\<version>`, the WebView2 page can fetch any file under that path including (theoretically) files placed there by an attacker with local-write access to LOCALAPPDATA.

The mitigation is that the launcher requires admin elevation (`app.manifest`), so the LOCALAPPDATA user-tree is owned by the same admin context that's running the EXE — there's no privilege boundary to cross. Risk LOW.

For posterity: the `Allow` access kind is the most permissive value; `DenyCors` would block cross-origin access patterns. Today's app doesn't make cross-origin requests so `Allow` is fine, but if a future feature loads cross-origin (e.g., embedding GitHub release notes from `https://api.github.com`), revisit.

---

## I5 — `Bridge` class name collides with namespace `Tiny11Options.Launcher.Gui.Bridge`

**Severity:** INFO
**File:** `launcher/Gui/Bridge/Bridge.cs:9`

The type is `Tiny11Options.Launcher.Gui.Bridge.Bridge`, requiring callers to write `Bridge.Bridge` to disambiguate (see `BuildHandlers.cs:12`, `CleanupHandlers.cs:24`, `UpdateHandlers.cs` etc.). Style inconvenience, not a bug. Rename to `BridgeDispatcher` or rename the namespace.

---

## I6 — `tiny11maker.ps1` accepts `-OutputPath`, GUI wrappers accept `-OutputIso` — naming drift

**Severity:** INFO
**File:** cross-reference — `tiny11maker.ps1:51` (`-OutputPath`) vs `launcher/Gui/Handlers/BuildHandlers.cs:451-453` (`-OutputIso`) vs `tiny11maker-from-config.ps1:19` (`-OutputIso`)

The headless path (`tiny11options.exe -NonInteractive ...`) forwards user args verbatim to `tiny11maker.ps1` per README:74-114 — that path expects `-OutputPath` (as the README example at line 81 shows). The GUI path invokes `tiny11maker-from-config.ps1` which expects `-OutputIso`. Two different parameter names for the same concept, hidden from headless users by README convention but visible to anyone reading the wrapper scripts.

Not a launcher defect — flagged here for the docs-consistency agent. The split is intentional (GUI wrapper has a different parameter surface than the top-level script) but the asymmetry is worth surfacing.

---

## I7 — `UpdateNotifier.PendingUpdate` is mutated without synchronization

**Severity:** INFO
**File:** `launcher/Gui/Updates/UpdateNotifier.cs:9, 25`

`PendingUpdate { get; private set; }` is written inside `CheckAsync` (line 25), read potentially from any thread later. No `volatile` or lock. The reference assignment is atomic in .NET, but ordering is not guaranteed. Practical impact: tiny — a race here at worst causes `apply-update` to see a stale `PendingUpdate`, which the underlying VelopackUpdateSource handles by re-checking inside `ApplyAndRestartAsync`. Flagged for posterity.

---

## I8 — `VelopackUpdateSource.ApplyAndRestartAsync` double-fetches the update info

**Severity:** INFO
**File:** `launcher/Gui/Updates/VelopackUpdateSource.cs:27-33`

`CheckForUpdatesAsync` is called twice: once in `CheckAsync` (storing result in `UpdateNotifier.PendingUpdate`), then again in `ApplyAndRestartAsync` (the stored info is ignored, line 29 fetches a fresh `info`). Wasted HTTP round-trip to GitHub. The double-fetch is intentional defense-against-staleness — if the user took 10 minutes between seeing the update notification and clicking Apply, a fresh check is reasonable. But it's also a small UX hitch (1-2 seconds delay before download starts).

Suggested fix direction: store the `UpdateInfo` from the first check on `VelopackUpdateSource` and reuse it; refresh only if older than ~5 minutes. Low priority.

---

## I9 — `MainWindow.WebView2 userDataDir` shared across all installed versions

**Severity:** INFO
**File:** `launcher/MainWindow.xaml.cs:67-70`

```csharp
var userDataDir = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "tiny11options", "webview2-userdata");
```

Note no version segment. Unlike `_uiCacheDir` and `_resourcesDir` (which include `version` in the path at lines 215 and 225), `webview2-userdata` is shared across every version that's ever been installed. After a Velopack auto-update, the new version inherits the old version's WebView2 state (localStorage `tiny11-theme`, IndexedDB if used, ServiceWorker caches).

Generally desirable (theme preference persists across updates). But if a future version ships a breaking change to the localStorage schema, the inherited old-version state can wedge the new version. Velopack auto-update path is the relevant lifecycle.

No fix required; flagged for future migration discussions.

---

## Cross-reference verification

### README claims vs code

| Claim | Verified |
|---|---|
| `tiny11options.exe -NonInteractive ...` forwards args verbatim to `tiny11maker.ps1` (`HeadlessRunner.BuildPwshArgLine`) | ✅ `HeadlessRunner.cs:152-163` |
| `--log <path>` accepts space-form AND equals-form | ✅ `HeadlessArgs.cs:42-63` |
| `--log` / `--append` lowercase only | ✅ `StringComparison.Ordinal` in `HeadlessArgs.cs:42, 54, 65` |
| `--append` requires `--log` | ✅ `HeadlessArgs.cs:74-78` |
| Exit codes 0/1/2/10/11/12/13 | ✅ Cross-checked: `Program.cs:32` (2), `HeadlessRunner.cs:47,59,90,138` (12, 10, 13, 11) |
| WebView2 Runtime required error message | ✅ `MainWindow.xaml.cs:150-156` |
| Window size + LastProfilePath persisted in settings.json | ✅ `UserSettings.cs` + `MainWindow.xaml.cs:41-46` |
| AppVersion auto-syncs csproj `<Version>` → UI footer | ✅ `MainWindow.xaml.cs:135-138`, `AppVersion.cs`, `ui/app.js:1046-1047` |
| Architecture rejection (non-x64) exits 2 | ✅ `Program.cs:17-32` |

### CHANGELOG claims vs code

| Entry | Verified |
|---|---|
| v1.0.7: `window.__appVersion` injection alongside `__tinyCatalog` | ✅ `MainWindow.xaml.cs:127-138` |
| v1.0.7: `AppVersion.Current()` + `Format()` test split | ✅ `AppVersion.cs:11-22` + `AppVersionTests.cs` |
| v1.0.3 A2: ArchitectureGate runs BEFORE `VelopackApp.Build().Run()` | ✅ `Program.cs:17-36` |
| v1.0.3 A2: OSArchitecture (not ProcessArchitecture) | ✅ `ArchitectureGate.cs:60` |
| v1.0.3 A13: `--log` + `--append` parser, exit codes 12/13 | ✅ `HeadlessArgs.cs`, `HeadlessRunner.cs:47, 90` |
| v1.0.3 A13: GUI-side logging via `BuildLogPathResolver`, default ON | ✅ `BuildLogPathResolver.cs`, `BuildHandlers.cs:132-203` |
| v1.0.1: post-boot cleanup toggle wiring (`-NoPostBootCleanup`) | ✅ `BuildHandlers.cs:469-470, 501-502`; matches `tiny11maker-from-config.ps1:25` and `tiny11Coremaker-from-config.ps1:28` |
| v1.0.0 cancel-build behavior (Process.Kill + dismount) | ✅ `BuildHandlers.cs:44-90, 537-590` |

### tiny11maker.ps1 invocation contract vs HeadlessRunner

`tiny11maker.ps1` exposes (via `[CmdletBinding()]` param block lines 44-56): `-Source`, `-Config`, `-ImageIndex`, `-Edition`, `-ScratchDir`, `-OutputPath`, `-NonInteractive`, `-FastBuild`, `-NoPostBootCleanup`, `-Internal`. Exit codes: `1` (pwsh-from-pwsh rejection, `tiny11maker.ps1:120`), `0` (success, `:171`).

HeadlessRunner forwards user args verbatim — no contract enforcement at the launcher layer. README documents the expected flag list at README:91-94. If a user passes a misspelled flag, `tiny11maker.ps1` surfaces its own `ParameterBindingException`; no preflight validation in the launcher. This is documented as intentional in CHANGELOG v1.0.3 B11 ("`HeadlessRunner.BuildPwshArgLine` raw passthrough is the design").

---

## Test quality observations

- 113 xUnit tests is solid coverage breadth across handlers + bridge + headless + interop.
- Strong drift tests (B9 / EmbeddedResources sync, BridgePayloadContract emit/handle parity) — these are the type that catch real bugs.
- Heavy reflection usage in BuildHandlersTests (see I1) — works but couples tests to implementation shape.
- HeadlessRunnerTests has only 2 tests covering the arg-line builder. The bulk of HeadlessRunner is uncovered by xUnit (log writer setup, Process spawn, TeeStreamToLog, tempDir resolution, cleanup-on-failure). Those code paths are touched by smoke tests (A13-S1..S4 per CHANGELOG v1.0.3) but xUnit doesn't lock them in.
- No tests around `MainWindow.InitializeWebViewAsync` — understandable (WebView2 is hard to fake) but the resource-extraction logic is testable in isolation via `ComputeManifestHash` (which IS tested at `ResourceCacheHashTests.cs`).
- No tests around `UpdateHandlers` (only `UpdateNotifier` is tested). `UpdateHandlers.HandleAsync` has non-trivial branching on the `request-update-check` vs `apply-update` path and an exception-rethrow path — uncovered.
- No tests around `WindowHandlers` (close + open-folder). Both paths shell out (Application.Current.Dispatcher and Process.Start("explorer.exe")) — hard to fake but the param-validation arms (empty path, missing dir) are pure logic and could be tested.

Suggested addition: 3-5 xUnit tests covering `UpdateHandlers` + `WindowHandlers` validation paths; 5-8 more tests covering `HeadlessRunner` log-writer setup error paths (FileMode.Append with locked file, etc.).

---

## What I did NOT find

- No deadlock in the async/await usage patterns I reviewed.
- No leaked Process objects in normal flow (the captured-build + finally-dispose pattern in BuildHandlers is correct).
- No leaked StreamWriter outside the active-log-writer race (B2).
- No TOCTOU on the resources/ui-cache extraction — the hash-and-rewrite pattern is sound.
- No obvious cancellation-flow bugs beyond the documented races (the cancel-build → kill → dismount → flag-set sequence is carefully ordered with explicit comments at `BuildHandlers.cs:55-66`).
- Velopack `IsInstalled` guard at `VelopackUpdateSource.cs:19` correctly prevents update-check in dev-build mode.
- The `BridgePayloadContractTests` 743680f-bug regression guard is real coverage for a real bug class.
