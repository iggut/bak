#!/usr/bin/env bash
# ============================================================================
# restore.sh — Restore app state from a backup produced by backup.sh
#
# Usage:
#   restore.sh                                # use latest complete backup under BACKUP_DEST
#   restore.sh /path/to/20260709T..._iggut    # use a specific backup run
#   restore.sh --dest PATH                    # backup root (or BACKUP_DEST env)
#   restore.sh --dry-run                       # show what would be done
#   restore.sh --apps hermes,zen,chromium      # limit to a comma list of apps
#   restore.sh --parts zen/bookmarks,extras-agents/openclaw
#   restore.sh --map extras-agents/openclaw=/tmp/openclaw-copy
#   restore.sh --no-sudo                       # skip privileged /etc + /var/lib restore
#   restore.sh --list-labels                   # print known labels (one per line)
#   restore.sh --list-parts [SNAPSHOT]         # JSON of partial restore parts
#
# Behaviour:
#   * For each selected app/label found in <BACKUP>/<app>/:
#       1. Detect missing packages (pacman -Q) and install them all via
#          pacman/paru *before* any file restore (see ensure_apps_installed).
#       2. Restore config / tokens / keys from the backup onto $HOME.
#   * Modern snapshots store HOME trees under <label>/home/<relpath>.
#   * Preserves any existing config (rsync --backup with timestamp suffix).
#   * Requires sudo to install packages + restore /etc paths.
#     The first privileged operation triggers a GUI popup (zenity > yad >
#     kdialog) wired to sudo via SUDO_ASKPASS=lib/askpass.sh; subsequent
#     sudo calls reuse sudo's timestamp cache without re-prompting.
#
# After it runs the apps should be signed-in; verify with:
#       spotify --status; steam -background; telegram-desktop -autostart
# ============================================================================
set -euo pipefail

BACKUP_ROOT="${BACKUP_DEST:-/run/media/iggut/Data/bakup}"
DRY_RUN=0
APP_FILTER=""
PARTS_FILTER=""
# DEST_MAP entries: part_id<TAB>dest_path  (one per line in the string)
DEST_MAP=""
SELECTED=""
SKIP_SUDO=0
LIST_PARTS=0

# Resolve script dir before arg parsing; --help/-h also uses it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PARTS_PY="${SCRIPT_DIR}/lib/restore_parts.py"

# Canonical label order (must stay aligned with backup.sh --list-labels).
ALL_LABELS=(
  hermes hermes-ui chromium zen dms telegram discord spotify
  inav kdeconnect claude antigravity cursor konsole heroic steam
  system system-root secrets extras-gemini extras-codex extras-agents
  mempalace tailscale packages
  shell-dots hyprland illogical-impulse matugen-colors kde-theme gtk-theme
  desktop-entries git-config mpv mangohud gaming-overlays input-remapper
  fonts audio-config klipper yubico nvim vscode terminals firefox keepassxc paru
)

usage() {
  cat <<'EOF'
Usage: restore.sh [SNAPSHOT] [--dest PATH] [--apps LIST] [--parts LIST]
                  [--map part=PATH] [--dry-run] [--no-sudo]
                  [--list-labels] [--list-parts]

Restores app state from a backup.sh snapshot. With no SNAPSHOT, picks the
newest complete snapshot under --dest / BACKUP_DEST.

  --parts LIST   Comma-separated part IDs (e.g. zen/bookmarks,extras-agents/openclaw).
                 When set, only those parts are restored (implies their labels).
  --map P=PATH   Override restore destination for part P (repeatable). Default is
                 the original location. For multi-file parts, PATH is a parent dir.
  --list-parts   Print JSON of available parts for SNAPSHOT (or latest).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --apps)        APP_FILTER="${2:-}"; shift 2 ;;
    --parts)
      [ $# -ge 2 ] && [ -n "$2" ] || { printf '%s\n' 'ERROR: --parts needs a list' >&2; exit 2; }
      PARTS_FILTER="$2"
      shift 2
      ;;
    --map)
      [ $# -ge 2 ] && [ -n "$2" ] || { printf '%s\n' 'ERROR: --map needs part=PATH' >&2; exit 2; }
      case "$2" in
        *=*) ;;
        *) printf '%s\n' 'ERROR: --map expects part=PATH' >&2; exit 2 ;;
      esac
      _map_part="${2%%=*}"
      _map_dest="${2#*=}"
      DEST_MAP="${DEST_MAP}${_map_part}"$'\t'"${_map_dest}"$'\n'
      shift 2
      ;;
    --dest)
      [ $# -ge 2 ] && [ -n "$2" ] || { printf '%s\n' 'ERROR: --dest needs a path' >&2; exit 2; }
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --no-sudo)     SKIP_SUDO=1; shift ;;
    --list-labels)
      printf '%s\n' "${ALL_LABELS[@]}"
      exit 0
      ;;
    --list-parts)  LIST_PARTS=1; shift ;;
    --help|-h)     usage; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)  SELECTED="$1"; shift ;;
  esac
done

