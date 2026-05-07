# Path C — Bundled .exe launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single signed `tiny11options.exe` that delivers GUI mode (WPF + WebView2) and headless mode (CLI args → spawn pwsh) from one binary, with built-in Velopack updates.

**Architecture:** Native C# WPF + WebView2 host. The C# layer owns the window, JSON bridge, and fast handlers. PowerShell is invoked as a subprocess only for ISO validation and the build worker. Self-contained .NET 10 single-file publish, Microsoft Trusted Signing, Velopack for in-app updates with passive notification.

**Tech Stack:** .NET 10 (`net10.0-windows`), WPF, WebView2 (vendored DLLs), xUnit + Moq for tests, Velopack for updates, GitHub Actions + Microsoft Trusted Signing for release.

**Spec:** `docs/superpowers/specs/2026-05-07-path-c-bundled-launcher-design.md`

---

## Phase overview

| Phase | Tasks | Outcome |
|---|---|---|
| 1 — Foundation | 1-7 | Solution + launcher project + xUnit project + headless mode end-to-end |
| 2 — GUI shell | 8-13 | WPF window with WebView2 rendering the existing `ui/` HTML |
| 3 — Bridge + handlers | 14-22 | C# bridge dispatch + all 5 handler classes wired |
| 4 — Updates | 23-26 | Velopack integration with passive notification + apply flow |
| 5 — PS cleanup | 27-29 | Delete retired modules + tests; update orchestrator |
| 6 — Build pipeline | 30-34 | Single-file publish + drift test + GitHub Actions release.yml |
| 7 — Smoke + release | 35-38 | Manual smoke 1-5, CHANGELOG, cut release |

**Branch:** `feat/path-c-launcher` (already created; spec is committed at `70e31e2`).

---

## Phase 1 — Foundation

### Task 1: Solution file at repo root

**Files:**
- Create: `tiny11options.sln`

- [ ] **Step 1: Generate solution file**

```powershell
cd C:/Users/jscha/source/repos/tiny11options
dotnet new sln -n tiny11options
```

Expected: `tiny11options.sln` created at repo root.

- [ ] **Step 2: Verify file contents**

Run: `Get-Content tiny11options.sln | Select-Object -First 5`
Expected: starts with `Microsoft Visual Studio Solution File, Format Version 12.00`.

- [ ] **Step 3: Commit**

```powershell
git add tiny11options.sln
git commit -m "chore(launcher): solution file at repo root"
```

---

### Task 2: Launcher project skeleton (csproj only)

**Files:**
- Create: `launcher/tiny11options.Launcher.csproj`

- [ ] **Step 1: Create launcher/ directory and csproj**

```powershell
New-Item -ItemType Directory -Path launcher -Force | Out-Null
```

Then write `launcher/tiny11options.Launcher.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <UseWPF>true</UseWPF>
    <UseWindowsForms>false</UseWindowsForms>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <RootNamespace>Tiny11Options.Launcher</RootNamespace>
    <AssemblyName>tiny11options</AssemblyName>
    <ApplicationManifest>app.manifest</ApplicationManifest>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
  </PropertyGroup>

  <!-- Single-file publish settings (only applied at publish time) -->
  <PropertyGroup Condition="'$(PublishSingleFile)' == 'true'">
    <IncludeAllContentForSelfExtract>true</IncludeAllContentForSelfExtract>
    <DebugType>embedded</DebugType>
  </PropertyGroup>

  <ItemGroup>
    <Reference Include="Microsoft.Web.WebView2.Core">
      <HintPath>..\dependencies\webview2\1.0.2535.41\Microsoft.Web.WebView2.Core.dll</HintPath>
    </Reference>
    <Reference Include="Microsoft.Web.WebView2.Wpf">
      <HintPath>..\dependencies\webview2\1.0.2535.41\Microsoft.Web.WebView2.Wpf.dll</HintPath>
    </Reference>
    <Content Include="..\dependencies\webview2\1.0.2535.41\WebView2Loader.dll">
      <Link>WebView2Loader.dll</Link>
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </Content>
  </ItemGroup>

</Project>
```

- [ ] **Step 2: Add app.manifest (required for AttachConsole + per-monitor DPI)**

Write `launcher/app.manifest`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="tiny11options"/>

  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/PM</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>

  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <!-- Windows 10 + Windows 11 -->
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
</assembly>
```

- [ ] **Step 3: Add the project to the solution**

```powershell
dotnet sln tiny11options.sln add launcher/tiny11options.Launcher.csproj
```

- [ ] **Step 4: Verify build (no source files yet, will fail predictably)**

```powershell
dotnet build launcher/tiny11options.Launcher.csproj
```

Expected: build fails with "no main entry point" or similar — that's fine; we add Program.cs in Task 3.

- [ ] **Step 5: Commit**

```powershell
git add launcher/tiny11options.Launcher.csproj launcher/app.manifest tiny11options.sln
git commit -m "chore(launcher): csproj + app.manifest skeleton"
```

---

### Task 3: Program.cs with arg-mode detection

**Files:**
- Create: `launcher/Program.cs`

- [ ] **Step 1: Write Program.cs**

```csharp
using System;

namespace Tiny11Options.Launcher;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            return Headless.HeadlessRunner.Run(args);
        }

        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}
```

- [ ] **Step 2: Stub HeadlessRunner so the project builds**

Create `launcher/Headless/HeadlessRunner.cs`:

```csharp
namespace Tiny11Options.Launcher.Headless;

internal static class HeadlessRunner
{
    public static int Run(string[] args)
    {
        Console.Error.WriteLine("HeadlessRunner not yet implemented");
        return 1;
    }
}
```

- [ ] **Step 3: Stub App.xaml + App.xaml.cs so the project builds**

Create `launcher/App.xaml`:

```xml
<Application x:Class="Tiny11Options.Launcher.App"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Application.Resources>
    </Application.Resources>
</Application>
```

Create `launcher/App.xaml.cs`:

```csharp
using System.Windows;

namespace Tiny11Options.Launcher;

public partial class App : Application
{
}
```

- [ ] **Step 4: Verify build succeeds**

```powershell
dotnet build launcher/tiny11options.Launcher.csproj
```

Expected: Build succeeded. 0 Error(s).

- [ ] **Step 5: Run with no args (GUI stub) — should exit cleanly with empty WPF app**

```powershell
dotnet run --project launcher/tiny11options.Launcher.csproj
```

Expected: process exits ~immediately (no startup window in App.xaml means Run() completes when no windows remain).

- [ ] **Step 6: Run with args (headless stub)**

```powershell
dotnet run --project launcher/tiny11options.Launcher.csproj -- --foo bar
```

Expected: stderr "HeadlessRunner not yet implemented", exit code 1.

- [ ] **Step 7: Commit**

```powershell
git add launcher/Program.cs launcher/Headless/HeadlessRunner.cs launcher/App.xaml launcher/App.xaml.cs
git commit -m "feat(launcher): Program.cs arg-mode detection + skeleton stubs"
```

---

### Task 4: xUnit test project

**Files:**
- Create: `launcher/Tests/tiny11options.Launcher.Tests.csproj`
- Create: `launcher/Tests/SmokeTests.cs`

- [ ] **Step 1: Generate test project**

```powershell
dotnet new xunit -n tiny11options.Launcher.Tests -o launcher/Tests --framework net10.0-windows
dotnet sln tiny11options.sln add launcher/Tests/tiny11options.Launcher.Tests.csproj
dotnet add launcher/Tests/tiny11options.Launcher.Tests.csproj reference launcher/tiny11options.Launcher.csproj
dotnet add launcher/Tests/tiny11options.Launcher.Tests.csproj package Moq
```

- [ ] **Step 2: Replace the auto-generated UnitTest1.cs with a single sanity-check test**

Delete `launcher/Tests/UnitTest1.cs` if generated. Create `launcher/Tests/SmokeTests.cs`:

```csharp
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class SmokeTests
{
    [Fact]
    public void Sanity_ProjectReferencesCompile()
    {
        Assert.True(true);
    }
}
```

- [ ] **Step 3: Run the test**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj
```

Expected: 1 passed, 0 failed.

- [ ] **Step 4: Commit**

```powershell
git add launcher/Tests/
git rm launcher/Tests/UnitTest1.cs --ignore-unmatch 2>$null
git commit -m "chore(launcher): xUnit test project + sanity test"
```

---

### Task 5: EmbeddedResources extraction (TDD)

**Files:**
- Create: `launcher/Headless/EmbeddedResources.cs`
- Create: `launcher/Tests/EmbeddedResourcesTests.cs`

- [ ] **Step 1: Add a test embedded resource to the launcher project**

Add to `launcher/tiny11options.Launcher.csproj` inside an `<ItemGroup>`:

```xml
<ItemGroup>
  <EmbeddedResource Include="Resources\test-fixture.txt">
    <LogicalName>test-fixture.txt</LogicalName>
  </EmbeddedResource>
</ItemGroup>
```

Create `launcher/Resources/test-fixture.txt` with content:

```
hello from embedded resource
```

- [ ] **Step 2: Write failing test**

Create `launcher/Tests/EmbeddedResourcesTests.cs`:

```csharp
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
```

- [ ] **Step 3: Run tests to confirm FAIL**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~EmbeddedResourcesTests"
```

Expected: 2 failed (EmbeddedResources class not found).

- [ ] **Step 4: Implement EmbeddedResources**

Replace `launcher/Headless/EmbeddedResources.cs` content (or create it):

```csharp
using System;
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
```

- [ ] **Step 5: Run tests to confirm PASS**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~EmbeddedResourcesTests"
```

Expected: 2 passed.

- [ ] **Step 6: Commit**

```powershell
git add launcher/Resources/test-fixture.txt launcher/Headless/EmbeddedResources.cs launcher/Tests/EmbeddedResourcesTests.cs launcher/tiny11options.Launcher.csproj
git commit -m "feat(launcher): EmbeddedResources.ExtractTo + tests"
```

---

### Task 6: MSBuild globs for the real embedded resources

**Files:**
- Modify: `launcher/tiny11options.Launcher.csproj`

- [ ] **Step 1: Add resource globs to csproj**

Append inside the existing root `<Project>` element (after the existing `<ItemGroup>` blocks):

```xml
<!-- Embedded resources: ui, catalog, retained PS modules, autounattend, orchestrator -->
<ItemGroup>
  <!-- ui/ - HTML/CSS/JS - LogicalName preserves the relative path -->
  <EmbeddedResource Include="..\ui\**\*">
    <LogicalName>ui/%(RecursiveDir)%(Filename)%(Extension)</LogicalName>
    <Link>Resources\ui\%(RecursiveDir)%(Filename)%(Extension)</Link>
  </EmbeddedResource>

  <!-- catalog/ -->
  <EmbeddedResource Include="..\catalog\**\*">
    <LogicalName>catalog/%(RecursiveDir)%(Filename)%(Extension)</LogicalName>
    <Link>Resources\catalog\%(RecursiveDir)%(Filename)%(Extension)</Link>
  </EmbeddedResource>

  <!-- Retained PS modules (named explicitly per spec D3) -->
  <EmbeddedResource Include="..\src\Tiny11.Iso.psm1"><LogicalName>src/Tiny11.Iso.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Worker.psm1"><LogicalName>src/Tiny11.Worker.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Catalog.psm1"><LogicalName>src/Tiny11.Catalog.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Hives.psm1"><LogicalName>src/Tiny11.Hives.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Selections.psm1"><LogicalName>src/Tiny11.Selections.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Autounattend.psm1"><LogicalName>src/Tiny11.Autounattend.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Actions.psm1"><LogicalName>src/Tiny11.Actions.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Actions.Registry.psm1"><LogicalName>src/Tiny11.Actions.Registry.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Actions.Filesystem.psm1"><LogicalName>src/Tiny11.Actions.Filesystem.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Actions.ProvisionedAppx.psm1"><LogicalName>src/Tiny11.Actions.ProvisionedAppx.psm1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\src\Tiny11.Actions.ScheduledTask.psm1"><LogicalName>src/Tiny11.Actions.ScheduledTask.psm1</LogicalName></EmbeddedResource>

  <!-- Orchestrator + autounattend template -->
  <EmbeddedResource Include="..\tiny11maker.ps1"><LogicalName>tiny11maker.ps1</LogicalName></EmbeddedResource>
  <EmbeddedResource Include="..\autounattend.template.xml"><LogicalName>autounattend.template.xml</LogicalName></EmbeddedResource>
</ItemGroup>
```

- [ ] **Step 2: Verify build picks up the resources**

```powershell
dotnet build launcher/tiny11options.Launcher.csproj -v normal | Select-String "EmbeddedResource"
```

Expected: see lines referencing `Tiny11.Iso.psm1`, `tiny11maker.ps1`, etc.

- [ ] **Step 3: Add an integration test that confirms the real resources are accessible**

Append to `launcher/Tests/EmbeddedResourcesTests.cs`:

