using System.IO;
using System.Text;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

/// Unit tests for MainWindow.ComputeManifestHash — the static helper that
/// drives ui-cache + resources-cache invalidation. Covers the three failure
/// modes that should trigger re-extraction: name added/removed, content
/// changed, and stable-input determinism (must NOT trigger).
public class ResourceCacheHashTests
{
    private static Stream Make(string content) => new MemoryStream(Encoding.UTF8.GetBytes(content));

    [Fact]
    public void Hash_IsStableForIdenticalInput()
    {
        string[] names = { "ui/app.js", "ui/style.css" };
        Stream Open(string n) => n switch
        {
            "ui/app.js" => Make("console.log('hi')"),
            "ui/style.css" => Make("body { color: red; }"),
            _ => Stream.Null,
        };

        var h1 = MainWindow.ComputeManifestHash(names, Open);
        var h2 = MainWindow.ComputeManifestHash(names, Open);

        Assert.Equal(h1, h2);
    }

    [Fact]
    public void Hash_ChangesWhenContentChanges()
    {
        string[] names = { "ui/app.js", "ui/style.css" };
        Stream OpenV1(string n) => n switch
        {
            "ui/app.js" => Make("v1"),
            "ui/style.css" => Make("css1"),
            _ => Stream.Null,
        };
        Stream OpenV2(string n) => n switch
        {
            "ui/app.js" => Make("v2"),
            "ui/style.css" => Make("css1"),
            _ => Stream.Null,
        };

        var h1 = MainWindow.ComputeManifestHash(names, OpenV1);
        var h2 = MainWindow.ComputeManifestHash(names, OpenV2);

        Assert.NotEqual(h1, h2);
    }

    [Fact]
    public void Hash_ChangesWhenResourceAdded()
    {
        string[] namesV1 = { "ui/app.js" };
        string[] namesV2 = { "ui/app.js", "ui/style.css" };
        Stream Open(string n) => Make($"content-of-{n}");

        var h1 = MainWindow.ComputeManifestHash(namesV1, Open);
        var h2 = MainWindow.ComputeManifestHash(namesV2, Open);

        Assert.NotEqual(h1, h2);
    }

    [Fact]
    public void Hash_ChangesWhenResourceRemoved()
    {
        string[] namesV1 = { "ui/app.js", "ui/style.css" };
        string[] namesV2 = { "ui/app.js" };
        Stream Open(string n) => Make($"content-of-{n}");

        var h1 = MainWindow.ComputeManifestHash(namesV1, Open);
        var h2 = MainWindow.ComputeManifestHash(namesV2, Open);

        Assert.NotEqual(h1, h2);
    }

    [Fact]
    public void Hash_DistinguishesNameBoundaryFromContentBytes()
    {
        // If the implementation concatenated names + content without a
        // separator, ["ab", "cd"] with empty content would hash the same as
        // ["a", "bcd"] with empty content. The NUL separator between name and
        // content (and between entries) keeps these distinct.
        string[] names1 = { "ab", "cd" };
        string[] names2 = { "a", "bcd" };
        Stream Empty(string _) => Stream.Null;

        var h1 = MainWindow.ComputeManifestHash(names1, Empty);
        var h2 = MainWindow.ComputeManifestHash(names2, Empty);

        Assert.NotEqual(h1, h2);
    }

    [Fact]
    public void Hash_HandlesMissingStreamGracefully()
    {
        // Real openResource implementations may return null for unknown names
        // (Assembly.GetManifestResourceStream returns null for missing). The
        // hash should still produce a stable, name-derived value rather than
        // throwing or differing run-to-run.
        string[] names = { "missing-resource.txt" };
        Stream? OpenNull(string _) => null;

        var h1 = MainWindow.ComputeManifestHash(names, OpenNull);
        var h2 = MainWindow.ComputeManifestHash(names, OpenNull);

        Assert.Equal(h1, h2);
        Assert.Equal(64, h1.Length); // SHA256 hex = 64 chars
    }
}