dry() { if [ "${DRY_RUN}" -eq 1 ]; then echo "[dry-run] $*"; else eval "$@"; fi; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
progress() { printf 'PROGRESS label=%s status=%s\n' "$1" "$2"; }

# Pick newest snapshot that has .complete; fall back to newest dir.
pick_latest_snapshot() {
  local root="$1" best="" candidate
  for candidate in $(ls -1d "${root}"/*/ 2>/dev/null | sort -r | sed 's:/$::'); do
    if [ -f "${candidate}/.complete" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
    [ -z "${best}" ] && best="${candidate}"
  done
  printf '%s' "${best}"
}

# ---------------------------------------------------------------------------
# Sudo helper (askpass popup for privileged operations).
# ---------------------------------------------------------------------------
# shellcheck source=lib/sudo-helper.sh
. "${SCRIPT_DIR}/lib/sudo-helper.sh"
SUDO_AVAILABLE=0
if [ "${LIST_PARTS}" = "1" ]; then
  : # listing parts never needs sudo
elif [ "${SKIP_SUDO}" = "1" ]; then
  log "  (sudo skipped via --no-sudo; privileged restores will be skipped)"
elif [ "${DRY_RUN}" = "1" ]; then
  log "  (dry-run — sudo popup deferred; privileged steps will be printed, not run)"
elif sudo_init "${SCRIPT_DIR}/lib" 2>/dev/null; then
  SUDO_AVAILABLE=1
  log "  (sudo credentials cached; privileged restores enabled)"
fi
# In dry-run, we pretend sudo is available so that restore_label's
# `sudo <something>` calls render as `[dry-run] sudo <something>` and
# the user can inspect them; without this the system-root restore path
# would silently skip.
if [ "${DRY_RUN}" = "1" ] && [ "${SKIP_SUDO}" != "1" ] && [ "${LIST_PARTS}" != "1" ]; then
  SUDO_AVAILABLE=1
fi

# Wrapper for sudo_run: in dry-run, *print* the command instead of running it.
# Without this, restore_label's `sudo` calls show up as `[dry-run] sudo …`
# via the `dry()` indirection only when the call site uses dry().  This shim
# makes `sudo_run` itself dry-run-aware.
if [ "${DRY_RUN}" = "1" ]; then
  sudo_run() { echo "[dry-run] sudo $*"; }
fi


# --- 1. resolve backup target -----------------------------------------------
if [ -n "${SELECTED}" ]; then
  BACKUP="${SELECTED}"
elif [ -d "${BACKUP_ROOT}" ]; then
  BACKUP="$(pick_latest_snapshot "${BACKUP_ROOT}")"
else
  echo "ERROR: no backup root at ${BACKUP_ROOT}" >&2; exit 1
fi
[ -n "${BACKUP}" ] && [ -d "${BACKUP}" ] || { echo "ERROR: backup ${BACKUP:-<empty>} not found" >&2; exit 1; }

# Early exit for --list-parts (needs resolved SNAPSHOT; no log noise on stdout).
if [ "${LIST_PARTS}" = "1" ]; then
  if [ ! -f "${PARTS_PY}" ]; then
    echo "ERROR: ${PARTS_PY} missing" >&2
    exit 1
  fi
  label_args=()
  [ -n "${APP_FILTER}" ] && label_args=(--labels "${APP_FILTER}")
  exec python3 "${PARTS_PY}" list "${BACKUP}" "${label_args[@]}"
fi

log "Using backup: ${BACKUP}"
if [ ! -f "${BACKUP}/.complete" ]; then
  log "  (warning: snapshot has no .complete stamp — may be incomplete)"
fi

# --- 2. helpers --------------------------------------------------------------
have()    { command -v "$1" >/dev/null 2>&1; }
have_app() {
  case "$1" in
    chromium|zen|chrome)            have chromium zen google-chrome ;;
    steam|heroic|spotify|discord|telegram-desktop|inav-configurator|kdeconnect|clip)
                                       have "$1" ;;
    konsole)                        have konsole ;;
    claude)                         have claude ;;
    cursor)                         have cursor ;;
    mempalace)
      # MemPalace often lives in a venv not on PATH — check common locations.
      [ -x "${HOME}/.openclaw/workspace/mempalace-venv/bin/mempalace" ] || \
        [ -x "${HOME}/.local/share/mempalace-venv/bin/mempalace" ] || \
        [ -x "${HOME}/.local/share/mempalace/bin/mempalace" ] || \
        have mempalace ;;
    *)                              have "$1" ;;
  esac
}

# Pick an AUR helper, preferring paru (already on the system), else yay.
aur_helper="$(command -v paru || command -v yay || echo)"

# Install a list of packages via pacman, falling back to aur helper, then
# logging failures rather than aborting.
install_pkgs() {
  local pkgs="$1" missing=() tried=""
  for p in ${pkgs}; do
    if have pacman && ! pacman -Qq "${p}" >/dev/null 2>&1; then
      missing+=("${p}")
    fi
  done
  [ ${#missing[@]} -eq 0 ] && { log "  (already installed) ${pkgs}"; return; }

  # Try pacman first (sync repos). Use sudo_run so askpass works.
  if have pacman; then
    log "  pacman -S --needed ${missing[*]}"
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "[dry-run] sudo pacman -S --needed --noconfirm ${missing[*]}"
    else
      sudo_run pacman -S --needed --noconfirm ${missing[*]} || \
        log "  pacman install failed for: ${missing[*]}"
    fi
  fi
  # Anything still missing, try AUR helper
  if [ -n "${aur_helper}" ]; then
    local aur_missing=()
    for p in "${missing[@]}"; do
      pacman -Qq "${p}" >/dev/null 2>&1 || aur_missing+=("${p}")
    done
    if [ ${#aur_missing[@]} -gt 0 ]; then
      log "  ${aur_helper} -S --needed ${aur_missing[*]}"
      dry "${aur_helper} -S --needed --noconfirm ${aur_missing[*]}" || \
        log "  ${aur_helper} failed for: ${aur_missing[*]}"
    fi
  fi
}

# Restore <label>/home/ tree onto $HOME (modern backup layout).
restore_home_tree() {
  local src="$1"
  local home_src="${src}/home"
  local suffix=".bak-$(date +%Y%m%d-%H%M%S)"
  [ -d "${home_src}" ] || return 1
  log "  -> ${home_src}/ → \$HOME/"
  dry "rsync -a --backup --suffix=${suffix} \"${home_src}/\" \"${HOME}/\""
  return 0
}

# Look up an optional destination override for a part id.
map_dest_for() {
  local part_id="$1" line key val
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    key="${line%%$'\t'*}"
    val="${line#*$'\t'}"
    if [ "${key}" = "${part_id}" ]; then
      printf '%s' "${val}"
      return 0
    fi
  done <<EOF
${DEST_MAP}
EOF
  return 1
}

# Copy one source path onto dest with backup suffix. Uses sudo for /etc and /var.
restore_path_pair() {
  local src="$1" dest="$2"
  local suffix=".bak-$(date +%Y%m%d-%H%M%S)"
  local dest_dir need_sudo=0
  case "${dest}" in
    /etc/*|/var/*|/usr/*) need_sudo=1 ;;
  esac

  if [ ! -e "${src}" ]; then
    log "  (missing source) ${src}"
    return 1
  fi

  if [ -d "${src}" ] && [ ! -L "${src}" ]; then
    log "  -> ${src}/ → ${dest}/"
    if [ "${need_sudo}" = "1" ]; then
      if [ "${SUDO_AVAILABLE}" != "1" ]; then
        log "  (sudo unavailable — skipping ${dest})"
        return 1
      fi
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "[dry-run] sudo mkdir -p ${dest}"
        echo "[dry-run] sudo rsync -a --backup --suffix=${suffix} ${src}/ ${dest}/"
      else
        sudo_run mkdir -p "${dest}"
        sudo_run rsync -a --backup --suffix="${suffix}" "${src}/" "${dest}/"
      fi
    else
      dry "mkdir -p \"${dest}\" && rsync -a --backup --suffix=${suffix} \"${src}/\" \"${dest}/\""
    fi
  else
    dest_dir="$(dirname "${dest}")"
    log "  -> ${src} → ${dest}"
    if [ "${need_sudo}" = "1" ]; then
      if [ "${SUDO_AVAILABLE}" != "1" ]; then
        log "  (sudo unavailable — skipping ${dest})"
        return 1
      fi
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "[dry-run] sudo mkdir -p ${dest_dir}"
        echo "[dry-run] sudo install -D -m 0644 ${src} ${dest}"
      else
        sudo_run mkdir -p "${dest_dir}"
        # Preserve mode roughly via install; fall back to cp --backup
        sudo_run cp -a --backup=numbered "${src}" "${dest}" 2>/dev/null || \
          sudo_run install -D -m 0644 "${src}" "${dest}"
      fi
    else
      dry "mkdir -p \"${dest_dir}\" && rsync -a --backup --suffix=${suffix} \"${src}\" \"${dest}\""
    fi
  fi
}

# Restore one partial part via lib/restore_parts.py resolve.
restore_part() {
  local part_id="$1"
  local override="" pair src dest
  override="$(map_dest_for "${part_id}" || true)"

  # packages/* parts: reinstall from list files (unless pre-install already did).
  case "${part_id}" in
    packages/pacman-explicit|packages/paru-foreign)
      if [ "${PACKAGE_LISTS_DONE}" = "1" ]; then
        log "  (package lists already applied in pre-install phase)"
        return 0
      fi
      local list
      list="$(python3 "${PARTS_PY}" resolve "${BACKUP}" "${part_id}" \
        ${override:+--dest "${override}"} | awk -F'\t' 'NR==1{print $1}')"
      if [ -z "${list}" ] || [ ! -f "${list}" ]; then
        log "  (missing) ${part_id}"
        return 1
      fi
      if [ "${part_id}" = "packages/pacman-explicit" ]; then
        log "  install pacman-explicit.txt"
        if [ "${DRY_RUN}" -eq 1 ]; then
          echo "[dry-run] sudo pacman -S --needed --noconfirm < ${list}"
        else
          # shellcheck disable=SC2046
          sudo_run pacman -S --needed --noconfirm $(tr '\n' ' ' < "${list}") || \
            log "  pacman-explicit install had failures"
        fi
      else
        if [ -n "${aur_helper}" ]; then
          log "  install paru-foreign.txt via ${aur_helper}"
          dry "xargs -a \"${list}\" ${aur_helper} -S --needed --noconfirm"
        else
          log "  (no AUR helper — skip ${part_id})"
        fi
      fi
      return 0
      ;;
  esac

  log "  part ${part_id}${override:+ → ${override}}"
  while IFS=$'\t' read -r src dest; do
    [ -z "${src}" ] && continue
    restore_path_pair "${src}" "${dest}"
  done < <(
    if [ -n "${override}" ]; then
      python3 "${PARTS_PY}" resolve "${BACKUP}" "${part_id}" --dest "${override}"
    else
      python3 "${PARTS_PY}" resolve "${BACKUP}" "${part_id}"
    fi
  )
}

# Legacy fallback: map mangled subdir names from older snapshots.
restore_legacy_subs() {
  local label="$1" src="$2" sub labelname
  for sub in "${src}"/*/; do
    [ -d "${sub}" ] || continue
    labelname=$(basename "${sub}")
    [ "${labelname}" = "home" ] && continue
    case "${label}:${labelname}" in
      telegram:TelegramDesktop)
        dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${sub}\" \"${HOME}/.local/share/TelegramDesktop/\""
        ;;
      telegram:AyuGramDesktop_tdata)
        dry "rsync -a --backup \"${sub}\" \"${HOME}/.local/share/AyuGramDesktop/tdata/\""
        ;;
      telegram:flatpak-telegram)
        dry "rsync -a --backup \"${sub}\" \"${HOME}/.var/app/org.telegram.desktop/\""
        ;;
      discord:flatpak-discord)
        dry "rsync -a --backup \"${sub}\" \"${HOME}/.var/app/com.discordapp.Discord/\""
        ;;
      *)
        restore_map_path "${label}" "${sub}" \
          | while read -r relpath; do
            [ -z "${relpath}" ] && continue
            dest="${HOME}/${relpath}"
            dry "mkdir -p \"$(dirname "${dest}")\" && rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${sub}\" \"${dest}/\""
          done
        ;;
    esac
  done
}

