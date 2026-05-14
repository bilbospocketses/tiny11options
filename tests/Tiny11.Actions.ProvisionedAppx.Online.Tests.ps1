Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.ProvisionedAppx.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11ProvisionedAppxOnlineCommand' {
    It 'emits Remove-AppxByPackagePrefix with packagePrefix' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='Clipchamp.Clipchamp' }
        $cmds = @(Get-Tiny11ProvisionedAppxOnlineCommand -Action $action)
        $cmds.Count          | Should -Be 1
        $cmds[0].Kind        | Should -Be 'Remove-AppxByPackagePrefix'
        $cmds[0].Args.Prefix | Should -Be 'Clipchamp.Clipchamp'
    }

    It 'description references prefix' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='Microsoft.OutlookForWindows' }
        $cmds = @(Get-Tiny11ProvisionedAppxOnlineCommand -Action $action)
        $cmds[0].Description | Should -Match 'Microsoft.OutlookForWindows'
    }

    It 'works for prefixes with dots in vendor namespace' {
        $action = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='Microsoft.BingNews' }
        $cmds = @(Get-Tiny11ProvisionedAppxOnlineCommand -Action $action)
        $cmds[0].Args.Prefix | Should -Be 'Microsoft.BingNews'
    }
    It 'throws on empty packagePrefix (A5 W4 regression guard)' {
        # Pre-fix: would emit `Remove-AppxByPackagePrefix -Prefix ''` which the
        # runtime helper expands to `Get-AppxPackage -Name "*"` - matches and
        # removes EVERY appx package. Treat empty prefix as catalog corruption.
        $emptyAction = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='' }
        { Get-Tiny11ProvisionedAppxOnlineCommand -Action $emptyAction } | Should -Throw -ExpectedMessage "*non-empty 'packagePrefix'*"
    }
    It 'throws on whitespace-only packagePrefix (A5 W4 regression guard)' {
        $wsAction = [pscustomobject]@{ type='provisioned-appx'; packagePrefix='   ' }
        { Get-Tiny11ProvisionedAppxOnlineCommand -Action $wsAction } | Should -Throw -ExpectedMessage "*non-empty 'packagePrefix'*"
    }
}
