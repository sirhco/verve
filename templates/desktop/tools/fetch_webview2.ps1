# fetch_webview2.ps1 — download the Microsoft.Web.WebView2 NuGet package
# at the version pinned in `webview2.pinned.txt` and unpack it into
# `third_party/webview2/`. Idempotent: refuses to overwrite an
# existing SDK unless `-Force` is passed.
#
# Run from the project root: `pwsh -File tools\fetch_webview2.ps1`.
# CI wires this through `build.zig` on Windows builds so contributors
# do not need to manually drag the .lib out of the .nupkg zip.

[CmdletBinding()]
param(
    [string] $Dest = "third_party/webview2",
    [switch] $Force
)

$ErrorActionPreference = "Stop"

$PinFile = Join-Path $PSScriptRoot "webview2.pinned.txt"
if (-not (Test-Path $PinFile)) {
    Write-Error "fetch_webview2.ps1: missing $PinFile"
}

$pins = @{}
Get-Content $PinFile | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^\s*$') { return }
    if ($_ -match '^(?<k>[^=]+)=(?<v>.*)$') {
        $pins[$Matches.k.Trim()] = $Matches.v.Trim()
    }
}

$Version = $pins['version']
$Sha512 = $pins['sha512']
if (-not $Version) {
    Write-Error "fetch_webview2.ps1: webview2.pinned.txt has no version= line"
}

$LibPath = Join-Path $Dest "WebView2Loader.dll.lib"
if ((Test-Path $LibPath) -and -not $Force) {
    Write-Host "fetch_webview2.ps1: $LibPath already exists (pass -Force to refresh)"
    exit 0
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$Tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath()) -Name ([System.Guid]::NewGuid().ToString())
$Nupkg = Join-Path $Tmp.FullName "webview2.nupkg"

$Url = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version"
Write-Host "fetch_webview2.ps1: downloading $Url"
Invoke-WebRequest -Uri $Url -OutFile $Nupkg -UseBasicParsing

if ($Sha512) {
    Write-Host "fetch_webview2.ps1: verifying SHA-512 against pin"
    $Hasher = [System.Security.Cryptography.SHA512]::Create()
    $Stream = [System.IO.File]::OpenRead($Nupkg)
    try {
        $Bytes = $Hasher.ComputeHash($Stream)
    } finally {
        $Stream.Close()
    }
    $Actual = [System.Convert]::ToBase64String($Bytes)
    if ($Actual -ne $Sha512) {
        Write-Error "fetch_webview2.ps1: SHA mismatch`n  expected: $Sha512`n  actual:   $Actual"
    }
} else {
    Write-Host "fetch_webview2.ps1: WARNING — webview2.pinned.txt has no sha512= value, skipping verification"
}

$Unpacked = Join-Path $Tmp.FullName "unpacked"
Expand-Archive -Path $Nupkg -DestinationPath $Unpacked -Force

$SrcLib = Join-Path $Unpacked "build\native\x64\WebView2Loader.dll.lib"
$SrcDll = Join-Path $Unpacked "build\native\x64\WebView2Loader.dll"
if (-not (Test-Path $SrcLib)) {
    Write-Error "fetch_webview2.ps1: extracted package missing $SrcLib"
}

Copy-Item -Path $SrcLib -Destination (Join-Path $Dest "WebView2Loader.dll.lib") -Force
if (Test-Path $SrcDll) {
    Copy-Item -Path $SrcDll -Destination (Join-Path $Dest "WebView2Loader.dll") -Force
}

Remove-Item -Recurse -Force $Tmp.FullName
Write-Host "fetch_webview2.ps1: installed WebView2 $Version into $Dest"
