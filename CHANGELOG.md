# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `.gitattributes` enforcing LF line endings repo-wide, with CRLF preserved for `.ps1`/`.bat`/`.cmd` and explicit binary patterns including `.iso`/`.wim`/`.esd`/`.exe`.
- `CHANGELOG.md` (this file) following Keep a Changelog format.

### Changed
- `tiny11maker.ps1`: autounattend.xml fallback fetch URL now points at our fork (`bilbospocketses/tiny11options`) instead of upstream `ntdevlabs/tiny11builder`. Ensures any future edits to our `autounattend.xml` reach users who copied only the `.ps1` to a working directory.

### Notes
- Fork of [`ntdevlabs/tiny11builder`](https://github.com/ntdevlabs/tiny11builder). Standalone — no upstream contributions planned.
- Active work focuses on `tiny11maker.ps1`. `tiny11Coremaker.ps1` is out of scope for the current effort.
