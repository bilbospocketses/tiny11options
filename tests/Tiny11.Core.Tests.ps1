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

Describe 'Get-Tiny11CoreScheduledTaskTargets' {
    It 'returns 8 scheduled-task deletion targets' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $targets.Count | Should -Be 8
    }

    It 'includes Compatibility Appraiser, CEIP, ProgramDataUpdater, Chkdsk Proxy, QueueReporting' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $rels = $targets | ForEach-Object { $_.RelPath }
        $rels | Should -Contain 'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        $rels | Should -Contain 'Microsoft\Windows\Customer Experience Improvement Program'
        $rels | Should -Contain 'Microsoft\Windows\Application Experience\ProgramDataUpdater'
        $rels | Should -Contain 'Microsoft\Windows\Chkdsk\Proxy'
        $rels | Should -Contain 'Microsoft\Windows\Windows Error Reporting\QueueReporting'
    }

    It 'CEIP entry is marked as a folder (recurse-delete the entire folder)' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $ceip = $targets | Where-Object RelPath -eq 'Microsoft\Windows\Customer Experience Improvement Program'
        $ceip.Recurse | Should -BeTrue
    }

    It 'includes WUB-recipe WU scheduled task folders (WindowsUpdate, UpdateOrchestrator, WaaSMedic)' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $rels = $targets | ForEach-Object { $_.RelPath }
        $rels | Should -Contain 'Microsoft\Windows\WindowsUpdate'
        $rels | Should -Contain 'Microsoft\Windows\UpdateOrchestrator'
        $rels | Should -Contain 'Microsoft\Windows\WaaSMedic'
    }

    It 'WU scheduled task folders are recurse-delete (entire folder contents)' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        foreach ($folder in @('Microsoft\Windows\WindowsUpdate', 'Microsoft\Windows\UpdateOrchestrator', 'Microsoft\Windows\WaaSMedic')) {
            $entry = $targets | Where-Object RelPath -eq $folder
            $entry.Recurse | Should -BeTrue -Because "$folder must recurse-delete to catch all child tasks"
        }
    }
}

Describe 'Get-Tiny11CoreWinSxsKeepList' {
    It 'returns the amd64 keep-list (31 entries after de-duping) when -Architecture amd64' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'amd64'
        $list.Count | Should -Be 31
    }

    It 'returns the arm64 keep-list (33 entries) when -Architecture arm64' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'arm64'
        $list.Count | Should -Be 33
    }

    It 'amd64 list contains servicingstack and Manifests' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'amd64'
        $list | Should -Contain 'amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
        $list | Should -Contain 'Manifests'
    }

    It 'arm64 list contains arm64-specific servicingstack' {
        $list = Get-Tiny11CoreWinSxsKeepList -Architecture 'arm64'
        $list | Should -Contain 'arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
    }

    It 'throws on unknown architecture with helpful message' {
        { Get-Tiny11CoreWinSxsKeepList -Architecture 'mips' } |
            Should -Throw -ExpectedMessage '*architecture*mips*'
    }
}

