# claude-code-obsidian-sync

Sync Claude Code project config (`settings.json`, slash commands, auto-memory) and global config (commands, skills, plugins) across devices using Obsidian Sync.

## The Problem

Obsidian Sync skips hidden files — anything starting with `.` is not synced. Claude Code stores project config in `.claude/` directories, so your settings, custom commands, and auto-memory don't travel between devices. Global config at `~/.claude/` lives outside the vault entirely.

## How It Works

The strategy: rename `.claude/` to `_claude/` (visible, synced by Obsidian) and create symlinks so Claude Code still finds everything.

`claude-sync` handles four things automatically:

1. **Converts** real `.claude/` directories (created by Claude Code) to `_claude/` + symlink
2. **Creates** `.claude -> _claude` symlinks for directories synced from other devices
3. **Links auto-memory** — symlinks `~/.claude/projects/<encoded>/memory/` into each project's `_claude/memory/`
4. **Syncs global config** — symlinks `~/.claude/commands/` and `~/.claude/skills/` into the vault, and maintains a plugin manifest

Global commands and skills sync via symlinks into `_claude-global/` (no hidden files, so Obsidian Sync handles them cleanly). Plugins can't sync this way (they contain `.git/` directories that Obsidian skips), so `claude-sync` maintains a `plugins.json` manifest instead — on new devices it merges enabled plugins into settings and tells you which plugins to install.

A Claude Code Stop hook runs `claude-sync` after every session, so there's nothing to remember.

```
vault/
  Project/
    CLAUDE.md               <- syncs normally (not hidden)
    _claude/                <- real config (synced by Obsidian)
    │   settings.json
    │   commands/
    │   memory/MEMORY.md    <- auto-memory (synced)
    .claude -> _claude      <- symlink (created per device, not synced)
  _claude-global/             <- global config (synced by Obsidian)
    commands/                 <- symlinked from ~/.claude/commands/
    skills/                   <- symlinked from ~/.claude/skills/
    plugins.json              <- plugin manifest (enabledPlugins + versions)
```

```
┌─────────────────────────────────────────────────────┐
│                   Obsidian Vault                    │
│                                                     │
│  Project/_claude/          (synced across devices)  │
│         .claude -> _claude (symlink, per device)    │
│                                                     │
│                  ▲ Obsidian Sync ▲                   │
└──────────────────┼───────────────┼──────────────────┘
                   │               │
     Device A ─────┘               └───── Device B
     .claude symlink                 .claude symlink
     memory symlink                  memory symlink
```

## Install

### macOS / Linux

**Option A: Clone and install**

```bash
git clone https://github.com/maulmota/claude-code-obsidian-sync.git
cd claude-code-obsidian-sync
./install.sh
```

**Option B: curl**

```bash
curl -fsSL https://raw.githubusercontent.com/maulmota/claude-code-obsidian-sync/main/install.sh | bash
```

**Prerequisites:** `bash`, `jq` (for JSON operations — `brew install jq` on macOS, `apt install jq` on Linux)

### Windows

1. Enable Developer Mode: **Settings > System > For Developers > Developer Mode ON** (required for symlinks)
2. Save `claude-sync.ps1` somewhere on your PATH
3. Run `claude-sync init`

## Setup

Run the interactive setup:

```bash
claude-sync init
```

This will:
1. Ask for your Obsidian vault path
2. Save it to `~/.config/claude-sync/config`
3. Offer to install a Claude Code Stop hook (so syncing is automatic)
4. Offer to sync global commands, skills, and plugins across devices
5. Run the first sync

## Usage

After setup, everything is automatic. The Stop hook runs `claude-sync` after every Claude Code session.

| Scenario | Action needed? |
|---|---|
| Edit CLAUDE.md | No |
| Add/edit slash commands | No |
| Change project settings | No |
| Add/edit global commands or skills | No (synced via symlink) |
| Install a new plugin | No (manifest updates on next sync) |
| Use Claude Code in a new vault directory | No (Stop hook handles it) |
| Set up a new device | **Yes** — install claude-sync + run `claude-sync init` |

### Manual sync

```bash
claude-sync              # sync using configured vault path
claude-sync --vault PATH # sync a specific vault
```

## Configuration

**Config file:** `~/.config/claude-sync/config`

```
VAULT_PATH="/path/to/your/vault"
```

**Re-run setup:** `claude-sync init` (overwrites existing config)

**Override vault path:** `claude-sync --vault /other/vault`

**Global config:** `vault/_claude-global/`

```
_claude-global/
  commands/       <- ~/.claude/commands/ symlinks here
  skills/         <- ~/.claude/skills/ symlinks here
  plugins.json    <- plugin manifest (synced, merged on new devices)
```

`plugins.json` tracks which plugins are enabled and their versions. On a new device, `claude-sync init` merges `enabledPlugins` into your local `settings.json` and lists any plugins that need manual installation.

**Stop hook** in `~/.claude/settings.json`:
```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "claude-sync" }] }]
  }
}
```

## Obsidian Sync Settings

- Confirm `_claude` folders are **not excluded** in Selective Sync
- Add `settings.local.json` to **Excluded files** (device-specific permissions, should not sync)
- No extra file type configuration needed — Obsidian Sync handles `.json` and `.md` in visible directories

## Troubleshooting

**No `_claude/` directories found** — Obsidian Sync may not have finished. Open Obsidian, wait for sync to complete, verify the vault path is correct.

**Claude Code doesn't see config** — Check the symlink: `ls -la .claude` should show `.claude -> _claude`. If broken: `rm .claude && ln -s _claude .claude`

**Both `.claude/` and `_claude/` exist** — This happens if Claude Code created `.claude/` before sync ran. `claude-sync` merges them automatically. To fix manually: `cp -rn .claude/* _claude/ && rm -rf .claude && ln -s _claude .claude`

**Memory path differs between devices** — Expected. The encoded path under `~/.claude/projects/` depends on the absolute vault path and username. `claude-sync` computes the correct path for each device.

**Global commands/skills not available on new device** — Run `claude-sync init` and say yes to global sync. Check that `ls -la ~/.claude/commands` and `ls -la ~/.claude/skills` show symlinks pointing into the vault. If they're real directories, delete them and re-run `claude-sync`.

**Plugins not enabled on new device** — Run `claude-sync init`. It reads `plugins.json` from the vault and merges `enabledPlugins` into your local `settings.json`. Plugins themselves must be installed manually — the init output will list which ones.

**Windows: symlinks don't work** — Enable Developer Mode: **Settings > System > For Developers > Developer Mode ON**

## License

MIT
