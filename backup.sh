#!/usr/bin/env bash
# ============================================================================
# backup.sh — App-specific backup of install state, settings, logins, secrets
#
# Destination: ${BACKUP_ROOT:-/run/media/${USER}/Data/bakup}
# OS:          Arch-based, pacman + (paru or yay as AUR helper)
#
# Strategy:
#   - rsync per app into a clean mirror under <DEST>/<app_name>/...
#   - Drop giant caches/build artifacts and game downloads
#   - Generate SHA256SUMS per app + a top-level manifest with paths + sizes
#   - Restore-side script detects what's missing and reinstalls + restores
#
# Apps covered (16 explicitly requested, plus 4 discovered agents):
#   Hermes      (auth.json, .env, config.yaml, skills/plugins/memories cache,
#                NOT sessions.jsonl dumps — they regenerate)
#   Hermes UI   (hermes-ui, .hermes-ui)
#   Chromium / Google Chrome
#   Zen         (zen browser — Firefox fork)
#   DMS         (DankMaterialShell + Quickshell if present)
#   Telegram    (TelegramDesktop + AyuGram fork)
#   Discord     (~/.config/discord)
#   Spotify     (~/.config/spotify + spicetify config)
#   INAV        (Configurator user dir + .config/INAV Configurator)
#   KDE Connect (~/.config/kdeconnect — includes certs & trusted devices)
#   Claude      (~/.claude — code is regenerable, only settings + skills + mcp)
#   Antigravity (~/.config/Antigravity*, ~/.antigravity*, ~antigravity-ide)
#   Cursor      (~/.cursor + ~/.config/Cursor — NOT full sqlite indexes)
#   Konsole     (~/.local/share/konsole + ~/.config/konsolerc)
#   Heroic      (~/.config/heroic + ~/.local/state/Heroic — NO game prefixes)
#   Steam       (Steam login: ~/.steam/{registry.vdf,exportedsettings.json,
#                steam.token} + ~/.local/share/Steam/{config,userdata,skins}
#                — NO steamapps, NO shader cache, NO Proton runtime)
#   ~/.secrets  (user-stashed API keys, .env, .npmrc, tokens — perms tightened)
#   Tailscale   (status snapshot, netcheck, version, daemon env — node-key
#                re-auth required on restore; see tailscale/RESTORE.md)
#
# Extras covered: Gemini CLI settings, Codex CLI settings, ECC plugin config,
#                 systemd user-level .config/systemd/user, ssh keys,
#                 Keyrings (Chrome/Firefox passwords), NetworkManager secrets,
#                 OpenVPN config, GPG private-keys, pki/nssdb, ~/.secrets.
#
# Privileged reads (require sudo, see lib/sudo-helper.sh — uses a GUI popup
# via lib/askpass.sh the first time sudo is touched, then lets sudo's
# timestamp cache handle the rest of the run):
#   * /etc/nftables.conf + current kernel ruleset (nft list ruleset)
#   * /etc/ssh/{sshd_config,sshd_config.d/,ssh_config}
#   * /etc/pacman.d/gnupg (keyring) + /etc/pacman.conf
#   * /etc/{fstab,crypttab,hostname,hosts,machine-id,locale.gen}
#   * /usr/lib/systemd/system/tailscaled.service + /var/lib/tailscale/ metadata
#   * NetworkManager system connections (/etc/NetworkManager/system-connections)
#   * OpenVPN client (/etc/openvpn/client)
#   * systemctl list-unit-files snapshot
#
# Pass --no-sudo to skip the privileged reads entirely (e.g. on a TTY
# without DISPLAY in a context where the popup would block).  Pass
# --preauth-sudo to refresh the sudo timestamp before each label so long
# runs don't expire the cache mid-backup.
# ============================================================================
set -euo pipefail

# Default destination — overridable via BACKUP_ROOT env var, e.g.:
#   BACKUP_ROOT=/mnt/nas/bakup ./backup.sh
# Defaults to /run/media/<user>/Data/bakup which is a portable external
# drive mounted under /run/media on a typical Linux desktop.
DEST="${BACKUP_ROOT:-/run/media/${USER}/Data/bakup}"
DATE="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s)"
TS_DIR="${DEST}/${DATE}_${HOST}"
mkdir -p "${TS_DIR}"
cd "${TS_DIR}"

# Resolve script dir so we can find lib/*.sh even if the script is invoked
# via PATH or symlink.  BASH_SOURCE[0] is the original $0; if sourced by
# another script the caller can override SCRIPT_DIR before sourcing us.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# CLI flags
SKIP_SUDO=0
PREAUTH_SUDO=0
for arg in "$@"; do
  case "${arg}" in
    --no-sudo)        SKIP_SUDO=1 ;;
    --preauth-sudo)   PREAUTH_SUDO=1 ;;
    --help|-h)
      sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -50
      exit 0
      ;;
    *) printf 'unknown arg: %s\n' "${arg}" 1>&2 ;;
  esac
done

LOG="${TS_DIR}/backup.log"
MANIFEST="${TS_DIR}/MANIFEST.json"
SHA_SUMS="${TS_DIR}/SHA256SUMS"
: > "${LOG}"
: > "${SHA_SUMS}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${LOG}" ; }
banner() { log ""; log "================ $* ================"; }

# ---------------------------------------------------------------------------
# Sudo helper (askpass popup for privileged reads)
# ---------------------------------------------------------------------------
# shellcheck source=lib/sudo-helper.sh
. "${SCRIPT_DIR}/lib/sudo-helper.sh"
SUDO_AVAILABLE=0
if [ "${SKIP_SUDO}" = "1" ]; then
  log "  (sudo skipped via --no-sudo; privileged reads will be skipped)"
elif sudo_init "${SCRIPT_DIR}/lib" 2>>"${LOG}"; then
  SUDO_AVAILABLE=1
  log "  (sudo credentials cached; privileged reads enabled)"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
must_exist() { [ -e "$1" ] || { log "  (skipped) $1 — not present"; return 1; }; }

# Sync one path into <TS_DIR>/<label>/<relative path>, excluding common junk
sync_one() {
  local label="$1" src="$2"; shift 2
  # remaining args become --exclude patterns
  local ex=()
  for p in "$@"; do ex+=(--exclude "$p"); done
  local dest="${TS_DIR}/${label}/$(echo "${src}" | sed 's|^/||;s|/|_|g')"
  if must_exist "${src}"; then
    log "  -> ${src}"
    mkdir -p "${dest}"
    if [ -d "${src}" ]; then
      rsync -a --info=stats2 "${ex[@]}" "${src}/" "${dest}/" 2>>"${LOG}" || log "  (rsync warnings for ${src})"
    else
      cp -a "${src}" "${dest}/" 2>>"${LOG}" || log "  (copy warning for ${src})"
    fi
  fi
}