Describe 'Get-Tiny11CoreRegistryTweaks' {
    BeforeAll {
        $script:tweaks = Get-Tiny11CoreRegistryTweaks
    }

    It 'returns at least 60 entries' {
        $script:tweaks.Count | Should -BeGreaterOrEqual 60
    }

    It 'every entry has Category, Op, Hive, Path fields' {
        foreach ($t in $script:tweaks) {
            $t.PSObject.Properties.Name | Should -Contain 'Category'
            $t.PSObject.Properties.Name | Should -Contain 'Op'
            $t.PSObject.Properties.Name | Should -Contain 'Hive'
            $t.PSObject.Properties.Name | Should -Contain 'Path'
        }
    }

    It 'every entry has a known category' {
        $known = @('bypass-sysreqs', 'sponsored-apps', 'telemetry', 'defender-disable', 'update-disable', 'ifeo-block', 'misc')
        foreach ($t in $script:tweaks) {
            $known | Should -Contain $t.Category
        }
    }

    It 'every entry has a known op' {
        $known = @('add', 'delete')
        foreach ($t in $script:tweaks) {
            $known | Should -Contain $t.Op
        }
    }

    It 'bypass-sysreqs category contains BypassTPMCheck, BypassSecureBootCheck, BypassRAMCheck' {
        $bypass = $script:tweaks | Where-Object Category -eq 'bypass-sysreqs'
        $bypass | Where-Object { $_.Name -eq 'BypassTPMCheck' } | Should -Not -BeNullOrEmpty
        $bypass | Where-Object { $_.Name -eq 'BypassSecureBootCheck' } | Should -Not -BeNullOrEmpty
        $bypass | Where-Object { $_.Name -eq 'BypassRAMCheck' } | Should -Not -BeNullOrEmpty
    }

    It 'defender-disable category contains all 5 services with Start=4' {
        $defender = $script:tweaks | Where-Object Category -eq 'defender-disable'
        $services = @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'Sense')
        foreach ($svc in $services) {
            $entry = $defender | Where-Object { $_.Path -like "*Services\$svc" -and $_.Name -eq 'Start' }
            $entry | Should -Not -BeNullOrEmpty -Because "$svc service Start=4 entry expected"
            $entry.Value | Should -Be 4
        }
    }

    It 'defender-disable SettingsPageVisibility uses ms-settings:windowsdefender token (not legacy "virus")' {
        # 2026-05-12: upstream's `hide:virus` token doesn't exist in the
        # ms-settings: URI scheme on Win11 25H2. Canonical URI for the
        # Windows Security page is `ms-settings:windowsdefender` per
        # learn.microsoft.com/en-us/windows/uwp/launch-resume/launch-settings-app
        # ("Update and security" section). This test locks in the corrected
        # token so a future "let me match upstream verbatim" pass can't
        # silently re-introduce the broken `virus`.
        $defender = $script:tweaks | Where-Object Category -eq 'defender-disable'
        $spv = $defender | Where-Object { $_.Name -eq 'SettingsPageVisibility' }
        $spv | Should -Not -BeNullOrEmpty -Because 'SettingsPageVisibility entry expected in defender-disable'
        $spv.Value | Should -Be 'hide:windowsdefender;windowsupdate'
        $spv.Value | Should -Not -Match 'virus' -Because 'legacy hide:virus token is broken on Win11 25H2'
    }

    It 'add ops have Type and Value fields; delete ops do not require Value' {
        $adds = $script:tweaks | Where-Object Op -eq 'add'
        foreach ($a in $adds) {
            $a.PSObject.Properties.Name | Should -Contain 'Type'
            $a.PSObject.Properties.Name | Should -Contain 'Value'
        }
    }

    It 'update-disable category contains WUB-recipe dosvc + InstallService entries (Start=4)' {
        $upd = $script:tweaks | Where-Object Category -eq 'update-disable'
        foreach ($svc in @('dosvc', 'InstallService')) {
            $entry = $upd | Where-Object { $_.Path -like "*Services\$svc" -and $_.Name -eq 'Start' }
            $entry | Should -Not -BeNullOrEmpty -Because "$svc service Start=4 entry expected"
            $entry.Value | Should -Be 4
        }
    }

    It 'update-disable category retains wuauserv Start=4 + deletes UsoSvc + deletes WaaSMedicSVC' {
        $upd = $script:tweaks | Where-Object Category -eq 'update-disable'
        $wu = $upd | Where-Object { $_.Path -like '*Services\wuauserv' -and $_.Name -eq 'Start' }
        $wu.Value | Should -Be 4
        ($upd | Where-Object { $_.Op -eq 'delete' -and $_.Path -like '*Services\UsoSvc' })       | Should -Not -BeNullOrEmpty
        ($upd | Where-Object { $_.Op -eq 'delete' -and $_.Path -like '*Services\WaaSMedicSVC' }) | Should -Not -BeNullOrEmpty
    }

    It 'ifeo-block category contains 13 IFEO Debugger entries' {
        $ifeo = $script:tweaks | Where-Object Category -eq 'ifeo-block'
        $ifeo.Count | Should -Be 13
    }

    It 'every ifeo-block entry sets Debugger=systray.exe under HKLM\SOFTWARE Image File Execution Options\<exe>' {
        $ifeo = $script:tweaks | Where-Object Category -eq 'ifeo-block'
        foreach ($e in $ifeo) {
            $e.Op    | Should -Be 'add'
            $e.Hive  | Should -Be 'zSOFTWARE'
            $e.Name  | Should -Be 'Debugger'
            $e.Type  | Should -Be 'REG_SZ'
            $e.Value | Should -Be 'systray.exe'
            $e.Path  | Should -Match '^Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\.+\.exe$'
        }
    }

    It 'ifeo-block category covers the 13 WUB-recipe blocked executables' {
        $ifeo = $script:tweaks | Where-Object Category -eq 'ifeo-block'
        $exes = $ifeo | ForEach-Object { ($_.Path -split '\\')[-1] }
        $expected = @(
            'WaaSMedic.exe', 'WaasMedicAgent.exe',
            'Windows10Upgrade.exe', 'Windows10UpgraderApp.exe', 'UpdateAssistant.exe',
            'UsoClient.exe', 'remsh.exe', 'EOSnotify.exe', 'SihClient.exe', 'InstallAgent.exe',
            'MusNotification.exe', 'MusNotificationUx.exe', 'MoNotificationUx.exe'
        )
        foreach ($exe in $expected) {
            $exes | Should -Contain $exe
        }
    }
}

