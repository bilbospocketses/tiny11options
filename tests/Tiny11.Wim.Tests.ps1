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

Describe 'Invoke-Tiny11WimDismountSave' {
    It 'succeeds on the first attempt and calls Dismount-WindowsImage once' {
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\scratch' -DelaySeconds 0 } | Should -Not -Throw
        Should -Invoke -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -Times 1 `
            -ParameterFilter { $Save -eq $true -and $Path -eq 'C:\scratch' }
    }

    It 'retries after a transient failure and then succeeds' {
        $script:n = 0
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith {
            $script:n++
            if ($script:n -lt 2) { throw 'the process cannot access the file because it is being used by another process' }
        }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\scratch' -Attempts 3 -DelaySeconds 0 } | Should -Not -Throw
        Should -Invoke -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -Times 2
    }

    It 'gives up after N attempts and throws with the path and attempt count' {
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { throw 'sharing violation' }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\scratch' -Attempts 3 -DelaySeconds 0 } |
            Should -Throw -ExpectedMessage "*failed for 'C:\scratch' after 3 attempt(s)*"
        Should -Invoke -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -Times 3
    }

    It 'does not sleep when DelaySeconds is 0' {
        Mock -CommandName Dismount-WindowsImage -ModuleName 'Tiny11.Wim' -MockWith { throw 'x' }
        Mock -CommandName Start-Sleep -ModuleName 'Tiny11.Wim' -MockWith { }
        { Invoke-Tiny11WimDismountSave -MountPath 'C:\s' -Attempts 2 -DelaySeconds 0 } | Should -Throw
        Should -Invoke -CommandName Start-Sleep -ModuleName 'Tiny11.Wim' -Times 0
    }
}
