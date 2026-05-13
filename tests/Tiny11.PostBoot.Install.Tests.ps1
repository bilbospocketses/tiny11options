Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $script:srcDir 'Tiny11.Actions.psm1')   -Force -DisableNameChecking
    Import-Module (Join-Path $script:srcDir 'Tiny11.PostBoot.psm1')  -Force -DisableNameChecking
}

Describe 'Install-Tiny11PostBootCleanup' {
    BeforeEach {
        $script:tempMount = Join-Path ([System.IO.Path]::GetTempPath()) ("postboot-install-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tempMount -Force | Out-Null
        $script:tinyCatalog = [pscustomobject]@{
            Version    = 1
            Categories = @([pscustomobject]@{ id='c'; displayName='c'; description='c' })
            Items      = @([pscustomobject]@{ id='only'; category='c'; displayName='Only'; description='only'; default='apply'; runtimeDepsOn=@(); actions=@([pscustomobject]@{ type='provisioned-appx'; packagePrefix='Only.Pkg' }) })
            Path       = 'test://catalog'
        }
        $script:tinyResolved = @{
            'only' = [pscustomobject]@{ ItemId='only'; UserState='apply'; EffectiveState='apply'; Locked=$false; LockedBy=@() }
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tempMount -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '-Enabled:$false writes nothing' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$false
        Test-Path (Join-Path $script:tempMount 'Windows\Setup\Scripts') | Should -Be $false
    }

    It '-Enabled:$true creates Windows\Setup\Scripts directory' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        Test-Path (Join-Path $script:tempMount 'Windows\Setup\Scripts') | Should -Be $true
    }

    It 'writes SetupComplete.cmd as ASCII + CRLF' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\SetupComplete.cmd'
        Test-Path $p | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($p)
        # ASCII: no byte > 127
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        # CRLF: at least one 0x0D 0x0A sequence
        $hasCrLf = $false
        for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
            if ($bytes[$i] -eq 0x0D -and $bytes[$i+1] -eq 0x0A) { $hasCrLf = $true; break }
        }
        $hasCrLf | Should -Be $true
    }

    It 'writes tiny11-cleanup.ps1 as UTF-8 + BOM' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\tiny11-cleanup.ps1'
        Test-Path $p | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($p)
        # UTF-8 BOM: EF BB BF
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'writes tiny11-cleanup.xml as UTF-16 LE + BOM' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\tiny11-cleanup.xml'
        Test-Path $p | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($p)
        # UTF-16 LE BOM: FF FE
        $bytes[0] | Should -Be 0xFF
        $bytes[1] | Should -Be 0xFE
    }

    It 'generated script contains the catalog item header' {
        Install-Tiny11PostBootCleanup -MountDir $script:tempMount -Catalog $script:tinyCatalog -ResolvedSelections $script:tinyResolved -Enabled:$true
        $p = Join-Path $script:tempMount 'Windows\Setup\Scripts\tiny11-cleanup.ps1'
        $text = [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($true))
        $text | Should -Match '# --- Item: Only \(only\) ---'
        $text | Should -Match "Remove-AppxByPackagePrefix -Prefix 'Only\.Pkg'"
    }
}
