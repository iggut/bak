# bak — Linux desktop backup & restore

Opinionated, PII-free backup and restore scripts for Arch Linux desktops.
Backs up application state, browser profiles, agent configs, secrets, and
system files to an external drive; restores them on a fresh install with
a GUI wizard.

## What it backs up

| Category | Apps |
|----------|------|
| **Browsers** | Chromium, Zen Browser |
| **Communication** | Telegram, Discord, KDE Connect |
| **Media** | Spotify (+ Spicetify) |
| **Gaming** | Steam, Heroic Games Launcher, INAV Configurator |
| **Desktop** | DankMaterialShell/Quickshell, Konsole |
| **AI agents** | Claude Code, Antigravity IDE, Cursor, Gemini CLI, Codex CLI |
| **System** | SSH keys, GnuPG, NSS database, keyrings, NetworkManager connections |
| **System (root)** | `/etc` config, `/var/lib` (pacman keyring, firewall rules) |
| **Secrets** | `~/.secrets` (API keys, .env, .npmrc, tokens) |
| **Packages** | Explicitly-installed package list (`pacman -Qqen`) |
| **Tailscale** | Status snapshot (node-key not backed up — re-auth required) |

## Quick start

```bash
# Backup (default destination: /run/media/$USER/Data/bakup)
./backup.sh

# Restore with GUI wizard
./restore.sh

# Dry-run restore of specific apps
./restore.sh --dry-run --apps claude,zen,kdeconnect

# Restore from a specific backup timestamp
./restore.sh /path/to/backups/20260709T183837Z_Hostname
```

## Configuration

All settings are environment-variable overridable:

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_ROOT` | `/run/media/$USER/Data/bakup` | Backup destination root |
| `DRY_RUN` | `0` | Set to `1` for dry-run mode |
| `SKIP_SUDO` | `0` | Set to `1` to skip privileged operations |
| `BACKUP_USER_MANGLE` | _(auto)_ | Override for renamed accounts |
| `MEMPALACE_VENV` | `$HOME/.mempalace/.venv` | MemPalace virtualenv path |
| `BAKUP_ASKPASS` | _(auto-detected)_ | Custom askpass helper path |
| `TAILSCALE_AUTHKEY_FILE` | `~/.secrets/tailscale-authkey` | Tailscale pre-auth key for auto-rejoin |

## How it works

### Backup

`backup.sh` uses `rsync` with per-app exclude rules (caches, logs, GPU
shaders, node_modules, etc.) to create timestamped snapshots:

```
$BACKUP_ROOT/
  20260709T183837Z_Hostname/
    hermes/          # Hermes Agent config + state
    chromium/        # Browser profiles (cookies, logins, history, extensions)
    claude/          # Claude Code settings + agents + MCP configs
    spotify/         # Spotify + Spicetify config
    system/          # SSH, GnuPG, keyrings, NM connections
    system-root/     # /etc + /var/lib (requires sudo)
    mempalace/       # MemPalace SQLite + chromadb/HNSW (live snapshot)
    ...
    SHA256SUMS       # Integrity hashes for every file
    MANIFEST.json    # Backup metadata
```

### Restore

`restore.sh` unmangles backup directory names back to their original
`$HOME`-relative paths and `rsync`s them back with `--backup` (existing
files are preserved as `.bak-<timestamp>` rather than overwritten).

The optional GUI wizard (`lib/restore-gui.sh`) provides a 4-step popup
flow:

1. **Pick backup** — select timestamp from dropdown
2. **Pick categories** — checkbox per app group
3. **Per-label drilldown** — expand each category to select individual
   items; Tailscale auth-key prompt
4. **Confirm** — summary of everything that will be restored

### Path unmangling

Backup directory names are mangled versions of absolute paths:

- `sync_one` (most labels): `sed 's|^/||;s|/|_|g'`
  - `/home/user/.config/chromium` → `home_user_.config_chromium`
- Antigravity: `tr '/ ' '__'` (preserves leading slash as underscore)
  - `/home/user/.antigravity-ide` → `_home_user_.antigravity-ide`
- Special literals: `quickshell`, `dot-config`, Telegram share names

`restore_map_path()` reverses these generically — no hardcoded lookup
table, works for any username.

## Requirements

- Arch Linux (or Arch-based distro with `pacman`)
- `rsync`, `sqlite3`, `coreutils`
- `zenity` (for GUI wizard)
- `sudo` (for system-root backup/restore)
- Optional: `paru` or `yay` (AUR package install on restore)

## Install

```bash
./install.sh    # Copies to ~/.local/share/bakup/, symlinks to ~/.local/bin/
```

## License

MIT — see [LICENSE](LICENSE).
