Set-StrictMode -Version Latest

function Invoke-ScheduledTaskAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action, [Parameter(Mandatory)][string]$ScratchDir)

    if ($Action.op -ne 'remove') { throw "Invalid scheduled-task op: $($Action.op)" }

    $tasksRoot = Join-Path $ScratchDir 'Windows\System32\Tasks'
    $relPath = $Action.path -replace '/','\'
    $full = Join-Path $tasksRoot $relPath

    if (-not (Test-Path $full)) { return }
    if ($Action.recurse) { Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue }
    else                 { Remove-Item -Path $full -Force -ErrorAction SilentlyContinue }
}

function Get-Tiny11ScheduledTaskOnlineCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    if ($Action.op -ne 'remove') { throw "Invalid scheduled-task op: $($Action.op)" }
    $relPath = $Action.path -replace '/', '\'

    ,([pscustomobject]@{
        Kind        = 'Remove-PathIfPresent'
        Args        = [ordered]@{ Path = '$env:SystemRoot\System32\Tasks\' + $relPath; Recurse = [bool]$Action.recurse }
        Description = "Remove scheduled task XML '$relPath'" + $(if ([bool]$Action.recurse) { ' (recurse)' } else { '' })
    })
}

Export-ModuleMember -Function Invoke-ScheduledTaskAction, Get-Tiny11ScheduledTaskOnlineCommand
