using System;
using System.IO;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class PathValidationHandlersTests
{
    // -----------------------------------------------------------------------
    // ValidateScratchPath
    // -----------------------------------------------------------------------

    [Fact]
    public void ValidateScratchPath_EmptyString_IsInvalid()
    {
        var (valid, message) = PathValidationHandlers.ValidateScratchPath("");
        Assert.False(valid);
        Assert.Contains("required", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateScratchPath_WhitespaceOnly_IsInvalid()
    {
        var (valid, message) = PathValidationHandlers.ValidateScratchPath("   ");
        Assert.False(valid);
        Assert.Contains("required", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateScratchPath_GarbageInput_IsInvalidWithFormatMessage()
    {
        var (valid, message) = PathValidationHandlers.ValidateScratchPath("asdf jkl");
        Assert.False(valid);
        Assert.Contains("valid Windows path format", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateScratchPath_ValidPathUnderExistingParent_IsValid()
    {
        // Use %TEMP% as a known-existing parent. The sub-directory itself need
        // not exist (scratch is created at build time, not at validation time).
        var subdir = Path.Combine(Path.GetTempPath(), "tiny11-test-" + Guid.NewGuid().ToString("N")[..8]);
        var (valid, message) = PathValidationHandlers.ValidateScratchPath(subdir);
        Assert.True(valid, $"Expected valid; got message: '{message}'");
        Assert.Equal("", message);
    }

    [Fact]
    public void ValidateScratchPath_ParentDoesNotExist_IsInvalid()
    {
        var path = @"C:\definitely-not-a-real-dir-12345\sub";
        var (valid, message) = PathValidationHandlers.ValidateScratchPath(path);
        Assert.False(valid);
        Assert.Contains("Parent directory does not exist", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateScratchPath_PathIsExistingFile_IsInvalid()
    {
        // Create a real temp file; the path points at a file, not a directory.
        var tmpFile = Path.GetTempFileName();
        try
        {
            var (valid, message) = PathValidationHandlers.ValidateScratchPath(tmpFile);
            Assert.False(valid);
            Assert.Contains("file, not a directory", message, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            File.Delete(tmpFile);
        }
    }

    [Fact]
    public void ValidateScratchPath_UncStylePath_PassesFormatCheck()
    {
        // UNC paths look like \\server\share\subdir.
        // \\server doesn't actually exist on this box, so the parent-exists
        // check will fail -- but the format check must NOT be what rejects it.
        var (_, message) = PathValidationHandlers.ValidateScratchPath(@"\\server\share\subdir");
        Assert.DoesNotContain("valid Windows path format", message, StringComparison.OrdinalIgnoreCase);
    }

    // -----------------------------------------------------------------------
    // ValidateOutputPath
    // -----------------------------------------------------------------------

    [Fact]
    public void ValidateOutputPath_EmptyString_IsInvalid()
    {
        var (valid, message) = PathValidationHandlers.ValidateOutputPath("");
        Assert.False(valid);
        Assert.Contains("required", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateOutputPath_GarbageInput_IsInvalidWithFormatMessage()
    {
        var (valid, message) = PathValidationHandlers.ValidateOutputPath("not a path at all");
        Assert.False(valid);
        Assert.Contains("valid Windows path format", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateOutputPath_ValidPathUnderExistingParent_IsValid()
    {
        var file = Path.Combine(Path.GetTempPath(), "tiny11-test-output-" + Guid.NewGuid().ToString("N")[..8] + ".iso");
        var (valid, message) = PathValidationHandlers.ValidateOutputPath(file);
        Assert.True(valid, $"Expected valid; got message: '{message}'");
        Assert.Equal("", message);
    }

    [Fact]
    public void ValidateOutputPath_PathIsExistingDirectory_IsInvalid()
    {
        // %TEMP% itself is a directory — output must be a file location.
        var dir = Path.GetTempPath().TrimEnd('\\', '/');
        var (valid, message) = PathValidationHandlers.ValidateOutputPath(dir);
        Assert.False(valid);
        Assert.Contains("existing directory", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateOutputPath_ParentDirectoryDoesNotExist_IsInvalid()
    {
        var path = @"C:\definitely-not-a-real-dir-12345\output.iso";
        var (valid, message) = PathValidationHandlers.ValidateOutputPath(path);
        Assert.False(valid);
        Assert.Contains("Output directory does not exist", message, StringComparison.OrdinalIgnoreCase);
    }

    // -----------------------------------------------------------------------
    // Writability probe smoke tests
    //
    // These verify the probe runs end-to-end on a writable directory without
    // surfacing a false-negative permission error. Negative-permission cases
    // (e.g. read-only volumes) are not exercised because reliably setting one
    // up cross-machine without admin is not worth the test-fixture cost --
    // the production error paths are simple `catch` blocks with no branches.
    // -----------------------------------------------------------------------

    [Fact]
    public void ValidateScratchPath_OnWritableTempParent_PassesProbeAndCleansUp()
    {
        var tempDir = Path.GetTempPath().TrimEnd('\\', '/');
        var subdir = Path.Combine(tempDir, "tiny11-test-scratch-probe-" + Guid.NewGuid().ToString("N")[..8]);

        var (valid, message) = PathValidationHandlers.ValidateScratchPath(subdir);

        Assert.True(valid, $"Expected valid (probe should succeed on writable temp); got message: '{message}'");
        Assert.Equal("", message);
        // Probe file should be cleaned up by TryDeleteProbe -- nothing matching
        // the .tiny11-write-probe-* pattern should linger in temp from this call.
        var leftovers = Directory.GetFiles(tempDir, ".tiny11-write-probe-*.tmp");
        Assert.Empty(leftovers);
    }

    [Fact]
    public void ValidateOutputPath_OnWritableTempParent_PassesProbeAndCleansUp()
    {
        var tempDir = Path.GetTempPath().TrimEnd('\\', '/');
        var file = Path.Combine(tempDir, "tiny11-test-output-probe-" + Guid.NewGuid().ToString("N")[..8] + ".iso");

        var (valid, message) = PathValidationHandlers.ValidateOutputPath(file);

        Assert.True(valid, $"Expected valid (probe should succeed on writable temp); got message: '{message}'");
        Assert.Equal("", message);
        var leftovers = Directory.GetFiles(tempDir, ".tiny11-write-probe-*.tmp");
        Assert.Empty(leftovers);
    }
}
