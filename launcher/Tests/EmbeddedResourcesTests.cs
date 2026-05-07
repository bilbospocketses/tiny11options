using System;
using System.IO;
using Tiny11Options.Launcher.Headless;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class EmbeddedResourcesTests
{
    [Fact]
    public void ExtractTo_WritesNamedResourceToTargetDir()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"tiny11-test-{Guid.NewGuid():N}");
        try
        {
            EmbeddedResources.ExtractTo(tempDir, new[] { "test-fixture.txt" });

            var written = Path.Combine(tempDir, "test-fixture.txt");
            Assert.True(File.Exists(written), $"Expected {written} to exist");
            Assert.Equal("hello from embedded resource", File.ReadAllText(written).Trim());
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
    }

    [Fact]
    public void ExtractTo_ThrowsOnUnknownResourceName()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"tiny11-test-{Guid.NewGuid():N}");
        try
        {
            var ex = Assert.Throws<FileNotFoundException>(
                () => EmbeddedResources.ExtractTo(tempDir, new[] { "does-not-exist.txt" }));
            Assert.Contains("does-not-exist.txt", ex.Message);
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
    }
}
