#!/usr/bin/python3
"""Bakup GUI — GTK3 front-end for backup.sh and restore.sh."""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gtk, Pango, Gdk

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))
try:
    from discover_apps import discover_extra_apps, discover_known_status
    from icon_lookup import load_pixbuf, lookup_icon_name
except ImportError:
    discover_extra_apps = None  # type: ignore[assignment]
    discover_known_status = None  # type: ignore[assignment]
    load_pixbuf = None  # type: ignore[assignment]
    lookup_icon_name = None  # type: ignore[assignment]

BACKUP_SH = SCRIPT_DIR / "backup.sh"
RESTORE_SH = SCRIPT_DIR / "restore.sh"
PARTS_PY = SCRIPT_DIR / "lib" / "restore_parts.py"
DEFAULT_DEST = os.environ.get("BACKUP_DEST", "/run/media/iggut/Data/bakup")
CUSTOM_CONFIG_PATH = Path("~/.config/bakup/custom.json").expanduser()

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
    "shell-dots": "Shell dotfiles",
    "hyprland": "Hyprland",
    "illogical-impulse": "illogical-impulse",
    "matugen-colors": "Matugen colors",
    "kde-theme": "KDE theming",
    "gtk-theme": "GTK theme",
    "desktop-entries": "Desktop entries",
    "git-config": "Git + gh",
    "mpv": "mpv",
    "mangohud": "MangoHud",
    "gaming-overlays": "Gaming overlays",
    "input-remapper": "Input remapper",
    "fonts": "Fonts",
    "audio-config": "Audio config",
    "klipper": "Klipper",
    "yubico": "YubiKey",
    "nvim": "Neovim / Vim",
    "vscode": "VS Code",
    "terminals": "Terminals",
    "firefox": "Firefox",
    "keepassxc": "KeePassXC",
    "paru": "paru / yay",
}


