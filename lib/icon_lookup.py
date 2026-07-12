#!/usr/bin/python3
"""Resolve Freedesktop / GTK icons for bakup labels and discovered apps."""

from __future__ import annotations

import os
import re
from functools import lru_cache
from pathlib import Path

# Curated icon names (Freedesktop / theme) for known bakup labels.
LABEL_ICONS: dict[str, str] = {
    "hermes": "applications-science",
    "hermes-ui": "applications-internet",
    "chromium": "chromium",
    "zen": "zen-browser",
    "dms": "preferences-desktop",
    "telegram": "telegram",
    "discord": "discord",
    "spotify": "spotify-client",
    "inav": "applications-engineering",
    "kdeconnect": "kdeconnect",
    "claude": "utilities-terminal",
    "antigravity": "text-editor",
    "cursor": "cursor",
    "konsole": "utilities-terminal",
    "heroic": "heroic",
    "steam": "steam",
    "system": "dialog-password",
    "system-root": "system-run",
    "secrets": "security-high",
    "extras-gemini": "google-chrome",
    "extras-codex": "utilities-terminal",
    "extras-agents": "applications-development",
    "mempalace": "folder-documents",
    "tailscale": "network-workgroup",
    "packages": "system-software-install",
    # Desktop / shell
    "shell-dots": "utilities-terminal",
    "hyprland": "hyprland",
    "illogical-impulse": "preferences-desktop-theme",
    "matugen-colors": "preferences-desktop-color",
    "kde-theme": "preferences-desktop-theme",
    "gtk-theme": "preferences-desktop-theme",
    "desktop-entries": "application-x-desktop",
    "git-config": "git",
    "mpv": "mpv",
    "mangohud": "applications-games",
    "gaming-overlays": "applications-games",
    "input-remapper": "input-keyboard",
    "fonts": "preferences-desktop-font",
    "audio-config": "audio-card",
    "klipper": "klipper",
    "yubico": "yubikey",
    "nvim": "nvim",
    "vscode": "vscode",
    "terminals": "utilities-terminal",
    "firefox": "firefox",
    "keepassxc": "keepassxc",
    "paru": "system-software-install",
}

# Alternate icon names tried when the primary is missing.
LABEL_ICON_FALLBACKS: dict[str, tuple[str, ...]] = {
    "zen": ("zen-browser", "firefox", "web-browser"),
    "telegram": ("telegram", "org.telegram.desktop", "telegram-desktop"),
    "discord": ("discord", "com.discordapp.Discord"),
    "spotify": ("spotify-client", "spotify"),
    "heroic": ("heroic", "heroic-icon", "applications-games"),
    "cursor": ("cursor", "cursor-editor", "code", "text-editor"),
    "hyprland": ("hyprland", "preferences-desktop", "video-display"),
    "git-config": ("git", "gitg", "folder-git", "text-x-script"),
    "nvim": ("nvim", "neovim", "vim", "text-editor"),
    "vscode": ("vscode", "code", "com.visualstudio.code", "text-editor"),
    "firefox": ("firefox", "firefox-esr", "web-browser"),
    "keepassxc": ("keepassxc", "keepassx", "password"),
    "yubico": ("yubikey", "yubikey-manager", "security-high"),
    "klipper": ("klipper", "edit-paste", "edit-copy"),
    "mpv": ("mpv", "multimedia-player"),
    "paru": ("system-software-install", "package-x-generic"),
    "illogical-impulse": ("preferences-desktop-theme", "applications-graphics"),
    "matugen-colors": ("preferences-desktop-color", "applications-graphics"),
    "kde-theme": ("preferences-desktop-theme", "kde"),
    "gtk-theme": ("preferences-desktop-theme", "gtk3-demo"),
    "input-remapper": ("input-keyboard", "input-mouse", "preferences-desktop-peripherals"),
    "audio-config": ("audio-card", "audio-speakers", "multimedia-volume-control"),
    "fonts": ("preferences-desktop-font", "font-x-generic"),
    "desktop-entries": ("application-x-desktop", "preferences-system-windows"),
    "gaming-overlays": ("applications-games", "input-gaming"),
    "mangohud": ("applications-games", "utilities-system-monitor"),
    "shell-dots": ("utilities-terminal", "text-x-script"),
    "terminals": ("utilities-terminal", "terminal"),
    "packages": ("system-software-install", "package-x-generic"),
    "system": ("dialog-password", "preferences-system"),
    "system-root": ("system-run", "preferences-system"),
    "secrets": ("security-high", "dialog-password"),
    "tailscale": ("network-workgroup", "network-wired"),
    "mempalace": ("folder-documents", "accessories-dictionary"),
    "dms": ("preferences-desktop", "preferences-system-windows"),
    "inav": ("applications-engineering", "applications-science"),
    "kdeconnect": ("kdeconnect", "phone", "smartphone"),
    "claude": ("utilities-terminal", "applications-development"),
    "antigravity": ("text-editor", "applications-development"),
    "extras-gemini": ("google-chrome", "applications-internet"),
    "extras-codex": ("utilities-terminal", "applications-development"),
    "extras-agents": ("applications-development", "applications-science"),
    "hermes": ("applications-science", "applications-development"),
    "hermes-ui": ("applications-internet", "text-html"),
}