Describe 'External-command wrapper shims' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'Invoke-CoreDism passes args to dism.exe and surfaces exit code' {
        InModuleScope 'Tiny11.Core' {
            Mock Start-CoreProcess { @{ ExitCode = 0; Output = 'mock dism output' } }
            $result = Invoke-CoreDism -Arguments @('/English', '/image:C:\mount', '/Get-WimInfo')
            Should -Invoke Start-CoreProcess -Exactly 1 -ParameterFilter {
                $FileName -eq 'dism.exe' -and
                $Arguments -contains '/English' -and
                $Arguments -contains '/image:C:\mount'
            }
            $result.ExitCode | Should -Be 0
        }
    }

    It 'Invoke-CoreTakeown passes args to takeown.exe' {
        InModuleScope 'Tiny11.Core' {
            Mock Start-CoreProcess { @{ ExitCode = 0 } }
            Invoke-CoreTakeown -Path 'C:\some\dir' -Recurse
            Should -Invoke Start-CoreProcess -Exactly 1 -ParameterFilter {
                $FileName -eq 'takeown.exe' -and
                $Arguments -contains '/F' -and
                $Arguments -contains 'C:\some\dir' -and
                $Arguments -contains '/R' -and
                $Arguments -contains '/D' -and
                $Arguments -contains 'Y'
            }
        }
    }

    It 'Invoke-CoreIcacls passes args to icacls.exe with grant Administrators:F' {
        InModuleScope 'Tiny11.Core' {
            Mock Start-CoreProcess { @{ ExitCode = 0 } }
            Invoke-CoreIcacls -Path 'C:\some\dir' -Recurse
            Should -Invoke Start-CoreProcess -Exactly 1 -ParameterFilter {
                $FileName -eq 'icacls.exe' -and
                $Arguments -contains 'C:\some\dir' -and
                $Arguments -contains '/grant' -and
                ($Arguments -join ' ') -match 'Administrators:F' -and
                $Arguments -contains '/T' -and
                $Arguments -contains '/C'
            }
        }
    }
}

