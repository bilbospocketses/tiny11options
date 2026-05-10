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
    It 'returns 5 scheduled-task deletion targets' {
        $targets = Get-Tiny11CoreScheduledTaskTargets
        $targets.Count | Should -Be 5
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
        $known = @('bypass-sysreqs', 'sponsored-apps', 'telemetry', 'defender-disable', 'update-disable', 'misc')
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

    It 'add ops have Type and Value fields; delete ops do not require Value' {
        $adds = $script:tweaks | Where-Object Op -eq 'add'
        foreach ($a in $adds) {
            $a.PSObject.Properties.Name | Should -Contain 'Type'
            $a.PSObject.Properties.Name | Should -Contain 'Value'
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

        It 'creates Windows\Setup\Scripts and writes SetupComplete.cmd' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            Test-Path -LiteralPath $expected | Should -Be $true
        }

        It 'writes the script content from New-Tiny11CorePostBootCleanupScript' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            $content = Get-Content -LiteralPath $expected -Raw
            $content | Should -Match 'dism /online /English /Cleanup-Image /StartComponentCleanup /ResetBase'
            $content | Should -Match '@echo off'
        }

        It 'writes ASCII (no UTF-8 BOM) for cmd.exe compatibility' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            $bytes = [System.IO.File]::ReadAllBytes($expected)
            # UTF-8 BOM is EF BB BF; ASCII files don't start with that.
            $bytes[0] | Should -Not -Be 0xEF
        }

        It 'writes CRLF line endings' {
            Install-Tiny11CorePostBootCleanup -MountDir $script:mountDir
            $expected = Join-Path $script:mountDir 'Windows\Setup\Scripts\SetupComplete.cmd'
            $bytes = [System.IO.File]::ReadAllBytes($expected)
            # Find a CR (0x0D) byte; if present and followed by LF (0x0A), CRLF is being used.
            $hasCRLF = $false
            for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
                if ($bytes[$i] -eq 0x0D -and $bytes[$i+1] -eq 0x0A) { $hasCRLF = $true; break }
            }
            $hasCRLF | Should -Be $true
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
