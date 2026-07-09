#!/usr/bin/env bash
# ============================================================================
# restore.sh — Restore app state from a backup produced by backup.sh
#
# Usage:
#   restore.sh                                # interactive GUI wizard; latest backup
#   restore.sh /path/to/20260709T..._hostname # use a specific backup run
#   restore.sh --dry-run                       # show what would be done
#   restore.sh --apps hermes,zen,chrome        # limit to a comma list of apps
#   restore.sh --no-sudo                       # skip privileged /etc + /var/lib restore
#   restore.sh --askpass lib/askpass.sh        # alternative askpass helper
#
# Behaviour:
#   * For each app found in <BACKUP>/<app>/ exists:
#       1. If the app's main binary is missing, install via pacman/paru.
#       2. Restore config / tokens / keys from the backup onto $HOME.
#   * Preserves any existing config (--no-clobber via rsync).
#   * Requires sudo to install packages + restore /etc paths.
#     The first privileged operation triggers a GUI popup (zenity > yad >
#     kdialog) wired to sudo via SUDO_ASKPASS=lib/askpass.sh; subsequent
#     sudo calls reuse sudo's timestamp cache without re-prompting.
#
# After it runs the apps should be signed-in; verify with:
#       spotify --status; steam -background; telegram-desktop -autostart
# ============================================================================
set -euo pipefail

# Default backup root — same as backup.sh. Override with $BACKUP_ROOT.
BACKUP_ROOT="${BACKUP_ROOT:-/run/media/${USER}/Data/bakup}"
DRY_RUN=0
APP_FILTER=""
SELECTED=""
SKIP_SUDO=0

# Resolve script dir before arg parsing; --help/-h also uses it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --apps)        APP_FILTER="${2:-}"; shift 2 ;;
    --no-sudo)     SKIP_SUDO=1; shift ;;
    --askpass)     BAKUP_ASKPASS="${2:-}"; export BAKUP_ASKPASS; shift 2 ;;
    --help|-h)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  SELECTED="$1"; shift ;;
  esac
done

