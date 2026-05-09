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

Export-ModuleMember -Function Get-Tiny11CoreAppxPrefixes, Get-Tiny11CoreSystemPackagePatterns
