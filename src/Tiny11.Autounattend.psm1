Set-StrictMode -Version Latest

$EmbeddedTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideOnlineAccountScreens>{{HIDE_ONLINE_ACCOUNT_SCREENS}}</HideOnlineAccountScreens>
            </OOBE>
        </component>
    </settings>
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        <ConfigureChatAutoInstall>{{CONFIGURE_CHAT_AUTO_INSTALL}}</ConfigureChatAutoInstall>
    </component>
    <settings pass="windowsPE">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <DynamicUpdate>
                <WillShowUI>OnError</WillShowUI>
            </DynamicUpdate>
            <ImageInstall>
                <OSImage>
                    <Compact>{{COMPACT_INSTALL}}</Compact>
                    <WillShowUI>OnError</WillShowUI>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>{{IMAGE_INDEX}}</Value>
                        </MetaData>
                    </InstallFrom>
                </OSImage>
            </ImageInstall>
            <UserData>
                <ProductKey>
                    <Key/>
                </ProductKey>
            </UserData>
        </component>
    </settings>
</unattend>
'@

$ForkTemplateUrl = 'https://raw.githubusercontent.com/bilbospocketses/tiny11options/refs/heads/main/autounattend.template.xml'

function Render-Tiny11Autounattend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Bindings
    )
    $remaining = [regex]::Matches($Template, '\{\{([A-Z_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    foreach ($key in $remaining) {
        if (-not $Bindings.ContainsKey($key)) { throw "Autounattend template has unknown placeholder: $key" }
    }
    $output = $Template
    foreach ($k in $Bindings.Keys) { $output = $output.Replace("{{$k}}", [string]$Bindings[$k]) }
    $output
}

function Get-Tiny11AutounattendBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ResolvedSelections,
        [Parameter(Mandatory)][int]$ImageIndex
    )
    function State($id) { if ($ResolvedSelections.ContainsKey($id)) { $ResolvedSelections[$id].EffectiveState } else { 'apply' } }
    $hideOnline = if ((State 'tweak-bypass-nro') -eq 'apply') { 'true' } else { 'false' }
    $chatAuto   = if ((State 'tweak-disable-chat-icon') -eq 'apply') { 'false' } else { 'true' }
    $compact    = if ((State 'tweak-compact-install') -eq 'apply') { 'true' } else { 'false' }
    @{
        HIDE_ONLINE_ACCOUNT_SCREENS = $hideOnline
        CONFIGURE_CHAT_AUTO_INSTALL = $chatAuto
        COMPACT_INSTALL             = $compact
        IMAGE_INDEX                 = "$ImageIndex"
    }
}

function Get-Tiny11AutounattendTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LocalPath)

    if (Test-Path $LocalPath) {
        $localContent = [System.IO.File]::ReadAllText($LocalPath)
        $localContent = $localContent -replace '(\r?\n)+$', ''
        return [pscustomobject]@{ Source='Local'; Content=$localContent }
    }
    try {
        $content = Invoke-RestMethod -Uri $ForkTemplateUrl -ErrorAction Stop
        Set-Content -Path $LocalPath -Value $content -Encoding UTF8
        return [pscustomobject]@{ Source='Network'; Content=$content }
    } catch {
        Write-Warning "autounattend template fetch from $ForkTemplateUrl failed; using embedded fallback. ($_)"
        return [pscustomobject]@{ Source='Embedded'; Content=$EmbeddedTemplate }
    }
}

function Get-Tiny11EmbeddedAutounattend { $EmbeddedTemplate }

Export-ModuleMember -Function Render-Tiny11Autounattend, Get-Tiny11AutounattendBindings, Get-Tiny11AutounattendTemplate, Get-Tiny11EmbeddedAutounattend
