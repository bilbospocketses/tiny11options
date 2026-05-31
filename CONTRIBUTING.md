# Contributing to tiny11options

Thanks for your interest. This document covers the essentials for getting a development environment running, the code-style bar, and how to land changes.

This project is a standalone fork; we do not contribute back to the upstream `ntdevlabs/tiny11builder` repo.

## Prerequisites

- **PowerShell 5.1** (Windows built-in) — the legacy `tiny11maker.ps1` + `tiny11Coremaker.ps1` runtimes target Windows PowerShell, not PowerShell 7+
- **.NET 10 SDK** (pinned via `global.json`) — install the matching SDK from [dotnet.microsoft.com](https://dotnet.microsoft.com/download)
- **WebView2 Runtime** — bundled with modern Windows 11 / Edge; install from Microsoft if missing for older hosts
- **Pester 5.3.1 – 5.99.99** — pinned in `tests/Run-Tests.ps1`. Install via `Install-Module -Name Pester -RequiredVersion 5.x.x`
- A Windows 10/11 host (the app builds and runs Windows-only; ISO modification requires `dism.exe` + `oscdimg.exe` + `reg.exe`)

## Setup

```bash
git clone https://github.com/bilbospocketses/tiny11options.git
cd tiny11options
dotnet restore tiny11options.sln
dotnet build tiny11options.sln -c Release
```

For local development, the launcher runs the WebView2 UI plus the PowerShell modules; launch it via `dotnet run --project launcher/tiny11options.Launcher.csproj`.

The legacy PowerShell path (no UI) still works for direct CLI use:

```powershell
pwsh -NoProfile -File tiny11maker.ps1
```

**Prerequisite for the legacy PS path:** the WPF wizard imports `Tiny11.WebView2.psm1`, which loads Microsoft.Web.WebView2 DLLs from the NuGet global packages folder (`%USERPROFILE%\.nuget\packages\microsoft.web.webview2\<version>\`). Run `dotnet restore launcher/tiny11options.Launcher.csproj` once before invoking `tiny11maker.ps1` to populate the cache. The .NET launcher (`tiny11options.exe`) bundles these DLLs into the published single-file binary, so production users never need this restore step — it only applies when running the legacy PS path from a source checkout.

## Development Workflow

```bash
dotnet build tiny11options.sln -c Release           # incremental build
dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj -c Release  # xUnit (C# launcher tests)
pwsh -NoProfile -File tests/Run-Tests.ps1            # Pester (PowerShell module tests)
```

The Pester runner enforces the `#Requires Pester 5.3.1`/`5.99.99` pin so the suite cannot silently regress against a Pester 6.x prerelease.

## Project Structure

```
tiny11options/
├── tiny11maker.ps1                  Legacy CLI entrypoint (full ISO build)
├── tiny11Coremaker.ps1              Legacy CLI entrypoint (Core variant)
├── tiny11maker-from-config.ps1      Headless / config-driven build
├── tiny11Coremaker-from-config.ps1  Headless / config-driven Core build
├── tiny11-iso-validate.ps1          ISO sanity check
├── tiny11-profile-validate.ps1      Profile JSON schema check
├── tiny11-cancel-cleanup.ps1        Scratch cleanup on cancellation
├── autounattend.template.xml        Bundled autounattend template (embedded in the exe; no runtime fetch as of v1.0.28)
├── catalog/                         Removal lists, registry tweaks, capability deprovisioning data
├── config/                          Default JSON profiles consumed by the GUI + headless flows
├── dependencies/                    Vendored helpers
├── src/                             PowerShell modules (Tiny11.*.psm1)
├── ui/                              WebView2 UI assets (index.html, app.js, style.css)
├── launcher/                        .NET 10 WebView2 host
│   ├── tiny11options.Launcher.csproj
│   └── Tests/                       xUnit test project
├── tests/                           Pester tests + Run-Tests.ps1 runner
└── docs/                            Specs, plans, smoke evidence
```

## Code Style

- **PowerShell:** verb-noun cmdlet naming; `Set-StrictMode -Version Latest` at module top; `$ErrorActionPreference = 'Stop'`; no aliases in scripts (`Get-ChildItem`, not `gci`)
- **C# 13 / .NET 10:** nullable reference types enabled; file-scoped namespaces; primary constructors welcome; `dotnet format` clean before commit
- **No PowerShell string interpolation into native commands** — use parameter binding / argument arrays; `Invoke-RegCommand` (in `src/Tiny11.Hives.psm1`) wraps `reg.exe` safely
- **Offline registry hives: `reg.exe` only — never the .NET registry provider.** Read/write loaded offline hives via `reg.exe` (`Invoke-RegCommand` / `Get-Tiny11RegValueNames` / `Test-Tiny11HiveLoaded`), never `Get-Item`/`Set-ItemProperty`/`Test-Path` on `HKLM:\z*`. The provider caches an in-process hive handle that survives `reg unload` and locks `Dismount-WindowsImage -Save` ("being used by another process"). Enforced by `tests/Tiny11.OfflineHive.NoProvider.Drift.Tests.ps1`. Build-process `reg.exe`/`dism.exe`/`robocopy.exe` resolve from the absolute `%SystemRoot%\System32` path (`Get-Tiny11RegExePath` / `Get-Tiny11DismExePath`), not `%PATH%`.
- **Logging:** use the launcher's bridge-routed logger; do not `Write-Host` in PS modules (breaks the UI bridge); use `Write-BridgeLog -Level Info/Warning/Error`
- **No AI-generated attribution lines** in commit messages

## Tests

- **xUnit (`launcher/Tests/tiny11options.Launcher.Tests.csproj`)** — launcher bridge, manifest extraction, path validation, autounattend XML generation
- **Pester (`tests/`)** — PowerShell module behavior, catalog application, registry tweaks, profile validation

Any PR that changes catalog application, registry editing, bridge contracts, or the build pipeline MUST include or update a test.

## Specs and Plans

Larger features go through a spec → plan → implementation cycle:

- **Specs:** `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- **Plans:** `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`
- **Smoke evidence:** `docs/superpowers/smoke/YYYY-MM-DD-<topic>.md`

Existing specs and plans in `docs/superpowers/` are useful reading before proposing architectural changes. They are frozen snapshots — do not retroactively edit them.

## Commit Messages

Follow conventional-commit-style prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `style:`, `chore:`, `build:`, `test:`, `ci:`.

Keep the subject line short and imperative. Wrap the body at 72 columns. Reference issue numbers when applicable.

Do not include AI-generated attribution lines in commit messages.

## Pull Requests

- Keep PRs focused on one concern. Big refactors are easier to review as a series of small commits than one sprawling patch.
- Update `CHANGELOG.md` under `[Unreleased]` for any user-visible change.
- Update `README.md` when behavior the user sees changes.
- Update `docs/superpowers/smoke/` if the PR landed via a manual smoke matrix.

## Branch Strategy

`main` is the development branch. PR-gated as of v1.0.23: all changes go branch → PR → `build-and-test` green → squash-merge.

## Reporting Bugs

Open an issue on GitHub with:

- Expected vs actual behavior
- Windows version (10/11, build number)
- .NET runtime version (`dotnet --info`)
- Relevant excerpt from the launcher / build logs
- ISO source description (Windows 11 Pro/Home/Enterprise, build, language) if the bug is build-related

## Reporting Security Issues

Do **not** file a public issue. See `SECURITY.md` for the private reporting flow.
