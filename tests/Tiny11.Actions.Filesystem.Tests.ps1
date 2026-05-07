Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions.Filesystem'

Describe "Invoke-FilesystemAction" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }

    It "removes a single file (op=remove)" {
        $f = Join-Path $script:tmp 'subdir\file.txt'
        New-Item -ItemType File -Path $f -Force | Out-Null
        Invoke-FilesystemAction -Action @{ type='filesystem'; op='remove'; path='subdir\file.txt'; recurse=$false } -ScratchDir $script:tmp
        Test-Path $f | Should -BeFalse
    }
    It "removes a directory recursively" {
        $d = Join-Path $script:tmp 'recdir'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'a.txt') -Force | Out-Null
        Invoke-FilesystemAction -Action @{ type='filesystem'; op='remove'; path='recdir'; recurse=$true } -ScratchDir $script:tmp
        Test-Path $d | Should -BeFalse
    }
    It "is idempotent on missing path" {
        { Invoke-FilesystemAction -Action @{ type='filesystem'; op='remove'; path='ghost\nope.txt'; recurse=$false } -ScratchDir $script:tmp } | Should -Not -Throw
    }
    It "calls takeown+icacls before remove for op=takeown-and-remove" {
        Mock -CommandName 'Invoke-Takeown' -MockWith { } -ModuleName 'Tiny11.Actions.Filesystem'
        Mock -CommandName 'Invoke-Icacls'  -MockWith { } -ModuleName 'Tiny11.Actions.Filesystem'
        $f = Join-Path $script:tmp 'protected'
        New-Item -ItemType Directory -Path $f -Force | Out-Null
        Invoke-FilesystemAction -Action @{ type='filesystem'; op='takeown-and-remove'; path='protected'; recurse=$true } -ScratchDir $script:tmp
        Should -Invoke -CommandName 'Invoke-Takeown' -ModuleName 'Tiny11.Actions.Filesystem' -Times 1
        Should -Invoke -CommandName 'Invoke-Icacls'  -ModuleName 'Tiny11.Actions.Filesystem' -Times 1
        Test-Path $f | Should -BeFalse
    }
}
