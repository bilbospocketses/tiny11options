Set-StrictMode -Version 3.0
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Bridge'

Describe "ConvertTo-Tiny11BridgeMessage" {
    It "round-trips type + payload" {
        $json = ConvertTo-Tiny11BridgeMessage -Type 'iso-validated' -Payload @{ editions = @(1,2,3) }
        $obj = $json | ConvertFrom-Json
        $obj.type | Should -Be 'iso-validated'
        $obj.editions.Count | Should -Be 3
    }
    It "produces type-only message when payload is empty" {
        $json = ConvertTo-Tiny11BridgeMessage -Type 'noop'
        $obj = $json | ConvertFrom-Json
        $obj.type | Should -Be 'noop'
    }
}

Describe "Invoke-Tiny11BridgeHandler" {
    It "dispatches by type" {
        $registry = @{ 'ping' = { param($msg) "pong:$($msg.value)" } }
        Invoke-Tiny11BridgeHandler -Registry $registry -Message ([pscustomobject]@{ type='ping'; value=42 }) | Should -Be 'pong:42'
    }
    It "throws on unknown type" {
        { Invoke-Tiny11BridgeHandler -Registry @{} -Message ([pscustomobject]@{ type='ghost' }) } | Should -Throw "*ghost*"
    }
}
