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
    It "throws on empty packagePrefix (A5 W4 regression guard)" {
        # Pre-fix: `-like '**'` matches every package, would Invoke-DismRemoveAppx
        # for the entire provisioned-appx set. Treat empty prefix as corruption.
        { Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='' } -ScratchDir 'C:\s' } | Should -Throw -ExpectedMessage "*non-empty 'packagePrefix'*"
        Should -Invoke -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 0
    }
    It "throws on whitespace-only packagePrefix (A5 W4 regression guard)" {
        { Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='   ' } -ScratchDir 'C:\s' } | Should -Throw -ExpectedMessage "*non-empty 'packagePrefix'*"
        Should -Invoke -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 0
    }
}

Describe "Provisioned-appx package cache" {
    BeforeEach {
        Clear-Tiny11AppxPackageCache
        Mock -CommandName 'Get-ProvisionedAppxPackagesFromImage' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -MockWith {
            @('Clipchamp.Clipchamp_x', 'Microsoft.BingNews_x', 'Microsoft.WindowsTerminal_x')
        }
        Mock -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -MockWith { }
    }
    It "enumerates packages only once across multiple actions on the same scratchdir" {
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='Clipchamp.Clipchamp' } -ScratchDir 'C:\s'
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='Microsoft.BingNews' } -ScratchDir 'C:\s'
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='Microsoft.WindowsTerminal' } -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Get-ProvisionedAppxPackagesFromImage' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 1
        Should -Invoke -CommandName 'Invoke-DismRemoveAppx' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 3
    }
    It "re-enumerates after the cache is cleared" {
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='Clipchamp.Clipchamp' } -ScratchDir 'C:\s'
        Clear-Tiny11AppxPackageCache
        Invoke-ProvisionedAppxAction -Action @{ type='provisioned-appx'; packagePrefix='Microsoft.BingNews' } -ScratchDir 'C:\s'
        Should -Invoke -CommandName 'Get-ProvisionedAppxPackagesFromImage' -ModuleName 'Tiny11.Actions.ProvisionedAppx' -Times 2
    }
}
