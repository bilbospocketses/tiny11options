# Audit: CI / release pipeline (v1.0.8 cycle)

**Date:** 2026-05-15
**Scope:** `.github/workflows/*.yml` + `.github/FUNDING.yml` + `global.json` + `tests/Run-Tests.ps1` + `tests/Tiny11.PesterConfig.ps1` + cross-refs into `launcher/tiny11options.Launcher.csproj` `<Version>` and the README "Running tests" / "System requirements" / "Two modes" claims.
**Branch:** main at `285f7b6` (post-v1.0.7)
**Auditor:** parallel subagent (no session context)

---

## Summary

- BLOCKER: 0
- WARNING: 4
- INFO: 8

Workflow inventory:

| File | Purpose | Notes |
|------|---------|-------|
| `.github/workflows/release.yml` | tag-push release pipeline | Sole workflow; full audit below |
| `.github/FUNDING.yml` | sponsorship buttons | Upstream's ntdevlabs/ntdev2 links — see I8 |

There is **no** PR/CI workflow (no `ci.yml`, no `pr.yml`), **no** dependabot or renovate config, and **no** repo-root scripts under `tools/` or `scripts/`. Test execution runs only at release time.

---

## B1 — Workflow's Pester step does NOT call `tests/Run-Tests.ps1`; inlines its own config and silently bypasses the explicit `5.3.1`/`5.99.99` Pester pin

**Severity:** WARNING
**File:** `.github/workflows/release.yml:72-80`

**What.** The "Test (Pester)" step is:

```yaml
- name: Test (Pester)
  shell: pwsh
  run: |
    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
    $config = New-PesterConfiguration
    $config.Run.Path = 'tests/'
    $config.Run.Exit = $true
    $config.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $config
```

This invocation never sources `tests/Run-Tests.ps1`. `Run-Tests.ps1:1` carries the explicit pin written for the v1.0.2 A6 W4 fix:

```powershell
#Requires -Module @{ ModuleName='Pester'; ModuleVersion='5.3.1'; MaximumVersion='5.99.99' }
```

The CHANGELOG entry `[1.0.2]` documents the floor of `5.3.1` + ceiling of `5.99.99` as a binding design decision (Pester 6.x not validated; pre-5.3 BeforeAll behavior breaks fixtures). The CI step's `Install-Module Pester ... -Force` with **no** `-RequiredVersion` and **no** `-MaximumVersion` will pull whatever PSGallery currently publishes as `latest`. PSGallery today serves 5.7.1, but the moment Pester 6.0 ships stable (currently 6.0.0-alpha5 dated 2024-10-30), the CI runner will start pulling 6.x and the suite will silently regress against an unvalidated runtime. The local-dev `pwsh -File tests/Run-Tests.ps1` path will reject the 6.x install (via `MaximumVersion`); CI will not, creating a green-locally / red-in-CI (or worse, red-locally / unknown-in-CI) divergence.

**Why.** The pin exists for a reason — the v1.0.1 cycle hit Pester-5.x BeforeAll behavior changes; the v1.0.2 cycle landed the floor + ceiling as the fix. CI silently bypassing that pin defeats the whole point of having a `Run-Tests.ps1` wrapper. It also means the inlined config drifts from `tests/Tiny11.PesterConfig.ps1` (the local-dev source of truth) — the CI config doesn't set `TestResult.Enabled = $false` or `CodeCoverage.Enabled = $false`, both of which are Pester 5.x defaults today but could change.

