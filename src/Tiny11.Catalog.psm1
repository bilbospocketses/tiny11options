Set-StrictMode -Version Latest

$ValidActionTypes = @('provisioned-appx','filesystem','registry','scheduled-task')
$ValidHives       = @('COMPONENTS','DEFAULT','NTUSER','SOFTWARE','SYSTEM')

function Get-Tiny11Catalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "Catalog file not found: $Path" }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    try { $obj = $raw | ConvertFrom-Json } catch { throw "Catalog JSON parse error: $_" }

    if (-not $obj.PSObject.Properties.Name.Contains('version')) {
        throw "Catalog missing required field: version"
    }
    if ($obj.version -ne 1) { throw "Catalog version unsupported: $($obj.version) (expected 1)" }

    $categoryIds = @{}
    foreach ($cat in @($obj.categories)) {
        foreach ($field in 'id','displayName','description') {
            if (-not $cat.PSObject.Properties.Name.Contains($field)) {
                throw "Catalog category missing required field: $field"
            }
        }
        $categoryIds[$cat.id] = $true
    }

    $itemIds = @{}
    foreach ($item in @($obj.items)) {
        foreach ($field in 'id','category','displayName','description','default','runtimeDepsOn','actions') {
            if (-not $item.PSObject.Properties.Name.Contains($field)) {
                throw "Catalog item '$($item.id)' missing required field: $field"
            }
        }
        if (-not $categoryIds.ContainsKey($item.category)) {
            throw "Catalog item '$($item.id)' references unknown category: $($item.category)"
        }
        if ($item.default -notin 'apply','skip') {
            throw "Catalog item '$($item.id)' has invalid default: $($item.default) (expected 'apply' or 'skip')"
        }
        foreach ($action in @($item.actions)) {
            if ($action.type -notin $ValidActionTypes) {
                throw "Catalog item '$($item.id)' has invalid action type: $($action.type) (expected one of $($ValidActionTypes -join ', '))"
            }
            if ($action.type -eq 'registry' -and ($action.PSObject.Properties.Name -contains 'hive') -and ($action.hive -notin $ValidHives)) {
                throw "Catalog item '$($item.id)' has invalid hive: $($action.hive)"
            }
        }
        $itemIds[$item.id] = $true
    }

    foreach ($item in @($obj.items)) {
        foreach ($dep in @($item.runtimeDepsOn)) {
            if (-not $itemIds.ContainsKey($dep)) {
                throw "Catalog item '$($item.id)' has unknown runtimeDepsOn target: $dep"
            }
        }
    }

    [pscustomobject]@{
        Version    = $obj.version
        Categories = @($obj.categories)
        Items      = @($obj.items)
        Path       = (Resolve-Path $Path).Path
    }
}

Export-ModuleMember -Function Get-Tiny11Catalog
