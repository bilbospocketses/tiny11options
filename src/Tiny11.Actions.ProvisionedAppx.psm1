Set-StrictMode -Version Latest

function Get-ProvisionedAppxPackagesFromImage {
    param([Parameter(Mandatory)][string]$ScratchDir)
    & 'dism.exe' '/English' "/image:$ScratchDir" '/Get-ProvisionedAppxPackages' |
        ForEach-Object {
            if ($_ -match '^PackageName\s*:\s*(.+)$') { $matches[1].Trim() }
        }
}

function Invoke-DismRemoveAppx {
    param([Parameter(Mandatory)][string]$ScratchDir, [Parameter(Mandatory)][string]$PackageName)
    & 'dism.exe' '/English' "/image:$ScratchDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$PackageName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dism /Remove-ProvisionedAppxPackage failed for $PackageName (exit $LASTEXITCODE)" }
}

function Invoke-ProvisionedAppxAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)
    $packages = Get-ProvisionedAppxPackagesFromImage -ScratchDir $ScratchDir
    $matchedPackages = $packages | Where-Object { $_ -like "*$($Action.packagePrefix)*" }
    foreach ($pkg in $matchedPackages) { Invoke-DismRemoveAppx -ScratchDir $ScratchDir -PackageName $pkg }
}

Export-ModuleMember -Function Invoke-ProvisionedAppxAction, Get-ProvisionedAppxPackagesFromImage, Invoke-DismRemoveAppx
