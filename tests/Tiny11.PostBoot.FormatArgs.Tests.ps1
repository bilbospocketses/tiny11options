Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
}

Describe 'Format-PSNamedParams' {
    It 'string value gets single-quoted' {
        Format-PSNamedParams -Arguments([ordered]@{ Path = 'C:\Windows' }) | Should -Be "-Path 'C:\Windows'"
    }
    It "string with single quote escapes via doubling" {
        Format-PSNamedParams -Arguments([ordered]@{ Name = "it's" }) | Should -Be "-Name 'it''s'"
    }
    It 'int value unquoted' {
        Format-PSNamedParams -Arguments([ordered]@{ Value = 0 }) | Should -Be '-Value 0'
    }
    It 'long value unquoted' {
        Format-PSNamedParams -Arguments([ordered]@{ Value = [long]4294967296 }) | Should -Be '-Value 4294967296'
    }
    It 'bool true renders as $true literal' {
        Format-PSNamedParams -Arguments([ordered]@{ Recurse = $true }) | Should -Be '-Recurse $true'
    }
    It 'bool false renders as $false literal' {
        Format-PSNamedParams -Arguments([ordered]@{ Recurse = $false }) | Should -Be '-Recurse $false'
    }
    It 'multiple args preserve insertion order' {
        $a = [ordered]@{ A = 1; B = 'x'; C = $true }
        Format-PSNamedParams -Arguments $a | Should -Be "-A 1 -B 'x' -C `$true"
    }
    It 'byte array renders as [byte[]] literal' {
        Format-PSNamedParams -Arguments([ordered]@{ Value = ([byte[]](0x01,0xAB,0xFF)) }) | Should -Be '-Value ([byte[]](0x01,0xAB,0xFF))'
    }
    It 'string array renders as @() literal' {
        Format-PSNamedParams -Arguments([ordered]@{ Value = @('a','b') }) | Should -Be "-Value @('a','b')"
    }
}
