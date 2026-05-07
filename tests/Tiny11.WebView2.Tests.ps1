Set-StrictMode -Version 3.0
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.WebView2'

Describe "Get-Tiny11WebView2SdkPath" {
    It "returns paths under repo dependencies/webview2/<version>/" {
        $r = Get-Tiny11WebView2SdkPath
        $r.CoreDll   | Should -Match 'Microsoft\.Web\.WebView2\.Core\.dll$'
        $r.WpfDll    | Should -Match 'Microsoft\.Web\.WebView2\.Wpf\.dll$'
        $r.NativeDll | Should -Match 'WebView2Loader\.dll$'
        $r.VersionDir | Should -Match 'dependencies[\\/]webview2[\\/]1\.0\.2535\.41$'
    }
    It "honors -RepoRoot override" {
        $tmp = New-TempScratchDir
        try {
            $r = Get-Tiny11WebView2SdkPath -RepoRoot $tmp
            $r.CoreDll | Should -BeLike "$tmp*dependencies*webview2*Microsoft.Web.WebView2.Core.dll"
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
}

Describe "Test-Tiny11WebView2SdkPresent" {
    It "returns paths object when all 3 DLLs present" {
        $tmp = New-TempScratchDir
        try {
            $verDir = Join-Path $tmp 'dependencies\webview2\1.0.2535.41'
            New-Item -ItemType Directory -Force -Path $verDir | Out-Null
            New-Item -ItemType File -Path (Join-Path $verDir 'Microsoft.Web.WebView2.Core.dll') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $verDir 'Microsoft.Web.WebView2.Wpf.dll') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $verDir 'WebView2Loader.dll') -Force | Out-Null
            $r = Test-Tiny11WebView2SdkPresent -RepoRoot $tmp
            $r.CoreDll   | Should -Exist
            $r.WpfDll    | Should -Exist
            $r.NativeDll | Should -Exist
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
    It "throws with helpful message when no DLLs present" {
        $tmp = New-TempScratchDir
        try {
            { Test-Tiny11WebView2SdkPresent -RepoRoot $tmp } | Should -Throw -ExpectedMessage '*WebView2 SDK DLL missing*'
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
    It "throws when only some DLLs are present" {
        $tmp = New-TempScratchDir
        try {
            $verDir = Join-Path $tmp 'dependencies\webview2\1.0.2535.41'
            New-Item -ItemType Directory -Force -Path $verDir | Out-Null
            New-Item -ItemType File -Path (Join-Path $verDir 'Microsoft.Web.WebView2.Core.dll') -Force | Out-Null
            { Test-Tiny11WebView2SdkPresent -RepoRoot $tmp } | Should -Throw -ExpectedMessage '*WebView2 SDK DLL missing*'
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
    It "finds the vendored DLLs in the repo (integration)" {
        $r = Test-Tiny11WebView2SdkPresent
        Test-Path $r.CoreDll   | Should -BeTrue
        Test-Path $r.WpfDll    | Should -BeTrue
        Test-Path $r.NativeDll | Should -BeTrue
    }
}

Describe "Test-Tiny11WebView2RuntimeInstalled" {
    It "returns true when registry indicates Runtime is installed" {
        Mock -CommandName 'Test-Path'        -MockWith { $true }                                  -ModuleName 'Tiny11.WebView2'
        Mock -CommandName 'Get-ItemProperty' -MockWith { [pscustomobject]@{ pv = '120.0.6099.130' } } -ModuleName 'Tiny11.WebView2'
        Test-Tiny11WebView2RuntimeInstalled | Should -BeTrue
    }
    It "returns false when no registry key indicates Runtime" {
        Mock -CommandName 'Test-Path' -MockWith { $false } -ModuleName 'Tiny11.WebView2'
        Test-Tiny11WebView2RuntimeInstalled | Should -BeFalse
    }
}
