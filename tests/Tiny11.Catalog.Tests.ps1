Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Catalog'

Describe "Get-Tiny11Catalog" {
    BeforeAll  { $script:tmp = New-TempScratchDir }
    AfterAll   { Remove-TempScratchDir -Path $script:tmp }

    It "loads a minimal valid catalog" {
        $path = Join-Path $script:tmp 'catalog.json'
        Set-Content -Path $path -Value '{"version":1,"categories":[],"items":[]}' -Encoding UTF8
        $cat = Get-Tiny11Catalog -Path $path
        $cat.Version | Should -Be 1
        $cat.Categories.Count | Should -Be 0
        $cat.Items.Count | Should -Be 0
    }

    It "throws on missing version field" {
        $path = Join-Path $script:tmp 'bad.json'
        Set-Content -Path $path -Value '{"categories":[],"items":[]}' -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*version*"
    }

    It "throws on unknown action type" {
        $path = Join-Path $script:tmp 'badaction.json'
        $catalog = @{
            version = 1
            categories = @(@{ id='c1'; displayName='C1'; description='' })
            items = @(@{
                id='item1'; category='c1'; displayName='I1'; description='';
                default='apply'; runtimeDepsOn=@();
                actions=@(@{ type='invalid-type' })
            })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $path -Value $catalog -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*invalid-type*"
    }

    It "throws when item references unknown category" {
        $path = Join-Path $script:tmp 'badcat.json'
        $catalog = @{
            version = 1; categories = @()
            items = @(@{
                id='i1'; category='nonexistent'; displayName='X'; description='';
                default='apply'; runtimeDepsOn=@(); actions=@()
            })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $path -Value $catalog -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*category*nonexistent*"
    }

    It "throws when runtimeDepsOn references unknown item id" {
        $path = Join-Path $script:tmp 'baddeps.json'
        $catalog = @{
            version = 1
            categories = @(@{ id='c1'; displayName='C1'; description='' })
            items = @(@{
                id='i1'; category='c1'; displayName='X'; description='';
                default='apply'; runtimeDepsOn=@('ghost'); actions=@()
            })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $path -Value $catalog -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*ghost*"
    }

    It "throws when version is unsupported (e.g. 2)" {
        $path = Join-Path $script:tmp 'badversion.json'
        Set-Content -Path $path -Value '{"version":2,"categories":[],"items":[]}' -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*version*2*"
    }

    It "throws when item default is invalid (e.g. 'maybe')" {
        $path = Join-Path $script:tmp 'baddefault.json'
        $catalog = @{
            version = 1
            categories = @(@{ id='c1'; displayName='C1'; description='' })
            items = @(@{
                id='i1'; category='c1'; displayName='X'; description='';
                default='maybe'; runtimeDepsOn=@(); actions=@()
            })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $path -Value $catalog -Encoding UTF8
        { Get-Tiny11Catalog -Path $path } | Should -Throw "*default*maybe*"
    }
}

Describe "Real catalog file" {
    It "loads catalog/catalog.json without errors" {
        $catPath = "$PSScriptRoot/../catalog/catalog.json"
        $cat = Get-Tiny11Catalog -Path $catPath
        $cat.Items.Count | Should -BeGreaterThan 0
    }
}

Describe "Catalog completeness" {
    BeforeAll { $script:cat = Get-Tiny11Catalog -Path "$PSScriptRoot/../catalog/catalog.json" }
    It "has the expected 10 categories" {
        $expected = @('store-apps','xbox-and-gaming','communication','edge-and-webview','onedrive','telemetry','sponsored','copilot-ai','hardware-bypass','oobe')
        ($script:cat.Categories | ForEach-Object id) | Should -Be $expected
    }
    It "covers every package prefix from the legacy script" {
        $legacyPrefixes = @(
            'AppUp.IntelManagementandSecurityStatus','Clipchamp.Clipchamp','DolbyLaboratories.DolbyAccess',
            'DolbyLaboratories.DolbyDigitalPlusDecoderOEM','Microsoft.BingNews','Microsoft.BingSearch',
            'Microsoft.BingWeather','Microsoft.Copilot','Microsoft.Windows.CrossDevice','Microsoft.GamingApp',
            'Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.Microsoft3DViewer','Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftStickyNotes','Microsoft.MixedReality.Portal',
            'Microsoft.MSPaint','Microsoft.Office.OneNote','Microsoft.OfficePushNotificationUtility',
            'Microsoft.OutlookForWindows','Microsoft.Paint','Microsoft.People','Microsoft.PowerAutomateDesktop',
            'Microsoft.SkypeApp','Microsoft.StartExperiencesApp','Microsoft.Todos','Microsoft.Wallet',
            'Microsoft.Windows.DevHome','Microsoft.Windows.Copilot','Microsoft.Windows.Teams',
            'Microsoft.WindowsAlarms','Microsoft.WindowsCamera','microsoft.windowscommunicationsapps',
            'Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.WindowsSoundRecorder',
            'Microsoft.WindowsTerminal','Microsoft.Xbox.TCUI','Microsoft.XboxApp','Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay','Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay',
            'Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
            'MicrosoftCorporationII.MicrosoftFamily','MicrosoftCorporationII.QuickAssist',
            'MSTeams','MicrosoftTeams','Microsoft.549981C3F5F10'
        )
        $catalogPrefixes = @()
        foreach ($item in $script:cat.Items) {
            foreach ($a in $item.actions) {
                if ($a.type -eq 'provisioned-appx') { $catalogPrefixes += $a.packagePrefix }
            }
        }
        foreach ($legacy in $legacyPrefixes) {
            $catalogPrefixes | Should -Contain $legacy
        }
    }
}
