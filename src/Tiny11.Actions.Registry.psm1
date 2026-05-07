Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Hives.psm1" -Force -DisableNameChecking

function Invoke-RegistryAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)

    $mountKey = Get-Tiny11HiveMountKey -Hive $Action.hive
    $fullKey  = "$mountKey\$($Action.key)"

    switch ($Action.op) {
        'set' {
            Invoke-RegCommand 'add' $fullKey '/v' $Action.name '/t' $Action.valueType '/d' $Action.value '/f' | Out-Null
        }
        'remove' {
            try { Invoke-RegCommand 'delete' $fullKey '/f' | Out-Null }
            catch { if ($_.Exception.Message -notmatch 'unable to find') { throw } }
        }
        default { throw "Invalid registry op: $($Action.op)" }
    }
}

Export-ModuleMember -Function Invoke-RegistryAction
