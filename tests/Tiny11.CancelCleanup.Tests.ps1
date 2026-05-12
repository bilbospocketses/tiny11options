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

    It 'declares optional OutputIso parameter (build-complete safety guard)' {
        $script:content | Should -Match '\[string\]\$OutputIso = '''''
    }

    It 'refuses to run when OutputIso falls inside MountDir or SourceDir' {
        # The defensive guard at the top of the script: if $OutputIso is non-empty
        # and starts with $MountDir or $SourceDir (after path normalization), emit
        # cleanup-error and exit 1 before doing anything destructive.
        $script:content | Should -Match 'StartsWith\(\$normalizedTarget'
        $script:content | Should -Match "Refusing to clean up: output ISO"
    }

    Context '2026-05-11 order-fix: hive-unload + source-last + mount-gone gate' {
        # The first C5a smoke run surfaced two foot-guns:
        #   (1) The pipeline's `reg load HKLM\z*` keeps the host's System process
        #       holding NTUSER.DAT / SOFTWARE / SYSTEM / DEFAULT / COMPONENTS open
        #       inside MountDir, so Remove-Item silently fails on those files
        #       even though no other tool obviously holds them. Fixed by adding
        #       a `reg unload` pass at the top of the script.
        #   (2) The original step order deleted SourceDir unconditionally after
        #       attempting MountDir removal. If DISM unmount didn't actually
        #       succeed (mount still in Invalid state, source.wim still needed
        #       as reference), deleting SourceDir leaves the mount permanently
        #       unrecoverable until reboot. Fixed by gating Remove-Item SourceDir
        #       on a Test-Path MountDir check, with a "reboot required" diagnostic.

        It 'iterates the five zHive mount-key names in a foreach' {
            # The script unloads via foreach over an array literal of the 5 names,
            # building the HKLM\$mountKey path at runtime. Assert the array literal
            # contains each name.
            foreach ($key in @('zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM')) {
                $script:content | Should -Match "'$key'"
            }
        }

        It 'invokes reg.exe unload (not load — defensive against accidental hive mount in the cleanup script)' {
            $script:content | Should -Match "&\s+'reg\.exe'\s+'unload'"
            # No `reg.exe' 'load'` call (only `reg load`-references in comments,
            # which use backticks for code spans).
            $script:content | Should -Not -Match "&\s+'reg\.exe'\s+'load'"
        }

        It 'reg unload call site precedes the DISM /Unmount-Image call site (order is load-bearing)' {
            # Find the actual `& 'reg.exe'` invocation and the actual `& 'dism.exe' '/Unmount-Image'`
            # invocation — NOT the comment references (which appear earlier).
            $regIdx     = $script:content.IndexOf("& 'reg.exe' 'unload'")
            $unmountIdx = $script:content.IndexOf("& 'dism.exe' '/Unmount-Image'")
            $regIdx     | Should -BeGreaterThan -1
            $unmountIdx | Should -BeGreaterThan $regIdx
        }

        It 'verifies the DISM mount registry after /Cleanup-Mountpoints (re-runs cleanup if mount still listed)' {
            $script:content | Should -Match '/Get-MountedWimInfo'
            $script:content | Should -Match '\$mountInfo\s+-match\s+\[regex\]::Escape\(\$MountDir\)'
        }

        It 'removes MountDir BEFORE SourceDir (source-last) — source.wim must remain available for DISM unmount' {
            $mountRemove  = $script:content.IndexOf('Remove-Item -LiteralPath $MountDir')
            $sourceRemove = $script:content.IndexOf('Remove-Item -LiteralPath $SourceDir')
            $mountRemove  | Should -BeGreaterThan -1
            $sourceRemove | Should -BeGreaterThan $mountRemove
        }

        It 'gates SourceDir removal on Test-Path MountDir verification (post-removal mount-gone check)' {
            # After Remove-Item MountDir, the script re-checks Test-Path -LiteralPath $MountDir;
            # if the dir is still present (kernel handles held by wimmount driver), it bails
            # WITHOUT deleting SourceDir.
            $script:content | Should -Match '(?ms)if \(Test-Path -LiteralPath \$MountDir\) \{[\s\S]{0,1000}REBOOT REQUIRED[\s\S]{0,300}exit 1'
        }

        It 'emits a REBOOT REQUIRED cleanup-error when mount removal failed' {
            $script:content | Should -Match "REBOOT REQUIRED"
        }

        It 'reboot-required diagnostic explains why SourceDir was preserved' {
            $script:content | Should -Match "SourceDir.*preserved"
        }
    }
}
