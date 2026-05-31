# Regression guard for the v1.0.30 dismount-lock fix.
#
# The offline build process must NEVER touch a loaded offline hive (HKLM\z<HIVE>) through
# the .NET PowerShell registry provider -- i.e. the "HKLM:\z*" (or HKU:\z* / HKCU:\z*)
# PSDrive paths used with Get-Item / Get-ItemProperty / Set-ItemProperty / New-Item /
# Test-Path. The provider caches an in-process RegistryKey handle that survives `reg unload`
# and keeps the hive's backing file (inside the mount) open, so Dismount-WindowsImage -Save
# fails with "The process cannot access the file because it is being used by another process"
# (the v1.0.26..v1.0.29 build break). All offline-hive access must go through reg.exe
# (Get-Tiny11RegValueNames / Test-Tiny11HiveLoaded / Invoke-RegCommand), whose child process
# closes its handle on exit -- the reg.exe-only pattern of upstream tiny11builder and
# Microsoft's offline-servicing docs.
#
# This static scan fails if a provider-drive reference to a z-prefixed offline hive
# ("HK{LM,U,CU}:\z") reappears in any src module. It is intentionally narrow: the z-prefix
# is what marks a *mounted offline* hive (live-registry paths like HKLM:\SOFTWARE or
# HKU:\<sid> used in the emitted post-boot scripts are fine and are NOT matched). Matches
# that fall after a '#' on the line are treated as explanatory comments and ignored.

Set-StrictMode -Version Latest

Describe 'Offline-hive servicing uses reg.exe only (no .NET registry provider)' {
    BeforeAll {
        $script:srcDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    }

    It 'no src module references an offline-hive provider drive (HK*:\z)' {
        $pattern = 'HK(LM|U|CU):\\z'
        $offenders = foreach ($file in (Get-ChildItem -LiteralPath $script:srcDir -Filter '*.psm1')) {
            foreach ($mi in (Select-String -LiteralPath $file.FullName -Pattern $pattern -AllMatches)) {
                foreach ($m in $mi.Matches) {
                    # Skip matches that appear after a '#' on the line (explanatory comments).
                    if ($mi.Line.Substring(0, $m.Index) -notmatch '#') {
                        '{0}:{1}: {2}' -f $file.Name, $mi.LineNumber, $mi.Line.Trim()
                    }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because (
            "offline hives must be serviced via reg.exe, not the .NET registry provider " +
            "(an HK*:\z* provider handle locks Dismount-WindowsImage -Save). Offenders:`n" +
            ($offenders -join "`n"))
    }
}
