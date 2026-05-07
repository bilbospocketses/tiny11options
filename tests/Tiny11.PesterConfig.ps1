$config = New-PesterConfiguration
$config.Run.Path = (Resolve-Path "$PSScriptRoot").Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $false
$config.CodeCoverage.Enabled = $false
$config
