# bak — Linux desktop backup & restore

Opinionated backup and restore scripts for Arch Linux desktops (Garuda-tested).
Backs up application state, browser profiles, agent configs, secrets, and
selected system files to an external drive; restores them on a fresh install
with a CLI and GTK GUI.

**Agents:** start at [AGENTS.md](AGENTS.md). Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Codemaps: [docs/CODEMAPS/](docs/CODEMAPS/).

## What it backs up

| Category | Labels / apps |
|----------|----------------|
| **Browsers** | Chromium, Zen Browser, Firefox |
| **Communication** | Telegram, Discord, KDE Connect |
| **Media** | Spotify (+ Spicetify), mpv |
| **Gaming** | Steam, Heroic, INAV, MangoHud, overlays (vkBasalt/gamescope/cava) |
| **Desktop** | DankMaterialShell/Quickshell, Hyprland (+ waybar/wlogout/…), KDE/GTK themes, fonts, desktop entries |
| **Shell & editors** | Shell dotfiles (bash/zsh/fish/starship), Konsole, terminals (alacritty/kitty/foot/ghostty), Neovim/Vim, VS Code |
| **AI agents** | Hermes, Claude Code, Antigravity, Cursor, Gemini CLI, Codex CLI, other harnesses |
| **Dev tools** | Git + gh, paru/yay config, input remapper |
| **System** | SSH keys, GnuPG, NSS database, keyrings, NetworkManager, audio (PipeWire/Pulse), YubiKey, Klipper |
| **System (root)** | `/etc` config, selected `/var/lib` (pacman keyring, firewall rules) |
| **Secrets** | `~/.secrets` (API keys, .env, .npmrc, tokens), KeePassXC settings |
| **Packages** | Explicitly-installed package list (`pacman -Qqen`) + AUR foreign list |
| **Tailscale** | Status snapshot (node-key not backed up — re-auth required) |
| **MemPalace** | SQLite + chroma data under `~/.mempalace` |
| **Other apps** | GUI can scan `~/.config` / Flatpak apps and back up any selected settings tree |

Full label list: `./backup.sh --list-labels` (must match `./restore.sh --list-labels`).
The GTK GUI shows per-app icons, can filter to installed apps, and can scan for
additional installed apps not in the curated list.
## Quick start

```bash
# Backup (default destination: $BACKUP_DEST or /run/media/$USER/Data/bakup)
./backup.sh

# Restore latest snapshot (CLI)
./restore.sh

# GTK GUI (backup + restore with per-part destinations)
./bakup-gui

# Dry-run restore of specific labels
./restore.sh --dry-run --apps claude,zen,kdeconnect

# Restore from a specific backup timestamp
./restore.sh /path/to/backups/20260709T183837Z_Hostname
```

## Configuration

| Variable / flag | Default | Description |
|-----------------|---------|-------------|
| `BACKUP_DEST` | `/run/media/$USER/Data/bakup` (hardcoded user path in scripts) | Backup destination root |
| `--dest PATH` | _(from `BACKUP_DEST`)_ | Override destination / backup root |
| `--labels LIST` | all | Backup only these labels (comma-separated) |
| `--extra-apps FILE` | _(none)_ | (backup) JSON list of discovered apps to include |
| `--apps LIST` | all | Restore only these labels |
| `--dry-run` / `-n` | off | Show restore actions without writing |
| `--no-sudo` | off | Skip privileged `/etc` and `/var` operations |
| `--preauth-sudo` | off | (backup) Refresh sudo timestamp between labels |

## How it works

### Backup

`backup.sh` uses `rsync` with per-app exclude rules (caches, logs, GPU
shaders, node_modules, game downloads, etc.) to create timestamped snapshots:

```
$BACKUP_DEST/
  20260709T183837Z_Hostname/
    hermes/            # Hermes Agent config + state
    chromium/home/…    # Modern layout: paths relative to $HOME
    claude/home/…      # Claude Code settings + agents + MCP configs
    spotify/home/…
    system/            # SSH, GnuPG, keyrings, NM connections
    system-root/       # /etc + /var/lib (requires sudo)
    mempalace/         # MemPalace SQLite + chromadb
    …
    SHA256SUMS         # Integrity hashes
    MANIFEST.json      # Backup metadata
```

Modern snapshots store user trees under `<label>/home/<relpath>`. Older
snapshots used mangled directory names; restore still supports both.

### Restore

`restore.sh` prefers the modern `home/` layout (`rsync` onto `$HOME` with
`--backup` so existing files become `.bak-<timestamp>`). Label-specific
logic covers telegram, steam, secrets, packages, mempalace, tailscale, and
privileged system paths.

The GTK GUI (`./bakup-gui`) provides backup label selection and an expandable
restore tree of **parts** with an editable **Restore to** column.

An older zenity multi-step wizard lives in `lib/restore-gui.sh`.

### Partial restore

Restore individual pieces of a label (bookmarks only, one agent harness, etc.)
and optionally change the destination path:

```bash
# List available parts for a snapshot (JSON)
./restore.sh /path/to/SNAPSHOT --list-parts

# Restore selected parts (original locations by default)
./restore.sh SNAPSHOT --parts zen/bookmarks,extras-agents/openclaw

# Override destination for a part
./restore.sh SNAPSHOT --parts extras-agents/openclaw \
  --map extras-agents/openclaw=/tmp/openclaw-copy
```

## Requirements

- Arch Linux (or Arch-based distro with `pacman`)
- `rsync`, `sqlite3`, `coreutils`, `python3`
- GTK3 + PyGObject (`python-gobject`) for `./bakup-gui`
- `zenity` (optional; askpass / older restore wizard)
- `sudo` (for system-root backup/restore and package install)
- Optional: `paru` or `yay` (AUR package install on restore)

## Install

```bash
./install.sh    # Copies to ~/.local/share/bakup/, symlinks to ~/.local/bin/
```

Creates `backup`, `restore`, and `bakup-gui` on your PATH (ensure
`~/.local/bin` is included).

## Development / tests

```bash
diff <(./backup.sh --list-labels) <(./restore.sh --list-labels)
./test/test_restore_map.sh
python3 -m py_compile bakup-gui.py lib/restore_parts.py
```

See [AGENTS.md](AGENTS.md) for contribution rules aimed at coding agents.

## License

MIT — see [LICENSE](LICENSE).
