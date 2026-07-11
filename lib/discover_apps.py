#!/usr/bin/python3
"""Discover installed apps that have user config / settings to back up.

Used by bakup-gui.py to offer:
  - which known bakup labels look "present" on this machine
  - extra ~/.config (and related) apps not covered by ALL_LABELS

CLI:
  python3 lib/discover_apps.py [--json] [--known-labels a,b,c]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home()))).expanduser()

# Config-dir basenames (under ~/.config) already owned by a known label.
# Discovered "other apps" skip these so we don't double-offer.
KNOWN_CONFIG_DIRS: dict[str, str] = {
    "chromium": "chromium",
    "zen": "zen",
    "DankMaterialShell": "dms",
    "discord": "discord",
    "spotify": "spotify",
    "spicetify": "spotify",
    "INAV Configurator": "inav",
    "kdeconnect": "kdeconnect",
    "Antigravity": "antigravity",
    "Antigravity IDE": "antigravity",
    "Cursor": "cursor",
    "cursor": "cursor",
    "heroic": "heroic",
    "TelegramDesktop": "telegram",
    "hypr": "hyprland",
    "waybar": "hyprland",
    "wlogout": "hyprland",
    "hyprland": "hyprland",
    "wofi": "hyprland",
    "rofi": "hyprland",
    "fuzzel": "hyprland",
    "illogical-impulse": "illogical-impulse",
    "matugen": "matugen-colors",
    "gtk-3.0": "gtk-theme",
    "gtk-4.0": "gtk-theme",
    "git": "git-config",
    "gh": "git-config",
    "mpv": "mpv",
    "MangoHud": "mangohud",
    "vkBasalt": "gaming-overlays",
    "gamescope": "gaming-overlays",
    "cava": "gaming-overlays",
    "goverlay": "gaming-overlays",
    "input-remapper": "input-remapper",
    "input-remapper-2": "input-remapper",
    "pipewire": "audio-config",
    "pulse": "audio-config",
    "Yubico": "yubico",
    "nvim": "nvim",
    "Code": "vscode",
    "Code - OSS": "vscode",
    "alacritty": "terminals",
    "kitty": "terminals",
    "foot": "terminals",
    "ghostty": "terminals",
    "keepassxc": "keepassxc",
    "paru": "paru",
    "yay": "paru",
    "fish": "shell-dots",
    "starship.toml": "shell-dots",
    "konsolerc": "konsole",
    "konsolesshconfig": "konsole",
    "kdeglobals": "kde-theme",
    "plasmarc": "kde-theme",
    "plasmashellrc": "kde-theme",
    "klipperrc": "klipper",
}

# Top-level HOME entries owned by known labels.
KNOWN_HOME_ENTRIES: dict[str, str] = {
    ".hermes": "hermes",
    ".hermes-ui": "hermes-ui",
    "hermes-ui": "hermes-ui",
    ".claude": "claude",
    ".claude.json": "claude",
    ".antigravity": "antigravity",
    ".antigravity-ide": "antigravity",
    ".cursor": "cursor",
    ".steam": "steam",
    ".secrets": "secrets",
    ".gemini": "extras-gemini",
    ".codex": "extras-codex",
    ".agents": "extras-agents",
    ".openclaw": "extras-agents",
    ".ssh": "system",
    ".gnupg": "system",
    ".mempalace": "mempalace",
    ".mozilla": "firefox",
    ".vim": "nvim",
    ".vimrc": "nvim",
    ".gitconfig": "git-config",
    ".zshrc": "shell-dots",
    ".bashrc": "shell-dots",
    ".profile": "shell-dots",
    ".bash_profile": "shell-dots",
    ".zprofile": "shell-dots",
    ".zshenv": "shell-dots",
    ".yubico": "yubico",
}

# Presence probes for known labels (any existing path ⇒ "installed").
LABEL_PRESENCE: dict[str, tuple[str, ...]] = {
    "hermes": ("~/.hermes",),
    "hermes-ui": ("~/.hermes-ui", "~/hermes-ui"),
    "chromium": ("~/.config/chromium",),
    "zen": ("~/.config/zen",),
    "dms": ("~/.config/DankMaterialShell", "~/.local/state/DankMaterialShell"),
    "telegram": (
        "~/.local/share/TelegramDesktop",
        "~/.local/share/AyuGramDesktop",
        "~/.var/app/org.telegram.desktop",
    ),
    "discord": ("~/.config/discord", "~/.var/app/com.discordapp.Discord"),
    "spotify": ("~/.config/spotify", "~/.config/spicetify"),
    "inav": ("~/.config/INAV Configurator",),
    "kdeconnect": ("~/.config/kdeconnect",),
    "claude": ("~/.claude", "~/.claude.json"),
    "antigravity": ("~/.antigravity", "~/.config/Antigravity", "~/.config/Antigravity IDE"),
    "cursor": ("~/.cursor", "~/.config/Cursor"),
    "konsole": ("~/.local/share/konsole", "~/.config/konsolerc"),
    "heroic": ("~/.config/heroic",),
    "steam": ("~/.steam", "~/.local/share/Steam"),
    "system": ("~/.ssh", "~/.gnupg"),
    "system-root": ("/etc",),
    "secrets": ("~/.secrets",),
    "extras-gemini": ("~/.gemini",),
    "extras-codex": ("~/.codex",),
    "extras-agents": ("~/.agents", "~/.openclaw", "~/.copilot", "~/.opencode"),
    "mempalace": ("~/.mempalace",),
    "tailscale": ("/etc/default/tailscaled",),
    "packages": ("/usr/bin/pacman",),
    "shell-dots": ("~/.bashrc", "~/.zshrc", "~/.profile", "~/.config/fish", "~/.config/starship.toml"),
    "hyprland": ("~/.config/hypr", "~/.config/waybar", "~/.config/wlogout"),
    "illogical-impulse": ("~/.config/illogical-impulse",),
    "matugen-colors": ("~/.config/matugen",),
    "kde-theme": ("~/.config/kdeglobals", "~/.config/plasmarc", "~/.local/share/plasma"),
    "gtk-theme": ("~/.config/gtk-3.0", "~/.config/gtk-4.0"),
    "desktop-entries": ("~/.local/share/applications", "~/.config/mimeapps.list"),
    "git-config": ("~/.gitconfig", "~/.config/git", "~/.config/gh"),
    "mpv": ("~/.config/mpv",),
    "mangohud": ("~/.config/MangoHud",),
    "gaming-overlays": ("~/.config/vkBasalt", "~/.config/gamescope", "~/.config/cava"),
    "input-remapper": ("~/.config/input-remapper", "~/.config/input-remapper-2"),
    "fonts": ("~/.local/share/fonts", "~/.fonts"),
    "audio-config": ("~/.config/pipewire", "~/.config/pulse"),
    "klipper": ("~/.config/klipperrc", "~/.local/share/klipper"),
    "yubico": ("~/.config/Yubico", "~/.yubico"),
    "nvim": ("~/.config/nvim", "~/.vim", "~/.vimrc"),
    "vscode": ("~/.config/Code", "~/.config/Code - OSS"),
    "terminals": ("~/.config/alacritty", "~/.config/kitty", "~/.config/foot", "~/.config/ghostty"),
    "firefox": ("~/.mozilla",),
    "keepassxc": ("~/.config/keepassxc", "~/.cache/keepassxc"),
    "paru": ("~/.config/paru", "~/.config/yay"),
}

# Directories under ~/.config that are never useful as standalone "apps".
CONFIG_DENYLIST = {
    "autostart",
    "dconf",
    "evolution",
    "fontconfig",
    "glib-2.0",
    "goa-1.0",
    "gtk-3.0",
    "gtk-4.0",
    "ibus",
    "kde.org",
    "KDE",
    "libaccounts-glib",
    "pulse",
    "pipewire",
    "wireplumber",
    "systemd",
    "user-dirs.dirs",
    "user-dirs.locale",
    "xorg",
    "xdg",
    "menus",
    "session",
    "procps",
    "QtProject",
    "enchant",
    "fcitx",
    "fcitx5",
    "environment.d",
    "configstore",
    "Electron",
    "session",
    "plasma-workspace",
    "kdedefaults",
    "kded5rc",
    "kate",
    "katemetainfos",
    "kate-externaltoolspluginrc",
    "dolphin_service_menus_creator",
    "cosmic",  # often empty scaffolding
}

# Prefer skipping huge / regenerable trees when offering discovery.
SKIP_IF_NAME = {
    "Cache",
    "cache",
    "Code Cache",
    "GPUCache",
    "Crash Reports",
    "logs",
    "tmp",
    "node_modules",
    "__pycache__",
}

# KDE / Qt single-file noise in ~/.config (covered by kde-theme or not worth a row).
_KDE_RC_RE = re.compile(
    r"^(plasma|kwin|kglobal|kcm|kded|kde|dolphin|kate|konsole|klipper|"
    r"ark|okular|gwenview|spectacle|systemsettings|baloo|krunner|"
    r"kactivitymanagerd|powerdevil|powermanagement|kiorc|ktrash|"
    r"mimeapps|Trolltech|kuriikws|kconf_update|kfontinst|"
    r"auror|breezerc|oxygenrc|qtcurve)",
    re.I,
)

_SAFE = re.compile(r"[^a-z0-9]+")


def slugify(name: str) -> str:
    s = _SAFE.sub("-", name.strip().lower()).strip("-")
    return s or "app"


def _expand(path: str) -> Path:
    return Path(os.path.expanduser(path))


def path_exists(path: str) -> bool:
    return _expand(path).exists()


def label_is_present(label: str) -> bool:
    probes = LABEL_PRESENCE.get(label)
    if not probes:
        return True  # unknown → show
    if label == "packages":
        return path_exists("/usr/bin/pacman")
    if label == "system-root":
        return True
    if label == "tailscale":
        return path_exists("/usr/bin/tailscale") or path_exists("/etc/default/tailscaled")
    return any(path_exists(p) for p in probes)


def _parse_desktop_name_icon(path: Path) -> tuple[str | None, str | None]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None, None
    name = icon = None
    in_entry = False
    for line in text.splitlines():
        if line.strip() == "[Desktop Entry]":
            in_entry = True
            continue
        if line.startswith("[") and line.strip() != "[Desktop Entry]":
            if in_entry:
                break
            continue
        if not in_entry:
            continue
        if line.startswith("Name=") and name is None:
            name = line.split("=", 1)[1].strip()
        elif line.startswith("Icon=") and icon is None:
            icon = line.split("=", 1)[1].strip()
    return name, icon


def _desktop_lookup() -> dict[str, tuple[str, str | None]]:
    """stem/lower → (Name, Icon)."""
    out: dict[str, tuple[str, str | None]] = {}
    for directory in (
        Path("/usr/share/applications"),
        Path("/usr/local/share/applications"),
        HOME / ".local/share/applications",
    ):
        if not directory.is_dir():
            continue
        try:
            desks = list(directory.glob("*.desktop"))
        except OSError:
            continue
        for desk in desks:
            title, icon = _parse_desktop_name_icon(desk)
            if not title:
                continue
            stem = desk.stem.lower()
            out.setdefault(stem, (title, icon))
            parts = stem.split(".")
            if parts:
                out.setdefault(parts[-1], (title, icon))
    return out


def discover_extra_apps(known_labels: set[str] | None = None) -> list[dict]:
    """Return apps under ~/.config (etc.) not already covered by known labels."""
    known_labels = known_labels or set()
    desks = _desktop_lookup()
    results: list[dict] = []
    seen_ids: set[str] = set()

    config = HOME / ".config"
    if config.is_dir():
        try:
            children = sorted(config.iterdir(), key=lambda p: p.name.lower())
        except OSError:
            children = []
        for child in children:
            name = child.name
            if name.startswith(".") or name in CONFIG_DENYLIST:
                continue
            if name in SKIP_IF_NAME:
                continue
            # Skip KDE/Qt rc files and other loose config files — only dirs
            # (real app settings trees). Known single-file apps are covered
            # by curated labels (starship → shell-dots, etc.).
            if child.is_file():
                continue
            if not child.is_dir():
                continue
            if _KDE_RC_RE.match(name) or name.endswith("rc"):
                continue
            owner = KNOWN_CONFIG_DIRS.get(name)
            if owner and (not known_labels or owner in known_labels):
                continue
            # Skip empty-ish dirs
            app_id = f"cfg-{slugify(name)}"
            if app_id in seen_ids:
                continue
            seen_ids.add(app_id)
            desk_key = slugify(name)
            title, icon = desks.get(desk_key, (None, None))
            if title is None:
                # try original case key
                title, icon = desks.get(name.lower(), (name, None))
            if not title:
                title = name
            results.append(
                {
                    "id": app_id,
                    "title": title,
                    "icon": icon,
                    "paths": [str(child)],
                    "source": "config",
                    "known_label": owner,
                }
            )

    # Flatpak app data (settings often live here)
    var_app = HOME / ".var" / "app"
    if var_app.is_dir():
        try:
            flats = sorted(var_app.iterdir(), key=lambda p: p.name.lower())
        except OSError:
            flats = []
        for child in flats:
            if not child.is_dir():
                continue
            # Skip ones already covered
            flat_id = child.name
            if flat_id in {"org.telegram.desktop", "com.discordapp.Discord"}:
                continue
            # Only offer Flatpak apps that have a config or data tree worth copying.
            config_dir = child / "config"
            data_dir = child / "data"
            if not config_dir.is_dir() and not data_dir.is_dir():
                continue
            app_id = f"cfg-flatpak-{slugify(flat_id)}"
            if app_id in seen_ids:
                continue
            seen_ids.add(app_id)
            title, icon = desks.get(flat_id.lower(), (flat_id, None))
            paths = [str(child)]
            results.append(
                {
                    "id": app_id,
                    "title": f"{title} (Flatpak)",
                    "icon": icon,
                    "paths": paths,
                    "source": "flatpak",
                    "known_label": None,
                }
            )

    results.sort(key=lambda r: r["title"].lower())
    return results


def discover_known_status(labels: list[str]) -> list[dict]:
    return [
        {
            "id": label,
            "present": label_is_present(label),
        }
        for label in labels
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="JSON output (default)")
    parser.add_argument(
        "--known-labels",
        default="",
        help="Comma-separated known label ids (from backup.sh --list-labels)",
    )
    parser.add_argument(
        "--status-only",
        action="store_true",
        help="Only report present/absent for known labels",
    )
    args = parser.parse_args()
    known = [x.strip() for x in args.known_labels.split(",") if x.strip()]
    payload: dict
    if args.status_only:
        payload = {"known": discover_known_status(known)}
    else:
        payload = {
            "known": discover_known_status(known),
            "extra": discover_extra_apps(set(known)),
        }
    json.dump(payload, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
