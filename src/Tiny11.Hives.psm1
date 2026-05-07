Set-StrictMode -Version Latest

$HiveMap = @{
    'COMPONENTS' = 'Windows\System32\config\COMPONENTS'
    'DEFAULT'    = 'Windows\System32\config\default'
    'NTUSER'     = 'Users\Default\ntuser.dat'
    'SOFTWARE'   = 'Windows\System32\config\SOFTWARE'
    'SYSTEM'     = 'Windows\System32\config\SYSTEM'
}

function Resolve-Tiny11HivePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$ScratchDir)
    if (-not $HiveMap.ContainsKey($Hive)) {
        throw "Unknown hive: $Hive (expected one of $($HiveMap.Keys -join ', '))"
    }
    Join-Path $ScratchDir $HiveMap[$Hive]
}

function Get-Tiny11HiveMountKey {
    param([Parameter(Mandatory)][string]$Hive)
    "HKLM\z$Hive"
}

function Invoke-RegCommand {
    param([Parameter(ValueFromRemainingArguments)][string[]]$RegArgs)
    $captured = (& reg.exe @RegArgs) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg.exe failed (exit $LASTEXITCODE): $($RegArgs -join ' ')`n$captured" }
}

function Mount-Tiny11Hive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$ScratchDir)
    $path = Resolve-Tiny11HivePath -Hive $Hive -ScratchDir $ScratchDir
    Invoke-RegCommand 'load' (Get-Tiny11HiveMountKey -Hive $Hive) $path
}

function Dismount-Tiny11Hive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive)
    Invoke-RegCommand 'unload' (Get-Tiny11HiveMountKey -Hive $Hive)
}

function Mount-Tiny11AllHives {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScratchDir)
    foreach ($h in $HiveMap.Keys) { Mount-Tiny11Hive -Hive $h -ScratchDir $ScratchDir }
}

function Dismount-Tiny11AllHives {
    [CmdletBinding()] param()
    foreach ($h in $HiveMap.Keys) {
        try { Dismount-Tiny11Hive -Hive $h } catch { Write-Warning "Failed to unload hive ${h}: $_" }
    }
}

Export-ModuleMember -Function Resolve-Tiny11HivePath, Get-Tiny11HiveMountKey, Invoke-RegCommand, Mount-Tiny11Hive, Dismount-Tiny11Hive, Mount-Tiny11AllHives, Dismount-Tiny11AllHives
