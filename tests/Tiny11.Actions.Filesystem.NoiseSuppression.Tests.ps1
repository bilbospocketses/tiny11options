Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions.Filesystem'

# v1.0.7 Finding 4 -- guards the takeown/icacls stderr noise filter against
# (a) failing to suppress the two known-benign protected-folder lines, OR
# (b) accidentally widening to swallow real failure messages. Both regressions
# are silent and would only surface when shipped builds either pollute logs
# (a) or hide legitimate offline-image errors (b).
Describe "Test-IsKnownBenignTakeownIcaclsNoise" {

    Context "matches the known protected-folder lines verbatim" {
        It "matches the WMI\RtBackup line from a real headless build" {
            $line = 'C:\Users\jscha\AppData\Local\Temp\tiny11options-XXXX\scratchdir\Windows\System32\LogFiles\WMI\RtBackup\*: Access is denied.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeTrue
        }
        It "matches the WebThreatDefSvc line from a real headless build" {
            $line = 'C:\Users\jscha\AppData\Local\Temp\tiny11options-XXXX\scratchdir\Windows\System32\WebThreatDefSvc\*: Access is denied.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeTrue
        }
        It "matches with arbitrary scratch-dir prefixes (different temp UUIDs / drive letters)" {
            $line = 'D:\some\other\scratch\Windows\System32\LogFiles\WMI\RtBackup\*: Access is denied.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeTrue
        }
        It "matches case-insensitively (Windows paths are case-insensitive)" {
            $line = 'C:\scratch\WINDOWS\System32\WebThreatDefSvc\*: ACCESS IS DENIED.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeTrue
        }
    }

    Context "does NOT swallow real failure messages" {
        It "passes through Access-is-denied on a path NOT in the protected list" {
            # A genuine failure on the Edge WebView path itself MUST surface -- that
            # would mean the catalog action couldn't take ownership of the very
            # folder it's trying to remove. Hiding that would be a real regression.
            $line = 'C:\scratch\Windows\System32\Microsoft-Edge-Webview\*: Access is denied.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeFalse
        }
        It "passes through other System32 subfolder access errors" {
            # Any new SYSTEM-protected folder Microsoft adds in a future Win11 build
            # would surface as a similar stderr line -- let it through so we know to
            # add it to the suppression list deliberately, not silently swallow.
            $line = 'C:\scratch\Windows\System32\NewProtectedFolder\*: Access is denied.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeFalse
        }
        It "passes through generic 'Access is denied' lines without the path-asterisk form" {
            $line = 'Access is denied.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeFalse
        }
        It "passes through 'ERROR:' style takeown/icacls failures" {
            $line = 'ERROR: The system cannot find the file specified.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeFalse
        }
        It "passes through partial matches (just the protected folder name without the trailing wildcard)" {
            # Without the verbatim "\*: Access is denied." trailing form, this is
            # NOT the takeown/icacls noise pattern -- could be a different command's
            # error referencing the same path. Don't swallow.
            $line = 'Some other tool says C:\scratch\Windows\System32\LogFiles\WMI\RtBackup is bad.'
            Test-IsKnownBenignTakeownIcaclsNoise -Line $line | Should -BeFalse
        }
    }

    Context "edge cases" {
        It "returns false for an empty string" {
            Test-IsKnownBenignTakeownIcaclsNoise -Line '' | Should -BeFalse
        }
        It "returns false for a whitespace-only string" {
            Test-IsKnownBenignTakeownIcaclsNoise -Line '   ' | Should -BeFalse
        }
    }
}
