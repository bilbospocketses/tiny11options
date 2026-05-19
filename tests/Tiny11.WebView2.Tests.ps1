Set-StrictMode -Version 3.0
Import-Module "$PSScriptRoot/Tiny11.TestHelpers.psm1" -Force
Import-Tiny11Module -Name 'Tiny11.WebView2'

Describe "Get-Tiny11WebView2SdkPath" {
    It "returns paths under the NuGet packages cache for microsoft.web.webview2/<version>" {
        $r = Get-Tiny11WebView2SdkPath
        $r.CoreDll   | Should -Match 'lib[\\/]net462[\\/]Microsoft\.Web\.WebView2\.Core\.dll$'
        $r.WpfDll    | Should -Match 'lib[\\/]net462[\\/]Microsoft\.Web\.WebView2\.Wpf\.dll$'
        $r.NativeDll | Should -Match 'runtimes[\\/]win-x64[\\/]native[\\/]WebView2Loader\.dll$'
        $r.VersionDir | Should -Match 'microsoft\.web\.webview2[\\/]1\.0\.2535\.41$'
    }
    It "honors -NugetPackagesRoot override" {
        $tmp = New-TempScratchDir
        try {
            $r = Get-Tiny11WebView2SdkPath -NugetPackagesRoot $tmp
            $r.CoreDll | Should -BeLike "$tmp*microsoft.web.webview2*1.0.2535.41*lib*net462*Microsoft.Web.WebView2.Core.dll"
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
    It "honors NUGET_PACKAGES environment variable when -NugetPackagesRoot is omitted" {
        $tmp = New-TempScratchDir
        $original = $env:NUGET_PACKAGES
        try {
            $env:NUGET_PACKAGES = $tmp
            $r = Get-Tiny11WebView2SdkPath
            $r.CoreDll | Should -BeLike "$tmp*microsoft.web.webview2*1.0.2535.41*lib*net462*Microsoft.Web.WebView2.Core.dll"
        } finally {
            $env:NUGET_PACKAGES = $original
            Remove-TempScratchDir -Path $tmp
        }
    }
}

Describe "Test-Tiny11WebView2SdkPresent" {
    It "returns paths object when all 3 DLLs present" {
        $tmp = New-TempScratchDir
        try {
            $libDir    = Join-Path $tmp 'microsoft.web.webview2\1.0.2535.41\lib\net462'
            $nativeDir = Join-Path $tmp 'microsoft.web.webview2\1.0.2535.41\runtimes\win-x64\native'
            New-Item -ItemType Directory -Force -Path $libDir    | Out-Null
            New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null
            New-Item -ItemType File -Path (Join-Path $libDir    'Microsoft.Web.WebView2.Core.dll') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $libDir    'Microsoft.Web.WebView2.Wpf.dll')  -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $nativeDir 'WebView2Loader.dll')              -Force | Out-Null
            $r = Test-Tiny11WebView2SdkPresent -NugetPackagesRoot $tmp
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
            { Test-Tiny11WebView2SdkPresent -NugetPackagesRoot $tmp } | Should -Throw -ExpectedMessage '*WebView2 SDK DLL missing*'
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
    It "throws with dotnet restore hint when no DLLs present" {
        $tmp = New-TempScratchDir
        try {
            { Test-Tiny11WebView2SdkPresent -NugetPackagesRoot $tmp } | Should -Throw -ExpectedMessage '*dotnet restore*'
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
    It "throws when only some DLLs are present" {
        $tmp = New-TempScratchDir
        try {
            $libDir = Join-Path $tmp 'microsoft.web.webview2\1.0.2535.41\lib\net462'
            New-Item -ItemType Directory -Force -Path $libDir | Out-Null
            New-Item -ItemType File -Path (Join-Path $libDir 'Microsoft.Web.WebView2.Core.dll') -Force | Out-Null
            { Test-Tiny11WebView2SdkPresent -NugetPackagesRoot $tmp } | Should -Throw -ExpectedMessage '*WebView2 SDK DLL missing*'
        } finally {
            Remove-TempScratchDir -Path $tmp
        }
    }
    It "finds the NuGet-restored DLLs after dotnet restore (integration)" {
        # Requires `dotnet restore launcher/tiny11options.Launcher.csproj` to have populated
        # the NuGet cache. CI runs Restore before Test (Pester); local dev box has the cache
        # warm from any prior build. Documented in CONTRIBUTING.md.
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
