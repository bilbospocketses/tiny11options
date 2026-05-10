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

# Registry operations applied to the offline-mounted hives during a Core
# build. 85 unique entries across 6 categories (after de-duplication of
# upstream repeated invocations) matching the build pipeline phases:
# bypass-sysreqs (10), sponsored-apps (26), telemetry (10),
# defender-disable (6), update-disable (16), misc (17).
#
# Schema: each entry is a PSCustomObject with these fields:
#   Category : phase-tag for filtering (one of the 6 known values)
#   Op       : 'add' (REG ADD) or 'delete' (REG DELETE)
#   Hive     : hive prefix used in offline mount (e.g. 'zSOFTWARE')
#   Path     : registry path under the hive (no leading backslash)
#   Name     : value name (add ops and some delete-value ops)
#   Type     : REG_DWORD / REG_SZ etc. (add ops only)
#   Value    : the value to set (add ops only)
#
# Consumed by the registry-* phases in Invoke-Tiny11CoreBuildPipeline,
# which filters by Category and dispatches each entry to
# Tiny11.Actions.Registry.Invoke-RegistryAction.
#
# Ported from upstream tiny11Coremaker.ps1 lines 340-470 (install.wim hive
# edits). Upstream has 81 '& reg' invocations plus 2 bare 'reg delete' calls
# for Edge (lines 392-393) and 5 Set-ItemProperty calls for Defender services
# (lines 467-469) — all captured here. Upstream duplicates de-duplicated:
#   - ContentDeliveryAllowed appears 3x (lines 356/358/359) -> 1 entry
#   - SubscribedContentEnabled appears 2x (lines 366/373) -> 1 entry
#
# The boot.wim bypass-sysreqs subset (upstream lines 503-514) is applied
# separately by Plan Task 12's boot-wim phase, which re-uses the
# bypass-sysreqs category from THIS data plus one extra Setup\CmdLine entry
# inlined there.
function Get-Tiny11CoreRegistryTweaks {
    @(
        # bypass-sysreqs (10 entries) — install.wim
        # Upstream lines 341-350: UnsupportedHardwareNotificationCache + LabConfig + MoSetup
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zDEFAULT'; Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV1'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zDEFAULT'; Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV2'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zNTUSER';  Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV1'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zNTUSER';  Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV2'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassCPUCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassRAMCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassSecureBootCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassStorageCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\LabConfig'; Name='BypassTPMCheck'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='bypass-sysreqs'; Op='add'; Hive='zSYSTEM';  Path='Setup\MoSetup'; Name='AllowUpgradesWithUnsupportedTPMOrCPU'; Type='REG_DWORD'; Value=1 }

        # sponsored-apps (26 entries) — ContentDeliveryManager + CloudContent + PolicyManager +
        # PushToInstall + MRT + Subscription deletes. De-duped from upstream (ContentDeliveryAllowed
        # appeared 3x at lines 356/358/359; SubscribedContentEnabled appeared 2x at lines 366/373).
        # Upstream lines 352-380.
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='OemPreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='ContentDeliveryAllowed'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\PolicyManager\current\device\Start'; Name='ConfigureStartPins'; Type='REG_SZ'; Value='{"pinnedList": [{}]}' }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='FeatureManagementEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='OemPreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEverEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SoftLandingEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContentEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-310093Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338388Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338389Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338393Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-353694Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-353696Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SystemPaneSuggestionsEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\PushToInstall'; Name='DisablePushToInstall'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\MRT'; Name='DontOfferThroughWUAU'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='delete'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' }
        [pscustomobject]@{ Category='sponsored-apps'; Op='delete'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableConsumerAccountStateContent'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='sponsored-apps'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableCloudOptimizedContent'; Type='REG_DWORD'; Value=1 }

        # misc (17 entries) — BypassNRO, Reserved Storage, BitLocker, Chat icon, TaskbarMn,
        # Edge uninstall reg deletes, OneDrive backup, DevHome/Outlook prevent+delete,
        # Copilot, Edge HubsSidebar, Explorer SearchBoxSuggestions, Teams, Mail.
        # Upstream lines 382, 385, 387, 389-390, 392-393, 395, 408-415, 417, 419.
        # Note: lines 392-393 use bare 'reg delete' (not '& reg') in upstream.
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\OOBE'; Name='BypassNRO'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\ReserveManager'; Name='ShippedWithReserves'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSYSTEM';   Path='ControlSet001\Control\BitLocker'; Name='PreventDeviceEncryption'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\Windows Chat'; Name='ChatIcon'; Type='REG_DWORD'; Value=3 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zNTUSER';   Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarMn'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update' }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\OneDrive'; Name='DisableFileSyncNGSC'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'; Name='workCompleted'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'; Name='workCompleted'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' }
        [pscustomobject]@{ Category='misc'; Op='delete'; Hive='zSOFTWARE'; Path='Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Edge'; Name='HubsSidebarEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\Explorer'; Name='DisableSearchBoxSuggestions'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Teams'; Name='DisableInstallation'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='misc'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\Windows Mail'; Name='PreventRun'; Type='REG_DWORD'; Value=1 }

        # telemetry (10 entries) — AdvertisingInfo, Privacy, OnlineSpeechPrivacy, Input TIPC,
        # InputPersonalization, TrainedDataStore, Personalization, DataCollection, dmwappushservice.
        # Upstream lines 397-406.
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name='HasAccepted'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Input\TIPC'; Name='Enabled'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitInkCollection'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitTextCollection'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\InputPersonalization\TrainedDataStore'; Name='HarvestContacts'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zNTUSER';  Path='Software\Microsoft\Personalization\Settings'; Name='AcceptedPrivacyPolicy'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Type='REG_DWORD'; Value=0 }
        [pscustomobject]@{ Category='telemetry'; Op='add'; Hive='zSYSTEM';  Path='ControlSet001\Services\dmwappushservice'; Name='Start'; Type='REG_DWORD'; Value=4 }

        # update-disable (16 entries) — RunOnce post-OOBE WU stops, WindowsUpdate policies,
        # wuauserv Start=4, WaaSMedicSVC/UsoSvc service deletions, NoAutoUpdate, DisableOnline.
        # Upstream lines 441-456.
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='StopWUPostOOBE1'; Type='REG_SZ'; Value='net stop wuauserv' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='StopWUPostOOBE2'; Type='REG_SZ'; Value='sc stop wuauserv' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='StopWUPostOOBE3'; Type='REG_SZ'; Value='sc config wuauserv start= disabled' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='DisbaleWUPostOOBE1'; Type='REG_SZ'; Value='reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\RunOnce'; Name='DisbaleWUPostOOBE2'; Type='REG_SZ'; Value='reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='DoNotConnectToWindowsUpdateInternetLocations'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='DisableWindowsUpdateAccess'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='WUServer'; Type='REG_SZ'; Value='localhost' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='WUStatusServer'; Type='REG_SZ'; Value='localhost' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='UpdateServiceUrlAlternate'; Type='REG_SZ'; Value='localhost' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='UseWUServer'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\OOBE'; Name='DisableOnline'; Type='REG_DWORD'; Value=1 }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSYSTEM';  Path='ControlSet001\Services\wuauserv'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='update-disable'; Op='delete'; Hive='zSYSTEM';  Path='ControlSet001\Services\WaaSMedicSVC' }
        [pscustomobject]@{ Category='update-disable'; Op='delete'; Hive='zSYSTEM';  Path='ControlSet001\Services\UsoSvc' }
        [pscustomobject]@{ Category='update-disable'; Op='add'; Hive='zSOFTWARE'; Path='Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='NoAutoUpdate'; Type='REG_DWORD'; Value=1 }

        # defender-disable (6 entries) — 5 services Start=4 (via Set-ItemProperty in upstream
        # lines 459-469) + SettingsPageVisibility (upstream line 470).
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WinDefend'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WdNisSvc'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WdNisDrv'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\WdFilter'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSYSTEM'; Path='ControlSet001\Services\Sense'; Name='Start'; Type='REG_DWORD'; Value=4 }
        [pscustomobject]@{ Category='defender-disable'; Op='add'; Hive='zSOFTWARE'; Path='Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name='SettingsPageVisibility'; Type='REG_SZ'; Value='hide:virus;windowsupdate' }
    )
}

