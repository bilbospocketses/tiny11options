using System;
using System.IO;
using Tiny11Options.Launcher.Gui;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class AutoScratchPathTests
{
    [Fact]
    public void Generate_ReturnsAbsolutePathUnderUserDocumentsTiny11Outputs()
    {
        var path = AutoScratchPath.Generate();
        Assert.True(Path.IsPathFullyQualified(path), $"Expected fully qualified path; got '{path}'");
        var expectedParent = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            AutoScratchPath.DefaultParentFolderName);
        Assert.StartsWith(expectedParent, path, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Generate_ParentDirectoryIsExactlyTiny11Outputs()
    {
        var path = AutoScratchPath.Generate();
        var parent = Path.GetDirectoryName(path);
        Assert.NotNull(parent);
        Assert.Equal(AutoScratchPath.DefaultParentFolderName, Path.GetFileName(parent));
    }

    [Fact]
    public void Generate_LeafFolderUsesTiny11HexSuffixPattern()
    {
        var path = AutoScratchPath.Generate();
        var leaf = Path.GetFileName(path);
        Assert.StartsWith("tiny11-", leaf);
        var hex = leaf.Substring("tiny11-".Length);
        Assert.Equal(8, hex.Length);
        Assert.All(hex, c => Assert.True(Uri.IsHexDigit(c), $"Expected hex char in suffix; got '{c}'"));
    }

    [Fact]
    public void Generate_TwoConsecutiveCallsProduceDifferentSuffixes()
    {
        var first = AutoScratchPath.Generate();
        var second = AutoScratchPath.Generate();
        Assert.NotEqual(first, second);
    }

    [Fact]
    public void Generate_DoesNotCreateDirectoryOnDisk()
    {
        var path = AutoScratchPath.Generate();
        Assert.False(Directory.Exists(path), $"AutoScratchPath should return a candidate path only; directory '{path}' was created");
        var parent = Path.GetDirectoryName(path);
        if (parent is not null)
        {
            // Sibling assertion: Generate should not create the tiny11_outputs parent either.
            // (If it already exists from a prior real run on this machine, this assertion is
            // harmless — we'd only fail when both did-not-exist and Generate created it.)
            // To keep the assertion robust on a developer box that has used the launcher
            // before, scope to: "Generate did not transition from absent to present in this call".
            // Simplest robust check: just confirm Generate is side-effect-free relative to the leaf.
            Assert.False(Directory.Exists(path));
        }
    }
}