```csharp
[Theory]
[InlineData("tiny11maker.ps1")]
[InlineData("autounattend.template.xml")]
[InlineData("src/Tiny11.Iso.psm1")]
[InlineData("ui/index.html")]
public void RealResource_IsEmbedded(string logicalName)
{
    var asm = typeof(EmbeddedResources).Assembly;
    using var stream = asm.GetManifestResourceStream(logicalName);
    Assert.NotNull(stream);
    Assert.True(stream!.Length > 0, $"{logicalName} stream is empty");
}
```

- [ ] **Step 4: Run tests to confirm PASS**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~EmbeddedResourcesTests"
```

Expected: all tests pass (including the 4 theory cases).

- [ ] **Step 5: Commit**

```powershell
git add launcher/tiny11options.Launcher.csproj launcher/Tests/EmbeddedResourcesTests.cs
git commit -m "feat(launcher): MSBuild globs for ui/, catalog/, retained PS modules"
```

---

### Task 7: HeadlessRunner — extract + spawn pwsh + AttachConsole

**Files:**
- Modify: `launcher/Headless/HeadlessRunner.cs`
- Create: `launcher/Interop/ConsoleAttach.cs`
- Create: `launcher/Tests/HeadlessRunnerTests.cs`

- [ ] **Step 1: Write failing tests**

Create `launcher/Tests/HeadlessRunnerTests.cs`:

```csharp
using Tiny11Options.Launcher.Headless;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class HeadlessRunnerTests
{
    [Fact]
    public void BuildPwshArgs_QuotesPathWithSpaces()
    {
        var ps1 = @"C:\Temp\dir with spaces\tiny11maker.ps1";
        var userArgs = new[] { "-Source", "C:\\my iso\\win11.iso", "-Edition", "Windows 11 Pro" };

        var argLine = HeadlessRunner.BuildPwshArgLine(ps1, userArgs);

        Assert.Contains("\"C:\\Temp\\dir with spaces\\tiny11maker.ps1\"", argLine);
        Assert.Contains("\"C:\\my iso\\win11.iso\"", argLine);
        Assert.Contains("\"Windows 11 Pro\"", argLine);
    }

    [Fact]
    public void BuildPwshArgLine_PrependsBypassAndNoProfile()
    {
        var argLine = HeadlessRunner.BuildPwshArgLine(
            @"C:\foo.ps1",
            Array.Empty<string>());

        Assert.StartsWith("-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden", argLine);
        Assert.Contains("-File", argLine);
    }
}
```

- [ ] **Step 2: Run tests to confirm FAIL**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~HeadlessRunnerTests"
```

Expected: 2 failed (BuildPwshArgLine method not found).

- [ ] **Step 3: Implement ConsoleAttach P/Invoke wrapper**

Create `launcher/Interop/ConsoleAttach.cs`:

```csharp
using System;
using System.Runtime.InteropServices;

namespace Tiny11Options.Launcher.Interop;

internal static class ConsoleAttach
{
    private const int ATTACH_PARENT_PROCESS = -1;

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeConsole();

    public static void AttachToParent()
    {
        // If launched from a console (cmd, pwsh, terminal), attach to the parent
        // so child stdout/stderr stream to the user's shell. Best-effort: ignore
        // failures (e.g., launched from Explorer with no parent console).
        AttachConsole(ATTACH_PARENT_PROCESS);
    }

    public static void Detach() => FreeConsole();
}
```

- [ ] **Step 4: Implement HeadlessRunner**

Replace `launcher/Headless/HeadlessRunner.cs`:

```csharp
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using Tiny11Options.Launcher.Interop;

namespace Tiny11Options.Launcher.Headless;

internal static class HeadlessRunner
{
    // Resources that the headless wrapper needs at runtime.
    private static readonly string[] HeadlessResources = new[]
    {
        "tiny11maker.ps1",
        "autounattend.template.xml",
        "src/Tiny11.Iso.psm1",
        "src/Tiny11.Worker.psm1",
        "src/Tiny11.Catalog.psm1",
        "src/Tiny11.Hives.psm1",
        "src/Tiny11.Selections.psm1",
        "src/Tiny11.Autounattend.psm1",
        "src/Tiny11.Actions.psm1",
        "src/Tiny11.Actions.Registry.psm1",
        "src/Tiny11.Actions.Filesystem.psm1",
        "src/Tiny11.Actions.ProvisionedAppx.psm1",
        "src/Tiny11.Actions.ScheduledTask.psm1",
    };

    public static int Run(string[] args)
    {
        ConsoleAttach.AttachToParent();
        try
        {
            var tempDir = ResolveExtractionDir();
            try
            {
                EmbeddedResources.ExtractTo(tempDir, AllResourcesIncludingCatalog());
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[tiny11options] Failed to extract runtime resources: {ex.Message}");
                return 10;
            }

            var ps1Path = Path.Combine(tempDir, "tiny11maker.ps1");
            var argLine = BuildPwshArgLine(ps1Path, args);

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = argLine,
                UseShellExecute = false,
                RedirectStandardOutput = false,  // inherit from attached console
                RedirectStandardError = false,
                CreateNoWindow = true,
                WorkingDirectory = tempDir,
            };

            try
            {
                using var proc = Process.Start(psi)
                    ?? throw new InvalidOperationException("Process.Start returned null");
                proc.WaitForExit();
                return proc.ExitCode;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                Console.Error.WriteLine(
                    "[tiny11options] powershell.exe is required but was not found on PATH. " +
                    "Install Windows PowerShell 5.1 (built into Windows) or PowerShell 7+.");
                return 11;
            }
            finally
            {
                TryCleanup(tempDir);
            }
        }
        finally
        {
            ConsoleAttach.Detach();
        }
    }

    public static string BuildPwshArgLine(string ps1Path, string[] userArgs)
    {
        var sb = new StringBuilder();
        sb.Append("-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ");
        sb.Append(QuoteIfNeeded(ps1Path));
        foreach (var a in userArgs)
        {
            sb.Append(' ');
            sb.Append(QuoteIfNeeded(a));
        }
        return sb.ToString();
    }

    private static string QuoteIfNeeded(string s)
    {
        if (string.IsNullOrEmpty(s)) return "\"\"";
        if (s.Contains(' ') || s.Contains('"'))
        {
            return "\"" + s.Replace("\"", "\\\"") + "\"";
        }
        return s;
    }

    private static string ResolveExtractionDir()
    {
        var tempPath = Path.Combine(
            Path.GetTempPath(),
            $"tiny11options-{Environment.ProcessId}");
        try
        {
            Directory.CreateDirectory(tempPath);
            // Probe write access
            var probe = Path.Combine(tempPath, ".write-probe");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return tempPath;
        }
        catch
        {
            // %TEMP% non-writable - fall back to %LOCALAPPDATA%
            var fallback = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "tiny11options", "runtime", $"{Environment.ProcessId}");
            Directory.CreateDirectory(fallback);
            return fallback;
        }
    }

    private static void TryCleanup(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch { /* non-fatal: %TEMP% reaped at reboot */ }
    }

    private static IEnumerable<string> AllResourcesIncludingCatalog()
    {
        foreach (var r in HeadlessResources) yield return r;

        // Catalog is loaded from disk by Tiny11.Catalog.psm1; enumerate the embedded
        // catalog/** entries from the assembly manifest.
        var asm = typeof(HeadlessRunner).Assembly;
        foreach (var name in asm.GetManifestResourceNames())
        {
            if (name.StartsWith("catalog/", StringComparison.OrdinalIgnoreCase))
                yield return name;
        }
    }
}
```

- [ ] **Step 5: Run tests to confirm PASS**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj
```

Expected: all tests pass.

- [ ] **Step 6: Manual smoke — invoke headless mode and confirm pwsh receives args**

For the smoke we don't have a working tiny11maker.ps1 path that exits cleanly without a real ISO, so we just verify that pwsh is invoked. Build then run:

```powershell
dotnet build launcher/tiny11options.Launcher.csproj
$exe = "launcher/bin/Debug/net10.0-windows/win-x64/tiny11options.exe"
& $exe -Source "C:\nonexistent.iso" -Edition "Windows 11 Pro"
```

Expected: pwsh runs `tiny11maker.ps1` with those args, errors out on "ISO not found" with non-zero exit code. The launcher passes through that exit code. (Specific error message comes from existing tiny11maker.ps1 logic.)

- [ ] **Step 7: Commit**

```powershell
git add launcher/Headless/HeadlessRunner.cs launcher/Interop/ConsoleAttach.cs launcher/Tests/HeadlessRunnerTests.cs
git commit -m "feat(launcher): HeadlessRunner extracts resources, spawns pwsh, attaches console"
```

---

## Phase 2 — GUI shell

### Task 8: MainWindow XAML + WebView2 host

**Files:**
- Create: `launcher/MainWindow.xaml`
- Create: `launcher/MainWindow.xaml.cs`
- Modify: `launcher/App.xaml`
- Modify: `launcher/App.xaml.cs`

- [ ] **Step 1: Configure App.xaml to launch MainWindow**

Replace `launcher/App.xaml`:

```xml
<Application x:Class="Tiny11Options.Launcher.App"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             StartupUri="MainWindow.xaml"
             ShutdownMode="OnMainWindowClose">
    <Application.Resources>
    </Application.Resources>
</Application>
```

- [ ] **Step 2: Create MainWindow.xaml**

```xml
<Window x:Class="Tiny11Options.Launcher.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;assembly=Microsoft.Web.WebView2.Wpf"
        Title="tiny11options"
        Width="1200" Height="900"
        MinWidth="1000" MinHeight="750"
        WindowStartupLocation="CenterScreen">
    <Grid>
        <wv2:WebView2 x:Name="WebView" />
    </Grid>
</Window>
```

- [ ] **Step 3: Create MainWindow.xaml.cs with WebView2 init**

```csharp
using System;
using System.IO;
using System.Reflection;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Tiny11Options.Launcher.Headless;

namespace Tiny11Options.Launcher;

public partial class MainWindow : Window
{
    private string? _uiCacheDir;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += async (_, _) => await InitializeWebViewAsync();
    }

    private async System.Threading.Tasks.Task InitializeWebViewAsync()
    {
        try
        {
            _uiCacheDir = ResolveUiCacheDir();
            ExtractUiResourcesIfNeeded(_uiCacheDir);

            var userDataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "tiny11options", "webview2-userdata");
            Directory.CreateDirectory(userDataDir);

            var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            await WebView.EnsureCoreWebView2Async(env);

            WebView.CoreWebView2.SetVirtualHostNameToFolderMapping(
                "app.local",
                _uiCacheDir,
                CoreWebView2HostResourceAccessKind.Allow);

            WebView.CoreWebView2.Settings.IsWebMessageEnabled = true;
            WebView.Source = new Uri("http://app.local/index.html");
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"WebView2 Runtime is required but could not be initialized.\n\n{ex.Message}\n\n" +
                "Install from https://developer.microsoft.com/microsoft-edge/webview2/",
                "tiny11options",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Close();
        }
    }

    private static string ResolveUiCacheDir()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "dev";
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tiny11options", "ui-cache", version);
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static void ExtractUiResourcesIfNeeded(string targetDir)
    {
        var marker = Path.Combine(targetDir, ".extracted");
        if (File.Exists(marker)) return;

        var asm = typeof(MainWindow).Assembly;
        foreach (var name in asm.GetManifestResourceNames())
        {
            if (!name.StartsWith("ui/", StringComparison.OrdinalIgnoreCase)) continue;

            var relPath = name.Substring("ui/".Length);
            var dest = Path.Combine(targetDir, relPath);
            var destDir = Path.GetDirectoryName(dest);
            if (!string.IsNullOrEmpty(destDir)) Directory.CreateDirectory(destDir);

            using var stream = asm.GetManifestResourceStream(name)!;
            using var fs = File.Create(dest);
            stream.CopyTo(fs);
        }

        File.WriteAllText(marker, "");
    }
}
```

- [ ] **Step 4: Build**

```powershell
dotnet build launcher/tiny11options.Launcher.csproj
```

Expected: 0 errors.

- [ ] **Step 5: Run**

```powershell
dotnet run --project launcher/tiny11options.Launcher.csproj
```

Expected: window opens at 1200×900, WebView2 loads `http://app.local/index.html`, the existing v0.2.0 wizard UI renders. Cancel/close exits cleanly.

- [ ] **Step 6: Commit**

```powershell
git add launcher/MainWindow.xaml launcher/MainWindow.xaml.cs launcher/App.xaml
git commit -m "feat(launcher): MainWindow + WebView2 host loading embedded ui/"
```

---

### Task 9: UserSettings (port from Tiny11.WebView2.psm1)

**Files:**
- Create: `launcher/Gui/Settings/UserSettings.cs`
- Create: `launcher/Tests/UserSettingsTests.cs`

- [ ] **Step 1: Write failing tests**

Create `launcher/Tests/UserSettingsTests.cs`:

