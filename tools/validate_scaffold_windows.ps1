<#
Regression guard: scaffold + build + verify Windows desktop apps end-to-end.

Reproduces the CI `scaffold-and-smoke` job (.github/workflows/desktop.yml) on a
local Windows machine, for BOTH the `full` and `minimal` desktop templates:

  1. build verve-cli from this checkout
  2. scaffold a desktop app (path-dep back to this checkout via --verve-path)
  3. zig build the scaffolded app (native)
  4. assert app.exe + WebView2Loader.dll landed in zig-out/bin
  5. exercise it:
       - full   : run `app.exe --smoke <dir>` and require checksum.txt + a clean
                  self-terminate. This is the RIGOROUS gate — the self-driving
                  harness only writes checksum.txt after the page loads, the WASM
                  client hydrates, an IPC round-trip completes, and a webview
                  snapshot succeeds. It catches blank-webview / broken-IPC
                  regressions that the per-app `smoke_windows.ps1` (a bare screen
                  capture) silently passes.
       - minimal: launch app.exe, confirm it doesn't exit early / crash, capture
                  a screenshot (no self-driving smoke harness in this template).

Needs the WebView2 Evergreen runtime installed (preinstalled on Win11).

Usage:
  pwsh -File tools/validate_scaffold_windows.ps1 [-WorkDir <dir>] [-Keep]
#>

param(
    [string]$WorkDir = (Join-Path $env:TEMP "verve-scaffold-validate"),
    [int]$SmokeTimeoutSecs = 30,
    [switch]$Keep
)

$ErrorActionPreference = "Stop"

# Repo root = parent of this script's tools/ directory.
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Cli = Join-Path $RepoRoot "zig-out\bin\verve-cli.exe"
$ResultsDir = Join-Path $WorkDir "_results"

function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

Write-Host "== Verve Windows scaffold validation ==" -ForegroundColor Cyan
Write-Host "repo:    $RepoRoot"
Write-Host "workdir: $WorkDir"

# --- 1. Build verve-cli ------------------------------------------------------
Write-Host "`n[1/3] building verve-cli ..." -ForegroundColor Cyan
Push-Location $RepoRoot
try { & zig build; if ($LASTEXITCODE -ne 0) { Fail "framework 'zig build' failed" } }
finally { Pop-Location }
if (-not (Test-Path $Cli)) { Fail "verve-cli not found at $Cli" }

# Fresh work dir.
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# Validate one template; returns $true on PASS.
function Test-Template {
    param([string]$Name, [string[]]$ScaffoldArgs, [bool]$RunSmoke)

    Write-Host "`n--- template: $Name ---" -ForegroundColor Cyan
    $dir = Join-Path $WorkDir $Name

    # scaffold. Pipe native-command output to the host so it doesn't pollute
    # this function's return value (PowerShell folds stray stdout into output).
    $cliArgs = @("new", $Name, "--desktop", "--name", "app",
                 "--verve-path", $RepoRoot) + $ScaffoldArgs
    Push-Location $WorkDir
    try { & $Cli @cliArgs | Out-Host; if ($LASTEXITCODE -ne 0) { Write-Host "  scaffold failed" -ForegroundColor Red; return $false } }
    finally { Pop-Location }

    # build
    Push-Location $dir
    try {
        & zig build | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Host "  'zig build' failed" -ForegroundColor Red; return $false }

        $exe = Join-Path $dir "zig-out\bin\app.exe"
        $dll = Join-Path $dir "zig-out\bin\WebView2Loader.dll"
        if (-not (Test-Path $exe)) { Write-Host "  missing app.exe" -ForegroundColor Red; return $false }
        if (-not (Test-Path $dll)) { Write-Host "  missing WebView2Loader.dll" -ForegroundColor Red; return $false }
        Write-Host "  build OK: app.exe + WebView2Loader.dll present"

        if ($RunSmoke) {
            # Rigorous gate: --smoke must write checksum.txt AND self-terminate.
            $sdir = Join-Path $dir ".validate-smoke"
            if (Test-Path $sdir) { Remove-Item -Recurse -Force $sdir }
            New-Item -ItemType Directory -Force -Path $sdir | Out-Null
            $proc = Start-Process -FilePath $exe -ArgumentList @("--smoke", $sdir) -PassThru
            if (-not $proc.WaitForExit($SmokeTimeoutSecs * 1000)) {
                Stop-Process -Id $proc.Id -Force
                Write-Host "  --smoke HUNG (>${SmokeTimeoutSecs}s, no self-terminate)" -ForegroundColor Red
                return $false
            }
            $cksum = Join-Path $sdir "checksum.txt"
            $shot  = Join-Path $sdir "shot.png"
            if (-not (Test-Path $cksum)) { Write-Host "  --smoke wrote no checksum.txt (load/WASM/IPC/snapshot failed)" -ForegroundColor Red; return $false }
            if (Test-Path $shot) { Copy-Item $shot (Join-Path $ResultsDir "$Name-shot.png") -Force }
            Write-Host "  --smoke OK: checksum=$(Get-Content $cksum) (full round-trip verified)"
        } else {
            # Launch sanity: app must stay up (no early crash) for a few seconds.
            $proc = Start-Process -FilePath $exe -PassThru
            Start-Sleep -Seconds 3
            if ($proc.HasExited) {
                Write-Host "  app exited early (code $($proc.ExitCode))" -ForegroundColor Red
                return $false
            }
            try {
                Add-Type -AssemblyName System.Drawing
                Add-Type -AssemblyName System.Windows.Forms
                $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
                $bmp.Save((Join-Path $ResultsDir "$Name-shot.png"), [System.Drawing.Imaging.ImageFormat]::Png)
                $g.Dispose(); $bmp.Dispose()
            } catch { }
            Stop-Process -Id $proc.Id -Force
            Write-Host "  launch OK: app stayed up, screenshot captured"
        }
        return $true
    }
    finally { Pop-Location }
}

# --- 2/3. Validate both templates -------------------------------------------
$results = [ordered]@{}
$results["full"]    = Test-Template -Name "full"    -ScaffoldArgs @()                      -RunSmoke $true
$results["minimal"] = Test-Template -Name "minimal" -ScaffoldArgs @("--template=minimal") -RunSmoke $false

# --- Summary -----------------------------------------------------------------
Write-Host "`n== Summary ==" -ForegroundColor Cyan
$allPass = $true
foreach ($k in $results.Keys) {
    if ($results[$k]) { Write-Host ("  {0,-8} PASS" -f $k) -ForegroundColor Green }
    else { Write-Host ("  {0,-8} FAIL" -f $k) -ForegroundColor Red; $allPass = $false }
}
Write-Host "  screenshots: $ResultsDir"

if (-not $Keep) {
    foreach ($k in $results.Keys) {
        $d = Join-Path $WorkDir $k
        if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
    }
}

if ($allPass) { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
else { Write-Host "`nFAILED" -ForegroundColor Red; exit 1 }
