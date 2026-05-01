Set-StrictMode -Version Latest

function Invoke-Takeown {
    param([Parameter(Mandatory)][string]$Path, [bool]$Recurse)
    $args = @('/f', $Path)
    if ($Recurse) { $args += '/r'; $args += '/d'; $args += 'Y' }
    & 'takeown.exe' @args | Out-Null
}

function Invoke-Icacls {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AdminGroup)
    & 'icacls.exe' $Path '/grant' "$AdminGroup`:(F)" '/T' '/C' | Out-Null
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

Export-ModuleMember -Function Invoke-FilesystemAction, Invoke-Takeown, Invoke-Icacls, Get-AdminGroupAccount
