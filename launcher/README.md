# tiny11options launcher

Native C# WPF + WebView2 + Velopack-updated launcher for tiny11options.
Produces a single self-contained `.exe` that hosts both:

- **GUI mode** (no args) -- WPF + WebView2 wizard with 3-step flow (Source, Customize, Build)
- **Headless mode** (CLI args) -- spawns `powershell.exe` running `tiny11maker.ps1` against the provided source / edition / output paths

Target framework: `net10.0-windows` (LTS through Nov 2028). Vendored WebView2 SDK at `dependencies/webview2/1.0.2535.41/`. WPF enabled, WinForms disabled. Per-monitor V2 DPI awareness.

## Local build

```powershell
dotnet build launcher/Tiny11Options.Launcher.csproj
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj
```

The xUnit test project lives at `launcher/Tests/`. Pester tests for the PowerShell side are under `tests/` at the repo root.

## Local single-file publish

```powershell
dotnet publish launcher/Tiny11Options.Launcher.csproj `
    -c Release -r win-x64 `
    -p:PublishSingleFile=true -p:SelfContained=true -p:IncludeAllContentForSelfExtract=true `
    -o dist/raw/
```

Output: `dist/raw/tiny11options.exe` (~135 MB self-contained -- includes .NET runtime, WPF, WebView2 SDK, and all embedded PS scripts + UI resources).

First-launch behavior: the binary extracts embedded resources to `%LOCALAPPDATA%\tiny11options\resources-cache\<version>\` and `%LOCALAPPDATA%\tiny11options\ui-cache\<version>\`. Subsequent launches reuse the cache.

Local builds are **unsigned**. Release builds are signed via Microsoft Trusted Signing in CI (see Trusted Signing section below).

## Headless mode quick reference

```powershell
dist/raw/tiny11options.exe `
    -Source "D:\Win11_25H2.iso" `
    -Edition "Windows 11 Pro" `
    -OutputIso "C:\out\tiny11.iso" `
    -ScratchDir "C:\Temp\scratch"
```

All arguments pass through to `tiny11maker.ps1` -- run it directly for the full parameter list and defaults. Headless mode attaches to the parent console so pwsh output streams inline; if launching from a non-console parent (e.g. a script that captures output programmatically), output routing depends on how `Process.Start` is configured.

## Trusted Signing -- one-time setup

The release workflow signs `tiny11options.exe` and Velopack artifacts via
Microsoft Trusted Signing. To enable it:

1. Create an Azure subscription if you don't have one. The Trusted Signing
   service costs ~$10/mo (~$120/yr).
2. In Azure Portal: create a **Trusted Signing account**.
3. Create a **certificate profile** with publisher name `Jamie Chapman`.
4. Note the endpoint (e.g. `https://eus.codesigning.azure.net`), account
   name, and certificate-profile name.
5. Configure GitHub OIDC federation:
   - Azure Portal -> App registrations -> New registration
   - Federated credentials -> Add -> "GitHub Actions deploying Azure resources"
   - Organization: `bilbospocketses`, Repository: `tiny11options`,
     Entity type: "Tag", Pattern: `v*`
6. Grant the App Registration the `Trusted Signing Certificate Profile Signer` role
   on the certificate profile.
7. Add repo secrets at github.com -> Settings -> Secrets and variables -> Actions:
   - `AZURE_TENANT_ID`             -- Azure AD tenant GUID
   - `AZURE_CLIENT_ID`             -- App Registration client ID
   - `TRUSTED_SIGNING_ENDPOINT`    -- full endpoint URL
   - `TRUSTED_SIGNING_ACCOUNT`     -- Trusted Signing account name
   - `TRUSTED_SIGNING_CERT_PROFILE` -- certificate profile name

After setup, push a `v*` tag to trigger a release.

## Release pipeline

CI workflow lives at `.github/workflows/release.yml`. Triggers on `v*` tag push.
Steps:

1. Checkout + setup-dotnet 10.x
2. Restore + xUnit test + Pester test
3. `dotnet publish` self-contained single-file -> `dist/raw/`
4. Sign `.exe` + `.dll` via `azure/trusted-signing-action@v0.5.1`
5. `vpk pack` (pinned to vpk 0.0.1298) -> `dist/releases/`
6. Sign Velopack artifacts (`.exe` + `.nupkg`) again
7. `gh release create` with release notes pulled from `CHANGELOG.md` matching the tag version

## Update channel

The launcher's `VelopackUpdateSource` polls GitHub releases at
`https://github.com/bilbospocketses/tiny11options` (configured in
`launcher/MainWindow.xaml.cs`). The update notifier fires on app launch and surfaces
a passive update badge near the theme toggle when a newer stable release is
available. Prereleases are filtered out (`GithubSource(..., prerelease: false)`).
