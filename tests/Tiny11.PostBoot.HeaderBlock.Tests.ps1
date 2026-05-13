Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    $script:header = & (Get-Module Tiny11.PostBoot) { $script:headerBlock }
}

Describe 'PostBoot header block' {
    It 'is non-empty' { $script:header | Should -Not -BeNullOrEmpty }
    It 'sets ErrorActionPreference to Continue' { $script:header | Should -Match "ErrorActionPreference\s*=\s*'Continue'" }
    It 'defines log paths under SystemDrive\Windows\Logs' {
        $script:header | Should -Match 'tiny11-cleanup\.log'
        $script:header | Should -Match 'tiny11-cleanup\.log\.1'
    }
    It 'rotates when active log >= 5000 lines' {
        $script:header | Should -Match '5000'
        $script:header | Should -Match 'Move-Item.*logPath.*logPathBackup'
    }
    It 'defines Write-CleanupLog with yyyy-MM-dd HH:mm:ss timestamp' {
        $script:header | Should -Match 'function Write-CleanupLog'
        $script:header | Should -Match "yyyy-MM-dd HH:mm:ss"
    }
    It 'logs an opening "==== tiny11-cleanup triggered ====" banner' {
        $script:header | Should -Match '==== tiny11-cleanup triggered ===='
    }
    It 'is pure ASCII (no smart quotes / em-dashes)' {
        ($script:header.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
}
