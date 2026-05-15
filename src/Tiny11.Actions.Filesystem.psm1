Set-StrictMode -Version Latest

# v1.0.7 Finding 4 -- known-benign stderr lines emitted by takeown.exe / icacls.exe
# during offline catalog application when a recursive pass touches Windows folders
# Microsoft protects with DACLs even elevated processes can't override. The build
# completes exit 0 with a valid ISO regardless, but pre-v1.0.7 these lines leaked
# into headless build logs (visible after A13 added --log; previously they just
# flashed past on-screen). Suppression preserves ALL real-error stderr -- only
# verbatim "<protected-path>\*: Access is denied." lines are dropped, anchored on
# the trailing-asterisk wildcard form takeown/icacls emit when /R or /T can't
# enumerate a subtree's children.
$script:KnownBenignTakeownIcaclsNoisePatterns = @(
    'Windows\\System32\\LogFiles\\WMI\\RtBackup\\\*:\s+Access is denied\.',
    'Windows\\System32\\WebThreatDefSvc\\\*:\s+Access is denied\.'
)

function Test-IsKnownBenignTakeownIcaclsNoise {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    foreach ($pattern in $script:KnownBenignTakeownIcaclsNoisePatterns) {
        if ($Line -match $pattern) { return $true }
    }
    return $false
}

# Internal helper -- pipes stdout+stderr through the noise filter. Real stderr
# (anything not matching the benign patterns) is re-emitted to the host's
# console error stream so the launcher's child-process stderr capture still
# sees real failures. Stdout is dropped, matching the pre-v1.0.7 `| Out-Null`
# behavior of Invoke-Takeown / Invoke-Icacls.
function Invoke-NativeWithNoiseFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    & $FileName @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $msg = $_.Exception.Message
            if (-not (Test-IsKnownBenignTakeownIcaclsNoise -Line $msg)) {
                [System.Console]::Error.WriteLine($msg)
            }
        }
    }
}

function Invoke-Takeown {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [bool]$Recurse)
    $takeownArgs = @('/f', $Path)
    if ($Recurse) { $takeownArgs += '/r'; $takeownArgs += '/d'; $takeownArgs += 'Y' }
    Invoke-NativeWithNoiseFilter -FileName 'takeown.exe' -Arguments $takeownArgs
}

function Invoke-Icacls {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AdminGroup)
    $icaclsArgs = @($Path, '/grant', "$AdminGroup`:(F)", '/T', '/C')
    Invoke-NativeWithNoiseFilter -FileName 'icacls.exe' -Arguments $icaclsArgs
}

function Get-AdminGroupAccount {
    $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $sid.Translate([System.Security.Principal.NTAccount]).Value
}

function Invoke-FilesystemAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)

    $full = Join-Path $ScratchDir $Action.path
    if (-not (Test-Path $full)) { return }

    if ($Action.op -eq 'takeown-and-remove') {
        $admin = Get-AdminGroupAccount
        Invoke-Takeown -Path $full -Recurse:([bool]$Action.recurse)
        Invoke-Icacls -Path $full -AdminGroup $admin
    } elseif ($Action.op -ne 'remove') {
        throw "Invalid filesystem op: $($Action.op)"
    }

    if ($Action.recurse) { Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue }
    else                 { Remove-Item -Path $full -Force -ErrorAction SilentlyContinue }
}

function Get-Tiny11FilesystemOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    $kind = switch ($Action.op) {
        'remove'              { 'Remove-PathIfPresent' }
        'takeown-and-remove'  { 'Remove-PathWithOwnership' }
        default               { throw "Invalid filesystem op: $($Action.op)" }
    }

    ,([pscustomobject]@{
        Kind        = $kind
        Args        = [ordered]@{ Path = '$env:SystemDrive\' + $Action.path; Recurse = [bool]$Action.recurse }
        Description = "$kind '$($Action.path)'" + $(if ([bool]$Action.recurse) { ' (recurse)' } else { '' })
    })
}

Export-ModuleMember -Function Invoke-FilesystemAction, Invoke-Takeown, Invoke-Icacls, Get-AdminGroupAccount, Get-Tiny11FilesystemOnlineCommand, Test-IsKnownBenignTakeownIcaclsNoise
