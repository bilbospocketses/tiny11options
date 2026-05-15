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
# v1.0.8 audit WARNING ps-modules A4: anchor with ^.*...\s*$ to preserve the
# scratch-dir-prefix match semantics (the .* prefix allows arbitrary leading
# path; tests use D:\some\other\scratch\... etc.) while tightening end-of-line
# so a partial match without the trailing "\*: Access is denied." line shape
# doesn't accidentally suppress real errors.
$script:KnownBenignTakeownIcaclsNoisePatterns = @(
    '^.*Windows\\System32\\LogFiles\\WMI\\RtBackup\\\*:\s+Access is denied\.\s*$',
    '^.*Windows\\System32\\WebThreatDefSvc\\\*:\s+Access is denied\.\s*$'
)

function Test-IsKnownBenignTakeownIcaclsNoise {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    foreach ($pattern in $script:KnownBenignTakeownIcaclsNoisePatterns) {
        if ($Line -match $pattern) { return $true }
    }
    return $false
}

# Internal helper -- pipes stdout+stderr through the noise filter. Symmetric
# in v1.0.8 (audit A4): the filter applies to BOTH ErrorRecord AND string-
# wrapped lines (PS 5.1 host-dependent native-stream wrapping can deliver
# native stderr as either). Non-noise stdout is passed through to STDOUT so
# takeown.exe / icacls.exe "SUCCESS: ..." lines remain visible in build logs.
# Pre-v1.0.8 the filter only fired on ErrorRecord branch + all stdout was
# silently dropped (regression in observability vs pre-v1.0.7).
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
        } else {
            $msg = [string]$_
            if (-not (Test-IsKnownBenignTakeownIcaclsNoise -Line $msg)) {
                [System.Console]::Out.WriteLine($msg)
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
