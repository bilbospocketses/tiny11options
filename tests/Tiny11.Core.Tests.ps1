Describe 'Get-Tiny11CoreAppxPrefixes' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'returns 32 hardcoded provisioned-appx package prefixes' {
        $prefixes = Get-Tiny11CoreAppxPrefixes
        $prefixes.Count | Should -Be 32
    }

    It 'contains known consumer-app entries' {
        $prefixes = Get-Tiny11CoreAppxPrefixes
        $prefixes | Should -Contain 'Microsoft.BingNews_'
        $prefixes | Should -Contain 'Microsoft.BingWeather_'
        $prefixes | Should -Contain 'Microsoft.YourPhone_'
        $prefixes | Should -Contain 'Microsoft.ZuneMusic_'
    }

    It 'contains current-Win11 cruft (Copilot, Teams, Outlook)' {
        $prefixes = Get-Tiny11CoreAppxPrefixes
        $prefixes | Should -Contain 'Microsoft.Copilot_'
        $prefixes | Should -Contain 'MSTeams_'
        $prefixes | Should -Contain 'Microsoft.OutlookForWindows_'
    }
}

Describe 'Get-Tiny11CoreSystemPackagePatterns' {
    It 'returns 12 entries for any language code' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'en-US'
        $patterns.Count | Should -Be 12
    }

    It 'substitutes language code into LanguageFeatures templates' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'en-US'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-Handwriting-en-US-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-OCR-en-US-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-Speech-en-US-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-TextToSpeech-en-US-Package~31bf3856ad364e35'
    }

    It 'substitutes a different language code correctly' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'de-DE'
        $patterns | Should -Contain 'Microsoft-Windows-LanguageFeatures-Handwriting-de-DE-Package~31bf3856ad364e35'
        $patterns | Should -Not -Contain 'Microsoft-Windows-LanguageFeatures-Handwriting-en-US-Package~31bf3856ad364e35'
    }

    It 'passes through non-templated entries unchanged' {
        $patterns = Get-Tiny11CoreSystemPackagePatterns -LanguageCode 'en-US'
        $patterns | Should -Contain 'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35'
        $patterns | Should -Contain 'Windows-Defender-Client-Package~31bf3856ad364e35~'
    }
}

Describe 'Get-Tiny11CoreFilesystemTargets' {
    It 'returns 5 filesystem deletion targets' {
        $targets = Get-Tiny11CoreFilesystemTargets
        $targets.Count | Should -Be 5
    }

    It 'includes Edge, EdgeUpdate, EdgeCore, OneDriveSetup, Microsoft-Edge-Webview' {
        $targets = Get-Tiny11CoreFilesystemTargets
        $rels = $targets | ForEach-Object { $_.RelPath }
        $rels | Should -Contain 'Program Files (x86)\Microsoft\Edge'
        $rels | Should -Contain 'Program Files (x86)\Microsoft\EdgeUpdate'
        $rels | Should -Contain 'Program Files (x86)\Microsoft\EdgeCore'
        $rels | Should -Contain 'Windows\System32\OneDriveSetup.exe'
        $rels | Should -Contain 'Windows\System32\Microsoft-Edge-Webview'
    }

    It 'every target has RelPath and Recurse fields' {
        $targets = Get-Tiny11CoreFilesystemTargets
        foreach ($t in $targets) {
            $t.PSObject.Properties.Name | Should -Contain 'RelPath'
            $t.PSObject.Properties.Name | Should -Contain 'Recurse'
        }
    }
}
