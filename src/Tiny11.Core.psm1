# tiny11 Core build mode — data accessors + operation orchestrators.
# Backs tiny11Coremaker-from-config.ps1 (the launcher's Core build wrapper).
#
# Reuses these existing modules where operations overlap with the standard
# tiny11 build: Tiny11.Iso (mount/dismount), Tiny11.Hives (load/unload),
# Tiny11.Actions.{Registry,Filesystem,ProvisionedAppx,ScheduledTask}.
# Core-unique operations (WinSxS wipe, /Remove-Package loop, .NET 3.5
# enable, Compress:max + Compress:recovery export sequence) live here.
#
# Spec: docs/superpowers/specs/2026-05-09-tiny11-core-mode-design.md

Set-StrictMode -Version Latest

# Hardcoded provisioned-appx package prefixes that Core removes from every
# build. List ported verbatim from upstream tiny11Coremaker.ps1 line 119.
# Each entry is a wildcard-prefix used by DISM /Remove-ProvisionedAppxPackage
# match logic — most end with "_" (the appx-package-name version separator).
function Get-Tiny11CoreAppxPrefixes {
    @(
        'Clipchamp.Clipchamp_'
        'Microsoft.BingNews_'
        'Microsoft.BingWeather_'
        'Microsoft.GamingApp_'
        'Microsoft.GetHelp_'
        'Microsoft.Getstarted_'
        'Microsoft.MicrosoftOfficeHub_'
        'Microsoft.MicrosoftSolitaireCollection_'
        'Microsoft.People_'
        'Microsoft.PowerAutomateDesktop_'
        'Microsoft.Todos_'
        'Microsoft.WindowsAlarms_'
        'microsoft.windowscommunicationsapps_'
        'Microsoft.WindowsFeedbackHub_'
        'Microsoft.WindowsMaps_'
        'Microsoft.WindowsSoundRecorder_'
        'Microsoft.Xbox.TCUI_'
        'Microsoft.XboxGamingOverlay_'
        'Microsoft.XboxGameOverlay_'
        'Microsoft.XboxSpeechToTextOverlay_'
        'Microsoft.YourPhone_'
        'Microsoft.ZuneMusic_'
        'Microsoft.ZuneVideo_'
        'MicrosoftCorporationII.MicrosoftFamily_'
        'MicrosoftCorporationII.QuickAssist_'
        'MicrosoftTeams_'
        'Microsoft.549981C3F5F10_'
        'Microsoft.Windows.Copilot'
        'MSTeams_'
        'Microsoft.OutlookForWindows_'
        'Microsoft.Windows.Teams_'
        'Microsoft.Copilot_'
    )
}

# DISM /Remove-Package patterns for Core's aggressive system-package removal.
# 12 entries; 4 are language-code-templated (LanguageFeatures-* family).
# Ported from upstream tiny11Coremaker.ps1 lines 135-149.
function Get-Tiny11CoreSystemPackagePatterns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LanguageCode
    )
    @(
        'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35'
        'Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64'
        "Microsoft-Windows-LanguageFeatures-Handwriting-$LanguageCode-Package~31bf3856ad364e35"
        "Microsoft-Windows-LanguageFeatures-OCR-$LanguageCode-Package~31bf3856ad364e35"
        "Microsoft-Windows-LanguageFeatures-Speech-$LanguageCode-Package~31bf3856ad364e35"
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$LanguageCode-Package~31bf3856ad364e35"
        'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35'
        'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35'
        'Windows-Defender-Client-Package~31bf3856ad364e35~'
        'Microsoft-Windows-WordPad-FoD-Package~'
        'Microsoft-Windows-TabletPCMath-Package~'
        'Microsoft-Windows-StepsRecorder-Package~'
    )
}