```csharp
using System.IO;
using System.Text.Json;
using Tiny11Options.Launcher.Gui.Settings;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class UserSettingsTests
{
    private static string TempPath() =>
        Path.Combine(Path.GetTempPath(), $"tiny11-settings-{Guid.NewGuid():N}.json");

    [Fact]
    public void Load_ReturnsDefaults_WhenFileMissing()
    {
        var path = TempPath();
        var s = UserSettings.Load(path);
        Assert.NotNull(s);
        Assert.Equal(1200, s.WindowWidth);
        Assert.Equal(900, s.WindowHeight);
    }

    [Fact]
    public void Save_ThenLoad_RoundTrips()
    {
        var path = TempPath();
        try
        {
            var original = new UserSettings { WindowWidth = 1500, WindowHeight = 1000, Theme = "dark" };
            original.Save(path);

            var loaded = UserSettings.Load(path);
            Assert.Equal(1500, loaded.WindowWidth);
            Assert.Equal(1000, loaded.WindowHeight);
            Assert.Equal("dark", loaded.Theme);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public void Load_ReturnsDefaults_WhenJsonCorrupt()
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, "{ corrupt json");
            var s = UserSettings.Load(path);
            Assert.Equal(1200, s.WindowWidth);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public void Load_ClampsBelowMinimumWindowSize()
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, JsonSerializer.Serialize(new { WindowWidth = 200, WindowHeight = 200 }));
            var s = UserSettings.Load(path);
            Assert.True(s.WindowWidth >= 1000);
            Assert.True(s.WindowHeight >= 750);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }
}
```

- [ ] **Step 2: Run tests to confirm FAIL**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~UserSettingsTests"
```

Expected: 4 failed.

- [ ] **Step 3: Implement UserSettings**

Create `launcher/Gui/Settings/UserSettings.cs`:

```csharp
using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Tiny11Options.Launcher.Gui.Settings;

public class UserSettings
{
    public const int MinWidth = 1000;
    public const int MinHeight = 750;

    public int WindowWidth { get; set; } = 1200;
    public int WindowHeight { get; set; } = 900;
    public string Theme { get; set; } = "system";

    [JsonIgnore]
    public static string DefaultPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tiny11options", "settings.json");

    public static UserSettings Load(string? path = null)
    {
        path ??= DefaultPath;
        if (!File.Exists(path)) return new UserSettings();

        try
        {
            var json = File.ReadAllText(path);
            var loaded = JsonSerializer.Deserialize<UserSettings>(json);
            if (loaded is null) return new UserSettings();
            loaded.Clamp();
            return loaded;
        }
        catch
        {
            return new UserSettings();
        }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }

    private void Clamp()
    {
        if (WindowWidth < MinWidth) WindowWidth = MinWidth;
        if (WindowHeight < MinHeight) WindowHeight = MinHeight;
        if (Theme != "system" && Theme != "light" && Theme != "dark") Theme = "system";
    }
}
```

- [ ] **Step 4: Run tests to confirm PASS**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~UserSettingsTests"
```

Expected: 4 passed.

- [ ] **Step 5: Wire UserSettings into MainWindow**

Modify `launcher/MainWindow.xaml.cs` — add at the top of the constructor (before `InitializeComponent`):

```csharp
private readonly Gui.Settings.UserSettings _settings;

public MainWindow()
{
    _settings = Gui.Settings.UserSettings.Load();
    InitializeComponent();
    Width = _settings.WindowWidth;
    Height = _settings.WindowHeight;

    // Persist size on close
    Closing += (_, _) =>
    {
        _settings.WindowWidth = (int)Width;
        _settings.WindowHeight = (int)Height;
        _settings.Save();
    };

    Loaded += async (_, _) => await InitializeWebViewAsync();
}
```

- [ ] **Step 6: Manual smoke — verify window size persistence**

```powershell
dotnet run --project launcher/tiny11options.Launcher.csproj
# Resize window to ~1400x950, close
dotnet run --project launcher/tiny11options.Launcher.csproj
# Window should reopen at the new size
```

Expected: second launch opens at the size you resized to.

- [ ] **Step 7: Commit**

```powershell
git add launcher/Gui/Settings/UserSettings.cs launcher/Tests/UserSettingsTests.cs launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): UserSettings with window size + theme persistence"
```

---

### Task 10: ThemeManager

**Files:**
- Create: `launcher/Gui/Theme/ThemeManager.cs`
- Create: `launcher/Tests/ThemeManagerTests.cs`

- [ ] **Step 1: Write failing tests**

Create `launcher/Tests/ThemeManagerTests.cs`:

```csharp
using Tiny11Options.Launcher.Gui.Theme;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ThemeManagerTests
{
    [Fact]
    public void EffectiveTheme_FollowsSystem_WhenUserPrefIsSystem()
    {
        var mgr = new ThemeManager(userPreference: "system", systemPrefersDark: () => true);
        Assert.Equal("dark", mgr.EffectiveTheme());

        mgr = new ThemeManager(userPreference: "system", systemPrefersDark: () => false);
        Assert.Equal("light", mgr.EffectiveTheme());
    }

    [Fact]
    public void EffectiveTheme_OverridesSystem_WhenUserSpecifies()
    {
        var mgr = new ThemeManager(userPreference: "dark", systemPrefersDark: () => false);
        Assert.Equal("dark", mgr.EffectiveTheme());

        mgr = new ThemeManager(userPreference: "light", systemPrefersDark: () => true);
        Assert.Equal("light", mgr.EffectiveTheme());
    }

    [Fact]
    public void SetUserPreference_FiresChangeEvent()
    {
        var mgr = new ThemeManager(userPreference: "light", systemPrefersDark: () => false);
        var fired = false;
        string? captured = null;
        mgr.ThemeChanged += (_, t) => { fired = true; captured = t; };

        mgr.SetUserPreference("dark");

        Assert.True(fired);
        Assert.Equal("dark", captured);
    }
}
```

- [ ] **Step 2: Run tests to confirm FAIL**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~ThemeManagerTests"
```

Expected: 3 failed.

- [ ] **Step 3: Implement ThemeManager**

Create `launcher/Gui/Theme/ThemeManager.cs`:

```csharp
using System;
using Microsoft.Win32;

namespace Tiny11Options.Launcher.Gui.Theme;

public class ThemeManager
{
    public event EventHandler<string>? ThemeChanged;

    private string _userPreference;
    private readonly Func<bool> _systemPrefersDark;

    public ThemeManager(string userPreference = "system", Func<bool>? systemPrefersDark = null)
    {
        _userPreference = userPreference;
        _systemPrefersDark = systemPrefersDark ?? DetectSystemDarkMode;
    }

    public string UserPreference => _userPreference;

    public void SetUserPreference(string pref)
    {
        if (pref != "system" && pref != "light" && pref != "dark") return;
        _userPreference = pref;
        ThemeChanged?.Invoke(this, EffectiveTheme());
    }

    public string EffectiveTheme()
    {
        if (_userPreference == "system")
            return _systemPrefersDark() ? "dark" : "light";
        return _userPreference;
    }

    private static bool DetectSystemDarkMode()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var v = key?.GetValue("AppsUseLightTheme");
            if (v is int i) return i == 0;
        }
        catch { }
        return false;
    }
}
```

- [ ] **Step 4: Run tests to confirm PASS**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~ThemeManagerTests"
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```powershell
git add launcher/Gui/Theme/ThemeManager.cs launcher/Tests/ThemeManagerTests.cs
git commit -m "feat(launcher): ThemeManager with system + user preference"
```

---

### Tasks 11-13 — defer until bridge is in place

Theme + settings are wired into UI behavior (via JS on the WebView2 side) once the bridge exists. Continue to Phase 3.

---

## Phase 3 — Bridge + handlers

### Task 14: BridgeMessage shape + Bridge dispatch (TDD)

**Files:**
- Create: `launcher/Gui/Bridge/BridgeMessage.cs`
- Create: `launcher/Gui/Bridge/IBridgeHandler.cs`
- Create: `launcher/Gui/Bridge/Bridge.cs`
- Create: `launcher/Tests/BridgeTests.cs`

- [ ] **Step 1: Write failing tests**

Create `launcher/Tests/BridgeTests.cs`:

```csharp
using System.Text.Json.Nodes;
using Moq;
using Tiny11Options.Launcher.Gui.Bridge;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BridgeTests
{
    [Fact]
    public async Task Dispatch_RoutesToHandler_ByType()
    {
        var handler = new Mock<IBridgeHandler>();
        handler.Setup(h => h.HandledTypes).Returns(new[] { "ping" });
        handler.Setup(h => h.HandleAsync("ping", It.IsAny<JsonObject>()))
            .ReturnsAsync(new BridgeMessage { Type = "pong", Payload = new JsonObject() });

        var bridge = new Bridge(new[] { handler.Object });

        var resp = await bridge.DispatchJsonAsync("{\"type\":\"ping\",\"payload\":{}}");

        Assert.NotNull(resp);
        var typeProp = JsonNode.Parse(resp!)?["type"]?.ToString();
        Assert.Equal("pong", typeProp);
    }

    [Fact]
    public async Task Dispatch_ReturnsHandlerError_OnUnknownType()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var resp = await bridge.DispatchJsonAsync("{\"type\":\"unknown\"}");
        var typeProp = JsonNode.Parse(resp!)?["type"]?.ToString();
        Assert.Equal("handler-error", typeProp);
    }

    [Fact]
    public async Task Dispatch_ReturnsHandlerError_OnMalformedJson()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var resp = await bridge.DispatchJsonAsync("{ not valid");
        var typeProp = JsonNode.Parse(resp!)?["type"]?.ToString();
        Assert.Equal("handler-error", typeProp);
    }
}
```

- [ ] **Step 2: Run tests to confirm FAIL**

Expected: 3 failed (types not defined).

- [ ] **Step 3: Implement BridgeMessage**

Create `launcher/Gui/Bridge/BridgeMessage.cs`:

```csharp
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Tiny11Options.Launcher.Gui.Bridge;

public class BridgeMessage
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "";

    [JsonPropertyName("payload")]
    public JsonObject? Payload { get; set; }
}
```

- [ ] **Step 4: Implement IBridgeHandler**

Create `launcher/Gui/Bridge/IBridgeHandler.cs`:

```csharp
using System.Text.Json.Nodes;

namespace Tiny11Options.Launcher.Gui.Bridge;

public interface IBridgeHandler
{
    IEnumerable<string> HandledTypes { get; }
    Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload);
}
```

- [ ] **Step 5: Implement Bridge**

Create `launcher/Gui/Bridge/Bridge.cs`:

```csharp
using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Bridge;

public class Bridge
{
    private readonly Dictionary<string, IBridgeHandler> _handlers = new(StringComparer.OrdinalIgnoreCase);

    public Bridge(IEnumerable<IBridgeHandler> handlers)
    {
        foreach (var h in handlers)
            foreach (var t in h.HandledTypes)
                _handlers[t] = h;
    }

    public event Action<string>? MessageToJs;

    public async Task<string?> DispatchJsonAsync(string json)
    {
        BridgeMessage? msg;
        try
        {
            msg = JsonSerializer.Deserialize<BridgeMessage>(json);
            if (msg is null || string.IsNullOrEmpty(msg.Type))
                return ErrorResponse("Empty or null bridge message");
        }
        catch (JsonException ex)
        {
            return ErrorResponse($"Malformed JSON: {ex.Message}");
        }

        if (!_handlers.TryGetValue(msg.Type, out var handler))
            return ErrorResponse($"Unknown message type: {msg.Type}");

        try
        {
            var resp = await handler.HandleAsync(msg.Type, msg.Payload);
            return resp is null ? null : Serialize(resp);
        }
        catch (Exception ex)
        {
            return ErrorResponse($"Handler {msg.Type} threw: {ex.Message}");
        }
    }

    public void SendToJs(BridgeMessage msg)
    {
        MessageToJs?.Invoke(Serialize(msg));
    }

    private static string Serialize(BridgeMessage msg)
        => JsonSerializer.Serialize(msg);

    private static string ErrorResponse(string msg)
    {
        var obj = new JsonObject { ["message"] = msg };
        return JsonSerializer.Serialize(new BridgeMessage { Type = "handler-error", Payload = obj });
    }
}
```

- [ ] **Step 6: Run tests to confirm PASS**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~BridgeTests"
```

Expected: 3 passed.

- [ ] **Step 7: Commit**

```powershell
git add launcher/Gui/Bridge/ launcher/Tests/BridgeTests.cs
git commit -m "feat(launcher): Bridge + IBridgeHandler + dispatch tests"
```

---

### Task 15: Wire Bridge into MainWindow + WebMessageReceived

**Files:**
- Modify: `launcher/MainWindow.xaml.cs`

- [ ] **Step 1: Update MainWindow to construct + wire Bridge**

In `MainWindow.xaml.cs`, add a private `Bridge _bridge` field and modify `InitializeWebViewAsync`:

