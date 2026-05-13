Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.Filesystem.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11FilesystemOnlineCommand' {
    It 'op=remove recurse=true emits Remove-PathIfPresent with SystemDrive prefix and Recurse=true' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='Program Files (x86)\Microsoft\Edge'; recurse=$true }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds.Count            | Should -Be 1
        $cmds[0].Kind          | Should -Be 'Remove-PathIfPresent'
        $cmds[0].Args.Path     | Should -Be '$env:SystemDrive\Program Files (x86)\Microsoft\Edge'
        $cmds[0].Args.Recurse  | Should -Be $true
    }

    It 'op=remove recurse=false emits Recurse=false' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='Windows\X.exe'; recurse=$false }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Args.Recurse | Should -Be $false
    }

    It 'op=takeown-and-remove emits Remove-PathWithOwnership' {
        $action = [pscustomobject]@{ type='filesystem'; op='takeown-and-remove'; path='Windows\System32\OneDriveSetup.exe'; recurse=$false }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Kind         | Should -Be 'Remove-PathWithOwnership'
        $cmds[0].Args.Path    | Should -Be '$env:SystemDrive\Windows\System32\OneDriveSetup.exe'
        $cmds[0].Args.Recurse | Should -Be $false
    }

    It 'op=takeown-and-remove with recurse=true' {
        $action = [pscustomobject]@{ type='filesystem'; op='takeown-and-remove'; path='Windows\System32\Microsoft-Edge-Webview'; recurse=$true }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Kind         | Should -Be 'Remove-PathWithOwnership'
        $cmds[0].Args.Recurse | Should -Be $true
    }

    It 'unknown op throws' {
        $action = [pscustomobject]@{ type='filesystem'; op='nuke'; path='X'; recurse=$false }
        { Get-Tiny11FilesystemOnlineCommand -Action $action } | Should -Throw '*Invalid filesystem op*'
    }

    It 'Description present and references path' {
        $action = [pscustomobject]@{ type='filesystem'; op='remove'; path='Windows\X'; recurse=$true }
        $cmds = @(Get-Tiny11FilesystemOnlineCommand -Action $action)
        $cmds[0].Description | Should -Match 'Windows\\X'
    }
}