# Internal helper: invoke an external .exe with controlled args, capture
# exit code + output. Wrapped as a named function so Pester `Mock` can
# intercept cleanly during unit tests (the `&` call operator is harder
# to mock reliably). Not exported.
function Start-CoreProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$Arguments = @()
    )
    $output = & $FileName @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output -join "`n"
    }
}

# Wrapper for dism.exe invocations (mounting, removing packages, exporting,
# cleanup, etc.). Returns @{ExitCode, Output}; callers check ExitCode and
# throw on non-zero with descriptive context.
function Invoke-CoreDism {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Start-CoreProcess -FileName 'dism.exe' -Arguments $Arguments
}

# Wrapper for takeown.exe — assigns Administrators ownership of $Path.
# /D Y answers the confirmation prompt for inaccessible directories.
function Invoke-CoreTakeown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )
    $args = @('/F', $Path)
    if ($Recurse) { $args += '/R' }
    $args += @('/D', 'Y')
    Start-CoreProcess -FileName 'takeown.exe' -Arguments $args
}

# Wrapper for icacls.exe — grants Administrators full control. /T recurses,
# /C continues on errors.
function Invoke-CoreIcacls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )
    $args = @($Path, '/grant', 'Administrators:F')
    if ($Recurse) { $args += @('/T', '/C') }
    Start-CoreProcess -FileName 'icacls.exe' -Arguments $args
}