```csharp
using Tiny11Options.Launcher.Gui.Bridge;

// ... inside MainWindow class:

private Bridge? _bridge;

private async System.Threading.Tasks.Task InitializeWebViewAsync()
{
    try
    {
        _uiCacheDir = ResolveUiCacheDir();
        ExtractUiResourcesIfNeeded(_uiCacheDir);

        var userDataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tiny11options", "webview2-userdata");
        Directory.CreateDirectory(userDataDir);

        var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
        await WebView.EnsureCoreWebView2Async(env);

        WebView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            "app.local", _uiCacheDir, CoreWebView2HostResourceAccessKind.Allow);

        WebView.CoreWebView2.Settings.IsWebMessageEnabled = true;

        _bridge = BuildBridge();
        _bridge.MessageToJs += SendJsonToJs;
        WebView.CoreWebView2.WebMessageReceived += async (_, e) =>
        {
            var json = e.TryGetWebMessageAsString();
            if (string.IsNullOrEmpty(json)) return;
            var resp = await _bridge.DispatchJsonAsync(json);
            if (!string.IsNullOrEmpty(resp)) SendJsonToJs(resp);
        };

        WebView.Source = new Uri("http://app.local/index.html");
    }
    catch (Exception ex)
    {
        MessageBox.Show(
            $"WebView2 Runtime is required but could not be initialized.\n\n{ex.Message}\n\n" +
            "Install from https://developer.microsoft.com/microsoft-edge/webview2/",
            "tiny11options", MessageBoxButton.OK, MessageBoxImage.Error);
        Close();
    }
}

private void SendJsonToJs(string json)
{
    if (WebView?.CoreWebView2 is null) return;
    Dispatcher.Invoke(() => WebView.CoreWebView2.PostWebMessageAsString(json));
}

private Bridge BuildBridge()
{
    // Handlers registered as we add them.
    var handlers = new List<IBridgeHandler>();
    return new Bridge(handlers);
}
```

- [ ] **Step 2: Build**

```powershell
dotnet build launcher/tiny11options.Launcher.csproj
```

Expected: 0 errors.

- [ ] **Step 3: Manual smoke**

```powershell
dotnet run --project launcher/tiny11options.Launcher.csproj
```

Expected: window opens, UI renders. JS calls to `window.chrome.webview.postMessage(...)` will receive `handler-error: Unknown message type` until handlers are wired in subsequent tasks.

- [ ] **Step 4: Commit**

```powershell
git add launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): wire Bridge into MainWindow WebMessageReceived"
```

---

### Task 16: BrowseHandlers (folder + file pickers)

**Files:**
- Create: `launcher/Gui/Handlers/BrowseHandlers.cs`
- Create: `launcher/Tests/BrowseHandlersTests.cs`

- [ ] **Step 1: Write failing test (logic-only — UI dialog mocked)**

Create `launcher/Tests/BrowseHandlersTests.cs`:

```csharp
using System.Text.Json.Nodes;
using Moq;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BrowseHandlersTests
{
    [Fact]
    public async Task BrowseFile_ReturnsBrowseResult_WithSelectedPath()
    {
        var picker = new Mock<IFilePicker>();
        picker.Setup(p => p.PickOpen(It.IsAny<string?>(), It.IsAny<string?>()))
              .Returns("C:\\test\\win11.iso");

        var handler = new BrowseHandlers(picker.Object);
        var resp = await handler.HandleAsync("browse-file",
            JsonNode.Parse("{\"context\":\"iso\",\"filter\":\"ISO|*.iso\"}")!.AsObject());

        Assert.NotNull(resp);
        Assert.Equal("browse-result", resp!.Type);
        Assert.Equal("iso", resp.Payload!["context"]?.ToString());
        Assert.Equal("C:\\test\\win11.iso", resp.Payload["path"]?.ToString());
    }

    [Fact]
    public async Task BrowseFile_ReturnsBrowseResult_WithNullPath_WhenCancelled()
    {
        var picker = new Mock<IFilePicker>();
        picker.Setup(p => p.PickOpen(It.IsAny<string?>(), It.IsAny<string?>()))
              .Returns((string?)null);

        var handler = new BrowseHandlers(picker.Object);
        var resp = await handler.HandleAsync("browse-file",
            JsonNode.Parse("{\"context\":\"iso\"}")!.AsObject());

        Assert.NotNull(resp);
        Assert.Equal("browse-result", resp!.Type);
        Assert.Null(resp.Payload!["path"]);
    }
}
```

- [ ] **Step 2: Run tests to confirm FAIL**

Expected: 2 failed.

- [ ] **Step 3: Implement IFilePicker + BrowseHandlers**

Create `launcher/Gui/Handlers/BrowseHandlers.cs`:

```csharp
using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.Win32;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public interface IFilePicker
{
    string? PickOpen(string? title, string? filter);
    string? PickFolder(string? title);
    string? PickSaveFile(string? title, string? filter, string? defaultName);
}

public class WpfFilePicker : IFilePicker
{
    public string? PickOpen(string? title, string? filter)
    {
        var dlg = new OpenFileDialog { Title = title, Filter = filter ?? "All files|*.*" };
        return dlg.ShowDialog() == true ? dlg.FileName : null;
    }

    public string? PickFolder(string? title)
    {
        var dlg = new OpenFolderDialog { Title = title };
        return dlg.ShowDialog() == true ? dlg.FolderName : null;
    }

    public string? PickSaveFile(string? title, string? filter, string? defaultName)
    {
        var dlg = new SaveFileDialog { Title = title, Filter = filter ?? "All files|*.*", FileName = defaultName ?? "" };
        return dlg.ShowDialog() == true ? dlg.FileName : null;
    }
}

public class BrowseHandlers : IBridgeHandler
{
    private readonly IFilePicker _picker;
    public BrowseHandlers(IFilePicker picker) { _picker = picker; }

    public IEnumerable<string> HandledTypes => new[] { "browse-file", "browse-folder", "browse-save-file" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var context = payload?["context"]?.ToString();
        var title = payload?["title"]?.ToString();
        var filter = payload?["filter"]?.ToString();
        var defaultName = payload?["defaultName"]?.ToString();

        string? path = type switch
        {
            "browse-file" => _picker.PickOpen(title, filter),
            "browse-folder" => _picker.PickFolder(title),
            "browse-save-file" => _picker.PickSaveFile(title, filter, defaultName),
            _ => null,
        };

        var resultPayload = new JsonObject
        {
            ["context"] = context,
            ["path"] = path,
        };
        return Task.FromResult<BridgeMessage?>(new BridgeMessage { Type = "browse-result", Payload = resultPayload });
    }
}
```

- [ ] **Step 4: Run tests to confirm PASS**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~BrowseHandlersTests"
```

Expected: 2 passed.

- [ ] **Step 5: Register in MainWindow.BuildBridge**

In `launcher/MainWindow.xaml.cs`, modify `BuildBridge()`:

```csharp
private Bridge BuildBridge()
{
    var handlers = new List<IBridgeHandler>
    {
        new BrowseHandlers(new WpfFilePicker()),
    };
    return new Bridge(handlers);
}
```

(Add `using Tiny11Options.Launcher.Gui.Handlers;` if not present.)

- [ ] **Step 6: Commit**

```powershell
git add launcher/Gui/Handlers/BrowseHandlers.cs launcher/Tests/BrowseHandlersTests.cs launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): BrowseHandlers (file/folder/save pickers)"
```

---

### Task 17: ProfileHandlers (save/load profile JSON)

**Files:**
- Create: `launcher/Gui/Handlers/ProfileHandlers.cs`
- Create: `launcher/Tests/ProfileHandlersTests.cs`

- [ ] **Step 1: Write failing tests**

Create `launcher/Tests/ProfileHandlersTests.cs`:

```csharp
using System.IO;
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ProfileHandlersTests
{
    [Fact]
    public async Task SaveAndLoadProfile_RoundTripsSelections()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tiny11-profile-{Guid.NewGuid():N}.json");
        try
        {
            var handler = new ProfileHandlers();

            var saveResp = await handler.HandleAsync("save-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\",\"selections\":{{\"items\":[\"a\",\"b\"]}}}}")!.AsObject());
            Assert.Equal("profile-saved", saveResp!.Type);

            var loadResp = await handler.HandleAsync("load-profile",
                JsonNode.Parse($"{{\"path\":\"{path.Replace("\\", "\\\\")}\"}}")!.AsObject());
            Assert.Equal("profile-loaded", loadResp!.Type);
            var items = loadResp.Payload!["selections"]?["items"]?.AsArray();
            Assert.NotNull(items);
            Assert.Equal(2, items!.Count);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task LoadProfile_ReturnsHandlerError_WhenFileMissing()
    {
        var handler = new ProfileHandlers();
        var resp = await handler.HandleAsync("load-profile",
            JsonNode.Parse("{\"path\":\"C:\\\\nonexistent\\\\path.json\"}")!.AsObject());
        Assert.Equal("handler-error", resp!.Type);
    }
}
```

- [ ] **Step 2: Run tests to confirm FAIL**

Expected: 2 failed.

- [ ] **Step 3: Implement ProfileHandlers**

Create `launcher/Gui/Handlers/ProfileHandlers.cs`:

```csharp
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class ProfileHandlers : IBridgeHandler
{
    public IEnumerable<string> HandledTypes => new[] { "save-profile", "load-profile" };

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var path = payload?["path"]?.ToString();
        if (string.IsNullOrEmpty(path))
            return Error("path required");

        return type switch
        {
            "save-profile" => await SaveAsync(path, payload!["selections"]?.AsObject()),
            "load-profile" => await LoadAsync(path),
            _ => Error($"unknown type {type}"),
        };
    }

    private static async Task<BridgeMessage> SaveAsync(string path, JsonObject? selections)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        var doc = new JsonObject { ["selections"] = selections?.DeepClone() ?? new JsonObject() };
        await File.WriteAllTextAsync(path, doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return new BridgeMessage { Type = "profile-saved", Payload = new JsonObject { ["path"] = path } };
    }

    private static async Task<BridgeMessage> LoadAsync(string path)
    {
        if (!File.Exists(path)) return Error($"profile not found: {path}");
        try
        {
            var json = await File.ReadAllTextAsync(path);
            var node = JsonNode.Parse(json) as JsonObject ?? new JsonObject();
            return new BridgeMessage
            {
                Type = "profile-loaded",
                Payload = new JsonObject
                {
                    ["path"] = path,
                    ["selections"] = node["selections"]?.DeepClone() ?? new JsonObject(),
                },
            };
        }
        catch (System.Exception ex)
        {
            return Error($"profile load failed: {ex.Message}");
        }
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
```

- [ ] **Step 4: Run tests to confirm PASS**

Expected: 2 passed.

- [ ] **Step 5: Register in MainWindow.BuildBridge** (add `new ProfileHandlers()` to handlers list).

- [ ] **Step 6: Commit**

```powershell
git add launcher/Gui/Handlers/ProfileHandlers.cs launcher/Tests/ProfileHandlersTests.cs launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): ProfileHandlers (save/load profile JSON)"
```

---

### Task 18: SelectionHandlers (port reconcile from Tiny11.Selections.psm1)

**Files:**
- Create: `launcher/Gui/Handlers/SelectionHandlers.cs`
- Create: `launcher/Gui/Catalog/CatalogModel.cs`
- Create: `launcher/Tests/SelectionHandlersTests.cs`

The C# version mirrors `Tiny11.Selections.psm1`'s `Resolve-Tiny11Selections` semantics: given a catalog (parsed from YAML elsewhere) and a set of user-selected item IDs, compute the effective selection by adding required dependencies (`runtimeDepsOn`) and removing selections that conflict with locked items.

- [ ] **Step 1: Write failing tests**

Create `launcher/Tests/SelectionHandlersTests.cs`:

```csharp
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class SelectionHandlersTests
{
    private const string SimpleCatalog = """
        {
          "items": [
            {"id":"a","displayName":"A","default":true,"locked":false},
            {"id":"b","displayName":"B","default":false,"locked":false,"runtimeDepsOn":["a"]},
            {"id":"c","displayName":"C","default":true,"locked":true}
          ]
        }
        """;

    [Fact]
    public async Task Reconcile_AddsRuntimeDeps()
    {
        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse($"{{\"catalog\":{SimpleCatalog},\"selected\":[\"b\"]}}")!.AsObject());

        Assert.Equal("selections-reconciled", resp!.Type);
        var effective = resp.Payload!["effective"]?.AsArray();
        Assert.Contains(effective!, n => n!.ToString() == "a");
        Assert.Contains(effective!, n => n!.ToString() == "b");
    }

    [Fact]
    public async Task Reconcile_LockedItemsAlwaysIncluded()
    {
        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse($"{{\"catalog\":{SimpleCatalog},\"selected\":[]}}")!.AsObject());

        var effective = resp!.Payload!["effective"]?.AsArray();
        Assert.Contains(effective!, n => n!.ToString() == "c");
    }
}
```

- [ ] **Step 2: Run tests to confirm FAIL**

Expected: 2 failed.

- [ ] **Step 3: Implement CatalogModel**

Create `launcher/Gui/Catalog/CatalogModel.cs`:

```csharp
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Tiny11Options.Launcher.Gui.Catalog;

