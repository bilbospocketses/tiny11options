# Structural / contract tests for tiny11-cancel-cleanup.ps1.
#
# We don't run the script as a subprocess in tests because it invokes
# dism /Cleanup-Mountpoints which has system-wide side effects (could
# disrupt other DISM operations on the test host). Instead we assert
# the script's shape: that it parses cleanly, has the right parameters,
# emits the three marker types, and tolerates missing mount/source dirs
# (the "user clicked cleanup but state is already clean" path). The
# runtime behavior is validated via Phase 7 C5 manual smoke against a
# real cancel-mid-build scenario.

Describe 'tiny11-cancel-cleanup.ps1 — structural contract' {
    BeforeAll {
        $script:scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\tiny11-cancel-cleanup.ps1')).Path
        $script:content    = Get-Content $script:scriptPath -Raw
    }

    It 'exists at repo root' {
        Test-Path $script:scriptPath | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'declares Mandatory MountDir parameter' {
        $script:content | Should -Match '\[Parameter\(Mandatory\)\]\[string\]\$MountDir'
    }

    It 'declares Mandatory SourceDir parameter' {
        $script:content | Should -Match '\[Parameter\(Mandatory\)\]\[string\]\$SourceDir'
    }

    It 'invokes DISM /Unmount-Image /Discard against MountDir' {
        $script:content | Should -Match "dism\.exe.*'/Unmount-Image'.*MountDir"
    }

    It 'invokes DISM /Cleanup-Mountpoints' {
        $script:content | Should -Match "dism\.exe.*'/Cleanup-Mountpoints'"
    }

    It 'invokes takeown with /F MountDir /R /D Y' {
        $script:content | Should -Match "takeown\.exe.*'/F'.*\$MountDir.*'/R'.*'/D'.*'Y'"
    }

    It 'invokes icacls with /grant Administrators:F /T /C' {
        $script:content | Should -Match "icacls\.exe.*\$MountDir.*'/grant'.*'Administrators:F'.*'/T'.*'/C'"
    }

    It 'guards takeown/icacls/Remove behind Test-Path MountDir (tolerates clean state)' {
        $script:content | Should -Match 'if \(Test-Path -LiteralPath \$MountDir\)'
    }

    It 'guards SourceDir Remove behind Test-Path (tolerates clean state)' {
        $script:content | Should -Match 'if \(Test-Path -LiteralPath \$SourceDir\)'
    }

    It 'uses Remove-Item -ErrorAction SilentlyContinue for non-fatal cleanup' {
        # Two Remove-Item calls (mount + source), both SilentlyContinue.
        ([regex]::Matches($script:content, 'Remove-Item -LiteralPath \$\w+Dir -Recurse -Force -ErrorAction SilentlyContinue')).Count | Should -BeGreaterOrEqual 2
    }

    It 'emits cleanup-progress markers via Write-Marker' {
        $script:content | Should -Match "Write-Marker 'cleanup-progress'"
    }

    It 'emits cleanup-complete marker on success path' {
        $script:content | Should -Match "Write-Marker 'cleanup-complete'"
    }

    It 'emits cleanup-error marker in catch block' {
        $script:content | Should -Match "Write-Marker 'cleanup-error'"
    }

    It 'wraps the work in a try/catch so failures surface as cleanup-error not raw exception' {
        $script:content | Should -Match '(?ms)try \{.*\} catch \{'
    }

    It 'exits 0 on success and 1 on error' {
        $script:content | Should -Match 'exit 0'
        $script:content | Should -Match 'exit 1'
    }
}