def get_friendly_name(label: str) -> str:
    if label in FRIENDLY:
        return FRIENDLY[label]
    if label.startswith("custom-"):
        parts = label[len("custom-"):].split("-")
        return " ".join(p.capitalize() for p in parts) + " (Custom)"
    if label.startswith("cfg-flatpak-"):
        parts = label[len("cfg-flatpak-"):].split("-")
        return " ".join(p.capitalize() for p in parts) + " (Flatpak)"
    if label.startswith("cfg-"):
        parts = label[len("cfg-"):].split("-")
        return " ".join(p.capitalize() for p in parts) + " (Config)"
    return label

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
    COL_ICON = 1
    COL_TITLE = 2
    COL_PART_ID = 3
    COL_DEST = 4
    COL_DEFAULT_DEST = 5
    COL_IS_LABEL = 6
    COL_LABEL = 7
    COL_DESC = 8

    def __init__(self) -> None:
        super().__init__(title="Bakup — Backup / Restore")
        self.set_default_size(1040, 800)
        self.set_border_width(10)
        self.connect("destroy", self._on_destroy)

        # Apply custom GTK3 styles for a modern, premium aesthetic
        try:
            css_provider = Gtk.CssProvider()
            css_provider.load_from_data(b"""
                /* Premium styling highlights */
                button {
                    border-radius: 6px;
                    padding: 6px 14px;
                    transition: background-color 0.2s ease, border-color 0.2s ease;
                }
                button.suggested-action {
                    background-color: #3584e4;
                    color: white;
                    font-weight: bold;
                    border: 1px solid #1b60c4;
                }
                button.suggested-action:hover {
                    background-color: #4a90e2;
                }
                button.destructive-action {
                    background-color: #e01b24;
                    color: white;
                    font-weight: bold;
                    border: 1px solid #a51d24;
                }
                button.destructive-action:hover {
                    background-color: #ec5858;
                }
                entry {
                    border-radius: 6px;
                    padding: 6px;
                }
                progressbar progress {
                    background-color: #3584e4;
                    background-image: linear-gradient(to right, #3584e4, #12c2e9);
                    border-radius: 4px;
                }
                progressbar trough {
                    border-radius: 4px;
                }
                notebook {
                    border-radius: 6px;
                }
                notebook tab {
                    padding: 6px 12px;
                    font-weight: 500;
                }
                notebook tab:checked {
                    border-bottom: 2px solid #3584e4;
                }
            """)
            screen = Gdk.Screen.get_default()
            if screen:
                Gtk.StyleContext.add_provider_for_screen(
                    screen,
                    css_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                )
        except Exception as e:
            sys.stderr.write(f"Failed to apply custom CSS: {e}\n")

        self.labels = list_labels()
        self.proc = None
        self._io_id = None
        self._progress_total = 0
        self._progress_done = 0
        self._updating_tree = False
        self._label_present: dict[str, bool] = {}
        self._extra_apps: list[dict] = []
        self._extra_temp: str | None = None

        self.backup_checks: dict[str, Gtk.CheckButton] = {}
        self.extra_checks: dict[str, Gtk.CheckButton] = {}
        self.custom_checks: dict[str, Gtk.CheckButton] = {}
        self._label_rows: dict[str, Gtk.Widget] = {}

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
        self.notebook.append_page(self._build_custom_paths_tab(), Gtk.Label(label="Custom Paths"))

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
        GLib.idle_add(self._refresh_presence)
        GLib.idle_add(self._scan_extra_apps_silent)
        GLib.idle_add(self._rebuild_custom_grid)
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
        self.backup_installed_only = Gtk.CheckButton(label="Show installed only")
        self.backup_installed_only.set_active(True)
        self.backup_installed_only.set_tooltip_text(
            "Hide known labels that have no config/data on this machine."
        )
        self.backup_installed_only.connect("toggled", lambda *_: self._apply_installed_filter())
        opts.pack_start(self.backup_sudo, False, False, 0)
        opts.pack_start(self.backup_preauth, False, False, 0)
        opts.pack_start(self.backup_installed_only, False, False, 0)
        box.pack_start(opts, False, False, 0)

        # Resizable columns container (single Gtk.Paned)
        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        paned.set_hexpand(True)
        paned.set_vexpand(True)
        box.pack_start(paned, True, True, 0)

        # Column 1 (Left): Known apps
        col1 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        col1.set_hexpand(True)
        col1.set_vexpand(True)
        col1.set_size_request(280, -1)
        col1.pack_start(Gtk.Label(label="Known apps & settings:", xalign=0), False, False, 0)

        self._label_scrolled, self._label_flow = self._make_flow(min_height=320, max_per_line=1)
        col1.pack_start(self._label_scrolled, True, True, 0)
        self._rebuild_label_grid(checked=True)

        sel_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        all_btn = Gtk.Button(label="Select all")
        all_btn.connect("clicked", lambda *_: self._set_all_visible(self.backup_checks, True))
        none_btn = Gtk.Button(label="Select none")
        none_btn.connect("clicked", lambda *_: self._set_all_visible(self.backup_checks, False))
        sel_row.pack_start(all_btn, False, False, 0)
        sel_row.pack_start(none_btn, False, False, 0)
        col1.pack_start(sel_row, False, False, 0)

        paned.pack1(col1, resize=True, shrink=False)

        # Column 2 (Right): Other installed apps
        col2 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        col2.set_hexpand(True)
        col2.set_vexpand(True)
        col2.set_size_request(280, -1)

        extra_hdr = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        extra_hdr.pack_start(
            Gtk.Label(label="Other installed apps (settings):", xalign=0), True, True, 0
        )
        scan_btn = Gtk.Button(label="Scan")
        scan_btn.set_tooltip_text(
            "Find ~/.config and Flatpak apps not already covered by known labels."
        )
        scan_btn.connect("clicked", lambda *_: self._scan_extra_apps())
        extra_hdr.pack_start(scan_btn, False, False, 0)
        col2.pack_start(extra_hdr, False, False, 0)

        self.extra_info = Gtk.Label(xalign=0)
        self.extra_info.set_markup(
            "<small>Scan to list other settings.</small>"
        )
        self.extra_info.set_line_wrap(True)
        col2.pack_start(self.extra_info, False, False, 0)

        self._extra_scrolled, self._extra_flow = self._make_flow(min_height=320, max_per_line=1)
        col2.pack_start(self._extra_scrolled, True, True, 0)

        extra_sel = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        e_all = Gtk.Button(label="Select all")
        e_all.connect("clicked", lambda *_: self._set_all(self.extra_checks, True))
        e_none = Gtk.Button(label="Select none")
        e_none.connect("clicked", lambda *_: self._set_all(self.extra_checks, False))
        extra_sel.pack_start(e_all, False, False, 0)
        extra_sel.pack_start(e_none, False, False, 0)
        col2.pack_start(extra_sel, False, False, 0)

        paned.pack2(col2, resize=True, shrink=False)

        # Separator below columns
        box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

        # Custom backups spanning full width at the bottom (below both columns)
        custom_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        custom_box.pack_start(Gtk.Label(label="Custom backups (dotfiles/themes):", xalign=0), False, False, 0)

        custom_info = Gtk.Label(xalign=0)
        custom_info.set_markup(
            "<small>Manage inside the Custom Paths tab.</small>"
        )
        custom_box.pack_start(custom_info, False, False, 0)

        self._custom_scrolled, self._custom_flow = self._make_flow(min_height=140, max_per_line=3)
        custom_box.pack_start(self._custom_scrolled, True, True, 0)

        custom_sel = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        c_all = Gtk.Button(label="Select all")
        c_all.connect("clicked", lambda *_: self._set_all(self.custom_checks, True))
        c_none = Gtk.Button(label="Select none")
        c_none.connect("clicked", lambda *_: self._set_all(self.custom_checks, False))
        custom_sel.pack_start(c_all, False, False, 0)
        custom_sel.pack_start(c_none, False, False, 0)
        custom_box.pack_start(custom_sel, False, False, 0)

        box.pack_start(custom_box, False, True, 0)

        start = Gtk.Button(label="Start Backup")
        start.get_style_context().add_class("suggested-action")
        start.connect("clicked", self._on_start_backup)
        box.pack_start(start, False, False, 0)
        return box

    def _make_flow(self, min_height: int = 180, max_per_line: int = 3) -> tuple[Gtk.ScrolledWindow, Gtk.FlowBox]:
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_min_content_height(min_height)
        grid = Gtk.FlowBox()
        grid.set_selection_mode(Gtk.SelectionMode.NONE)
        grid.set_max_children_per_line(max_per_line)
        grid.set_min_children_per_line(1)
        scrolled.add(grid)
        return scrolled, grid

    def _icon_image(self, label: str, hint: str | None = None, size: int = 22) -> Gtk.Image:
        img = Gtk.Image()
        img.set_size_request(size, size)
        pix = load_pixbuf(label, size, hint) if load_pixbuf else None
        if pix is not None:
            img.set_from_pixbuf(pix)
        else:
            name = (
                lookup_icon_name(label, hint)
                if lookup_icon_name
                else "application-x-executable"
            )
            img.set_from_icon_name(name, Gtk.IconSize.BUTTON)
            img.set_pixel_size(size)
        return img

    def _app_check_row(
        self, label_id: str, title: str, tooltip: str, checked: bool, icon_hint: str | None = None
    ) -> tuple[Gtk.Widget, Gtk.CheckButton]:
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        row.set_border_width(2)
        row.pack_start(self._icon_image(label_id, icon_hint), False, False, 0)
        cb = Gtk.CheckButton(label=title)
        cb.set_active(checked)
        cb.set_tooltip_text(tooltip)
        row.pack_start(cb, True, True, 0)
        row.show_all()
        return row, cb

    def _rebuild_label_grid(self, checked: bool = True) -> None:
        for child in list(self._label_flow.get_children()):
            self._label_flow.remove(child)
        self.backup_checks.clear()
        self._label_rows.clear()
        for label in self.labels:
            title = get_friendly_name(label)
            row, cb = self._app_check_row(label, title, label, checked)
            self.backup_checks[label] = cb
            self._label_rows[label] = row
            self._label_flow.add(row)
        self._label_flow.show_all()
        self._apply_installed_filter()

    def _apply_installed_filter(self) -> None:
        only = self.backup_installed_only.get_active()
        for label, row in self._label_rows.items():
            present = self._label_present.get(label, True)
            row.set_visible(present if only else True)

    def _refresh_presence(self) -> bool:
        if discover_known_status is None:
            return False
        try:
            status = discover_known_status(self.labels)
            self._label_present = {s["id"]: bool(s["present"]) for s in status}
            present_n = sum(1 for v in self._label_present.values() if v)
            self._append_log(
                f"Detected {present_n}/{len(self.labels)} known labels present on this machine.\n"
            )
            self._apply_installed_filter()
        except Exception as exc:
            self._append_log(f"Presence scan failed: {exc}\n")
        return False

    def _scan_extra_apps_silent(self) -> bool:
        self._scan_extra_apps()
        return False

    def _scan_extra_apps(self) -> None:
        if discover_extra_apps is None:
            self._append_log("discover_apps module unavailable.\n")
            return
        try:
            extras = discover_extra_apps(set(self.labels))
        except Exception as exc:
            self._append_log(f"App scan failed: {exc}\n")
            return
        self._extra_apps = extras
        for child in list(self._extra_flow.get_children()):
            self._extra_flow.remove(child)
        self.extra_checks.clear()
        for app in extras:
            app_id = app["id"]
            title = app.get("title") or app_id
            paths = app.get("paths") or []
            tip = f"{app_id}\n" + "\n".join(paths)
            row, cb = self._app_check_row(
                app_id, title, tip, checked=False, icon_hint=app.get("icon")
            )
            self.extra_checks[app_id] = cb
            # stash paths on the checkbutton
            cb._bakup_paths = paths  # type: ignore[attr-defined]
            cb._bakup_title = title  # type: ignore[attr-defined]
            self._extra_flow.add(row)
        self._extra_flow.show_all()
        self.extra_info.set_markup(
            f"<small>Found <b>{len(extras)}</b> additional apps with config. "
            "Select any to include in the backup.</small>"
        )
        self._append_log(f"Scanned {len(extras)} extra apps with settings.\n")

    def _set_all_visible(self, store: dict[str, Gtk.CheckButton], value: bool) -> None:
        for name, cb in store.items():
            row = self._label_rows.get(name)
            if row is not None and not row.get_visible():
                continue
            cb.set_active(value)
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
        # check, icon, title, part_id, dest, default_dest, is_label, label, desc
        self.parts_store = Gtk.TreeStore(
            bool, str, str, str, str, str, bool, str, str
        )
        self.parts_view = Gtk.TreeView(model=self.parts_store)
        self.parts_view.set_headers_visible(True)
        self.parts_view.set_enable_tree_lines(True)

        toggle = Gtk.CellRendererToggle()
        toggle.connect("toggled", self._on_part_toggled)
        col_check = Gtk.TreeViewColumn("", toggle, active=self.COL_CHECK)
        self.parts_view.append_column(col_check)

        icon_r = Gtk.CellRendererPixbuf()
        col_icon = Gtk.TreeViewColumn("", icon_r, icon_name=self.COL_ICON)
        self.parts_view.append_column(col_icon)

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

    def _label_icon_name(self, label: str) -> str:
        if lookup_icon_name:
            return lookup_icon_name(label)
        return "application-x-executable"

    # -------------------------------------------------------------- helpers
    def _set_all(self, store: dict[str, Gtk.CheckButton], value: bool) -> None:
        for cb in store.values():
            cb.set_active(value)

    def _selected(self, store: dict[str, Gtk.CheckButton]) -> list[str]:
        selected: list[str] = []
        for name, cb in store.items():
            if not cb.get_active():
                continue
            # Skip known labels hidden by "installed only" filter
            row = self._label_rows.get(name)
            if row is not None and not row.get_visible():
                continue
            selected.append(name)
        return selected

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
                    self._label_icon_name(label),
                    get_friendly_name(label),
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
                        "",
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
        # Double-click the dest column or browse column → folder picker
        cols = self.parts_view.get_columns()
        # columns: check(0), icon(1), name(2), dest(3), browse(4)
        if column not in cols[3:]:
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
        extra_selected: list[dict] = []
        for app_id, cb in self.extra_checks.items():
            if not cb.get_active():
                continue
            paths = getattr(cb, "_bakup_paths", None) or []
            title = getattr(cb, "_bakup_title", app_id)
            if not paths:
                # fall back to scan cache
                for app in self._extra_apps:
                    if app["id"] == app_id:
                        paths = app.get("paths") or []
                        title = app.get("title") or app_id
                        break
            if paths:
                extra_selected.append({"id": app_id, "title": title, "paths": paths})
                selected.append(app_id)
        for app_id, cb in self.custom_checks.items():
            if not cb.get_active():
                continue
            paths = getattr(cb, "_bakup_paths", None) or []
            title = getattr(cb, "_bakup_title", app_id)
            if paths:
                extra_selected.append({"id": app_id, "title": title, "paths": paths})
                selected.append(app_id)
        if not selected:
            self._append_log("Select at least one label, discovered app, or custom backup.\n")
            return
        dest = self.backup_dest.get_text().strip() or DEFAULT_DEST
        cmd = [str(BACKUP_SH), "--dest", dest, "--labels", ",".join(selected)]
        if extra_selected:
            # Write temp JSON for backup.sh --extra-apps
            try:
                fd, path = tempfile.mkstemp(prefix="bakup-extra-", suffix=".json")
                os.close(fd)
                Path(path).write_text(
                    json.dumps(extra_selected, indent=2), encoding="utf-8"
                )
                self._extra_temp = path
                cmd.extend(["--extra-apps", path])
            except OSError as exc:
                self._append_log(f"Failed to write extra-apps list: {exc}\n")
                return
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
                # Pre-install phase is not part of the selected-item count.
                if label != "install-apps":
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
        if self._extra_temp:
            try:
                os.unlink(self._extra_temp)
            except OSError:
                pass
            self._extra_temp = None
        if self.notebook.get_current_page() == 1:
            self._refresh_snapshots()
        return False

    # ------------------------------------------------------------ Custom Paths
    def _load_custom_backups(self) -> list[dict]:
        if not CUSTOM_CONFIG_PATH.parent.exists():
            try:
                CUSTOM_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
            except Exception as e:
                self._append_log(f"Failed to create config dir: {e}\n")
        if CUSTOM_CONFIG_PATH.is_file():
            try:
                return json.loads(CUSTOM_CONFIG_PATH.read_text(encoding="utf-8"))
            except Exception as e:
                self._append_log(f"Error loading custom backups: {e}\n")
        return []

    def _save_custom_backups(self, items: list[dict]) -> None:
        try:
            CUSTOM_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
            CUSTOM_CONFIG_PATH.write_text(json.dumps(items, indent=2), encoding="utf-8")
        except Exception as e:
            self._append_log(f"Error saving custom backups: {e}\n")

    def _rebuild_custom_grid(self) -> None:
        for child in list(self._custom_flow.get_children()):
            self._custom_flow.remove(child)
        self.custom_checks.clear()

        custom_items = self._load_custom_backups()
        if not custom_items:
            lbl = Gtk.Label()
            lbl.set_markup("<span color='gray'><i>No custom backups defined. Manage them in the Custom Paths tab.</i></span>")
            self._custom_flow.add(lbl)
            self._custom_flow.show_all()
            return

        for item in custom_items:
            app_id = item["id"]
            title = item["title"]
            paths = item["paths"]
            cb = Gtk.CheckButton(label=title)
            cb.set_active(True)
            cb._bakup_paths = paths
            cb._bakup_title = title
            self.custom_checks[app_id] = cb

            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            row.pack_start(cb, True, True, 0)
            tooltip = "Paths:\n" + "\n".join(paths)
            row.set_tooltip_text(tooltip)

            self._custom_flow.add(row)
        self._custom_flow.show_all()

    def _build_custom_paths_tab(self) -> Gtk.Widget:
        main_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        main_box.set_border_width(8)

        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_hexpand(True)
        scrolled.set_vexpand(True)

        self.custom_store = Gtk.ListStore(int, str, str)
        self.custom_tree = Gtk.TreeView(model=self.custom_store)
        self.custom_tree.set_headers_visible(True)

        r_title = Gtk.CellRendererText()
        col_title = Gtk.TreeViewColumn("Name", r_title, text=1)
        col_title.set_resizable(True)
        col_title.set_expand(True)
        self.custom_tree.append_column(col_title)

        r_paths = Gtk.CellRendererText()
        col_paths = Gtk.TreeViewColumn("Paths", r_paths, text=2)
        col_paths.set_resizable(True)
        col_paths.set_expand(True)
        self.custom_tree.append_column(col_paths)

        scrolled.add(self.custom_tree)
        main_box.pack_start(scrolled, True, True, 0)

        btn_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)

        add_btn = Gtk.Button(label="Add...")
        add_btn.connect("clicked", self._on_add_custom_item)
        btn_box.pack_start(add_btn, False, False, 0)

        edit_btn = Gtk.Button(label="Edit...")
        edit_btn.connect("clicked", self._on_edit_custom_item)
        btn_box.pack_start(edit_btn, False, False, 0)

        del_btn = Gtk.Button(label="Remove")
        del_btn.connect("clicked", self._on_del_custom_item)
        btn_box.pack_start(del_btn, False, False, 0)

        main_box.pack_start(btn_box, False, False, 0)

        self._refresh_custom_tree()
        return main_box

    def _refresh_custom_tree(self) -> None:
        self.custom_store.clear()
        items = self._load_custom_backups()
        for idx, item in enumerate(items):
            paths_str = ", ".join(item.get("paths", []))
            self.custom_store.append([idx, item.get("title", ""), paths_str])

    def _on_add_custom_item(self, _btn: Gtk.Button) -> None:
        dialog = CustomBackupDialog(self, title="Add Custom Backup")
        if dialog.run() == Gtk.ResponseType.OK:
            title, paths = dialog.get_data()
            if title and paths:
                import re
                slug = re.sub(r'[^a-z0-9]+', '-', title.strip().lower()).strip('-') or 'custom'
                app_id = f"custom-{slug}"

                items = self._load_custom_backups()
                existing_ids = {item["id"] for item in items}
                base_id = app_id
                counter = 1
                while app_id in existing_ids:
                    app_id = f"{base_id}-{counter}"
                    counter += 1

                items.append({
                    "id": app_id,
                    "title": title,
                    "paths": paths
                })
                self._save_custom_backups(items)
                self._refresh_custom_tree()
                self._rebuild_custom_grid()
        dialog.destroy()

    def _on_edit_custom_item(self, _btn: Gtk.Button) -> None:
        selection = self.custom_tree.get_selection()
        model, tree_iter = selection.get_selected()
        if not tree_iter:
            return
        idx = model[tree_iter][0]
        items = self._load_custom_backups()
        if idx < 0 or idx >= len(items):
            return
        item_data = items[idx]

        dialog = CustomBackupDialog(self, title="Edit Custom Backup", item_data=item_data)
        if dialog.run() == Gtk.ResponseType.OK:
            title, paths = dialog.get_data()
            if title and paths:
                item_data["title"] = title
                item_data["paths"] = paths
                self._save_custom_backups(items)
                self._refresh_custom_tree()
                self._rebuild_custom_grid()
        dialog.destroy()

    def _on_del_custom_item(self, _btn: Gtk.Button) -> None:
        selection = self.custom_tree.get_selection()
        model, tree_iter = selection.get_selected()
        if not tree_iter:
            return
        idx = model[tree_iter][0]
        items = self._load_custom_backups()
        if idx < 0 or idx >= len(items):
            return

        confirm = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text=f"Are you sure you want to remove the custom backup '{items[idx]['title']}'?"
        )
        if confirm.run() == Gtk.ResponseType.YES:
            items.pop(idx)
            self._save_custom_backups(items)
            self._refresh_custom_tree()
            self._rebuild_custom_grid()
        confirm.destroy()


