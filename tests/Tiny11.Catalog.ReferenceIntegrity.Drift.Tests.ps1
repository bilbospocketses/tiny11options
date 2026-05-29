Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Catalog'

Describe "Catalog-ID reference integrity (production code)" {
    # Defense-in-depth (v1.0.25): the autounattend orphan-reference bug was a hardcoded
    # catalog ID ('tweak-compact-install') referenced by production code but absent from
    # catalog.json. This scan fails if ANY production-runtime file hardcodes a catalog-ID
    # literal that isn't in catalog.json -- stopping the whole class from recurring rather
    # than fixing only the one instance.
    #
    # Scope: PowerShell modules, top-level orchestrator scripts, and the C# launcher.
    # Excludes tests/ (fixtures legitimately fabricate IDs) and docs/ (specs reference
    # planned IDs). A catalog-ID literal = a known catalog prefix + kebab tail, quoted.
    BeforeAll {
        $script:repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
        $catalog = Get-Tiny11Catalog -Path "$script:repoRoot/catalog/catalog.json"

        $script:ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($i in $catalog.Items) { [void]$script:ids.Add([string]$i.id) }

        $prefixes = ($catalog.Items | ForEach-Object { ($_.id -split '-', 2)[0] } | Sort-Object -Unique)
        $alt = ($prefixes | ForEach-Object { [regex]::Escape($_) }) -join '|'
        # \x27 = single quote; matches an ID literal wrapped in either ' or " quotes.
        $script:idRegex = '["\x27](?<id>(?:' + $alt + ')-[a-z0-9-]+)["\x27]'

        $script:prodFiles = Get-ChildItem -Recurse -File -Path $script:repoRoot -Include *.psm1, *.ps1, *.cs |
            Where-Object {
                $_.FullName -notmatch '[\\/](bin|obj|\.git|node_modules|dist)[\\/]' -and
                $_.FullName -notmatch '[\\/][Tt]ests[\\/]' -and
                $_.FullName -notmatch '\.Tests\.' -and
                $_.Name -ne 'Tiny11.TestHelpers.psm1'
            }
    }

    It "every hardcoded catalog-ID literal in production code exists in catalog.json" {
        $orphans = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $script:prodFiles) {
            $n = 0
            foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
                $n++
                foreach ($m in [regex]::Matches($line, $script:idRegex)) {
                    $id = $m.Groups['id'].Value
                    if (-not $script:ids.Contains($id)) {
                        $orphans.Add(('{0}:{1}  {2}' -f $f.Name, $n, $id))
                    }
                }
            }
        }
        # On failure Pester prints the offending file:line  id list.
        ($orphans -join "`n") | Should -BeNullOrEmpty
    }
}
