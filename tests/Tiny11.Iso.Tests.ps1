Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Iso'

Describe "Resolve-Tiny11Source" {
    It "treats single-letter input as drive letter"  { (Resolve-Tiny11Source -InputPath 'E').Kind | Should -Be 'DriveLetter' }
    It "treats E: as drive letter"                    { (Resolve-Tiny11Source -InputPath 'E:').DriveLetter | Should -Be 'E' }
    It "treats E:\\ as drive letter"                  { (Resolve-Tiny11Source -InputPath 'E:\').Kind | Should -Be 'DriveLetter' }
    It "treats path ending in .iso as iso file"       {
        $r = Resolve-Tiny11Source -InputPath 'C:\foo.iso'
        $r.Kind | Should -Be 'IsoFile'; $r.IsoPath | Should -Be 'C:\foo.iso'
    }
    It "throws on unrecognized input"                 { { Resolve-Tiny11Source -InputPath 'C:\not-an-iso.txt' } | Should -Throw }
}

Describe "Mount-Tiny11Source / Get-Tiny11Editions" {
    BeforeEach {
        Mock -CommandName 'Mount-DiskImage' -MockWith { [pscustomobject]@{ ImagePath = $ImagePath; Attached = $true } } -ModuleName 'Tiny11.Iso'
        Mock -CommandName 'Get-Tiny11VolumeForImage' -MockWith { [pscustomobject]@{ DriveLetter = 'F' } } -ModuleName 'Tiny11.Iso'
        Mock -CommandName 'Get-DiskImage'   -MockWith { [pscustomobject]@{ Attached = $false } } -ModuleName 'Tiny11.Iso'
        Mock -CommandName 'Get-WindowsImage' -MockWith {
            @(
                [pscustomobject]@{ ImageIndex=1; ImageName='Windows 11 Home'; Architecture='x64'; Languages=@('en-US') }
                [pscustomobject]@{ ImageIndex=6; ImageName='Windows 11 Pro';  Architecture='x64'; Languages=@('en-US') }
            )
        } -ModuleName 'Tiny11.Iso'
    }
    It "mounts an ISO file and returns drive letter + mountedByUs=true" {
        $r = Mount-Tiny11Source -InputPath 'C:\Win11.iso'
        $r.DriveLetter | Should -Be 'F'; $r.MountedByUs | Should -BeTrue
    }
    It "skips mount when input is a drive letter; mountedByUs=false" {
        $r = Mount-Tiny11Source -InputPath 'E:'
        $r.DriveLetter | Should -Be 'E'; $r.MountedByUs | Should -BeFalse
    }
    It "enumerates editions from install.wim" {
        Mock -CommandName 'Test-Path' -MockWith { $true } -ModuleName 'Tiny11.Iso'
        $editions = Get-Tiny11Editions -DriveLetter 'F'
        $editions.Count | Should -Be 2
        $editions[1].ImageIndex | Should -Be 6; $editions[1].ImageName | Should -Be 'Windows 11 Pro'
    }
}
