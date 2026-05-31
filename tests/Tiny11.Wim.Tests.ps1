Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Wim'

Describe 'Assert-Tiny11WimIntegrity' {
    It 'passes -ImagePath and -Index to Get-WindowsImage and does not throw on success' {
        Mock -CommandName Get-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { [pscustomobject]@{ ImageIndex = 2 } }
        { Assert-Tiny11WimIntegrity -ImagePath 'X:\install.wim' -Index 2 } | Should -Not -Throw
        Should -Invoke -CommandName Get-WindowsImage -ModuleName 'Tiny11.Wim' -Times 1 `
            -ParameterFilter { $Index -eq 2 -and $ImagePath -eq 'X:\install.wim' }
    }

    It 'throws an actionable error when Get-WindowsImage fails' {
        Mock -CommandName Get-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { throw 'cannot read WIM resource table' }
        { Assert-Tiny11WimIntegrity -ImagePath 'X:\install.wim' -Index 1 } |
            Should -Throw -ExpectedMessage '*failed its post-save integrity check*'
    }
}
