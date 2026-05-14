Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    # Format-PSNamedParams is intentionally NOT exported (A7 W6 hygiene). Reach
    # it via Function: provider scoped inside the module via & $module {...}.
    $script:Fmt = & (Get-Module Tiny11.PostBoot) { Get-Item Function:\Format-PSNamedParams }
}

Describe 'Format-PSNamedParams' {
    It 'string value gets single-quoted' {
        & $script:Fmt -Arguments([ordered]@{ Path = 'C:\Windows' }) | Should -Be "-Path 'C:\Windows'"
    }
    It "string with single quote escapes via doubling" {
        & $script:Fmt -Arguments([ordered]@{ Name = "it's" }) | Should -Be "-Name 'it''s'"
    }
    It 'int value unquoted' {
        & $script:Fmt -Arguments([ordered]@{ Value = 0 }) | Should -Be '-Value 0'
    }
    It 'long value unquoted' {
        & $script:Fmt -Arguments([ordered]@{ Value = [long]4294967296 }) | Should -Be '-Value 4294967296'
    }
    It 'bool true renders as $true literal' {
        & $script:Fmt -Arguments([ordered]@{ Recurse = $true }) | Should -Be '-Recurse $true'
    }
    It 'bool false renders as $false literal' {
        & $script:Fmt -Arguments([ordered]@{ Recurse = $false }) | Should -Be '-Recurse $false'
    }
    It 'multiple args preserve insertion order' {
        $a = [ordered]@{ A = 1; B = 'x'; C = $true }
        & $script:Fmt -Arguments $a | Should -Be "-A 1 -B 'x' -C `$true"
    }
    It 'byte array renders as [byte[]] literal' {
        & $script:Fmt -Arguments([ordered]@{ Value = ([byte[]](0x01,0xAB,0xFF)) }) | Should -Be '-Value ([byte[]](0x01,0xAB,0xFF))'
    }
    It 'string array renders as @() literal' {
        & $script:Fmt -Arguments([ordered]@{ Value = @('a','b') }) | Should -Be "-Value @('a','b')"
    }
    It 'string containing $env: renders DOUBLE-quoted so PS expands at runtime' {
        # Regression guard for B1: single-quoted '$env:SystemDrive\...' is a literal
        # path PS cannot resolve. Must be double-quoted so the env-var expands.
        $r = & $script:Fmt -Arguments([ordered]@{ Path = '$env:SystemDrive\Program Files\Foo' })
        $r | Should -Be '-Path "$env:SystemDrive\Program Files\Foo"'
    }
    It 'string containing $env: at non-start position still renders double-quoted' {
        $r = & $script:Fmt -Arguments([ordered]@{ Path = 'prefix-$env:SystemRoot-suffix' })
        $r | Should -Be '-Path "prefix-$env:SystemRoot-suffix"'
    }
    It 'plain string without $env: stays single-quoted' {
        # Lock in the original behavior for non-expandable strings.
        & $script:Fmt -Arguments([ordered]@{ Path = 'HKLM:\Software\Foo' }) | Should -Be "-Path 'HKLM:\Software\Foo'"
    }
    It 'is NOT in the module exported function list (A7 W6 regression guard)' {
        # The function is an internal rendering helper. If it leaks back into
        # the export list, callers might rely on its current shape and the
        # internal-only contract is lost.
        (Get-Module Tiny11.PostBoot).ExportedFunctions.Keys | Should -Not -Contain 'Format-PSNamedParams'
    }
}