# Restore one label from backup into the user's $HOME.  rsync -a puts files
# back in the original location.  --backup keeps any current files as
# *.bak-YYYYMMDD-HHMMSS so you can recover if you change your mind.
restore_label() {
  local label="$1"
  local src="${BACKUP}/${label}"
  [ -d "${src}" ] || { log "  (missing) ${label} — nothing to restore"; return; }
  log "  restore ${label}"
  case "${label}" in
    hermes-ui|chromium|zen|dms|discord|spotify|kdeconnect|claude|antigravity|cursor|konsole|heroic|extras-gemini|extras-codex|extras-agents|\
    shell-dots|hyprland|illogical-impulse|matugen-colors|kde-theme|gtk-theme|desktop-entries|git-config|\
    mpv|mangohud|gaming-overlays|input-remapper|fonts|audio-config|klipper|yubico|nvim|vscode|terminals|firefox|keepassxc|paru)
      if restore_home_tree "${src}"; then
        # Flatpak discord may still live beside home/ in some snapshots.
        [ -d "${src}/flatpak-discord" ] && \
          dry "rsync -a --backup \"${src}/flatpak-discord/\" \"${HOME}/.var/app/com.discordapp.Discord/\""
      else
        log "  (legacy layout — mangled path map)"
        restore_legacy_subs "${label}" "${src}"
      fi
      ;;
    telegram)
      # telegram uses custom subdirs (not home/), plus optional flatpak.
      if [ -d "${src}/TelegramDesktop" ]; then
        dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/TelegramDesktop/\" \"${HOME}/.local/share/TelegramDesktop/\""
      fi
      if [ -d "${src}/AyuGramDesktop_tdata" ]; then
        dry "rsync -a --backup \"${src}/AyuGramDesktop_tdata/\" \"${HOME}/.local/share/AyuGramDesktop/tdata/\""
      fi
      if [ -d "${src}/flatpak-telegram" ]; then
        dry "rsync -a --backup \"${src}/flatpak-telegram/\" \"${HOME}/.var/app/org.telegram.desktop/\""
      fi
      # Also accept modern home/ if present.
      restore_home_tree "${src}" || true
      ;;
    inav)
      if [ -d "${src}/INAVConfigurator" ]; then
        dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/INAVConfigurator/\" \"${HOME}/.config/INAV Configurator/\""
      fi
      restore_home_tree "${src}" || true
      ;;
    secrets)
      # Single-file form: secrets/.secrets → ~/.secrets
      if [ -f "${src}/.secrets" ] && [ ! -d "${src}/.secrets" ]; then
        # Directory of many files vs single credential file.
        # If only .secrets (+ maybe hashes) treat as file; if other entries, dir.
        local other
        other=$(find "${src}" -mindepth 1 -maxdepth 1 ! -name '.secrets' ! -name 'SHA256SUMS' 2>/dev/null | head -n1 || true)
        if [ -z "${other}" ]; then
          dry "install -m 0600 -D \"${src}/.secrets\" \"${HOME}/.secrets\""
          log "  -> ~/.secrets (file, mode 0600)"
        else
          dry "mkdir -p -m 0700 \"${HOME}/.secrets\""
          dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/\" \"${HOME}/.secrets/\""
          dry "chmod -R u=rwX,g=,o= \"${HOME}/.secrets/\""
          log "  -> ~/.secrets/ (directory, permissions tightened)"
        fi
      elif [ -d "${src}" ]; then
        dry "mkdir -p -m 0700 \"${HOME}/.secrets\""
        dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/\" \"${HOME}/.secrets/\""
        dry "chmod -R u=rwX,g=,o= \"${HOME}/.secrets/\""
        log "  -> ~/.secrets/ (directory, permissions tightened)"
      else
        log "  (no ~/.secrets file or directory found in backup — skipped)"
      fi
      ;;
    mempalace)
      log "  backup current ~/.mempalace → .mempalace.bak-restore-<ts>"
      if [ -e "${HOME}/.mempalace" ]; then
        dry "cp -a \"${HOME}/.mempalace\" \"${HOME}/.mempalace.bak-restore-$(date +%Y%m%d-%H%M%S)\""
      fi
      if have_app mempalace; then
        log "  stopping mempalace mcp_server (graceful)"
        dry "mempalace daemon stop || true"
      else
        log "  (note: mempalace CLI not found — files copied anyway; stop mcp_server manually if live)"
      fi
      log "  restoring ~/.mempalace/ from ${src}/"
      dry "mkdir -p -m 0700 \"${HOME}/.mempalace\""
      [ -f "${src}/chroma.sqlite3" ] && \
        dry "install -m 0644 -D \"${src}/chroma.sqlite3\" \"${HOME}/.mempalace/chroma.sqlite3\""
      [ -f "${src}/knowledge_graph.sqlite3" ] && \
        dry "install -m 0644 -D \"${src}/knowledge_graph.sqlite3\" \"${HOME}/.mempalace/knowledge_graph.sqlite3\""
      [ -f "${src}/knowledge_graph.sqlite3-wal" ] && \
        dry "install -m 0644 -D \"${src}/knowledge_graph.sqlite3-wal\" \"${HOME}/.mempalace/knowledge_graph.sqlite3-wal\""
      [ -f "${src}/knowledge_graph.sqlite3-shm" ] && \
        dry "install -m 0644 -D \"${src}/knowledge_graph.sqlite3-shm\" \"${HOME}/.mempalace/knowledge_graph.sqlite3-shm\""
      [ -f "${src}/palace/chroma.sqlite3" ] && \
        dry "install -m 0644 -D \"${src}/palace/chroma.sqlite3\" \"${HOME}/.mempalace/palace/chroma.sqlite3\""
      dry "rsync -a --backup --suffix=.bak-restore-$(date +%Y%m%d-%H%M%S) --exclude='*.sqlite3*' \"${src}/\" \"${HOME}/.mempalace/\""
      dry "chmod -R u=rwX,g=,o= \"${HOME}/.mempalace/\""
      if have_app mempalace; then
        log "  mempalace repair-status (read-only health check)"
        dry "mempalace repair-status" || true
      fi
      log "  -> ~/.mempalace restored (if mempalace was running, restart it manually)"
      ;;
    steam)
      [ -d "${src}/dot-steam" ] && dry "rsync -a \"${src}/dot-steam/\" \"${HOME}/.steam/\""
      [ -d "${src}/SteamShare" ] && dry "rsync -a \"${src}/SteamShare/\" \"${HOME}/.local/share/Steam/\""
      restore_home_tree "${src}" || true
      ;;
    hermes)
      dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/\" \"${HOME}/.hermes/\""
      ;;
    packages)
      if [ "${PACKAGE_LISTS_DONE}" = "1" ]; then
        log "  (package lists already applied in pre-install phase)"
      else
        install_package_lists
      fi
      ;;
    tailscale)
      log "  (tailscale restore is non-automatic — see RESTORE.md)"
      if [ -f "${src}/tailscaled.env" ]; then
        log "  -> /etc/default/tailscaled"
        if [ "${DRY_RUN}" -eq 1 ]; then
          echo "[dry-run] sudo install -m 0644 -D ${src}/tailscaled.env /etc/default/tailscaled"
          echo "[dry-run] sudo systemctl restart tailscaled"
        else
          sudo_run install -m 0644 -D "${src}/tailscaled.env" /etc/default/tailscaled
          sudo_run systemctl restart tailscaled
        fi
      fi
      log "  enable + start tailscaled daemon"
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "[dry-run] sudo systemctl enable --now tailscaled"
      else
        sudo_run systemctl enable --now tailscaled
      fi
      if [ -f "${src}/status.json" ]; then
        log "  captured mesh snapshot: ${src}/status.json ($(wc -c < "${src}/status.json") bytes)"
        if have jq; then
          local peers self_tailnet self_ips
          peers=$(jq -r '.Peer | length // 0' "${src}/status.json" 2>/dev/null || echo "?")
          self_tailnet=$(jq -r '.CurrentTailnet.Name // "?"' "${src}/status.json" 2>/dev/null || echo "?")
          self_ips=$(jq -r '.TailscaleIPs | join(",") // "?"' "${src}/status.json" 2>/dev/null || echo "?")
          log "    tailnet : ${self_tailnet}"
          log "    peers   : ${peers}"
          log "    node IPs: ${self_ips}"
        fi
      fi
      log "  ============================================================"
      log "   MANUAL STEP REQUIRED (no auth in backup):"
      log "     1. Get a pre-auth key from https://login.tailscale.com/admin/settings/keys"
      log "     2. sudo systemctl status tailscaled"
      log "     3. sudo tailscale up --accept-routes --accept-dns --authkey=tskey-xxx"
      log "  ============================================================"
      ;;
    system)
      restore_system_extras "${src}" ;;
    system-root)
      restore_system_root "${src}" ;;
    *)
      # Discovered apps (cfg-*) and any future home/-layout labels.
      if restore_home_tree "${src}"; then
        :
      else
        log "  no restore logic for label '${label}' (and no home/ tree)"
      fi
      ;;
  esac
}