dry() { if [ "${DRY_RUN}" -eq 1 ]; then echo "[dry-run] $*"; else eval "$@"; fi; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# Sudo helper (askpass popup for privileged operations).
# ---------------------------------------------------------------------------
# shellcheck source=lib/sudo-helper.sh
. "${SCRIPT_DIR}/lib/sudo-helper.sh"
SUDO_AVAILABLE=0
if [ "${SKIP_SUDO}" = "1" ]; then
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
if [ "${DRY_RUN}" = "1" ] && [ "${SKIP_SUDO}" != "1" ]; then
  SUDO_AVAILABLE=1
fi

# Wrapper for sudo_run: in dry-run, *print* the command instead of running it.
# Without this, restore_label's `sudo` calls show up as `[dry-run] sudo …`
# via the `dry()` indirection only when the call site uses dry().  This shim
# makes `sudo_run` itself dry-run-aware.
if [ "${DRY_RUN}" = "1" ]; then
  sudo_run() { echo "[dry-run] sudo $*"; }
fi


# Pick the latest backup directory under $1 (a parent of multiple snapshot
# runs).  Filter to directories whose names look like a timestamp prefix
# ("YYYYMMDDTHHMMSSZ_..." or anything starting with a digit).  This avoids
# picking up neighbour dirs like `lib/`, `README.md`-files, or partial
# runs that don't follow the date convention.
auto_pick_latest_backup() {
  local root="$1"
  [ -d "${root}" ] || return 1
  local cur
  # `ls -1d` lists one entry per line; sort -r puts newest first.  The
  # first entry whose basename starts with a digit is the latest valid
  # backup.  Returns the absolute path with NO trailing slash.
  while IFS= read -r cur; do
    [ -z "${cur}" ] && continue
    local bn
    bn="$(basename "${cur%/}")"
    case "${bn}" in
      [0-9]*) printf '%s\n' "${cur%/}"; return 0 ;;
    esac
  done < <(ls -1d "${root}"/*/ 2>/dev/null | sort -r)
  return 1
}

# --- 1. resolve backup target -----------------------------------------------
if [ -n "${SELECTED}" ]; then
  BACKUP="${SELECTED}"
elif [ -z "${APP_FILTER}" ] && [ "${BAKUP_NO_WIZARD:-0}" != "1" ]; then
  # No --apps and no explicit backup path. Pop the wizard so the user
  # can choose what to restore.  The wizard itself decides GUI vs TTY mode
  # and falls back to the auto-latest backup if its first stage fails.
  # shellcheck source=lib/restore-gui.sh
  if [ -f "${SCRIPT_DIR}/lib/restore-gui.sh" ]; then
    . "${SCRIPT_DIR}/lib/restore-gui.sh"
    if ! run_wizard; then
      echo "Restore cancelled. Re-run with --apps <labels> to bypass." >&2
      exit 1
    fi
  else
    echo "wizard missing at ${SCRIPT_DIR}/lib/restore-gui.sh — falling back to auto-latest." >&2
    BACKUP="$(auto_pick_latest_backup "${BACKUP_ROOT}")" || {
      echo "ERROR: no backup root at ${BACKUP_ROOT}" >&2
      exit 1
    }
  fi
else
  BACKUP="$(auto_pick_latest_backup "${BACKUP_ROOT}")" || {
    echo "ERROR: no backup root at ${BACKUP_ROOT}" >&2
    exit 1
  }
fi
[ -d "${BACKUP}" ] || { echo "ERROR: backup ${BACKUP} not found" >&2; exit 1; }
log "Using backup: ${BACKUP}"

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
      # MemPalace lives in a venv (not on the default PATH) for many users.
      # Check explicit venv locations before falling back to PATH.  Override
      # via MEMPALACE_VENV env var if your install is elsewhere.
      mempalace_venv="${MEMPALACE_VENV:-${HOME}/.local/share/mempalace-venv}"
      [ -x "${HOME}/.openclaw/workspace/mempalace-venv/bin/mempalace" ] || \
        [ -x "${mempalace_venv}/bin/mempalace" ] || \
        [ -x "${HOME}/.local/share/mempalace-venv/bin/mempalace" ] || \
        have mempalace ;;

  *)
    have "$1"
    ;;
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

  # Try pacman first (sync repos).
  if have pacman; then
    log "  pacman -S --needed ${missing[*]}"
    dry "sudo pacman -S --needed --noconfirm ${missing[*]}" || \
      log "  pacman install failed for: ${missing[*]}"
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

# Restore one label from backup into the user's $HOME.  rsync -a puts files
# back in the original location.  --backup keeps any current files as
# *.bak-YYYYMMDD-HHMMSS so you can recover if you change your mind.
restore_label() {
  local label="$1"
  local src="${BACKUP}/${label}"
  [ -d "${src}" ] || { log "  (missing) ${label} — nothing to restore"; return; }
  log "  restore ${label}"
  case "${label}" in
    hermes-ui)
      # Recursive sub-folders already use absolute paths from HOME
      for sub in "${src}"/*/; do
        case "$(basename "${sub}")" in
          dot-hermes-ui)
            for f in "${sub}"/*; do
              dest="${HOME}/.hermes-ui/$(basename "${f}")"
              dry "install -m 600 -D \"${f}\" \"${dest}\""
            done ;;
          repo)
            for f in "${sub}"/*; do
              dest="${HOME}/hermes-ui/$(basename "${f}")"
              dry "install -m 600 -D \"${f}\" \"${dest}\""
            done ;;
        esac
      done ;;
    inav)
      # restore ~/.config/INAV Configurator (note space)
      if [ -d "${src}/INAVConfigurator" ]; then
        dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/INAVConfigurator/\" \"${HOME}/.config/INAV Configurator/\""
      fi ;;
    secrets)
      # ~/.secrets — credentials, restore with tight perms.
      # May be either a single file OR a directory; restore matches the source.
      if [ -d "${src}" ]; then
        dry "mkdir -p -m 0700 \"${HOME}/.secrets\""
        dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/\" \"${HOME}/.secrets/\""
        dry "chmod -R u=rwX,g=,o= \"${HOME}/.secrets/\""
        log "  -> ~/.secrets/ (directory, permissions tightened to 0600/0700)"
      else
        # Treat any file inside src/ as the candidate (single-file case uses
        # install -m 0600 -D ... .secrets, so the file lands at ".secrets").
        f="${src}/.secrets"
        if [ -f "${f}" ]; then
          dry "install -m 0600 -D \"${f}\" \"${HOME}/.secrets\""
          log "  -> ~/.secrets (file, mode 0600)"
        else
          log "  (no ~/.secrets file or directory found in backup — skipped)"
        fi
      fi ;;
    mempalace)
      # ~/.mempalace — MemPalace data (SQLite + chromadb/HNSW + WAL).
      # Restore semantics differ from a flat config dir because there are
      # live writers (mcp_server). Always make a backup of the current
      # state first, then stop mempalace mcp_server before replacing files,
      # then start mempalace again. If mempalace is not installed, just
      # copy files in and warn — user can install it later and `repair`.
      log "  backup current ~/.mempalace → .mempalace.bak-restore-<ts>"
      dry "cp -a ${HOME}/.mempalace ${HOME}/.mempalace.bak-restore-$(date +%Y%m%d-%H%M%S)"

      # Try to find mcp_server pids and stop them, gracefully. If mempalace
      # CLI is missing we skip the stop and warn — restore can still
      # proceed.
      if have_app mempalace; then
        log "  stopping mempalace mcp_server (graceful)"
        dry "mempalace daemon stop || true"
      else
        log "  (note: mempalace CLI not found — files copied anyway; stop mcp_server manually if live)"
      fi

      # rsync the tree back. The SQLite files were captured with
      # `sqlite3 .backup` (atomic), so just `cp` them over (not rsync, to
      # keep their atime/ctime simple). The rest of ~/.mempalace is rsync'd.
      log "  restoring ~/.mempalace/ from ${src}/"
      dry "mkdir -p -m 0700 ${HOME}/.mempalace"
      # SQLite files (atomic copies):
      [ -f "${src}/chroma.sqlite3" ] && \
        dry "install -m 0644 -D \"${src}/chroma.sqlite3\" \"${HOME}/.mempalace/chroma.sqlite3\""
      [ -f "${src}/knowledge_graph.sqlite3" ] && \
        dry "install -m 0644 -D \"${src}/knowledge_graph.sqlite3\" \"${HOME}/.mempalace/knowledge_graph.sqlite3\""
      [ -f "${src}/knowledge_graph.sqlite3-wal" ] && \
        dry "install -m 0644 -D \"${src}/knowledge_graph.sqlite3-wal\" \"${HOME}/.mempalace/knowledge_graph.sqlite3-wal\""
      [ -f "${src}/knowledge_graph.sqlite3-shm" ] && \
        dry "install -m 0644 -D \"${src}/knowledge_graph.sqlite3-shm\" \"${HOME}/.mempalace/knowledge_graph.sqlite3-shm\""
      # palace/chroma.sqlite3 — the BIG one (1.2+ GB). Often restored by
      # the natural `cp -a` of ~/.mempalace below, but we install it
      # last to guarantee it's the backup's version and not a partial
      # leftover.
      [ -f "${src}/palace/chroma.sqlite3" ] && \
        dry "install -m 0644 -D \"${src}/palace/chroma.sqlite3\" \"${HOME}/.mempalace/palace/chroma.sqlite3\""

      # Everything else (rsync; --backup keeps current versions as *.bak).
      # We also exclude all *.sqlite3 from rsync; each was installed above.
      dry "rsync -a --backup --suffix=.bak-restore-$(date +%Y%m%d-%H%M%S) --exclude='*.sqlite3*' \"${src}/\" \"${HOME}/.mempalace/\""

      # Restore perms
      dry "chmod -R u=rwX,g=,o= \"${HOME}/.mempalace/\""

      # Optionally run a repair status check
      if have_app mempalace; then
        log "  mempalace repair-status (read-only health check)"
        dry "mempalace repair-status" || true
      fi
      log "  -> ~/.mempalace restored (if mempalace was running, restart it manually)"
      ;;
    claude)
      # backup_claude rsyncs ~/.claude/ contents directly into <label>/
      # (no mangled subdirs).  Restore the whole tree back to ~/.claude/.
      log "  restoring ~/.claude/ from ${src}/"
      dry "mkdir -p \"${HOME}/.claude\""
      dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/\" \"${HOME}/.claude/\""
      # .claude.json was stored as a file inside the label dir
      if [ -f "${src}/.claude.json" ]; then
        dry "cp -a \"${src}/.claude.json\" \"${HOME}/.claude.json\""
      fi
      ;;
    chromium|zen|dms|telegram|discord|spotify|kdeconnect|antigravity|cursor|konsole|heroic)
      # One sub-attribute per real location — find and rsync each path that
      # mirrors an absolute path under $HOME.
      for sub in "${src}"/*/; do
        labelname=$(basename "${sub}")
        case "${label}:${labelname}" in
          # telegram restores the entire share tree
          telegram:TelegramDesktop)
            dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${sub}\" \"${HOME}/.local/share/TelegramDesktop/\""
            ;;
          telegram:AyuGramDesktop_tdata)
            dry "rsync -a --backup \"${sub}\" \"${HOME}/.local/share/AyuGramDesktop/tdata/\""
            ;;
          # antichamber: spike-pattern commit key
          telegram:flatpak-telegram)
            dry "rsync -a --backup \"${sub}\" \"${HOME}/.var/app/org.telegram.desktop/\""
            ;;
          discord:flatpak-discord)
            dry "rsync -a --backup \"${sub}\" \"${HOME}/.var/app/com.discordapp.Discord/\""
            ;;
          *)
            # Generic restore: unmangle the backup subdir name back to a
            # relative path under $HOME using restore_map_path.
            relpath="$(restore_map_path "${label}" "${sub}")"
            if [ -n "${relpath}" ]; then
              dest="${HOME}/${relpath}"
              dry "mkdir -p \"$(dirname "${dest}")\" && rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${sub}\" \"${dest}/\""
            else
              log "    (no restore rule for ${label}/${labelname} — skipped)"
            fi
            ;;
        esac
      done ;;
    steam)
      # Drop ~/.steam/registry.vdf etc back; restore Steam/config, userdata
      [ -d "${src}/dot-steam" ] && dry "rsync -a \"${src}/dot-steam/\" \"${HOME}/.steam/\""
      [ -d "${src}/SteamShare" ] && dry "rsync -a \"${src}/SteamShare/\" \"${HOME}/.local/share/Steam/\""
      ;;
    hermes)
      dry "rsync -a --backup --suffix=.bak-$(date +%Y%m%d-%H%M%S) \"${src}/\" \"${HOME}/.hermes/\""
      ;;
    packages)
      if [ -f "${src}/pacman-explicit.txt" ]; then
        log "  install pacman-explicit.txt"
        dry "xargs -a \"${src}/pacman-explicit.txt\" sudo pacman -S --needed --noconfirm"
      fi
      if [ -f "${src}/paru-foreign.txt" ] && [ -n "${aur_helper}" ]; then
        log "  install paru-foreign.txt via ${aur_helper}"
        dry "xargs -a \"${src}/paru-foreign.txt\" ${aur_helper} -S --needed --noconfirm"
      fi ;;
    tailscale)
      # Restore /etc/default/tailscaled (port, FLAGS) only — daemon
      # state in /var/lib/tailscale/tailscaled.state is root-only and
      # holds the encrypted node key. We can't carry that across installs,
      # so a fresh auth-key (or interactive login) is required.
      #
      # Flow (interactive / GUI path):
      #   1. install_pkgs "tailscale" (handled before restore_label)
      #   2. systemctl enable --now tailscaled
      #   3. restore /etc/default/tailscaled (if backup had it)
      #   4. If the wizard captured a key in $TAILSCALE_AUTHKEY_FILE, run
      #      `sudo tailscale up --authkey=tskey-...` automatically.  The
      #      keyfile is `shred -u`'d immediately after the call, leaving
      #      no copy in /tmp.
      #   5. Otherwise print the manual instructions and stop.
      log "  tailscale restore"
      if [ -f "${src}/tailscaled.env" ]; then
        if [ "${SUDO_AVAILABLE:-0}" = "1" ]; then
          sudo_run install -m 0644 -D "${src}/tailscaled.env" /etc/default/tailscaled
          sudo_run systemctl restart tailscaled
        else
          log "  (sudo unavailable — cannot install /etc/default/tailscaled)"
          dry "install -m 0644 -D \"${src}/tailscaled.env\" /etc/default/tailscaled"
        fi
      fi
      if [ "${SUDO_AVAILABLE:-0}" = "1" ]; then
        log "  enable + start tailscaled daemon"
        sudo_run systemctl enable --now tailscaled
      else
        log "  (sudo unavailable — skipping tailscaled daemon enable)"
        dry "sudo systemctl enable --now tailscaled"
      fi
      if [ -f "${src}/status.json" ]; then
        log "  captured mesh snapshot: ${src}/status.json ($(wc -c < "${src}/status.json") bytes)"
        # Quick summary
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
      # If wizard captured a tskey, use it. Then `shred -u` immediately.
      if [ -n "${TAILSCALE_AUTHKEY_FILE:-}" ] && [ -r "${TAILSCALE_AUTHKEY_FILE}" ]; then
        local tskey
        tskey="$(cat "${TAILSCALE_AUTHKEY_FILE}")"
        if [ -n "${tskey}" ] && [ "${SUDO_AVAILABLE:-0}" = "1" ]; then
          log "  -> running: sudo tailscale up --accept-routes --accept-dns --authkey=<captured>"
          sudo_run tailscale up --accept-routes --accept-dns --authkey="${tskey}" || \
            log "  (auth-key rejected; falling back to manual instructions below)"
        elif [ -n "${tskey}" ]; then
          log "  (sudo unavailable — cannot apply authkey automatically)"
          log "     captured key is in ${TAILSCALE_AUTHKEY_FILE} — apply manually with:"
          log "       sudo tailscale up --accept-routes --accept-dns --authkey=\$(cat ${TAILSCALE_AUTHKEY_FILE})"
        fi
        # Shred the file regardless (best-effort). Falls back to rm if
        # shred is not installed.
        if have shred; then
          shred -u "${TAILSCALE_AUTHKEY_FILE}" 2>/dev/null || rm -f "${TAILSCALE_AUTHKEY_FILE}"
        else
          rm -f "${TAILSCALE_AUTHKEY_FILE}"
        fi
        unset TAILSCALE_AUTHKEY_FILE
      else
        log "  ============================================================"
        log "   MANUAL STEP REQUIRED (no auth in backup):"
        log "     1. Get a pre-auth key from https://login.tailscale.com/admin/settings/keys"
        log "     2. sudo systemctl status tailscaled"
        log "     3. sudo tailscale up --accept-routes --accept-dns --authkey=tskey-..."
        log "  ============================================================"
      fi
      ;;
    system)
      restore_system_extras "${src}" ;;
    system-root)
      restore_system_root "${src}" ;;
    extras-gemini|extras-codex|extras-agents)
      for sub in "${src}"/*/; do
        relpath="$(restore_map_path "${label}" "${sub}")"
        [ -z "${relpath}" ] && continue
        dest="${HOME}/${relpath}"
        dry "mkdir -p \"$(dirname "${dest}")\" && rsync -a --backup \"${sub}\" \"${dest}/\""
      done ;;
    shell-dots)
      for f in "${src}"/*; do
        [ -f "${f}" ] || continue
        dry "cp -a --backup \"${f}\" \"${HOME}/$(basename "${f}")\""
      done ;;
    kde-theme)
      # Restore sub-dirs and individual files
      for sub in "${src}"/*/; do
        [ -d "${sub}" ] || continue
        relpath="$(restore_map_path "${label}" "${sub}")"
        [ -n "${relpath}" ] && dry "mkdir -p \"${HOME}/${relpath}\" && rsync -a --backup \"${sub}\" \"${HOME}/${relpath}/\""
      done
      for f in "${src}"/*.rc "${src}"/kdeglobals "${src}"/kwinrc                "${src}"/kglobalshortcutsrc                "${src}"/plasma-org.kde.plasma.desktop-appletsrc; do
        [ -f "${f}" ] || continue
        dry "cp -a --backup \"${f}\" \"${HOME}/.config/$(basename "${f}")\""
      done ;;
    git-config)
      for sub in "${src}"/*/; do
        [ -d "${sub}" ] || continue
        relpath="$(restore_map_path "${label}" "${sub}")"
        [ -n "${relpath}" ] && dry "mkdir -p \"${HOME}/${relpath}\" && rsync -a --backup \"${sub}\" \"${HOME}/${relpath}/\""
      done ;;
    *)
      # Generic sync_one labels: each sub-dir is a mangled absolute path.
      # Restore using restore_map_path to unmangle back to $HOME.
      for sub in "${src}"/*/; do
        [ -d "${sub}" ] || continue
        relpath="$(restore_map_path "${label}" "${sub}")"
        if [ -n "${relpath}" ]; then
          dest="${HOME}/${relpath}"
          dry "mkdir -p \"$(dirname \"${dest}\")\" && rsync -a --backup \"${sub}\" \"${dest}/\""
        else
          log "    (no restore rule for ${label}/$(basename "${sub}") — skipped)"
        fi
      done
      # Also restore individual files at label root (e.g. libinput-gestures.conf)
      for f in "${src}"/*; do
        [ -f "${f}" ] || continue
        fname="$(basename "${f}")"
        case "${label}:${fname}" in
          input-remapper:libinput-gestures.conf)
            dry "cp -a --backup \"${f}\" \"${HOME}/.config/${fname}\"" ;;
          desktop-entries:mimeapps.list)
            dry "cp -a --backup \"${f}\" \"${HOME}/.config/${fname}\"" ;;
        esac
      done
      ;;
  esac
}

# Map an in-backup label+subdir-name back to its real $HOME relative path.
#
# Sub-dir naming convention (from sync_one in backup.sh): absolute paths
# starting with "/" have it stripped, then every "/" replaced with "_".
# So /home/alice/.claude becomes "home_alice__claude".
#
# restore_map_path: given a label and a backup sub-dir name (the mangled
# directory created by backup.sh's sync_one / direct rsync), return the
# relative path under $HOME where the contents should be restored.
#
# Three backup mangling schemes exist in backup.sh:
#
#   1. sync_one (most labels): sed 's|^/||; s|/|_|g'
#      /home/<user>/.config/chromium → home_<user>_.config_chromium
#
#   2. antigravity: tr '/ ' '__'  (preserves leading slash as underscore)
#      /home/<user>/.antigravity-ide → _home_<user>_.antigravity-ide
#
#   3. Special literal names (no mangle):
#      claude: files rsync'd directly into <label>/
#      dms/quickshell: literal "quickshell"
#      konsole/dot-config: literal "dot-config"
#      telegram: TelegramDesktop / AyuGramDesktop_tdata / flatpak-telegram
#
# We handle (1) and (2) generically by stripping the user prefix and
# converting remaining underscores back to slashes.  (3) is handled by
# explicit case patterns.
#
# When the source backup was made on a user whose name no longer exists
# (e.g. you renamed the account), set $BACKUP_USER_MANGLE to the old
# mangled prefix (e.g. "home_olduser_").
restore_map_path() {
  local label="$1" sub="$2" name
  name="$(basename "${sub}")"

  # --- compute user prefix variants --------------------------------------
  local user
  user="${USER:-$(basename "${HOME}")}"
  if [ -z "${user}" ] || [ "${user}" = "home" ]; then
    user="$(basename "${HOME}")"
  fi
  local prefix_sync="home_${user}_"    # sync_one style (leading slash stripped)
  local prefix_tr="_home_${user}_"     # antigravity tr style (leading / → _)
  local prefix_alt="${BACKUP_USER_MANGLE:-}"  # renamed-account override

  # --- special literal names (scheme 3) ----------------------------------
  case "${label}:${name}" in
    # dms uses sync_one for the main dirs + literal "quickshell"
    dms:quickshell)
      echo ".local/state/quickshell"; return ;;
    # konsole uses sync_one for ~/.local/share/konsole + literal "dot-config"
    konsole:dot-config)
      echo ".config"; return ;;
    # telegram / steam / system / packages are handled by their own restore fns
    telegram:*|steam:*|system:*|packages:*)
      return ;;
    # discord flatpak (rare)
    discord:flatpak-discord)
      return ;;
  esac

  # --- generic unmangle (schemes 1 and 2) --------------------------------
  # Try stripping each known prefix, then convert underscores back to slashes.
  # The rest is the relative path under $HOME.
  local relpath=""
  local stripped=""
  for try_prefix in "${prefix_sync}" "${prefix_tr}" "${prefix_alt}"; do
    [ -z "${try_prefix}" ] && continue
    case "${name}" in
      "${try_prefix}"*)
        stripped="${name#${try_prefix}}"
        break ;;
    esac
  done

  if [ -n "${stripped}" ]; then
    # Convert underscores back to slashes.  Special case: a leading dot
    # component (e.g. ".config_chromium") starts with a literal dot that
    # sync_one preserved, so the underscore after it is a path separator.
    # Generic rule: replace ALL underscores with slashes, then prepend "/".
    # This gives e.g. ".config/chromium" → correct.
    # Edge: spaces were converted to underscores by antigravity's tr, so
    # "Antigravity IDE" → "Antigravity_IDE" → we can't distinguish _ from
    # space.  Handle the one known case explicitly below.
    relpath="$(echo "${stripped}" | sed 's|_|/|g')"
    # Fix known space-in-path cases:
    case "${relpath}" in
      */Antigravity/IDE) relpath="$(echo "${relpath}" | sed 's|/IDE$| IDE|')" ;;
    esac
    echo "${relpath}"
    return
  fi

  # --- fallback: no match, return nothing --------------------------------
  return
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

