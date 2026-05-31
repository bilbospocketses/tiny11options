Set-StrictMode -Version Latest

$HiveMap = @{
    'COMPONENTS' = 'Windows\System32\config\COMPONENTS'
    'DEFAULT'    = 'Windows\System32\config\default'
    'NTUSER'     = 'Users\Default\ntuser.dat'
    'SOFTWARE'   = 'Windows\System32\config\SOFTWARE'
    'SYSTEM'     = 'Windows\System32\config\SYSTEM'
}

function Resolve-Tiny11HivePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$ScratchDir)
    if (-not $HiveMap.ContainsKey($Hive)) {
        throw "Unknown hive: $Hive (expected one of $($HiveMap.Keys -join ', '))"
    }
    Join-Path $ScratchDir $HiveMap[$Hive]
}

function Get-Tiny11HiveMountKey {
    param([Parameter(Mandatory)][string]$Hive)
    "HKLM\z$Hive"
}

function Get-Tiny11RegExePath {
    # Absolute path to the OS reg.exe rather than PATH resolution. reg.exe is an
    # OS-intrinsic servicing tool (it can't be vendored into the app -- it must be the
    # host's, to operate on the loaded offline hive), so the local-dependency rule is
    # satisfied by pinning the absolute OS path; this also blocks a PATH-hijacked reg.exe.
    # ($env:SystemRoot is the OS root, not a tool-locator env var like %ADB%/$FFMPEG.)
    Join-Path $env:SystemRoot 'System32\reg.exe'
}

function Get-Tiny11DismExePath {
    # Absolute path to the OS (inbox) dism.exe -- same local-deps rationale as
    # Get-Tiny11RegExePath. The build has always used the inbox dism (System32), not the
    # ADK copy; pinning the absolute path keeps that and blocks a PATH-hijacked dism.exe.
    Join-Path $env:SystemRoot 'System32\dism.exe'
}

function Invoke-RegCommand {
    param([Parameter(ValueFromRemainingArguments)][string[]]$RegArgs)
    $captured = (& (Get-Tiny11RegExePath) @RegArgs) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg.exe failed (exit $LASTEXITCODE): $($RegArgs -join ' ')`n$captured" }
}

function Invoke-Tiny11RegExe {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$RegArgs)
    # Run the OS reg.exe (absolute path, child process) and return its exit code + stdout.
    # A child process closes its handles on exit, so -- unlike the .NET registry provider --
    # it never leaves an in-process hive handle that would lock Dismount-WindowsImage -Save.
    # Returning a structured result keeps callers off the ambient $LASTEXITCODE.
    $out = & (Get-Tiny11RegExePath) @RegArgs 2>$null
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
}

function Test-Tiny11HiveLoaded {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive)
    # Is HKLM\z<Hive> currently loaded? Checked via reg.exe (a child process; no in-process
    # handle), NOT `Test-Path` on the provider drive, which opens a .NET RegistryKey handle
    # that survives `reg unload` and locks the mount at Dismount-WindowsImage -Save.
    # `reg query` against a loaded hive root returns exit 0; an unloaded key returns non-zero.
    (Invoke-Tiny11RegExe 'query' (Get-Tiny11HiveMountKey -Hive $Hive)).ExitCode -eq 0
}

function Get-Tiny11RegValueNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,                 # native reg.exe form, e.g. HKLM\zNTUSER\<subkey>
        [Parameter()][string]$NamePattern = '*'
    )
    # Enumerate value names under $Key via reg.exe -- NEVER the .NET registry provider.
    # Get-Item / Get-ItemProperty / Test-Path on an offline-hive provider path cache an
    # in-process RegistryKey handle that keeps the hive's backing file (inside the mount)
    # open after `reg unload`, so Dismount-WindowsImage -Save fails "being used by another
    # process". reg.exe is a child process (handle closed on exit -- deterministic): the
    # reg.exe-only pattern of upstream tiny11builder and Microsoft's offline-servicing docs.
    # `reg query` exits non-zero when the key is absent -> return no names (legitimate no-op).
    $res = Invoke-Tiny11RegExe 'query' $Key
    if ($res.ExitCode -ne 0) { return @() }
    $names = foreach ($line in $res.Output) {
        # reg query value rows: 4-space indent, value NAME, 4-space gap, REG_<type>, gap, data.
        # Anchor on the 4-space + REG_<type> column (value names may themselves contain spaces).
        if ($line -match '^\s{4}(.+?)\s{4}REG_[A-Z_]+\b') { $Matches[1] }
    }
    @($names | Where-Object { $_ -like $NamePattern })
}

function Mount-Tiny11Hive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$ScratchDir)
    $path = Resolve-Tiny11HivePath -Hive $Hive -ScratchDir $ScratchDir
    Invoke-RegCommand 'load' (Get-Tiny11HiveMountKey -Hive $Hive) $path
}

function Dismount-Tiny11Hive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive)
    Invoke-RegCommand 'unload' (Get-Tiny11HiveMountKey -Hive $Hive)
}

function Mount-Tiny11AllHives {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScratchDir)
    foreach ($h in $HiveMap.Keys) { Mount-Tiny11Hive -Hive $h -ScratchDir $ScratchDir }
}

function Dismount-Tiny11AllHives {
    [CmdletBinding()] param()
    foreach ($h in $HiveMap.Keys) {
        try { Dismount-Tiny11Hive -Hive $h } catch { Write-Warning "Failed to unload hive ${h}: $_" }
    }
}

function Clear-Tiny11StaleHives {
    [CmdletBinding()] param()
    # v1.0.26: recover from a prior build that exited with hives still loaded. A stranded
    # HKLM\z<Hive> makes the next build's `reg load` fail with "Access is denied", bricking
    # every subsequent build until manual cleanup. Best-effort + never throws: unload any
    # z-key currently present, ignoring per-hive failures (e.g. a hive genuinely in use).
    # Detection is via reg.exe (Test-Tiny11HiveLoaded), never the provider -- a stranded
    # hive is exactly the case where a Test-Path probe would open a fresh in-process handle.
    $ErrorActionPreference = 'Continue'
    foreach ($h in $HiveMap.Keys) {
        if (Test-Tiny11HiveLoaded -Hive $h) {
            try { Dismount-Tiny11Hive -Hive $h } catch { Write-Warning "Stale-hive recovery: could not unload HKLM\z${h}: $_" }
        }
    }
}

Export-ModuleMember -Function Resolve-Tiny11HivePath, Get-Tiny11HiveMountKey, Get-Tiny11RegExePath, Get-Tiny11DismExePath, Invoke-RegCommand, Invoke-Tiny11RegExe, Test-Tiny11HiveLoaded, Get-Tiny11RegValueNames, Mount-Tiny11Hive, Dismount-Tiny11Hive, Mount-Tiny11AllHives, Dismount-Tiny11AllHives, Clear-Tiny11StaleHives
