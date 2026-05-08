Set-StrictMode -Version 3.0

# End-to-end test for tiny11-profile-validate.ps1 — runs the actual script
# against the real catalog/catalog.json + src/* layout, mirrors what the
# C# launcher does via PwshRunner. Catches path-resolution bugs (cf. B4
# from the Path C audit) that a pure-module test of Import-Tiny11Selections
# would miss because the script's own $PSCommandPath -> $RepoRoot logic
# never gets exercised.

BeforeAll {
    $script:ValidatorScript = Join-Path $PSScriptRoot '..\tiny11-profile-validate.ps1'

    function script:Invoke-ProfileValidator([string]$ProfilePath) {
        $stdout = & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $script:ValidatorScript -ProfilePath $ProfilePath 2>&1
        @{
            ExitCode = $LASTEXITCODE
            # Last non-empty line is always the JSON envelope; earlier lines may be
            # PowerShell warning streams (e.g. import-module verbose).
            Json = $stdout | Where-Object { $_ -and $_.ToString().Trim() } | Select-Object -Last 1
        }
    }

    function script:New-TempProfile([string]$Json) {
        $path = Join-Path $env:TEMP "tiny11-profile-validate-test-$([guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($path, $Json, [System.Text.UTF8Encoding]::new($false))
        $path
    }
}

Describe "tiny11-profile-validate.ps1" {

    It "emits ok=true and flattens selections to {id: state} on a valid profile" {
        # 'remove-edge' / 'remove-clipchamp' are real catalog items; values
        # 'apply' / 'skip' are valid states.
        $profile = New-TempProfile '{"version": 1, "selections": {"remove-edge": "apply", "remove-clipchamp": "skip"}}'
        try {
            $r = Invoke-ProfileValidator $profile
            $r.ExitCode | Should -Be 0
            $obj = $r.Json | ConvertFrom-Json
            $obj.ok | Should -BeTrue
            # Catalog has ~74 items; New-Tiny11Selections fills in defaults for any
            # the profile didn't override, so the flat output covers all of them.
            $propCount = @($obj.selections.PSObject.Properties).Count
            $propCount | Should -BeGreaterThan 50
            $obj.selections.'remove-edge' | Should -Be 'apply'
            $obj.selections.'remove-clipchamp' | Should -Be 'skip'
        } finally {
            Remove-Item $profile -Force -ErrorAction SilentlyContinue
        }
    }

    It "emits ok=false with message on invalid state value" {
        # 'aplly' is the typo case the user might make. Import-Tiny11Selections
        # rejects with: "Selection state for '<id>' must be 'apply' or 'skip', got: aplly"
        $profile = New-TempProfile '{"version": 1, "selections": {"remove-edge": "aplly"}}'
        try {
            $r = Invoke-ProfileValidator $profile
            $r.ExitCode | Should -Be 1
            $obj = $r.Json | ConvertFrom-Json
            $obj.ok | Should -BeFalse
            $obj.message | Should -Match 'aplly'
        } finally {
            Remove-Item $profile -Force -ErrorAction SilentlyContinue
        }
    }

    It "emits ok=false on missing profile file" {
        $r = Invoke-ProfileValidator (Join-Path $env:TEMP "definitely-does-not-exist-$([guid]::NewGuid().ToString('N')).json")
        $r.ExitCode | Should -Be 1
        $obj = $r.Json | ConvertFrom-Json
        $obj.ok | Should -BeFalse
        $obj.message | Should -Match 'Profile not found'
    }

    It "emits ok=false on profile with version != 1" {
        $profile = New-TempProfile '{"version": 99, "selections": {}}'
        try {
            $r = Invoke-ProfileValidator $profile
            $r.ExitCode | Should -Be 1
            $obj = $r.Json | ConvertFrom-Json
            $obj.ok | Should -BeFalse
            $obj.message | Should -Match 'version'
        } finally {
            Remove-Item $profile -Force -ErrorAction SilentlyContinue
        }
    }
}
