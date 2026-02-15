# claude-sync.ps1: Sync Claude Code config across devices via Obsidian
# https://github.com/motapod/claude-code-obsidian-sync
#
# What it does:
#   1. Converts any real .claude/ directories to _claude/ + symlink
#   2. Creates .claude -> _claude symlinks for directories synced from other devices
#   3. Ensures commands/ and memory/ subdirectories exist
#   4. Sets up memory symlinks so auto-memory writes into the vault
#
# Requires: Developer Mode enabled (Settings > System > For Developers)

param(
    [Parameter(Position=0)]
    [string]$Command,

    [string]$Vault,

    [switch]$Help,
    [switch]$Version
)

$ErrorActionPreference = "Stop"
$script:VERSION = "1.0.0"
$script:CONFIG_DIR = Join-Path $HOME ".config" "claude-sync"
$script:CONFIG_FILE = Join-Path $script:CONFIG_DIR "config"

# --- Helpers ---

function Show-Usage {
    Write-Host @"
claude-sync $script:VERSION — Sync Claude Code config across devices via Obsidian

Usage:
  claude-sync              Sync vault (uses configured path)
  claude-sync init         Interactive setup (vault path + Stop hook)
  claude-sync -Vault PATH  Sync a specific vault path
  claude-sync -Help        Show this help
  claude-sync -Version     Show version

Config: $script:CONFIG_FILE
"@
}

function Get-IsInteractive {
    return [Environment]::UserInteractive -and -not $env:CLAUDE_HOOK
}

function Write-Log {
    param([string]$Message)
    if (Get-IsInteractive) {
        Write-Host $Message
    }
}

function Get-VaultPath {
    if ($script:VaultPath) { return $script:VaultPath }

    if (Test-Path $script:CONFIG_FILE) {
        foreach ($line in Get-Content $script:CONFIG_FILE) {
            if ($line -match '^VAULT_PATH="(.+)"$') {
                return $Matches[1]
            }
        }
    }

    Write-Error "[claude-sync] Error: No vault path configured. Run 'claude-sync init' to set up, or use 'claude-sync -Vault PATH'."
    exit 1
}

# --- Init subcommand ---

function Invoke-Init {
    Write-Host "claude-sync $script:VERSION — Setup"
    Write-Host ""

    # Determine default
    $defaultVault = Join-Path $HOME "Documents"
    if (Test-Path $script:CONFIG_FILE) {
        foreach ($line in Get-Content $script:CONFIG_FILE) {
            if ($line -match '^VAULT_PATH="(.+)"$') {
                $defaultVault = $Matches[1]
            }
        }
    }

    $inputVault = Read-Host "Obsidian vault path [$defaultVault]"
    $vaultPath = if ($inputVault) { $inputVault } else { $defaultVault }

    # Expand ~ if present
    if ($vaultPath.StartsWith("~")) {
        $vaultPath = $vaultPath -replace "^~", $HOME
    }

    if (-not (Test-Path $vaultPath -PathType Container)) {
        Write-Error "Error: '$vaultPath' is not a directory."
        exit 1
    }

    # Write config
    New-Item -ItemType Directory -Path $script:CONFIG_DIR -Force | Out-Null
    @"
# claude-sync configuration
VAULT_PATH="$vaultPath"
"@ | Set-Content $script:CONFIG_FILE -Encoding UTF8
    Write-Host "Config saved to $($script:CONFIG_FILE)"

    # Offer to install Stop hook
    Write-Host ""
    $installHook = Read-Host "Install Claude Code Stop hook? (runs claude-sync automatically) [Y/n]"
    if (-not $installHook -or $installHook -match "^[Yy]") {
        Install-StopHook
    }

    # Run first sync
    Write-Host ""
    Write-Host "Running initial sync..."
    $script:VaultPath = $vaultPath
    Invoke-Sync
}

function Install-StopHook {
    $settingsFile = Join-Path $HOME ".claude" "settings.json"
    $claudeDir = Join-Path $HOME ".claude"

    if (-not (Test-Path $claudeDir)) {
        New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    }

    $hookEntry = @{
        hooks = @(
            @{
                type = "command"
                command = "claude-sync"
            }
        )
    }

    if (Test-Path $settingsFile) {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json

        # Check if hook already exists
        $existing = $false
        if ($settings.hooks -and $settings.hooks.Stop) {
            foreach ($group in $settings.hooks.Stop) {
                foreach ($hook in $group.hooks) {
                    if ($hook.command -eq "claude-sync") {
                        $existing = $true
                    }
                }
            }
        }

        if ($existing) {
            Write-Host "Stop hook already installed."
            return
        }

        # Add hook
        if (-not $settings.hooks) {
            $settings | Add-Member -NotePropertyName "hooks" -NotePropertyValue @{ Stop = @($hookEntry) }
        } elseif (-not $settings.hooks.Stop) {
            $settings.hooks | Add-Member -NotePropertyName "Stop" -NotePropertyValue @($hookEntry)
        } else {
            $settings.hooks.Stop += $hookEntry
        }

        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
    } else {
        @{
            hooks = @{
                Stop = @($hookEntry)
            }
        } | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
    }

    Write-Host "Stop hook installed in $settingsFile"
}