log ""
log "============================================================"
log " Restore plan"
log "============================================================"
log " backup    : ${BACKUP}"
log " dry-run   : ${DRY_RUN}"
log " filter    : ${APP_FILTER:-<all>}"
log " aur-helper: ${aur_helper:-none found}"
log ""

# Order matters: restore the package list FIRST so that binaries exist when
# individual app-restoration needs to invoke them.  Some apps don't need
# install (e.g. KDE connect pieces, Hermes UI is a pip pkg).

if should_run packages; then
  log "[0/15] packages"
  install_pkgs "$(cat "${BACKUP}/packages/pacman-explicit.txt" 2>/dev/null || true)"
fi

# --- per-app install+restore ---
app_installs=(
  # app_label : "pacman_pkg1 pkg2" "aur_pkg [optional]"
  "chrome|chromium|google-chrome|chromium discord telegram-desktop telegram-desktop-bin spotify spotify heroic inav-configurator inav-configurator-bin steam steam-native-runtime kdeconnect-cli"
)
# (simplification: install is done only if missing via the package file)

# Per-app install commands for things that may not be in pacman-explicit
# (AUR-only packages, Flatpak, etc.).
install_extra=(
  "antigravity:  inav-configurator-bin"
  "heroic:       heroic-gog-plugin heroic-gamemode heroic-launcher-bin"
  "zen:          zen-browser-bin"
  "ag:           antigravity-ide-bin"
)