# DISM /Remove-Package loop. Enumerates installed packages once, then
# removes any whose identity matches one of the supplied patterns
# (prefix-matched). Non-fatal on zero matches per pattern (a pattern
# matching nothing means the source ISO didn't include that component).
# Fatal if DISM /Get-Packages itself errors.
function Invoke-Tiny11CoreSystemPackageRemoval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string]$LanguageCode
    )

    $enumResult = Invoke-CoreDism -Arguments @('/English', "/image:$ScratchDir", '/Get-Packages', '/Format:Table')
    if ($enumResult.ExitCode -ne 0) {
        throw "dism /Get-Packages failed (exit $($enumResult.ExitCode)): $($enumResult.Output)"
    }

    # Upstream approach (tiny11Coremaker.ps1 lines 153-161): split output on newlines,
    # then for each pattern filter lines where the full line matches the prefix.
    # The identity is extracted as the first whitespace-delimited token from each
    # matching line. Header and label lines are naturally excluded because they
    # don't match any package-identity prefix pattern.
    $allLines = $enumResult.Output -split "`n"

    foreach ($pattern in $Patterns) {
        $matchedItems = $allLines |
            Where-Object { $_ -like "$pattern*" } |
            ForEach-Object { ($_ -split '\s+')[0] }
        if (-not $matchedItems) {
            Write-Verbose "No matches for pattern: $pattern (non-fatal — package may be absent in this ISO version)"
            continue
        }
        foreach ($identity in $matchedItems) {
            $removeResult = Invoke-CoreDism -Arguments @('/English', "/image:$ScratchDir", '/Remove-Package', "/PackageName:$identity")
            if ($removeResult.ExitCode -ne 0) {
                Write-Verbose "dism /Remove-Package $identity failed (exit $($removeResult.ExitCode)) — non-fatal, continuing"
            }
        }
    }
}

Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks, `
    Invoke-Tiny11CoreSystemPackageRemoval
