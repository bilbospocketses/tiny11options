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

# Enable .NET 3.5 in the offline image via DISM. Only invoked when the
# user checked the .NET 3.5 box in Step 1 (-EnableNet35:$true). Source
# path is the sources\sxs directory inside the copied ISO contents
# (typically <scratch>\source\sources\sxs). Throws if the sxs directory
# is missing — usually means the user's ISO doesn't bundle SxS payloads.
function Invoke-Tiny11CoreNet35Enable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][bool]$EnableNet35
    )

    if (-not $EnableNet35) {
        Write-Verbose '.NET 3.5 enable skipped (-EnableNet35:$false)'
        return
    }

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw ".NET 3.5 source not found at $SourcePath. Verify your Windows 11 ISO includes sources\sxs. Either uncheck Enable .NET 3.5 in Step 1 and rebuild, or use a complete Win11 multi-edition ISO."
    }

    $result = Invoke-CoreDism -Arguments @(
        '/English',
        "/image:$ScratchDir",
        '/enable-feature',
        '/featurename:NetFX3',
        '/All',
        "/source:$SourcePath"
    )
    if ($result.ExitCode -ne 0) {
        throw "DISM /enable-feature NetFX3 failed (exit $($result.ExitCode)): $($result.Output)"
    }
}

# DISM /Export-Image wrapper. Used twice during a Core build:
#   1. install.wim -> install2.wim with /Compress:max (intermediate)
#   2. install2.wim (renamed install.wim) -> install.esd with /Compress:recovery (final)
# Throws on non-zero exit. Caller is responsible for the rename + cleanup.
function Invoke-Tiny11CoreImageExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceImageFile,
        [Parameter(Mandatory)][string]$DestinationImageFile,
        [Parameter(Mandatory)][int]$SourceIndex,
        [Parameter(Mandatory)][ValidateSet('max', 'recovery')][string]$Compress
    )

    $result = Invoke-CoreDism -Arguments @(
        '/English',
        '/Export-Image',
        "/SourceImageFile:$SourceImageFile",
        "/SourceIndex:$SourceIndex",
        "/DestinationImageFile:$DestinationImageFile",
        "/Compress:$Compress"
    )
    if ($result.ExitCode -ne 0) {
        throw "DISM /Export-Image $SourceImageFile -> $DestinationImageFile (Compress:$Compress) failed (exit $($result.ExitCode)): $($result.Output)"
    }
}

# The destructive WinSxS wipe — Core's signature operation.
# Sequence:
#   1. takeown + icacls on <scratch>\Windows\WinSxS (recursive, ~5 min)
#   2. Create <scratch>\Windows\WinSxS_edit
#   3. For each pattern in the architecture-specific keep-list, copy
#      matching subdirs (or top-level dirs like Catalogs/Manifests) from
#      WinSxS into WinSxS_edit
#   4. Delete <scratch>\Windows\WinSxS recursively
#   5. Rename <scratch>\Windows\WinSxS_edit to WinSxS
#
# Failure modes:
#   - Zero patterns matched anywhere in WinSxS -> throw (architecture
#     mismatch or unexpected ISO layout; better to fail loudly than
#     produce a corrupted image)
#   - Mid-flight cancel -> non-resumable state; cleanup-command UI guides
#     user recovery (documented in build-progress + build-failed UIs)
function Invoke-Tiny11CoreWinSxsWipe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Architecture
    )

    $winSxs = Join-Path $ScratchDir 'Windows\WinSxS'
    $winSxsEdit = Join-Path $ScratchDir 'Windows\WinSxS_edit'
    $keepList = Get-Tiny11CoreWinSxsKeepList -Architecture $Architecture

    Write-Verbose "Taking ownership of $winSxs (recursive)..."
    Invoke-CoreTakeown -Path $winSxs -Recurse | Out-Null
    Invoke-CoreIcacls  -Path $winSxs -Recurse | Out-Null

    Write-Verbose "Creating $winSxsEdit..."
    New-Item -Path $winSxsEdit -ItemType Directory -Force | Out-Null

    $totalMatches = 0
    foreach ($pattern in $keepList) {
        $patternMatches = Get-ChildItem -Path $winSxs -Filter $pattern -Directory -ErrorAction SilentlyContinue
        if (-not $patternMatches) {
            Write-Verbose "Keep-list pattern '$pattern' matched zero entries (non-fatal per-pattern)"
            continue
        }
        foreach ($match in $patternMatches) {
            $totalMatches++
            $dest = Join-Path $winSxsEdit $match.Name
            Copy-Item -Path $match.FullName -Destination $dest -Recurse -Force
        }
    }

    if ($totalMatches -eq 0) {
        throw "WinSxS wipe: zero keep-list patterns matched any subdirectory under $winSxs (Architecture=$Architecture). Source ISO may not be a $Architecture Win11 image, or its WinSxS layout differs from the expected layout."
    }

    Write-Verbose "Deleting original WinSxS..."
    Remove-Item -Path $winSxs -Recurse -Force

    Write-Verbose "Renaming WinSxS_edit -> WinSxS..."
    Rename-Item -Path $winSxsEdit -NewName 'WinSxS'
}

