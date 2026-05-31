Set-StrictMode -Version Latest

function Assert-Tiny11WimIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index
    )
    # Validate the WIM is structurally readable -- its header + the serviced image's
    # metadata parse. Get-WindowsImage throws on a truncated / corrupt-header WIM, the
    # gross form of a silent partial Dismount-WindowsImage -Save commit (transient host
    # interference: AV scan, Search indexer, Controlled Folder Access, a stray handle)
    # -- before oscdimg wraps a broken install.wim into an ISO that fails Windows Setup
    # at the file-copy step. NOTE: this is a readability gate, not a per-resource hash
    # scan -- Get-WindowsImage has no -CheckIntegrity parameter (that switch is on the
    # write/mount/export cmdlets). The deep, full-resource verify is the
    # `dism /Export-Image ... /CheckIntegrity` pass on the normal (non-FastBuild) path.
    try {
        Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop | Out-Null
    } catch {
        throw ("Build aborted -- '$ImagePath' (index $Index) failed its post-save integrity check; " +
               "the image was NOT shipped. Likely transient host interference (AV real-time scan / " +
               "Windows Search indexer / Controlled Folder Access / a stray file handle). Re-run the build. " +
               "Underlying error: $($_.Exception.Message)")
    }
}

Export-ModuleMember -Function Assert-Tiny11WimIntegrity