declare -A install_pkgs_for_label=(
  ["chrome"]="chromium"
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
  ["chromium"]="chromium"
  ["mempalace"]=""  # pipx-installed; see install_pip_pkgs map below
  ["tailscale"]="tailscale"
)

# pipx / pip-installed Python CLIs. The label matches install_pkgs_for_label
# in `restore_label mempalace` flow, but pkg_install_pip handles the actual
# install via pipx (or python -m venv + pip fallback).
declare -A install_pip_pkgs_for_label=(
  ["mempalace"]="mempalace"
)

# Install a pip package. Prefer pipx (gives an isolated venv + PATH entry);
# fall back to python -m venv if pipx isn't present. Always best-effort:
# a missing tool here only loses the install side; data still restores.
install_pip_pkg() {
  local pkg="$1"
  # MemPalace lives in a venv location not on default PATH. Check there too.
  local have_pkg=0
  if have "$pkg"; then have_pkg=1
  elif [ "$pkg" = "mempalace" ]; then
    local mp_venv="${MEMPALACE_VENV:-${HOME}/.local/share/mempalace-venv}"
    for f in "${HOME}/.openclaw/workspace/mempalace-venv/bin/mempalace" \
             "${mp_venv}/bin/mempalace" \
             "${HOME}/.local/share/mempalace/bin/mempalace"; do
      [ -x "$f" ] && have_pkg=1 && break
    done
  fi
  if [ "$have_pkg" -eq 0 ]; then
    if have pipx; then
      log "  pipx install $pkg (no venv yet)"
      dry "pipx install $pkg" || log "  (pipx install failed; restore data anyway)"
    elif have pip; then
      # Best-effort: install into a user venv at ~/.local/share/$pkg-venv.
      # Skip on externally-managed systems where pip refuses.
      local venv="${HOME}/.local/share/${pkg}-venv"
      if [ ! -d "${venv}" ]; then
        dry "python3 -m venv ${venv}" || true
      fi
      dry "${venv}/bin/pip install --quiet $pkg" || \
        log "  (pip install $pkg failed; restore data anyway)"
      # Symlink the bin entry onto PATH so subsequent `have pkg` is true.
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
  ["shell-dots"]="Shell dotfiles (.bashrc, .profile)"
  ["hyprland"]="Hyprland config"
  ["illogical-impulse"]="illogical-impulse (theming framework)"
  ["matugen-colors"]="Matugen + color schemes"
  ["kde-theme"]="KDE theming bundle (Kvantum, kwinrc, shortcuts)"
  ["gtk-theme"]="GTK 3.0 + 4.0"
  ["desktop-entries"]="Custom .desktop files + MIME handlers"
  ["git-config"]="Git config + gh CLI auth"
  ["mpv"]="mpv player config"
  ["mangohud"]="MangoHud overlay"
  ["gaming-overlays"]="Gamescope / vkBasalt / cava"
  ["input-remapper"]="Input remapper + libinput gestures"
  ["fonts"]="Custom fonts"
  ["audio-config"]="PulseAudio / PipeWire config"
  ["klipper"]="Klipper (clipboard history)"
  ["yubico"]="Yubico / YubiKey configs"
)