# Filesystem paths Core deletes (relative to mounted scratchdir root).
# Each entry has RelPath (relative path from scratchdir) and Recurse
# (whether to recurse into directories — false for single-file targets).
# Ported from upstream tiny11Coremaker.ps1 lines 183-220.
# WinSxS architecture-specific WebView dir is handled separately by
# Invoke-Tiny11CoreWinSxsWipe (it's part of the WinSxS phase).
# WinRE.wim replacement is handled separately (delete+recreate empty file).
function Get-Tiny11CoreFilesystemTargets {
    @(
        [pscustomobject]@{ RelPath = 'Program Files (x86)\Microsoft\Edge';        Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Program Files (x86)\Microsoft\EdgeUpdate';  Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Program Files (x86)\Microsoft\EdgeCore';    Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Windows\System32\OneDriveSetup.exe';        Recurse = $false }
        [pscustomobject]@{ RelPath = 'Windows\System32\Microsoft-Edge-Webview';   Recurse = $true  }
    )
}

# Scheduled-task XML files Core deletes from the mounted image.
# Paths relative to <scratchdir>\Windows\System32\Tasks\.
# Each entry has RelPath (relative task XML path) and Recurse
# (whether to recurse — true only for CEIP which is a folder containing multiple tasks).
# Ported from upstream tiny11Coremaker.ps1 lines 422-438.
function Get-Tiny11CoreScheduledTaskTargets {
    @(
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'; Recurse = $false }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Customer Experience Improvement Program';                    Recurse = $true  }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Application Experience\ProgramDataUpdater';                  Recurse = $false }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Chkdsk\Proxy';                                                Recurse = $false }
        [pscustomobject]@{ RelPath = 'Microsoft\Windows\Windows Error Reporting\QueueReporting';                     Recurse = $false }
    )
}

# WinSxS subdirs preserved during Core's destructive WinSxS wipe.
# Per architecture: amd64 (29 entries) or arm64 (28 entries).
# Patterns are Get-ChildItem -Filter wildcards — most end in `_*` to match
# version-suffixed dirs. Non-wildcarded entries (Catalogs, Manifests, etc.)
# are exact directory names that exist verbatim under WinSxS.
# Ported from upstream tiny11Coremaker.ps1 lines 235-316.
# Note: upstream amd64 list has a duplicate entry; we de-dupe via Select-Object -Unique.
# Note: upstream arm64 array uses non-comma syntax in places; we normalize.
# Note: ValidateSet enforces architecture at parameter binding; the explicit
#   throw at the bottom is unreachable for valid invocations but kept as a
#   defensive guard if ValidateSet is ever loosened or the function is called
#   from contexts that bypass parameter validation.
function Get-Tiny11CoreWinSxsKeepList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('amd64', 'arm64')]
        [string]$Architecture
    )

    if ($Architecture -eq 'amd64') {
        $list = @(
            'x86_microsoft.windows.common-controls_6595b64144ccf1df_*',
            'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*',
            'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
            'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
            'x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*',
            'x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*',
            'x86_microsoft-windows-servicingstack_31bf3856ad364e35_*',
            'x86_microsoft-windows-servicingstack-inetsrv_*',
            'x86_microsoft-windows-servicingstack-onecore_*',
            'amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
            'amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
            'amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
            'amd64_microsoft.windows.common-controls_6595b64144ccf1df_*',
            'amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*',
            'amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
            'amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
            'amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*',
            'amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*',
            'amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*',
            'amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*',
            'amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*',
            'amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*',
            'amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*',
            'Catalogs',
            'FileMaps',
            'Fusion',
            'InstallTemp',
            'Manifests',
            'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
            'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
            'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
        )
        # de-dupe (upstream listed x86_microsoft.windows.c..-controls.resources twice at lines 267-268)
        return $list | Select-Object -Unique
    }

    if ($Architecture -eq 'arm64') {
        return @(
            'arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*',
            'Catalogs',
            'FileMaps',
            'Fusion',
            'InstallTemp',
            'Manifests',
            'SettingsManifests',
            'Temp',
            'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
            'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
            'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
            'x86_microsoft.windows.common-controls_6595b64144ccf1df_*',
            'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*',
            'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
            'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
            'arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
            'arm_microsoft.windows.common-controls_6595b64144ccf1df_*',
            'arm_microsoft.windows.gdiplus_6595b64144ccf1df_*',
            'arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
            'arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
            'arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
            'arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
            'arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
            'arm64_microsoft.windows.common-controls_6595b64144ccf1df_*',
            'arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*',
            'arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
            'arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
            'arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*',
            'arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*',
            'arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*',
            'arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*',
            'arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*',
            'arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*'
        )
    }

    throw "Unknown architecture: $Architecture. Expected 'amd64' or 'arm64'."
}

Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList
