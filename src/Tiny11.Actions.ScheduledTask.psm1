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

Export-ModuleMember -Function Invoke-ScheduledTaskAction
