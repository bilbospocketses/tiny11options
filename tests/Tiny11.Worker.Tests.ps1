Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Worker'
# A11/v1.0.3: Get-Tiny11ApplyItems / Invoke-Tiny11ApplyActions moved to
# Tiny11.Actions.psm1 -- import it explicitly so Mock -ModuleName targets the
# correct scope (the moved functions now call Invoke-Tiny11Action from within
# Tiny11.Actions module scope, not Tiny11.Worker).
Import-Tiny11Module -Name 'Tiny11.Actions'

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
    BeforeEach { Mock -CommandName 'Invoke-Tiny11Action' -MockWith { } -ModuleName 'Tiny11.Actions' }
    It "calls dispatcher once per action across apply items" {
        $catalog = [pscustomobject]@{
            Items = @(
                @{ id='a'; actions=@(@{type='registry'; op='set'; hive='SOFTWARE'; key='K1'; name='N'; valueType='REG_DWORD'; value='0'}) }
                @{ id='b'; actions=@(@{type='filesystem'; op='remove'; path='X'; recurse=$false}, @{type='filesystem'; op='remove'; path='Y'; recurse=$false}) }
            )
        }
        $resolved = @{ 'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' }; 'b' = [pscustomobject]@{ ItemId='b'; EffectiveState='apply' } }
        Invoke-Tiny11ApplyActions -Catalog $catalog -ResolvedSelections $resolved -ScratchDir 'C:\s' -ProgressCallback {}
        Should -Invoke -CommandName 'Invoke-Tiny11Action' -ModuleName 'Tiny11.Actions' -Times 3
    }
    It "invokes the progress callback per item" {
        $catalog = [pscustomobject]@{ Items = @(@{ id='a'; actions=@() }) }
        $resolved = @{ 'a' = [pscustomobject]@{ ItemId='a'; EffectiveState='apply' } }
        $script:calls = 0
        Invoke-Tiny11ApplyActions -Catalog $catalog -ResolvedSelections $resolved -ScratchDir 'C:\s' -ProgressCallback { $script:calls++ }
        $script:calls | Should -BeGreaterThan 0
    }
}

Describe 'Invoke-Tiny11BuildPipeline post-boot cleanup integration' {
    It 'source calls Install-Tiny11PostBootCleanup and threads $InstallPostBootCleanup' {
        $source = Get-Content (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.Worker.psm1') -Raw
        $source | Should -Match 'Install-Tiny11PostBootCleanup'
        $source | Should -Match '\$InstallPostBootCleanup'
        $source | Should -Match '-Enabled:\$InstallPostBootCleanup'
    }

    It 'has an InstallPostBootCleanup parameter on Invoke-Tiny11BuildPipeline' {
        $cmd = Get-Command Invoke-Tiny11BuildPipeline
        $cmd.Parameters.Keys | Should -Contain 'InstallPostBootCleanup'
        $cmd.Parameters['InstallPostBootCleanup'].ParameterType.Name | Should -Be 'Boolean'
    }
}

Describe 'Invoke-Tiny11BuildPipeline install.wim commit/discard symmetry (B6/B7 regression guard)' {
    BeforeAll {
        $script:workerSource = Get-Content (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.Worker.psm1') -Raw
    }
    It 'has an $installPipelineSucceeded flag mirroring Core' {
        # B6/B7: Worker pre-fix called Install-Tiny11PostBootCleanup BEFORE
        # Dismount-WindowsImage with no try/finally guarding the unmount. An
        # Install throw left the WIM mount abandoned. Core has the
        # $pipelineSucceeded pattern at Core.psm1:1165; Worker must too.
        $script:workerSource | Should -Match '\$installPipelineSucceeded = \$false'
        $script:workerSource | Should -Match '\$installPipelineSucceeded = \$true'
    }
    It 'has Dismount-WindowsImage in a finally branch with both -Save and -Discard arms' {
        # The unmount must live in a finally so it runs even when the inner
        # try throws, and it must choose between -Save (success) and -Discard
        # (failure) based on the flag.
        $script:workerSource | Should -Match 'Dismount-WindowsImage -Path \$scratchImg -Save'
        $script:workerSource | Should -Match 'Dismount-WindowsImage -Path \$scratchImg -Discard'
        $script:workerSource | Should -Match '(?ms)finally\s*\{[\s\S]*?Dismount-WindowsImage -Path \$scratchImg -Discard'
    }
    It 'rethrows with a mid-flight diagnostic when the inner pipeline fails' {
        # After the finally branch, a clean re-throw with a recognisable
        # message lets the launcher distinguish "build failed mid-pipeline"
        # from "build failed during teardown".
        $script:workerSource | Should -Match "throw 'Worker build pipeline failed mid-flight"
    }
}

Describe 'Invoke-Tiny11BuildPipeline boot.wim commit/discard symmetry (v1.0.2 carry-over #4 regression guard)' {
    # Structural sibling to the B6/B7 install.wim fix. The boot.wim block was
    # not in the original Batch 1/2 audit scope but has identical failure
    # semantics: a throw between Mount-WindowsImage(boot.wim) and
    # Dismount-WindowsImage left boot.wim mounted with no recovery path.
    BeforeAll {
        $script:workerSource = Get-Content (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.Worker.psm1') -Raw
    }
    It 'has a $bootPipelineSucceeded flag mirroring the install.wim block' {
        $script:workerSource | Should -Match '\$bootPipelineSucceeded = \$false'
        $script:workerSource | Should -Match '\$bootPipelineSucceeded = \$true'
    }
    It 'has boot.wim Dismount-WindowsImage in a finally with both -Save and -Discard arms' {
        # Both arms must exist, gated by the flag. Match the install.wim block's structure.
        $script:workerSource | Should -Match '(?ms)if \(\$bootPipelineSucceeded\) \{\s*Dismount-WindowsImage -Path \$scratchImg -Save'
        $script:workerSource | Should -Match '(?ms)\} else \{\s*Dismount-WindowsImage -Path \$scratchImg -Discard'
    }
    It 'rethrows with a boot.wim mid-flight diagnostic when the inner pipeline fails' {
        $script:workerSource | Should -Match "throw 'Worker boot\.wim pipeline failed mid-flight"
    }
}
