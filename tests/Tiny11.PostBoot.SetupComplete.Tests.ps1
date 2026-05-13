Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
}

Describe 'New-Tiny11PostBootSetupCompleteScript' {
    BeforeAll { $script:cmd = New-Tiny11PostBootSetupCompleteScript }

    It 'is non-empty'                                  { $script:cmd | Should -Not -BeNullOrEmpty }
    It 'logs to tiny11-cleanup-setup.log'              { $script:cmd | Should -Match 'tiny11-cleanup-setup\.log' }
    It 'registers Post-Boot Cleanup task via schtasks' {
        $script:cmd | Should -Match 'schtasks /create /xml'
        $script:cmd | Should -Match '/tn "tiny11options\\Post-Boot Cleanup"'
    }
    It 'runs tiny11-cleanup.ps1 once immediately' {
        $script:cmd | Should -Match 'powershell\.exe.*tiny11-cleanup\.ps1'
    }
    It 'self-deletes via del /F /Q "%~f0"' {
        $script:cmd | Should -Match 'del /F /Q "%~f0"'
    }
    It 'is pure ASCII' {
        ($script:cmd.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
}