**Fix.** Replace the inlined config with `pwsh -NoProfile -File tests/Run-Tests.ps1`. That single command honors the `#Requires` pin, sources `Tiny11.PesterConfig.ps1`, and ensures CI and local dev run the same Pester invocation. The `Install-Module` call should either disappear (rely on the runner's preinstalled Pester 5.7.1) or be replaced with `Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck` so the version is explicit. Track as a v1.0.8-cycle candidate alongside the Trusted Signing wire-up.

---

## B2 — Job-level `env:` block exposes ALL 5 Trusted Signing secrets to every step in the job (broader-than-needed secret scope)

**Severity:** WARNING
**File:** `.github/workflows/release.yml:38-47`

**What.** The job declares:

```yaml
env:
  AZURE_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
  AZURE_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
  TRUSTED_SIGNING_ENDPOINT: ${{ secrets.TRUSTED_SIGNING_ENDPOINT }}
  TRUSTED_SIGNING_ACCOUNT: ${{ secrets.TRUSTED_SIGNING_ACCOUNT }}
  TRUSTED_SIGNING_CERT_PROFILE: ${{ secrets.TRUSTED_SIGNING_CERT_PROFILE }}
```

The header comment justifies this: "Surface signing secrets at job-level so step-level `if:` guards can check env.AZURE_TENANT_ID." That justification is **only valid for `AZURE_TENANT_ID`** — that's the single secret the `if:` guards read (lines 95 + 147). The other four secrets do NOT need to be in job-level env scope; they are passed to the action via `with:` inputs (lines 98-102 + 150-154) which already use `${{ env.* }}` or could equally use `${{ secrets.* }}` directly.

By exposing all 5 secrets to job env, any step in the job — including future `run:` blocks added by maintainers, third-party actions added later, or workflow re-pollutions — has visibility into the secret values. GitHub's secret masking is best-effort: it replaces verbatim secret values in logs, but doesn't catch transformations (base64-encoded, partially redacted, URL-encoded). The smaller the blast radius, the less chance of a future leak.

**Why.** v1.0.8 cycle plan is to wire in the secrets — i.e., this exact set of env values will start carrying real, non-empty values for the first time. The right moment to narrow the scope is BEFORE the secrets become real, not after.

**Fix.** Keep only `AZURE_TENANT_ID` at job level (the only one the `if:` checks). Move the other 4 to step-level `env:` blocks under each of the two `Sign ... via Trusted Signing` steps, or pass them via `${{ secrets.* }}` directly in the `with:` block. Pattern:

```yaml
env:
  AZURE_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}  # gate only

# ... later, inside step:
- name: Sign tiny11options.exe via Trusted Signing
  if: env.AZURE_TENANT_ID != ''
  uses: azure/trusted-signing-action@v0.5.1
  with:
    azure-tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    azure-client-id: ${{ secrets.AZURE_CLIENT_ID }}
    endpoint: ${{ secrets.TRUSTED_SIGNING_ENDPOINT }}
    ...
```

This pre-empts a v1.0.8 cycle finding by an outside security reviewer the moment the action goes live with real secrets.

---

## B3 — `azure/trusted-signing-action@v0.5.1` is significantly stale; action was renamed + GA-ed as `azure/artifact-signing-action@v1.0.0`+ (currently at v2.0.0)

**Severity:** WARNING
**File:** `.github/workflows/release.yml:96` and `:148`

**What.** Two steps reference `uses: azure/trusted-signing-action@v0.5.1`. Per the Azure action's public release history:

- v0.5.1 was released 2024-01-07 — pre-GA pre-release.
- v1.0.0 (released later, GA) **rebranded the action from `azure/trusted-signing-action` to `azure/artifact-signing-action`**. The release notes for v1.0.0 explicitly say "Rebranding action from Trusted Signing into Artifact Signing. This will be our initial version for GA."
- v2.0.0 is the current latest (2026-05-14).

The old repo name `azure/trusted-signing-action` still resolves on GitHub due to GitHub's automatic repo-rename redirects, and `@v0.5.1` is still pullable. But the workflow is pinned to a pre-GA tag from January 2024 — over two years stale by the time v1.0.8 ships. Likely missing: SHA-256 file digest fixes, retry-on-throttle changes, OIDC flow updates, MSI signing support added later, and any post-2024 Azure SDK upgrades.

The v1.0.8 cycle is the moment to land the un-pinning + rename — wiring secrets to a stale action is exactly the kind of "we'll fix that later" footgun that bites three releases from now.

**Why.** The v1.0.8 cycle's whole purpose is wiring up signing. Doing so against a 2024-vintage pre-GA action pin is silently betting that nothing has changed in the action's authentication contract for two years. Trusted Signing's federated identity / OIDC flow has been actively iterated on by Azure in that window. Stale pin = stale flow = surprise auth failures the first time the secrets fire for real.

**Fix.** Bump to `azure/artifact-signing-action@v2.0.0` (or the latest `v2`/`v1` major you trust at audit time). Verify the input names are still `azure-tenant-id`, `azure-client-id`, `endpoint`, `trusted-signing-account-name`, `certificate-profile-name`, `files-folder`, `files-folder-filter`, `file-digest` — these may have been renamed in the rebrand. Test the green-path locally or in a draft branch via a manual `workflow_dispatch` trigger BEFORE relying on it for a tag push.

Also worth verifying: the rebranded action may have changed the `cert-profile-name` parameter name (since the rebrand explicitly moves away from "Trusted Signing" terminology). If the rename includes parameter renames, the v0.5.1 → v2.0.0 jump has to be done in lockstep with the secrets wire-up, NOT after.

---

## B4 — Single `dotnet restore` step targets only the launcher project, not the Tests project; coupled with cross-file path-case drift to the actual on-disk filename

**Severity:** WARNING
**File:** `.github/workflows/release.yml:66-70`, `:82-87`

**What.** Two related issues in the build-prep block:

```yaml
- name: Restore
  run: dotnet restore launcher/Tiny11Options.Launcher.csproj

- name: Test (xUnit)
  run: dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj -c Release --logger "trx"
```

**(a) Path-case drift.** The workflow references `launcher/Tiny11Options.Launcher.csproj` (capital `T`, `O`). The actual file on disk is `launcher/tiny11options.Launcher.csproj` (all lowercase) — confirmed via `tiny11options.sln:8` and `launcher/README.md:14`. Windows NTFS is case-insensitive so this resolves fine on the `windows-2025-vs2026` runner today. But:

- Git's `core.ignorecase` default on Windows means a future rename (e.g., someone renames the file to canonical casing) would not surface as a diff. Whoever did this in `release.yml` may have inferred the casing rather than reading the file.
- The same workflow references the test project with the correct lowercase casing (`launcher/Tests/tiny11options.Launcher.Tests.csproj`, line 70). The inconsistency *within the same workflow* is the bigger signal — half-correct.

**(b) Redundant + asymmetric restore.** The `Restore` step restores ONLY the launcher project. The `Test (xUnit)` step then implicitly restores the Tests project (default `dotnet test` behavior, no `--no-restore`). The Publish step at line 82 also re-restores. Net effect: NuGet packages are restored 3 times instead of once, adding 30-60s to the cold path. With no `actions/cache@v4` for NuGet packages either, every release re-pulls everything from nuget.org.

**Why.** The v1.0.7 cycle already paid attention to runner/Action freshness; the next-easiest perf+correctness win is restore caching + a single explicit restore covering the whole solution. The path-case mismatch should be fixed as a pure-doc nit at the same time so future reviewers don't have to wonder which casing is canonical.

**Fix.** Replace the targeted restore with a solution-level restore:

```yaml
- name: Restore
  run: dotnet restore tiny11options.sln

- name: Test (xUnit)
  run: dotnet test launcher/Tests/tiny11options.Launcher.Tests.csproj -c Release --no-restore --logger "trx"

- name: Publish (single-file, self-contained)
  run: |
    dotnet publish launcher/tiny11options.Launcher.csproj `
      -c Release -r win-x64 --no-restore `
      -p:PublishSingleFile=true ...
```

Add `actions/cache@v4` for `~/.nuget/packages` keyed on the lockfile. Use the actual lowercase filename consistently.

---

## I1 — TRX test logs not uploaded as workflow artifacts; failure forensics requires log-scraping or local re-run

**Severity:** INFO
**File:** `.github/workflows/release.yml:70`

`dotnet test ... --logger "trx"` writes TRX files to `launcher/Tests/TestResults/<name>.trx`. The workflow does NOT have an `actions/upload-artifact@v4` step capturing them. On test failure, all you have is the streamed `--logger "trx"` summary in the live GH Actions log; the structured TRX (with per-test stack traces, output, timings) is gone the moment the runner is reaped.

Same story for Pester: no `OutputFormat` or `OutputFile` is configured, no test-result `.xml` written, no upload step.

**Fix direction (non-blocking):** add an `if: always()` upload step:

```yaml
- name: Upload test results
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: test-results
    path: |
      launcher/Tests/TestResults/*.trx
      tests/TestResults/*.xml  # if Pester output is added
    retention-days: 14
```

Defer to v1.0.9 or later if v1.0.8 stays narrowly scoped on signing.

---

## I2 — No `concurrency:` block; two simultaneous tag pushes would race

**Severity:** INFO
**File:** `.github/workflows/release.yml` (workflow-level concurrency block absent)

Tag pushes are rare (1 per release cut) so the practical risk is near-zero. But two `v*` tags pushed within the same minute (e.g., a typo-correction force re-tag, or v1.0.x + v1.0.y from a hotfix) would run two release jobs in parallel, both calling `gh release create` on overlapping artifacts and possibly leaving one half-published.

**Fix direction (non-blocking):** add a top-level concurrency guard:

```yaml
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
```

`cancel-in-progress: false` is important — you don't want to cancel an in-flight signing operation midway through. The group key tied to `github.ref` (the tag) means re-pushing the same tag waits its turn.

---

## I3 — `--target main` on `gh release create` is a no-op when the tag already exists (which it always does in tag-push trigger flow)

**Severity:** INFO
**File:** `.github/workflows/release.yml:178`

```yaml
gh release create "${{ github.ref_name }}" `
  ...
  --target main
```

Per `gh release create` docs: `--target` is only honored when `gh` has to **create** the tag (because it doesn't yet exist). The workflow is triggered by `push: tags: 'v*'` — the tag exists before the job starts. `--target main` is ignored. Harmless cosmetic, but misleading to a future reviewer who might assume the release is being targeted at the `main` branch (it isn't; it's targeted at the tag's commit, which may or may not be on `main`).

**Fix (cosmetic only):** drop `--target main`, or replace with a comment explaining it's a no-op kept defensively.

---

## I4 — VPK_VERSION pin to 0.0.1298 has no companion bump cadence or check; same version locked across v1.0.0→v1.0.7

**Severity:** INFO
**File:** `.github/workflows/release.yml:24`, cross-ref `launcher/tiny11options.Launcher.csproj:122` (`<PackageReference Include="Velopack" Version="0.0.1298" />`)

The workflow's `env.VPK_VERSION: 0.0.1298` and the launcher's `<PackageReference Include="Velopack" Version="0.0.1298" />` both pin to the same Velopack version. Good — these are correctly coupled (a vpk CLI version mismatch against the runtime baked into the exe would surface as subtle delta-update bugs).

But: there is no automated check that they stay coupled, and no scheduled audit prompt to consider a bump. Velopack 0.0.1298 was the right pin for v1.0.4's `releases.win.json` fix. Subsequent Velopack releases may have shipped (a) more `GithubSource` robustness, (b) MSI signing improvements (relevant to the v1.0.8 cycle goal), (c) post-2025 bug fixes. The longer this stays pinned, the larger the v1.0.x → v1.x.y jump becomes.

**Fix direction (non-blocking):** add a one-line TODO marker in the CHANGELOG `[Unreleased]` or in `todo_tiny11options.md` to bump Velopack on a documented cadence (e.g., every 3 releases, or whenever an upstream bug fix becomes relevant). Alternatively, add a Pester or PowerShell drift test that asserts `$env:VPK_VERSION` from the workflow equals the `<PackageReference Version="...">` value in the csproj.

---

## I5 — `Install-Module Pester -Force -SkipPublisherCheck` runs on every CI invocation; ~10-30s wasted reinstalling the same version

**Severity:** INFO
**File:** `.github/workflows/release.yml:75`

The Windows runner image ships with Pester preinstalled. `-Force` re-installs it from PSGallery anyway. Without an explicit `-RequiredVersion`, the install always re-resolves the latest version metadata against PSGallery, downloads, and stages — even when the preinstalled version matches.

Couple with B1 (no version pin): once the floor pin is added, an `if`-guard around the install (`if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge '5.3.1')) { Install-Module ... }`) saves the install round-trip on every run.

**Fix (defer):** part of the same edit as B1.

---

## I6 — No `actions/cache@v4` for NuGet packages or PowerShell modules

**Severity:** INFO
**File:** `.github/workflows/release.yml` (cache step absent)

Each release run cold-restores all NuGet packages (xunit, Moq, Velopack, coverlet.collector, Microsoft.NET.Test.Sdk, etc. — see `launcher/Tests/tiny11options.Launcher.Tests.csproj:11-16`). Typical NuGet cache for this project is ~50-100MB; restore time ~30-60s on a cold runner.

A package cache would shave the restore step by ~80%:

```yaml
- name: Cache NuGet packages
  uses: actions/cache@v4
  with:
    path: ~/.nuget/packages
    key: ${{ runner.os }}-nuget-${{ hashFiles('**/*.csproj', 'global.json') }}
    restore-keys: ${{ runner.os }}-nuget-
