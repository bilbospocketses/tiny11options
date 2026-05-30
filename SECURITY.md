# Security Policy

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Report security issues privately through GitHub's built-in security advisory flow:

**[Report a vulnerability](https://github.com/bilbospocketses/tiny11options/security/advisories/new)**

This opens a private channel between you and the maintainer — no public disclosure until a fix is ready.

## What to Include

When reporting, please provide:

- A clear description of the vulnerability and its impact
- Steps to reproduce (proof-of-concept code, ISO source description, or environment conditions)
- The affected version / commit
- Any mitigations you're aware of

## Response Expectations

- **Acknowledgement:** within **72 hours** of receipt
- **Triage and initial assessment:** within one week
- **Fix and disclosure timeline:** discussed with the reporter on a per-issue basis, depending on severity and complexity

## Supported Versions

Security fixes target the latest commit on `main`. Older commits and tagged releases are not maintained — upgrade to the latest release to receive fixes.

## Scope

**In scope:**

- The PowerShell ISO builder (`tiny11maker.ps1`, `tiny11Coremaker.ps1`, and the `-from-config.ps1` variants)
- The .NET / WebView2 launcher (`launcher/tiny11options.Launcher`) and its bridge code
- The Velopack-managed auto-update flow (manifest fetch, signature verification, install/restart)
- The autounattend.xml template (bundled + embedded as of v1.0.28 — the runtime fetch from our fork was retired) and the runtime fetch of `oscdimg.exe` from Microsoft's symbol server
- Catalog application logic (registry hive editing, Appx removal, capability deprovisioning)

**Out of scope:**

- Vulnerabilities in upstream tools that have not been released against tiny11options — report those to their respective projects:
  - Microsoft `oscdimg.exe`, `dism.exe`, `reg.exe`, `wmic.exe`
  - Microsoft.Web.WebView2 runtime
  - Velopack auto-updater library
- Issues requiring physical or local-admin access to a host already running the app (the app is itself an ISO-modification tool; admin is the entry condition)
- Self-XSS or similar issues requiring the reporter to paste attacker-controlled code into the WebView2 devtools
- Vulnerabilities introduced by user-supplied custom autounattend.xml or custom catalog overrides

Thanks for helping keep the project safe.
