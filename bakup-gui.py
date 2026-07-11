#!/usr/bin/python3
"""Bakup GUI — GTK3 front-end for backup.sh and restore.sh."""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gtk, Pango

SCRIPT_DIR = Path(__file__).resolve().parent
BACKUP_SH = SCRIPT_DIR / "backup.sh"
RESTORE_SH = SCRIPT_DIR / "restore.sh"
PARTS_PY = SCRIPT_DIR / "lib" / "restore_parts.py"
DEFAULT_DEST = os.environ.get("BACKUP_DEST", "/run/media/iggut/Data/bakup")

PROGRESS_RE = re.compile(r"^PROGRESS label=(\S+) status=(start|done)\s*$")

FRIENDLY = {
    "hermes": "Hermes Agent",
    "hermes-ui": "Hermes WebUI",
    "chromium": "Chromium",
    "zen": "Zen Browser",
    "dms": "DankMaterialShell",
    "telegram": "Telegram",
    "discord": "Discord",
    "spotify": "Spotify",
    "inav": "INAV Configurator",
    "kdeconnect": "KDE Connect",
    "claude": "Claude Code",
    "antigravity": "Antigravity",
    "cursor": "Cursor",
    "konsole": "Konsole",
    "heroic": "Heroic",
    "steam": "Steam",
    "system": "System extras",
    "system-root": "System root (/etc)",
    "secrets": "Secrets",
    "extras-gemini": "Gemini CLI",
    "extras-codex": "Codex CLI",
    "extras-agents": "Other agents",
    "mempalace": "MemPalace",
    "tailscale": "Tailscale",
    "packages": "Packages",
}

# Parts that are usually opt-in (large / redundant with finer parts).
DEFAULT_OFF_SUFFIXES = (
    "/all",
    "/cache",
)
DEFAULT_OFF_PREFIXES = (
    "zen/profile-",
    "chromium/profile-",
)


def list_labels() -> list[str]:
    try:
        out = subprocess.check_output(
            [str(BACKUP_SH), "--list-labels"],
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        sys.stderr.write(f"failed to list labels: {exc}\n")
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def scan_snapshots(dest: Path) -> list[dict]:
    """Return snapshot metadata sorted newest-first."""
    if not dest.is_dir():
        return []
    snaps: list[dict] = []
    for child in dest.iterdir():
        if not child.is_dir():
            continue
        name = child.name
        if name in {".git", "lib", ".agents", ".codex"} or name.startswith("."):
            continue
        if not re.match(r"^\d{8}T\d{6}Z_", name):
            continue
        complete = (child / ".complete").is_file()
        size = "?"
        labels: list[str] = []
        manifest = child / "MANIFEST.json"
        if manifest.is_file():
            try:
                data = json.loads(manifest.read_text(encoding="utf-8", errors="replace"))
                size = (data.get("totals") or {}).get("size", size)
                labels = [x.get("name", "") for x in data.get("labels", []) if x.get("name")]
            except (OSError, json.JSONDecodeError, TypeError):
                pass
        if not labels:
            labels = sorted(
                p.name
                for p in child.iterdir()
                if p.is_dir() and not p.name.startswith(".")
            )
        snaps.append(
            {
                "path": str(child),
                "name": name,
                "complete": complete,
                "size": size,
                "labels": labels,
            }
        )
    snaps.sort(key=lambda s: s["name"], reverse=True)
    return snaps


def load_parts(snapshot: str) -> list[dict]:
    if not PARTS_PY.is_file():
        return []
    try:
        out = subprocess.check_output(
            ["/usr/bin/python3", str(PARTS_PY), "list", snapshot],
            text=True,
            timeout=60,
        )
        data = json.loads(out)
        return list(data.get("parts") or [])
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, TypeError) as exc:
        sys.stderr.write(f"failed to list parts: {exc}\n")
        return []


def part_default_on(part_id: str) -> bool:
    for suf in DEFAULT_OFF_SUFFIXES:
        if part_id.endswith(suf):
            return False
    for pref in DEFAULT_OFF_PREFIXES:
        if part_id.startswith(pref):
            return False
    return True