Describe 'Invoke-Tiny11CoreSystemPackageRemoval' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'invokes dism /Get-Packages once and /Remove-Package once per matching package' {
        InModuleScope 'Tiny11.Core' {
            $script:dismCalls = @()
            Mock Invoke-CoreDism {
                $script:dismCalls += , @($Arguments)
                if ($Arguments -contains '/Get-Packages') {
                    # Simulate dism /Format:Table output: first whitespace-delimited token is the
                    # package identity, followed by state and release-type columns.
                    # Header row + one data row.
                    $tableOutput = "Package Identity                                                         State      Release Type`n" +
                                   "Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35~amd64~~10.0.22621.1  Installed  Foundation"
                    return @{ ExitCode = 0; Output = $tableOutput }
                }
                return @{ ExitCode = 0; Output = '' }
            }

            Invoke-Tiny11CoreSystemPackageRemoval `
                -ScratchDir 'C:\mount' `
                -Patterns @('Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35') `
                -LanguageCode 'en-US'

            # First call enumerates; second call removes the matching one
            $script:dismCalls.Count | Should -BeGreaterOrEqual 2
            ($script:dismCalls[0] -join ' ') | Should -Match '/Get-Packages'
            ($script:dismCalls[1] -join ' ') | Should -Match '/Remove-Package'
        }
    }

    It 'is non-fatal when zero packages match a pattern' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism {
                if ($Arguments -contains '/Get-Packages') {
                    return @{ ExitCode = 0; Output = '' }   # no packages reported
                }
                return @{ ExitCode = 0; Output = '' }
            }

            { Invoke-Tiny11CoreSystemPackageRemoval `
                -ScratchDir 'C:\mount' `
                -Patterns @('Definitely-Does-Not-Exist-Package~') `
                -LanguageCode 'en-US' } | Should -Not -Throw
        }
    }

    It 'is fatal when dism /Get-Packages itself fails' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism {
                if ($Arguments -contains '/Get-Packages') {
                    return @{ ExitCode = 50; Output = 'DISM error 50' }
                }
                return @{ ExitCode = 0; Output = '' }
            }

            { Invoke-Tiny11CoreSystemPackageRemoval `
                -ScratchDir 'C:\mount' `
                -Patterns @('foo') `
                -LanguageCode 'en-US' } | Should -Throw -ExpectedMessage '*Get-Packages*'
        }
    }
}

Describe 'Invoke-Tiny11CoreNet35Enable' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'does not invoke DISM when -EnableNet35:$false' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }
            Mock Test-Path { $true }

            Invoke-Tiny11CoreNet35Enable -ScratchDir 'C:\mount' -SourcePath 'C:\source\sxs' -EnableNet35:$false

            Should -Invoke Invoke-CoreDism -Times 0
        }
    }

    It 'invokes DISM /enable-feature /featurename:NetFX3 when -EnableNet35:$true and source exists' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }
            Mock Test-Path { $true }

            Invoke-Tiny11CoreNet35Enable -ScratchDir 'C:\mount' -SourcePath 'C:\source\sxs' -EnableNet35:$true

            Should -Invoke Invoke-CoreDism -Exactly 1 -ParameterFilter {
                ($Arguments -join ' ') -match '/enable-feature' -and
                ($Arguments -join ' ') -match '/featurename:NetFX3' -and
                ($Arguments -join ' ') -match '/All' -and
                ($Arguments -join ' ') -match '/source:C:\\source\\sxs'
            }
        }
    }

    It 'throws when source path is missing' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }
            Mock Test-Path { $false }

            { Invoke-Tiny11CoreNet35Enable -ScratchDir 'C:\mount' -SourcePath 'C:\source\sxs' -EnableNet35:$true } |
                Should -Throw -ExpectedMessage '*sxs*'
        }
    }
}

Describe 'Invoke-Tiny11CoreWinSxsWipe' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'orchestrates takeown -> copy retained -> delete WinSxS -> rename WinSxS_edit' {
        InModuleScope 'Tiny11.Core' {
            $script:callOrder = @()
            Mock Invoke-CoreTakeown { $script:callOrder += "takeown:$Path"; @{ ExitCode = 0 } }
            Mock Invoke-CoreIcacls  { $script:callOrder += "icacls:$Path";  @{ ExitCode = 0 } }
            Mock Get-ChildItem {
                @([pscustomobject]@{ Name = "$Filter-fake"; FullName = "$Path\$Filter-fake" })
            }
            Mock New-Item { }
            Mock Copy-Item { $script:callOrder += "copy:$Path->$Destination" }
            Mock Remove-Item { $script:callOrder += "remove:$Path" }
            Mock Rename-Item { $script:callOrder += "rename:$Path->$NewName" }

            Invoke-Tiny11CoreWinSxsWipe -ScratchDir 'C:\mount' -Architecture 'amd64'

            # Sanity: takeown happens before any copies
            $script:callOrder[0] | Should -Match '^takeown:'
            # Find the deletion of WinSxS itself (not WinSxS_edit)
            ($script:callOrder -join '|') | Should -Match 'remove:.*\\WinSxS'
            ($script:callOrder -join '|') | Should -Match 'rename:.*WinSxS_edit'
        }
    }

    It 'throws when zero keep-list patterns match (architecture mismatch)' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreTakeown { @{ ExitCode = 0 } }
            Mock Invoke-CoreIcacls  { @{ ExitCode = 0 } }
            Mock New-Item { }
            Mock Get-ChildItem { @() }   # nothing matches anywhere

            { Invoke-Tiny11CoreWinSxsWipe -ScratchDir 'C:\mount' -Architecture 'amd64' } |
                Should -Throw -ExpectedMessage '*WinSxS*amd64*'
        }
    }

    It 'uses arm64 keep-list when -Architecture arm64' {
        InModuleScope 'Tiny11.Core' {
            $script:filterCalls = @()
            Mock Invoke-CoreTakeown { @{ ExitCode = 0 } }
            Mock Invoke-CoreIcacls  { @{ ExitCode = 0 } }
            Mock New-Item { }
            Mock Get-ChildItem {
                $script:filterCalls += $Filter
                @([pscustomobject]@{ Name = "$Filter-fake"; FullName = "$Path\$Filter-fake" })
            }
            Mock Copy-Item { }
            Mock Remove-Item { }
            Mock Rename-Item { }

            Invoke-Tiny11CoreWinSxsWipe -ScratchDir 'C:\mount' -Architecture 'arm64'

            # arm64 list contains specific patterns that amd64 doesn't
            ($script:filterCalls -join '|') | Should -Match 'arm64_microsoft.vc80.crt'
            ($script:filterCalls -join '|') | Should -Not -Match '^amd64_'
        }
    }
}

Describe 'Invoke-Tiny11CoreImageExport' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'invokes DISM /Export-Image with /Compress:max' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }

            Invoke-Tiny11CoreImageExport `
                -SourceImageFile 'C:\source\install.wim' `
                -DestinationImageFile 'C:\source\install2.wim' `
                -SourceIndex 6 `
                -Compress 'max'

            Should -Invoke Invoke-CoreDism -Exactly 1 -ParameterFilter {
                ($Arguments -join ' ') -match '/Export-Image' -and
                ($Arguments -join ' ') -match '/SourceImageFile:C:\\source\\install.wim' -and
                ($Arguments -join ' ') -match '/DestinationImageFile:C:\\source\\install2.wim' -and
                ($Arguments -join ' ') -match '/SourceIndex:6' -and
                ($Arguments -join ' ') -match '/Compress:max'
            }
        }
    }

    It 'invokes DISM /Export-Image with /Compress:recovery' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }

            Invoke-Tiny11CoreImageExport `
                -SourceImageFile 'C:\source\install.wim' `
                -DestinationImageFile 'C:\source\install.esd' `
                -SourceIndex 1 `
                -Compress 'recovery'

            Should -Invoke Invoke-CoreDism -Exactly 1 -ParameterFilter {
                ($Arguments -join ' ') -match '/Compress:recovery'
            }
        }
    }

    It 'accepts /Compress:fast for FastBuild narrow-but-no-recompress' {
        # FastBuild Phase 20 uses /Compress:fast to narrow the multi-edition install.wim
        # to the user's selected index without paying the LZX cost. Without this support
        # the export call would fail with a parameter binding error and the user would
        # be prompted for an edition at install time.
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism { @{ ExitCode = 0; Output = '' } }

            Invoke-Tiny11CoreImageExport `
                -SourceImageFile 'C:\source\install.wim' `
                -DestinationImageFile 'C:\source\install2.wim' `
                -SourceIndex 6 `
                -Compress 'fast'

            Should -Invoke Invoke-CoreDism -Exactly 1 -ParameterFilter {
                ($Arguments -join ' ') -match '/Compress:fast'
            }
        }
    }

    It 'throws on DISM exit code != 0' {
        InModuleScope 'Tiny11.Core' {
            Mock Invoke-CoreDism { @{ ExitCode = 5; Output = 'mock dism error' } }

            { Invoke-Tiny11CoreImageExport `
                -SourceImageFile 'C:\src.wim' `
                -DestinationImageFile 'C:\dest.wim' `
                -SourceIndex 1 `
                -Compress 'max' } | Should -Throw -ExpectedMessage '*Export-Image*'
        }
    }
}

Describe 'New-Tiny11CorePostBootCleanupScript' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'returns a non-empty CMD script' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Not -BeNullOrEmpty
        $script.Length | Should -BeGreaterThan 100
    }

    It 'starts with @echo off' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match '^@echo off'
    }

    It 'invokes dism /online /Cleanup-Image /StartComponentCleanup /ResetBase' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'dism /online /English /Cleanup-Image /StartComponentCleanup /ResetBase'
    }

    It 'writes to %SystemDrive%\Windows\Logs\tiny11-postboot.log' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'tiny11-postboot\.log'
        $script | Should -Match 'SystemDrive'
    }

    It 'self-deletes via del /F /Q "%~f0"' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'del /F /Q "%~f0"'
    }

    It 'creates the Logs directory if missing' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'mkdir "%SystemDrive%\\Windows\\Logs"'
    }

    It 'disables wuauserv via sc config start= disabled' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'sc config wuauserv\s+start= disabled'
    }

    It 'disables UsoSvc (Update Session Orchestrator) via sc config' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'sc config UsoSvc\s+start= disabled'
    }

    It 'disables WaaSMedicSvc (Windows-As-A-Service healing) via sc config' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'sc config WaaSMedicSvc\s+start= disabled'
    }

    It 'stops the three WU-related services immediately (defense in depth alongside sc config)' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'sc stop\s+wuauserv'
        $script | Should -Match 'sc stop\s+UsoSvc'
        $script | Should -Match 'sc stop\s+WaaSMedicSvc'
    }

    It 'redundantly writes wuauserv Start=4 to the registry as a second mechanism' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'reg add "HKLM\\SYSTEM\\CurrentControlSet\\Services\\wuauserv" /v Start /t REG_DWORD /d 4 /f'
    }

    It 'verifies the resolved wuauserv state via sc qc for the next-iteration diagnostic' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'sc qc wuauserv'
    }

    It 'registers the Keep-WU-Disabled scheduled task via schtasks /create /xml' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'schtasks /create /xml ".*tiny11-wu-enforce\.xml" /tn "tiny11options\\Keep WU Disabled" /f'
    }

    It 'runs tiny11-wu-enforce.ps1 once immediately after registering the task' {
        $script = New-Tiny11CorePostBootCleanupScript
        $script | Should -Match 'powershell\.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ".*tiny11-wu-enforce\.ps1"'
    }
}

Describe 'New-Tiny11CoreWuEnforceScript' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'returns a non-empty PowerShell script' {
        $s = New-Tiny11CoreWuEnforceScript
        $s | Should -Not -BeNullOrEmpty
        $s.Length | Should -BeGreaterThan 500
    }

    It 'sets up the log path at %SystemDrive%\Windows\Logs\tiny11-wu-enforce.log' {
        $s = New-Tiny11CoreWuEnforceScript
        $s | Should -Match '\$env:SystemDrive\\Windows\\Logs\\tiny11-wu-enforce\.log'
    }

    It 'iterates the 5 WU-related services with their target Start values' {
        $s = New-Tiny11CoreWuEnforceScript
        foreach ($svc in @('wuauserv','dosvc','WaaSMedicSvc','UsoSvc','InstallService')) {
            $s | Should -Match "'$svc'"
        }
    }

    It 'sets UsoSvc to Manual (3) per WUB recipe, others to Disabled (4)' {
        $s = New-Tiny11CoreWuEnforceScript
        # Hashtable shape -- UsoSvc should map to 3
        $s | Should -Match "'UsoSvc'\s*=\s*3"
        $s | Should -Match "'wuauserv'\s*=\s*4"
    }

    It 'iterates the 3 WU scheduled-task folders for removal' {
        $s = New-Tiny11CoreWuEnforceScript
        foreach ($folder in @('Microsoft\\Windows\\WindowsUpdate', 'Microsoft\\Windows\\UpdateOrchestrator', 'Microsoft\\Windows\\WaaSMedic')) {
            $s | Should -Match $folder
        }
    }

    It 'enforces IFEO Debugger=systray.exe for the 13 WU repair binaries' {
        $s = New-Tiny11CoreWuEnforceScript
        foreach ($exe in @('WaaSMedic.exe','WaasMedicAgent.exe','Windows10Upgrade.exe','UsoClient.exe','MusNotification.exe')) {
            $s | Should -Match $exe
        }
        $s | Should -Match "'systray\.exe'"
        $s | Should -Match 'Image File Execution Options'
    }

    It 'includes process-kill safety net for WU repair processes' {
        $s = New-Tiny11CoreWuEnforceScript
        foreach ($proc in @('WaaSMedic','WaasMedicAgent','MusNotification','MoUsoCoreWorker','UsoClient')) {
            $s | Should -Match $proc
        }
        $s | Should -Match 'Stop-Process'
    }

    It 'is idempotent -- every correction path has a "Start=N already" or "Debugger=systray.exe already" fast-path' {
        $s = New-Tiny11CoreWuEnforceScript
        $s | Should -Match 'Start=\$expected already'
        $s | Should -Match 'Debugger=systray\.exe already'
    }

    It 'logs every correction with before/after via Write-EnforceLog CORRECTED' {
        $s = New-Tiny11CoreWuEnforceScript
        $s | Should -Match 'Start CORRECTED:'
        $s | Should -Match 'Debugger CORRECTED:'
    }

    It 'defines a .log.1 backup path for rotation' {
        $s = New-Tiny11CoreWuEnforceScript
        $s | Should -Match 'tiny11-wu-enforce\.log\.1'
    }

    It 'rotates the active log to .log.1 when line count reaches 5000' {
        $s = New-Tiny11CoreWuEnforceScript
        $s | Should -Match '\$lineCount -ge 5000'
        $s | Should -Match 'Move-Item.+logPath.+logPathBackup'
    }

    It 'drops the prior backup before rotating (caps at 2 files)' {
        $s = New-Tiny11CoreWuEnforceScript
        $s | Should -Match 'Remove-Item.+\$logPathBackup.+SilentlyContinue'
    }

    It 'swallows rotation failures so enforcement still proceeds' {
        $s = New-Tiny11CoreWuEnforceScript
        # The rotation block is wrapped in try/catch; the catch body is empty (best-effort).
        $s | Should -Match "try \{[\s\S]+lineCount[\s\S]+\} catch \{"
    }
}

Describe 'New-Tiny11CoreWuEnforceTaskXml' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    It 'returns well-formed XML parseable by .NET' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Not -BeNullOrEmpty
        # Parse via [xml] -- throws on malformed
        $parsed = [xml]$xml
        $parsed | Should -Not -BeNullOrEmpty
    }

    It 'declares UTF-16 encoding (Task Scheduler convention)' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<\?xml version="1\.0" encoding="UTF-16"\?>'
    }

    It 'uses Task Scheduler 2.0 namespace + version 1.4' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match 'xmlns="http://schemas\.microsoft\.com/windows/2004/02/mit/task"'
        $xml | Should -Match 'version="1\.4"'
    }

    It 'declares Author=tiny11options and the URI matches the registered task path' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<Author>tiny11options</Author>'
        $xml | Should -Match '<URI>\\tiny11options\\Keep WU Disabled</URI>'
    }

    It 'has BootTrigger with PT2M delay' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<BootTrigger>'
        $xml | Should -Match '<Delay>PT2M</Delay>'
    }

    It 'has daily CalendarTrigger at 03:00' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<CalendarTrigger>'
        $xml | Should -Match 'T03:00:00'
        $xml | Should -Match '<DaysInterval>1</DaysInterval>'
    }

    It 'has EventTrigger subscribing to WindowsUpdateClient/Operational event ID 19' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<EventTrigger>'
        $xml | Should -Match 'Microsoft-Windows-WindowsUpdateClient/Operational'
        $xml | Should -Match 'EventID=19'
    }

    It 'has EventTrigger subscribing to Service Control Manager event ID 7040 (start type change)' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match "Provider\[@Name='Service Control Manager'\]"
        $xml | Should -Match 'EventID=7040'
        $xml | Should -Match 'Path="System"'
    }

    It 'has 5 trigger nodes total (BootTrigger + TimeTrigger + CalendarTrigger + 2 EventTriggers)' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $parsed = [xml]$xml
        $triggerCount = $parsed.Task.Triggers.ChildNodes.Count
        $triggerCount | Should -Be 5
    }

    It 'has TimeTrigger with PT1M Repetition Interval (proven enforcement mechanism)' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<TimeTrigger>'
        $xml | Should -Match '<Interval>PT1M</Interval>'
        $xml | Should -Match '<StopAtDurationEnd>false</StopAtDurationEnd>'
    }

    # Regression guard for the 2026-05-11 task-registration bug. The original
    # TimeTrigger placed <Repetition> before <StartBoundary>/<Enabled> and included
    # a magic-number <Duration> alongside StopAtDurationEnd=false. Either of those
    # can make schtasks /create /xml reject the WHOLE task (not just the trigger),
    # silently leaving \tiny11options\ unregistered post-install.
    It 'TimeTrigger has canonical element order (StartBoundary, Enabled, Repetition) and no Duration' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $parsed = [xml]$xml
        $ns = New-Object System.Xml.XmlNamespaceManager($parsed.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

        $timeTrigger = $parsed.SelectSingleNode('//t:TimeTrigger', $ns)
        $timeTrigger | Should -Not -BeNullOrEmpty

        $childOrder = @($timeTrigger.ChildNodes | ForEach-Object { $_.LocalName })
        $startBoundaryIdx = $childOrder.IndexOf('StartBoundary')
        $enabledIdx       = $childOrder.IndexOf('Enabled')
        $repetitionIdx    = $childOrder.IndexOf('Repetition')

        $startBoundaryIdx | Should -BeGreaterOrEqual 0
        $enabledIdx       | Should -BeGreaterOrEqual 0
        $repetitionIdx    | Should -BeGreaterOrEqual 0
        $startBoundaryIdx | Should -BeLessThan $repetitionIdx
        $enabledIdx       | Should -BeLessThan $repetitionIdx

        $repetition = $timeTrigger.SelectSingleNode('t:Repetition', $ns)
        $repetition.SelectSingleNode('t:Duration', $ns) | Should -BeNullOrEmpty
        $repetition.SelectSingleNode('t:Interval', $ns).InnerText           | Should -Be 'PT1M'
        $repetition.SelectSingleNode('t:StopAtDurationEnd', $ns).InnerText  | Should -Be 'false'
    }

    It 'runs as SYSTEM (S-1-5-18) with HighestAvailable privilege' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<UserId>S-1-5-18</UserId>'
        $xml | Should -Match '<RunLevel>HighestAvailable</RunLevel>'
    }

    It 'Action invokes powershell.exe -File against tiny11-wu-enforce.ps1' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<Command>powershell\.exe</Command>'
        $xml | Should -Match '-NoProfile'
        $xml | Should -Match 'tiny11-wu-enforce\.ps1'
    }

    It 'allows running on batteries + when network is unavailable (kiosk + offline OK)' {
        $xml = New-Tiny11CoreWuEnforceTaskXml
        $xml | Should -Match '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        $xml | Should -Match '<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>'
    }
}

Describe 'Install-Tiny11CorePostBootCleanup' {
    BeforeAll {
        $script:modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $script:modulePath -Force
    }

    Context 'fresh mount with no Setup\Scripts directory' {
        BeforeEach {
            $script:mountDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tiny11-postboot-test-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:mountDir -Force | Out-Null
        }
        AfterEach {
            if (Test-Path -LiteralPath $script:mountDir) {
                Remove-Item -LiteralPath $script:mountDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'creates Windows\Setup\Scripts and writes all 3 post-boot artifacts' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $cmd = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            $ps1 = Join-Path $script:mountDir 'Windows\Setup\Scripts\tiny11-wu-enforce.ps1'
            $xml = Join-Path $script:mountDir 'Windows\Setup\Scripts\tiny11-wu-enforce.xml'
            Test-Path -LiteralPath $cmd | Should -Be $true
            Test-Path -LiteralPath $ps1 | Should -Be $true
            Test-Path -LiteralPath $xml | Should -Be $true
        }

        It 'writes the SetupComplete.cmd content from New-Tiny11CorePostBootCleanupScript' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            $content = Get-Content -LiteralPath $expected -Raw
            $content | Should -Match 'dism /online /English /Cleanup-Image /StartComponentCleanup /ResetBase'
            $content | Should -Match '@echo off'
        }

        It 'writes the tiny11-wu-enforce.ps1 content from New-Tiny11CoreWuEnforceScript' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\tiny11-wu-enforce.ps1'
            $content = Get-Content -LiteralPath $expected -Raw
            $content | Should -Match 'tiny11-wu-enforce triggered'
            $content | Should -Match 'Image File Execution Options'
        }

        It 'writes the tiny11-wu-enforce.xml content from New-Tiny11CoreWuEnforceTaskXml' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\tiny11-wu-enforce.xml'
            $content = Get-Content -LiteralPath $expected -Raw
            $content | Should -Match 'tiny11options'
            $content | Should -Match 'BootTrigger'
        }

        It 'SetupComplete.cmd is ASCII (no UTF-8 BOM) for cmd.exe compatibility' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            $bytes = [System.IO.File]::ReadAllBytes($expected)
            $bytes[0] | Should -Not -Be 0xEF
        }

        It 'SetupComplete.cmd uses CRLF line endings' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            $bytes = [System.IO.File]::ReadAllBytes($expected)
            $hasCRLF = $false
            for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
                if ($bytes[$i] -eq 0x0D -and $bytes[$i+1] -eq 0x0A) { $hasCRLF = $true; break }
            }
            $hasCRLF | Should -Be $true
        }

        It 'tiny11-wu-enforce.ps1 is UTF-8 with BOM (PS 5.1 reads BOM-less as Windows-1252)' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\tiny11-wu-enforce.ps1'
            $bytes = [System.IO.File]::ReadAllBytes($expected)
            $bytes[0] | Should -Be 0xEF
            $bytes[1] | Should -Be 0xBB
            $bytes[2] | Should -Be 0xBF
        }

        It 'tiny11-wu-enforce.xml is UTF-16 LE with BOM (Task Scheduler convention)' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\tiny11-wu-enforce.xml'
            $bytes = [System.IO.File]::ReadAllBytes($expected)
            $bytes[0] | Should -Be 0xFF
            $bytes[1] | Should -Be 0xFE
        }
    }

    Context 'mount with existing Setup\Scripts directory' {
        BeforeEach {
            $script:mountDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tiny11-postboot-test-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path (Join-Path $script:mountDir 'Windows\Setup\Scripts') -Force | Out-Null
        }
        AfterEach {
            if (Test-Path -LiteralPath $script:mountDir) {
                Remove-Item -LiteralPath $script:mountDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'overwrites without erroring' {
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            Set-Content -LiteralPath $expected -Value 'dummy prior content' -Force
            { Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir } | Should -Not -Throw
            $content = Get-Content -LiteralPath $expected -Raw
            $content | Should -Not -Match 'dummy prior content'
            $content | Should -Match 'tiny11options'
        }
    }
}

Describe 'New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration' {
    BeforeAll {
        $modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Tiny11.Core.psm1')).Path
        Import-Module $modulePath -Force
    }

    It 'without the switch: ONE schtasks /create line (Keep WU Disabled only)' {
        $cmd = New-Tiny11CorePostBootCleanupScript
        ([regex]::Matches($cmd, 'schtasks /create /xml')).Count | Should -Be 1
        $cmd | Should -Match '/tn "tiny11options\\Keep WU Disabled"'
        $cmd | Should -Not -Match '/tn "tiny11options\\Post-Boot Cleanup"'
    }

    It 'with -IncludePostBootCleanupRegistration: TWO schtasks /create lines' {
        $cmd = New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration
        ([regex]::Matches($cmd, 'schtasks /create /xml')).Count | Should -Be 2
        $cmd | Should -Match '/tn "tiny11options\\Keep WU Disabled"'
        $cmd | Should -Match '/tn "tiny11options\\Post-Boot Cleanup"'
    }

    It 'both variants still self-delete' {
        (New-Tiny11CorePostBootCleanupScript)                                  | Should -Match 'del /F /Q "%~f0"'
        (New-Tiny11CorePostBootCleanupScript -IncludePostBootCleanupRegistration) | Should -Match 'del /F /Q "%~f0"'
    }
}
