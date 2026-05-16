Describe "Build-RelaunchArgs" {
    It "forwards bound parameters with proper quoting" {
        . "$PSScriptRoot/../tiny11maker.ps1" -Internal
        $bound = [ordered]@{
            Source         = 'C:\some path\Win11.iso'
            Config         = 'profile.json'
            NonInteractive = [switch]$true
        }
        $argString = Build-RelaunchArgs -Bound $bound -ScriptPath 'C:\foo\tiny11maker.ps1'
        $argString | Should -Match '-Source "C:\\some path\\Win11.iso"'
        $argString | Should -Match '-Config "profile.json"'
        $argString | Should -Match '-NonInteractive'
        $argString | Should -Match '-File "C:\\foo\\tiny11maker.ps1"'
    }
    It "serializes array params by repeating the param name (v1.0.8 audit A2)" {
        . "$PSScriptRoot/../tiny11maker.ps1" -Internal
        $bound = @{ Editions = @('Pro', 'Home') }
        $args = Build-RelaunchArgs -Bound $bound -ScriptPath 'x.ps1'
        $args | Should -Match '-Editions "Pro"'
        $args | Should -Match '-Editions "Home"'
    }
    It "escapes embedded double-quote in scalar string values (v1.0.8 audit A2)" {
        . "$PSScriptRoot/../tiny11maker.ps1" -Internal
        $bound = @{ Source = 'C:\path\with"quote.iso' }
        $args = Build-RelaunchArgs -Bound $bound -ScriptPath 'x.ps1'
        # Embedded " is doubled (PS convention for embedded " in "..." strings)
        $args | Should -Match '"C:\\path\\with""quote\.iso"'
    }
}

Describe "Invoke-SelfElevate (v1.0.8 audit A1)" {
    BeforeAll { . "$PSScriptRoot/../tiny11maker.ps1" -Internal }
    It "throws on -NonInteractive self-elevation attempt" {
        $bound = @{ NonInteractive = $true; Source = 'C:\fake.iso' }
        { Invoke-SelfElevate -Bound $bound } | Should -Throw "*requires a pre-elevated session*"
    }
}
