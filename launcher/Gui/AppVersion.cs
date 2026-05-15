using System.Reflection;

namespace Tiny11Options.Launcher.Gui;

// Resolves the running app's version from assembly metadata for display in the
// WebView2 UI footer. Source of truth is csproj <Version> which auto-populates
// AssemblyVersion + FileVersion at build time, so bumping <Version> per release
// automatically updates the UI display — no manual sync step.
internal static class AppVersion
{
    public static string Current()
        => Format(Assembly.GetExecutingAssembly().GetName().Version);

    // Pure formatter — split out for unit testing. Returns "vMajor.Minor.Build".
    // The fourth System.Version field (Revision) is dropped since csproj <Version>
    // only carries 3 segments. Returns "v?.?.?" for null input (only happens on
    // dynamically emitted assemblies in test contexts).
    public static string Format(System.Version? version)
    {
        if (version is null) return "v?.?.?";
        return $"v{version.Major}.{version.Minor}.{version.Build}";
    }
}