DEFAULT_ICON = "application-x-executable"


def _parse_desktop_icon(path: Path) -> str | None:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    in_desktop = False
    for line in text.splitlines():
        if line.strip() == "[Desktop Entry]":
            in_desktop = True
            continue
        if line.startswith("[") and line.strip() != "[Desktop Entry]":
            if in_desktop:
                break
            continue
        if in_desktop and line.startswith("Icon="):
            value = line.split("=", 1)[1].strip()
            return value or None
    return None


@lru_cache(maxsize=1)
def _desktop_icon_index() -> dict[str, str]:
    """Map lowercase app id / desktop stem → Icon= value."""
    index: dict[str, str] = {}
    dirs = [
        Path("/usr/share/applications"),
        Path("/usr/local/share/applications"),
        Path(os.environ.get("HOME", "")) / ".local/share/applications",
    ]
    for directory in dirs:
        if not directory.is_dir():
            continue
        try:
            entries = list(directory.glob("*.desktop"))
        except OSError:
            continue
        for desk in entries:
            icon = _parse_desktop_icon(desk)
            if not icon:
                continue
            stem = desk.stem.lower()
            index.setdefault(stem, icon)
            # org.foo.Bar → bar, foo
            parts = stem.split(".")
            if parts:
                index.setdefault(parts[-1], icon)
            # Strip common prefixes
            for prefix in ("org.", "com.", "io.", "net."):
                if stem.startswith(prefix):
                    rest = stem[len(prefix) :]
                    index.setdefault(rest, icon)
                    if "." in rest:
                        index.setdefault(rest.split(".")[-1], icon)
    return index


def candidate_icon_names(label: str, hint: str | None = None) -> list[str]:
    """Ordered icon name candidates for a label or discovered app id."""
    names: list[str] = []
    seen: set[str] = set()

    def add(name: str | None) -> None:
        if not name or name in seen:
            return
        seen.add(name)
        names.append(name)

    if hint:
        add(hint)
    add(LABEL_ICONS.get(label))
    for fb in LABEL_ICON_FALLBACKS.get(label, ()):
        add(fb)

    # Strip cfg- or custom- prefix used for discovered/custom apps
    slug = label
    if slug.startswith("cfg-"):
        slug = slug[4:]
    elif slug.startswith("custom-"):
        slug = slug[7:]
    add(slug)
    add(slug.replace("_", "-"))
    add(slug.replace("-", "_"))

    desk = _desktop_icon_index()
    add(desk.get(slug.lower()))
    add(desk.get(label.lower()))
    # Partial desktop matches
    for key, icon in desk.items():
        if key == slug.lower() or key.endswith("." + slug.lower()) or slug.lower() in key:
            add(icon)
            break

    if label.startswith("custom-"):
        add("folder")
        add("folder-symbolic")
        add("document-properties")

    add(DEFAULT_ICON)
    add("application-x-executable-symbolic")
    return names


def lookup_icon_name(label: str, hint: str | None = None) -> str:
    """Return the best icon *name* (not a pixbuf) for GTK set_from_icon_name."""
    return candidate_icon_names(label, hint)[0]


def load_pixbuf(label: str, size: int = 24, hint: str | None = None):
    """Load a GdkPixbuf for the label, always scaled to exactly size×size."""
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        from gi.repository import GdkPixbuf, Gtk
    except (ImportError, ValueError):
        return None

    theme = Gtk.IconTheme.get_default()
    # FORCE_SIZE asks the theme for an icon at the requested size; we still
    # scale afterward because some app icons ignore it and return native size.
    flags = Gtk.IconLookupFlags.FORCE_SIZE
    raw = None

    for name in candidate_icon_names(label, hint):
        if name.startswith("/") and Path(name).is_file():
            try:
                raw = GdkPixbuf.Pixbuf.new_from_file_at_size(name, size, size)
            except Exception:
                raw = None
            if raw is not None:
                break
            continue

        try:
            if theme.has_icon(name):
                raw = theme.load_icon(name, size, flags)
                if raw is not None:
                    break
        except Exception:
            raw = None

        try:
            info = theme.lookup_icon(name, size, flags)
            if info is not None:
                raw = info.load_icon()
                if raw is not None:
                    break
        except Exception:
            raw = None

    if raw is None:
        return None

    if raw.get_width() != size or raw.get_height() != size:
        raw = raw.scale_simple(size, size, GdkPixbuf.InterpType.BILINEAR)
    return raw


_SAFE_ID = re.compile(r"[^a-z0-9]+")


def slugify(name: str) -> str:
    s = _SAFE_ID.sub("-", name.strip().lower()).strip("-")
    return s or "app"