# After sync, write SHA256 sums for the whole label, append to top-level
hash_label() {
  local label="$1"
  if [ -d "${TS_DIR}/${label}" ]; then
    log "  hash ${label}"
    # Use `find -readable` so root-owned directories that the unprivileged
    # backup user can't stat (e.g. NM/openvpn client files copied via
    # sudo) get skipped silently instead of triggering set -e/pipefail
    # failures via sha256sum's EACCES. The chmod-after-rsync step in the
    # parent labels makes this uncommon, but we belt-and-brace it.
    ( cd "${TS_DIR}" && find "${label}" -type f -readable -print0 2>/dev/null \
        | sort -z | xargs -0 sha256sum 2>/dev/null ) >> "${SHA_SUMS}" || true
  fi
}

# ---------------------------------------------------------------------------
# Per-app backup blocks
# ---------------------------------------------------------------------------

backup_hermes() {
  banner "Hermes Agent"
  mkdir -p "${TS_DIR}/hermes"
  # The whole ~/.hermes is needed EXCEPT session logs (jsonl) which regenerate
  # and cache directories which are 100% reproducible.
  if [ -d ~/.hermes ]; then
    rsync -a \
      --exclude 'sessions/' \
      --exclude 'cache/' \
      --exclude 'audio_cache/' \
      --exclude '.hermes_history' \
      --exclude 'checkpoints/' \
      --exclude '*.jsonl' \
      --exclude '*.tmp' \
      --exclude '*.lock' \
      --exclude 'request_dump_*.json' \
      --exclude '*.bak' \
      --exclude '*.broken-*' \
      --exclude '*.corrupt.*' \
      ~/.hermes/ "${TS_DIR}/hermes/" 2>>"${LOG}"
    log "  hashes: hermes/auth.json, hermes/config.yaml, hermes/.env, hermes/skills (top 5), hermes/plugins, hermes/memories"
  else
    log "  (skipped) ~/.hermes — not present"
  fi
  hash_label hermes
}

backup_hermes_ui() {
  banner "Hermes WebUI"
  mkdir -p "${TS_DIR}/hermes-ui"
  sync_one hermes-ui ~/hermes-ui 'node_modules' '__pycache__' '*.pyc' '.venv'
  if [ -d ~/.hermes-ui ]; then
    rsync -a ~/.hermes-ui/ "${TS_DIR}/hermes-ui/dot-hermes-ui/" 2>>"${LOG}"
  fi
  if [ -d ~/hermes-ui ]; then
    rsync -a --exclude='node_modules' --exclude='__pycache__' \
      --exclude='*.pyc' --exclude='.venv' --exclude='.git' \
      ~/hermes-ui/ "${TS_DIR}/hermes-ui/repo/" 2>>"${LOG}"
  fi
  hash_label hermes-ui
}

backup_chromium() {
  banner "Chromium / Chrome"
  # Default profiles hold: cookies, logins, history, bookmarks, extensions, sync
  sync_one chromium ~/.config/chromium 'Cache' 'Code Cache' 'GPUCache' \
    'Crashpad' 'component_crx_cache' 'BrowserMetrics*' 'ShaderCache' \
    'GrShaderCache' 'GraphiteDawnCache' 'SafetyNet'
  sync_one chromium ~/.cache/chromium 'Cache' 'Code Cache' \
    'GPUCache' 'Crashpad' 'component_crx_cache' 'BrowserMetrics*' \
    'ShaderCache' 'GrShaderCache' 'GraphiteDawnCache' 'SafetyNet'
  # pki is shared with Firefox; capture once at bottom under system
  hash_label chromium
}

backup_zen() {
  banner "Zen Browser"
  # Profiles hold: cookies, logins, history, extensions, sync, settings.
  # KEEP storage/, extensions/, bookmarkbackups/.
  sync_one zen ~/.config/zen 'cache2' 'thumbnails' 'OfflineCache' \
    'startupCache' 'minidumps' 'crashes' 'datareporting'
  sync_one zen ~/.cache/zen 2>/dev/null || true
  hash_label zen
}

backup_dms() {
  banner "DankMaterialShell (and Quickshell fallback)"
  mkdir -p "${TS_DIR}/dms"
  sync_one dms ~/.config/DankMaterialShell
  sync_one dms ~/.local/state/DankMaterialShell
  if [ -d ~/.local/state/quickshell ]; then
    rsync -a ~/.local/state/quickshell/ "${TS_DIR}/dms/quickshell/" 2>>"${LOG}"
  fi
  hash_label dms
}

backup_telegram() {
  banner "Telegram Desktop + AyuGram fork"
  # tdata holds DC keys, session, chat settings — KEEP all. Drop cache.
  mkdir -p "${TS_DIR}/telegram"
  if [ -d ~/.local/share/TelegramDesktop/tdata ]; then
    rsync -a \
      --exclude='emoji/cache_*' \
      --exclude='user_data' \
      --exclude='tmp' \
      ~/.local/share/TelegramDesktop/ "${TS_DIR}/telegram/TelegramDesktop/" 2>>"${LOG}"
  fi
  if [ -d ~/.local/share/AyuGramDesktop/tdata ]; then
    rsync -a ~/.local/share/AyuGramDesktop/tdata/ \
      "${TS_DIR}/telegram/AyuGramDesktop_tdata/" 2>>"${LOG}"
  fi
  if [ -d ~/.var/app/org.telegram.desktop ]; then
    rsync -a --exclude='cache' ~/.var/app/org.telegram.desktop/ \
      "${TS_DIR}/telegram/flatpak-telegram/" 2>>"${LOG}"
  fi
  hash_label telegram
}

backup_discord() {
  banner "Discord"
  mkdir -p "${TS_DIR}/discord"
  # LevelsDB at Local Storage holds the auth token + sessions.
  # Trust Tokens folder — required for not being flagged as new device.
  # Sync/Network state, leveldb, State Store.
  sync_one discord ~/.config/discord \
    'Cache' 'Code Cache' 'GPUCache' 'Crashpad' 'ShaderCache' 'logs' \
    'component_crx_cache' 'BrowserMetrics*'
  if [ -d ~/.var/app/com.discordapp.Discord ]; then
    rsync -a --exclude='cache' \
      ~/.var/app/com.discordapp.Discord/ \
      "${TS_DIR}/discord/flatpak-discord/" 2>>"${LOG}"
  fi
  hash_label discord
}

backup_spotify() {
  banner "Spotify (+ Spicetify)"
  sync_one spotify ~/.config/spotify
  # Spicetify (custom theme) — config lives in ~/.local/state/spicetify and ~/.config/spicetify
  sync_one spotify ~/.local/state/spicetify
  sync_one spotify ~/.config/spicetify 2>/dev/null || true
  # Not backing up ~/.cache/spotify (precompiled shaders; ~2GB; regenerates)
  hash_label spotify
}

backup_inav() {
  banner "INAV Configurator"
  mkdir -p "${TS_DIR}/inav"
  # Holds: persisted settings, port defaults, the last-seen firmware config
  if [ -d ~/.config/INAV\ Configurator ]; then
    rsync -a --exclude='cache' --exclude='Cache' \
      ~/.config/INAV\ Configurator/ "${TS_DIR}/inav/INAVConfigurator/" 2>>"${LOG}"
  fi
  hash_label inav
}

