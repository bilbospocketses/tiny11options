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

    # P8 finding: previously this emitted Remove-PathIfPresent against
    # $env:SystemRoot\System32\Tasks\<relPath>, deleting only the task XML file.
    # That leaves the Task Scheduler service's registry-cache entries
    # (HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\
    #  {Tasks,Tree}) intact, so any task Windows servicing re-registers via a
    # registry-only mechanism (observed: CEIP Consolidator/UsbCeip, WER
    # QueueReporting) remains Ready and fires on its trigger. Unregister-
    # ScheduledTask clears both layers atomically.
    if ([bool]$Action.recurse) {
        # Folder removal: unregister every task at or under the path.
        ,([pscustomobject]@{
            Kind        = 'Unregister-ScheduledTaskFolder'
            Args        = [ordered]@{ TaskPathPrefix = '\' + $relPath + '\' }
            Description = "Unregister scheduled tasks under folder '$relPath' (recurse)"
        })
    } else {
        # Leaf task: split the path into parent folder + task name. Task
        # Scheduler's TaskPath argument uses leading + trailing backslashes.
        $parent = Split-Path -Path $relPath -Parent
        $leaf   = Split-Path -Path $relPath -Leaf
        $taskPathArg = if ($parent) { '\' + $parent + '\' } else { '\' }
        ,([pscustomobject]@{
            Kind        = 'Unregister-ScheduledTaskIfPresent'
            Args        = [ordered]@{ TaskPath = $taskPathArg; TaskName = $leaf }
            Description = "Unregister scheduled task '$relPath'"
        })
    }
}

Export-ModuleMember -Function Invoke-ScheduledTaskAction, Get-Tiny11ScheduledTaskOnlineCommand