# Custom Dialog for adding/editing Custom Backup Units
class CustomBackupDialog(Gtk.Dialog):
    def __init__(self, parent, title="Custom Backup Item", item_data=None):
        super().__init__(
            title=title,
            transient_for=parent,
            flags=0
        )
        self.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_SAVE, Gtk.ResponseType.OK
        )
        self.set_default_size(500, 400)
        self.set_border_width(8)

        # Get content area
        content = self.get_content_area()
        content.set_spacing(10)

        # Label & Entry for Title
        title_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        title_box.pack_start(Gtk.Label(label="Name:", xalign=0), False, False, 0)
        self.title_entry = Gtk.Entry()
        self.title_entry.set_hexpand(True)
        if item_data:
            self.title_entry.set_text(item_data.get("title", ""))
        title_box.pack_start(self.title_entry, True, True, 0)
        content.pack_start(title_box, False, False, 0)

        content.pack_start(Gtk.Label(label="Paths to backup (files or folders):", xalign=0), False, False, 0)

        # Paths TreeView
        path_scrolled = Gtk.ScrolledWindow()
        path_scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        path_scrolled.set_vexpand(True)

        self.path_store = Gtk.ListStore(str)
        self.path_tree = Gtk.TreeView(model=self.path_store)
        self.path_tree.set_headers_visible(False)

        cell = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn("Path", cell, text=0)
        self.path_tree.append_column(col)

        path_scrolled.add(self.path_tree)

        # Horizontal layout for paths + buttons
        paths_layout = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        paths_layout.pack_start(path_scrolled, True, True, 0)

        # Path buttons
        p_btn_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)

        add_file_btn = Gtk.Button(label="Add File...")
        add_file_btn.connect("clicked", self._on_add_file)
        p_btn_box.pack_start(add_file_btn, False, False, 0)

        add_folder_btn = Gtk.Button(label="Add Folder...")
        add_folder_btn.connect("clicked", self._on_add_folder)
        p_btn_box.pack_start(add_folder_btn, False, False, 0)

        remove_path_btn = Gtk.Button(label="Remove")
        remove_path_btn.connect("clicked", self._on_remove_path)
        p_btn_box.pack_start(remove_path_btn, False, False, 0)

        paths_layout.pack_start(p_btn_box, False, False, 0)
        content.pack_start(paths_layout, True, True, 0)

        # Populate if editing
        if item_data:
            for p in item_data.get("paths", []):
                self.path_store.append([p])

        self.show_all()

    def _on_add_file(self, _btn):
        dialog = Gtk.FileChooserDialog(
            title="Select File",
            parent=self,
            action=Gtk.FileChooserAction.OPEN
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OPEN, Gtk.ResponseType.OK
        )
        dialog.set_default_size(600, 450)
        dialog.set_current_folder(str(Path.home()))
        if dialog.run() == Gtk.ResponseType.OK:
            path = dialog.get_filename()
            if path:
                self.path_store.append([path])
        dialog.destroy()

    def _on_add_folder(self, _btn):
        dialog = Gtk.FileChooserDialog(
            title="Select Folder",
            parent=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OPEN, Gtk.ResponseType.OK
        )
        dialog.set_default_size(600, 450)
        dialog.set_current_folder(str(Path.home()))
        if dialog.run() == Gtk.ResponseType.OK:
            path = dialog.get_filename()
            if path:
                self.path_store.append([path])
        dialog.destroy()

    def _on_remove_path(self, _btn):
        selection = self.path_tree.get_selection()
        model, tree_iter = selection.get_selected()
        if tree_iter:
            model.remove(tree_iter)

    def get_data(self) -> tuple[str, list[str]]:
        title = self.title_entry.get_text().strip()
        paths = []
        for row in self.path_store:
            paths.append(row[0])
        return title, paths


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