backup_kdeconnect() {
  banner "KDE Connect"
  mkdir -p "${TS_DIR}/kdeconnect"
  # privateKey.pem, certificate.pem, trusted_devices — REQUIRED to keep
  # device pairing so you don't have to re-pair every phone.
  sync_one kdeconnect ~/.config/kdeconnect
  sync_one kdeconnect ~/.local/share/kdeconnect 2>/dev/null || true
  sync_one kdeconnect ~/.cache/kdeconnect.app
  sync_one kdeconnect ~/.cache/kdeconnect.daemon
  sync_one kdeconnect ~/.cache/kdeconnect.sms 2>/dev/null || true
  hash_label kdeconnect
}

backup_claude() {
  banner "Claude Code"
  mkdir -p "${TS_DIR}/claude"
  # settings.json, mcp configs, agents, skills, history (compressed),
  # but NOT scratch project artifacts under .claude/<cwd-hash>.
  if [ -d ~/.claude ]; then
    rsync -a \
      --exclude='projects' \
      --exclude='file-history' \
      --exclude='i-gstack/node_modules' \
      --exclude='i-gstack/.git' \
      --exclude='i-gstack/browse/test' \
      --exclude='i-gstack/make-pdf/node_modules' \
      --exclude='i-gstack/design/node_modules' \
      --exclude='shell-snapshots' \
      --exclude='telemetry' \
      --exclude='downloads' \
      --exclude='cache' \
      --exclude='logs' \
      --exclude='tmp' \
      --exclude='node_modules' \
      --exclude='.venv' \
      --exclude='*.pid' --exclude='*.lock' \
      ~/.claude/ "${TS_DIR}/claude/" 2>>"${LOG}"
  fi
  if [ -d ~/.claude.json ]; then
    cp -a ~/.claude.json "${TS_DIR}/claude/.claude.json" 2>>"${LOG}" || true
  fi
  hash_label claude
}

backup_antigravity() {
  banner "Antigravity"
  mkdir -p "${TS_DIR}/antigravity"
  # Four locations, all four used by the IDE per process tree:
  #   ~/.antigravity
  #   ~/.antigravity-ide
  #   ~/.config/Antigravity
  #   ~/.config/Antigravity IDE
  #   ~/.local/share/antigravity-ide
  for src in "$HOME/.antigravity" "$HOME/.antigravity-ide" \
             "$HOME/.config/Antigravity" "$HOME/.config/Antigravity IDE" \
             "$HOME/.local/share/antigravity-ide"; do
    if [ -d "${src}" ]; then
      safe=$(echo "${src}" | tr '/ ' '__')
      rsync -a \
        --exclude='Cache' --exclude='Code Cache' --exclude='GPUCache' \
        --exclude='Crashpad' --exclude='ShaderCache' --exclude='logs' \
        --exclude='component_crx_cache' --exclude='BrowserMetrics*' \
        --exclude='CachedExtensions' --exclude='CachedExtensionVSIXs' \
        --exclude='CachedData' --exclude='extensions/.cache' \
        "${src}/" "${TS_DIR}/antigravity/${safe}/" 2>>"${LOG}" || true
    fi
  done
  hash_label antigravity
}

backup_cursor() {
  banner "Cursor"
  mkdir -p "${TS_DIR}/cursor"
  sync_one cursor ~/.cursor
  sync_one cursor ~/.config/Cursor 'Cache' 'Code Cache' 'GPUCache' \
    'Crashpad' 'ShaderCache' 'logs' 'CachedExtensions' \
    'CachedExtensionVSIXs' 'CachedData'
  hash_label cursor
}

backup_konsole() {
  banner "Konsole"
  mkdir -p "${TS_DIR}/konsole"
  sync_one konsole ~/.local/share/konsole
  # ~/.config/konsolerc, ~/.config/konsolesshconfig, ~/.config/kde-material-you-colors
  mkdir -p "${TS_DIR}/konsole/dot-config"
  for f in konsolerc konsolesshconfig; do
    [ -f ~/.config/$f ] && cp -a ~/.config/$f "${TS_DIR}/konsole/dot-config/$f" 2>>"${LOG}"
  done
  hash_label konsole
}

backup_heroic() {
  banner "Heroic Games Launcher"
  mkdir -p "${TS_DIR}/heroic"
  # Login tokens, store creds, gog/amazon/epic tokens
  sync_one heroic ~/.config/heroic
  sync_one heroic ~/.local/state/Heroic
  # Game data lives on the DATA drive (e.g. /run/media/<user>/Data/Heroic).
  # The Wine prefix is BIG (54GB) but it IS your install state per game;
  # back it up separately or note location.
  cat <<EOF | tee -a "${LOG}" >/dev/null
  WARN: Wine prefixes + game data are stored on the DATA drive (NOT in
        this folder). They survive reinstall because that drive is
        untouched. Reinstall Heroic, then point it back to the Wine
        prefixes it normally uses; Heroic auto-detects them on the
        mounted data drive.
EOF
  hash_label heroic
}

backup_steam() {
  banner "Steam"
  mkdir -p "${TS_DIR}/steam"
  # We ONLY need: registry.vdf (login state, server mapping), userdata
  # (per-user settings + login), config.vdf (UI settings). We do NOT
  # back up steamapps/ (game installs), shader cache, Proton runtime,
  # or compat data — they regenerate / are huge.
  if [ -f ~/.steam/registry.vdf ]; then
    mkdir -p "${TS_DIR}/steam/dot-steam"
    cp -a ~/.steam/registry.vdf "${TS_DIR}/steam/dot-steam/" 2>>"${LOG}"
    cp -a ~/.steam/exportedsettings.json "${TS_DIR}/steam/dot-steam/" 2>>"${LOG}"
    cp -a ~/.steam/steam.token "${TS_DIR}/steam/dot-steam/" 2>>"${LOG}"
  fi
  if [ -d ~/.local/share/Steam ]; then
    rsync -a \
      --exclude='steamapps/' \
      --exclude='shader_cache/' \
      --exclude='compatibilitytools.d/' \
      --exclude='ubuntu12_*' \
      --exclude='linux32/' --exclude='linux64/' \
      --exclude='graphics/' --exclude='music/' \
      --exclude='package/' \
      --exclude='logs/' \
      --exclude='dumps/' \
      --exclude='depotcache/' \
      --exclude='appcache/httpcache' \
      --exclude='appcache/librarycache' \
      --exclude='appcache/print_copies' \
      --exclude='*.log' \
      --exclude='*.vtf' --exclude='*.vtex' \
      ~/.local/share/Steam/ "${TS_DIR}/steam/SteamShare/" 2>>"${LOG}"
  fi
  hash_label steam
}

# ---------------------------------------------------------------------------
# System-wide secrets & aux state
# ---------------------------------------------------------------------------

