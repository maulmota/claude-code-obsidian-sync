# install.ps1: Install claude-sync for Windows
# Can be run from a clone or piped from a remote URL:
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/maulmota/claude-code-obsidian-sync/main/install.ps1 | iex"

$ErrorActionPreference = "Stop"

$Repo = "maulmota/claude-code-obsidian-sync"
$InstallDir = Join-Path (Join-Path $HOME ".local") "bin"
$ScriptName = "claude-sync.ps1"
$CmdName = "claude-sync.cmd"

Write-Host "claude-code-obsidian-sync installer"
Write-Host ""

# Determine source: local clone vs remote download
$ScriptDir = $PSScriptRoot

if ($ScriptDir -and (Test-Path (Join-Path $ScriptDir $ScriptName))) {
    # Running from a local clone
    $SourcePS1 = Join-Path $ScriptDir $ScriptName
    $SourceCMD = Join-Path $ScriptDir $CmdName
    $IsLocal = $true
    Write-Host "Installing from local clone..."
} else {
    # Running via irm | iex or $PSScriptRoot is empty --download both files
    $IsLocal = $false
    Write-Host "Downloading claude-sync from GitHub..."

    $SourcePS1 = Join-Path $env:TEMP "claude-sync.ps1"
    $SourceCMD = Join-Path $env:TEMP "claude-sync.cmd"

    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/main/$ScriptName" -OutFile $SourcePS1 -UseBasicParsing
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/main/$CmdName" -OutFile $SourceCMD -UseBasicParsing
}

# Check Developer Mode
$devMode = $false
try {
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    if (Test-Path $regPath) {
        $val = Get-ItemProperty -Path $regPath -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
        if ($val.AllowDevelopmentWithoutDevLicense -eq 1) {
            $devMode = $true
        }
    }
} catch {}

if (-not $devMode) {
    Write-Host ""
    Write-Host "Warning: Developer Mode does not appear to be enabled."
    Write-Host "  claude-sync requires Developer Mode for symlinks."
    Write-Host "  Enable it: Settings > System > For Developers > Developer Mode ON"
    Write-Host ""
}

# Install
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Copy-Item $SourcePS1 (Join-Path $InstallDir $ScriptName) -Force
Copy-Item $SourceCMD (Join-Path $InstallDir $CmdName) -Force

Write-Host "Installed to $InstallDir"
Write-Host "  $ScriptName"
Write-Host "  $CmdName"

# Clean up temp files if downloaded
if (-not $IsLocal) {
    Remove-Item $SourcePS1 -Force -ErrorAction SilentlyContinue
    Remove-Item $SourceCMD -Force -ErrorAction SilentlyContinue
}

# Check PATH
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$inPath = $false
if ($userPath) {
    foreach ($entry in $userPath -split ";") {
        if ($entry.TrimEnd("\") -eq $InstallDir.TrimEnd("\")) {
            $inPath = $true
            break
        }
    }
}

if (-not $inPath) {
    Write-Host ""
    Write-Host "$InstallDir is not on your PATH."
    $addPath = Read-Host "Add it to your user PATH? [Y/n]"
    if (-not $addPath -or $addPath -match "^[Yy]") {
        if ($userPath) {
            $newPath = "$userPath;$InstallDir"
        } else {
            $newPath = $InstallDir
        }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Host "Added to user PATH. Open a new terminal for this to take effect."
    } else {
        Write-Host "Add this directory to your PATH manually:"
        Write-Host "  $InstallDir"
    }
}

# Offer to run init
Write-Host ""
$runInit = Read-Host "Run 'claude-sync init' now? [Y/n]"
if (-not $runInit -or $runInit -match "^[Yy]") {
    Write-Host ""
    $syncScript = Join-Path $InstallDir $ScriptName
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $syncScript init
}

Write-Host ""
Write-Host "Done! claude-sync is ready to use."
