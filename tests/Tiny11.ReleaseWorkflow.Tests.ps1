Describe "release.yml conditional-signing guard" {
    # The two Trusted Signing steps in .github/workflows/release.yml MUST be
    # gated on `if: env.AZURE_TENANT_ID != ''` so unsigned releases (v1.0.0,
    # signing deferred to v1.0.2) can ship without the workflow failing at
    # the sign step. A future workflow edit that drops the guard would
    # silently re-couple release pushes to signing-secret presence.

    BeforeAll {
        $script:workflowPath = "$PSScriptRoot/../.github/workflows/release.yml"
        $script:content      = Get-Content $script:workflowPath -Raw

        # Split on top-level "- name:" markers to get one entry per step.
        $script:steps = [regex]::Split($script:content, "(?m)^      - name: ") |
            Where-Object { $_ -match '^\S' }
    }

    It "release.yml exists" {
        Test-Path $script:workflowPath | Should -BeTrue
    }

    It "exposes AZURE_TENANT_ID at job-level env (so step `if:` guards can read it)" {
        $script:content | Should -Match '(?ms)^    env:.*?AZURE_TENANT_ID: \$\{\{ secrets\.AZURE_TENANT_ID \}\}'
    }

    It "both Trusted Signing steps carry the `if: env.AZURE_TENANT_ID != ''` guard" {
        $signSteps = $script:steps | Where-Object { $_ -match '^Sign.*Trusted Signing' }
        $signSteps.Count | Should -Be 2
        foreach ($step in $signSteps) {
            $step | Should -Match "if: env\.AZURE_TENANT_ID != ''"
        }
    }

    It "no signing step references `secrets.AZURE_*` directly inside `with:` (must go through env)" {
        # Going through env keeps the surface consistent + avoids template-eval
        # surprises when secrets are absent.
        $signSteps = $script:steps | Where-Object { $_ -match '^Sign.*Trusted Signing' }
        foreach ($step in $signSteps) {
            $step | Should -Not -Match '\$\{\{ secrets\.AZURE_'
            $step | Should -Not -Match '\$\{\{ secrets\.TRUSTED_SIGNING_'
        }
    }
}
