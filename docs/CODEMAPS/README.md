# Codemap — bakup

Quick orientation for agents. Prefer this over grepping the whole tree first.

## Repository tree (source only)

```
bakup/
├── AGENTS.md              # Agent contract (read first)
├── README.md              # User-facing docs
├── LICENSE
├── .gitignore             # Ignores snapshot dirs + local agent scratch
├── backup.sh              # Backup entry (~1100 lines)
├── restore.sh             # Restore entry (~940 lines)
├── bakup-gui              # Thin bash → bakup-gui.py
├── bakup-gui.py           # GTK3 UI
├── bakup.desktop          # Desktop entry
├── install.sh             # Local install + PATH symlinks
├── docs/
│   ├── ARCHITECTURE.md
│   └── CODEMAPS/          # This folder
├── lib/
│   ├── askpass.sh         # SUDO_ASKPASS GUI helper
│   ├── sudo-helper.sh     # sudo_init / sudo_run
│   ├── restore_parts.py   # Part discovery + resolve
│   └── restore-gui.sh     # Zenity restore wizard
└── test/
    └── test_restore_map.sh
```

Live snapshot directories matching `YYYYMMDDThhmmssZ_*` may sit beside these files; they are **not** source.

## backup.sh

| Symbol / region | Purpose |
|-----------------|---------|
| `ALL_LABELS` | Canonical label list |
| `should_backup` / `run_label` | Filter + PROGRESS wrappers |
| `home_backup_path` | `$HOME/...` → relative path |
| `sync_one` | rsync/cp into `<TS>/<label>/home/<rel>` |
| `hash_label` | Append SHA256 lines |
| `backup_*` | Per-label collectors |
| `backup_gemini_codex` | extras-gemini/codex/agents |
| `backup_root_etc` | Privileged system-root |
| `emit_manifest` | Write `MANIFEST.json` |
| Main `run_label …` block | Dispatch table — keep aligned with restore |

## restore.sh

| Symbol / region | Purpose |
|-----------------|---------|
| `ALL_LABELS` | Must match backup.sh |
| `pick_latest_snapshot` | Choose newest complete snapshot under dest |
| `restore_home_tree` | Modern layout restore |
| `restore_part` / `restore_path_pair` | Partial restore via parts.py |
| `restore_label` | Per-label full restore switch |
| `restore_map_path` | Legacy mangled-name → `$HOME`-relative |
| `restore_legacy_subs` | Walk legacy subdirs using the map |
| `restore_system_extras` / `restore_system_root` | system + system-root |
| `--list-parts` early exit | Calls `lib/restore_parts.py list` |

## lib/restore_parts.py

| Symbol | Purpose |
|--------|---------|
| `Part` / `RestoreItem` | Data model |
| `FRIENDLY_LABEL` / `AGENT_TITLES` | UI strings |
| `parts_*` | Per-label part builders |
| `PART_BUILDERS` | label → builder map |
| `discover_parts` | Scan snapshot dirs |
| `resolve_destinations` | Apply optional dest override |
| CLI `list` / `resolve` | JSON / TSV for shell + GUI |

When adding fine-grained parts, extend the matching `parts_*` function and ensure IDs stay stable (`label/name`).

## bakup-gui.py

| Area | Purpose |
|------|---------|
| `FRIENDLY` / `DEFAULT_OFF_*` | Display names; which parts start unchecked |
| `list_labels` / `scan_snapshots` | Drive UI from scripts + filesystem |
| Backup tab | Runs `backup.sh --dest … --labels …`, parses PROGRESS |
| Restore tab | Tree of parts from `restore_parts.py`, editable dest, invokes `restore.sh` |

## Tests

`test/test_restore_map.sh` extracts `restore_map_path` from `restore.sh` and runs synthetic (and optional real-snapshot) checks. Run after any change to legacy path mapping.
