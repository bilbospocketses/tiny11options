Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Actions.ScheduledTask'

Describe "Invoke-ScheduledTaskAction" {
    BeforeAll { $script:tmp = New-TempScratchDir }
    AfterAll  { Remove-TempScratchDir -Path $script:tmp }

    It "deletes a single task XML file" {
        $tasksRoot = Join-Path $script:tmp 'Windows\System32\Tasks'
        $taskPath = Join-Path $tasksRoot 'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        New-Item -ItemType File -Path $taskPath -Force | Out-Null
        Invoke-ScheduledTaskAction -Action @{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Application Experience/Microsoft Compatibility Appraiser'; recurse=$false } -ScratchDir $script:tmp
        Test-Path $taskPath | Should -BeFalse
    }
    It "deletes a folder recursively" {
        $tasksRoot = Join-Path $script:tmp 'Windows\System32\Tasks'
        $folder = Join-Path $tasksRoot 'Microsoft\Windows\Customer Experience Improvement Program'
        New-Item -ItemType File -Path (Join-Path $folder 'subtask') -Force | Out-Null
        Invoke-ScheduledTaskAction -Action @{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Customer Experience Improvement Program'; recurse=$true } -ScratchDir $script:tmp
        Test-Path $folder | Should -BeFalse
    }
    It "is idempotent on missing path" {
        { Invoke-ScheduledTaskAction -Action @{ type='scheduled-task'; op='remove'; path='Microsoft/Windows/Ghost'; recurse=$false } -ScratchDir $script:tmp } | Should -Not -Throw
    }
}
