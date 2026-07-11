# Architecture

bakup is a small shell + Python toolkit. There is no server, database, or build step beyond making scripts executable.

## Data flow

```
┌─────────────┐     rsync / cp      ┌──────────────────────────────┐
│  Live $HOME │ ──────────────────► │ $BACKUP_DEST/                │
│  /etc (sudo)│   backup.sh         │   YYYYMMDDThhmmssZ_Host/     │
└─────────────┘                     │     <label>/…                │
                                    │     MANIFEST.json            │
┌─────────────┐     rsync --backup  │     SHA256SUMS               │
│  Live $HOME │ ◄────────────────── │                              │
│  /etc (sudo)│   restore.sh        └──────────────────────────────┘
└─────────────┘         ▲
                        │ parts JSON / resolve TSV
               lib/restore_parts.py
                        ▲
                   bakup-gui.py (GTK3)
```

## Snapshot layout

Each run creates a **new** directory (never reused):

```
$BACKUP_DEST/<UTC-timestamp>_<hostname>/
  <label>/
    home/<relpath-under-$HOME>/   # modern layout (preferred)
    …                             # label-specific extras (steam, telegram, …)
  MANIFEST.json                   # sizes / file counts per label
  SHA256SUMS                      # integrity hashes
  backup.log                      # run log (if present)
```

### Modern vs legacy

| Era | On-disk shape | Restore path |
|-----|---------------|--------------|
| Modern | `<label>/home/.config/foo` | `restore_home_tree` → rsync onto `$HOME` |
| Legacy | mangled names (`home_user_.config_foo`, `dot-config_…`) | `restore_legacy_subs` + `restore_map_path` |

New backup code should only write the modern layout. Restore must keep legacy support.

## Labels

A **label** is one logical backup unit (one top-level directory in the snapshot). Canonical order is `ALL_LABELS` in both `backup.sh` and `restore.sh` (must stay identical). List with `./backup.sh --list-labels`.

Special cases:

- `extras-gemini`, `extras-codex`, `extras-agents` are produced by one backup function (`backup_gemini_codex`) but remain separate restore/part labels.
- `system` = user secrets-adjacent extras (ssh, gnupg, keyrings, NM copies, …).
- `system-root` = privileged `/etc` + selected `/var/lib` (needs sudo).
- `tailscale` stores status/env snapshots; node key is **not** backed up — re-auth is manual.
- `packages` stores pacman/paru package lists for reinstall on restore.

## Partial restore (“parts”)

`lib/restore_parts.py` discovers **parts** inside a snapshot. Part IDs are `label/part` (e.g. `zen/bookmarks`).

- `list` subcommand → JSON for GUI / `--list-parts`
- `resolve` subcommand → TSV `src\tdest` lines for bash

`restore.sh --parts` and `bakup-gui.py` both call this module. Destination overrides (`--map` / GUI “Restore to”) use `resolve_destinations`:

- one item → override is the full destination path
- many items → override is a parent; each item appends its `rel`

## Privilege model

1. First privileged op → `sudo_init` sets `SUDO_ASKPASS` to `lib/askpass.sh` (zenity/yad/kdialog).
2. Later ops reuse sudo’s timestamp cache via `sudo_run`.
3. `--no-sudo` / `SKIP_SUDO=1` skips privileged backup/restore sections.
4. Dry-run restore may pretend sudo is available for logging without executing.

## GUI layers

| Surface | File | Notes |
|---------|------|--------|
| GTK3 app | `bakup-gui.py` | Primary UI: backup label picker, restore tree with parts + dest column |
| Launcher | `bakup-gui` | `exec python3 bakup-gui.py` |
| Zenity wizard | `lib/restore-gui.sh` | Older multi-step popup flow; still used by some restore paths |

The GTK UI watches backup stdout for `PROGRESS label=… status=…` lines.

## Install layout

`install.sh` copies scripts into `~/.local/share/bakup/` and symlinks:

- `~/.local/bin/backup` → `backup.sh`
- `~/.local/bin/restore` → `restore.sh`
- `~/.local/bin/bakup-gui` → `bakup-gui`

Development usually runs scripts from the git checkout (this directory).
