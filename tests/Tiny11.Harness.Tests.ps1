Describe "Test harness" {
    It "loads helpers without error" {
        Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
        Get-Command New-TempScratchDir | Should -Not -BeNullOrEmpty
    }
}
