Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.Autounattend'

Describe "Embedded autounattend template drift" {
    # Compare line-ending-insensitive: .gitattributes enforces *.psm1 = CRLF and *.xml = LF (default),
    # so the embedded here-string and the file will always have different EOL bytes. The drift we
    # actually care about is content drift (placeholders, structure), not EOL bytes.
    It "embedded constant equals autounattend.template.xml (content-equal modulo EOL + trailing newline)" {
        $filePath = "$PSScriptRoot/../autounattend.template.xml"
        $file     = (Get-Content $filePath -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $file     = $file.TrimEnd("`n")
        $embedded = (Get-Tiny11EmbeddedAutounattend) -replace "`r`n", "`n"
        $embedded = $embedded.TrimEnd("`n")
        $embedded | Should -Be $file
    }
}
