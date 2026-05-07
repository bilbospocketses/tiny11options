Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Worker'

Describe "Get-Tiny11ApplyItems" {
    It "returns only items with EffectiveState=apply" {
        $resolved = @{
            'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' }
            'b' = [pscustomobject]@{ ItemId='b'; EffectiveState='skip' }
            'c' = [pscustomobject]@{ ItemId='c'; EffectiveState='apply' }
        }
        $catalog = [pscustomobject]@{ Items = @( @{ id='a'; actions=@() }, @{ id='b'; actions=@() }, @{ id='c'; actions=@() } ) }
        $items = Get-Tiny11ApplyItems -Catalog $catalog -ResolvedSelections $resolved
        $items.Count | Should -Be 2
        $items[0].id | Should -Be 'a'; $items[1].id | Should -Be 'c'
    }
}

Describe "Invoke-Tiny11ApplyActions" {
    BeforeEach { Mock -CommandName 'Invoke-Tiny11Action' -MockWith { } -ModuleName 'Tiny11.Worker' }
    It "calls dispatcher once per action across apply items" {
        $catalog = [pscustomobject]@{
            Items = @(
                @{ id='a'; actions=@(@{type='registry'; op='set'; hive='SOFTWARE'; key='K1'; name='N'; valueType='REG_DWORD'; value='0'}) }
                @{ id='b'; actions=@(@{type='filesystem'; op='remove'; path='X'; recurse=$false}, @{type='filesystem'; op='remove'; path='Y'; recurse=$false}) }
            )
        }
        $resolved = @{ 'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' }; 'b' = [pscustomobject]@{ ItemId='b'; EffectiveState='apply' } }
        Invoke-Tiny11ApplyActions -Catalog $catalog -ResolvedSelections $resolved -ScratchDir 'C:\s' -ProgressCallback {}
        Should -Invoke -CommandName 'Invoke-Tiny11Action' -ModuleName 'Tiny11.Worker' -Times 3
    }
    It "invokes the progress callback per item" {
        $catalog = [pscustomobject]@{ Items = @(@{ id='a'; actions=@() }) }
        $resolved = @{ 'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' } }
        $script:calls = 0
        Invoke-Tiny11ApplyActions -Catalog $catalog -ResolvedSelections $resolved -ScratchDir 'C:\s' -ProgressCallback { $script:calls++ }
        $script:calls | Should -BeGreaterThan 0
    }
}
