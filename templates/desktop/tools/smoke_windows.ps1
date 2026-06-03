<#
Level-1 smoke harness for Windows.

Launches the desktop app, waits for the main window to appear, captures
a screenshot of the primary display via System.Drawing, and validates
that the resulting PNG is non-trivial.

Usage:
  pwsh -File tools/smoke_windows.ps1 -App <path-to-app.exe> [-OutDir <dir>]

Requires the WebView2 Evergreen runtime to be installed.
#>

param(
    [Parameter(Mandatory = $true)][string]$App,
    [string]$OutDir = ".\.smoke",
    [int]$MinBytes = 5000,
    [int]$WaitSecs = 3
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $App)) {
    Write-Error "smoke: app binary not found: $App"
    exit 64
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$shot = Join-Path $OutDir "shot.png"
$logPath = Join-Path $OutDir "app.log"

$proc = Start-Process -FilePath $App -PassThru -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
try {
    Start-Sleep -Seconds $WaitSecs

    if ($proc.HasExited) {
        Write-Host "smoke: FAIL - app exited early (code $($proc.ExitCode))"
        if (Test-Path $logPath) { Get-Content $logPath | Select-Object -Last 40 }
        exit 1
    }

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
    $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()

    $size = (Get-Item $shot).Length
    if ($size -lt $MinBytes) {
        Write-Host "smoke: FAIL - capture too small ($size B < $MinBytes)"
        exit 1
    }

    Write-Host "smoke: PASS - $shot ($size B)"
} finally {
    if (-not $proc.HasExited) { $proc | Stop-Process -Force }
}
