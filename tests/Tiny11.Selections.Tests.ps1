Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Catalog'
Import-Tiny11Module -Name 'Tiny11.Selections'

Describe "New-Tiny11Selections" {
    BeforeAll {
        $script:catalog = [pscustomobject]@{
            Version = 1
            Categories = @(@{ id='c1'; displayName='C1'; description='' })
            Items = @(
                @{ id='a'; category='c1'; displayName='A'; default='apply'; runtimeDepsOn=@(); actions=@() },
                @{ id='b'; category='c1'; displayName='B'; default='skip';  runtimeDepsOn=@(); actions=@() },
                @{ id='c'; category='c1'; displayName='C'; default='apply'; runtimeDepsOn=@('a'); actions=@() }
            )
            Path = ''
        }
    }
    It "produces defaults when no overrides" {
        $sel = New-Tiny11Selections -Catalog $script:catalog
        $sel['a'].State | Should -Be 'apply'
        $sel['b'].State | Should -Be 'skip'
        $sel['c'].State | Should -Be 'apply'
    }
    It "applies overrides over defaults" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ a = 'skip' }
        $sel['a'].State | Should -Be 'skip'
        $sel['b'].State | Should -Be 'skip'
    }
}

Describe "Resolve-Tiny11Selections (reconcile)" {
    BeforeAll {
        $script:catalog = [pscustomobject]@{
            Version = 1
            Categories = @(@{ id='c1'; displayName='C1'; description='' })
            Items = @(
                @{ id='runtime';  category='c1'; displayName='Runtime';  default='apply'; runtimeDepsOn=@();          actions=@() },
                @{ id='consumer'; category='c1'; displayName='Consumer'; default='apply'; runtimeDepsOn=@('runtime'); actions=@() }
            )
            Path = ''
        }
    }
    It "leaves both apply when neither is kept" {
        $sel = New-Tiny11Selections -Catalog $script:catalog
        $resolved = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $sel
        $resolved['runtime'].EffectiveState | Should -Be 'apply'
        $resolved['runtime'].Locked | Should -BeFalse
        $resolved['consumer'].EffectiveState | Should -Be 'apply'
    }
    It "locks the prereq when consumer is kept" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ consumer = 'skip' }
        $resolved = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $sel
        $resolved['runtime'].EffectiveState | Should -Be 'skip'
        $resolved['runtime'].Locked | Should -BeTrue
        $resolved['runtime'].LockedBy | Should -Contain 'consumer'
    }
    It "unlocks when consumer returns to apply" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ consumer = 'apply' }
        $resolved = Resolve-Tiny11Selections -Catalog $script:catalog -Selections $sel
        $resolved['runtime'].Locked | Should -BeFalse
    }
}

Describe "Export-/Import-Tiny11Selections" {
    BeforeAll {
        $script:catalog = [pscustomobject]@{
            Version = 1
            Categories = @(@{ id='c1'; displayName='C1'; description='' })
            Items = @(
                @{ id='a'; category='c1'; displayName='A'; default='apply'; runtimeDepsOn=@(); actions=@() },
                @{ id='b'; category='c1'; displayName='B'; default='apply'; runtimeDepsOn=@(); actions=@() }
            )
            Path = ''
        }
        $script:tmp = New-TempScratchDir
    }
    AfterAll { Remove-TempScratchDir -Path $script:tmp }

    It "writes only items that diverge from default" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ a = 'skip' }
        $path = Join-Path $script:tmp 'profile.json'
        Export-Tiny11Selections -Selections $sel -Catalog $script:catalog -Path $path
        $loaded = Get-Content $path -Raw | ConvertFrom-Json
        $loaded.version | Should -Be 1
        $loaded.selections.PSObject.Properties.Name | Should -Contain 'a'
        $loaded.selections.PSObject.Properties.Name | Should -Not -Contain 'b'
    }
    It "round-trips overrides through Export and Import" {
        $sel = New-Tiny11Selections -Catalog $script:catalog -Overrides @{ a='skip' }
        $path = Join-Path $script:tmp 'rt.json'
        Export-Tiny11Selections -Selections $sel -Catalog $script:catalog -Path $path
        $loaded = Import-Tiny11Selections -Path $path -Catalog $script:catalog
        $loaded['a'].State | Should -Be 'skip'
        $loaded['b'].State | Should -Be 'apply'
    }
}
