using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class BuildHandlers : IBridgeHandler
{
    private readonly Bridge.Bridge _bridge;
    private readonly string _resourcesDir;

    public BuildHandlers(Bridge.Bridge bridge, string resourcesDir)
    {
        _bridge = bridge;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "start-build", "cancel-build" };

    private Process? _activeBuild;
    // Persisted from start-build so cancel-build / stderr-fallback can dismount
    // the source ISO if the build process was killed mid-preflight (before its
    // own try/finally Dismount-Tiny11Source ran). Process.Kill bypasses finally
    // blocks entirely, so without this catch-all the user is left with a phantom
    // virtual drive until they reboot or manually dismount.
    private string _activeSource = "";

    // A13 (v1.0.3): optional per-build log writer. Opened in start-build when
    // the Step 1 "Log build output" checkbox is on (logBuildOutput=true in the
    // payload), teed from ForwardJsonLine on every JSON marker, closed in the
    // stderr-fallback Task's finally block (covers normal completion, errors,
    // cancellation, and abnormal exits in one place). _logLock serializes the
    // three writer threads: stdout reader (ForwardJsonLine), stderr-fallback,
    // and the cancel handler on the WebView2 message-pump thread.
    private StreamWriter? _activeLogWriter;
    private readonly object _logLock = new();

    public async Task<Bridge.BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "cancel-build")
        {
            // PORTED: tiny11maker.ps1:289 (legacy `cancel` handler). Legacy used a
            // CancellationTokenSource on the runspace worker; the worker observed
            // cancellation and posted build-error {message="...cancelled..."}, which
            // JS handles via its existing build-error path (renders error screen).
            // We emulate that by sending build-error directly here so JS doesn't
            // need a separate build-cancelled handler -- and the wizard exits the
            // progress state cleanly. The Process.Kill stops the actual work; this
            // bridge message stops the UI hang.
            //
            // CRITICAL ORDER: set _terminalMarkerSeen + _cancelRequested BEFORE Kill().
            // Kill(entireProcessTree: true) walks the process tree signalling each
            // child and can block briefly; during that window, the stderr-fallback
            // Task awaiting WaitForExitAsync can wake up the instant the root process
            // dies, run its !_terminalMarkerSeen check, see false, and fire a
            // spurious "Build process exited with code -1 and no output" build-error
            // that overwrites the friendly "Build cancelled by user." message in JS.
            // Setting both flags first closes that race window; _cancelRequested is
            // the belt-and-suspenders guard the fallback uses to convert any
            // post-cancel build-error into the cancel message even if the timing
            // somehow still slips. C5g iteration-4 regression: 2026-05-12.
            _terminalMarkerSeen = true;
            _cancelRequested = true;
            // Kill can throw InvalidOperationException (process already exited
            // between our HasExited checks elsewhere and this call) or
            // Win32Exception (rare AccessDenied on locked-down child). Swallow:
            // flags are already set; we still need to fire dismount + return the
            // friendly build-error below. Without this catch the exception would
            // propagate to the bridge dispatcher and JS would see no build-error,
            // leaving the UI stuck on the progress screen.
            try { _activeBuild?.Kill(entireProcessTree: true); }
            catch { /* see note above */ }
            // Catch-all: dismount the source ISO if the build was cancelled mid-
            // preflight (Phase 1 mounts the ISO, copies to scratch, dismounts in
            // a try/finally -- but Process.Kill bypasses finally entirely, so a
            // cancel during the copy leaves the ISO mounted to a phantom drive).
            // Idempotent: silently no-ops if the ISO isn't currently attached.
            // Fire-and-forget so the UI thread isn't blocked by the 10s timeout.
            // See DismountSourceIsoIfApplicable XML comment for the accepted-race note.
            _ = DismountSourceIsoIfApplicable();
            return new Bridge.BridgeMessage
            {
                Type = "build-error",
                Payload = new JsonObject { ["message"] = "Build cancelled by user." },
            };
        }

        if (_activeBuild is { HasExited: false })
            return Error("a build is already in progress");

        // PORTED: tiny11maker.ps1:271-278 (legacy `build` worker payload reads).
        // Legacy reads source / imageIndex / scratchDir / outputPath / unmountSource /
        // fastBuild / selections from the JS payload and passes them all to
        // Invoke-Tiny11BuildPipeline. Path C must do the same — the prior scaffold
        // forwarded only Source / OutputIso / Edition and dropped scratchDir,
        // unmountSource, fastBuild, imageIndex on the floor.
        var src = payload?["source"]?.ToString() ?? "";
        var outputIso = payload?["outputIso"]?.ToString() ?? "";
        var scratchDir = payload?["scratchDir"]?.ToString() ?? "";

        // Defense in depth: the UI gates Build ISO on a non-empty output path, but a
        // headless/CLI path or future code change could bypass that. The build scripts
        // ValidateNotNullOrEmpty -OutputIso so pwsh bombs at parameter binding with
        // ParameterArgumentValidationErrorEmptyStringNotAllowed -- surface a friendly
        // error here instead of spawning a doomed subprocess.
        if (string.IsNullOrWhiteSpace(outputIso))
            return Error("Output ISO path is required. Set the Output ISO field on the Build step before clicking Build ISO.");
        if (string.IsNullOrWhiteSpace(src))
            return Error("Source path is required. Choose an ISO or DVD on Step 1 before building.");

        // Reset per-run flags BEFORE spawning the build process so a prior cancelled
        // run's flag state doesn't bleed into this one. Without the reset,
        // _terminalMarkerSeen=true (set by a prior cancel) would persist and the
        // stderr-fallback would silently skip on a legitimate post-reset crash.
        _terminalMarkerSeen = false;
        _cancelRequested = false;
        _activeSource = src;
        var unmountSource = payload?["unmountSource"]?.GetValue<bool>() ?? false;
        var fastBuild = payload?["fastBuild"]?.GetValue<bool>() ?? false;
        var installPostBootCleanup = payload?["installPostBootCleanup"]?.GetValue<bool>() ?? true;
        var coreMode = payload?["coreMode"]?.GetValue<bool>() ?? false;
        var enableNet35 = payload?["enableNet35"]?.GetValue<bool>() ?? false;
        // A13 (v1.0.3): Step 1 "Log build output" checkbox + indented "Append to
        // existing log" checkbox. Default is logging ON / append OFF in the UI;
        // we default both to false here so a payload missing the keys (older JS
        // build, malformed message) doesn't surprise-create a log file. JS state
        // always sends both keys.
        var logBuildOutput = payload?["logBuildOutput"]?.GetValue<bool>() ?? false;
        var appendLog = payload?["appendLog"]?.GetValue<bool>() ?? false;

        // JS-side `state.edition` is the integer ImageIndex (set in app.js:527
        // from p.editions[0].index). Treat it as ImageIndex by default; only fall
        // back to -Edition (the human-readable name) if the value isn't numeric.
        var editionRaw = payload?["edition"];
        int imageIndex = 0;
        string editionName = "";
        if (editionRaw is not null)
        {
            if (editionRaw.GetValueKind() == JsonValueKind.Number)
                imageIndex = editionRaw.GetValue<int>();
            else if (int.TryParse(editionRaw.ToString(), out var parsed))
                imageIndex = parsed;
            else
                editionName = editionRaw.ToString();
        }

        string psArgs;
        if (coreMode)
        {
            psArgs = BuildCoreArgs(_resourcesDir, src, outputIso, scratchDir, imageIndex, editionName, unmountSource, enableNet35, fastBuild, installPostBootCleanup);
        }
        else
        {
            var configPath = Path.Combine(_resourcesDir, $"build-config-{Guid.NewGuid():N}.json");
            await File.WriteAllTextAsync(configPath, payload?.ToJsonString() ?? "{}");
            psArgs = BuildStandardArgs(_resourcesDir, configPath, src, outputIso, scratchDir, imageIndex, editionName, unmountSource, fastBuild, installPostBootCleanup);
        }

        // A13: open the build log writer BEFORE Process.Start. A failure to open
        // the log file is non-fatal -- we surface a single warning marker on the
        // build-progress stream so the user sees it without aborting the build.
        // Path resolves via BuildLogPathResolver (scratchDir/tiny11build.log,
        // falling back to %TEMP%/tiny11build.log when scratchDir is blank).
        // Defensive: dispose any leaked writer from a prior failed Process.Start
        // before opening a fresh one (the stderr-fallback finally only closes
        // the writer when a Process actually started).
        CloseActiveLog(null);
        if (logBuildOutput)
        {
            var logPath = BuildLogPathResolver.Resolve(scratchDir);
            try
            {
                var logDir = Path.GetDirectoryName(logPath);
                if (!string.IsNullOrEmpty(logDir))
                    Directory.CreateDirectory(logDir);
                var mode = appendLog ? FileMode.Append : FileMode.Create;
                var stream = new FileStream(logPath, mode, FileAccess.Write, FileShare.Read);
                _activeLogWriter = new StreamWriter(stream) { AutoFlush = true };
                _activeLogWriter.WriteLine($"==== tiny11options GUI build started {DateTime.Now:yyyy-MM-dd HH:mm:ss} ====");
                _activeLogWriter.WriteLine($"     source={src}");
                _activeLogWriter.WriteLine($"     output={outputIso}");
                if (!string.IsNullOrWhiteSpace(scratchDir))
                    _activeLogWriter.WriteLine($"     scratch={scratchDir}");
                _activeLogWriter.WriteLine($"     mode={(coreMode ? "Core" : "Standard")}, fastBuild={fastBuild}, postBootCleanup={installPostBootCleanup}, appendLog={appendLog}");
            }
            catch (Exception ex)
            {
                _activeLogWriter = null;
                _bridge.SendToJs(new Bridge.BridgeMessage
                {
                    Type = "build-progress",
                    Payload = new JsonObject
                    {
                        ["phase"] = "log",
                        ["step"] = $"[warning] Could not open build log at '{logPath}': {ex.Message} -- build will proceed without logging.",
                        ["percent"] = 0,
                    },
                });
            }
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = psArgs,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = _resourcesDir,
        };

        try
        {
            _activeBuild = Process.Start(psi);
        }
        catch
        {
            // Close the log writer before re-throwing so we don't leak the file
            // handle into the bridge dispatcher's exception path. The bridge
            // will surface the exception to JS via its generic handler-error
            // route; without this catch, the writer would stay open until the
            // next start-build, blocking the file on the next attempt.
            CloseActiveLog(null);
            throw;
        }
        if (_activeBuild is null)
        {
            CloseActiveLog(null);
            return Error("Failed to spawn pwsh for build");
        }

        // Stream stdout line-by-line. The wrapper writes ALL bridge traffic
        // (build-progress, build-complete, build-error) to STDOUT — single forwarder
        // routes everything by `type`.
        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await _activeBuild.StandardOutput.ReadLineAsync()) is not null)
                {
                    ForwardJsonLine(line);
                }
            }
            catch { /* read loop must not crash bridge */ }
        });

        // STDERR fallback: if the wrapper crashes BEFORE its catch block (e.g. parse
        // error, ImportModule failure), it never writes a build-error JSON marker.
        // Capture stderr and emit build-error on non-zero exit only when no
        // build-error / build-complete has come through stdout.
        // Capture _activeBuild AND _activeLogWriter AND _activeSource into the
        // closure so the finally block can dispose the right Process, close the
        // right writer, and clear the right source path even if a fresh
        // start-build has replaced any of these instance fields before this
        // fallback Task runs to completion.
        // v1.0.8 audit WARNING launcher B2: per-run identity capture for all
        // three fields. Pre-fix, only _activeBuild had the ReferenceEquals
        // guard; _activeLogWriter (line 182 writer-open is BEFORE line 219
        // process-start) and _activeSource (set at start-build entry) could
        // already point at the NEW build's values during the audit's window.
        // The finally would then close the new writer and wipe the new source.
        var capturedBuild = _activeBuild;
        var capturedWriter = _activeLogWriter;
        var capturedSource = _activeSource;
        _ = Task.Run(async () =>
        {
            try
            {
                await capturedBuild.WaitForExitAsync();
                // Belt-and-suspenders: if _cancelRequested is set, the cancel handler
                // already returned the "Build cancelled by user." build-error and JS
                // rendered it. Skip the fallback entirely so we never overwrite that
                // with the misleading "exit -1" message. The _terminalMarkerSeen check
                // covers the normal completion/error paths.
                if (_cancelRequested || _terminalMarkerSeen) return;
                // Abnormal exit BEFORE the script's own try/finally ran (parse error,
                // ImportModule failure, etc.) -- the source ISO may still be attached
                // if the crash landed between Mount-Tiny11Source and Dismount-Tiny11Source.
                // Same catch-all as the cancel handler; idempotent if not mounted.
                // We're already on a Task.Run background thread here, so awaiting
                // is fine -- and we want the dismount to complete before the
                // build-error reaches JS so users see consistent state.
                await DismountSourceIsoIfApplicable();
                if (capturedBuild.ExitCode != 0)
                {
                    var err = await capturedBuild.StandardError.ReadToEndAsync();
                    _bridge.SendToJs(new Bridge.BridgeMessage
                    {
                        Type = "build-error",
                        Payload = new JsonObject
                        {
                            ["message"] = string.IsNullOrWhiteSpace(err)
                                ? $"Build process exited with code {capturedBuild.ExitCode} and no output"
                                : err.Trim(),
                        },
                    });
                }
            }
            finally
            {
                // Release the Process handle + std stream buffers and clear the
                // stale source path. If a new start-build raced this Task and
                // already replaced _activeBuild, ReferenceEquals keeps us from
                // nulling the fresh reference; only clear the slots we owned.
                // v1.0.8 audit WARNING launcher B1: cache HasExited/ExitCode to
                // locals BEFORE Dispose -- Process docs warn that accessing
                // these properties on a disposed Process is contract-undefined
                // (InvalidOperationException risk). HasExited itself can throw
                // if the process never started, so wrap in its own try/catch.
                int? cachedExitCode = null;
                try { if (capturedBuild.HasExited) { cachedExitCode = capturedBuild.ExitCode; } } catch { /* HasExited can throw if process never started */ }
                try { capturedBuild.Dispose(); } catch { /* dispose must not throw out of finally */ }
                if (ReferenceEquals(_activeBuild, capturedBuild))
                {
                    _activeBuild = null;
                }
                // v1.0.8 audit B2: gate _activeSource clear on per-build identity
                // (string equality since ReferenceEquals on interned strings is
                // unreliable). Pre-fix this was inside the process-identity
                // guard but the race lets _activeSource diverge from
                // _activeBuild in the writer-open → process-start window.
                if (_activeSource == capturedSource)
                {
                    _activeSource = "";
                }
                // v1.0.8 audit B2: gate CloseActiveLog on writer identity. A13
                // semantics preserved -- still covers normal completion,
                // build-error, cancel, and abnormal exits.
                if (ReferenceEquals(_activeLogWriter, capturedWriter))
                {
                    CloseActiveLog(cachedExitCode);
                }
            }
        });

        return new Bridge.BridgeMessage { Type = "build-started", Payload = new JsonObject() };
    }

    // Both flags use `volatile` so writes from the cancel handler (HandleAsync runs
    // on the WebView2 message-pump thread) are immediately visible to the stderr-
    // fallback Task (running on a thread pool worker, resuming after
    // WaitForExitAsync). Plain bool fields are atomic but unordered in the C#
    // memory model; volatile gives us release-acquire semantics so the flag-then-
    // Kill sequence in the cancel handler is observed in order on the fallback side.
    private volatile bool _terminalMarkerSeen;
    private volatile bool _cancelRequested;

    private void ForwardJsonLine(string line)
    {
        try
        {
            var node = JsonNode.Parse(line) as JsonObject;
            var t = node?["type"]?.ToString();
            if (t is "build-progress" or "build-complete" or "build-error")
            {
                if (t is "build-complete" or "build-error") _terminalMarkerSeen = true;
                // Race guard against the d637289-flagged double-emit case: when the
                // wrapper script writes a build-error to stdout milliseconds before
                // our Kill arrives (e.g. the pipeline's own catch fired on a
                // different abort path), the cancel handler has already sent its
                // own "Build cancelled by user." build-error. Suppress this
                // stdout-sourced one so JS doesn't receive two back-to-back
                // build-errors. Reviewer marked 🟡 not 🔴 because the later cancel
                // message wins in JS rendering, so the behavior was correct but
                // the cause-of-failure ordering was reversed on screen. Note we
                // still set _terminalMarkerSeen above before this gate -- that
                // protects the stderr-fallback Task from firing a spurious
                // post-exit message. build-progress / build-complete are NOT
                // gated: surplus progress is harmless, and build-complete with
                // _cancelRequested=true means the script raced past our Kill and
                // actually finished -- surfacing the success is fine.
                if (t is "build-error" && _cancelRequested) return;
                // A13: tee a human-readable form of the marker to the build log
                // BEFORE the SendToJs dispatch (so a SendToJs exception below
                // doesn't silently drop the log line). Skip when no log is open.
                var payloadForLog = node!["payload"] as JsonObject;
                WriteToLog(BuildLogMessage(t, payloadForLog));
                // DeepClone the payload so the new BridgeMessage owns it cleanly.
                // Without the clone, node["payload"] is still parented under `node`
                // and System.Text.Json throws "node already has a parent" when
                // re-serializing inside Bridge.SendToJs. Throw inside this Task.Run
                // reader is unobserved, which would silently drop the marker.
                var payloadClone = node["payload"]?.DeepClone() as JsonObject;
                try { _bridge.SendToJs(new Bridge.BridgeMessage { Type = t, Payload = payloadClone }); }
                catch { /* SendToJs must not crash the read loop */ }
            }
        }
        catch { /* malformed line — ignore */ }
    }

    // A13: render a JSON marker as one log line. build-progress carries
    // {phase, step, percent} plus optional mount-state fields; build-complete
    // carries {outputPath}; build-error carries {message}. Anything else gets
    // a generic "[type] <json>" rendering so we never silently drop content.
    private static string BuildLogMessage(string type, JsonObject? payload)
    {
        if (payload is null) return $"[{type}]";
        switch (type)
        {
            case "build-progress":
                var phase = payload["phase"]?.ToString() ?? "";
                var step = payload["step"]?.ToString() ?? "";
                var pctNode = payload["percent"];
                var pct = pctNode is null ? "" : $" {pctNode}%";
                return string.IsNullOrEmpty(phase) ? step : $"[{phase}]{pct} {step}";
            case "build-complete":
                var outputPath = payload["outputPath"]?.ToString() ?? "(unknown)";
                return $"[build-complete] output={outputPath}";
            case "build-error":
                var message = payload["message"]?.ToString() ?? payload.ToJsonString();
                return $"[build-error] {message}";
            default:
                return $"[{type}] {payload.ToJsonString()}";
        }
    }

    // A13: thread-safe write to the active build log. Silent no-op when no
    // log is open. The lock serializes against CloseActiveLog and against
    // the cancel-handler / stderr-fallback writers; the inner try/catch
    // swallows transient write failures (disk full, writer racing dispose)
    // so the read loop / cancel handler never crashes the launcher over a
    // log-side issue.
    private void WriteToLog(string text)
    {
        var writer = _activeLogWriter;
        if (writer is null) return;
        lock (_logLock)
        {
            if (_activeLogWriter is null) return;
            try { _activeLogWriter.WriteLine(text); } catch { /* log-side never fatal */ }
        }
    }

    // A13: write a build-end footer and dispose the writer. Called from the
    // stderr-fallback Task's finally block (single owner of the lifecycle).
    // Passing exitCode null indicates "ended without a known exit code"
    // (e.g. cancelled before Process.Start succeeded).
    private void CloseActiveLog(int? exitCode)
    {
        lock (_logLock)
        {
            var writer = _activeLogWriter;
            if (writer is null) return;
            try
            {
                string status = _cancelRequested
                    ? "cancelled by user"
                    : exitCode is null
                        ? "ended (no exit code captured)"
                        : exitCode == 0
                            ? "completed successfully"
                            : $"failed (exit {exitCode})";
                writer.WriteLine($"==== tiny11options GUI build {status} {DateTime.Now:yyyy-MM-dd HH:mm:ss} ====");
                writer.WriteLine();
                writer.Flush();
                writer.Dispose();
            }
            catch { /* dispose-side never fatal */ }
            _activeLogWriter = null;
        }
    }

    // Extracted for testability: builds the powershell.exe -Arguments string for
    // the standard (non-Core) build path. Callers that need to unit-test routing
    // logic can invoke this via reflection without spawning a real process.
    internal static string BuildStandardArgs(
        string resourcesDir,
        string configPath,
        string src,
        string outputIso,
        string scratchDir,
        int imageIndex,
        string editionName,
        bool unmountSource,
        bool fastBuild,
        bool installPostBootCleanup = true)
    {
        var script = Path.Combine(resourcesDir, "tiny11maker-from-config.ps1");
        var args = new System.Text.StringBuilder("-ExecutionPolicy Bypass -NoProfile -File ");
        args.Append('"').Append(script).Append('"');
        args.Append(" -ConfigPath \"").Append(configPath).Append('"');
        args.Append(" -Source \"").Append(src).Append('"');
        args.Append(" -OutputIso \"").Append(outputIso).Append('"');
        if (imageIndex > 0) args.Append(" -ImageIndex ").Append(imageIndex);
        if (!string.IsNullOrEmpty(editionName)) args.Append(" -Edition \"").Append(editionName).Append('"');
        if (!string.IsNullOrEmpty(scratchDir)) args.Append(" -ScratchDir \"").Append(scratchDir).Append('"');
        if (unmountSource) args.Append(" -UnmountSource");
        if (fastBuild) args.Append(" -FastBuild");
        if (!installPostBootCleanup) args.Append(" -NoPostBootCleanup");
        return args.ToString();
    }

    // Extracted for testability: builds the powershell.exe -Arguments string for
    // the Core build path. No -ConfigPath, no selections — Core has no catalog.
    // -FastBuild is honored (since 2026-05-11): when set, Phase 20 /Compress:max
    // and Phase 22 /Compress:recovery skip, saving ~20-40 min per build at the
    // cost of a larger ISO.
    internal static string BuildCoreArgs(
        string resourcesDir,
        string src,
        string outputIso,
        string scratchDir,
        int imageIndex,
        string editionName,
        bool unmountSource,
        bool enableNet35,
        bool fastBuild,
        bool installPostBootCleanup = true)
    {
        var script = Path.Combine(resourcesDir, "tiny11Coremaker-from-config.ps1");
        var args = new System.Text.StringBuilder("-ExecutionPolicy Bypass -NoProfile -File ");
        args.Append('"').Append(script).Append('"');
        args.Append(" -Source \"").Append(src).Append('"');
        args.Append(" -OutputIso \"").Append(outputIso).Append('"');
        if (imageIndex > 0) args.Append(" -ImageIndex ").Append(imageIndex);
        if (!string.IsNullOrEmpty(editionName)) args.Append(" -Edition \"").Append(editionName).Append('"');
        if (!string.IsNullOrEmpty(scratchDir)) args.Append(" -ScratchDir \"").Append(scratchDir).Append('"');
        if (enableNet35) args.Append(" -EnableNet35");
        if (unmountSource) args.Append(" -UnmountSource");
        if (fastBuild) args.Append(" -FastBuild");
        if (!installPostBootCleanup) args.Append(" -NoPostBootCleanup");
        return args.ToString();
    }

    private static Bridge.BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };

    // Catch-all dismount for the source ISO when a build was killed or crashed
    // before its own try/finally Dismount-Tiny11Source could run. Only acts on
    // .iso file paths -- a bare drive letter source means the user mounted the
    // ISO externally and we have no business unmounting it. Idempotent: if the
    // ISO isn't currently attached, Dismount-DiskImage with SilentlyContinue
    // returns without error. 10s timeout cap so a hung Dismount can't wedge
    // any caller indefinitely.
    //
    // d637289 code-review item: this previously ran synchronously on the
    // WebView2 message-pump thread when invoked from the cancel handler, so
    // a 10s timeout would freeze the UI for up to 10s. Now: the active-source
    // check is synchronous (captures _activeSource into a local), but the
    // shell-out runs on the thread pool via Task.Run. Caller chooses whether
    // to await (background-thread callers like the stderr-fallback) or
    // fire-and-forget (UI-thread cancel handler).
    //
    // Known race accepted per reviewer guidance ("users can accept best-effort
    // dismount and don't need synchronous confirmation"): if the user cancels
    // a build and then IMMEDIATELY starts a new build with the same source
    // path, the cancel's still-pending dismount Task could fire after the new
    // build's mount and break it. Practically this requires sub-second user
    // re-action against a typical 1-3s dismount. If it ever surfaces, gate
    // start-build on awaiting any prior dismount Task before re-mounting.
    //
    // NOTE on Local-Dependencies-Only policy: this shells out to powershell.exe
    // via system PATH, which is explicitly covered by the dependency policy
    // waiver in project_tiny11options_dependency_policy.md (vendoring PS5.1 is
    // impractical for this app; the launcher already shells out to it for
    // build / cleanup scripts).
    private Task DismountSourceIsoIfApplicable()
    {
        // Capture into a local synchronously so a fresh start-build replacing
        // _activeSource can't swap the path out from under the background
        // shell-out. Pre-checks also run sync to avoid spinning up a Task
        // for the common no-op case (no active source / non-.iso).
        //
        // COUPLED CONSTRAINT (d637289 review item): the EndsWith(".iso") filter
        // is correct ONLY because the upstream `Resolve-Tiny11Source` in
        // `src/Tiny11.Iso.psm1` rejects file paths that don't match `*.iso`.
        // If validate-iso is ever loosened to accept `.img` or extension-less
        // files (Windows Setup media on USB is sometimes `.img`), this filter
        // must be updated to match -- otherwise the user's mounted source will
        // stay attached after a build cancel. The paired Pester test in
        // `tests/Tiny11.Iso.Tests.ps1` ("rejects non-.iso file paths like .img")
        // locks in the upstream side; both sides must change together.
        var src = _activeSource;
        if (string.IsNullOrWhiteSpace(src)) return Task.CompletedTask;
        if (!src.EndsWith(".iso", StringComparison.OrdinalIgnoreCase)) return Task.CompletedTask;
        if (!File.Exists(src)) return Task.CompletedTask;

        return Task.Run(() =>
        {
            try
            {
                // `'` doubling escapes any single-quote in the path; .iso paths almost
                // never contain quotes but be safe. -ErrorAction SilentlyContinue makes
                // the not-currently-attached case a no-op.
                var escaped = src.Replace("'", "''");
                var cmd = $"Dismount-DiskImage -ImagePath '{escaped}' -ErrorAction SilentlyContinue | Out-Null";
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -NonInteractive -Command \"{cmd}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                using var p = Process.Start(psi);
                if (p is null) return;
                if (!p.WaitForExit(10_000))
                {
                    try { p.Kill(entireProcessTree: true); } catch { }
                }
            }
            catch
            {
                // Never crash on dismount failure -- leaving the ISO mounted is
                // worse UX but recoverable; throwing here would surface as an
                // unobserved Task exception (or block the caller if awaited).
            }
        });
    }
}
