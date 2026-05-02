Set-StrictMode -Version Latest

$script:packageCache = @{}

function Clear-Tiny11AppxPackageCache {
    [CmdletBinding()] param([string]$ScratchDir)
    if ($ScratchDir) { $script:packageCache.Remove($ScratchDir) | Out-Null }
    else { $script:packageCache.Clear() }
}

function Get-ProvisionedAppxPackagesFromImage {
    param([Parameter(Mandatory)][string]$ScratchDir)
    if ($script:packageCache.ContainsKey($ScratchDir)) {
        return $script:packageCache[$ScratchDir]
    }
    $list = [System.Collections.Generic.List[string]]::new()
    & 'dism.exe' '/English' "/image:$ScratchDir" '/Get-ProvisionedAppxPackages' |
        ForEach-Object {
            if ($_ -match '^PackageName\s*:\s*(.+)$') { $list.Add($matches[1].Trim()) }
        }
    $script:packageCache[$ScratchDir] = $list
    $list
}

function Invoke-DismRemoveAppx {
    param([Parameter(Mandatory)][string]$ScratchDir, [Parameter(Mandatory)][string]$PackageName)
    & 'dism.exe' '/English' "/image:$ScratchDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$PackageName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dism /Remove-ProvisionedAppxPackage failed for $PackageName (exit $LASTEXITCODE)" }
    if ($script:packageCache.ContainsKey($ScratchDir)) {
        $null = $script:packageCache[$ScratchDir].Remove($PackageName)
    }
}

function Invoke-ProvisionedAppxAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)
    $packages = Get-ProvisionedAppxPackagesFromImage -ScratchDir $ScratchDir
    $matchedPackages = @($packages | Where-Object { $_ -like "*$($Action.packagePrefix)*" })
    foreach ($pkg in $matchedPackages) { Invoke-DismRemoveAppx -ScratchDir $ScratchDir -PackageName $pkg }
}

Export-ModuleMember -Function Invoke-ProvisionedAppxAction, Get-ProvisionedAppxPackagesFromImage, Invoke-DismRemoveAppx, Clear-Tiny11AppxPackageCache
