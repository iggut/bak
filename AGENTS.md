# AGENTS.md — working on bakup

Read this before changing code. Human-facing overview: [README.md](README.md). Architecture detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). File map: [docs/CODEMAPS/](docs/CODEMAPS/).

## What this repo is

**bakup** (branded “bak”) is a set of Arch/Garuda Linux scripts that snapshot desktop app state, secrets, and selected system files to an external drive, then restore them on a fresh install. Primary surfaces:

| Entry | Role |
|-------|------|
| `backup.sh` | Create a timestamped snapshot under `BACKUP_DEST` |
| `restore.sh` | Restore a snapshot (full label, or `--parts`) |
| `bakup-gui` / `bakup-gui.py` | GTK3 UI over backup + restore |
| `install.sh` | Install into `~/.local/share/bakup` + `~/.local/bin` |

This workspace directory is often also the **live backup destination**. Snapshot dirs (`YYYYMMDDThhmmssZ_Hostname/`) are gitignored — never commit them.

## Non-negotiable conventions

1. **Keep label lists in sync.** `ALL_LABELS` in `backup.sh` and `restore.sh` must match. Friendly names live in both `bakup-gui.py` (`FRIENDLY`) and `lib/restore_parts.py` (`FRIENDLY_LABEL`). After adding a label, update all four and wire:
   - `backup_<name>()` + `run_label` in `backup.sh`
   - `restore_label` case in `restore.sh`
   - `PART_BUILDERS` (or rely on `parts_generic_home`) in `lib/restore_parts.py`
2. **Prefer the modern layout.** New backups store HOME trees as `<label>/home/<relpath>` via `sync_one` / `home_backup_path`. Restore prefers `restore_home_tree`. Do not invent new mangled flat names for new labels.
3. **Legacy still matters.** Older snapshots use mangled dir names; `restore_map_path` + `restore_legacy_subs` exist only for those. Extend them carefully; do not break modern `home/` restores.
4. **No secrets in git.** Never commit `~/.secrets`, key material, live snapshots, or auth keys. Docs may mention paths; do not paste real credentials.
5. **PII / bloat exclusions.** When adding rsync sources, exclude caches, GPU shaders, `node_modules`, game downloads, session dumps that regenerate, and similar junk (mirror patterns in existing `backup_*` functions).
6. **Sudo goes through helpers.** Use `lib/sudo-helper.sh` (`sudo_init` / `sudo_run`) and `lib/askpass.sh`. Do not call bare `sudo` for new privileged paths unless matching an existing pattern that already does.
7. **Progress lines for the GUI.** Backup labels should emit `PROGRESS label=<id> status=start|done` (see `run_label`). The GTK UI parses these.

## Environment & CLI (source of truth)

| Variable / flag | Used by | Notes |
|-----------------|---------|--------|
| `BACKUP_DEST` | backup, restore, GUI | Default `/run/media/iggut/Data/bakup` |
| `--dest PATH` | backup, restore | Overrides destination / backup root |
| `--labels LIST` | backup | Comma-separated subset |
| `--apps LIST` | restore | Same idea as `--labels` |
| `--parts LIST` | restore | Part IDs like `zen/bookmarks` |
| `--map id=path` | restore | Override restore destination for a part |
| `--dry-run` / `-n` | restore | Print actions only |
| `--no-sudo` | backup, restore | Skip privileged ops |
| `--list-labels` | both | Print `ALL_LABELS` |
| `--list-parts` | restore | JSON via `lib/restore_parts.py` |

There is no `BACKUP_ROOT` env var — restore uses `BACKUP_DEST` internally as `BACKUP_ROOT`.

## How to verify changes

```bash
# Label lists agree
diff <(./backup.sh --list-labels) <(./restore.sh --list-labels)

# Path-map / legacy restore tests (synthetic; optional real snapshot arg)
./test/test_restore_map.sh

# Parts discovery against a real snapshot (if one exists locally)
./restore.sh --list-parts /path/to/SNAPSHOT | head

# Dry-run restore of one label
./restore.sh --dry-run --apps zen --no-sudo

# Python syntax
python3 -m py_compile bakup-gui.py lib/restore_parts.py
```

Do not run a full live backup/restore against the user’s machine unless they ask. Prefer `--dry-run`, `--list-*`, and synthetic tests.

## Safe edit map

| Change | Touch |
|--------|--------|
| New app/label | `backup.sh`, `restore.sh`, `lib/restore_parts.py`, `bakup-gui.py` FRIENDLY, README table |
| Finer partial restore | `lib/restore_parts.py` builders; restore already uses `--parts` |
| Sudo / askpass | `lib/sudo-helper.sh`, `lib/askpass.sh` |
| GTK UX | `bakup-gui.py` only (launcher `bakup-gui` is a thin wrapper) |
| App discovery / icons | `lib/discover_apps.py`, `lib/icon_lookup.py`, `bakup-gui.py` |
| Zenity wizard | `lib/restore-gui.sh` (older popup flow; keep working if you change restore CLI) |
| Install paths | `install.sh`, `bakup.desktop` |

## Anti-patterns

- Hardcoding a username into **new** path logic (legacy `restore_map_path` still has historical `iggut` cases — do not add more).
- Committing or “cleaning up” snapshot directories under this repo root.
- Rewriting bash to Python “for cleanliness” without a requested scope.
- Changing default `BACKUP_DEST` without an explicit user request.
- Skipping `ALL_LABELS` / FRIENDLY updates when adding labels.

## Docs maintenance

When behavior changes, update in this order: code → `AGENTS.md` / `docs/` if agent contracts change → `README.md` for user-visible CLI and tables.
