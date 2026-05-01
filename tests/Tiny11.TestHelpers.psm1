Set-StrictMode -Version 3.0

function Import-Tiny11Module {
    param([Parameter(Mandatory)][string]$Name)
    $modulePath = "$PSScriptRoot/../src/$Name.psm1"
    if (-not (Test-Path $modulePath)) { throw "Module not found: $modulePath" }
    Import-Module $modulePath -Force -DisableNameChecking
}
function New-TempScratchDir {
    $tmp = Join-Path $env:TEMP "tiny11test-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $tmp
}
function Remove-TempScratchDir {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue }
}
Export-ModuleMember -Function Import-Tiny11Module, New-TempScratchDir, Remove-TempScratchDir