public class CatalogItem
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "";
    [JsonPropertyName("default")] public bool Default { get; set; }
    [JsonPropertyName("locked")] public bool Locked { get; set; }
    [JsonPropertyName("runtimeDepsOn")] public List<string>? RuntimeDepsOn { get; set; }
}

public class Catalog
{
    [JsonPropertyName("items")] public List<CatalogItem> Items { get; set; } = new();
}
```

- [ ] **Step 4: Implement SelectionHandlers**

Create `launcher/Gui/Handlers/SelectionHandlers.cs`:

```csharp
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Catalog;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class SelectionHandlers : IBridgeHandler
{
    public IEnumerable<string> HandledTypes => new[] { "reconcile-selections" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var catalogJson = payload?["catalog"]?.ToJsonString();
        if (string.IsNullOrEmpty(catalogJson))
            return Task.FromResult<BridgeMessage?>(Error("catalog required"));

        var catalog = JsonSerializer.Deserialize<Catalog>(catalogJson) ?? new Catalog();

        var selected = (payload?["selected"]?.AsArray() ?? new JsonArray())
            .Select(n => n!.ToString())
            .ToHashSet();

        var byId = catalog.Items.ToDictionary(i => i.Id);

        // Always include locked items
        foreach (var item in catalog.Items.Where(i => i.Locked))
            selected.Add(item.Id);

        // Iteratively add runtime deps (transitive)
        bool changed;
        do
        {
            changed = false;
            foreach (var id in selected.ToList())
            {
                if (!byId.TryGetValue(id, out var item)) continue;
                foreach (var dep in item.RuntimeDepsOn ?? new List<string>())
                {
                    if (selected.Add(dep)) changed = true;
                }
            }
        } while (changed);

        var resultArr = new JsonArray();
        foreach (var id in selected) resultArr.Add(id);

        return Task.FromResult<BridgeMessage?>(new BridgeMessage
        {
            Type = "selections-reconciled",
            Payload = new JsonObject { ["effective"] = resultArr },
        });
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
```

- [ ] **Step 5: Run tests to confirm PASS**

Expected: 2 passed.

- [ ] **Step 6: Register in MainWindow.BuildBridge**, commit:

```powershell
git add launcher/Gui/Catalog/CatalogModel.cs launcher/Gui/Handlers/SelectionHandlers.cs launcher/Tests/SelectionHandlersTests.cs launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): SelectionHandlers (reconcile with runtime deps + locked items)"
```

---

### Task 19: tiny11maker-from-config.ps1 wrapper script

**Files:**
- Create: `tiny11maker-from-config.ps1` (at repo root)

This wrapper reads a JSON config file (selections + options) and invokes the build worker directly without going through the interactive wizard. It's embedded into the .exe alongside `tiny11maker.ps1`.

- [ ] **Step 1: Create the wrapper script**

Create `tiny11maker-from-config.ps1`:

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutputIso,
    [int]$ImageIndex = 0,
    [string]$Edition,
    [switch]$AllowVLSource,
    [switch]$FastBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

$ConfigJson = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Locate the bundled modules - same dir as this wrapper
$RepoRoot = Split-Path -Parent $PSCommandPath
$ModulesDir = Join-Path $RepoRoot 'src'

Import-Module (Join-Path $ModulesDir 'Tiny11.Catalog.psm1')   -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Selections.psm1') -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Iso.psm1')        -Force
Import-Module (Join-Path $ModulesDir 'Tiny11.Worker.psm1')     -Force

# Build the selection list from the config and reconcile against catalog
$catalogPath = Join-Path $RepoRoot 'catalog'
$catalog = Import-Tiny11Catalog -Path $catalogPath
$selections = Resolve-Tiny11Selections -Catalog $catalog -Selected $ConfigJson.selections

# Stream JSON progress markers - launcher parses these line-by-line
function Write-ProgressJson($phase, $step, $percent) {
    $obj = @{ type = 'build-progress'; payload = @{ phase = $phase; step = $step; percent = $percent } }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
}

try {
    Write-ProgressJson 'preflight' 'Validating source ISO' 0
    $imageInfo = Get-Tiny11VolumeForImage -ImagePath $Source
    if ($Edition) { $ImageIndex = Resolve-Tiny11ImageIndex -ImageInfo $imageInfo -EditionName $Edition }
    if ($ImageIndex -le 0) { throw "Image index could not be resolved (Edition=$Edition)" }

    if (-not $AllowVLSource -and -not (Test-Tiny11SourceIsConsumer -ImageInfo $imageInfo -ImageIndex $ImageIndex)) {
        throw "Source appears to be VL/MSDN. Pass -AllowVLSource to override."
    }

    Invoke-Tiny11Build `
        -SourceIso $Source `
        -ImageIndex $ImageIndex `
        -OutputIso $OutputIso `
        -Selections $selections `
        -FastBuild:$FastBuild `
        -ProgressHook { param($phase, $step, $percent) Write-ProgressJson $phase $step $percent }

    $obj = @{ type = 'build-complete'; payload = @{ outputIso = $OutputIso } }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
    exit 0
}
catch {
    $obj = @{ type = 'build-error'; payload = @{ message = $_.Exception.Message; stackTrace = $_.ScriptStackTrace } }
    [Console]::Error.WriteLine(($obj | ConvertTo-Json -Compress))
    exit 1
}
```

- [ ] **Step 2: Verify the wrapper script lints with PSScriptAnalyzer (smoke check, no functional run yet)**

```powershell
Invoke-ScriptAnalyzer -Path tiny11maker-from-config.ps1 -Severity Warning,Error
```

Expected: no warnings/errors. (If `Invoke-Tiny11Build` or other functions don't yet exist with these exact names in the existing modules, the wrapper either calls into existing equivalent functions or this task documents the API gap to be addressed by the engineer reviewing v0.2.0 module exports — see "Implementation note" in spec.)

- [ ] **Step 3: Add the wrapper to the launcher's embedded resources**

In `launcher/tiny11options.Launcher.csproj`, add inside the resources `<ItemGroup>`:

```xml
<EmbeddedResource Include="..\tiny11maker-from-config.ps1">
  <LogicalName>tiny11maker-from-config.ps1</LogicalName>
</EmbeddedResource>
```

- [ ] **Step 4: Commit**

```powershell
git add tiny11maker-from-config.ps1 launcher/tiny11options.Launcher.csproj
git commit -m "feat: tiny11maker-from-config.ps1 wrapper for launcher-driven builds"
```

---

### Task 20: IsoHandlers (subprocess pwsh for validate-iso)

**Files:**
- Create: `launcher/Gui/Handlers/IsoHandlers.cs`
- Create: `launcher/Gui/Subprocess/PwshRunner.cs`
- Create: `tiny11-iso-validate.ps1` (at repo root)
- Create: `launcher/Tests/PwshRunnerTests.cs`

- [ ] **Step 1: Create the validation wrapper script**

Create `tiny11-iso-validate.ps1`:

```powershell
[CmdletBinding()]
param([Parameter(Mandatory)][string]$IsoPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $RepoRoot 'src' 'Tiny11.Iso.psm1') -Force

try {
    if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }

    $info = Get-Tiny11VolumeForImage -ImagePath $IsoPath
    $editions = @()
    foreach ($img in $info.Images) {
        $editions += @{
            index    = $img.ImageIndex
            name     = $img.ImageName
            size     = $img.ImageSize
            arch     = $img.Architecture
        }
    }

    $obj = @{ ok = $true; editions = $editions }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
    exit 0
}
catch {
    $obj = @{ ok = $false; message = $_.Exception.Message }
    [Console]::WriteLine(($obj | ConvertTo-Json -Compress))
    exit 1
}
```

- [ ] **Step 2: Embed the validation script in csproj** (same pattern as Task 19 step 3, with LogicalName `tiny11-iso-validate.ps1`).

- [ ] **Step 3: Implement PwshRunner**

Create `launcher/Gui/Subprocess/PwshRunner.cs`:

```csharp
using System.Diagnostics;
using System.Text;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Subprocess;

public record PwshResult(int ExitCode, string Stdout, string Stderr);

public class PwshRunner
{
    public virtual async Task<PwshResult> RunAsync(string ps1Path, string[] args, string workingDir)
    {
        var argLine = new StringBuilder("-ExecutionPolicy Bypass -NoProfile -File ");
        argLine.Append('"').Append(ps1Path).Append('"');
        foreach (var a in args)
        {
            argLine.Append(' ');
            if (a.Contains(' ') || a.Contains('"'))
                argLine.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
            else
                argLine.Append(a);
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = argLine.ToString(),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = workingDir,
        };

        using var proc = Process.Start(psi)!;
        var stdoutTask = proc.StandardOutput.ReadToEndAsync();
        var stderrTask = proc.StandardError.ReadToEndAsync();
        await proc.WaitForExitAsync();
        return new PwshResult(proc.ExitCode, await stdoutTask, await stderrTask);
    }
}
```

- [ ] **Step 4: Implement IsoHandlers**

Create `launcher/Gui/Handlers/IsoHandlers.cs`:

```csharp
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Subprocess;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class IsoHandlers : IBridgeHandler
{
    private readonly PwshRunner _runner;
    private readonly string _resourcesDir;

    public IsoHandlers(PwshRunner runner, string resourcesDir)
    {
        _runner = runner;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "validate-iso" };

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var iso = payload?["isoPath"]?.ToString();
        if (string.IsNullOrEmpty(iso))
            return Error("isoPath required");

        var script = Path.Combine(_resourcesDir, "tiny11-iso-validate.ps1");
        var result = await _runner.RunAsync(script, new[] { "-IsoPath", iso }, _resourcesDir);

        if (result.ExitCode != 0)
            return new BridgeMessage
            {
                Type = "iso-error",
                Payload = new JsonObject { ["message"] = result.Stderr.Trim() },
            };

        var parsed = JsonNode.Parse(result.Stdout) as JsonObject ?? new JsonObject();
        return new BridgeMessage
        {
            Type = "iso-validated",
            Payload = new JsonObject { ["editions"] = parsed["editions"]?.DeepClone() },
        };
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
```

- [ ] **Step 5: Write tests for PwshRunner (using a known-trivial command)**

Create `launcher/Tests/PwshRunnerTests.cs`:

```csharp
using System.IO;
using Tiny11Options.Launcher.Gui.Subprocess;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class PwshRunnerTests
{
    [Fact]
    public async Task RunAsync_ReturnsStdoutAndExitZero_OnTrivialScript()
    {
        var script = Path.Combine(Path.GetTempPath(), $"echo-{Guid.NewGuid():N}.ps1");
        File.WriteAllText(script, "Write-Output 'hello'");
        try
        {
            var runner = new PwshRunner();
            var result = await runner.RunAsync(script, Array.Empty<string>(), Path.GetTempPath());

            Assert.Equal(0, result.ExitCode);
            Assert.Contains("hello", result.Stdout);
        }
        finally { File.Delete(script); }
    }

    [Fact]
    public async Task RunAsync_ReturnsNonZeroExit_OnFailure()
    {
        var script = Path.Combine(Path.GetTempPath(), $"fail-{Guid.NewGuid():N}.ps1");
        File.WriteAllText(script, "exit 7");
        try
        {
            var runner = new PwshRunner();
            var result = await runner.RunAsync(script, Array.Empty<string>(), Path.GetTempPath());
            Assert.Equal(7, result.ExitCode);
        }
        finally { File.Delete(script); }
    }
}
```

- [ ] **Step 6: Run tests to confirm PASS**

Expected: 2 passed.

- [ ] **Step 7: Register IsoHandlers in MainWindow.BuildBridge**

The `_resourcesDir` for IsoHandlers is the per-version cache where the headless wrapper extracts. Add a helper in MainWindow that extracts ALL needed PS resources to a stable cache dir (similar to `_uiCacheDir`), and pass that to IsoHandlers.

- [ ] **Step 8: Commit**

```powershell
git add launcher/Gui/Subprocess/PwshRunner.cs launcher/Gui/Handlers/IsoHandlers.cs tiny11-iso-validate.ps1 launcher/Tests/PwshRunnerTests.cs launcher/MainWindow.xaml.cs launcher/tiny11options.Launcher.csproj
git commit -m "feat(launcher): IsoHandlers + PwshRunner + iso-validate wrapper"
```

---

### Task 21: BuildHandlers (subprocess pwsh + progress streaming)

**Files:**
- Create: `launcher/Gui/Handlers/BuildHandlers.cs`
- Create: `launcher/Tests/BuildHandlersTests.cs`

- [ ] **Step 1: Implement BuildHandlers**

Create `launcher/Gui/Handlers/BuildHandlers.cs`:

```csharp
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class BuildHandlers : IBridgeHandler
{
    private readonly Bridge _bridge;
    private readonly string _resourcesDir;

    public BuildHandlers(Bridge bridge, string resourcesDir)
    {
        _bridge = bridge;
        _resourcesDir = resourcesDir;
    }

    public IEnumerable<string> HandledTypes => new[] { "start-build", "cancel-build" };

    private Process? _activeBuild;

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "cancel-build")
        {
            _activeBuild?.Kill(entireProcessTree: true);
            return new BridgeMessage { Type = "build-cancelled", Payload = new JsonObject() };
        }

        if (_activeBuild is { HasExited: false })
            return Error("a build is already in progress");

        var configPath = Path.Combine(_resourcesDir, $"build-config-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(configPath, payload?.ToJsonString() ?? "{}");

        var script = Path.Combine(_resourcesDir, "tiny11maker-from-config.ps1");
        var src = payload?["source"]?.ToString() ?? "";
        var iso = payload?["outputIso"]?.ToString() ?? "";
        var edition = payload?["edition"]?.ToString() ?? "";

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-ExecutionPolicy Bypass -NoProfile -File \"{script}\" " +
                        $"-ConfigPath \"{configPath}\" -Source \"{src}\" -OutputIso \"{iso}\" -Edition \"{edition}\"",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = _resourcesDir,
        };

        _activeBuild = Process.Start(psi);
        if (_activeBuild is null) return Error("Failed to spawn pwsh for build");

        // Stream stdout line-by-line, forwarding JSON markers as bridge messages
        _ = Task.Run(async () =>
        {
            string? line;
            while ((line = await _activeBuild.StandardOutput.ReadLineAsync()) is not null)
            {
                ForwardJsonLine(line);
            }
        });

        _ = Task.Run(async () =>
        {
            await _activeBuild.WaitForExitAsync();
            if (_activeBuild.ExitCode != 0)
            {
                var err = await _activeBuild.StandardError.ReadToEndAsync();
                _bridge.SendToJs(new BridgeMessage
                {
                    Type = "build-error",
                    Payload = new JsonObject { ["message"] = err.Trim() },
                });
            }
        });

        return new BridgeMessage { Type = "build-started", Payload = new JsonObject() };
    }

    private void ForwardJsonLine(string line)
    {
        try
        {
            var node = JsonNode.Parse(line) as JsonObject;
            if (node?["type"]?.ToString() is string t && (t == "build-progress" || t == "build-complete"))
            {
                _bridge.SendToJs(new BridgeMessage
                {
                    Type = t,
                    Payload = node["payload"]?.AsObject(),
                });
            }
        }
        catch { /* non-JSON lines ignored */ }
    }

    private static BridgeMessage Error(string msg)
        => new() { Type = "handler-error", Payload = new JsonObject { ["message"] = msg } };
}
```

- [ ] **Step 2: Write a smoke test that asserts ForwardJsonLine parsing**

Create `launcher/Tests/BuildHandlersTests.cs`:

```csharp
using System.Reflection;
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BuildHandlersTests
{
    [Fact]
    public void ForwardJsonLine_RoutesProgressMarkers_ViaBridge()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? captured = null;
        bridge.MessageToJs += s => captured = s;

        var bh = new BuildHandlers(bridge, Path.GetTempPath());
        var fwd = bh.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(bh, new object?[] { "{\"type\":\"build-progress\",\"payload\":{\"phase\":\"foo\",\"step\":\"bar\",\"percent\":42}}" });

        Assert.NotNull(captured);
        var node = JsonNode.Parse(captured!);
        Assert.Equal("build-progress", node?["type"]?.ToString());
        Assert.Equal(42, (int?)node?["payload"]?["percent"]);
    }

    [Fact]
    public void ForwardJsonLine_IgnoresNonJsonLines()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var bh = new BuildHandlers(bridge, Path.GetTempPath());
        var fwd = bh.GetType().GetMethod("ForwardJsonLine", BindingFlags.Instance | BindingFlags.NonPublic)!;
        fwd.Invoke(bh, new object?[] { "this is just a log line, not JSON" });

        Assert.False(fired);
    }
}
```

- [ ] **Step 3: Run tests to confirm PASS**

Expected: 2 passed.

- [ ] **Step 4: Register BuildHandlers in MainWindow.BuildBridge** (passing the bridge instance via a small refactor — `BuildBridge` returns the bridge AFTER all handlers including BuildHandlers are wired).

- [ ] **Step 5: Commit**

```powershell
git add launcher/Gui/Handlers/BuildHandlers.cs launcher/Tests/BuildHandlersTests.cs launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): BuildHandlers with subprocess + progress streaming"
```

---

### Task 22: Theme bridge handler (apply-theme + get-theme)

**Files:**
- Create: `launcher/Gui/Handlers/ThemeHandlers.cs`
- Create: `launcher/Tests/ThemeHandlersTests.cs`

The JS UI sends `{type:"apply-theme",payload:{theme:"dark"}}` to set user pref, and `{type:"get-theme"}` on load to query effective theme.

- [ ] **Step 1: Implement ThemeHandlers**

Create `launcher/Gui/Handlers/ThemeHandlers.cs`:

```csharp
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Theme;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class ThemeHandlers : IBridgeHandler
{
    private readonly ThemeManager _theme;
    private readonly UserSettings _settings;

    public ThemeHandlers(ThemeManager theme, UserSettings settings)
    {
        _theme = theme;
        _settings = settings;
    }

    public IEnumerable<string> HandledTypes => new[] { "get-theme", "apply-theme" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "apply-theme")
        {
            var pref = payload?["theme"]?.ToString() ?? "system";
            _theme.SetUserPreference(pref);
            _settings.Theme = pref;
            _settings.Save();
        }

        var resp = new BridgeMessage
        {
            Type = "theme-applied",
            Payload = new JsonObject
            {
                ["userPreference"] = _theme.UserPreference,
                ["effective"] = _theme.EffectiveTheme(),
            },
        };
        return Task.FromResult<BridgeMessage?>(resp);
    }
}
```

- [ ] **Step 2: Write tests**

Create `launcher/Tests/ThemeHandlersTests.cs`:

```csharp
using System.IO;
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Handlers;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Theme;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ThemeHandlersTests
{
    [Fact]
    public async Task ApplyTheme_PersistsToSettings()
    {
        var path = Path.Combine(Path.GetTempPath(), $"theme-{Guid.NewGuid():N}.json");
        try
        {
            var s = new UserSettings();
            var t = new ThemeManager("system", () => false);
            var h = new ThemeHandlers(t, s);

            await h.HandleAsync("apply-theme", JsonNode.Parse("{\"theme\":\"dark\"}")!.AsObject());
            s.Save(path);

            var reloaded = UserSettings.Load(path);
            Assert.Equal("dark", reloaded.Theme);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task GetTheme_ReturnsEffectiveTheme()
    {
        var t = new ThemeManager("dark", () => false);
        var h = new ThemeHandlers(t, new UserSettings());
        var resp = await h.HandleAsync("get-theme", new JsonObject());
        Assert.Equal("dark", resp!.Payload!["effective"]?.ToString());
    }
}
```

- [ ] **Step 3: Run, register, commit**

```powershell
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj --filter "FullyQualifiedName~ThemeHandlersTests"
git add launcher/Gui/Handlers/ThemeHandlers.cs launcher/Tests/ThemeHandlersTests.cs launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): ThemeHandlers (get-theme, apply-theme)"
```

---

## Phase 4 — Updates

### Task 23: Add Velopack package

**Files:**
- Modify: `launcher/tiny11options.Launcher.csproj`

- [ ] **Step 1: Add Velopack PackageReference**

```powershell
dotnet add launcher/tiny11options.Launcher.csproj package Velopack
```

Then verify the resulting `<PackageReference>` in the csproj uses an exact (non-floating) version. If it uses a wildcard, edit to pin to the specific version.

- [ ] **Step 2: Hook Velopack into Program.Main**

Modify `launcher/Program.cs`:

```csharp
using System;
using Velopack;

namespace Tiny11Options.Launcher;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // Velopack hooks: must run BEFORE any other startup code so install/update events fire.
        VelopackApp.Build()
            .WithFirstRun(_ => { /* nothing on first run yet */ })
            .Run();

        if (args.Length > 0)
        {
            return Headless.HeadlessRunner.Run(args);
        }

        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}
```

- [ ] **Step 3: Build to confirm reference resolves**

```powershell
dotnet build launcher/tiny11options.Launcher.csproj
```

Expected: 0 errors.

- [ ] **Step 4: Commit**

```powershell
git add launcher/tiny11options.Launcher.csproj launcher/Program.cs
git commit -m "feat(launcher): Velopack package + VelopackApp.Build hook in Main"
```

---

### Task 24: UpdateNotifier (TDD with mocked update source)

**Files:**
- Create: `launcher/Gui/Updates/IUpdateSource.cs`
- Create: `launcher/Gui/Updates/UpdateNotifier.cs`
- Create: `launcher/Tests/UpdateNotifierTests.cs`

- [ ] **Step 1: Define IUpdateSource (so we can test the notifier without a real GitHub roundtrip)**

Create `launcher/Gui/Updates/IUpdateSource.cs`:

```csharp
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Updates;

public record UpdateInfo(string Version, string Changelog);

public interface IUpdateSource
{
    Task<UpdateInfo?> CheckAsync();
    Task ApplyAndRestartAsync();
}
```

- [ ] **Step 2: Write failing tests**

Create `launcher/Tests/UpdateNotifierTests.cs`:

```csharp
using System.Threading.Tasks;
using Moq;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Updates;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class UpdateNotifierTests
{
    [Fact]
    public async Task CheckAsync_SendsUpdateAvailable_WhenNewerVersionFound()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync())
              .ReturnsAsync(new UpdateInfo("0.3.0", "* New feature"));

        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        string? sent = null;
        bridge.MessageToJs += s => sent = s;

        var notifier = new UpdateNotifier(source.Object, bridge);
        await notifier.CheckAsync();

        Assert.NotNull(sent);
        Assert.Contains("update-available", sent!);
        Assert.Contains("0.3.0", sent);
    }

    [Fact]
    public async Task CheckAsync_SendsNothing_WhenNoUpdate()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync()).ReturnsAsync((UpdateInfo?)null);

        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var notifier = new UpdateNotifier(source.Object, bridge);
        await notifier.CheckAsync();

        Assert.False(fired);
    }

    [Fact]
    public async Task CheckAsync_Silent_WhenSourceThrows()
    {
        var source = new Mock<IUpdateSource>();
        source.Setup(s => s.CheckAsync()).ThrowsAsync(new System.Net.Http.HttpRequestException("network down"));

        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var fired = false;
        bridge.MessageToJs += _ => fired = true;

        var notifier = new UpdateNotifier(source.Object, bridge);
        await notifier.CheckAsync();

        Assert.False(fired);
    }
}
```

- [ ] **Step 3: Run tests to confirm FAIL**

Expected: 3 failed.

- [ ] **Step 4: Implement UpdateNotifier**

Create `launcher/Gui/Updates/UpdateNotifier.cs`:

```csharp
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Updates;

public class UpdateNotifier
{
    private readonly IUpdateSource _source;
    private readonly Bridge _bridge;
    public UpdateInfo? PendingUpdate { get; private set; }

    public UpdateNotifier(IUpdateSource source, Bridge bridge)
    {
        _source = source;
        _bridge = bridge;
    }

    public async Task CheckAsync()
    {
        try
        {
            var info = await _source.CheckAsync();
            if (info is null) return;
            PendingUpdate = info;
            _bridge.SendToJs(new BridgeMessage
            {
                Type = "update-available",
                Payload = new JsonObject
                {
                    ["version"] = info.Version,
                    ["changelog"] = info.Changelog,
                },
            });
        }
        catch
        {
            // Silent — network down, GitHub 503, etc.
        }
    }

    public Task ApplyAsync() => _source.ApplyAndRestartAsync();
}
```

- [ ] **Step 5: Implement VelopackUpdateSource**

Create `launcher/Gui/Updates/VelopackUpdateSource.cs`:

```csharp
using System.Threading.Tasks;
using Velopack;
using Velopack.Sources;

namespace Tiny11Options.Launcher.Gui.Updates;

public class VelopackUpdateSource : IUpdateSource
{
    private readonly UpdateManager _manager;

    public VelopackUpdateSource(string githubRepo)
    {
        var src = new GithubSource(githubRepo, accessToken: null, prerelease: false);
        _manager = new UpdateManager(src);
    }

    public async Task<UpdateInfo?> CheckAsync()
    {
        if (!_manager.IsInstalled) return null;
        var info = await _manager.CheckForUpdatesAsync();
        if (info is null) return null;
        return new UpdateInfo(
            info.TargetFullRelease.Version.ToString(),
            info.TargetFullRelease.NotesMarkdown ?? "");
    }

    public async Task ApplyAndRestartAsync()
    {
        var info = await _manager.CheckForUpdatesAsync();
        if (info is null) return;
        await _manager.DownloadUpdatesAsync(info);
        _manager.ApplyUpdatesAndRestart(info);
    }
}
```

- [ ] **Step 6: Run tests to confirm PASS**

Expected: 3 passed (the VelopackUpdateSource is not unit-tested directly because it requires a real Velopack-installed runtime; covered by manual smoke 3).

- [ ] **Step 7: Add an "apply-update" bridge handler**

Create `launcher/Gui/Handlers/UpdateHandlers.cs`:

```csharp
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Updates;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class UpdateHandlers : IBridgeHandler
{
    private readonly UpdateNotifier _notifier;
    public UpdateHandlers(UpdateNotifier notifier) { _notifier = notifier; }

    public IEnumerable<string> HandledTypes => new[] { "apply-update" };

    public async Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        try
        {
            await _notifier.ApplyAsync();
            return new BridgeMessage { Type = "update-applying", Payload = new JsonObject() };
        }
        catch (System.Exception ex)
        {
            return new BridgeMessage
            {
                Type = "update-error",
                Payload = new JsonObject { ["message"] = ex.Message },
            };
        }
    }
}
```

- [ ] **Step 8: Wire UpdateNotifier into MainWindow** (background-call CheckAsync after WebView2 init; register UpdateHandlers).

- [ ] **Step 9: Commit**

```powershell
git add launcher/Gui/Updates/ launcher/Gui/Handlers/UpdateHandlers.cs launcher/Tests/UpdateNotifierTests.cs launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): UpdateNotifier with Velopack source + apply-update handler"
```

---

### Task 25: JS-side update badge UI

**Files:**
- Modify: `ui/index.html` (add badge element)
- Modify: `ui/style.css` (badge styles)
- Modify: `ui/app.js` (handle `update-available`, badge click → dialog)

- [ ] **Step 1: Add badge element near theme toggle in `ui/index.html`**

Find the theme-toggle area in `ui/index.html` and add inside the same container:

```html
<button id="update-badge" class="hidden" title="Update available" aria-label="Update available">●</button>
```

- [ ] **Step 2: Add badge styles in `ui/style.css`**

```css
#update-badge {
    display: inline-block;
    margin-left: 0.5rem;
    color: var(--accent);
    background: transparent;
    border: none;
    font-size: 1.5rem;
    cursor: pointer;
    line-height: 1;
}
#update-badge.hidden { display: none; }
```

- [ ] **Step 3: Add handlers in `ui/app.js`**

Inside the existing `onPs(...)` dispatch:

```js
case 'update-available': {
    const badge = document.getElementById('update-badge');
    badge.classList.remove('hidden');
    badge.dataset.version = msg.payload.version;
    badge.dataset.changelog = msg.payload.changelog;
    break;
}
case 'update-applying':
    showToast('Update downloading… app will restart when ready.');
    break;
case 'update-error':
    showToast(`Update failed: ${msg.payload.message}`);
    break;
```

And bind a click handler near app initialization:

```js
document.getElementById('update-badge').addEventListener('click', () => {
    const v = badge.dataset.version || '?';
    const cl = badge.dataset.changelog || '';
    const result = window.confirm(
        `Version ${v} is available.\n\nChangelog:\n${cl}\n\nInstall and restart now?`);
    if (result) ps('apply-update', {});
});
```

(`showToast` is the existing v0.2.0 toast helper.)

- [ ] **Step 4: Manual smoke**

Run the launcher locally — no update will be available against the live GitHub Releases (your local build version will match latest), so the badge stays hidden. To smoke the path, temporarily make `UpdateNotifier.CheckAsync` synthesize a fake `UpdateInfo("999.0.0","fake")` and verify the badge appears + dialog shows. Revert the test stub before committing.

- [ ] **Step 5: Commit**

```powershell
git add ui/index.html ui/style.css ui/app.js
git commit -m "feat(ui): update badge near theme toggle + apply-update flow"
```

---

### Task 26: Wire update check to fire on app launch

**Files:**
- Modify: `launcher/MainWindow.xaml.cs`

- [ ] **Step 1: Trigger `_notifier.CheckAsync()` after WebView2 init**

In `MainWindow.InitializeWebViewAsync`, after `WebView.Source = new Uri(...)`:

```csharp
// Background update check — non-blocking, errors swallowed by notifier
_ = Task.Run(async () => await _notifier!.CheckAsync());
```

- [ ] **Step 2: Build + smoke as in Task 25**

- [ ] **Step 3: Commit**

```powershell
git add launcher/MainWindow.xaml.cs
git commit -m "feat(launcher): fire update check on app launch (background)"
```

---

## Phase 5 — PowerShell module cleanup

### Task 27: Delete Tiny11.Bridge.psm1 + tests

**Files:**
- Delete: `src/Tiny11.Bridge.psm1`
- Delete: `tests/Tiny11.Bridge.Tests.ps1`

- [ ] **Step 1: Verify nothing else imports the module**

```powershell
Select-String -Path src/*.psm1, tests/*.ps1, tiny11maker.ps1 -Pattern 'Tiny11\.Bridge' -List
```

Expected: only matches in the file being deleted and its test. Otherwise STOP and address the consumer first.

- [ ] **Step 2: Delete the files**

```powershell
git rm src/Tiny11.Bridge.psm1 tests/Tiny11.Bridge.Tests.ps1
```

- [ ] **Step 3: Run Pester to confirm no regressions**

```powershell
Invoke-Pester tests/
```

Expected: green (count is 4 lower than before).

- [ ] **Step 4: Commit**

```powershell
git commit -m "chore: remove Tiny11.Bridge.psm1 (superseded by C# Bridge in launcher)"
```

---

### Task 28: Delete Tiny11.WebView2.psm1 + tests + remove Show-Tiny11Wizard call

**Files:**
- Delete: `src/Tiny11.WebView2.psm1`
- Delete: `tests/Tiny11.WebView2.Tests.ps1`
- Modify: `tiny11maker.ps1` (remove Show-Tiny11Wizard branch; keep CLI/headless paths intact)

- [ ] **Step 1: Read tiny11maker.ps1 to find the Show-Tiny11Wizard call site**

Open `tiny11maker.ps1` and locate the section that conditionally calls `Show-Tiny11Wizard`. Replace that branch with an explicit error if the script is invoked with no CLI args:

```powershell
# Interactive (no-args) mode is now handled by tiny11options.exe, NOT this script.
# This script remains the orchestrator for CLI / headless invocation.
if ($PSBoundParameters.Count -eq 0 -and -not $Source) {
    Write-Error @"
tiny11maker.ps1 no longer ships an interactive wizard. Use the GUI launcher:

  tiny11options.exe                              (interactive wizard)
  tiny11options.exe -Source X -Edition 'Pro' -OutputIso Y    (headless)

To invoke this script directly with positional/named params, supply at least
-Source. See README.md for the full parameter list.
"@
    exit 64
}
```

(Adjust the exact location based on the existing structure of tiny11maker.ps1 — the engineer reading this plan should grep for `Show-Tiny11Wizard` and replace its surrounding control flow.)

- [ ] **Step 2: Verify no other module references WebView2 module**

```powershell
Select-String -Path src/*.psm1, tests/*.ps1, tiny11maker.ps1 -Pattern 'Tiny11\.WebView2' -List
```

Expected: only matches in the files being deleted.

- [ ] **Step 3: Delete the files**

```powershell
git rm src/Tiny11.WebView2.psm1 tests/Tiny11.WebView2.Tests.ps1
```

- [ ] **Step 4: Run Pester**

Expected: green; total count is 8 lower.

- [ ] **Step 5: Commit**

```powershell
git add tiny11maker.ps1
git commit -m "chore: remove Tiny11.WebView2.psm1; tiny11maker.ps1 no longer hosts wizard"
```

---

### Task 29: Drift test for embedded resources

**Files:**
- Create: `tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1`

- [ ] **Step 1: Write the drift test**

```powershell
Describe 'Launcher embedded-resource drift' {
    BeforeAll {
        $script:csproj = Get-Content -Raw "$PSScriptRoot\..\launcher\tiny11options.Launcher.csproj"
    }

    It 'Embeds every retained PS module from src/' {
        $retained = @(
            'Tiny11.Iso.psm1', 'Tiny11.Worker.psm1', 'Tiny11.Catalog.psm1', 'Tiny11.Hives.psm1',
            'Tiny11.Selections.psm1', 'Tiny11.Autounattend.psm1', 'Tiny11.Actions.psm1',
            'Tiny11.Actions.Registry.psm1', 'Tiny11.Actions.Filesystem.psm1',
            'Tiny11.Actions.ProvisionedAppx.psm1', 'Tiny11.Actions.ScheduledTask.psm1'
        )
        foreach ($m in $retained) {
            $csproj | Should -Match ([regex]::Escape($m))
        }
    }

    It 'Does NOT embed deleted modules' {
        $csproj | Should -Not -Match 'Tiny11\.Bridge\.psm1'
        $csproj | Should -Not -Match 'Tiny11\.WebView2\.psm1'
    }

    It 'Embeds wrapper scripts' {
        $csproj | Should -Match 'tiny11maker\.ps1'
        $csproj | Should -Match 'tiny11maker-from-config\.ps1'
        $csproj | Should -Match 'tiny11-iso-validate\.ps1'
        $csproj | Should -Match 'autounattend\.template\.xml'
    }

    It 'Every src/*.psm1 file is referenced (catches new modules added without csproj update)' {
        $disk = Get-ChildItem "$PSScriptRoot\..\src\*.psm1" | ForEach-Object Name
        foreach ($f in $disk) {
            $csproj | Should -Match ([regex]::Escape($f))
        }
    }
}
```

- [ ] **Step 2: Run the drift test**

```powershell
Invoke-Pester tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1
```

Expected: green.

- [ ] **Step 3: Commit**

```powershell
git add tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1
git commit -m "test: drift coverage for launcher embedded resources"
```

---

## Phase 6 — Build + release pipeline

### Task 30: .gitignore + dist/ output dir

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add launcher build/publish artifacts**

Append to `.gitignore`:

```
# Launcher build artifacts
launcher/bin/
launcher/obj/
launcher/Tests/bin/
launcher/Tests/obj/

# Single-file publish + Velopack output
dist/
```

- [ ] **Step 2: Commit**

```powershell
git add .gitignore
git commit -m "chore: gitignore launcher build artifacts + dist/"
```

---

### Task 31: Single-file publish smoke

**Files:** none (verification task)

- [ ] **Step 1: Publish self-contained single-file**

```powershell
dotnet publish launcher/tiny11options.Launcher.csproj `
    -c Release -r win-x64 `
    -p:PublishSingleFile=true -p:SelfContained=true -p:IncludeAllContentForSelfExtract=true `
    -o dist/raw/
```

Expected: `dist/raw/tiny11options.exe` exists, ~75-90 MB.

- [ ] **Step 2: Run the published binary in GUI mode**

```powershell
dist/raw/tiny11options.exe
```

Expected: window opens, wizard renders, all 3 steps navigate.

- [ ] **Step 3: Run the published binary in headless mode (with bogus ISO to fail-fast)**

```powershell
dist/raw/tiny11options.exe -Source "C:\nonexistent.iso" -Edition "Windows 11 Pro" -OutputIso "C:\out.iso"
```

Expected: pwsh runs, fails on missing ISO, error streams to console, .exe returns non-zero exit code.

- [ ] **Step 4: Document size + smoke result**

Add a brief note to `launcher/README.md`:

```markdown
# tiny11options launcher

Native C# WPF + WebView2 + Velopack-updated launcher for tiny11options.

## Local build

```powershell
dotnet build launcher/tiny11options.Launcher.csproj
dotnet test launcher/Tests/
```

## Local single-file publish

```powershell
dotnet publish launcher/tiny11options.Launcher.csproj `
    -c Release -r win-x64 `
    -p:PublishSingleFile=true -p:SelfContained=true -p:IncludeAllContentForSelfExtract=true `
    -o dist/raw/
```

Output: `dist/raw/tiny11options.exe` (~80 MB self-contained).

Local builds are unsigned. Release builds are signed via Microsoft Trusted Signing in CI.
```

- [ ] **Step 5: Commit**

```powershell
git add launcher/README.md
git commit -m "docs(launcher): build + publish instructions in launcher/README.md"
```

---

### Task 32: GitHub Actions release pipeline

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: release

on:
  push:
    tags:
      - 'v*'

jobs:
  build-sign-release:
    runs-on: windows-latest
    permissions:
      id-token: write   # OIDC federation to Azure for Trusted Signing
      contents: write   # gh release create
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: 10.x

      - name: Restore
        run: dotnet restore launcher/tiny11options.Launcher.csproj

      - name: Test (xUnit)
        run: dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj -c Release --logger "trx"

      - name: Test (Pester)
        shell: pwsh
        run: |
          Install-Module Pester -Scope CurrentUser -Force
          Invoke-Pester tests/ -CI

      - name: Publish (single-file, self-contained)
        run: |
          dotnet publish launcher/tiny11options.Launcher.csproj `
            -c Release -r win-x64 `
            -p:PublishSingleFile=true -p:SelfContained=true -p:IncludeAllContentForSelfExtract=true `
            -o dist/raw/

      - name: Sign with Microsoft Trusted Signing
        uses: azure/trusted-signing-action@v0.5.1
        with:
          azure-tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          azure-client-id: ${{ secrets.AZURE_CLIENT_ID }}
          endpoint: ${{ secrets.TRUSTED_SIGNING_ENDPOINT }}
          trusted-signing-account-name: ${{ secrets.TRUSTED_SIGNING_ACCOUNT }}
          certificate-profile-name: ${{ secrets.TRUSTED_SIGNING_CERT_PROFILE }}
          files-folder: dist/raw
          files-folder-filter: exe,dll
          file-digest: SHA256

      - name: Velopack pack
        shell: pwsh
        run: |
          dotnet tool install -g vpk
          $version = "${{ github.ref_name }}".TrimStart('v')
          $changelog = (Select-String -Path CHANGELOG.md -Pattern "^## \[$version\]" -Context 0,40).Context.PostContext -join "`n"
          vpk pack `
            --packId tiny11options `
            --packVersion $version `
            --packDir dist/raw `
            --mainExe tiny11options.exe `
            --releaseNotes ([System.IO.Path]::GetTempFileName() | ForEach-Object { Set-Content $_ $changelog; $_ }) `
            --output dist/releases

      - name: Sign Velopack artifacts
        uses: azure/trusted-signing-action@v0.5.1
        with:
          azure-tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          azure-client-id: ${{ secrets.AZURE_CLIENT_ID }}
          endpoint: ${{ secrets.TRUSTED_SIGNING_ENDPOINT }}
          trusted-signing-account-name: ${{ secrets.TRUSTED_SIGNING_ACCOUNT }}
          certificate-profile-name: ${{ secrets.TRUSTED_SIGNING_CERT_PROFILE }}
          files-folder: dist/releases
          files-folder-filter: exe,nupkg
          file-digest: SHA256

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        shell: pwsh
        run: |
          $version = "${{ github.ref_name }}".TrimStart('v')
          $notesFile = [System.IO.Path]::GetTempFileName()
          (Select-String -Path CHANGELOG.md -Pattern "^## \[$version\]" -Context 0,40).Context.PostContext | Set-Content $notesFile
          gh release create "${{ github.ref_name }}" `
            dist/releases/*.nupkg dist/releases/Setup.exe dist/releases/RELEASES `
            --notes-file $notesFile --target main
```

- [ ] **Step 2: Commit**

```powershell
git add .github/workflows/release.yml
git commit -m "ci: GitHub Actions release pipeline (sign + Velopack + GH Release)"
```

NOTE: the workflow will fail until the secrets are configured. That setup is a one-time manual step documented in Task 33.

---

### Task 33: Document Trusted Signing one-time setup

**Files:**
- Modify: `launcher/README.md`

- [ ] **Step 1: Append setup section to launcher/README.md**

```markdown
## Trusted Signing — one-time setup

The release workflow signs `tiny11options.exe` and Velopack artifacts via
Microsoft Trusted Signing. To enable it:

1. Create an Azure subscription if you don't have one. The Trusted Signing
   service costs ~$10/mo (~$120/yr).
2. In Azure Portal: create a **Trusted Signing account**.
3. Create a **certificate profile** with publisher name `Jamie Chapman`.
4. Note the endpoint (e.g. `https://eus.codesigning.azure.net`), account
   name, and certificate-profile name.
5. Configure GitHub OIDC federation:
   - Azure Portal → App registrations → New registration
   - Federated credentials → Add → "GitHub Actions deploying Azure resources"
   - Organization: `bilbospocketses`, Repository: `tiny11options`,
     Entity type: "Tag", Pattern: `v*`
6. Grant the App Registration the `Trusted Signing Certificate Profile Signer` role
   on the certificate profile.
7. Add repo secrets at github.com → Settings → Secrets and variables → Actions:
   - `AZURE_TENANT_ID`        — Azure AD tenant GUID
   - `AZURE_CLIENT_ID`        — App Registration client ID
   - `TRUSTED_SIGNING_ENDPOINT`        — full endpoint URL
   - `TRUSTED_SIGNING_ACCOUNT`         — Trusted Signing account name
   - `TRUSTED_SIGNING_CERT_PROFILE`    — certificate profile name

After setup, push a `v*` tag to trigger a release.
```

- [ ] **Step 2: Commit**

```powershell
git add launcher/README.md
git commit -m "docs(launcher): Trusted Signing one-time setup instructions"
```

---

### Task 34: CHANGELOG entry for v1.0.0

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add an Unreleased entry capturing Path C**

Update `CHANGELOG.md` `[Unreleased]` block:

```markdown
## [Unreleased]

### Added
- **Bundled `tiny11options.exe` launcher** (Path C): single self-contained .NET 10
  binary providing both GUI mode (no args → WPF + WebView2 wizard) and headless
  mode (CLI args → spawn `powershell.exe` running `tiny11maker.ps1`).
- **In-app updates** via Velopack with passive notification near the theme toggle
  and one-click apply-and-restart.
- **Code signing** via Microsoft Trusted Signing (publisher: Jamie Chapman). Both
  `tiny11options.exe` and Velopack release artifacts are signed by CI.
- New `tiny11maker-from-config.ps1` wrapper for launcher-driven builds.
- New `tiny11-iso-validate.ps1` wrapper for launcher-driven ISO validation.
- xUnit test project at `launcher/Tests/` for C# components.
- Pester drift test `tests/Tiny11.Launcher.EmbeddedResources.Drift.Tests.ps1`.
- GitHub Actions release pipeline (`.github/workflows/release.yml`).

### Changed
- `tiny11maker.ps1` no longer hosts the interactive wizard. Run
  `tiny11options.exe` for GUI mode, or pass `-Source` for direct headless.

### Removed
- `src/Tiny11.Bridge.psm1` — superseded by C# Bridge in the launcher.
- `src/Tiny11.WebView2.psm1` — superseded by C# WPF + WebView2 host.
- `tests/Tiny11.Bridge.Tests.ps1` and `tests/Tiny11.WebView2.Tests.ps1`.
```

- [ ] **Step 2: Commit**

```powershell
git add CHANGELOG.md
git commit -m "docs(changelog): catalog Path C launcher entries under [Unreleased]"
```

---

## Phase 7 — Manual smoke + release

### Task 35: Manual Smoke 1 — GUI startup + wizard render

- [ ] **Step 1:** Run `dist/raw/tiny11options.exe` from Explorer (no console).
- [ ] **Step 2:** Confirm window opens at 1200×900 (or last persisted size), all 3 wizard steps render and navigate (Next/Back), theme toggle works, settings.json is updated at `%LOCALAPPDATA%\tiny11options\settings.json`.
- [ ] **Step 3:** Close → relaunch → confirm window restores at modified size.
- [ ] **Step 4:** Document any issues; fix or file as TODO.

### Task 36: Manual Smoke 2 — Headless byte-for-byte match

- [ ] **Step 1:** Place a real Win11 Consumer ISO at known path, e.g. `C:/win11.iso`.
- [ ] **Step 2:** Build via launcher headless:

```powershell
dist/raw/tiny11options.exe -Source C:/win11.iso -Edition "Windows 11 Pro" -OutputIso C:/out-launcher.iso -FastBuild
```

- [ ] **Step 3:** Build via direct pwsh script:

```powershell
pwsh tiny11maker.ps1 -Source C:/win11.iso -ImageIndex 6 -OutputIso C:/out-pwsh.iso -FastBuild
```

(Adjust ImageIndex to match the same edition.)

- [ ] **Step 4:** Compare ISOs:

```powershell
Get-FileHash C:/out-launcher.iso, C:/out-pwsh.iso
```

Expected: identical SHA256.

If they differ, do a deep diff (mount both, compare loose files + WIM contents) per the v0.1.0 verification methodology in `docs/superpowers/plans/2026-05-01-interactive-variant-builder.md`.

### Task 37: Manual Smoke 3 — Velopack update flow

- [ ] **Step 1:** Set up a fake "older version" build:
  - Edit csproj `<AssemblyVersion>0.0.1.0</AssemblyVersion>`
  - Build + Velopack-pack as `v0.0.1` to a local NuGet directory
  - Install it via `Setup.exe`
- [ ] **Step 2:** Reset csproj to `<AssemblyVersion>0.0.2.0</AssemblyVersion>`, build + pack as `v0.0.2`, host the RELEASES manifest pointing at both versions.
- [ ] **Step 3:** Launch the installed v0.0.1 → confirm badge appears within ~5s → click → confirm dialog → click Install → confirm app restarts as v0.0.2.

### Task 38: Manual Smoke 4 + 5 — first-run extraction, SmartScreen

- [ ] **Smoke 4:** Boot a fresh Hyper-V Win11 VM with no .NET 10 runtime, copy `tiny11options.exe` over, double-click → confirm first-run extraction takes <2s and wizard appears.
- [ ] **Smoke 5:** Install the signed Setup.exe on the same VM → confirm SmartScreen does NOT show "unrecognized app" (a clean signed binary should pass).

### Task 39: Cut release v1.0.0

- [ ] **Step 1:** All smoke green → finalize CHANGELOG (rename `[Unreleased]` to `[1.0.0] - YYYY-MM-DD`, add new empty `[Unreleased]` block).
- [ ] **Step 2:** Merge `feat/path-c-launcher` to `main` via `git merge --no-ff` (matches the v0.1.0 / v0.2.0 release pattern).
- [ ] **Step 3:** Tag and push:

```powershell
git tag -a v1.0.0 -m "v1.0.0: bundled .exe launcher (Path C)"
git push origin main v1.0.0
```

- [ ] **Step 4:** GitHub Actions runs the release workflow. Verify it produces a signed `Setup.exe` + `.nupkg` + `RELEASES` on the GitHub Release page.

---

## Self-review

**Spec coverage:**
- D1 (Velopack updates) → Tasks 23-26
- D2 (Trusted Signing) → Tasks 32-33
- D3 (project layout) → Tasks 1-7
- D4 (native C# WPF) → Tasks 8-22
- Architecture (subprocess pwsh) → Tasks 7, 19, 20, 21
- Project structure → Tasks 1, 2, 6, 30, 32
- Data flow (headless + GUI) → Tasks 7, 8, 14-22
- Error handling → embedded in each handler task; cross-cutting in Tasks 7, 8, 24
- Testing (xUnit + Pester drift) → Tasks 4, 5, 6, 7, 9, 10, 14, 16, 17, 18, 20, 21, 22, 24, 29
- Release pipeline → Tasks 31-34
- Out of scope → respected (no cross-platform, no E2E ISO test harness)

**Placeholder scan:** clean. Two notes that look like placeholders but aren't:
- Velopack `Version="…"` in csproj (Task 23) — instruction says "pin to specific version at implementation time", which is a deliberate gate, not a placeholder.
- Task 28 step 1 says "Adjust the exact location based on the existing structure of tiny11maker.ps1" — this is unavoidable because the surrounding control flow may evolve before this plan is executed; the engineer greps for `Show-Tiny11Wizard` to find the precise edit point.

**Type consistency:** the bridge message types (`update-available`, `update-applying`, `update-error`, `apply-update`, `validate-iso`, `iso-validated`, `iso-error`, `start-build`, `cancel-build`, `build-started`, `build-progress`, `build-complete`, `build-error`, `browse-file`, `browse-folder`, `browse-save-file`, `browse-result`, `save-profile`, `load-profile`, `profile-saved`, `profile-loaded`, `reconcile-selections`, `selections-reconciled`, `get-theme`, `apply-theme`, `theme-applied`, `handler-error`) are used consistently across handler implementations and JS. C# class names (`Bridge`, `IBridgeHandler`, `BridgeMessage`, `IFilePicker`, `WpfFilePicker`, `BrowseHandlers`, `ProfileHandlers`, `SelectionHandlers`, `ThemeHandlers`, `IsoHandlers`, `BuildHandlers`, `UpdateHandlers`, `UpdateNotifier`, `IUpdateSource`, `UpdateInfo`, `VelopackUpdateSource`, `PwshRunner`, `PwshResult`, `EmbeddedResources`, `HeadlessRunner`, `ConsoleAttach`, `UserSettings`, `ThemeManager`, `Catalog`, `CatalogItem`) match across tasks where they cross-reference.

**Scope:** ~39 tasks covering ~45 hours of implementation. Single coherent plan; no decomposition needed.
