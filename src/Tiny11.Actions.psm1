Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Actions.Registry.psm1"        -Force -DisableNameChecking -Global
Import-Module "$PSScriptRoot/Tiny11.Actions.Filesystem.psm1"      -Force -DisableNameChecking -Global
Import-Module "$PSScriptRoot/Tiny11.Actions.ScheduledTask.psm1"   -Force -DisableNameChecking -Global
Import-Module "$PSScriptRoot/Tiny11.Actions.ProvisionedAppx.psm1" -Force -DisableNameChecking -Global

function Invoke-Tiny11Action {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)
    switch ($Action.type) {
        'registry'              { Invoke-RegistryAction            -Action $Action -ScratchDir $ScratchDir }
        'registry-pattern-zero' { Invoke-RegistryPatternZeroAction -Action $Action -ScratchDir $ScratchDir }
        'filesystem'            { Invoke-FilesystemAction          -Action $Action -ScratchDir $ScratchDir }
        'scheduled-task'        { Invoke-ScheduledTaskAction       -Action $Action -ScratchDir $ScratchDir }
        'provisioned-appx'      { Invoke-ProvisionedAppxAction     -Action $Action -ScratchDir $ScratchDir }
        default                 { throw "Unknown action type: $($Action.type)" }
    }
}

function Get-Tiny11ActionOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)
    switch ($Action.type) {
        'registry'              { Get-Tiny11RegistryOnlineCommand            -Action $Action }
        'registry-pattern-zero' { Get-Tiny11RegistryPatternZeroOnlineCommand -Action $Action }
        'filesystem'            { Get-Tiny11FilesystemOnlineCommand          -Action $Action }
        'scheduled-task'        { Get-Tiny11ScheduledTaskOnlineCommand       -Action $Action }
        'provisioned-appx'      { Get-Tiny11ProvisionedAppxOnlineCommand     -Action $Action }
        default                 { throw "Unknown action type: $($Action.type)" }
    }
}

# A11/v1.0.3: catalog-iteration helpers extracted from Tiny11.Worker.psm1 so
# both Worker and Core build pipelines can apply catalog actions at offline
# build time. Pre-v1.0.3, these lived in Worker only -- Core mode skipped
# offline catalog application entirely (relied on the post-boot cleanup task
# at first boot via SetupComplete.cmd). With Core + -NoPostBootCleanup, that
# meant the catalog was NEVER applied. Moving the helpers here lets Core's
# Invoke-Tiny11CoreBuildPipeline call them directly inside its Phase 9 hive
# mount window, restoring symmetry with Worker.

function Get-Tiny11ApplyItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Catalog, [Parameter(Mandatory)][hashtable]$ResolvedSelections)
    $Catalog.Items | Where-Object { $ResolvedSelections[$_.id].EffectiveState -eq 'apply' }
}

function Invoke-Tiny11ApplyActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][hashtable]$ResolvedSelections,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][scriptblock]$ProgressCallback
    )
    $items = Get-Tiny11ApplyItems -Catalog $Catalog -ResolvedSelections $ResolvedSelections
    $total = $items.Count; $i = 0
    foreach ($item in $items) {
        $i++
        $displayName = if ($item -is [hashtable]) { $item['displayName'] } elseif ($item.PSObject.Properties['displayName']) { $item.displayName } else { $item.id }
        & $ProgressCallback @{ phase='apply'; step="$i of $total : $displayName"; percent=([int](($i / [math]::Max(1,$total)) * 100)); itemId=$item.id }
        foreach ($action in $item.actions) { Invoke-Tiny11Action -Action $action -ScratchDir $ScratchDir }
    }
}

Export-ModuleMember -Function Invoke-Tiny11Action, Get-Tiny11ActionOnlineCommand, Get-Tiny11ApplyItems, Invoke-Tiny11ApplyActions
