Set-StrictMode -Version Latest

# Module-scope constants populated by tasks 7-9.
$script:headerBlock  = ''
$script:helpersBlock = ''
$script:footerBlock  = ''

function Format-PSNamedParams {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Args)
    $parts = foreach ($entry in $Args.GetEnumerator()) {
        $value = $entry.Value
        $rendered = if ($value -is [bool]) {
            if ($value) { '$true' } else { '$false' }
        } elseif ($value -is [int] -or $value -is [long]) {
            "$value"
        } elseif ($value -is [byte[]]) {
            $hex = ($value | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','
            "([byte[]]($hex))"
        } elseif ($value -is [string[]]) {
            $quoted = ($value | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            "@($quoted)"
        } else {
            $s = [string]$value
            "'" + ($s -replace "'", "''") + "'"
        }
        "-$($entry.Key) $rendered"
    }
    $parts -join ' '
}

function New-Tiny11PostBootCleanupScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]            $Catalog,
        [Parameter(Mandatory)][hashtable] $ResolvedSelections
    )
    throw 'New-Tiny11PostBootCleanupScript not yet implemented'
}

function New-Tiny11PostBootTaskXml {
    [CmdletBinding()] param()
    throw 'New-Tiny11PostBootTaskXml not yet implemented'
}

function New-Tiny11PostBootSetupCompleteScript {
    [CmdletBinding()] param()
    throw 'New-Tiny11PostBootSetupCompleteScript not yet implemented'
}

function Install-Tiny11PostBootCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]    $MountDir,
        [Parameter(Mandatory)]            $Catalog,
        [Parameter(Mandatory)][hashtable] $ResolvedSelections,
        [bool]                            $Enabled = $true
    )
    throw 'Install-Tiny11PostBootCleanup not yet implemented'
}

Export-ModuleMember -Function `
    Format-PSNamedParams, `
    New-Tiny11PostBootCleanupScript, `
    New-Tiny11PostBootTaskXml, `
    New-Tiny11PostBootSetupCompleteScript, `
    Install-Tiny11PostBootCleanup
