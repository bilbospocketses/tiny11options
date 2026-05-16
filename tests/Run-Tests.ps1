#Requires -Module @{ ModuleName='Pester'; ModuleVersion='5.3.1'; MaximumVersion='5.99.99' }
# Tested against Pester 5.7.1. Floor 5.3.1 sidesteps BeforeAll variable-
# visibility behavior changes that landed earlier in 5.x; ceiling 5.99.99
# caps below Pester 6.x which is not yet validated against this suite.
$config = & "$PSScriptRoot/Tiny11.PesterConfig.ps1"
$result = Invoke-Pester -Configuration $config
# v1.0.10: [System.Environment]::Exit() instead of `exit`. Long-standing pwsh
# quirk: when this script is invoked via `pwsh -NoProfile -File Run-Tests.ps1`
# (the form CI uses, see .github/workflows/release.yml), the script-level
# `exit 1` does NOT propagate to the host process's exit code -- pwsh returns
# 0 regardless of FailedCount, and GitHub Actions reports the step as success
# on red runs. v1.0.9 release workflow run 25956315625 shipped with 14 Pester
# failures hidden behind exactly this silent-fail. [System.Environment]::Exit
# terminates the process directly with the given code and propagates through
# both -File and -Command invocations. Confirmed locally before this change.
if ($result.FailedCount -gt 0) { [System.Environment]::Exit(1) }
[System.Environment]::Exit(0)
