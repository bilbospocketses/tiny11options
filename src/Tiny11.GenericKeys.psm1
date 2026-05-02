Set-StrictMode -Version Latest

# Microsoft-published generic install keys (KMS client setup keys).
# These let Windows Setup proceed without activating the OS — the user
# enters their real key after install (or the system stays in
# "activation pending" mode, which is functionally identical for testing).
# Source: https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys
$script:GenericKeys = @{
    'Windows 11 Home'                   = 'TX9XD-98N7V-6WMQ6-BX7FG-H8Q99'
    'Windows 11 Home N'                 = '3KHY7-WNT83-DGQKR-F7HPR-844BM'
    'Windows 11 Home Single Language'   = '7HNRX-D7KGG-3K4RQ-4WPJ4-YTDFH'
    'Windows 11 Home Country Specific'  = 'PVMJN-6DFY6-9CCP6-7BKTT-D3WVR'
    'Windows 11 Pro'                    = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
    'Windows 11 Pro N'                  = 'MH37W-N47XK-V7XM9-C7227-GCQG9'
    'Windows 11 Pro Education'          = '6TP4R-GNPTD-KYYHQ-7B7DP-J447Y'
    'Windows 11 Pro Education N'        = 'YVWGF-BXNMC-HTQYQ-CPQ99-66QFC'
    'Windows 11 Pro for Workstations'   = 'NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J'
    'Windows 11 Pro N for Workstations' = '9FNHH-K3HBT-3W4TD-6383H-6XYWF'
    'Windows 11 Education'              = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
    'Windows 11 Education N'            = '2WH4N-8QGBV-H22JP-CT43Q-MDWWJ'
    'Windows 11 Enterprise'             = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
    'Windows 11 Enterprise N'           = 'DPH2V-TTNVB-4X9Q3-TJR4H-KHJW4'
}

function Get-Tiny11GenericKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EditionName)
    if (-not $script:GenericKeys.ContainsKey($EditionName)) {
        throw "No generic install key known for edition '$EditionName'. Known editions: $($script:GenericKeys.Keys -join ', ')"
    }
    $script:GenericKeys[$EditionName]
}

function Get-Tiny11KnownEditions {
    [CmdletBinding()] param()
    @($script:GenericKeys.Keys | Sort-Object)
}

Export-ModuleMember -Function Get-Tiny11GenericKey, Get-Tiny11KnownEditions
