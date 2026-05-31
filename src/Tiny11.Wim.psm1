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

function Invoke-Tiny11WimDismountSave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter()][int]$Attempts = 3,
        [Parameter()][int]$DelaySeconds = 2
    )
    # Dismount-WindowsImage -Save is the big, slow write that commits every offline
    # modification back into the WIM. Under a transient lock (Defender real-time scan,
    # Search indexer, Controlled Folder Access, a lingering handle) it can fail. Retry
    # a bounded number of times with exponential backoff (base $DelaySeconds, x2 each
    # attempt) before giving up. Retry-on-any: the cost of retrying a genuine
    # (non-transient) dism error is just the backoff before the same failure resurfaces
    # -- acceptable for a step this critical.
    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Dismount-WindowsImage -Path $MountPath -Save -ErrorAction Stop | Out-Null
            return
        } catch {
            $lastError = $_
            if ($attempt -lt $Attempts) {
                $backoff = [int]($DelaySeconds * [math]::Pow(2, $attempt - 1))
                if ($backoff -gt 0) { Start-Sleep -Seconds $backoff }
            }
        }
    }
    throw "Dismount-WindowsImage -Save failed for '$MountPath' after $Attempts attempt(s): $($lastError.Exception.Message)"
}

Export-ModuleMember -Function Assert-Tiny11WimIntegrity, Invoke-Tiny11WimDismountSave
