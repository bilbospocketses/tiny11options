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
}

Describe "Real catalog file" {
    It "loads catalog/catalog.json without errors" {
        $catPath = "$PSScriptRoot/../catalog/catalog.json"
        $cat = Get-Tiny11Catalog -Path $catPath
        $cat.Items.Count | Should -BeGreaterThan 0
    }
}