# Map an in-backup label+subdir-name back to its real $HOME relative path.
# Used only for legacy (pre-home/) snapshots.
restore_map_path() {
  local label="$1" sub="$2" name; name="$(basename "${sub}")"
  case "${label}:${name}" in
    chromium:dot-cache_chromium)                echo ".cache/chromium" ;;
    chromium:dot-config_chromium)               echo ".config/chromium" ;;
    zen:dot-config_zen)                         echo ".config/zen" ;;
    zen:dot-cache_zen)                          echo ".cache/zen" ;;
    dms:dot-config_DankMaterialShell)           echo ".config/DankMaterialShell" ;;
    dms:dot-local_state_DankMaterialShell)      echo ".local/state/DankMaterialShell" ;;
    dms:quickshell)                             echo ".local/state/quickshell" ;;
    spotify:dot-config_spotify)                 echo ".config/spotify" ;;
    spotify:dot-local_state_spicetify)          echo ".local/state/spicetify" ;;
    spotify:dot-config_spicetify)               echo ".config/spicetify" ;;
    kdeconnect:dot-config_kdeconnect)           echo ".config/kdeconnect" ;;
    kdeconnect:dot-cache_kdeconnect.app)        echo ".cache/kdeconnect.app" ;;
    kdeconnect:dot-cache_kdeconnect.daemon)     echo ".cache/kdeconnect.daemon" ;;
    kdeconnect:dot-cache_kdeconnect.sms)        echo ".cache/kdeconnect.sms" ;;
    claude:__dot-claude.json)                   echo ".claude" ;;
    claude:_home_iggut__claude)                 echo ".claude" ;;
    claude:_home_iggut__claude.json)            echo ".claude.json" ;;
    claude:_home_iggut___claude)                echo ".claude" ;;
    antigravity:_home_iggut__antigravity)       echo ".antigravity" ;;
    antigravity:_home_iggut__antigravity-ide)   echo ".antigravity-ide" ;;
    antigravity:_home_iggut__config_Antigravity) echo ".config/Antigravity" ;;
    antigravity:_home_iggut__config_Antigravity_IDE) echo ".config/Antigravity IDE" ;;
    antigravity:_home_iggut__local_share_antigravity-ide) echo ".local/share/antigravity-ide" ;;
    cursor:dot-cursor)                          echo ".cursor" ;;
    cursor:dot-config_Cursor)                   echo ".config/Cursor" ;;
    konsole:dot-config)                         echo ".config" ;;
    konsole:dot-local_share_konsole)            echo ".local/share/konsole" ;;
    heroic:dot-config_heroic)                   echo ".config/heroic" ;;
    heroic:dot-local_state_Heroic)              echo ".local/state/Heroic" ;;
    discord:dot-config_discord)                 echo ".config/discord" ;;
    telegram:*|steam:*|system:*|packages:*)     :  ;;
    extras-gemini:dot-gemini)                   echo ".gemini" ;;
    extras-codex:dot-codex)                     echo ".codex" ;;
    extras-agents:dot-claude)                   echo ".claude" ;;
    extras-agents:dot-agents)                   echo ".agents" ;;
    extras-agents:dot-acpx)                     echo ".acpx" ;;
    extras-agents:dot-gstack)                   echo ".gstack" ;;
    extras-agents:dot-copilot)                  echo ".copilot" ;;
    extras-agents:dot-pi)                       echo ".pi" ;;
    extras-agents:dot-roo)                      echo ".roo" ;;
    extras-agents:dot-cline)                    echo ".cline" ;;
    extras-agents:dot-aider)                    echo ".aider" ;;
    extras-agents:dot-opencode)                 echo ".local/state/opencode" ;;
    extras-agents:dot-openclaw)                 echo ".openclaw" ;;
    hermes-ui:dot-hermes-ui)                    echo ".hermes-ui" ;;
    hermes-ui:repo)                             echo "hermes-ui" ;;
    *)                                           : ;;
  esac
}