for label in hermes hermes-ui chromium zen dms telegram discord spotify \
             inav kdeconnect claude antigravity cursor konsole heroic steam \
             system system-root secrets extras-gemini extras-codex extras-agents \
             mempalace tailscale \
             shell-dots hyprland illogical-impulse matugen-colors kde-theme \
             gtk-theme desktop-entries git-config mpv mangohud gaming-overlays \
             input-remapper fonts audio-config klipper yubico packages; do
  if [ -d "${BACKUP}/${label}" ] && should_run "${label}"; then
    log ""
    log "============================================================"
    log " ${label_friendly_name[$label]:-$label}"
    log "============================================================"
    log " backup at : ${BACKUP}/${label}"
    pkgs="${install_pkgs_for_label[$label]:-}"
    [ -n "${pkgs}" ] && install_pkgs "${pkgs}"
    pip_pkgs="${install_pip_pkgs_for_label[$label]:-}"
    [ -n "${pip_pkgs}" ] && install_pip_pkg "${pip_pkgs}"
    restore_label "${label}"
  fi
done

log ""
log "============================================================"
log " Restore complete"
log "============================================================"
log ""
log "Verify everything works:"
log "  pacman -Qqen | wc -l        # packages match backup count"
log "  sha256sum -c '${BACKUP}/SHA256SUMS'"
log "  systemctl --user status ${label}   # Hermes services should be running"
log ""
log "Apps that need a manual sign-in (because tokens may have expired):"
log "  Discord (force re-auth if WebToken expired): discord --autorestart"
log "  Tailscale (node-key not backed up — pre-auth key from login.tailscale.com):"
log "      sudo tailscale up --accept-routes --accept-dns --authkey=tskey-xxx"
log "  Some stores (EGS/Amazon) via Heroic may need re-auth"
log ""
