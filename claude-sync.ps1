# claude-sync.ps1: Sync Claude Code config across devices via Obsidian
# https://github.com/maulmota/claude-code-obsidian-sync
#
# What it does:
#   1. Converts any real .claude/ directories to _claude/ + symlink
#   2. Creates .claude -> _claude symlinks for directories synced from other devices
#   3. Ensures commands/ and memory/ subdirectories exist
#   4. Sets up memory symlinks so auto-memory writes into the vault
#   5. Syncs global commands, skills, and plugin config via _claude-global/
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
$script:VER = "1.0.0"
$script:CONFIG_DIR = Join-Path (Join-Path $HOME ".config") "claude-sync"
$script:CONFIG_FILE = Join-Path $script:CONFIG_DIR "config"

# --- Helpers ---

function Set-Utf8Content {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function New-Symlink {
    param([string]$Path, [string]$Target)
    # New-Item -ItemType SymbolicLink requires admin on PS 5.1 even with
    # Developer Mode enabled. cmd /c mklink respects Developer Mode.
    if (Test-Path $Target -PathType Container) {
        cmd /c mklink /d "`"$Path`"" "`"$Target`"" > $null 2>&1
    } else {
        cmd /c mklink "`"$Path`"" "`"$Target`"" > $null 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create symlink: $Path -> $Target (is Developer Mode enabled?)"
    }
}

function Show-Usage {
    Write-Host "claude-sync $script:VER --Sync Claude Code config across devices via Obsidian"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  claude-sync              Sync vault (uses configured path)"
    Write-Host "  claude-sync init         Interactive setup (vault path + Stop hook)"
    Write-Host "  claude-sync -Vault PATH  Sync a specific vault path"
    Write-Host "  claude-sync -Help        Show this help"
    Write-Host "  claude-sync -Version     Show version"
    Write-Host ""
    Write-Host "Config: $script:CONFIG_FILE"
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

    Write-Error -Message "claude-sync: No vault path configured. Run 'claude-sync init' to set up, or use 'claude-sync -Vault PATH'."
    exit 1
}

# --- Init subcommand ---

function Invoke-Init {
    Write-Host "claude-sync $script:VER --Setup"
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
    Set-Utf8Content -Path $script:CONFIG_FILE -Content ("# claude-sync configuration`r`nVAULT_PATH=`"$vaultPath`"")
    Write-Host "Config saved to $($script:CONFIG_FILE)"

    # Offer to install Stop hook
    Write-Host ""
    $installHook = Read-Host "Install Claude Code Stop hook? (runs claude-sync automatically) [Y/n]"
    if (-not $installHook -or $installHook -match "^[Yy]") {
        Install-StopHook
    }

    # Offer to sync global commands, skills, and plugins
    Write-Host ""
    $syncGlobal = Read-Host "Sync global commands, skills, and plugins across devices? [Y/n]"
    if (-not $syncGlobal -or $syncGlobal -match "^[Yy]") {
        Initialize-GlobalSync $vaultPath
    }

    # Run first sync
    Write-Host ""
    Write-Host "Running initial sync..."
    $script:VaultPath = $vaultPath
    Invoke-Sync
}

function Install-StopHook {
    $settingsFile = Join-Path (Join-Path $HOME ".claude") "settings.json"
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

        Set-Utf8Content -Path $settingsFile -Content ($settings | ConvertTo-Json -Depth 10)
    } else {
        $newSettings = @{
            hooks = @{
                Stop = @($hookEntry)
            }
        }
        Set-Utf8Content -Path $settingsFile -Content ($newSettings | ConvertTo-Json -Depth 10)
    }

    Write-Host "Stop hook installed in $settingsFile"
}

function Initialize-GlobalSync {
    param([string]$VaultRoot)

    $globalDir = Join-Path $VaultRoot "_claude-global"

    if (Test-Path $globalDir -PathType Container) {
        # New device: _claude-global/ already exists from Obsidian Sync
        Write-Host "Found existing _claude-global/ --linking to it."

        foreach ($dirName in @("commands", "skills")) {
            $vaultDir = Join-Path $globalDir $dirName
            $claudeDir = Join-Path (Join-Path $HOME ".claude") $dirName

            if (-not (Test-Path $vaultDir -PathType Container)) { continue }

            if ((Test-Path $claudeDir) -and (Get-Item $claudeDir -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                Write-Host "  ~/.claude/$dirName already linked."
            } elseif (Test-Path $claudeDir -PathType Container) {
                Get-ChildItem $claudeDir -Force | ForEach-Object {
                    $dest = Join-Path $vaultDir $_.Name
                    if (-not (Test-Path $dest)) {
                        Copy-Item $_.FullName $dest -Recurse
                    }
                }
                Remove-Item $claudeDir -Recurse -Force
                New-Symlink -Path $claudeDir -Target $vaultDir
                Write-Host "  [migrated] ~/.claude/$dirName -> vault"
            } else {
                New-Symlink -Path $claudeDir -Target $vaultDir
                Write-Host "  [linked] ~/.claude/$dirName -> vault"
            }
        }

        # Merge enabledPlugins from manifest into device settings
        Merge-PluginsToDevice $globalDir
    } else {
        # First device: create _claude-global/ and move content
        Write-Host "Creating _claude-global/ in vault."
        New-Item -ItemType Directory -Path (Join-Path $globalDir "commands") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $globalDir "skills") -Force | Out-Null

        foreach ($dirName in @("commands", "skills")) {
            $vaultDir = Join-Path $globalDir $dirName
            $claudeDir = Join-Path (Join-Path $HOME ".claude") $dirName

            if ((Test-Path $claudeDir) -and (Get-Item $claudeDir -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                Write-Host "  ~/.claude/$dirName already a symlink --skipping."
            } elseif (Test-Path $claudeDir -PathType Container) {
                Get-ChildItem $claudeDir -Force | ForEach-Object {
                    $dest = Join-Path $vaultDir $_.Name
                    if (-not (Test-Path $dest)) {
                        Copy-Item $_.FullName $dest -Recurse
                    }
                }
                Remove-Item $claudeDir -Recurse -Force
                New-Symlink -Path $claudeDir -Target $vaultDir
                Write-Host "  [moved] ~/.claude/$dirName -> vault"
            } else {
                New-Symlink -Path $claudeDir -Target $vaultDir
                Write-Host "  [linked] ~/.claude/$dirName -> vault"
            }
        }

        # Generate initial plugins.json
        Update-PluginsManifest $globalDir
        $manifestPath = Join-Path $globalDir "plugins.json"
        if (Test-Path $manifestPath) {
            Write-Host "  [created] plugins.json"
        }
    }
}

function Merge-PluginsToDevice {
    param([string]$GlobalDir)

    $manifestPath = Join-Path $GlobalDir "plugins.json"
    $settingsFile = Join-Path (Join-Path $HOME ".claude") "settings.json"

    if (-not (Test-Path $manifestPath)) { return }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

    if (-not $manifest.enabledPlugins) { return }
    $manifestPlugins = $manifest.enabledPlugins

    # Merge into device settings
    if (Test-Path $settingsFile) {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if (-not $settings.enabledPlugins) {
            $settings | Add-Member -NotePropertyName "enabledPlugins" -NotePropertyValue @{}
        }
        foreach ($prop in $manifestPlugins.PSObject.Properties) {
            $settings.enabledPlugins | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
        Set-Utf8Content -Path $settingsFile -Content ($settings | ConvertTo-Json -Depth 10)
    }

    # List plugins that need manual installation
    $installedFile = Join-Path (Join-Path (Join-Path $HOME ".claude") "plugins") "installed_plugins.json"
    $installedKeys = @()
    if (Test-Path $installedFile) {
        $installed = Get-Content $installedFile -Raw | ConvertFrom-Json
        if ($installed.plugins) {
            $installedKeys = $installed.plugins.PSObject.Properties.Name
        }
    }

    $needInstall = @()
    if ($manifest.installedPlugins) {
        foreach ($prop in $manifest.installedPlugins.PSObject.Properties) {
            if ($prop.Name -notin $installedKeys) {
                $version = if ($prop.Value.version) { $prop.Value.version } else { "unknown" }
                $marketplace = if ($prop.Value.marketplace) { $prop.Value.marketplace } else { "unknown" }
                $needInstall += "$($prop.Name) ($marketplace v$version)"
            }
        }
    }

    if ($needInstall.Count -gt 0) {
        Write-Host ""
        Write-Host "Plugins to install manually:"
        foreach ($p in $needInstall) {
            Write-Host "  - $p"
        }
    }

    # Also update the manifest with any local plugins
    Update-PluginsManifest $GlobalDir
}

function Update-PluginsManifest {
    param([string]$GlobalDir)

    $installedFile = Join-Path (Join-Path (Join-Path $HOME ".claude") "plugins") "installed_plugins.json"
    $settingsFile = Join-Path (Join-Path $HOME ".claude") "settings.json"
    $manifestPath = Join-Path $GlobalDir "plugins.json"

    if (-not (Test-Path $installedFile) -or -not (Test-Path $settingsFile)) { return }

    $installed = Get-Content $installedFile -Raw | ConvertFrom-Json
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json

    # Build current device state
    $deviceEnabled = if ($settings.enabledPlugins) { $settings.enabledPlugins } else { @{} }
    $deviceInstalled = @{}

    if ($installed.plugins) {
        foreach ($prop in $installed.plugins.PSObject.Properties) {
            $pluginName = $prop.Name
            $version = if ($prop.Value[0].version) { $prop.Value[0].version } else { "unknown" }
            $parts = $pluginName -split "@"
            $marketplace = if ($parts.Count -gt 1) { $parts[-1] } else { "unknown" }
            $deviceInstalled[$pluginName] = @{
                version = $version
                marketplace = $marketplace
            }
        }
    }

    if (Test-Path $manifestPath) {
        # Merge: add new entries, keep existing
        $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json

        # Merge enabledPlugins
        $mergedEnabled = @{}
        if ($existing.enabledPlugins) {
            foreach ($prop in $existing.enabledPlugins.PSObject.Properties) {
                $mergedEnabled[$prop.Name] = $prop.Value
            }
        }
        if ($deviceEnabled -is [PSCustomObject]) {
            foreach ($prop in $deviceEnabled.PSObject.Properties) {
                $mergedEnabled[$prop.Name] = $prop.Value
            }
        }

        # Merge installedPlugins
        $mergedInstalled = @{}
        if ($existing.installedPlugins) {
            foreach ($prop in $existing.installedPlugins.PSObject.Properties) {
                $mergedInstalled[$prop.Name] = $prop.Value
            }
        }
        foreach ($key in $deviceInstalled.Keys) {
            $mergedInstalled[$key] = [PSCustomObject]$deviceInstalled[$key]
        }

        $manifest = @{
            enabledPlugins = [PSCustomObject]$mergedEnabled
            installedPlugins = [PSCustomObject]$mergedInstalled
        }
        Set-Utf8Content -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 10)
    } else {
        $manifest = @{
            enabledPlugins = $deviceEnabled
            installedPlugins = [PSCustomObject]$deviceInstalled
        }
        Set-Utf8Content -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 10)
    }

    Write-Log "  [updated] plugins.json"
}

function Invoke-GlobalSync {
    param([string]$VaultRoot)

    $globalDir = Join-Path $VaultRoot "_claude-global"

    if (-not (Test-Path $globalDir -PathType Container)) { return }

    $globalCount = 0

    foreach ($dirName in @("commands", "skills")) {
        $vaultDir = Join-Path $globalDir $dirName
        $claudeDir = Join-Path (Join-Path $HOME ".claude") $dirName

        if (-not (Test-Path $vaultDir -PathType Container)) { continue }

        if ((Test-Path $claudeDir) -and (Get-Item $claudeDir -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            # Already a symlink --skip
        } elseif (Test-Path $claudeDir -PathType Container) {
            Get-ChildItem $claudeDir -Force | ForEach-Object {
                $dest = Join-Path $vaultDir $_.Name
                if (-not (Test-Path $dest)) {
                    Copy-Item $_.FullName $dest -Recurse
                }
            }
            Remove-Item $claudeDir -Recurse -Force
            New-Symlink -Path $claudeDir -Target $vaultDir
            Write-Log "  [migrated] ~/.claude/$dirName -> vault"
            $globalCount++
        } else {
            New-Symlink -Path $claudeDir -Target $vaultDir
            Write-Log "  [new] ~/.claude/$dirName -> vault"
            $globalCount++
        }
    }

    Update-PluginsManifest $globalDir

    if ($globalCount -gt 0) {
        Write-Log "[claude-sync] Global: $globalCount directory link(s) updated."
    }
}

# --- Sync logic ---

function Invoke-Sync {
    $vaultPath = Get-VaultPath

    if (-not (Test-Path $vaultPath -PathType Container)) {
        Write-Error -Message "claude-sync: $vaultPath is not a directory"
        exit 1
    }

    $convertCount = 0
    $linkCount = 0
    $memCount = 0

    # Step 1: Convert any real .claude/ directories to _claude/ + symlink
    $dotClaudes = Get-ChildItem -Path $vaultPath -Recurse -Directory -Force -Filter ".claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[/\\]\.obsidian[/\\]' -and $_.FullName -notmatch '[/\\]_claude-global[/\\]' -and -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) }

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
            New-Symlink -Path (Join-Path $parent ".claude") -Target "_claude"
            Write-Log "  [merged] $parent/.claude -> _claude"
        } else {
            # Convert
            Move-Item $dotClaude.FullName $underscoreClaude
            New-Symlink -Path (Join-Path $parent ".claude") -Target "_claude"
            Write-Log "  [converted] $parent/.claude -> _claude"
        }

        New-Item -ItemType Directory -Path (Join-Path $underscoreClaude "commands") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $underscoreClaude "memory") -Force | Out-Null
        $convertCount++
    }

    # Step 2: Create .claude -> _claude symlinks and memory symlinks
    $underscoreClaudes = Get-ChildItem -Path $vaultPath -Recurse -Directory -Filter "_claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[/\\]\.obsidian[/\\]' -and $_.FullName -notmatch '[/\\]_claude-global[/\\]' -and $_.Parent.Name -ne "_claude-global" }

    foreach ($claudeDir in $underscoreClaudes) {
        $parent = $claudeDir.Parent.FullName
        $dotClaudeLink = Join-Path $parent ".claude"

        # Config symlink
        if (-not (Test-Path $dotClaudeLink)) {
            New-Symlink -Path $dotClaudeLink -Target "_claude"
            Write-Log "  [new] $parent/.claude -> _claude"
            $linkCount++
        } elseif (-not (Get-Item $dotClaudeLink -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            # It's a real directory, not a symlink --skip (handled in Step 1)
        }

        # Ensure commands/ and memory/ exist
        New-Item -ItemType Directory -Path (Join-Path $claudeDir.FullName "commands") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $claudeDir.FullName "memory") -Force | Out-Null

        # Memory symlink
        $absParent = (Resolve-Path $parent).Path
        $encoded = $absParent -replace '[/\\ ]', '-'
        $memTarget = Join-Path (Join-Path (Join-Path (Join-Path $HOME ".claude") "projects") $encoded) "memory"

        if ((Test-Path $memTarget) -and (Get-Item $memTarget -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            # Already a symlink --skip
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
            New-Symlink -Path $memTarget -Target (Join-Path $claudeDir.FullName "memory")
            Write-Log "  [migrated] memory: $encoded"
            $memCount++
        } else {
            # Create new memory symlink
            $projectDir = Join-Path (Join-Path (Join-Path $HOME ".claude") "projects") $encoded
            New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
            New-Symlink -Path $memTarget -Target (Join-Path $claudeDir.FullName "memory")
            Write-Log "  [new] memory: $encoded"
            $memCount++
        }
    }

    # Step 3: Sync global commands, skills, and plugin config
    Invoke-GlobalSync $vaultPath

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
    Write-Host "claude-sync $script:VER"
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
