Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Tests for Get-Tiny11CoreLanguageCodeFromDismIntl (L1, v1.0.3 cycle).
# Verifies that the BCP-47 regex captures the locale tag from `dism /Get-Intl`
# output across the language codes Windows 11 actually ships. Pre-L1 the regex
# was `[a-zA-Z]{2}-[a-zA-Z]{2}` and silently fell back to en-US for any tag
# longer than 5 characters -- most notably `sr-Latn-RS` (Serbian Latin).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.Core.psm1') -Force -DisableNameChecking
}

Describe 'Get-Tiny11CoreLanguageCodeFromDismIntl' {
    Context 'standard 5-char xx-XX locale tags (Windows 11 Language Packs)' {
        It 'captures <Tag>' -ForEach @(
            @{ Tag = 'en-US' }, @{ Tag = 'en-GB' }, @{ Tag = 'de-DE' }, @{ Tag = 'fr-FR' }
            @{ Tag = 'fr-CA' }, @{ Tag = 'es-ES' }, @{ Tag = 'es-MX' }, @{ Tag = 'it-IT' }
            @{ Tag = 'ja-JP' }, @{ Tag = 'ko-KR' }, @{ Tag = 'pt-BR' }, @{ Tag = 'pt-PT' }
            @{ Tag = 'ru-RU' }, @{ Tag = 'pl-PL' }, @{ Tag = 'tr-TR' }, @{ Tag = 'nl-NL' }
            @{ Tag = 'sv-SE' }, @{ Tag = 'nb-NO' }, @{ Tag = 'th-TH' }, @{ Tag = 'cs-CZ' }
            @{ Tag = 'hu-HU' }, @{ Tag = 'uk-UA' }, @{ Tag = 'zh-CN' }, @{ Tag = 'zh-TW' }
            @{ Tag = 'zh-HK' }, @{ Tag = 'he-IL' }, @{ Tag = 'ar-SA' }, @{ Tag = 'el-GR' }
        ) {
            $sample = "Deployment Image Servicing and Management tool`nVersion: 10.0.26100.1150`n`nImage Version: 10.0.26100.2454`n`nDefault system UI language : $Tag`nThe UI language fallback list is:`nen-US`n"
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $sample | Should -Be $Tag
        }
    }

    Context 'longer BCP-47 tags (L1 closes the legacy regex gap)' {
        It 'captures Serbian Latin <Tag> (the primary L1 motivator)' -ForEach @(
            @{ Tag = 'sr-Latn-RS' }   # current
            @{ Tag = 'sr-Latn-CS' }   # deprecated alias still seen in older 23H2 images
        ) {
            $sample = "Default system UI language : $Tag`n"
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $sample | Should -Be $Tag
        }
        It 'captures additional longer tags Microsoft uses elsewhere: <Tag>' -ForEach @(
            @{ Tag = 'az-Latn-AZ' }       # Azerbaijani Latin (LIP today but defensive)
            @{ Tag = 'bs-Latn-BA' }       # Bosnian Latin
            @{ Tag = 'uz-Latn-UZ' }       # Uzbek Latin
            @{ Tag = 'fil-PH' }           # Filipino (3-letter language)
            @{ Tag = 'chr-CHER-US' }      # Cherokee (3-letter language + script + region)
            @{ Tag = 'quc-Latn-GT' }      # K'iche'
            @{ Tag = 'ca-ES-valencia' }   # Valencian (variant subtag)
            @{ Tag = 'pa-Arab-PK' }       # Punjabi Arabic
            @{ Tag = 'sd-Arab-PK' }       # Sindhi Arabic
        ) {
            $sample = "Default system UI language : $Tag`n"
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $sample | Should -Be $Tag
        }
    }

    Context 'fallback behaviour' {
        It 'returns en-US when the marker line is absent' {
            $output = "Deployment Image Servicing and Management tool`nVersion: 10.0.26100.1150`nNo Intl info here.`n"
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $output | Should -Be 'en-US'
        }
        It 'returns en-US for empty output' {
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput '' | Should -Be 'en-US'
        }
        It 'returns en-US when DISM emits the marker with no value (malformed)' {
            $output = "Default system UI language : `n"
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $output | Should -Be 'en-US'
        }
    }

    Context 'tolerates whitespace variations around the colon' {
        It 'no-space form: "Default system UI language:de-DE"' {
            $output = "Default system UI language:de-DE`n"
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $output | Should -Be 'de-DE'
        }
        It 'extra-space form: "Default system UI language   :   ja-JP"' {
            $output = "Default system UI language   :   ja-JP`n"
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $output | Should -Be 'ja-JP'
        }
    }

    Context 'real-world DISM /Get-Intl output structure' {
        It 'extracts only the Default system UI language, not the fallback list entries' {
            # DISM prints a "UI language fallback list" below the default-language line.
            # Pre-L1 regex would also match en-US in the fallback list; locking that the
            # captured value is the DEFAULT, not a fallback.
            $output = @'
Deployment Image Servicing and Management tool
Version: 10.0.26100.1150

Image Version: 10.0.26100.2454

Default system UI language : de-DE
The UI language fallback list is:
en-US

System locale : de-DE
Default time zone : Pacific Standard Time
'@
            Get-Tiny11CoreLanguageCodeFromDismIntl -DismIntlOutput $output | Should -Be 'de-DE'
        }
    }
}
