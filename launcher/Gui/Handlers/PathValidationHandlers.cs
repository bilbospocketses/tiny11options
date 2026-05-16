using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class PathValidationHandlers : IBridgeHandler
{
    public IEnumerable<string> HandledTypes => new[] { "validate-scratch", "validate-output" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var path = payload?["path"]?.ToString() ?? "";

        BridgeMessage response;

        if (type == "validate-scratch")
        {
            var (valid, message) = ValidateScratchPath(path);
            response = new BridgeMessage
            {
                Type = "validated-scratch",
                Payload = new JsonObject
                {
                    ["path"]    = path,
                    ["valid"]   = valid,
                    ["message"] = message,
                },
            };
        }
        else // validate-output
        {
            var (valid, message) = ValidateOutputPath(path);
            response = new BridgeMessage
            {
                Type = "validated-output",
                Payload = new JsonObject
                {
                    ["path"]    = path,
                    ["valid"]   = valid,
                    ["message"] = message,
                },
            };
        }

        return Task.FromResult<BridgeMessage?>(response);
    }

    internal static (bool Valid, string Message) ValidateScratchPath(string path)
    {
        path = (path ?? "").Trim();
        if (string.IsNullOrEmpty(path)) return (false, "Scratch directory is required.");
        if (!LooksLikeWindowsPath(path)) return (false, "Not a valid Windows path format (expected drive-letter path like C:\\path or UNC \\\\server\\share).");

        try
        {
            // Parent-dir-exists check. Path.GetDirectoryName returns null for root paths
            // like "C:\\" -- that's fine, no parent to check.
            var parent = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(parent) && !Directory.Exists(parent))
            {
                return (false, $"Parent directory does not exist: {parent}");
            }
            // If the path itself exists, it must be a directory (not a file).
            if (File.Exists(path))
            {
                return (false, "Path exists but is a file, not a directory.");
            }

            // Writability probe. Probe the parent (or the path itself if it already
            // exists as a directory). If the parent isn't usable as a probe target
            // (e.g. drive-root edge case), skip rather than block -- the existence
            // checks above already covered the structural correctness.
            var probeTarget = !string.IsNullOrEmpty(parent) && Directory.Exists(parent)
                ? parent
                : (Directory.Exists(path) ? path : null);
            if (probeTarget != null)
            {
                var (writable, writeMsg) = ProbeWritable(probeTarget);
                if (!writable) return (false, writeMsg);
            }

            return (true, "");
        }
        catch (Exception ex)
        {
            return (false, $"Invalid path: {ex.Message}");
        }
    }

    internal static (bool Valid, string Message) ValidateOutputPath(string path)
    {
        path = (path ?? "").Trim();
        if (string.IsNullOrEmpty(path)) return (false, "Output ISO path is required.");
        if (!LooksLikeWindowsPath(path)) return (false, "Not a valid Windows path format (expected drive-letter path like C:\\file.iso or UNC \\\\server\\share\\file.iso).");

        try
        {
            var parent = Path.GetDirectoryName(path);
            if (string.IsNullOrEmpty(parent))
            {
                // Root-level file like "C:\\file.iso" -- parent is "C:\\" which always exists.
                // No further check needed.
            }
            else if (!Directory.Exists(parent))
            {
                return (false, $"Output directory does not exist: {parent}");
            }
            // Path itself must NOT be an existing directory (we'd be writing to a file).
            if (Directory.Exists(path))
            {
                return (false, "Path is an existing directory, not a file location.");
            }

            // Writability probe on the output's parent directory.
            if (!string.IsNullOrEmpty(parent) && Directory.Exists(parent))
            {
                var (writable, writeMsg) = ProbeWritable(parent);
                if (!writable) return (false, writeMsg);
            }
            else if (string.IsNullOrEmpty(parent))
            {
                // Root-level file like "C:\\file.iso" -- probe drive root.
                var driveRoot = Path.GetPathRoot(path);
                if (!string.IsNullOrEmpty(driveRoot) && Directory.Exists(driveRoot))
                {
                    var (writable, writeMsg) = ProbeWritable(driveRoot);
                    if (!writable) return (false, writeMsg);
                }
            }

            return (true, "");
        }
        catch (Exception ex)
        {
            return (false, $"Invalid path: {ex.Message}");
        }
    }

    private static bool LooksLikeWindowsPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        if (path.Length >= 3 && char.IsLetter(path[0]) && path[1] == ':' && (path[2] == '\\' || path[2] == '/')) return true;
        if (path.StartsWith(@"\\")) return true;
        return false;
    }

    // v1.0.9 smoke 2: write-probe for path validation. Creates a unique probe file
    // in the parent directory + immediately deletes it. Side-effect-free if both
    // steps succeed; if the create fails we return non-writable; if delete fails
    // we best-effort retry then ignore (the probe file would be tiny + named with
    // a guid so collision/leftover risk is negligible).
    private static (bool Writable, string Message) ProbeWritable(string parentDir)
    {
        var probePath = Path.Combine(parentDir, $".tiny11-write-probe-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var fs = File.Create(probePath)) { /* empty file is enough */ }
            TryDeleteProbe(probePath);
            return (true, "");
        }
        catch (UnauthorizedAccessException)
        {
            TryDeleteProbe(probePath);
            return (false, $"Directory not writable (permission denied): {parentDir}");
        }
        catch (IOException ex)
        {
            TryDeleteProbe(probePath);
            return (false, $"Cannot write to {parentDir}: {ex.Message}");
        }
        catch (Exception ex)
        {
            TryDeleteProbe(probePath);
            return (false, $"Write probe failed for {parentDir}: {ex.Message}");
        }
    }

    private static void TryDeleteProbe(string path)
    {
        try { File.Delete(path); } catch { /* best-effort cleanup */ }
    }
}
