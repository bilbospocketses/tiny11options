#Requires -Version 5.1
# Regenerates tests/golden/tiny11-cleanup-helpers.txt from the current
# $script:helpersBlock in src/Tiny11.PostBoot.psm1. Run after any change to
# the helpers here-string. .gitattributes will LF-normalize the file on commit.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
$helpers = & (Get-Module Tiny11.PostBoot) { $script:helpersBlock }
$out = Join-Path $PSScriptRoot 'tiny11-cleanup-helpers.txt'
[System.IO.File]::WriteAllText($out, $helpers)
Write-Host "Regen wrote $($helpers.Length) chars to $out"
