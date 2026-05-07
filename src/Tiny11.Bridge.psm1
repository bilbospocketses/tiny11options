Set-StrictMode -Version Latest

function ConvertTo-Tiny11BridgeMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Type, [hashtable]$Payload = @{})
    $combined = [ordered]@{ type = $Type }
    foreach ($k in $Payload.Keys) { $combined[$k] = $Payload[$k] }
    $combined | ConvertTo-Json -Depth 10 -Compress
}

function Invoke-Tiny11BridgeHandler {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Registry, [Parameter(Mandatory)] $Message)
    if (-not $Registry.ContainsKey($Message.type)) {
        throw "No handler registered for message type: $($Message.type)"
    }
    & $Registry[$Message.type] $Message
}

Export-ModuleMember -Function ConvertTo-Tiny11BridgeMessage, Invoke-Tiny11BridgeHandler
