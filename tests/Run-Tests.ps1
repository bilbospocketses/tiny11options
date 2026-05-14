#Requires -Module @{ ModuleName='Pester'; ModuleVersion='5.3.1'; MaximumVersion='5.99.99' }
# Tested against Pester 5.7.1. Floor 5.3.1 sidesteps BeforeAll variable-
# visibility behavior changes that landed earlier in 5.x; ceiling 5.99.99
# caps below Pester 6.x which is not yet validated against this suite.
$config = & "$PSScriptRoot/Tiny11.PesterConfig.ps1"
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