class BakupWindow(Gtk.Window):
    # TreeStore columns
    COL_CHECK = 0
    COL_TITLE = 1
    COL_PART_ID = 2
    COL_DEST = 3
    COL_DEFAULT_DEST = 4
    COL_IS_LABEL = 5
    COL_LABEL = 6
    COL_DESC = 7

    def __init__(self) -> None:
        super().__init__(title="Bakup — Backup / Restore")
        self.set_default_size(980, 740)
        self.set_border_width(10)
        self.connect("destroy", self._on_destroy)

        self.labels = list_labels()
        self.proc = None
        self._io_id = None
        self._progress_total = 0
        self._progress_done = 0
        self._updating_tree = False

        self.backup_checks: dict[str, Gtk.CheckButton] = {}

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(root)

        header = Gtk.Label()
        header.set_markup(
            "<span size='large'><b>Bakup</b></span>  — app state backup &amp; restore"
        )
        header.set_xalign(0)
        root.pack_start(header, False, False, 0)

        self.notebook = Gtk.Notebook()
        root.pack_start(self.notebook, True, True, 0)

        self.notebook.append_page(self._build_backup_tab(), Gtk.Label(label="Backup"))
        self.notebook.append_page(self._build_restore_tab(), Gtk.Label(label="Restore"))

        log_frame = Gtk.Frame(label="Log")
        root.pack_start(log_frame, True, True, 0)
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_min_content_height(160)
        log_frame.add(scrolled)
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log_view.override_font(Pango.FontDescription("Monospace 10"))
        scrolled.add(self.log_view)
        self.log_buf = self.log_view.get_buffer()

        self.progress = Gtk.ProgressBar()
        self.progress.set_show_text(True)
        self.progress.set_text("Idle")
        root.pack_start(self.progress, False, False, 0)

        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        root.pack_start(btn_row, False, False, 0)
        self.cancel_btn = Gtk.Button(label="Cancel")
        self.cancel_btn.set_sensitive(False)
        self.cancel_btn.connect("clicked", self._on_cancel)
        btn_row.pack_end(self.cancel_btn, False, False, 0)

        self._append_log(f"Script dir: {SCRIPT_DIR}\n")
        if not self.labels:
            self._append_log("WARNING: could not load labels from backup.sh --list-labels\n")

    def _on_destroy(self, *_args) -> None:
        if Gtk.main_level() > 0:
            Gtk.main_quit()

    # ------------------------------------------------------------------ Backup
    def _build_backup_tab(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(8)

        dest_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        dest_row.pack_start(Gtk.Label(label="Destination:"), False, False, 0)
        self.backup_dest = Gtk.Entry()
        self.backup_dest.set_text(DEFAULT_DEST)
        self.backup_dest.set_hexpand(True)
        dest_row.pack_start(self.backup_dest, True, True, 0)
        browse = Gtk.Button(label="Browse…")
        browse.connect("clicked", self._browse_dest, self.backup_dest)
        dest_row.pack_start(browse, False, False, 0)
        box.pack_start(dest_row, False, False, 0)

        opts = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        self.backup_sudo = Gtk.CheckButton(label="Use sudo (privileged reads)")
        self.backup_sudo.set_active(True)
        self.backup_preauth = Gtk.CheckButton(label="Pre-auth sudo (long runs)")
        self.backup_preauth.set_active(False)
        opts.pack_start(self.backup_sudo, False, False, 0)
        opts.pack_start(self.backup_preauth, False, False, 0)
        box.pack_start(opts, False, False, 0)

        box.pack_start(Gtk.Label(label="Labels to back up:", xalign=0), False, False, 0)
        box.pack_start(self._label_grid(self.backup_checks, checked=True), True, True, 0)

        sel_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        all_btn = Gtk.Button(label="Select all")
        all_btn.connect("clicked", lambda *_: self._set_all(self.backup_checks, True))
        none_btn = Gtk.Button(label="Select none")
        none_btn.connect("clicked", lambda *_: self._set_all(self.backup_checks, False))
        sel_row.pack_start(all_btn, False, False, 0)
        sel_row.pack_start(none_btn, False, False, 0)
        box.pack_start(sel_row, False, False, 0)

        start = Gtk.Button(label="Start Backup")
        start.get_style_context().add_class("suggested-action")
        start.connect("clicked", self._on_start_backup)
        box.pack_start(start, False, False, 0)
        return box

    # ------------------------------------------------------------------ Restore
    def _build_restore_tab(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(8)

        dest_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        dest_row.pack_start(Gtk.Label(label="Backup root:"), False, False, 0)
        self.restore_dest = Gtk.Entry()
        self.restore_dest.set_text(DEFAULT_DEST)
        self.restore_dest.set_hexpand(True)
        dest_row.pack_start(self.restore_dest, True, True, 0)
        browse = Gtk.Button(label="Browse…")
        browse.connect("clicked", self._browse_dest, self.restore_dest)
        dest_row.pack_start(browse, False, False, 0)
        refresh = Gtk.Button(label="Refresh")
        refresh.connect("clicked", lambda *_: self._refresh_snapshots())
        dest_row.pack_start(refresh, False, False, 0)
        box.pack_start(dest_row, False, False, 0)

        snap_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        snap_row.pack_start(Gtk.Label(label="Snapshot:"), False, False, 0)
        self.snap_combo = Gtk.ComboBoxText()
        self.snap_combo.set_hexpand(True)
        self.snap_combo.connect("changed", self._on_snap_changed)
        snap_row.pack_start(self.snap_combo, True, True, 0)
        box.pack_start(snap_row, False, False, 0)
        self.snap_info = Gtk.Label(xalign=0)
        self.snap_info.set_line_wrap(True)
        box.pack_start(self.snap_info, False, False, 0)

        opts = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        self.restore_sudo = Gtk.CheckButton(label="Use sudo")
        self.restore_sudo.set_active(True)
        self.restore_dry = Gtk.CheckButton(label="Dry run (print only)")
        self.restore_dry.set_active(False)
        self.restore_full_labels = Gtk.CheckButton(
            label="Full labels only (ignore part breakdown)"
        )
        self.restore_full_labels.set_active(False)
        self.restore_full_labels.set_tooltip_text(
            "When on, restores whole labels like before (no --parts). "
            "Part checkboxes still choose which labels."
        )
        opts.pack_start(self.restore_sudo, False, False, 0)
        opts.pack_start(self.restore_dry, False, False, 0)
        opts.pack_start(self.restore_full_labels, False, False, 0)
        box.pack_start(opts, False, False, 0)

        hint = Gtk.Label(xalign=0)
        hint.set_markup(
            "<small>Expand a label to restore only some pieces. "
            "Edit <b>Restore to</b> to change the destination "
            "(original path is the default).</small>"
        )
        hint.set_line_wrap(True)
        box.pack_start(hint, False, False, 0)

        box.pack_start(
            Gtk.Label(label="What to restore:", xalign=0), False, False, 0
        )
        box.pack_start(self._build_parts_tree(), True, True, 0)

        sel_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        all_btn = Gtk.Button(label="Select defaults")
        all_btn.connect("clicked", lambda *_: self._parts_select_defaults())
        none_btn = Gtk.Button(label="Select none")
        none_btn.connect("clicked", lambda *_: self._parts_set_all(False))
        expand_btn = Gtk.Button(label="Expand all")
        expand_btn.connect("clicked", lambda *_: self.parts_view.expand_all())
        collapse_btn = Gtk.Button(label="Collapse all")
        collapse_btn.connect("clicked", lambda *_: self.parts_view.collapse_all())
        reset_dest = Gtk.Button(label="Reset destinations")
        reset_dest.connect("clicked", lambda *_: self._parts_reset_dests())
        for b in (all_btn, none_btn, expand_btn, collapse_btn, reset_dest):
            sel_row.pack_start(b, False, False, 0)
        box.pack_start(sel_row, False, False, 0)

        start = Gtk.Button(label="Start Restore")
        start.get_style_context().add_class("suggested-action")
        start.connect("clicked", self._on_start_restore)
        box.pack_start(start, False, False, 0)

        self._snapshots: list[dict] = []
        self._refresh_snapshots()
        return box

    def _build_parts_tree(self) -> Gtk.Widget:
        # check, title, part_id, dest, default_dest, is_label, label, desc
        self.parts_store = Gtk.TreeStore(bool, str, str, str, str, bool, str, str)
        self.parts_view = Gtk.TreeView(model=self.parts_store)
        self.parts_view.set_headers_visible(True)
        self.parts_view.set_enable_tree_lines(True)

        toggle = Gtk.CellRendererToggle()
        toggle.connect("toggled", self._on_part_toggled)
        col_check = Gtk.TreeViewColumn("", toggle, active=self.COL_CHECK)
        self.parts_view.append_column(col_check)

        text = Gtk.CellRendererText()
        col_name = Gtk.TreeViewColumn("Item", text, text=self.COL_TITLE)
        col_name.set_expand(True)
        col_name.set_min_width(220)
        self.parts_view.append_column(col_name)

        dest_r = Gtk.CellRendererText()
        dest_r.set_property("editable", True)
        dest_r.connect("edited", self._on_dest_edited)
        col_dest = Gtk.TreeViewColumn("Restore to", dest_r, text=self.COL_DEST)
        col_dest.set_expand(True)
        col_dest.set_min_width(280)
        self.parts_view.append_column(col_dest)

        browse_r = Gtk.CellRendererPixbuf()
        browse_r.set_property("icon-name", "folder-open-symbolic")
        col_browse = Gtk.TreeViewColumn("", browse_r)
        self.parts_view.append_column(col_browse)
        self.parts_view.connect("row-activated", self._on_parts_row_activated)

        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_min_content_height(260)
        scrolled.add(self.parts_view)
        return scrolled

    def _label_grid(self, store: dict[str, Gtk.CheckButton], checked: bool) -> Gtk.Widget:
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_min_content_height(160)
        grid = Gtk.FlowBox()
        grid.set_selection_mode(Gtk.SelectionMode.NONE)
        grid.set_max_children_per_line(4)
        grid.set_homogeneous(True)
        for label in self.labels:
            cb = Gtk.CheckButton(label=FRIENDLY.get(label, label))
            cb.set_active(checked)
            cb.set_tooltip_text(label)
            store[label] = cb
            grid.add(cb)
        scrolled.add(grid)
        return scrolled

    # -------------------------------------------------------------- helpers
    def _set_all(self, store: dict[str, Gtk.CheckButton], value: bool) -> None:
        for cb in store.values():
            cb.set_active(value)

    def _selected(self, store: dict[str, Gtk.CheckButton]) -> list[str]:
        return [name for name, cb in store.items() if cb.get_active()]

    def _browse_dest(self, _btn: Gtk.Button, entry: Gtk.Entry) -> None:
        dialog = Gtk.FileChooserDialog(
            title="Select folder",
            parent=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OPEN, Gtk.ResponseType.OK,
        )
        dialog.set_current_folder(entry.get_text() or DEFAULT_DEST)
        if dialog.run() == Gtk.ResponseType.OK:
            entry.set_text(dialog.get_filename() or entry.get_text())
        dialog.destroy()

    def _browse_path(self, current: str) -> str | None:
        dialog = Gtk.FileChooserDialog(
            title="Select restore destination",
            parent=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OPEN, Gtk.ResponseType.OK,
        )
        if current:
            folder = current if os.path.isdir(current) else str(Path(current).parent)
            if os.path.isdir(folder):
                dialog.set_current_folder(folder)
        result = None
        if dialog.run() == Gtk.ResponseType.OK:
            result = dialog.get_filename()
        dialog.destroy()
        return result

    def _append_log(self, text: str) -> None:
        end = self.log_buf.get_end_iter()
        self.log_buf.insert(end, text)
        mark = self.log_buf.create_mark(None, self.log_buf.get_end_iter(), False)
        self.log_view.scroll_to_mark(mark, 0.0, True, 0.0, 1.0)

    def _refresh_snapshots(self) -> None:
        dest = Path(self.restore_dest.get_text().strip() or DEFAULT_DEST)
        self._snapshots = scan_snapshots(dest)
        self.snap_combo.remove_all()
        for snap in self._snapshots:
            badge = "complete" if snap["complete"] else "incomplete"
            self.snap_combo.append_text(f"{snap['name']}  [{snap['size']}, {badge}]")
        if self._snapshots:
            self.snap_combo.set_active(0)
        else:
            self.snap_info.set_text("No snapshots found under this root.")
            self.parts_store.clear()

    def _on_snap_changed(self, combo: Gtk.ComboBoxText) -> None:
        idx = combo.get_active()
        if idx < 0 or idx >= len(self._snapshots):
            return
        snap = self._snapshots[idx]
        present = set(snap["labels"])
        self.snap_info.set_text(
            f"{snap['path']}\n"
            f"{len(present)} labels · {snap['size']} · "
            f"{'complete' if snap['complete'] else 'INCOMPLETE'}"
        )
        self._populate_parts_tree(snap["path"], present)

    def _populate_parts_tree(self, snapshot: str, present_labels: set[str]) -> None:
        self._updating_tree = True
        self.parts_store.clear()
        parts = load_parts(snapshot)
        if not parts:
            self._append_log(f"No parts discovered for {snapshot}\n")
            self._updating_tree = False
            return

        by_label: dict[str, list[dict]] = {}
        for part in parts:
            by_label.setdefault(part["label"], []).append(part)

        # Preserve backup.sh label order, then any extras.
        ordered = [l for l in self.labels if l in by_label]
        ordered += sorted(l for l in by_label if l not in ordered)

        for label in ordered:
            if present_labels and label not in present_labels:
                continue
            label_parts = by_label[label]
            # Parent checked if any default-on child would be on
            parent_on = any(part_default_on(p["id"]) for p in label_parts)
            parent = self.parts_store.append(
                None,
                [
                    parent_on,
                    FRIENDLY.get(label, label),
                    "",
                    "",
                    "",
                    True,
                    label,
                    f"{len(label_parts)} parts",
                ],
            )
            for part in label_parts:
                on = parent_on and part_default_on(part["id"])
                dest = part.get("default_dest") or ""
                title = part.get("title") or part["id"]
                desc = part.get("description") or ""
                if desc:
                    title = f"{title}  —  {desc}"
                self.parts_store.append(
                    parent,
                    [
                        on,
                        title,
                        part["id"],
                        dest,
                        dest,
                        False,
                        label,
                        desc,
                    ],
                )
            self._sync_parent_check(parent)
        self._updating_tree = False

    def _on_part_toggled(self, _renderer: Gtk.CellRendererToggle, path_str: str) -> None:
        if self._updating_tree:
            return
        path = Gtk.TreePath.new_from_string(path_str)
        it = self.parts_store.get_iter(path)
        current = self.parts_store[it][self.COL_CHECK]
        new_val = not current
        self.parts_store[it][self.COL_CHECK] = new_val
        if self.parts_store[it][self.COL_IS_LABEL]:
            child = self.parts_store.iter_children(it)
            while child is not None:
                # When turning a label on, apply default-on rules; when off, clear all.
                if new_val:
                    pid = self.parts_store[child][self.COL_PART_ID]
                    self.parts_store[child][self.COL_CHECK] = part_default_on(pid)
                else:
                    self.parts_store[child][self.COL_CHECK] = False
                child = self.parts_store.iter_next(child)
        else:
            parent = self.parts_store.iter_parent(it)
            if parent is not None:
                self._sync_parent_check(parent)

    def _sync_parent_check(self, parent) -> None:
        child = self.parts_store.iter_children(parent)
        any_on = False
        while child is not None:
            if self.parts_store[child][self.COL_CHECK]:
                any_on = True
                break
            child = self.parts_store.iter_next(child)
        self.parts_store[parent][self.COL_CHECK] = any_on

    def _on_dest_edited(self, _renderer: Gtk.CellRendererText, path_str: str, new_text: str) -> None:
        it = self.parts_store.get_iter(path_str)
        if self.parts_store[it][self.COL_IS_LABEL]:
            return
        self.parts_store[it][self.COL_DEST] = new_text.strip()

    def _on_parts_row_activated(self, _view: Gtk.TreeView, path: Gtk.TreePath, column: Gtk.TreeViewColumn) -> None:
        # Double-click the dest column (index 2) or browse column (index 3) → folder picker
        cols = self.parts_view.get_columns()
        if column not in cols[2:]:
            return
        it = self.parts_store.get_iter(path)
        if self.parts_store[it][self.COL_IS_LABEL]:
            return
        current = self.parts_store[it][self.COL_DEST] or self.parts_store[it][self.COL_DEFAULT_DEST]
        chosen = self._browse_path(current)
        if chosen:
            self.parts_store[it][self.COL_DEST] = chosen

    def _parts_set_all(self, value: bool) -> None:
        self._updating_tree = True
        it = self.parts_store.get_iter_first()
        while it is not None:
            self.parts_store[it][self.COL_CHECK] = value
            child = self.parts_store.iter_children(it)
            while child is not None:
                if value:
                    pid = self.parts_store[child][self.COL_PART_ID]
                    self.parts_store[child][self.COL_CHECK] = part_default_on(pid) if value else False
                else:
                    self.parts_store[child][self.COL_CHECK] = False
                child = self.parts_store.iter_next(child)
            if value:
                self._sync_parent_check(it)
            it = self.parts_store.iter_next(it)
        self._updating_tree = False

    def _parts_select_defaults(self) -> None:
        self._parts_set_all(True)

    def _parts_reset_dests(self) -> None:
        it = self.parts_store.get_iter_first()
        while it is not None:
            child = self.parts_store.iter_children(it)
            while child is not None:
                self.parts_store[child][self.COL_DEST] = self.parts_store[child][self.COL_DEFAULT_DEST]
                child = self.parts_store.iter_next(child)
            it = self.parts_store.iter_next(it)

    def _collect_restore_selection(self) -> tuple[list[str], list[tuple[str, str]], list[str]]:
        """Return (part_ids, maps, labels_with_any_part)."""
        part_ids: list[str] = []
        maps: list[tuple[str, str]] = []
        labels: list[str] = []
        it = self.parts_store.get_iter_first()
        while it is not None:
            label = self.parts_store[it][self.COL_LABEL]
            label_has = False
            child = self.parts_store.iter_children(it)
            while child is not None:
                if self.parts_store[child][self.COL_CHECK]:
                    pid = self.parts_store[child][self.COL_PART_ID]
                    dest = self.parts_store[child][self.COL_DEST]
                    default = self.parts_store[child][self.COL_DEFAULT_DEST]
                    part_ids.append(pid)
                    label_has = True
                    if dest and default and dest != default:
                        maps.append((pid, dest))
                child = self.parts_store.iter_next(child)
            if label_has:
                labels.append(label)
            it = self.parts_store.iter_next(it)
        return part_ids, maps, labels

    # --------------------------------------------------------------- run
    def _busy(self, busy: bool) -> None:
        self.cancel_btn.set_sensitive(busy)
        self.notebook.set_sensitive(not busy)

    def _on_cancel(self, _btn: Gtk.Button) -> None:
        if self.proc and self.proc.poll() is None:
            self._append_log("\n--- cancelling ---\n")
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                self.proc.terminate()

    def _on_start_backup(self, _btn: Gtk.Button) -> None:
        if self.proc and self.proc.poll() is None:
            return
        selected = self._selected(self.backup_checks)
        if not selected:
            self._append_log("Select at least one label.\n")
            return
        dest = self.backup_dest.get_text().strip() or DEFAULT_DEST
        cmd = [str(BACKUP_SH), "--dest", dest, "--labels", ",".join(selected)]
        if not self.backup_sudo.get_active():
            cmd.append("--no-sudo")
        if self.backup_preauth.get_active():
            cmd.append("--preauth-sudo")
        self._run(cmd, selected)

    def _on_start_restore(self, _btn: Gtk.Button) -> None:
        if self.proc and self.proc.poll() is None:
            return
        idx = self.snap_combo.get_active()
        if idx < 0 or idx >= len(self._snapshots):
            self._append_log("Pick a snapshot first.\n")
            return
        part_ids, maps, labels = self._collect_restore_selection()
        if not part_ids and not labels:
            self._append_log("Select at least one item to restore.\n")
            return
        snap = self._snapshots[idx]
        cmd = [
            str(RESTORE_SH),
            snap["path"],
            "--dest",
            self.restore_dest.get_text().strip() or DEFAULT_DEST,
        ]
        if self.restore_full_labels.get_active():
            cmd.extend(["--apps", ",".join(labels)])
            progress_keys = labels
        else:
            cmd.extend(["--parts", ",".join(part_ids)])
            for pid, dest in maps:
                cmd.extend(["--map", f"{pid}={dest}"])
            progress_keys = part_ids
        if not self.restore_sudo.get_active():
            cmd.append("--no-sudo")
        if self.restore_dry.get_active():
            cmd.append("--dry-run")
        self._run(cmd, progress_keys)

    def _run(self, cmd: list[str], labels: list[str]) -> None:
        self._append_log(f"\n$ {' '.join(cmd)}\n")
        self._progress_total = max(len(labels), 1)
        self._progress_done = 0
        self.progress.set_fraction(0.0)
        self.progress.set_text(f"0 / {self._progress_total}")
        self._busy(True)
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                cwd=str(SCRIPT_DIR),
                start_new_session=True,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )
        except OSError as exc:
            self._append_log(f"Failed to start: {exc}\n")
            self._busy(False)
            return
        assert self.proc.stdout is not None
        fd = self.proc.stdout.fileno()
        self._io_id = GLib.io_add_watch(
            fd, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self._on_proc_io
        )
        GLib.timeout_add(400, self._poll_proc)

    def _on_proc_io(self, _fd: int, condition: int) -> bool:
        if self.proc is None or self.proc.stdout is None:
            return False
        if condition & (GLib.IO_IN):
            line = self.proc.stdout.readline()
            if line:
                self._handle_line(line)
        if condition & (GLib.IO_HUP | GLib.IO_ERR):
            for line in self.proc.stdout:
                self._handle_line(line)
            return False
        return True

    def _handle_line(self, line: str) -> None:
        m = PROGRESS_RE.match(line.rstrip("\n"))
        if m:
            label, status = m.group(1), m.group(2)
            if status == "start":
                self.progress.set_text(
                    f"{label} … ({self._progress_done}/{self._progress_total})"
                )
            elif status == "done":
                self._progress_done += 1
                frac = min(self._progress_done / self._progress_total, 1.0)
                self.progress.set_fraction(frac)
                self.progress.set_text(
                    f"{self._progress_done} / {self._progress_total}  ({label} done)"
                )
        self._append_log(line)

    def _poll_proc(self) -> bool:
        if self.proc is None:
            return False
        code = self.proc.poll()
        if code is None:
            return True
        if self.proc.stdout is not None:
            for line in self.proc.stdout:
                self._handle_line(line)
        self._append_log(f"\n--- finished (exit {code}) ---\n")
        self.progress.set_fraction(1.0 if code == 0 else self.progress.get_fraction())
        self.progress.set_text("Done" if code == 0 else f"Failed (exit {code})")
        self.proc = None
        self._busy(False)
        if self.notebook.get_current_page() == 1:
            self._refresh_snapshots()
        return False


def main() -> int:
    if not BACKUP_SH.is_file() or not RESTORE_SH.is_file():
        print("backup.sh / restore.sh not found next to bakup-gui.py", file=sys.stderr)
        return 1
    win = BakupWindow()
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
