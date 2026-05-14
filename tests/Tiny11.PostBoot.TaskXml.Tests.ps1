Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Tiny11.PostBoot.psm1') -Force -DisableNameChecking
    $script:xml = New-Tiny11PostBootTaskXml
    $script:doc = [xml]$script:xml
    $ns = New-Object System.Xml.XmlNamespaceManager $script:doc.NameTable
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $script:ns = $ns
}

Describe 'New-Tiny11PostBootTaskXml' {
    It 'parses as XML' { $script:doc | Should -Not -BeNullOrEmpty }

    It 'task URI is \tiny11options\Post-Boot Cleanup' {
        $script:doc.SelectSingleNode('//t:URI', $script:ns).InnerText | Should -Be '\tiny11options\Post-Boot Cleanup'
    }

    It 'has exactly 3 triggers: BootTrigger, CalendarTrigger, EventTrigger' {
        @($script:doc.SelectNodes('//t:Triggers/*', $script:ns)).Count | Should -Be 3
        $script:doc.SelectSingleNode('//t:BootTrigger', $script:ns)     | Should -Not -BeNullOrEmpty
        $script:doc.SelectSingleNode('//t:CalendarTrigger', $script:ns) | Should -Not -BeNullOrEmpty
        $script:doc.SelectSingleNode('//t:EventTrigger', $script:ns)    | Should -Not -BeNullOrEmpty
    }

    It 'BootTrigger delay is PT10M' {
        $script:doc.SelectSingleNode('//t:BootTrigger/t:Delay', $script:ns).InnerText | Should -Be 'PT10M'
    }

    It 'CalendarTrigger runs daily at 03:00' {
        $script:doc.SelectSingleNode('//t:CalendarTrigger/t:StartBoundary', $script:ns).InnerText | Should -Match '^.*T03:00:00$'
        $script:doc.SelectSingleNode('//t:CalendarTrigger/t:ScheduleByDay/t:DaysInterval', $script:ns).InnerText | Should -Be '1'
    }

    It 'EventTrigger subscribes to WindowsUpdateClient EventID 19' {
        $sub = $script:doc.SelectSingleNode('//t:EventTrigger/t:Subscription', $script:ns).InnerText
        $sub | Should -Match 'Microsoft-Windows-WindowsUpdateClient/Operational'
        $sub | Should -Match 'EventID=19'
    }

    It 'principal is SYSTEM with HighestAvailable' {
        $script:doc.SelectSingleNode('//t:Principal/t:UserId',   $script:ns).InnerText | Should -Be 'S-1-5-18'
        $script:doc.SelectSingleNode('//t:Principal/t:RunLevel', $script:ns).InnerText | Should -Be 'HighestAvailable'
    }

    It 'ExecutionTimeLimit is PT30M' {
        $script:doc.SelectSingleNode('//t:Settings/t:ExecutionTimeLimit', $script:ns).InnerText | Should -Be 'PT30M'
    }

    It 'Action invokes powershell.exe with absolute path to tiny11-cleanup.ps1' {
        $script:doc.SelectSingleNode('//t:Actions/t:Exec/t:Command', $script:ns).InnerText | Should -Be 'powershell.exe'
        $script:doc.SelectSingleNode('//t:Actions/t:Exec/t:Arguments', $script:ns).InnerText | Should -Match 'C:\\Windows\\Setup\\Scripts\\tiny11-cleanup\.ps1'
    }

    It 'RestartOnFailure retries 3 times at PT1M intervals (A5 W1 regression guard)' {
        # If the task fails at boot (locked files, transient resource issue) it
        # should retry rather than wait until the next trigger fires.
        $rof = $script:doc.SelectSingleNode('//t:Settings/t:RestartOnFailure', $script:ns)
        $rof | Should -Not -BeNullOrEmpty
        $rof.Interval | Should -Be 'PT1M'
        $rof.Count    | Should -Be '3'
    }
}
