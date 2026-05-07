#Requires -Module @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
$config = & "$PSScriptRoot/Tiny11.PesterConfig.ps1"
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
