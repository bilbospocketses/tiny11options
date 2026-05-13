Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Tiny11.Hives.psm1" -Force -DisableNameChecking -Global

function Invoke-RegistryAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)

    $mountKey = Get-Tiny11HiveMountKey -Hive $Action.hive
    $fullKey  = "$mountKey\$($Action.key)"

    switch ($Action.op) {
        'set' {
            # Pre-escape embedded " for reg.exe. Windows PowerShell 5.1's legacy
            # native-command argument passing does NOT auto-escape inner quotes,
            # so a value like `{"pinnedList": [{}]}` reaches reg.exe with the
            # quotes consumed as argument delimiters and the stored value
            # becomes `{pinnedList: [{}]}`. PS 7+'s Standard mode handles this,
            # but tiny11maker.ps1:91-112 blocks pwsh and forces PS 5.1.
            # Verified empirically: post-build offline SOFTWARE hive read
            # confirms quoted form lands intact after this escape is applied.
            $regValue = ([string]$Action.value) -replace '"', '\"'
            Invoke-RegCommand 'add' $fullKey '/v' $Action.name '/t' $Action.valueType '/d' $regValue '/f' | Out-Null
        }
        'remove' {
            try { Invoke-RegCommand 'delete' $fullKey '/f' | Out-Null }
            catch { if ($_.Exception.Message -notmatch 'unable to find') { throw } }
        }
        default { throw "Invalid registry op: $($Action.op)" }
    }
}

function Get-Tiny11RegistryOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    if ($Action.hive -eq 'COMPONENTS') {
        throw "COMPONENTS hive cleanup not supported online (action key: $($Action.key))"
    }

    $hivePrefix = switch ($Action.hive) {
        'SOFTWARE' { 'HKLM:\Software' }
        'SYSTEM'   { 'HKLM:\SYSTEM' }
        'DEFAULT'  { 'HKU:\.DEFAULT' }
        'NTUSER'   { $null }   # signals fan-out path below
        default    { throw "Unknown registry hive: $($Action.hive)" }
    }

    $isNtUser = ($Action.hive -eq 'NTUSER')

    switch ($Action.op) {
        'set' {
            $type = switch ($Action.valueType) {
                'REG_DWORD'     { 'DWord' }
                'REG_QWORD'     { 'QWord' }
                'REG_SZ'        { 'String' }
                'REG_EXPAND_SZ' { 'ExpandString' }
                'REG_BINARY'    { 'Binary' }
                'REG_MULTI_SZ'  { 'MultiString' }
                default         { throw "Unknown registry valueType: $($Action.valueType)" }
            }
            $parsedValue = switch ($Action.valueType) {
                'REG_DWORD'    { [int]   $Action.value }
                'REG_QWORD'    { [long]  $Action.value }
                'REG_BINARY'   { ,([byte[]] (-split ($Action.value) | ForEach-Object { [Convert]::ToByte($_, 16) })) }
                'REG_MULTI_SZ' { ,([string[]] ($Action.value -split '\|')) }
                default        { [string]$Action.value }
            }

            if ($isNtUser) {
                ,([pscustomobject]@{
                    Kind = 'Set-RegistryValueForAllUsers'
                    Args = [ordered]@{ RelativeKeyPath = $Action.key; Name = $Action.name; Type = $type; Value = $parsedValue }
                    Description = "Set HKU:*\$($Action.key)!$($Action.name) = $($Action.value) (per-user, all loaded SIDs + tiny11_default hive when mounted)"
                })
            } else {
                ,([pscustomobject]@{
                    Kind = 'Set-RegistryValue'
                    Args = [ordered]@{ KeyPath = "$hivePrefix\$($Action.key)"; Name = $Action.name; Type = $type; Value = $parsedValue }
                    Description = "Set $hivePrefix\$($Action.key)!$($Action.name) = $($Action.value)"
                })
            }
        }
        'remove' {
            if ($isNtUser) {
                ,([pscustomobject]@{
                    Kind = 'Remove-RegistryKeyForAllUsers'
                    Args = [ordered]@{ RelativeKeyPath = $Action.key }
                    Description = "Remove HKU:*\$($Action.key) (per-user, all loaded SIDs + tiny11_default hive when mounted)"
                })
            } else {
                ,([pscustomobject]@{
                    Kind = 'Remove-RegistryKey'
                    Args = [ordered]@{ KeyPath = "$hivePrefix\$($Action.key)" }
                    Description = "Remove $hivePrefix\$($Action.key)"
                })
            }
        }
        default { throw "Invalid registry op: $($Action.op)" }
    }
}

Export-ModuleMember -Function Invoke-RegistryAction, Get-Tiny11RegistryOnlineCommand