# --- Sync logic ---

function Invoke-Sync {
    $vaultPath = Get-VaultPath

    if (-not (Test-Path $vaultPath -PathType Container)) {
        Write-Error "[claude-sync] Error: $vaultPath is not a directory"
        exit 1
    }

    $convertCount = 0
    $linkCount = 0
    $memCount = 0

    # Step 1: Convert any real .claude/ directories to _claude/ + symlink
    $dotClaudes = Get-ChildItem -Path $vaultPath -Recurse -Directory -Force -Filter ".claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[/\\]\.obsidian[/\\]' -and -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) }

    foreach ($dotClaude in $dotClaudes) {
        $parent = $dotClaude.Parent.FullName
        $underscoreClaude = Join-Path $parent "_claude"

        if (Test-Path $underscoreClaude -PathType Container) {
            # Merge
            Get-ChildItem $dotClaude.FullName -Force | ForEach-Object {
                $dest = Join-Path $underscoreClaude $_.Name
                if (-not (Test-Path $dest)) {
                    Copy-Item $_.FullName $dest -Recurse
                }
            }
            Remove-Item $dotClaude.FullName -Recurse -Force
            New-Item -ItemType SymbolicLink -Path (Join-Path $parent ".claude") -Target "_claude" | Out-Null
            Write-Log "  [merged] $parent/.claude -> _claude"
        } else {
            # Convert
            Move-Item $dotClaude.FullName $underscoreClaude
            New-Item -ItemType SymbolicLink -Path (Join-Path $parent ".claude") -Target "_claude" | Out-Null
            Write-Log "  [converted] $parent/.claude -> _claude"
        }

        New-Item -ItemType Directory -Path (Join-Path $underscoreClaude "commands") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $underscoreClaude "memory") -Force | Out-Null
        $convertCount++
    }

    # Step 2: Create .claude -> _claude symlinks and memory symlinks
    $underscoreClaudes = Get-ChildItem -Path $vaultPath -Recurse -Directory -Filter "_claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[/\\]\.obsidian[/\\]' }

    foreach ($claudeDir in $underscoreClaudes) {
        $parent = $claudeDir.Parent.FullName
        $dotClaudeLink = Join-Path $parent ".claude"

        # Config symlink
        if (-not (Test-Path $dotClaudeLink)) {
            New-Item -ItemType SymbolicLink -Path $dotClaudeLink -Target "_claude" | Out-Null
            Write-Log "  [new] $parent/.claude -> _claude"
            $linkCount++
        } elseif (-not (Get-Item $dotClaudeLink -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            # It's a real directory, not a symlink — skip (handled in Step 1)
        }

        # Ensure commands/ and memory/ exist
        New-Item -ItemType Directory -Path (Join-Path $claudeDir.FullName "commands") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $claudeDir.FullName "memory") -Force | Out-Null

        # Memory symlink
        $absParent = (Resolve-Path $parent).Path
        $encoded = $absParent -replace '[/\\ ]', '-'
        $memTarget = Join-Path $HOME ".claude" "projects" $encoded "memory"

        if ((Test-Path $memTarget) -and (Get-Item $memTarget -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            # Already a symlink — skip
        } elseif (Test-Path $memTarget -PathType Container) {
            # Migrate existing memory
            $memSource = Join-Path $claudeDir.FullName "memory"
            Get-ChildItem $memTarget -Force | ForEach-Object {
                $dest = Join-Path $memSource $_.Name
                if (-not (Test-Path $dest)) {
                    Copy-Item $_.FullName $dest -Recurse
                }
            }
            Remove-Item $memTarget -Recurse -Force
            New-Item -ItemType SymbolicLink -Path $memTarget -Target (Join-Path $claudeDir.FullName "memory") | Out-Null
            Write-Log "  [migrated] memory: $encoded"
            $memCount++
        } else {
            # Create new memory symlink
            $projectDir = Join-Path $HOME ".claude" "projects" $encoded
            New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path $memTarget -Target (Join-Path $claudeDir.FullName "memory") | Out-Null
            Write-Log "  [new] memory: $encoded"
            $memCount++
        }
    }

    Write-Host "[claude-sync] Done. Converted $convertCount, created $linkCount symlink(s), $memCount memory link(s)."
}

# --- Main ---

# Check for Stop hook stdin (non-interactive)
if (-not [Environment]::UserInteractive -or $env:CLAUDE_HOOK) {
    try {
        $input_data = $input | Out-String
        if ($input_data) {
            $json = $input_data | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($json.stop_hook_active -eq $true) {
                exit 0
            }
        }
    } catch {
        # Not JSON input, continue
    }
}

# Parse arguments
if ($Help) {
    Show-Usage
    exit 0
}

if ($Version) {
    Write-Host "claude-sync $script:VERSION"
    exit 0
}

if ($Vault) {
    if ($Vault.StartsWith("~")) {
        $Vault = $Vault -replace "^~", $HOME
    }
    $script:VaultPath = $Vault
    Invoke-Sync
    exit 0
}

switch ($Command) {
    "init" { Invoke-Init }
    "" { Invoke-Sync }
    default {
        Write-Error "Unknown command: $Command"
        Show-Usage
        exit 1
    }
}