# Top-level Core build orchestrator. Composes the 24 phases per spec §6.
# Emits build-progress markers to the supplied -ProgressCallback (the
# wrapper script wires this to Write-Marker JSON to STDOUT for the
# launcher's BuildHandlers forwarder).
#
# Reuses Tiny11.Hives (load/unload) and calls the Core-unique helpers
# in this module directly. Registry tweaks, filesystem removals, scheduled-
# task cleanup, and provisioned-appx removal all route through internal
# helpers rather than the catalog-pattern action modules — those modules
# use a different ($Action, $ScratchDir) dispatch convention designed for
# the catalog-driven build pipeline.
#
# NOT unit-tested — 24-phase orchestration mocking is high-effort low-payoff.
# End-to-end verification via Phase 7 manual smoke C2-C5.
function Invoke-Tiny11CoreBuildPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$OutputIso,
        [Parameter(Mandatory)][bool]$EnableNet35,
        [Parameter(Mandatory)][bool]$UnmountSource,
        [Parameter(Mandatory)][scriptblock]$ProgressCallback
    )

    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Hives.psm1') -Force

    $sourceDir = Join-Path $ScratchDir 'source'
    $mountDir  = Join-Path $ScratchDir 'mount'
    $sxsSourcePath = Join-Path $sourceDir 'sources\sxs'

    # Phase 1: preflight — copy source + detect install.esd -> convert
    & $ProgressCallback @{ phase='preflight'; step='Copying Windows image to scratch'; percent=5 }
    New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
    Copy-Item -Path "$Source\*" -Destination $sourceDir -Recurse -Force

    # Phase 2: preflight — mount install.wim
    & $ProgressCallback @{ phase='preflight'; step='Mounting install.wim for offline edit'; percent=10 }
    New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
    $installWim = Join-Path $sourceDir 'sources\install.wim'
    $mountResult = Invoke-CoreDism -Arguments @('/English', '/Mount-Image', "/ImageFile:$installWim", "/Index:$ImageIndex", "/MountDir:$mountDir")
    if ($mountResult.ExitCode -ne 0) { throw "DISM /Mount-Image failed: $($mountResult.Output)" }

    $pipelineSucceeded = $false
    try {
        # Phase 3: detect language code from mounted image (used by system-package patterns)
        $intl = Invoke-CoreDism -Arguments @('/English', "/Image:$mountDir", '/Get-Intl')
        $languageCode = 'en-US'
        if ($intl.Output -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})') {
            $languageCode = $Matches[1]
        }

        # Phase 3b: detect architecture (upstream lines 92-105)
        $imageInfo = Invoke-CoreDism -Arguments @('/English', '/Get-WimInfo', "/wimFile:$installWim", "/index:$ImageIndex")
        $architecture = 'amd64'
        if ($imageInfo.Output -match 'Architecture : (\S+)') {
            $arch = $Matches[1]
            if ($arch -eq 'x64') { $architecture = 'amd64' }
            elseif ($arch -eq 'ARM64' -or $arch -eq 'arm64') { $architecture = 'arm64' }
            else { throw "Unsupported architecture: $arch (Core mode requires amd64 or arm64)" }
        }

        # Phase 4: appx-removal (upstream lines 111-128)
        & $ProgressCallback @{ phase='appx-removal'; step="Removing provisioned apps"; percent=15 }
        $appxPrefixes = Get-Tiny11CoreAppxPrefixes
        $allAppxOutput = (& 'dism.exe' '/English' "/image:$mountDir" '/Get-ProvisionedAppxPackages') -join "`n"
        $allAppxPackages = @()
        foreach ($line in ($allAppxOutput -split "`n")) {
            if ($line -match 'PackageName\s*:\s*(.+)') { $allAppxPackages += $Matches[1].Trim() }
        }
        foreach ($pkg in $allAppxPackages) {
            foreach ($prefix in $appxPrefixes) {
                if ($pkg -like "$prefix*") {
                    & 'dism.exe' '/English' "/image:$mountDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$pkg" | Out-Null
                    break
                }
            }
        }

        # Phase 5: system-package-removal (upstream lines 130-166)
        & $ProgressCallback @{ phase='system-package-removal'; step='Removing system packages (IE, MediaPlayer, Defender, etc.)'; percent=20 }
        $sysPatterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode $languageCode
        Invoke-Tiny11CoreSystemPackageRemoval -ScratchDir $mountDir -Patterns $sysPatterns -LanguageCode $languageCode

        # Phase 6: net35-enable (conditional, upstream lines 168-181)
        if ($EnableNet35) {
            & $ProgressCallback @{ phase='net35-enable'; step='Enabling .NET 3.5 from offline source'; percent=27 }
            Invoke-Tiny11CoreNet35Enable -ScratchDir $mountDir -SourcePath $sxsSourcePath -EnableNet35:$true
        }

        # Phase 7: filesystem-removal (upstream lines 182-220)
        & $ProgressCallback @{ phase='filesystem-removal'; step='Removing Edge / OneDrive / WebView'; percent=32 }
        $fsTargets = Get-Tiny11CoreFilesystemTargets
        foreach ($t in $fsTargets) {
            $abs = Join-Path $mountDir $t.RelPath
            if (Test-Path -LiteralPath $abs) {
                Invoke-CoreTakeown -Path $abs -Recurse | Out-Null
                Invoke-CoreIcacls  -Path $abs -Recurse | Out-Null
                if ($t.Recurse) { Remove-Item -Path $abs -Recurse -Force -ErrorAction SilentlyContinue }
                else             { Remove-Item -Path $abs -Force -ErrorAction SilentlyContinue }
            }
        }

        # WinRE.wim — delete-then-create-empty pattern (upstream lines 212-216)
        $winreWim = Join-Path $mountDir 'Windows\System32\Recovery\winre.wim'
        if (Test-Path -LiteralPath $winreWim) {
            $recoveryDir = Join-Path $mountDir 'Windows\System32\Recovery'
            Invoke-CoreTakeown -Path $recoveryDir -Recurse | Out-Null
            Invoke-CoreIcacls  -Path $recoveryDir -Recurse | Out-Null
            Remove-Item -Path $winreWim -Force
            New-Item -Path $winreWim -ItemType File -Force | Out-Null
        }

        # Phase 8: winsxs-wipe (longest single phase, upstream lines 222-332)
        & $ProgressCallback @{ phase='winsxs-wipe'; step='Taking ownership and wiping WinSxS (slowest phase, ~5-10 min)'; percent=35 }
        Invoke-Tiny11CoreWinSxsWipe -ScratchDir $mountDir -Architecture $architecture

        # Phase 9: registry-load (upstream lines 334-339)
        & $ProgressCallback @{ phase='registry-load'; step='Loading hives'; percent=66 }
        foreach ($hive in @('COMPONENTS', 'DEFAULT', 'NTUSER', 'SOFTWARE', 'SYSTEM')) {
            Mount-Tiny11Hive -Hive $hive -ScratchDir $mountDir
        }

        try {
            $allTweaks = Get-Tiny11CoreRegistryTweaks
            $phaseMap = @{
                'bypass-sysreqs'   = @{ phase='registry-bypass';            step='Applying system-requirement bypass keys'; percent=68 }
                'sponsored-apps'   = @{ phase='registry-sponsored-apps';    step='Disabling sponsored apps + ContentDeliveryManager'; percent=71 }
                'telemetry'        = @{ phase='registry-telemetry';         step='Disabling telemetry'; percent=73 }
                'defender-disable' = @{ phase='registry-defender-disable';  step='Disabling Windows Defender services'; percent=75 }
                'update-disable'   = @{ phase='registry-update-disable';    step='Disabling Windows Update'; percent=77 }
                'misc'             = @{ phase='registry-misc';              step='BitLocker / Chat / Copilot / Teams / Outlook / etc.'; percent=79 }
            }
            foreach ($cat in @('bypass-sysreqs', 'sponsored-apps', 'telemetry', 'defender-disable', 'update-disable', 'misc')) {
                & $ProgressCallback $phaseMap[$cat]
                $catTweaks = $allTweaks | Where-Object Category -eq $cat
                foreach ($t in $catTweaks) {
                    $mountKey = "HKLM\z$($t.Hive)"
                    $fullKey  = "$mountKey\$($t.Path)"
                    if ($t.Op -eq 'add') {
                        & 'reg.exe' 'add' $fullKey '/v' $t.Name '/t' $t.Type '/d' $t.Value '/f' | Out-Null
                    } elseif ($t.Op -eq 'delete') {
                        if ($t.PSObject.Properties['Name'] -and $t.Name) {
                            & 'reg.exe' 'delete' $fullKey '/v' $t.Name '/f' | Out-Null
                        } else {
                            & 'reg.exe' 'delete' $fullKey '/f' | Out-Null
                        }
                    }
                }
            }
        }
        finally {
            & $ProgressCallback @{ phase='registry-unload'; step='Unloading hives'; percent=81 }
            foreach ($hive in @('SYSTEM', 'SOFTWARE', 'NTUSER', 'DEFAULT', 'COMPONENTS')) {
                try { Dismount-Tiny11Hive -Hive $hive } catch { Write-Warning "Failed to unload hive ${hive}: $_" }
            }
        }

        # Phase 17: scheduled-task-cleanup (upstream lines 420-438)
        & $ProgressCallback @{ phase='scheduled-task-cleanup'; step='Removing 5 scheduled task definitions'; percent=82 }
        $taskTargets = Get-Tiny11CoreScheduledTaskTargets
        foreach ($t in $taskTargets) {
            $abs = Join-Path $mountDir "Windows\System32\Tasks\$($t.RelPath)"
            if (Test-Path -LiteralPath $abs) {
                if ($t.Recurse) { Remove-Item -Path $abs -Recurse -Force -ErrorAction SilentlyContinue }
                else             { Remove-Item -Path $abs -Force -ErrorAction SilentlyContinue }
            }
        }

        # Phase 18: cleanup-image (upstream lines 478-480)
        & $ProgressCallback @{ phase='cleanup-image'; step='DISM /Cleanup-Image /StartComponentCleanup /ResetBase'; percent=84 }
        $cleanResult = Invoke-CoreDism -Arguments @('/English', "/image:$mountDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
        if ($cleanResult.ExitCode -ne 0) { throw "DISM /Cleanup-Image failed: $($cleanResult.Output)" }

        $pipelineSucceeded = $true
    }
    finally {
        # Phase 19: unmount-install (commit on success, discard on failure; upstream lines 482-483)
        $unmountFlag = if ($pipelineSucceeded) { '/Commit' } else { '/Discard' }
        & $ProgressCallback @{ phase='unmount-install'; step="Unmounting install.wim with $unmountFlag"; percent=86 }
        Invoke-CoreDism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", $unmountFlag) | Out-Null
    }

    if (-not $pipelineSucceeded) {
        throw 'Core build pipeline failed mid-flight (see preceding error). install.wim unmounted with /Discard.'
    }

    # Phase 20: export-install with /Compress:max -> install2.wim, then rename (upstream lines 484-487)
    & $ProgressCallback @{ phase='export-install'; step='Exporting install.wim with /Compress:max'; percent=89 }
    $installWim2 = Join-Path $sourceDir 'sources\install2.wim'
    Invoke-Tiny11CoreImageExport -SourceImageFile $installWim -DestinationImageFile $installWim2 -SourceIndex $ImageIndex -Compress 'max'
    Remove-Item -Path $installWim -Force
    Rename-Item -Path $installWim2 -NewName 'install.wim'

    # Phase 21: boot-wim (upstream lines 491-523)
    # Mount boot.wim index 2, apply bypass-sysreqs subset + CmdLine extra, unmount /commit
    & $ProgressCallback @{ phase='boot-wim'; step='Mounting boot.wim index 2 + applying bypass-sysreqs'; percent=93 }
    $bootWim = Join-Path $sourceDir 'sources\boot.wim'
    Invoke-CoreTakeown -Path $bootWim | Out-Null
    Invoke-CoreIcacls  -Path $bootWim | Out-Null
    Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    Invoke-CoreDism -Arguments @('/English', '/Mount-Image', "/ImageFile:$bootWim", '/Index:2', "/MountDir:$mountDir") | Out-Null
    try {
        foreach ($hive in @('COMPONENTS', 'DEFAULT', 'NTUSER', 'SOFTWARE', 'SYSTEM')) {
            Mount-Tiny11Hive -Hive $hive -ScratchDir $mountDir
        }
        try {
            # Apply only the bypass-sysreqs subset to the setup image
            $bootTweaks = Get-Tiny11CoreRegistryTweaks | Where-Object Category -eq 'bypass-sysreqs'
            foreach ($t in $bootTweaks) {
                $mountKey = "HKLM\z$($t.Hive)"
                $fullKey  = "$mountKey\$($t.Path)"
                if ($t.Op -eq 'add') {
                    & 'reg.exe' 'add' $fullKey '/v' $t.Name '/t' $t.Type '/d' $t.Value '/f' | Out-Null
                }
            }
            # Plus the setup-image-only CmdLine override (upstream tiny11Coremaker.ps1 line 514)
            & 'reg.exe' 'add' 'HKLM\zSYSTEM\Setup' '/v' 'CmdLine' '/t' 'REG_SZ' '/d' 'X:\sources\setup.exe' '/f' | Out-Null
        }
        finally {
            foreach ($hive in @('SYSTEM', 'SOFTWARE', 'NTUSER', 'DEFAULT', 'COMPONENTS')) {
                try { Dismount-Tiny11Hive -Hive $hive } catch { Write-Warning "Failed to unload hive ${hive}: $_" }
            }
        }
    }
    finally {
        Invoke-CoreDism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Commit') | Out-Null
    }

    # Phase 22: export-install-esd with /Compress:recovery, then delete install.wim (upstream lines 525-527)
    & $ProgressCallback @{ phase='export-install-esd'; step='Exporting install.esd with /Compress:recovery'; percent=96 }
    # After phase 20 rename, install.wim is the exported/compressed one
    $installWimFinal = Join-Path $sourceDir 'sources\install.wim'
    $installEsd = Join-Path $sourceDir 'sources\install.esd'
    Invoke-Tiny11CoreImageExport -SourceImageFile $installWimFinal -DestinationImageFile $installEsd -SourceIndex 1 -Compress 'recovery'
    Remove-Item -Path $installWimFinal -Force

    # Phase 23: iso-create (upstream lines 529-559)
    # Resolve oscdimg via Tiny11.Worker's Resolve-Tiny11Oscdimg helper, then invoke directly.
    # NOTE: Tiny11.Worker.psm1 does NOT expose a standalone Invoke-OscdimgIsoCreate function;
    # the oscdimg invocation is inlined inside Invoke-Tiny11BuildPipeline there. We reuse the
    # Resolve-Tiny11Oscdimg path-resolver (which is exported) and do the invocation ourselves.
    & $ProgressCallback @{ phase='iso-create'; step='Creating bootable ISO with oscdimg'; percent=98 }
    Import-Module (Join-Path $PSScriptRoot 'Tiny11.Worker.psm1') -Force
    $oscdimgCacheDir = Join-Path $ScratchDir 'oscdimg-cache'
    New-Item -ItemType Directory -Force -Path $oscdimgCacheDir | Out-Null
    $oscdimg = Resolve-Tiny11Oscdimg -CacheDir $oscdimgCacheDir
    if (-not $oscdimg -or -not (Test-Path $oscdimg)) {
        throw "oscdimg.exe could not be resolved (ADK not installed and download failed). Cannot create ISO."
    }
    & $oscdimg '-m' '-o' '-u2' '-udfver102' `
        "-bootdata:2#p0,e,b$sourceDir\boot\etfsboot.com#pEF,e,b$sourceDir\efi\microsoft\boot\efisys.bin" `
        $sourceDir $OutputIso | Out-Null

    & $ProgressCallback @{ phase='complete'; step='Build complete'; percent=100; outputPath=$OutputIso }

    # Optional source-ISO unmount (only if we mounted it — caller passes UnmountSource:$true
    # when Source is an ISO that the launcher mounted for us)
    if ($UnmountSource) {
        Import-Module (Join-Path $PSScriptRoot 'Tiny11.Iso.psm1') -Force
        try { Dismount-DiskImage -ImagePath $Source -ErrorAction SilentlyContinue } catch { }
    }
}

Export-ModuleMember -Function `
    Get-Tiny11CoreAppxPrefixes, `
    Get-Tiny11CoreSystemPackagePatterns, `
    Get-Tiny11CoreFilesystemTargets, `
    Get-Tiny11CoreScheduledTaskTargets, `
    Get-Tiny11CoreWinSxsKeepList, `
    Get-Tiny11CoreRegistryTweaks, `
    Invoke-Tiny11CoreSystemPackageRemoval, `
    Invoke-Tiny11CoreNet35Enable, `
    Invoke-Tiny11CoreImageExport, `
    Invoke-Tiny11CoreWinSxsWipe, `
    Invoke-Tiny11CoreBuildPipeline
