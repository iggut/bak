#!/usr/bin/python3
"""Discover and resolve partial restore parts inside a bakup snapshot.

Used by restore.sh (--list-parts / --parts) and bakup-gui.py.

Part IDs look like ``label/part`` (e.g. ``zen/bookmarks``, ``extras-agents/openclaw``).
Each part maps one or more backup source paths to default restore destinations
under $HOME (or absolute system paths). Destinations can be overridden.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Iterable

HOME = Path(os.environ.get("HOME", str(Path.home()))).expanduser()

FRIENDLY_LABEL = {
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

AGENT_TITLES = {
    ".agents": "Agents skills registry",
    ".openclaw": "OpenClaw",
    ".acpx": "ACPX",
    ".gstack": "gstack",
    ".copilot": "GitHub Copilot",
    ".pi": "Pi agent",
    ".roo": "Roo",
    ".cline": "Cline",
    ".aider": "Aider",
    ".opencode": "OpenCode",
    ".claude": "Claude (extra copy)",
}


@dataclass
class RestoreItem:
    """One source → destination mapping inside a part."""

    src: str  # absolute path inside the snapshot
    default_dest: str  # absolute default restore path
    # Path relative to the part's common root (used when remapping a multi-item part)
    rel: str = ""


@dataclass
class Part:
    id: str
    label: str
    title: str
    description: str = ""
    items: list[RestoreItem] = field(default_factory=list)
    # If True, selecting the parent label without expanding restores this as part of "all"
    present: bool = True

    @property
    def default_dest(self) -> str:
        """Best single path to show in the UI (common parent or sole dest)."""
        if not self.items:
            return ""
        dests = [it.default_dest for it in self.items]
        if len(dests) == 1:
            return dests[0]
        try:
            return str(os.path.commonpath(dests))
        except ValueError:
            return dests[0]


def _exists(path: Path) -> bool:
    return path.exists()


def _profile_dirs(zen_config: Path) -> list[Path]:
    """Return Zen/Firefox profile directories under ~/.config/zen (in backup)."""
    if not zen_config.is_dir():
        return []
    profiles: list[Path] = []
    for child in sorted(zen_config.iterdir()):
        if not child.is_dir():
            continue
        name = child.name
        if name in {"Profile Groups", "firefox-mpris", "Crash Reports", "Pending Pings"}:
            continue
        # Heuristic: profile dirs contain prefs.js or places.sqlite
        if (child / "prefs.js").exists() or (child / "places.sqlite").exists():
            profiles.append(child)
    return profiles


def _sqlite_family(*bases: str) -> list[str]:
    out: list[str] = []
    for base in bases:
        out.extend([base, f"{base}-wal", f"{base}-shm"])
    return out


def parts_zen(label_dir: Path) -> list[Part]:
    cfg = label_dir / "home" / ".config" / "zen"
    cache = label_dir / "home" / ".cache" / "zen"
    parts: list[Part] = []
    profiles = _profile_dirs(cfg)

    def profile_part(part_key: str, title: str, desc: str, names: list[str]) -> Part:
        items: list[RestoreItem] = []
        for prof in profiles:
            dest_prof = HOME / ".config" / "zen" / prof.name
            for name in names:
                src = prof / name
                if not _exists(src):
                    continue
                items.append(
                    RestoreItem(
                        src=str(src),
                        default_dest=str(dest_prof / name),
                        rel=f"{prof.name}/{name}",
                    )
                )
        return Part(
            id=f"zen/{part_key}",
            label="zen",
            title=title,
            description=desc,
            items=items,
            present=bool(items),
        )

    parts.append(
        profile_part(
            "bookmarks",
            "Bookmarks",
            "places.sqlite + favicons + bookmark backups",
            _sqlite_family("places.sqlite", "favicons.sqlite") + ["bookmarkbackups"],
        )
    )
    parts.append(
        profile_part(
            "settings",
            "User settings",
            "prefs.js, containers, handlers, search, zen prefs",
            [
                "prefs.js",
                "user.js",
                "containers.json",
                "handlers.json",
                "search.json.mozlz4",
                "xulstore.json",
                "zen-keyboard-shortcuts.json",
                "zen-themes.json",
                "zen-live-folders.jsonlz4",
                "extension-preferences.json",
                "extension-settings.json",
                "compatability.ini",
                "compatibility.ini",
                "settings",
            ],
        )
    )
    parts.append(
        profile_part(
            "themes",
            "Themes / chrome CSS",
            "chrome/ userChrome + zen-themes.json",
            ["chrome", "zen-themes.json"],
        )
    )
    parts.append(
        profile_part(
            "extensions",
            "Extensions",
            "extensions/ + extensions.json",
            ["extensions", "extensions.json", "extension-store", "extension-store-menus"],
        )
    )
    parts.append(
        profile_part(
            "logins",
            "Saved logins & certs",
            "logins.db, key4.db, cert9.db",
            ["logins.db", "key4.db", "cert9.db", "pkcs11.txt", "logins.json"],
        )
    )
    parts.append(
        profile_part(
            "cookies",
            "Cookies & permissions",
            "cookies + permissions + site security",
            _sqlite_family("cookies.sqlite", "permissions.sqlite", "content-prefs.sqlite")
            + ["SiteSecurityServiceState.bin"],
        )
    )
    parts.append(
        profile_part(
            "sessions",
            "Sessions / tabs",
            "sessionstore + zen-sessions",
            [
                "sessionstore.jsonlz4",
                "sessionstore-backups",
                "sessionstore-logs",
                "zen-sessions.jsonlz4",
                "zen-sessions-backup",
                "sessionCheckpoints.json",
            ],
        )
    )

    # Profile registry (profiles.ini) — not inside a profile dir
    ini_items: list[RestoreItem] = []
    for name in ("profiles.ini", "installs.ini"):
        src = cfg / name
        if _exists(src):
            ini_items.append(
                RestoreItem(
                    src=str(src),
                    default_dest=str(HOME / ".config" / "zen" / name),
                    rel=name,
                )
            )
    if ini_items:
        parts.append(
            Part(
                id="zen/profiles-ini",
                label="zen",
                title="Profile registry",
                description="profiles.ini + installs.ini",
                items=ini_items,
            )
        )

    # Full profile trees (one part per profile) for "restore whole profile"
    for prof in profiles:
        slug = re.sub(r"[^A-Za-z0-9._-]+", "_", prof.name).strip("_")
        items = [
            RestoreItem(
                src=str(prof),
                default_dest=str(HOME / ".config" / "zen" / prof.name),
                rel=prof.name,
            )
        ]
        parts.append(
            Part(
                id=f"zen/profile-{slug}",
                label="zen",
                title=f"Full profile: {prof.name}",
                description="Entire profile directory",
                items=items,
            )
        )

    if cache.is_dir():
        parts.append(
            Part(
                id="zen/cache",
                label="zen",
                title="Cache",
                description="~/.cache/zen",
                items=[
                    RestoreItem(
                        src=str(cache),
                        default_dest=str(HOME / ".cache" / "zen"),
                        rel=".cache/zen",
                    )
                ],
            )
        )

    # Catch-all: anything under home/ not covered is still available as full tree
    home = label_dir / "home"
    if home.is_dir():
        parts.append(
            Part(
                id="zen/all",
                label="zen",
                title="Everything (full tree)",
                description="Entire zen/home → $HOME",
                items=[
                    RestoreItem(
                        src=str(home),
                        default_dest=str(HOME),
                        rel="home",
                    )
                ],
            )
        )
    return [p for p in parts if p.present and p.items]


def parts_chromium(label_dir: Path) -> list[Part]:
    cfg = label_dir / "home" / ".config" / "chromium"
    cache = label_dir / "home" / ".cache" / "chromium"
    parts: list[Part] = []
    if not cfg.is_dir():
        return parts

    profiles = [p for p in cfg.iterdir() if p.is_dir() and (p / "Preferences").exists()]
    if not profiles and (cfg / "Default").is_dir():
        profiles = [cfg / "Default"]

    def profile_part(key: str, title: str, desc: str, names: list[str]) -> Part:
        items: list[RestoreItem] = []
        for prof in profiles:
            dest_prof = HOME / ".config" / "chromium" / prof.name
            for name in names:
                src = prof / name
                if not _exists(src):
                    continue
                items.append(
                    RestoreItem(
                        src=str(src),
                        default_dest=str(dest_prof / name),
                        rel=f"{prof.name}/{name}",
                    )
                )
        return Part(
            id=f"chromium/{key}",
            label="chromium",
            title=title,
            description=desc,
            items=items,
            present=bool(items),
        )

    parts.append(
        profile_part(
            "bookmarks",
            "Bookmarks",
            "Bookmarks + Bookmarks.bak",
            ["Bookmarks", "Bookmarks.bak", "AccountBookmarks"],
        )
    )
    parts.append(
        profile_part(
            "settings",
            "Preferences",
            "Preferences + Secure Preferences",
            ["Preferences", "Secure Preferences"],
        )
    )
    parts.append(
        profile_part(
            "extensions",
            "Extensions",
            "Extensions dir + extension settings",
            [
                "Extensions",
                "Local Extension Settings",
                "Sync Extension Settings",
                "Managed Extension Settings",
                "Extension State",
                "Extension Rules",
                "Extension Scripts",
                "DNR Extension Rules",
            ],
        )
    )
    parts.append(
        profile_part(
            "logins",
            "Saved passwords",
            "Login Data",
            ["Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal"],
        )
    )
    parts.append(
        profile_part(
            "cookies",
            "Cookies",
            "Cookies DB",
            ["Cookies", "Cookies-journal"],
        )
    )
    parts.append(
        profile_part(
            "history",
            "History",
            "History + Favicons + Top Sites",
            [
                "History",
                "History-journal",
                "Favicons",
                "Favicons-journal",
                "Top Sites",
                "Top Sites-journal",
            ],
        )
    )
    parts.append(
        profile_part(
            "sessions",
            "Sessions / tabs",
            "Sessions directory",
            ["Sessions", "Current Session", "Current Tabs", "Last Session", "Last Tabs"],
        )
    )

    local_state = cfg / "Local State"
    if local_state.exists():
        parts.append(
            Part(
                id="chromium/local-state",
                label="chromium",
                title="Local State",
                description="Chromium Local State (profiles index)",
                items=[
                    RestoreItem(
                        src=str(local_state),
                        default_dest=str(HOME / ".config" / "chromium" / "Local State"),
                        rel="Local State",
                    )
                ],
            )
        )

    for prof in profiles:
        slug = re.sub(r"[^A-Za-z0-9._-]+", "_", prof.name).strip("_")
        parts.append(
            Part(
                id=f"chromium/profile-{slug}",
                label="chromium",
                title=f"Full profile: {prof.name}",
                description="Entire profile directory",
                items=[
                    RestoreItem(
                        src=str(prof),
                        default_dest=str(HOME / ".config" / "chromium" / prof.name),
                        rel=prof.name,
                    )
                ],
            )
        )

    home = label_dir / "home"
    if home.is_dir():
        parts.append(
            Part(
                id="chromium/all",
                label="chromium",
                title="Everything (full tree)",
                description="Entire chromium/home → $HOME",
                items=[
                    RestoreItem(src=str(home), default_dest=str(HOME), rel="home")
                ],
            )
        )
    if cache.is_dir():
        parts.append(
            Part(
                id="chromium/cache",
                label="chromium",
                title="Cache",
                description="~/.cache/chromium",
                items=[
                    RestoreItem(
                        src=str(cache),
                        default_dest=str(HOME / ".cache" / "chromium"),
                        rel=".cache/chromium",
                    )
                ],
            )
        )
    return [p for p in parts if p.items]


def parts_home_children(label: str, label_dir: Path, title_map: dict[str, str] | None = None) -> list[Part]:
    """One part per top-level entry under label/home/."""
    home = label_dir / "home"
    if not home.is_dir():
        return []
    title_map = title_map or {}
    parts: list[Part] = []
    for child in sorted(home.iterdir()):
        if child.name.startswith(".") and child.name in {".", ".."}:
            continue
        rel = child.name
        # Walk one more level for .config / .local / .cache so parts are useful
        if child.is_dir() and child.name in {".config", ".local", ".cache", ".var"}:
            for sub in sorted(child.iterdir()):
                rel2 = f"{child.name}/{sub.name}"
                dest = HOME / rel2
                key = sub.name.lstrip(".")
                parts.append(
                    Part(
                        id=f"{label}/{key}",
                        label=label,
                        title=title_map.get(rel2, title_map.get(sub.name, sub.name)),
                        description=f"~/{rel2}",
                        items=[
                            RestoreItem(
                                src=str(sub),
                                default_dest=str(dest),
                                rel=rel2,
                            )
                        ],
                    )
                )
            continue
        dest = HOME / rel
        parts.append(
            Part(
                id=f"{label}/{rel.lstrip('.')}",
                label=label,
                title=title_map.get(rel, AGENT_TITLES.get(rel, rel)),
                description=f"~/{rel}",
                items=[
                    RestoreItem(src=str(child), default_dest=str(dest), rel=rel)
                ],
            )
        )
    # Full tree
    parts.append(
        Part(
            id=f"{label}/all",
            label=label,
            title="Everything (full tree)",
            description=f"Entire {label}/home → $HOME",
            items=[RestoreItem(src=str(home), default_dest=str(HOME), rel="home")],
        )
    )
    return parts


def parts_extras_agents(label_dir: Path) -> list[Part]:
    return parts_home_children("extras-agents", label_dir, AGENT_TITLES)


def parts_cursor(label_dir: Path) -> list[Part]:
    home = label_dir / "home"
    parts: list[Part] = []
    mapping = [
        (".cursor", "cursor-dot", "Cursor ~/.cursor", "skills, mcp, plans, argv"),
        (".config/Cursor", "cursor-config", "Cursor app config", "~/.config/Cursor"),
        (".config/Cursor/User", "user-settings", "User settings/snippets", "settings.json, keybindings, snippets"),
        (".cursor/extensions", "extensions", "Extensions", "~/.cursor/extensions"),
        (".cursor/skills-cursor", "skills", "Skills", "~/.cursor/skills-cursor"),
        (".cursor/plugins", "plugins", "Plugins", "~/.cursor/plugins"),
        (".cursor/plans", "plans", "Plans", "~/.cursor/plans"),
        (".cursor/mcp.json", "mcp", "MCP config", "mcp.json"),
    ]
    for rel, key, title, desc in mapping:
        src = home / rel
        if not _exists(src):
            continue
        parts.append(
            Part(
                id=f"cursor/{key}",
                label="cursor",
                title=title,
                description=desc,
                items=[
                    RestoreItem(
                        src=str(src),
                        default_dest=str(HOME / rel),
                        rel=rel,
                    )
                ],
            )
        )
    if home.is_dir():
        parts.append(
            Part(
                id="cursor/all",
                label="cursor",
                title="Everything (full tree)",
                description="Entire cursor/home → $HOME",
                items=[RestoreItem(src=str(home), default_dest=str(HOME), rel="home")],
            )
        )
    return parts


def parts_spotify(label_dir: Path) -> list[Part]:
    home = label_dir / "home"
    specs = [
        (".config/spotify", "spotify-config", "Spotify config", "~/.config/spotify"),
        (".config/spicetify", "spicetify-config", "Spicetify config", "config-xpui.ini + CustomApps"),
        (".config/spicetify/Themes", "spicetify-themes", "Spicetify themes", "Themes/"),
        (".local/state/spicetify", "spicetify-state", "Spicetify state", "~/.local/state/spicetify"),
    ]
    parts: list[Part] = []
    for rel, key, title, desc in specs:
        src = home / rel
        if not _exists(src):
            continue
        parts.append(
            Part(
                id=f"spotify/{key}",
                label="spotify",
                title=title,
                description=desc,
                items=[
                    RestoreItem(src=str(src), default_dest=str(HOME / rel), rel=rel)
                ],
            )
        )
    if home.is_dir():
        parts.append(
            Part(
                id="spotify/all",
                label="spotify",
                title="Everything (full tree)",
                items=[RestoreItem(src=str(home), default_dest=str(HOME), rel="home")],
            )
        )
    return parts


def parts_system(label_dir: Path) -> list[Part]:
    mapping = [
        ("ssh", "SSH keys", str(HOME / ".ssh")),
        ("gnupg", "GnuPG", str(HOME / ".gnupg")),
        ("nssdb", "NSS DB (pki)", str(HOME / ".pki" / "nssdb")),
        ("keyrings", "Keyrings", str(HOME / ".local" / "share" / "keyrings")),
        ("libaccounts-glib", "Accounts", str(HOME / ".config" / "libaccounts-glib")),
        ("NM-system-connections", "NetworkManager connections", "/etc/NetworkManager/system-connections"),
        ("openvpn-client", "OpenVPN client", "/etc/openvpn/client"),
        ("systemd-user", "systemd user units", str(HOME / ".config" / "systemd" / "user")),
    ]
    parts: list[Part] = []
    for name, title, dest in mapping:
        src = label_dir / name
        if not _exists(src):
            continue
        parts.append(
            Part(
                id=f"system/{name}",
                label="system",
                title=title,
                description=dest,
                items=[RestoreItem(src=str(src), default_dest=dest, rel=name)],
            )
        )
    all_items: list[RestoreItem] = []
    for p in parts:
        all_items.extend(p.items)
    if all_items:
        parts.append(
            Part(
                id="system/all",
                label="system",
                title="Everything",
                description="All system extras subcomponents",
                items=list(all_items),
            )
        )
    return parts


def parts_system_root(label_dir: Path) -> list[Part]:
    mapping = [
        ("nftables", "nftables firewall", "/etc/nftables.conf"),
        ("ssh", "sshd / ssh config", "/etc/ssh"),
        ("pacman-keyring", "pacman keyring", "/etc/pacman.d/gnupg"),
        ("pacman.conf", "pacman.conf", "/etc/pacman.conf"),
        ("fstab", "fstab", "/etc/fstab"),
        ("crypttab", "crypttab", "/etc/crypttab"),
        ("hostname", "hostname", "/etc/hostname"),
        ("hosts", "hosts", "/etc/hosts"),
        ("machine-id", "machine-id", "/etc/machine-id"),
        ("locale.gen", "locale.gen", "/etc/locale.gen"),
        ("tailscaled-service", "tailscaled unit", "/usr/lib/systemd/system/tailscaled.service"),
        ("tailscale-var", "tailscale var metadata", "/var/lib/tailscale"),
        ("systemd-unit-files.txt", "systemd unit list (info)", str(label_dir / "systemd-unit-files.txt")),
        ("nftables-current-ruleset.nft", "live nft ruleset dump", str(label_dir / "nftables-current-ruleset.nft")),
    ]
    parts: list[Part] = []
    for name, title, dest in mapping:
        src = label_dir / name
        # nftables may be a dir with nftables.conf
        if name == "nftables":
            if (label_dir / "nftables" / "nftables.conf").exists():
                src = label_dir / "nftables" / "nftables.conf"
            elif (label_dir / "nftables.conf").exists():
                src = label_dir / "nftables.conf"
            else:
                continue
            parts.append(
                Part(
                    id="system-root/nftables",
                    label="system-root",
                    title=title,
                    description=dest,
                    items=[RestoreItem(src=str(src), default_dest=dest, rel="nftables.conf")],
                )
            )
            continue
        if not _exists(src):
            continue
        # informational-only dumps: default dest stays in a restore notes folder under home
        if name.endswith(".txt") or name.endswith(".nft"):
            dest = str(HOME / ".local" / "share" / "bakup-restore-notes" / name)
        parts.append(
            Part(
                id=f"system-root/{Path(name).stem}",
                label="system-root",
                title=title,
                description=dest,
                items=[RestoreItem(src=str(src), default_dest=dest, rel=name)],
            )
        )
    return parts


def parts_hermes(label_dir: Path) -> list[Part]:
    specs = [
        ("auth", "auth", "Auth tokens", "auth/"),
        (".env", "env", "Environment (.env)", ".env"),
        ("config.yaml", "config", "config.yaml", "main config"),
        ("SOUL.md", "soul", "SOUL.md", "persona"),
        ("skills", "skills", "Skills", "skills/"),
        ("plugins", "plugins", "Plugins", "plugins/"),
        ("memories", "memories", "Memories", "memories/"),
        ("cron", "cron", "Cron jobs", "cron/"),
        ("profiles", "profiles", "Profiles", "profiles/"),
        ("hermes-agent", "hermes-agent", "hermes-agent checkout", "source tree"),
        ("state.db", "state-db", "state.db", "SQLite state"),
    ]
    parts: list[Part] = []
    for name, key, title, desc in specs:
        src = label_dir / name
        if not _exists(src):
            continue
        parts.append(
            Part(
                id=f"hermes/{key}",
                label="hermes",
                title=title,
                description=desc,
                items=[
                    RestoreItem(
                        src=str(src),
                        default_dest=str(HOME / ".hermes" / name),
                        rel=name,
                    )
                ],
            )
        )
    parts.append(
        Part(
            id="hermes/all",
            label="hermes",
            title="Everything",
            description="Entire ~/.hermes",
            items=[
                RestoreItem(
                    src=str(label_dir),
                    default_dest=str(HOME / ".hermes"),
                    rel=".",
                )
            ],
        )
    )
    return parts


def parts_telegram(label_dir: Path) -> list[Part]:
    mapping = [
        ("TelegramDesktop", "telegram-desktop", "Telegram Desktop", str(HOME / ".local/share/TelegramDesktop")),
        ("AyuGramDesktop_tdata", "ayugram", "AyuGram tdata", str(HOME / ".local/share/AyuGramDesktop/tdata")),
        ("flatpak-telegram", "flatpak", "Flatpak Telegram", str(HOME / ".var/app/org.telegram.desktop")),
    ]
    parts: list[Part] = []
    for name, key, title, dest in mapping:
        src = label_dir / name
        if not _exists(src):
            continue
        parts.append(
            Part(
                id=f"telegram/{key}",
                label="telegram",
                title=title,
                description=dest,
                items=[RestoreItem(src=str(src), default_dest=dest, rel=name)],
            )
        )
    home = label_dir / "home"
    if home.is_dir():
        parts.append(
            Part(
                id="telegram/home",
                label="telegram",
                title="Home tree",
                items=[RestoreItem(src=str(home), default_dest=str(HOME), rel="home")],
            )
        )
    return parts


def parts_steam(label_dir: Path) -> list[Part]:
    mapping = [
        ("dot-steam", "dot-steam", "Steam ~/.steam", str(HOME / ".steam")),
        ("SteamShare", "share", "Steam share (login/userdata)", str(HOME / ".local/share/Steam")),
    ]
    parts: list[Part] = []
    for name, key, title, dest in mapping:
        src = label_dir / name
        if not _exists(src):
            continue
        parts.append(
            Part(
                id=f"steam/{key}",
                label="steam",
                title=title,
                description=dest,
                items=[RestoreItem(src=str(src), default_dest=dest, rel=name)],
            )
        )
    return parts


def parts_mempalace(label_dir: Path) -> list[Part]:
    specs = [
        ("chroma.sqlite3", "chroma", "chroma.sqlite3"),
        ("knowledge_graph.sqlite3", "knowledge-graph", "knowledge_graph.sqlite3"),
        ("palace", "palace", "palace/ (chromadb + HNSW)"),
        ("wal", "wal", "WAL"),
        ("config.json", "config", "config.json"),
        ("identity.txt", "identity", "identity.txt"),
        ("tunnels.json", "tunnels", "tunnels.json"),
    ]
    parts: list[Part] = []
    for name, key, title in specs:
        src = label_dir / name
        if not _exists(src):
            continue
        # also grab wal/shm siblings for sqlite
        items = [
            RestoreItem(
                src=str(src),
                default_dest=str(HOME / ".mempalace" / name),
                rel=name,
            )
        ]
        if name.endswith(".sqlite3"):
            for suf in ("-wal", "-shm"):
                sib = label_dir / f"{name}{suf}"
                if sib.exists():
                    items.append(
                        RestoreItem(
                            src=str(sib),
                            default_dest=str(HOME / ".mempalace" / f"{name}{suf}"),
                            rel=f"{name}{suf}",
                        )
                    )
        parts.append(
            Part(
                id=f"mempalace/{key}",
                label="mempalace",
                title=title,
                items=items,
            )
        )
    parts.append(
        Part(
            id="mempalace/all",
            label="mempalace",
            title="Everything",
            items=[
                RestoreItem(
                    src=str(label_dir),
                    default_dest=str(HOME / ".mempalace"),
                    rel=".",
                )
            ],
        )
    )
    return parts


def parts_generic_home(label: str, label_dir: Path) -> list[Part]:
    return parts_home_children(label, label_dir)


def parts_secrets(label_dir: Path) -> list[Part]:
    items: list[RestoreItem] = []
    if (label_dir / ".secrets").is_file():
        items.append(
            RestoreItem(
                src=str(label_dir / ".secrets"),
                default_dest=str(HOME / ".secrets"),
                rel=".secrets",
            )
        )
    else:
        items.append(
            RestoreItem(
                src=str(label_dir),
                default_dest=str(HOME / ".secrets"),
                rel=".",
            )
        )
    return [
        Part(
            id="secrets/all",
            label="secrets",
            title="~/.secrets",
            description="API keys / tokens",
            items=items,
        )
    ]


def parts_packages(label_dir: Path) -> list[Part]:
    parts: list[Part] = []
    for name, title in (
        ("pacman-explicit.txt", "pacman explicit packages"),
        ("paru-foreign.txt", "AUR / foreign packages"),
    ):
        src = label_dir / name
        if src.exists():
            parts.append(
                Part(
                    id=f"packages/{Path(name).stem}",
                    label="packages",
                    title=title,
                    description="Reinstall list (not a file copy)",
                    items=[
                        RestoreItem(
                            src=str(src),
                            default_dest=str(src),  # special: install handler
                            rel=name,
                        )
                    ],
                )
            )
    return parts


def parts_tailscale(label_dir: Path) -> list[Part]:
    parts: list[Part] = []
    env = label_dir / "tailscaled.env"
    if env.exists():
        parts.append(
            Part(
                id="tailscale/env",
                label="tailscale",
                title="tailscaled.env",
                description="/etc/default/tailscaled",
                items=[
                    RestoreItem(
                        src=str(env),
                        default_dest="/etc/default/tailscaled",
                        rel="tailscaled.env",
                    )
                ],
            )
        )
    for name in ("status.json", "netcheck.json", "version.txt", "RESTORE.md"):
        src = label_dir / name
        if src.exists():
            parts.append(
                Part(
                    id=f"tailscale/{Path(name).stem.lower()}",
                    label="tailscale",
                    title=name,
                    description="Informational snapshot",
                    items=[
                        RestoreItem(
                            src=str(src),
                            default_dest=str(HOME / ".local/share/bakup-restore-notes/tailscale" / name),
                            rel=name,
                        )
                    ],
                )
            )
    return parts


PART_BUILDERS: dict[str, Callable[[Path], list[Part]]] = {
    "zen": parts_zen,
    "chromium": parts_chromium,
    "extras-agents": parts_extras_agents,
    "cursor": parts_cursor,
    "spotify": parts_spotify,
    "system": parts_system,
    "system-root": parts_system_root,
    "hermes": parts_hermes,
    "telegram": parts_telegram,
    "steam": parts_steam,
    "mempalace": parts_mempalace,
    "secrets": parts_secrets,
    "packages": parts_packages,
    "tailscale": parts_tailscale,
}


def discover_parts(snapshot: Path, labels: Iterable[str] | None = None) -> list[Part]:
    snapshot = Path(snapshot)
    if not snapshot.is_dir():
        return []
    found_labels = sorted(
        p.name
        for p in snapshot.iterdir()
        if p.is_dir() and not p.name.startswith(".")
    )
    if labels is not None:
        wanted = set(labels)
        found_labels = [l for l in found_labels if l in wanted]

    parts: list[Part] = []
    for label in found_labels:
        label_dir = snapshot / label
        builder = PART_BUILDERS.get(label)
        if builder:
            parts.extend(builder(label_dir))
        elif (label_dir / "home").is_dir():
            parts.extend(parts_generic_home(label, label_dir))
        else:
            # Opaque label dir → single "all" part
            dest = str(HOME / f".{label}") if label not in {"inav"} else str(HOME / ".config/INAV Configurator")
            if label == "inav" and (label_dir / "INAVConfigurator").is_dir():
                parts.append(
                    Part(
                        id="inav/configurator",
                        label="inav",
                        title="INAV Configurator",
                        items=[
                            RestoreItem(
                                src=str(label_dir / "INAVConfigurator"),
                                default_dest=str(HOME / ".config/INAV Configurator"),
                                rel="INAVConfigurator",
                            )
                        ],
                    )
                )
            else:
                parts.append(
                    Part(
                        id=f"{label}/all",
                        label=label,
                        title=FRIENDLY_LABEL.get(label, label),
                        description=str(label_dir),
                        items=[
                            RestoreItem(
                                src=str(label_dir),
                                default_dest=dest,
                                rel=".",
                            )
                        ],
                    )
                )
    return parts


def part_to_dict(part: Part) -> dict:
    return {
        "id": part.id,
        "label": part.label,
        "title": part.title,
        "description": part.description,
        "default_dest": part.default_dest,
        "item_count": len(part.items),
        "items": [asdict(it) for it in part.items],
    }


def resolve_destinations(
    part: Part, override: str | None
) -> list[tuple[str, str]]:
    """Return (src, dest) pairs applying an optional destination override.

    Override semantics:
      - single item: override is the full destination path
      - multiple items: override is a parent directory; each item uses its ``rel``
    """
    if not override:
        return [(it.src, it.default_dest) for it in part.items]
    override = str(Path(override).expanduser())
    if len(part.items) == 1:
        return [(part.items[0].src, override)]
    pairs: list[tuple[str, str]] = []
    for it in part.items:
        rel = it.rel or Path(it.src).name
        pairs.append((it.src, str(Path(override) / rel)))
    return pairs


def cmd_list(args: argparse.Namespace) -> int:
    parts = discover_parts(Path(args.snapshot), args.labels.split(",") if args.labels else None)
    payload = {
        "snapshot": str(Path(args.snapshot).resolve()),
        "home": str(HOME),
        "parts": [part_to_dict(p) for p in parts],
    }
    if args.ids_only:
        for p in parts:
            print(p.id)
        return 0
    json.dump(payload, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    parts = {p.id: p for p in discover_parts(Path(args.snapshot))}
    part = parts.get(args.part)
    if not part:
        print(f"ERROR: unknown part {args.part}", file=sys.stderr)
        return 1
    pairs = resolve_destinations(part, args.dest)
    for src, dest in pairs:
        # TSV for bash consumption
        print(f"{src}\t{dest}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="List parts in a snapshot (JSON)")
    p_list.add_argument("snapshot")
    p_list.add_argument("--labels", default="", help="Comma-separated label filter")
    p_list.add_argument("--ids-only", action="store_true")
    p_list.set_defaults(func=cmd_list)

    p_res = sub.add_parser("resolve", help="Resolve src/dest pairs for one part")
    p_res.add_argument("snapshot")
    p_res.add_argument("part")
    p_res.add_argument("--dest", default="", help="Override destination")
    p_res.set_defaults(func=cmd_resolve)

    args = parser.parse_args(argv)
    if args.cmd == "resolve" and not args.dest:
        args.dest = None
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
