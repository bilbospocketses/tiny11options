#Requires -Version 7.0
<#
.SYNOPSIS
Runs the Pester suite under the PINNED Pester version, in a fresh pwsh.

.DESCRIPTION
This script is the single owner of the repo's Pester version: $PesterVersion below
(the line tagged PESTER_PIN). CI reads the pin from that line and installs exactly that
version before calling this script, so local runs and CI are the same engine by
construction. Bump the version here and nowhere else.

It re-launches itself in a fresh `pwsh -NoProfile -NonInteractive` before importing
Pester, because several Pester versions can coexist on a dev box and an already-loaded
one wins silently over -RequiredVersion (the module refuses to load twice). Fresh
process = the pin always holds. -NonInteractive is load-bearing: a mocked command with an
incomplete parameter set prompts for the missing mandatory value during binding, which
blocks forever in an interactive host but fails immediately here.

Exit code: 0 when every test passed and at least one ran, 1 otherwise, set with
[System.Environment]::Exit. v1.0.10: a script-level `exit` does NOT propagate through
`pwsh -NoProfile -File` (the form CI uses); v1.0.9 shipped with 14 hidden Pester failures
because of exactly that. Environment.Exit terminates the process with the given code
through both -File and -Command invocations.

Until 2026-09-03 the pin was a `#Requires -Module` line (5.3.1 <= Pester < 6). It moved to
a parameter so CI can read it and so `-PesterVersion` can trial a newer engine.

.EXAMPLE
pwsh -NoProfile -File tests/Run-Tests.ps1                    # whole suite
pwsh -NoProfile -File tests/Run-Tests.ps1 -ExcludeTag Online # skip the Online-tagged tests
pwsh -NoProfile -File tests/Run-Tests.ps1 -PesterVersion 6.2.0
#>
[CmdletBinding()]
param(
    # THE pin. CI parses this exact line by its PESTER_PIN tag; keep the single-quoted literal form.
    [string]$PesterVersion = '6.1.0',   # PESTER_PIN
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    # Internal: set when this script has re-launched itself in the fresh process.
    [switch]$Inner
)

if (-not $Inner) {
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $childArgs = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Inner', '-PesterVersion', $PesterVersion)
    if ($Tag)        { $childArgs += @('-Tag', ($Tag -join ',')) }
    if ($ExcludeTag) { $childArgs += @('-ExcludeTag', ($ExcludeTag -join ',')) }
    & $pwsh @childArgs
    [System.Environment]::Exit($LASTEXITCODE)
}

# ---- inner (fresh process) ----------------------------------------------------------
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion $PesterVersion
$loaded = (Get-Module Pester).Version.ToString()
if ($loaded -ne $PesterVersion) { throw "Pester $loaded is loaded, but this repo pins $PesterVersion." }

$config = & "$PSScriptRoot/Tiny11.PesterConfig.ps1"
# -Tag/-ExcludeTag arrive as one comma-joined string through -File; split them back.
if ($Tag)        { $config.Filter.Tag        = @(($Tag -join ',') -split ',') }
if ($ExcludeTag) { $config.Filter.ExcludeTag = @(($ExcludeTag -join ',') -split ',') }

$result = Invoke-Pester -Configuration $config
# $result is $null when Pester bails before running anything (e.g. no *.Tests.ps1 found): it
# writes the error itself instead of throwing, so that case must be an explicit failure.
if ($null -eq $result) {
    Write-Output "Pester ${loaded}: no result object - nothing ran."
    [System.Environment]::Exit(1)
}
Write-Output ("Pester {0}: {1} passed, {2} failed, {3} skipped, {4} total" -f $loaded, $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.TotalCount)
# PassedCount, not TotalCount: with a filter that matches nothing Pester still reports every
# discovered test in TotalCount and calls the run 'Passed', so a typo'd -Tag would exit 0.
$code = if ($result.Result -ne 'Passed' -or $result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { 1 } else { 0 }
[System.Environment]::Exit($code)