backup_system_extras() {
  banner "System extras (ssh, gnupg, nssdb, keyrings, NM, VPN, systemd-user)"
  mkdir -p "${TS_DIR}/system"
  # SSH keys (private + public) — guarded by per-file mode preservation
  if [ -d ~/.ssh ]; then
    rsync -a --exclude='known_hosts*' --exclude='*.lock' \
      ~/.ssh/ "${TS_DIR}/system/ssh/" 2>>"${LOG}"
  fi
  # GPG private keys (if any are present)
  if [ -d ~/.gnupg ]; then
    rsync -a --exclude='*.lock' --exclude='S.gpg-agent*' \
      --exclude='.gpg-v21-mbox' --exclude='random_seed' \
      ~/.gnupg/ "${TS_DIR}/system/gnupg/" 2>>"${LOG}"
  fi
  # NSS DB (Chrome/Firefox SSL client certs)
  if [ -d ~/.pki/nssdb ]; then
    rsync -a ~/.pki/nssdb/ "${TS_DIR}/system/nssdb/" 2>>"${LOG}"
  fi
  # GNOME Online Accounts (Google Drive, Nextcloud, etc.)
  if [ -d ~/.config/libaccounts-glib ]; then
    rsync -a ~/.config/libaccounts-glib/ \
      "${TS_DIR}/system/libaccounts-glib/" 2>>"${LOG}"
  fi
  # KDE keyring / Secret Service (Chromium & Firefox passwords)
  if [ -d ~/.local/share/keyrings ]; then
    rsync -a ~/.local/share/keyrings/ \
      "${TS_DIR}/system/keyrings/" 2>>"${LOG}"
  fi
  # NetworkManager secrets (Wi-Fi passwords, VPN certs) — root
  if [ -d /etc/NetworkManager/system-connections ]; then
    if [ "${SUDO_AVAILABLE}" = "1" ]; then
      sudo_run rsync -a /etc/NetworkManager/system-connections/ \
        "${TS_DIR}/system/NM-system-connections/" 2>>"${LOG}" || \
        log "  (NM system secrets rsync returned non-zero)"
      # Allow the post-backup `find` walk to stat these files even when
      # running as the unprivileged user. Mode 0400 is fine for reads;
      # we strip group/other write that rsync may have preserved.
      chmod -R u+rwX,go+rX,go-w "${TS_DIR}/system/NM-system-connections/" 2>/dev/null || true
    else
      log "  (sudo unavailable — skipping NM system secrets)"
    fi
  fi
  # OpenVPN client configs — root
  if [ -d /etc/openvpn/client ]; then
    if [ "${SUDO_AVAILABLE}" = "1" ]; then
      sudo_run rsync -a /etc/openvpn/client/ \
        "${TS_DIR}/system/openvpn-client/" 2>>"${LOG}" || \
        log "  (openvpn client rsync returned non-zero)"
      chmod -R u+rwX,go+rX,go-w "${TS_DIR}/system/openvpn-client/" 2>/dev/null || true
    else
      log "  (sudo unavailable — skipping openvpn client)"
    fi
  fi
  # systemd-user units (autostart, services) — user-readable
  if [ -d ~/.config/systemd/user ]; then
    rsync -a --exclude='*.preset' ~/.config/systemd/user/ \
      "${TS_DIR}/system/systemd-user/" 2>>"${LOG}" || true
  fi
  if [ -d ~/.local/share/systemd/user ]; then
    rsync -a ~/.local/share/systemd/user/ \
      "${TS_DIR}/system/systemd-user-share/" 2>>"${LOG}" || true
  fi
  hash_label system
}

