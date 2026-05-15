# 2026-05-15 v1.0.8-cycle thorough audit

Outside-perspective audit performed via parallel subagents (no session context,
fresh-eyes review). Findings-only — no code changes — to be triaged into v1.0.8
fixes after the dispatch completes.

## Baseline state

- Branch: `main` at commit `285f7b6` (after v1.0.7 release tag on `251d8d0` plus
  two docs-only follow-ups: `ee754a0` (Scripted section three-example rewrite)
  and `285f7b6` (Scripted section consolidated to one shell-agnostic example)).
- Latest release: **v1.0.7** (2026-05-15) — bundled UI version-display + Finding 4
  stderr suppression + Node.js 24 (`actions/checkout@v6` + `actions/setup-dotnet@v5`)
  + `windows-2025-vs2026` runner pin. First annotation-free release since v1.0.2.
- Tests: **Pester 496/0**, **xUnit 113/0**.
- Active backlog before audit: v1.0.8 cycle = Microsoft Trusted Signing only
  (5 GitHub Action secrets). This audit may surface new v1.0.8 candidates.

## Scopes (one parallel agent per row)

| # | Scope | Findings file |
|---|---|---|
| 1 | C# launcher — `launcher/**/*.cs` + csproj + app.manifest + xUnit tests | `launcher.md` |
| 2 | PowerShell modules — `src/Tiny11.*.psm1` (Core, Worker, Actions.*, PostBoot, Hives, Iso, Selections, Autounattend, Catalog) | `ps-modules.md` |
| 3 | Top-level scripts — `tiny11maker.ps1` + `*-from-config.ps1` + `*-validate.ps1` + `tiny11-cancel-cleanup.ps1` | `scripts.md` |
| 4 | UI — `ui/index.html` + `ui/style.css` + `ui/app.js` | `ui.md` |
| 5 | CI / release pipeline — `.github/workflows/release.yml` + `global.json` + `tests/Run-Tests.ps1` | `ci.md` |
| 6 | Docs-vs-code consistency — `README.md` + `CHANGELOG.md` + script `.PARAMETER` blocks + `docs/superpowers/specs/*.md` + smoke-doc claims vs current code | `docs-consistency.md` |

## Finding vocabulary (matches v1.0.1 audit precedent in `docs/superpowers/audits/2026-05-13-v1.0.1-audit-*.md`)

- `A`-prefix — **Added/Architectural**: enhancements the existing code is missing (better error messages, defensive checks, structural improvements, factoring opportunities, naming/comment improvements).
- `B`-prefix — **Broken/Bug**: logic errors, race conditions, resource leaks, missing-null-checks, error paths that swallow signal, contract violations, security issues (command injection, etc.).
- `I`-prefix — **Informational**: things to know but not necessarily fix (dead-code candidates, performance edge cases, things to revisit if conditions change).
- `D`-prefix (docs-consistency scope only) — **Docs drift**: docs say X but code says Y.
- `O`-prefix (docs-consistency scope only) — **Omission**: code has a behavior docs don't mention.
- `S`-prefix (docs-consistency scope only) — **Stale**: docs reference outdated state (old version numbers, removed flags, etc.).
- `W`-suffix — **Warning sub-item** under a root finding (e.g. `B1-W1`, `B1-W2`).

## Severity buckets

- **BLOCKER**: would prevent v1.0.8 from being shippable as-is (security flaw, deterministic data loss path, broken contract end-users rely on, runtime crash).
- **WARNING**: should fix in v1.0.8 if cheap (~1-2 commits); defer to v1.0.9 otherwise.
- **INFO**: posterity / future cycles / decided-not-to-fix patterns.

## Aggregate triage

*(Filled in after all 6 findings docs land — severity-sorted top-N list of items to fix in v1.0.8 vs defer.)*
