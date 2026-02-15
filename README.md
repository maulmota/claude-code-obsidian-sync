# claude-code-obsidian-sync

Sync Claude Code project config (`settings.json`, slash commands, auto-memory) across devices using Obsidian Sync.

## The Problem

Obsidian Sync skips hidden files — anything starting with `.` is not synced. Claude Code stores project config in `.claude/` directories, so your settings, custom commands, and auto-memory don't travel between devices. Global config at `~/.claude/` lives outside the vault entirely.

## How It Works

The strategy: rename `.claude/` to `_claude/` (visible, synced by Obsidian) and create symlinks so Claude Code still finds everything.

`claude-sync` handles three things automatically:

1. **Converts** real `.claude/` directories (created by Claude Code) to `_claude/` + symlink
2. **Creates** `.claude -> _claude` symlinks for directories synced from other devices
3. **Links auto-memory** — symlinks `~/.claude/projects/<encoded>/memory/` into each project's `_claude/memory/`

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
4. Run the first sync

## Usage

After setup, everything is automatic. The Stop hook runs `claude-sync` after every Claude Code session.

| Scenario | Action needed? |
|---|---|
| Edit CLAUDE.md | No |
| Add/edit slash commands | No |
| Change project settings | No |
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

**Windows: symlinks don't work** — Enable Developer Mode: **Settings > System > For Developers > Developer Mode ON**

## License

MIT
