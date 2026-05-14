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

Export-ModuleMember -Function Invoke-Tiny11Action, Get-Tiny11ActionOnlineCommand