restore_system_extras() {
  local src="$1"
  log "  restore system extras"
  if [ -d "${src}/ssh" ]; then
    dry "mkdir -p ${HOME}/.ssh && rsync -a --backup \"${src}/ssh/\" \"${HOME}/.ssh/\""
    dry "chmod 700 \"${HOME}/.ssh\""
    dry "find \"${HOME}/.ssh\" -type f -name 'id_*' -exec chmod 600 {} \;"
    dry "find \"${HOME}/.ssh\" -type f -name '*.pub' -exec chmod 644 {} \;"
  fi
  if [ -d "${src}/gnupg" ]; then
    dry "rsync -a --backup \"${src}/gnupg/\" \"${HOME}/.gnupg/\""
    dry "chmod 700 \"${HOME}/.gnupg\""
  fi
  if [ -d "${src}/nssdb" ]; then
    dry "rsync -a --backup \"${src}/nssdb/\" \"${HOME}/.pki/nssdb/\""
  fi
  if [ -d "${src}/keyrings" ]; then
    dry "rsync -a --backup \"${src}/keyrings/\" \"${HOME}/.local/share/keyrings/\""
  fi
  if [ -d "${src}/libaccounts-glib" ]; then
    dry "rsync -a --backup \"${src}/libaccounts-glib/\" \"${HOME}/.config/libaccounts-glib/\""
  fi
  if [ -d "${src}/NM-system-connections" ]; then
    if [ "${SUDO_AVAILABLE}" = "1" ]; then
      sudo_run rsync -a --backup "${src}/NM-system-connections/" "/etc/NetworkManager/system-connections/"
      sudo_run chmod 600 /etc/NetworkManager/system-connections/* || true
      sudo_run systemctl reload NetworkManager
    else
      log "  (sudo unavailable — skipping NM system connections restore)"
    fi
  fi
  if [ -d "${src}/openvpn-client" ]; then
    if [ "${SUDO_AVAILABLE}" = "1" ]; then
      sudo_run rsync -a --backup "${src}/openvpn-client/" "/etc/openvpn/client/"
    else
      log "  (sudo unavailable — skipping openvpn client restore)"
    fi
  fi
  if [ -d "${src}/systemd-user" ]; then
    dry "rsync -a --backup \"${src}/systemd-user/\" \"${HOME}/.config/systemd/user/\""
    dry "systemctl --user daemon-reload"
  fi
}

# ---------------------------------------------------------------------------
# Privileged restore of /etc + /var/lib items captured under <BACKUP>/system-root/
# Each item has its own dry/permission behavior; all are gated on SUDO_AVAILABLE.
# ---------------------------------------------------------------------------
restore_system_root() {
  local src="$1"
  if [ ! -d "${src}" ]; then return 0; fi

  log "  restore privileged system state (sudo)"
  if [ "${SUDO_AVAILABLE}" != "1" ]; then
    log "  (skipped — sudo credentials not available;"
    log "    re-run restore.sh interactively and authenticate the popup"
    log "    to apply /etc + /var/lib state)"
    return 0
  fi

  # Firewall
  if [ -f "${src}/nftables/nftables.conf" ] || [ -f "${src}/nftables.conf" ]; then
    local nf="${src}/nftables/nftables.conf"
    [ -f "${nf}" ] || nf="${src}/nftables.conf"
    sudo_run install -m 0644 -D "${nf}" /etc/nftables.conf
    log "    nftables.conf -> /etc/nftables.conf"
  fi
  if [ -f "${src}/nftables-current-ruleset.nft" ]; then
    log "    (live ruleset preserved as ${src}/nftables-current-ruleset.nft — re-apply with: sudo nft -f <file>)"
  fi

  # SSH server + client config
  if [ -d "${src}/ssh" ]; then
    [ -f "${src}/ssh/sshd_config" ] && \
      sudo_run install -m 0644 -D "${src}/ssh/sshd_config" /etc/ssh/sshd_config
    if [ -d "${src}/ssh/sshd_config.d" ]; then
      sudo_run mkdir -p /etc/ssh/sshd_config.d
      sudo_run rsync -a "${src}/ssh/sshd_config.d/" /etc/ssh/sshd_config.d/
    fi
    [ -f "${src}/ssh/ssh_config" ] && \
      sudo_run install -m 0644 -D "${src}/ssh/ssh_config" /etc/ssh/ssh_config
    log "    sshd_config + ssh_config restored (verify with: sudo sshd -t)"
  fi

  # Pacman keyring + pacman.conf
  if [ -d "${src}/pacman-keyring" ]; then
    sudo_run mkdir -p /etc/pacman.d/gnupg
    sudo_run rsync -a --backup "${src}/pacman-keyring/" /etc/pacman.d/gnupg/
    log "    pacman keyring restored (verify with: sudo pacman-key --list-keys)"
  fi
  [ -f "${src}/pacman.conf" ] && \
    sudo_run install -m 0644 -D "${src}/pacman.conf" /etc/pacman.conf

  # Single-file /etc/* restores (preserves existing file with .bak)
  for f in fstab crypttab hostname hosts machine-id locale.gen; do
    if [ -f "${src}/${f}" ]; then
      sudo_run cp -a --backup=numbered "${src}/${f}" "/etc/${f}"
    fi
  done

  # Tailscale unit file + /var/lib metadata (NOT the encrypted state itself)
  [ -f "${src}/tailscaled-service" ] && \
    sudo_run install -m 0644 -D \
      "${src}/tailscaled-service" /usr/lib/systemd/system/tailscaled.service
  if [ -d "${src}/tailscale-var" ]; then
    log "    (tailscale-var/ state metadata preserved; encrypted node-key still"
    log "     requires interactive 'sudo tailscale up --authkey=...' on restore)"
  fi

  # Snap list of enabled services (informational; the user manually re-enables)
  if [ -f "${src}/systemd-unit-files.txt" ]; then
    log "    (captured systemd unit list: ${src}/systemd-unit-files.txt)"
    log "     To re-enable a subset: sudo systemctl enable <service>.service"
  fi

  # End with a single verify pass on the sensitive configs
  if [ -x /usr/sbin/sshd ]; then
    if sudo_run sshd -t 2>/dev/null; then
      log "    sshd config validates OK"
    else
      log "    [WARNING] sshd config fails to validate — manual review needed"
    fi
  fi
}

# --- 3. Top-level orchestration --------------------------------------------

should_run() {
  [ -z "${APP_FILTER}" ] && return 0
  case ",${APP_FILTER}," in *",${1},"*) return 0 ;; *) return 1 ;; esac
}

# Default pacman/AUR packages for curated labels. Empty = settings-only
# (nothing to install) or handled specially (packages lists, pip).
declare -A install_pkgs_for_label=(
  ["chromium"]="chromium"
  ["zen"]="zen-browser-bin"
  ["telegram"]="telegram-desktop"
  ["discord"]="discord"
  ["spotify"]="spotify"
  ["steam"]="steam steam-native-runtime"
  ["heroic"]="heroic-gog-plugin heroic-gamemode heroic-launcher-bin"
  ["inav"]="inav-configurator-bin"
  ["kdeconnect"]="kdeconnect kio-extras"
  ["claude"]="claude-code"
  ["cursor"]="cursor-bin"
  ["konsole"]="konsole"
  ["antigravity"]="antigravity-ide-bin"
  ["tailscale"]="tailscale"
  ["mpv"]="mpv"
  ["mangohud"]="mangohud"
  ["input-remapper"]="input-remapper"
  ["nvim"]="neovim"
  ["firefox"]="firefox"
  ["keepassxc"]="keepassxc"
  ["paru"]="paru"
  ["git-config"]="git github-cli"
  ["yubico"]="yubikey-manager"
  ["matugen-colors"]="matugen-bin"
)

declare -A install_pip_pkgs_for_label=(
  ["mempalace"]="mempalace"
)

# True if backup has a modern home/ tree entry for this relative path.
_backup_has_home_path() {
  local label="$1" rel="$2"
  local base="${BACKUP}/${label}"
  if [ -e "${base}/home/${rel}" ] || [ -e "${base}/home/${rel#./}" ]; then
    return 0
  fi
  return 1
}

# Resolve packages to install for a label, preferring only apps that appear
# in the snapshot (e.g. don't install every terminal emulator).
pkgs_for_label() {
  local label="$1"
  local pkgs=()

  case "${label}" in
    packages|system|system-root|secrets|shell-dots|kde-theme|gtk-theme|\
    desktop-entries|fonts|audio-config|klipper|hermes|hermes-ui|dms|\
    extras-gemini|extras-codex|extras-agents|illogical-impulse|mempalace)
      # Settings-only, pip-only, or package-list label — no default pkgs here.
      printf ''
      return 0
      ;;
    terminals)
      _backup_has_home_path terminals ".config/alacritty" && pkgs+=(alacritty)
      _backup_has_home_path terminals ".config/kitty" && pkgs+=(kitty)
      _backup_has_home_path terminals ".config/foot" && pkgs+=(foot)
      _backup_has_home_path terminals ".config/ghostty" && pkgs+=(ghostty)
      _backup_has_home_path terminals ".config/wezterm" && pkgs+=(wezterm)
      # If snapshot has no recognizable trees, fall back to nothing (config-only restore).
      printf '%s' "${pkgs[*]}"
      return 0
      ;;
    hyprland)
      pkgs+=(hyprland)
      _backup_has_home_path hyprland ".config/waybar" && pkgs+=(waybar)
      _backup_has_home_path hyprland ".config/wlogout" && pkgs+=(wlogout)
      _backup_has_home_path hyprland ".config/wofi" && pkgs+=(wofi)
      _backup_has_home_path hyprland ".config/rofi" && pkgs+=(rofi)
      _backup_has_home_path hyprland ".config/fuzzel" && pkgs+=(fuzzel)
      printf '%s' "${pkgs[*]}"
      return 0
      ;;
    gaming-overlays)
      _backup_has_home_path gaming-overlays ".config/vkBasalt" && pkgs+=(vkbasalt)
      _backup_has_home_path gaming-overlays ".config/gamescope" && pkgs+=(gamescope)
      _backup_has_home_path gaming-overlays ".config/cava" && pkgs+=(cava)
      _backup_has_home_path gaming-overlays ".config/goverlay" && pkgs+=(goverlay)
      printf '%s' "${pkgs[*]}"
      return 0
      ;;
    vscode)
      # Arch/Chaotic typically ship `code` (MS) or `code-oss`.
      printf '%s' "code"
      return 0
      ;;
    *)
      printf '%s' "${install_pkgs_for_label[$label]:-}"
      return 0
      ;;
  esac
}

install_pip_pkg() {
  local pkg="$1"
  local have_pkg=0
  if have "$pkg"; then have_pkg=1
  elif [ "$pkg" = "mempalace" ]; then
    for f in "${HOME}/.openclaw/workspace/mempalace-venv/bin/mempalace" \
             "${HOME}/.local/share/mempalace-venv/bin/mempalace" \
             "${HOME}/.local/share/mempalace/bin/mempalace"; do
      [ -x "$f" ] && have_pkg=1 && break
    done
  fi
  if [ "$have_pkg" -eq 0 ]; then
    if have pipx; then
      log "  pipx install $pkg (no venv yet)"
      dry "pipx install $pkg" || log "  (pipx install failed; restore data anyway)"
    elif have pip; then
      local venv="${HOME}/.local/share/${pkg}-venv"
      if [ ! -d "${venv}" ]; then
        dry "python3 -m venv ${venv}" || true
      fi
      dry "${venv}/bin/pip install --quiet $pkg" || \
        log "  (pip install $pkg failed; restore data anyway)"
      if [ -x "${venv}/bin/${pkg}" ]; then
        dry "ln -sf ${venv}/bin/${pkg} ${HOME}/.local/bin/${pkg}"
      fi
    else
      log "  (no pipx / pip found — skipping pip install of $pkg)"
    fi
  else
    log "  (already installed) pip: $pkg"
  fi
}

# Install package lists from the packages/ label (pacman explicit + AUR foreign).
install_package_lists() {
  local src="${BACKUP}/packages"
  [ -d "${src}" ] || return 0
  if [ -f "${src}/pacman-explicit.txt" ]; then
    log "  install packages/pacman-explicit.txt"
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "[dry-run] sudo pacman -S --needed --noconfirm < ${src}/pacman-explicit.txt"
    else
      # shellcheck disable=SC2046
      sudo_run pacman -S --needed --noconfirm $(tr '\n' ' ' < "${src}/pacman-explicit.txt") || \
        log "  pacman-explicit install had failures"
    fi
  fi
  if [ -f "${src}/paru-foreign.txt" ] && [ -n "${aur_helper}" ]; then
    log "  install packages/paru-foreign.txt via ${aur_helper}"
    dry "xargs -a \"${src}/paru-foreign.txt\" ${aur_helper} -S --needed --noconfirm"
  elif [ -f "${src}/paru-foreign.txt" ]; then
    log "  (no AUR helper — skip paru-foreign.txt)"
  fi
  PACKAGE_LISTS_DONE=1
}

# Before any file restore: detect missing packages for selected labels and
# install them in one batch (plus optional full package lists).
PACKAGE_LISTS_DONE=0
ensure_apps_installed() {
  local -a labels=("$@")
  local label pkgs pip_pkgs
  local -a all_pkgs=()
  local -A seen_pkg=()
  local -a need_pip=()
  local want_package_lists=0
  local p

  log ""
  log "============================================================"
  log " Detect / install apps for selected restore targets"
  log "============================================================"
  progress "install-apps" start

  for label in "${labels[@]}"; do
    [ -z "${label}" ] && continue
    if [ "${label}" = "packages" ]; then
      want_package_lists=1
      continue
    fi
    [ -d "${BACKUP}/${label}" ] || continue

    pkgs="$(pkgs_for_label "${label}")"
    if [ -n "${pkgs}" ]; then
      log "  ${label}: need packages → ${pkgs}"
      for p in ${pkgs}; do
        if [ -z "${seen_pkg[$p]:-}" ]; then
          seen_pkg[$p]=1
          all_pkgs+=("${p}")
        fi
      done
    else
      log "  ${label}: no package mapping (settings-only or pip)"
    fi
    pip_pkgs="${install_pip_pkgs_for_label[$label]:-}"
    if [ -n "${pip_pkgs}" ]; then
      need_pip+=("${pip_pkgs}")
    fi
  done

  if [ "${want_package_lists}" -eq 1 ]; then
    log "  packages: reinstall from snapshot package lists"
    install_package_lists
  fi

  if [ ${#all_pkgs[@]} -gt 0 ]; then
    log "  installing missing packages (${#all_pkgs[@]} unique)…"
    install_pkgs "${all_pkgs[*]}"
  else
    log "  (no per-label packages to install)"
  fi

  for pip_pkgs in "${need_pip[@]+"${need_pip[@]}"}"; do
    [ -n "${pip_pkgs}" ] && install_pip_pkg "${pip_pkgs}"
  done

  progress "install-apps" done
  log ""
}

declare -A label_friendly_name=(
  ["hermes"]="Hermes Agent"
  ["hermes-ui"]="Hermes WebUI"
  ["chromium"]="Chromium"
  ["zen"]="Zen Browser"
  ["dms"]="DankMaterialShell"
  ["telegram"]="Telegram Desktop"
  ["discord"]="Discord"
  ["spotify"]="Spotify + Spicetify"
  ["inav"]="INAV Configurator"
  ["kdeconnect"]="KDE Connect"
  ["claude"]="Claude Code"
  ["antigravity"]="Antigravity IDE"
  ["cursor"]="Cursor"
  ["konsole"]="Konsole"
  ["heroic"]="Heroic Games Launcher"
  ["steam"]="Steam"
  ["system"]="System extras (ssh/gnupg/NM/VPN/keyrings)"
  ["system-root"]="Root-protected /etc + /var/lib (firewall, sshd, pacman keyring)"
  ["secrets"]="~/.secrets (API keys, .env, .npmrc, tokens)"
  ["extras-gemini"]="Gemini CLI (extra)"
  ["extras-codex"]="Codex CLI (extra)"
  ["extras-agents"]="Other agent harnesses (extra)"
  ["mempalace"]="MemPalace (memory palace — live SQLite + chromadb/HNSW + WAL)"
  ["tailscale"]="Tailscale (mesh VPN — status snapshot only, manual re-auth required)"
  ["packages"]="Package list"
)

log ""
log "============================================================"
log " Restore plan"
log "============================================================"
log " backup    : ${BACKUP}"
log " dry-run   : ${DRY_RUN}"
log " filter    : ${APP_FILTER:-<all>}"
log " parts     : ${PARTS_FILTER:-<full labels>}"
log " aur-helper: ${aur_helper:-none found}"
log ""

# Install missing apps for every selected label *before* any file restore.
# Settings-only labels are skipped; `packages` reinstalls from snapshot lists.

if [ -n "${PARTS_FILTER}" ]; then
  # Partial restore mode: only the selected parts (with optional dest overrides).
  if [ ! -f "${PARTS_PY}" ]; then
    echo "ERROR: ${PARTS_PY} missing — cannot resolve --parts" >&2
    exit 1
  fi
  IFS=',' read -ra _parts_arr <<< "${PARTS_FILTER}"
  declare -A _labels_seen=()
  _pre_labels=()
  for part_id in "${_parts_arr[@]}"; do
    part_id="${part_id## }"
    part_id="${part_id%% }"
    [ -z "${part_id}" ] && continue
    label="${part_id%%/*}"
    # Honour --apps as an additional filter when both are set.
    if [ -n "${APP_FILTER}" ] && ! should_run "${label}"; then
      continue
    fi
    if [ -z "${_labels_seen[$label]:-}" ]; then
      _labels_seen[$label]=1
      _pre_labels+=("${label}")
    fi
  done
  ensure_apps_installed "${_pre_labels[@]}"

  for part_id in "${_parts_arr[@]}"; do
    part_id="${part_id## }"
    part_id="${part_id%% }"
    [ -z "${part_id}" ] && continue
    label="${part_id%%/*}"
    if [ -n "${APP_FILTER}" ] && ! should_run "${label}"; then
      log "  (skip part ${part_id} — label filtered by --apps)"
      continue
    fi
    log ""
    log "============================================================"
    log " part ${part_id}"
    log "============================================================"
    progress "${part_id}" start
    restore_part "${part_id}"
    progress "${part_id}" done
  done
else
  _pre_labels=()
  for label in "${ALL_LABELS[@]}"; do
    if [ -d "${BACKUP}/${label}" ] && should_run "${label}"; then
      _pre_labels+=("${label}")
    fi
  done
  # Also scan for custom and cfg labels in the snapshot
  for d in "${BACKUP}"/*; do
    [ -d "${d}" ] || continue
    name="${d##*/}"
    case "${name}" in
      cfg-*|custom-*)
        if should_run "${name}"; then
          # Avoid duplicates
          found=0
          for _l in "${_pre_labels[@]+"${_pre_labels[@]}"}"; do
            [ "${_l}" = "${name}" ] && found=1 && break
          done
          [ "${found}" -eq 0 ] && _pre_labels+=("${name}")
        fi
        ;;
    esac
  done
  # --apps may also name dynamic cfg-* labels from the GUI discovery scan.
  if [ -n "${APP_FILTER}" ]; then
    IFS=',' read -ra _app_arr <<< "${APP_FILTER}"
    for label in "${_app_arr[@]}"; do
      label="${label## }"
      label="${label%% }"
      [ -z "${label}" ] && continue
      [ -d "${BACKUP}/${label}" ] || continue
      _found=0
      for _l in "${_pre_labels[@]+"${_pre_labels[@]}"}"; do
        [ "${_l}" = "${label}" ] && _found=1 && break
      done
      if [ "${_found}" -eq 0 ]; then
        _pre_labels+=("${label}")
      fi
    done
  fi

  ensure_apps_installed "${_pre_labels[@]}"

  for label in "${_pre_labels[@]+"${_pre_labels[@]}"}"; do
    log ""
    log "============================================================"
    log " ${label_friendly_name[$label]:-$label}"
    log "============================================================"
    log " backup at : ${BACKUP}/${label}"
    progress "${label}" start
    restore_label "${label}"
    progress "${label}" done
  done
fi

log ""
log "============================================================"
log " Restore complete"
log "============================================================"
log ""
log "Verify everything works:"
log "  pacman -Qqen | wc -l        # packages match backup count"
log "  sha256sum -c '${BACKUP}/SHA256SUMS'"
log ""
log "Apps that need a manual sign-in (because tokens may have expired):"
log "  Discord (force re-auth if WebToken expired): discord --autorestart"
log "  Tailscale (node-key not backed up — pre-auth key from login.tailscale.com):"
log "      sudo tailscale up --accept-routes --accept-dns --authkey=tskey-xxx"
log "  Some stores (EGS/Amazon) via Heroic may need re-auth"
log ""
