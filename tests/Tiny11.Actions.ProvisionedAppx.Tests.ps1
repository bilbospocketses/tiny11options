Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions.ProvisionedAppx'

Describe "Invoke-ProvisionedAppxAction" {
    BeforeEach {
        Mock -CommandName 'Get-ProvisionedAppxPackagesFromImage' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -MockWith {
            @(
                'Clipchamp.Clipchamp_3.1.13190.0_neutral_~_yxz26nhyzhsrt',
                'Microsoft.BingNews_4.55.1.0_x64__8wekyb3d8bbwe',
                'Microsoft.WindowsTerminal_1.18.3181.0_x64__8wekyb3d8bbwe'
            )
        }
        Mock -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -MockWith { }
    }
    It "removes all packages whose name contains the prefix" {
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='Microsoft.BingNews' } -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 1 -ParameterFilter {
            $PackageName -like 'Microsoft.BingNews_*'
        }
    }
    It "is idempotent on no matches" {
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='NotPresent.Anywhere' } -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 0
    }
}