```

**Fix:** non-urgent. Releases are infrequent; saving 30s twice a release is low-value compared to the cycle-time-sensitive smoke validation. Defer until release cadence picks up.

---

## I7 — README "Running tests" Pester+xUnit counts (485 / 105) are stale vs. v1.0.7 actuals (496 / 113); CHANGELOG `[1.0.7]` test-counts line is authoritative

**Severity:** INFO
**File:** `README.md:285` vs. `CHANGELOG.md:27-28`

This is technically in the docs-consistency agent's scope, but it surfaces as a cross-reference verification in this audit per the brief.

- `README.md:285` says "485 Pester tests ... and 105 xUnit launcher tests" — that's the v1.0.3 number.
- `CHANGELOG.md:27-28` for `[1.0.7]` says "Pester: 485 / 0 -> **496 / 0** (+11 noise-suppression)" and "xUnit: 105 / 0 -> **113 / 0** (+8 AppVersionTests)".

The workflow doesn't gate on this number, so it's not a CI defect; flagging as a docs cross-ref for the v1.0.8 docs-consistency pass.

**Fix:** docs-consistency agent owns. CI-side, no action.

---

## I8 — `.github/FUNDING.yml` carries upstream ntdevlabs sponsorship links (not the fork's), which is the maintainer's documented choice but is worth a re-check before the fork accumulates a separate audience

**Severity:** INFO
**File:** `.github/FUNDING.yml`

```yaml
github: [ntdevlabs]
patreon: [ntdev]
ko-fi: [ntdev]
custom: ['https://paypal.me/ntdev2']
```

All four channels point at NTDEV (the upstream tiny11builder maintainer), not at the tiny11options fork's maintainer. Per the README "License / credits" + "Contribution / fork boundary" sections, this is consistent with the fork's posture: it acknowledges upstream and routes any donation impulse to NTDEV. If the fork's audience grows or the fork takes on long-running maintenance work specific to the catalog/launcher/GUI, this allocation may merit revisiting.

**Fix:** none — calling out for posterity. CHANGELOG and README upstream-acknowledgement copy (v1.0.3 Documentation entry) is consistent with the current FUNDING.yml routing.

---

## Cross-reference verification

| Claim / cross-ref | Source | CI verification | Status |
|---|---|---|---|
| Tag `v*` push triggers `release.yml` | brief | line 18-21 `on: push: tags: v*` | OK |
| `windows-2025-vs2026` runner pin | brief + CHANGELOG `[1.0.7]:23` | line 34 `runs-on: windows-2025-vs2026` + runner image verified available | OK |
| `checkout@v6`, `setup-dotnet@v5` (Node 24) | CHANGELOG `[1.0.7]:22` | line 54 `actions/checkout@v6`, line 56 `actions/setup-dotnet@v5` — both verified Node 24 | OK |
| `global.json` SDK pin + `rollForward: latestPatch` | brief | `global.json` has `"version": "10.0.203"` + `"rollForward": "latestPatch"` — covers .NET 10 patch slip but caps at the SDK band; `launcher/tiny11options.Launcher.csproj:14` `<TargetFramework>net10.0-windows</TargetFramework>` matches | OK |
| Conditional sign exe (`if: env.AZURE_TENANT_ID != ''`) | brief | line 95 + line 147; syntax verified — `env.X != ''` in step-level `if:` is the documented form. Empty-string secret evaluates false correctly. | OK (but see B2/B3) |
| Asset glob includes `releases.*.json` (v1.0.4 fix) | brief + CHANGELOG `[1.0.4]:50` | line 176 `dist/releases/releases.*.json` present | OK |
| `gh release create "${{ github.ref_name }}"` extracts version from tag for the GH Release object | brief | line 175; tag is the release name | OK |
| csproj `<Version>` matches tag for Velopack delta-update | brief + audit-A2 W2 from v1.0.1 cycle | `launcher/tiny11options.Launcher.csproj:12` `<Version>1.0.7</Version>` matches the latest tag (v1.0.7). The v1.0.8 cycle MUST bump this to `1.0.8` before tagging. | OK for v1.0.7; v1.0.8 cycle requires manual bump |
| Release-notes regex fails closed on missing CHANGELOG section | brief | line 121-124 `Write-Error ... exit 1` — confirmed fails closed | OK |
| `VPK_VERSION: 0.0.1298` matches launcher's `<PackageReference Include="Velopack" Version="..." />` | implicit consistency requirement | env line 24 `0.0.1298` == csproj line 122 `0.0.1298` | OK (but see I4 on cadence) |
| `tests/Run-Tests.ps1` is what CI runs | brief implication | CI inlines its own config; Run-Tests.ps1 is local-dev-only — see B1 | DRIFT |
| Workflow references launcher csproj path | brief | line 67 + 84 use `Tiny11Options.Launcher.csproj` (capital T,O); on-disk is `tiny11options.Launcher.csproj` (lowercase) — see B4(a) | DRIFT (case) |

---

## Out-of-scope spillover noticed during audit

These items belong to other agents but were observed in passing and flagged here for cross-reference visibility:

- **launcher.md scope (csproj `<Version>` bump for v1.0.8):** `launcher/tiny11options.Launcher.csproj:12` currently `1.0.7`. The v1.0.8 cycle binding decision is to bump this AND `launcher/app.manifest` `<assemblyIdentity version="1.0.7.0">` (not read in this audit; brief notes only csproj) in lockstep. Listed in the v1.0.1 audit A2 W2 as a BLOCKER pattern (Velopack update chain breaks silently if `<Version>` drifts from tag). Not actionable here; flagging for the launcher agent.
- **docs-consistency.md scope (test counts):** README:285 cites the v1.0.3 counts (485/105). CHANGELOG `[1.0.7]` cites 496/113. Docs-consistency agent owns.
- **ps-modules.md scope (Run-Tests.ps1 / TestHelpers `-Global`):** The v1.0.1 audit A6 W1 documented the TestHelpers `-Global` pattern vs. standalone `-Force` divergence. Run-Tests.ps1 itself does not load modules, so it's clean from this audit's POV — but if v1.0.8 is going to revisit the test-isolation question, the CI-side cleanup (B1) should land in the same commit.

---

## What the workflow gets right

In the interest of fairness:

- Tag-triggered release with explicit `v*` glob — correctly narrow, won't fire on random tags.
- `permissions:` block is least-privilege: `id-token: write` for OIDC + `contents: write` for GH release creation. No `actions: write` or `packages: write` granted.
- Release-notes extraction fails closed (`exit 1` on missing CHANGELOG section, line 121-124). The v1.0.7 cycle's no-emojis-in-PS-scripts hook is not relevant here because CHANGELOG.md is markdown (not a PS script); Unicode prose / em-dashes / smart-quotes pass through the regex correctly because PowerShell `[regex]::Match` against `Get-Content -Raw` preserves bytes.
- v1.0.4's `releases.*.json` glob addition is the correct breadth — covers `releases.win.json` + future channel variants without needing per-channel changes.
- Runner pin chosen explicitly + change documented in CHANGELOG (`[1.0.7]:23` cites the 2026-06-15 silent-redirect window as the trigger).
- Single source of truth for .NET SDK via `global-json-file: global.json` — no `dotnet-version:` inline override.

The workflow is **reasonably robust for v1.0.7's narrow scope**. The four warnings are all about preparing for the v1.0.8 cycle's signing wire-up, where stale pins and broad secret scope move from theoretical to load-bearing.
