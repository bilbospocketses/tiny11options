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

The release workflow signs `tiny11options.exe` and Velopack artifacts via Microsoft Trusted Signing (rebranded by Microsoft in 2025 as **Artifact Signing**; same service, different blade name in Azure Portal).

**For the verbose, click-by-click walkthrough**, see [`docs/release-signing-setup.md`](../docs/release-signing-setup.md). That document covers: collecting your existing Artifact Signing values, creating the App Registration with OIDC federation, assigning the signing role, adding the 5 GitHub repo secrets, and running a smoke-test tag to validate the wiring before pushing v1.0.0.

**Quick reference for what gets configured:**

| Where | What |
|---|---|
| Azure Portal -> Microsoft Entra ID -> App registrations | Create app `tiny11options-github-signer` |
| App registration -> Certificates & secrets -> Federated credentials | Add credential for repo `bilbospocketses/tiny11options`, entity type **Tag**, pattern `v*` |
| Artifact Signing -> Certificate profile -> Access control (IAM) | Assign role **Artifact Signing Certificate Profile Signer** to the App Registration |
| github.com -> Settings -> Secrets and variables -> Actions | Add 5 secrets (table below) |

**The 5 repo secrets:**

| Secret | Source |
|---|---|
| `AZURE_TENANT_ID` | App Registration Overview -> Directory (tenant) ID |
| `AZURE_CLIENT_ID` | App Registration Overview -> Application (client) ID |
| `TRUSTED_SIGNING_ENDPOINT` | Artifact Signing Account Overview -> Endpoint URI (e.g. `https://eus.codesigning.azure.net`) |
| `TRUSTED_SIGNING_ACCOUNT` | Artifact Signing Account name |
| `TRUSTED_SIGNING_CERT_PROFILE` | Certificate Profile name within that account |

After setup, push a `v*` tag to trigger a release. **Strongly recommended:** smoke-test with a throwaway tag like `v0.99.0-smoketest` first per `docs/release-signing-setup.md` Part 5 -- gives you a chance to catch any secret mistypes without affecting v1.0.0.

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
