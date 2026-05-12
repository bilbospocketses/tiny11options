using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

namespace Tiny11Options.Launcher.Headless;

internal static class EmbeddedResources
{
    private static readonly Assembly OwnAssembly = typeof(EmbeddedResources).Assembly;

    public static void ExtractTo(string targetDir, IEnumerable<string> resourceNames)
    {
        Directory.CreateDirectory(targetDir);

        foreach (var name in resourceNames)
        {
            using var stream = OwnAssembly.GetManifestResourceStream(name);
            if (stream is null)
            {
                throw new FileNotFoundException(
                    $"Embedded resource not found: {name}. Did the .csproj <EmbeddedResource> globs miss it?",
                    name);
            }

            var dest = Path.Combine(targetDir, name);
            var destDir = Path.GetDirectoryName(dest);
            if (!string.IsNullOrEmpty(destDir)) Directory.CreateDirectory(destDir);

            using var fs = File.Create(dest);
            stream.CopyTo(fs);
        }
    }
}
