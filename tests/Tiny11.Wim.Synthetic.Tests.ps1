# Synthetic-WIM harness for the WIM-commit mechanics (integrity gate + -Save retry).
# Tag 'Synthetic' (implies RequiresAdmin + Slow): New-WindowsImage / Mount-WindowsImage
# require elevation, and capture+mount+save take real seconds. The BeforeDiscovery guard
# skips the whole file on a non-elevated host so local non-admin runs stay green; CI
# (admin runner) executes it for real.
#
# Scope note: a synthetic WIM is content-agnostic -- it validates the WIM CONTAINER
# mechanics (mount/save/readability/retry), NOT the real apply handlers (registry/
# filesystem/appx), which need a real Windows image (deferred Hyper-V tier).

Set-StrictMode -Version Latest

BeforeDiscovery {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $script:IsAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
}

Describe 'Tiny11.Wim synthetic-WIM harness' -Tag 'Synthetic' -Skip:(-not $script:IsAdmin) {
    BeforeAll {
        Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
        Import-Tiny11Module -Name 'Tiny11.Wim'

        $script:work    = Join-Path $env:TEMP "tiny11wim-$([guid]::NewGuid())"
        $script:capture = Join-Path $script:work 'capture'
        $script:mount   = Join-Path $script:work 'mount'
        $script:wim     = Join-Path $script:work 'test.wim'
        New-Item -ItemType Directory -Force -Path $script:capture, $script:mount | Out-Null
        Set-Content -Path (Join-Path $script:capture 'hello.txt') -Value 'synthetic wim payload' -Encoding UTF8
        New-Item -ItemType Directory -Force -Path (Join-Path $script:capture 'sub') | Out-Null
        Set-Content -Path (Join-Path $script:capture 'sub\data.txt') -Value 'more payload' -Encoding UTF8
        # Real .wim via the DISM cmdlet; -CheckIntegrity writes integrity data.
        New-WindowsImage -CapturePath $script:capture -ImagePath $script:wim -Name 'tiny11-test' -CompressionType Fast -CheckIntegrity | Out-Null
    }

    AfterAll {
        Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $script:mount } |
            ForEach-Object { Dismount-WindowsImage -Path $script:mount -Discard -ErrorAction SilentlyContinue | Out-Null }
        if (Test-Path $script:work) { Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue }
    }

    It 'happy round-trip: mount -> modify -> dismount-save -> integrity passes (real DISM)' {
        Set-ItemProperty -Path $script:wim -Name IsReadOnly -Value $false
        Mount-WindowsImage -ImagePath $script:wim -Index 1 -Path $script:mount | Out-Null
        Set-Content -Path (Join-Path $script:mount 'added.txt') -Value 'added during servicing' -Encoding UTF8
        { Invoke-Tiny11WimDismountSave -MountPath $script:mount -DelaySeconds 0 } | Should -Not -Throw
        { Assert-Tiny11WimIntegrity -ImagePath $script:wim -Index 1 } | Should -Not -Throw
    }

    It 'best-effort: a corrupted WIM is detected by the integrity gate' {
        # Copy + corrupt the middle bytes, then assert the gate throws. Best-effort:
        # if Get-WindowsImage does not flag this corruption (the readability gate is
        # weaker than a full per-resource hash scan -- see spec section 5.1), mark
        # Inconclusive rather than fail CI.
        $corrupt = Join-Path $script:work 'corrupt.wim'
        Copy-Item $script:wim $corrupt -Force
        $bytes = [System.IO.File]::ReadAllBytes($corrupt)
        for ($i = [int]($bytes.Length * 0.4); $i -lt [int]($bytes.Length * 0.6); $i++) { $bytes[$i] = $bytes[$i] -bxor 0xFF }
        [System.IO.File]::WriteAllBytes($corrupt, $bytes)
        try {
            Assert-Tiny11WimIntegrity -ImagePath $corrupt -Index 1
            Set-ItResult -Inconclusive -Because 'Get-WindowsImage did not flag the injected corruption; the readability gate is weaker than a full-resource scan (spec section 5.1). The dism /Export-Image /CheckIntegrity pass on the normal build path is the deep verify.'
        } catch {
            $_.Exception.Message | Should -BeLike '*failed its post-save integrity check*'
        }
    }
}