# ---------------------------------------------------------------------------
# /etc + /var/lib snapshots that need root: this is the "rebuild the box"
# label.  Each item is gated by SUDO_AVAILABLE; if the user did not authenticate
# the popup, we skip cleanly with an informational log line and continue.
# ---------------------------------------------------------------------------
backup_root_etc() {
  banner "Root-protected /etc + /var/lib (firewall, sshd, pacman keyring, …)"
  mkdir -p "${TS_DIR}/system-root"

  # Helper: copy one path with sudo, falling back to plain `cp` if the
  # file is already user-readable. Many /etc files (sddm, nftables,
  # pacman.conf) are 644; we don't need sudo for those.  We always
  # attempt the read; only escalate to sudo if SUDO_AVAILABLE=1 AND
  # the read fails.
  sudo_copy_one() {
    local src="$1" dest="$2"
    [ -e "${src}" ] || { log "  (skipped) ${src} — not present"; return 0; }
    mkdir -p "${dest}"
    if [ -r "${src}" ]; then
      cp -a "${src}" "${dest}/" 2>>"${LOG}" || \
        log "  (copy failed) ${src}"
    elif [ "${SUDO_AVAILABLE}" = "1" ]; then
      sudo_run cp -a "${src}" "${dest}/" 2>>"${LOG}" || \
        log "  (sudo copy failed) ${src}"
    else
      log "  (not readable + no sudo) ${src}"
    fi
  }

  # Items that STRICTLY need root (root-only files like pacman keyring,
  # /etc/shadow, or live `nft list ruleset`).  All other items go through
  # sudo_copy_one above which falls back to user-readable cp if possible.

  # Pacman keyring is root 700 by default
  if [ -d /etc/pacman.d/gnupg ]; then
    if [ "${SUDO_AVAILABLE}" = "1" ]; then
      sudo_run rsync -a --exclude='S.*' --exclude='*.lock' \
        /etc/pacman.d/gnupg/ \
        "${TS_DIR}/system-root/pacman-keyring/" 2>>"${LOG}" && \
        log "  -> /etc/pacman.d/gnupg (keyring, sudo)" || \
        log "  (pacman keyring copy failed)"
    else
      log "  (skipped /etc/pacman.d/gnupg — root-only + no sudo available)"
    fi
  fi

  # Live ruleset — must be captured as root to walk the namespace.
  if [ -x "$(command -v nft)" ]; then
    if [ "${SUDO_AVAILABLE}" = "1" ]; then
      sudo_run nft list ruleset \
        > "${TS_DIR}/system-root/nftables-current-ruleset.nft" \
        2>>"${LOG}" && \
        log "  -> /etc/nftables.conf + live ruleset" || \
        log "  (/etc/nftables.conf present but nft list ruleset failed)"
    else
      log "  (skipped live nft ruleset — requires sudo nft)"
    fi
  fi

  # systemctl list-unit-files — admin view; not strictly needed but useful
  if [ "${SUDO_AVAILABLE}" = "1" ] && [ -x "$(command -v systemctl)" ]; then
    sudo_run systemctl list-unit-files --type=service --no-pager \
      > "${TS_DIR}/system-root/systemd-unit-files.txt" 2>>"${LOG}" || \
      log "  (systemctl list-unit-files failed)"
  fi

  # Tailscale encrypted state metadata (root-only).  We do NOT touch
  # the state file itself; only stat-metadata.
  if [ -d /var/lib/tailscale ] && [ "${SUDO_AVAILABLE}" = "1" ]; then
    sudo_run sh -c '
      out="'"${TS_DIR}"'/system-root/tailscale-var"
      mkdir -p "$out"
      if [ -r /var/lib/tailscale/tailscaled.state ]; then
        stat -c "%n %s %Y" /var/lib/tailscale/tailscaled.state \
          > "$out/state-metadata.txt" 2>/dev/null
      fi
    ' 2>>"${LOG}" && \
      log "  -> /var/lib/tailscale (state metadata only)" || \
      log "  (/var/lib/tailscale not readable — skipping metadata)"
  fi

  # Now items that are usually world-readable but tracked here so the
  # restore step (system-root) has everything in one place:
  sudo_copy_one /etc/nftables.conf        "${TS_DIR}/system-root/nftables"
  [ -f /etc/nftables.conf ] && log "  -> /etc/nftables.conf"

  [ -f /etc/ssh/sshd_config ] && \
    sudo_copy_one /etc/ssh/sshd_config    "${TS_DIR}/system-root/ssh"
  if [ -d /etc/ssh/sshd_config.d ]; then
    mkdir -p "${TS_DIR}/system-root/ssh/sshd_config.d"
    for f in /etc/ssh/sshd_config.d/*; do
      [ -f "$f" ] || continue
      if [ -r "$f" ]; then
        cp -a "$f" "${TS_DIR}/system-root/ssh/sshd_config.d/" 2>>"${LOG}" || true
      elif [ "${SUDO_AVAILABLE}" = "1" ]; then
        sudo_run cp -a "$f" "${TS_DIR}/system-root/ssh/sshd_config.d/" 2>>"${LOG}" || true
      else
        log "  (skipped $f — needs sudo)"
      fi
    done
  fi
  [ -f /etc/ssh/ssh_config ] && \
    sudo_copy_one /etc/ssh/ssh_config      "${TS_DIR}/system-root/ssh"

  [ -f /etc/pacman.conf ] && \
    sudo_copy_one /etc/pacman.conf         "${TS_DIR}/system-root/"

  for f in fstab crypttab hostname hosts machine-id locale.gen; do
    if [ -f "/etc/${f}" ]; then
      sudo_copy_one "/etc/${f}" "${TS_DIR}/system-root/"
    fi
  done

  [ -f /usr/lib/systemd/system/tailscaled.service ] && \
    sudo_copy_one /usr/lib/systemd/system/tailscaled.service \
                  "${TS_DIR}/system-root/tailscaled-service"

  # Tight perms (root has just written potentially sensitive material)
  chmod -R u=rwX,g=,o= "${TS_DIR}/system-root/" 2>>"${LOG}" || true
  hash_label system-root
}

# Helper: refresh the sudo timestamp if requested + available.
sudo_keepalive() {
  if [ "${SUDO_AVAILABLE}" = "1" ] && [ "${PREAUTH_SUDO}" = "1" ]; then
    sudo -n -v 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# ~/.secrets — most API keys live here. This is typically a single sourceable
# shell file (export FOO=bar), but treat it as either a file OR a directory
# (defensive). Tight perms on the copy — credentials at rest should be 0600.
# ---------------------------------------------------------------------------

backup_secrets() {
  banner "~/.secrets (API keys + .env + .npmrc + tokens)"
  if [ -f ~/.secrets ]; then
    mkdir -p "${TS_DIR}/secrets"
    install -m 0600 -D ~/.secrets "${TS_DIR}/secrets/.secrets" 2>>"${LOG}" || \
      log "  (failed to copy ~/.secrets — manual check needed)"
    log "  -> ~/.secrets  (mode 0600)"
  elif [ -d ~/.secrets ]; then
    # User has ~/.secrets as a directory of credentials.
    mkdir -p "${TS_DIR}/secrets"
    rsync -a \
      --exclude='logs' \
      --exclude='cache' \
      --exclude='tmp' \
      --exclude='__pycache__' \
      --exclude='.venv' \
      --exclude='node_modules' \
      --exclude='*.pid' \
      --exclude='*.lock' \
      --exclude='*.swp' \
      ~/.secrets/ "${TS_DIR}/secrets/" 2>>"${LOG}" || true
    chmod -R u=rwX,g=,o= "${TS_DIR}/secrets/" 2>>"${LOG}" || true
    log "  -> ~/.secrets/  (perms: 0600 files / 0700 dirs)"
  else
    log "  (skipped) ~/.secrets — not present"
  fi
  hash_label secrets
}

backup_gemini_codex() {
  banner "Gemini / Codex CLI config (extras)"
  mkdir -p "${TS_DIR}/extras-agents"

  sync_one extras-gemini ~/.gemini 'cache' 'logs' 'node_modules' 'tmp'
  sync_one extras-codex  ~/.codex  'cache' 'logs' 'node_modules' 'tmp' 'sessions'

  # Other agent harnesses that ship with .env / mcp auth. Each harness has
  # different bloat — apply per-source excludes so we don't ship 274GB of
  # an agent's working directory just to preserve its 5MB of settings.
  #
  # The directory-traversal pattern is:
  #   "<src>" "<safe_name>" "<excludes...>"
  # where excludes are rsync --exclude patterns (no leading "./").
  log "  -> per-harness agent configs"

  # ~/.claude is already covered in full by backup_claude() above (with
  # proper excludes for i-gstack/node_modules, projects/, file-history/).
  # Don't re-walk it here — that would just double the disk cost.

  # ~/.agents: small skill registry — keep nearly everything.
  do_agent_dir extras-agents-skills  ~/.agents  'cache' 'logs' 'tmp' \
                                              'node_modules' '.venv' \
                                              '*.pid' '*.lock'

  # ~/.openclaw: huge agent workspace. Config surface is at the root;
  # workspace/, backups/, browser/ are scratch/recursive and must be skipped.
  do_agent_dir extras-openclaw  ~/.openclaw  'cache' 'logs' 'tmp' \
                                         'node_modules' '.venv' \
                                         '*.pid' '*.lock' \
                                         'workspace' 'backups' 'browser' \
                                         'media' 'delivery-queue'

  # Smaller harnesses — same shape, fewer excludes.
  for src_safe in \
      '~/.acpx|extras-acpx|cache|logs|tmp|node_modules|.venv' \
      '~/.gstack|extras-gstack|cache|logs|tmp|node_modules|.venv|__pycache__' \
      '~/.copilot|extras-copilot|cache|logs|tmp|node_modules|.venv' \
      '~/.pi|extras-pi|cache|logs|tmp|node_modules|.venv|sessions' \
      '~/.roo|extras-roo|cache|logs|tmp|node_modules|.venv' \
      '~/.cline|extras-cline|cache|logs|tmp|node_modules|.venv' \
      '~/.aider|extras-aider|cache|logs|tmp|node_modules|.venv' \
      '~/.opencode|extras-opencode|cache|logs|tmp|node_modules|.venv' ; do
    IFS='|' read -r src label excludes <<< "${src_safe}"
    do_agent_dir "${label}" "${src}" ${excludes}
  done

  hash_label extras-gemini
  hash_label extras-codex
  hash_label extras-agents
}

# ---------------------------------------------------------------------------
# ~/.mempalace — MemPalace data (SQLite + chromadb/HNSW + WAL)
#
# Layout in this user's box (~7.5 GB on disk):
#   palace/                       (~1.4 GB)  live chromadb backing store
#     chroma.sqlite3                          main vector index
#     <wing-uuid>/                            per-wing metadata
#     <wing-uuid>.drift-YYYYMMDD-HHMMSS/      automatic drift snapshots (cheap)
#   palace.snapshot.20260528_*     (~1.4 GB)  REGENERABLE — skip
#   palace.bak.2026*               (3 × ~1.4 GB) REGENERABLE — skip
#   palace.rebuilt-tiny-7000       (~227 MB)  REGENERABLE — skip
#   palace.pre-rebuild-20260707*   (~227 MB)  REGENERABLE — skip
#   palace.new                     (~122 MB)  REGENERABLE — skip
#   palace.backup                  (~84 MB)   REGENERABLE — skip
#   wal/                           (~5 MB)    WAL replay — KEEP
#   knowledge_graph.sqlite3*       (~200 KB)  current graph state — KEEP
#   chroma.sqlite3                 (~184 KB)  global chroma config — KEEP
#   tunnels.json, identity.txt,
#   config.json, rebuild*.json,
#   rebuild.pid, locks/,
#   .blob_seq_ids_migrated         — KEEP
#
# Live writers exist (mcp_server processes). To get a coherent snapshot we
# briefly suspend the chromadb client by snapshotting the SQLite files via
# `sqlite3 .backup` (which serialises on the writer mutex) and then take an
# rsync of the HNSW/palace/ tree while the client is idle. The hnsw/HNSW
# tree is only modified during mines; a 1-second pause during the rsync is
# negligible. We do NOT kill the servers — pausing is cleaner.
#
# Strategy (conservative):
#   1. Snapshot the live SQLite files with `sqlite3 .backup` (write-ahead log
#      is checkpointed inside the backup primitive).
#   2. Acquire ~/.mempalace/locks/rebuild.pid lock briefy to fence off any
#      concurrent `mempalace repair` running; release after rsync.
#   3. rsync ~/.mempalace → dest, with --exclude covering all regenerable
#      historic dirs AND `*/locks/*.pid` (transient).
#   4. sha256 the result.
# ---------------------------------------------------------------------------

backup_mempalace() {
  banner "~/.mempalace (live SQLite + chromadb/HNSW + WAL)"
  if [ ! -d ~/.mempalace ]; then
    log "  (skipped) ~/.mempalace — not present"
    return 0
  fi
  mkdir -p "${TS_DIR}/mempalace"

  # 1. Coherent snapshot of the live SQLite files using the .backup
  #    command. Falls back to file copy + sqlite3 wal2wal-checkpoint if
  #    .backup is unavailable (older sqlite3 builds).
  #
  #    IMPORTANT: this includes ALL chromadb SQLite files in the palace
  #    tree. Live writers (mcp_server) constantly checkpoint these — a
  #    plain rsync of a mid-checkpoint file can land as a zero-byte or
  #    page-torn copy (we've observed this for the 1.2 GB
  #    palace/chroma.sqlite3). Always use sqlite3 .backup for any *.sqlite3
  #    we touch.
  local sqlite_files=(chroma.sqlite3 knowledge_graph.sqlite3
                      palace/chroma.sqlite3)
  for sf in "${sqlite_files[@]}"; do
    local src="${HOME}/.mempalace/${sf}"
    [ -f "${src}" ] || continue
    local dst="${TS_DIR}/mempalace/${sf}"
    mkdir -p "$(dirname "${dst}")"
    # Try sqlite3 .backup first (atomic, WAL-coherent).
    if command -v sqlite3 >/dev/null && \
       sqlite3 "${src}" ".timeout 5000" \
               ".backup '${dst}'" 2>>"${LOG}"; then
      log "  -> ~/.mempalace/${sf}  (sqlite3 .backup, atomic)"
    else
      # Fallback: copy + force WAL replay + checkpoint. Requires briefly
      # turning off journal_mode during copy; if that fails (in-use), copy
      # files anyway and rely on a restore-time recovery script.
      rm -f "${dst}" "${dst}-wal" "${dst}-shm"
      install -m 0644 "${src}" "${dst}" 2>>"${LOG}" || \
        log "  (warning: copy of ${sf} failed)"
      for ext in -wal -shm; do
        [ -f "${src}${ext}" ] && \
          install -m 0644 "${src}${ext}" "${dst}${ext}" 2>>"${LOG}" || true
      done
      log "  -> ~/.mempalace/${sf}  (file copy + WAL pair, non-atomic)"
    fi
  done

  # 2. Acquire our own fence so we don't collide with a live `mempalace
  #    repair` rebuild mid-snapshot. We DON'T wait on it — if repair is
  #    actually running we should defer (it's the writer of record). We
  #    just record its presence.
  local repair_pid=""
  if [ -f ~/.mempalace/rebuild.pid ]; then
    repair_pid=$(cat ~/.mempalace/rebuild.pid 2>/dev/null || true)
    if [ -n "${repair_pid}" ] && kill -0 "${repair_pid}" 2>/dev/null; then
      log "  (note: mempalace repair is running as PID ${repair_pid} — snapshot is still safe to take; repair uses palace.new/, which we exclude)"
    fi
  fi

  # 3. rsync the rest: palace/ tree, WAL, configs. Exclude the regenerable
  #    historic dirs and the chromadb chroma.sqlite3 (we already snapshotted
  #    it above) to avoid the same file being both .backup-stamped AND
  #    rsync'd (which would leave us with the wrong one).
  log "  -> ~/.mempalace/ (rsync, excluding historic snapshots)"
  rsync -a \
    --exclude='chroma.sqlite3' \
    --exclude='knowledge_graph.sqlite3' \
    --exclude='knowledge_graph.sqlite3-wal' \
    --exclude='knowledge_graph.sqlite3-shm' \
    --exclude='palace/chroma.sqlite3' \
    --exclude='palace.snapshot.*' \
    --exclude='palace.bak.*' \
    --exclude='palace.rebuilt-*' \
    --exclude='palace.pre-rebuild-*' \
    --exclude='palace.new' \
    --exclude='palace.backup' \
    --exclude='palace/palace.snapshot.*' \
    --exclude='test-chroma2' \
    --exclude='test-chroma3' \
    --exclude='locks/*.lock' \
    --exclude='*.pid' \
    --exclude='*.swp' \
    ~/.mempalace/ "${TS_DIR}/mempalace/" 2>>"${LOG}" || \
      log "  (rsync warnings for ~/.mempalace)"
  chmod -R u=rwX,g=,o= "${TS_DIR}/mempalace/" 2>>"${LOG}" || true

  log "  Total state on disk (~1.5 GB after this, vs 7.5 GB before)."
  hash_label mempalace
}

# ============================================================================
# Tailscale (mesh VPN / SSH overlay network)
# ============================================================================
#
# What we back up (no root required):
#   tailscale/status.json      full mesh snapshot (peers, IPs, prefs, health)
#   tailscale/netcheck.txt     network diagnostic (DERP latency table)
#   tailscale/version.txt      daemon + client versions
#   tailscale/tailscaled.env   /etc/default/tailscaled (port, flags)
#   tailscale/RESTORE.md       recovery instructions (auth needs interaction)
#
# What we CAN'T back up without root:
#   /var/lib/tailscale/tailscaled.state  (root 700, holds encrypted node key).
#   Restore.sh MUST prompt the user to re-authenticate with a fresh pre-auth
#   key from https://login.tailscale.com/admin/settings/keys .
#
# The encrypted-state metadata capture (size/mtime/path hash) lives in the
# `system-root` label, where it has access to `sudo`.
#
backup_tailscale() {
  banner "Tailscale (mesh VPN — status snapshot only; node-key re-auth on restore)"
  if ! have tailscale; then
    log "  (skipped) tailscale CLI not found"
    return 0
  fi
  mkdir -p "${TS_DIR}/tailscale"

  # 1. JSON snapshot of the current state (peers, IPs, prefs, cert domains).
  log "  -> tailscale status --json"
  if tailscale status --json > "${TS_DIR}/tailscale/status.json" 2>>"${LOG}"; then
    log "     $(wc -c < ${TS_DIR}/tailscale/status.json) bytes, $(jq -r '.Peer | length // 0' "${TS_DIR}/tailscale/status.json" 2>/dev/null || echo '?') peers"
  else
    log "     (warning: tailscale status --json failed)"
  fi

  # 2. Network diagnostic (which DERP servers, latency, ports reachable).
  log "  -> tailscale netcheck"
  tailscale netcheck > "${TS_DIR}/tailscale/netcheck.txt" 2>>"${LOG}" || \
    log "     (warning: tailscale netcheck failed)"

  # 3. Version pinning
  log "  -> tailscale/version.txt"
  {
    echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "client:  $(tailscale version 2>/dev/null || echo unknown)"
    echo "package: $(pacman -Q tailscale 2>/dev/null || echo unknown)"
  } > "${TS_DIR}/tailscale/version.txt"

  # 4. Daemon env file (root-readable 644)
  log "  -> /etc/default/tailscaled"
  if [ -r /etc/default/tailscaled ]; then
    install -m 0644 -D /etc/default/tailscaled "${TS_DIR}/tailscale/tailscaled.env" 2>>"${LOG}"
  else
    log "     (warning: /etc/default/tailscaled not readable)"
  fi

  # 5. Recovery instructions — read this FIRST on restore.
  cat > "${TS_DIR}/tailscale/RESTORE.md" <<'EOF'
# Tailscale restore notes

## State this backup captures
- `status.json`        Full mesh snapshot — peer IPs, login name, cert domain,
                       BackendState, Health, User profile. Identity-only
                       information; **does NOT contain an auth key**.
- `netcheck.txt`       DERP server reachability + latency table.
- `version.txt`        Client + pacman version.
- `tailscaled.env`     /etc/default/tailscaled (port, FLAGS).

## State this backup CAN'T capture without sudo
- `/var/lib/tailscale/tailscaled.state`  — root-owned 700, holds the encrypted
  node key for this tailnet member. Restoring requires the user to re-auth.

## Restore sequence
1. `pacman -S tailscale`             # in package list
2. `sudo systemctl enable --now tailscaled`
3. Generate a fresh **pre-auth key** at
   https://login.tailscale.com/admin/settings/keys  (90-day reusable key
   with tag `tag:exit-node` if this box advertised exit-node routes).
4. `sudo tailscale up --accept-routes --accept-dns --authkey=tskey-xxx`
5. Re-apply any advertised routes/exit-node settings originally captured in
   `status.json` (look at "UserTags" / advertised preferences — at present
   the daemon only stores prefs internally; the JSON dump records defaults
   but not customisation).

## Auth recovery (manual)
If you can't re-auth via pre-auth key, log in interactively:
  sudo tailscale up               # prints https://login.tailscale.com/a/<url>
… then open the URL in any browser, sign in, the daemon gets the new node
key on its next poll.
EOF
  log "  -> RESTORE.md (recovery instructions)"

  # Lock down perms (auth keys may eventually appear in here)
  chmod -R u=rwX,g=,o= "${TS_DIR}/tailscale/" 2>>"${LOG}" || true

  hash_label tailscale
}

# Helper: rsync a single agent config dir with per-source excludes.
# Skips silently if the dir does not exist.
do_agent_dir() {
  local label="$1" src="$2"; shift 2
  local ex=()
  for p in "$@"; do ex+=(--exclude "$p"); done
  local safe=$(echo "${src}" | tr '/ ' '__')
  if [ ! -d "${src}" ]; then
    return 0
  fi
  mkdir -p "${TS_DIR}/extras-agents/${safe}"
  log "  -> ${src}"
  rsync -a "${ex[@]}" "${src}/" "${TS_DIR}/extras-agents/${safe}/" 2>>"${LOG}" || \
    log "  (rsync warnings for ${src})"
}

# ---------------------------------------------------------------------------
# Snapshot installed packages so restore.sh knows what to install
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Desktop & Shell configuration — 16 individually-restorable labels.
# Each label is its own top-level directory so the restore GUI can offer
# them as independent checkboxes under the "Desktop & Shell Config" category.
# ---------------------------------------------------------------------------

backup_desktop_config() {
  banner "Desktop & Shell Configuration (16 labels)"

  # 1. Shell dotfiles — individual files, not sync_one
  mkdir -p "${TS_DIR}/shell-dots"
  for f in .bashrc .bash_profile .profile .bash_aliases .p10k.zsh; do
    [ -f "${HOME}/${f}" ] && cp -a "${HOME}/${f}" "${TS_DIR}/shell-dots/" 2>>"${LOG}"
  done
  log "  -> shell dotfiles"
  hash_label shell-dots

  # 2. Hyprland config
  sync_one hyprland ~/.config/hypr
  hash_label hyprland

  # 3. illogical-impulse (theming framework)
  sync_one illogical-impulse ~/.config/illogical-impulse
  hash_label illogical-impulse

  # 4. Matugen + KDE color schemes
  sync_one matugen-colors ~/.config/matugen
  sync_one matugen-colors ~/.local/share/color-schemes
  hash_label matugen-colors

  # 5. KDE theming bundle — mix of files and dirs
  mkdir -p "${TS_DIR}/kde-theme"
  [ -d ~/.config/Kvantum ] && \
    rsync -a ~/.config/Kvantum/ "${TS_DIR}/kde-theme/Kvantum/" 2>>"${LOG}"
  [ -d ~/.config/wal ] && \
    rsync -a ~/.config/wal/ "${TS_DIR}/kde-theme/wal/" 2>>"${LOG}"
  [ -d ~/.config/kdedefaults ] && \
    rsync -a ~/.config/kdedefaults/ "${TS_DIR}/kde-theme/kdedefaults/" 2>>"${LOG}"
  for f in kdeglobals kwinrc kglobalshortcutsrc \
           plasma-org.kde.plasma.desktop-appletsrc; do
    [ -f ~/.config/"${f}" ] && \
      cp -a ~/.config/"${f}" "${TS_DIR}/kde-theme/" 2>>"${LOG}"
  done
  log "  -> KDE theming bundle"
  hash_label kde-theme

  # 6. GTK 3.0 + 4.0
  sync_one gtk-theme ~/.config/gtk-3.0
  sync_one gtk-theme ~/.config/gtk-4.0
  hash_label gtk-theme

  # 7. Custom .desktop files + mimeapps.list
  mkdir -p "${TS_DIR}/desktop-entries"
  sync_one desktop-entries ~/.local/share/applications
  [ -f ~/.config/mimeapps.list ] && \
    cp -a ~/.config/mimeapps.list "${TS_DIR}/desktop-entries/" 2>>"${LOG}"
  hash_label desktop-entries

  # 8. Git config + gh CLI auth
  sync_one git-config ~/.config/git
  sync_one git-config ~/.config/gh
  hash_label git-config

  # 9. mpv player config
  sync_one mpv ~/.config/mpv
  hash_label mpv

  # 10. MangoHud overlay
  sync_one mangohud ~/.config/MangoHud
  hash_label mangohud

  # 11. Gamescope / vkBasalt / cava
  sync_one gaming-overlays ~/.config/gamescope
  sync_one gaming-overlays ~/.config/vkBasalt
  sync_one gaming-overlays ~/.config/cava
  hash_label gaming-overlays

  # 12. Input remapper + libinput-gestures
  sync_one input-remapper ~/.config/input-remapper-2
  mkdir -p "${TS_DIR}/input-remapper"
  [ -f ~/.config/libinput-gestures.conf ] && \
    cp -a ~/.config/libinput-gestures.conf "${TS_DIR}/input-remapper/" 2>>"${LOG}"
  hash_label input-remapper

  # 13. Custom fonts
  sync_one fonts ~/.local/share/fonts
  hash_label fonts

  # 14. PulseAudio / PipeWire config
  sync_one audio-config ~/.config/pulse
  hash_label audio-config

  # 15. Klipper (clipboard history)
  sync_one klipper ~/.local/share/klipper
  hash_label klipper

  # 16. Yubico / YubiKey configs
  sync_one yubico ~/.config/Yubico
  sync_one yubico ~/.local/share/ykman
  sync_one yubico ~/.local/share/com.yubico.yubioath
  hash_label yubico
}

backup_package_state() {
  banner "Package state"
  mkdir -p "${TS_DIR}/packages"
  pacman -Qqen > "${TS_DIR}/packages/pacman-explicit.txt" 2>>"${LOG}"
  pacman -Qqem > "${TS_DIR}/packages/paru-foreign.txt"  2>>"${LOG}" || true
  pacman -Qqeq > "${TS_DIR}/packages/all-packages.txt"  2>>"${LOG}"
  pacman -Qqdt > "${TS_DIR}/packages/orphans.txt"         2>>"${LOG}" || true
  # AUR / built-from-source (paru -Qkam) skipped; restore.sh will pull
  # them from AUR if the names exist there.
  cat > "${TS_DIR}/packages/README.md" <<'EOF'
Restore-side `restore.sh` reads these files:

- pacman-explicit.txt   — packages installed via pacman (sync repos)
- paru-foreign.txt      — AUR / foreign-installed packages
- all-packages.txt      — every package on the system
- orphans.txt          — packages not required by any other (post-cleanup only)

Restore order:
  1. pacman -S --needed - < pacman-explicit.txt
  2. paru -S --needed --aur - < paru-foreign.txt
     (or use yay; restore.sh auto-detects)
EOF
  hash_label packages
}

# ---------------------------------------------------------------------------
# Manifest + summary
# ---------------------------------------------------------------------------

emit_manifest() {
  banner "Writing manifest"
  # Build a JSON manifest with sizes + SHA256 (slow: only for files < 32MB
  # to keep this bounded).
  local sz; local out="${MANIFEST}.tmp"
  : > "${out}"
  {
    printf '{\n'
    printf '  "timestamp": "%s",\n' "${DATE}"
    printf '  "host": "%s",\n' "${HOST}"
    printf '  "user": "%s",\n' "${USER}"
    printf '  "os": "%s",\n' "$(grep ^ID= /etc/os-release 2>/dev/null | cut -d= -f2 || echo unknown)"
    printf '  "labels": [\n'
    local first=1
    for d in */; do
      [ -d "${d}" ] || continue
      name="${d%/}"
      sizes=$(du -sh "${d}" 2>/dev/null | awk '{print $1}')
      # Use `-readable` to skip subtrees the unprivileged backup user
      # can't stat (e.g. NM/openvpn/pacman-keyring copies stored mode 0600).
      # Without this, `find` prints "Permission denied" to stderr (harmless)
      # but the manifest writer doesn't actually care — we just want the
      # file count, and we want it to keep moving even if some files are
      # hidden behind root perms.
      files=$(find "${d}" -type f -readable 2>/dev/null | wc -l)
      if [ $first -eq 0 ]; then printf ',\n'; fi
      first=0
      printf '    {"name": "%s", "size": "%s", "files": %s}' \
        "${name}" "${sizes}" "${files}"
    done
    printf '\n  ],\n'
    printf '  "totals": {\n'
    printf '    "size": "%s",\n' "$(du -sh . 2>/dev/null | awk '{print $1}')"
    printf '    "files": %s\n' "$(find . -type f -readable 2>/dev/null | wc -l)"
    printf '  }\n'
    printf '}\n'
  } > "${out}"
  mv "${out}" "${MANIFEST}"
  log "  manifest -> ${MANIFEST}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

banner "Backup started — $(date -u +%Y-%m-%dT%H:%M:%SZ) → ${TS_DIR}"

backup_hermes
backup_hermes_ui
backup_chromium
backup_zen
backup_dms
backup_telegram
backup_discord
backup_spotify
backup_inav
backup_kdeconnect
backup_claude
backup_antigravity
backup_cursor
backup_konsole
backup_heroic
backup_steam
backup_system_extras
backup_root_etc
backup_secrets
backup_gemini_codex
backup_mempalace
backup_tailscale
backup_desktop_config
backup_package_state

emit_manifest

banner "Summary"
{
  printf 'BACKUP DESTINATION : %s\n' "${TS_DIR}"
  printf 'TOTAL SIZE         : %s\n' "$(du -sh "${TS_DIR}" | awk '{print $1}')"
  printf 'FILE COUNT         : %s\n' "$(find "${TS_DIR}" -type f | wc -l)"
  printf 'CHECKSUM FILE      : %s\n' "${SHA_SUMS}"
  printf 'MANIFEST           : %s\n' "${MANIFEST}"
  printf 'LOG FILE           : %s\n' "${LOG}"
} | tee -a "${LOG}"

banner "Done — verify with: sha256sum -c ${SHA_SUMS}"
