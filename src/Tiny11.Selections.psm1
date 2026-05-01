Set-StrictMode -Version Latest

function New-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Catalog,
        [hashtable]$Overrides = @{}
    )
    $result = @{}
    foreach ($item in $Catalog.Items) {
        $state = if ($Overrides.ContainsKey($item.id)) { $Overrides[$item.id] } else { $item.default }
        if ($state -notin 'apply','skip') {
            throw "Selection state for '$($item.id)' must be 'apply' or 'skip', got: $state"
        }
        $result[$item.id] = [pscustomobject]@{ ItemId = $item.id; State = $state }
    }
    $result
}

function Resolve-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][hashtable]$Selections
    )
    $pinnedBy = @{}
    foreach ($item in $Catalog.Items) {
        if ($Selections[$item.id].State -eq 'skip') {
            foreach ($dep in $item.runtimeDepsOn) {
                if (-not $pinnedBy.ContainsKey($dep)) { $pinnedBy[$dep] = @() }
                $pinnedBy[$dep] += $item.id
            }
        }
    }
    $resolved = @{}
    foreach ($item in $Catalog.Items) {
        $userState = $Selections[$item.id].State
        $locked = $pinnedBy.ContainsKey($item.id)
        $effective = if ($locked) { 'skip' } else { $userState }
        $resolved[$item.id] = [pscustomobject]@{
            ItemId = $item.id; UserState = $userState
            EffectiveState = $effective; Locked = $locked
            LockedBy = if ($locked) { $pinnedBy[$item.id] } else { @() }
        }
    }
    $resolved
}

function Export-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Selections,
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)][string]$Path
    )
    $diverged = @{}
    foreach ($item in $Catalog.Items) {
        if ($Selections[$item.id].State -ne $item.default) {
            $diverged[$item.id] = $Selections[$item.id].State
        }
    }
    $payload = [ordered]@{ version = 1; selections = $diverged }
    $json = $payload | ConvertTo-Json -Depth 5
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Import-Tiny11Selections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)] $Catalog
    )
    if (-not (Test-Path $Path)) { throw "Profile file not found: $Path" }
    $obj = Get-Content $Path -Raw | ConvertFrom-Json
    if ($obj.version -ne 1) { throw "Profile version unsupported: $($obj.version)" }
    $overrides = @{}
    if ($obj.PSObject.Properties.Name -contains 'selections') {
        foreach ($p in $obj.selections.PSObject.Properties) { $overrides[$p.Name] = $p.Value }
    }
    New-Tiny11Selections -Catalog $Catalog -Overrides $overrides
}

Export-ModuleMember -Function New-Tiny11Selections, Resolve-Tiny11Selections, Export-Tiny11Selections, Import-Tiny11Selections
