using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Xml.Linq;
using Tiny11Options.Launcher.Headless;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class EmbeddedResourcesTests
{
    private static readonly Lazy<string> RepoRoot = new(FindRepoRoot);

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, ".git")))
            dir = dir.Parent;
        if (dir is null)
            throw new InvalidOperationException(
                ".git directory not found walking up from " + AppContext.BaseDirectory);
        return dir.FullName;
    }

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

    [Theory]
    [InlineData("tiny11maker.ps1")]
    [InlineData("autounattend.template.xml")]
    [InlineData("src/Tiny11.Iso.psm1")]
    [InlineData("src/Tiny11.PostBoot.psm1")]
    [InlineData("ui/index.html")]
    public void RealResource_IsEmbedded(string logicalName)
    {
        var asm = typeof(EmbeddedResources).Assembly;
        using var stream = asm.GetManifestResourceStream(logicalName);
        Assert.NotNull(stream);
        Assert.True(stream!.Length > 0, $"{logicalName} stream is empty");
    }

    // B9 (regression guard for b35d73a): the csproj `<EmbeddedResource>` list and
    // `HeadlessRunner.StaticResources` are TWO separate places listing what gets
    // shipped into the headless extraction dir. b35d73a happened because
    // `Tiny11.PostBoot.psm1` got added to the csproj and to the import chain in
    // `Tiny11.Worker.psm1`, but the third place -- `StaticResources` -- was
    // missed. Headless extracted everything EXCEPT PostBoot.psm1 and the build
    // shipped with no cleanup task installed. Neither side had a test asserting
    // they stay in sync.
    //
    // These two tests assert:
    //   1. Every entry in `StaticResources` exists as an `<EmbeddedResource>` in
    //      the csproj (otherwise extraction would throw "resource not found").
    //   2. Every csproj single-file `<EmbeddedResource>` is either in
    //      `StaticResources` OR explicitly allowlisted as a GUI-only / handler-
    //      only resource. Anything new added to the csproj forces a human to
    //      decide which list it belongs in.
    private static readonly HashSet<string> GuiOnlyResourceAllowlist = new(StringComparer.Ordinal)
    {
        // GUI-only wrapper scripts (the launcher's BuildHandlers invoke these
        // directly from the embedded stream, not the headless temp dir):
        "tiny11maker-from-config.ps1",
        "tiny11Coremaker-from-config.ps1",
        "tiny11-iso-validate.ps1",
        "tiny11-profile-validate.ps1",
        "tiny11-cancel-cleanup.ps1",
        // Core mode is GUI-only at v1.0.1 (no headless -Core path):
        "src/Tiny11.Core.psm1",
        // Test fixture (only consumed by ExtractTo_WritesNamedResourceToTargetDir):
        "test-fixture.txt",
    };

    private static IReadOnlyList<string> ReadStaticResources()
    {
        var headlessRunner = typeof(EmbeddedResources).Assembly
            .GetType("Tiny11Options.Launcher.Headless.HeadlessRunner", throwOnError: true)!;
        var field = headlessRunner.GetField("StaticResources", BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("HeadlessRunner.StaticResources field not found.");
        var arr = (string[])field.GetValue(null)!;
        return arr;
    }

    private static IReadOnlyList<string> ReadCsprojSingleFileLogicalNames()
    {
        var csprojPath = Path.Combine(RepoRoot.Value, "launcher", "tiny11options.Launcher.csproj");
        Assert.True(File.Exists(csprojPath), $"csproj not found at {csprojPath}");

        var doc = XDocument.Load(csprojPath);
        // Only single-file entries (those with a child <LogicalName>) -- skip
        // the wildcard globs (..\ui\**\*, ..\catalog\**\*, Resources\test-fixture.txt
        // which has its own structure) because those entries fan out at build time.
        var names = doc.Descendants()
            .Where(e => e.Name.LocalName == "EmbeddedResource")
            .Select(e =>
            {
                var logical = e.Elements().FirstOrDefault(c => c.Name.LocalName == "LogicalName");
                if (logical != null) return logical.Value;
                // Resources\test-fixture.txt has no <LogicalName> child; embedded name is the include path.
                var include = e.Attribute("Include")?.Value ?? string.Empty;
                return include.Replace("\\", "/");
            })
            // Filter out wildcard globs (have * in the Include) and MSBuild
            // metadata templates (have %(RecursiveDir)%(Filename)%(Extension)
            // in the LogicalName). Both fan out at build time into concrete
            // resources whose names we don't need to enumerate in this list --
            // RealResource_IsEmbedded covers a sample (ui/index.html) and the
            // ExtractTo path catches missing files at runtime.
            .Where(n => !string.IsNullOrEmpty(n) && !n.Contains("*") && !n.Contains("%("))
            .ToList();
        return names;
    }

    [Fact]
    public void StaticResources_AllExistAsEmbeddedResources()
    {
        // Every name HeadlessRunner tries to extract must be embedded; otherwise
        // EmbeddedResources.ExtractTo throws FileNotFoundException at runtime.
        var staticResources = ReadStaticResources();
        var csprojNames = new HashSet<string>(ReadCsprojSingleFileLogicalNames(), StringComparer.Ordinal);
        var missing = staticResources.Where(s => !csprojNames.Contains(s)).ToList();
        Assert.True(missing.Count == 0,
            "HeadlessRunner.StaticResources contains entries with no matching <EmbeddedResource> in the csproj. " +
            "Add each missing name to launcher/tiny11options.Launcher.csproj or remove from StaticResources: " +
            string.Join(", ", missing));
    }

    [Fact]
    public void EveryCsprojSingleFileResource_IsEitherStaticOrGuiOnlyAllowlisted()
    {
        // Drift catcher for the b35d73a class: an entry added to the csproj
        // but not to StaticResources, where it should have been. If the new
        // entry is legitimately GUI-only, add it to GuiOnlyResourceAllowlist.
        // Otherwise add it to HeadlessRunner.StaticResources.
        var staticSet = new HashSet<string>(ReadStaticResources(), StringComparer.Ordinal);
        var csprojNames = ReadCsprojSingleFileLogicalNames();
        var orphans = csprojNames
            .Where(n => !staticSet.Contains(n) && !GuiOnlyResourceAllowlist.Contains(n))
            .ToList();
        Assert.True(orphans.Count == 0,
            "Csproj <EmbeddedResource> entries are not reflected in HeadlessRunner.StaticResources " +
            "and are not on the GuiOnlyResourceAllowlist. For each, decide:\n" +
            "  (a) it IS needed by the headless wrapper -> add to HeadlessRunner.StaticResources\n" +
            "  (b) it is GUI-only / handler-only -> add to GuiOnlyResourceAllowlist in this test\n" +
            "Orphans: " + string.Join(", ", orphans));
    }
}
