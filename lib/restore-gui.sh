#!/usr/bin/env bash
# ============================================================================
# restore-gui.sh — interactive restore wizard (popup-driven)
# ============================================================================
#
# Sourced by restore.sh when invoked without --apps (i.e. user wants the
# wizard).  Walks the user through 4 popups and exits with the resulting
# APP_FILTER / TAILSCALE_AUTHKEY_FILE set in env.
#
# Stages:
#   1. Pick a backup run from ${BACKUP_ROOT}/<date>_<host>/
#   2. Pick category groups (10 umbrella categories)
#   3. (For each selected category with >1 label) per-label drilldown.
#      Tailscale shows an entry field for the auth-key.
#   4. Confirm summary, mode (live / dry-run / preview), sudo.
#
# Falls back to a TTY-driven version of the same flow when no GUI is
# available (cron, SSH, broken DISPLAY).  Set BAKUP_NO_GUI=1 to force TTY.
#
# After success, the wizard emits to stdout nothing, but sets:
#   BACKUP=<chosen backup path>
#   APP_FILTER="<comma-separated selected labels>"
#   TAILSCALE_AUTHKEY_FILE="/tmp/bakup-tskey-XXXX"   # only if user provided
# All other restore.sh state (BACKUP_ROOT, DRY_RUN, SKIP_SUDO) is preserved.
# ============================================================================

# Detect GUI capability. We require zenity (preferred) but fall back to
# yad → kdialog.  X11/Wayland display env is taken from auto_resolve_gui_env
# in askpass.sh if the user used the askpass path.  We re-detect here in
# case the wizard is invoked standalone (no askpass priming needed yet).
_gui_env_setup() {
  # Already set — nothing to do.
  [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
  [ -n "${DISPLAY:-}" ] && return 0

  # XDG_RUNTIME_DIR — usually /run/user/<UID> for a login user.
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
  fi

  # Wayland detection
  if [ -n "${XDG_RUNTIME_DIR}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
    local sock
    for sock in "${XDG_RUNTIME_DIR}"/wayland-*; do
      [ -S "$sock" ] || continue
      WAYLAND_DISPLAY="${sock##*/}"
      export WAYLAND_DISPLAY
      break
    done
  fi

  # Fallback to X
  if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
    local x
    for x in /tmp/.X11-unix/X*; do
      [ -S "$x" ] || continue
      DISPLAY=":$(printf '%s' "${x##*/X}").0"
      export DISPLAY
      break
    done
  fi
  return 0
}

_gui_has_display() {
  [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
  [ -n "${DISPLAY:-}" ] && return 0
  return 1
}

_gui_pick_dialog() {
  # Prefer zenity (common on GNOME, also installed standalone). Fall back
  # to yad, then kdialog.
  if command -v zenity >/dev/null 2>&1; then echo "zenity"; return; fi
  if command -v yad    >/dev/null 2>&1; then echo "yad";    return; fi
  if command -v kdialog >/dev/null 2>&1; then echo "kdialog"; return; fi
  echo ""
}

# ============================================================================
# GUI MODE — 4 popups
# ============================================================================

# Each category is a tuple: (group_id, "Friendly label", "default-state",
# "1-line description", "list of underlying labels").
CATEGORIES=(
  "hermes-bundle:Hermes (agent + WebUI):on:Hermes Agent auth + WebUI service + skills/plugins"
  "browsers:Browsers:on:Chromium + Zen profiles"
  "chat:Chat & Social:on:Telegram + Discord + KDE Connect (certs)"
  "media-gaming:Media & Gaming:on:Spotify + Steam login + Heroic + INAV"
  "code-ides:Code IDEs:on:Cursor + Antigravity + Claude Code configs"
  "shell-term:Shell & Terminal:off:Konsole + DMS (DankMaterialShell + Quickshell)"
  "system-secrets:System & Secrets:on:ssh + gnupg + NM + VPN + /etc + ~/.secrets"
  "memory-network:Memory & Network:on:MemPalace (live SQLite) + Tailscale status"
  "agents-extras:Agent extras:on:Gemini/Codex/Claude/ECC plugin configs"
  "desktop-shell:Desktop & Shell Config:off:Shell dotfiles, Hyprland, theming, fonts, YubiKey, etc."
  "packages:Packages:on:Re-install pacman + AUR list"
)

# Map category-id -> space-separated list of labels.
declare -A CATEGORY_LABELS=(
  ["hermes-bundle"]="hermes hermes-ui"
  ["browsers"]="chromium zen"
  ["chat"]="telegram discord kdeconnect"
  ["media-gaming"]="spotify steam heroic inav"
  ["code-ides"]="cursor antigravity claude"
  ["shell-term"]="konsole dms"
  ["system-secrets"]="system system-root secrets"
  ["memory-network"]="mempalace tailscale"
  ["agents-extras"]="extras-gemini extras-codex extras-agents"
  ["desktop-shell"]="shell-dots hyprland illogical-impulse matugen-colors kde-theme gtk-theme desktop-entries git-config mpv mangohud gaming-overlays input-remapper fonts audio-config klipper yubico"
  ["packages"]="packages"
)

# Per-label friendly name fallback (used in drilldown).
declare -A LABEL_NAME=(
  ["hermes"]="Hermes Agent"
  ["hermes-ui"]="Hermes WebUI"
  ["chromium"]="Chromium"
  ["zen"]="Zen"
  ["dms"]="DankMaterialShell"
  ["telegram"]="Telegram"
  ["discord"]="Discord"
  ["spotify"]="Spotify"
  ["inav"]="INAV Configurator"
  ["kdeconnect"]="KDE Connect"
  ["claude"]="Claude Code"
  ["antigravity"]="Antigravity IDE"
  ["cursor"]="Cursor"
  ["konsole"]="Konsole"
  ["heroic"]="Heroic"
  ["steam"]="Steam (login only)"
  ["system"]="System extras"
  ["system-root"]="Root /etc + /var/lib"
  ["secrets"]="~/.secrets"
  ["extras-gemini"]="Gemini CLI"
  ["extras-codex"]="Codex CLI"
  ["extras-agents"]="Other agent harnesses"
  ["mempalace"]="MemPalace"
  ["tailscale"]="Tailscale (needs re-auth)"
  ["packages"]="Package list (reinstall)"
  ["shell-dots"]="Shell dotfiles (.bashrc, .profile)"
  ["hyprland"]="Hyprland config"
  ["illogical-impulse"]="illogical-impulse (theming)"
  ["matugen-colors"]="Matugen + color schemes"
  ["kde-theme"]="KDE theming bundle"
  ["gtk-theme"]="GTK 3.0 + 4.0"
  ["desktop-entries"]="Custom .desktop + MIME"
  ["git-config"]="Git config + gh CLI"
  ["mpv"]="mpv player"
  ["mangohud"]="MangoHud overlay"
  ["gaming-overlays"]="Gamescope / vkBasalt / cava"
  ["input-remapper"]="Input remapper + gestures"
  ["fonts"]="Custom fonts"
  ["audio-config"]="PulseAudio / PipeWire"
  ["klipper"]="Klipper (clipboard history)"
  ["yubico"]="Yubico / YubiKey"
)

# Stage 1 — backup picker.
# Returns chosen path on stdout.
_gui_stage1_pick_backup() {
  local dialog="$1" backup_root="$2"
  local -a options=()
  local -a paths=()
  local dir
  # Sort newest first (reverse ls). Cap at 50 most recent.
  while IFS= read -r dir; do
    [ -z "${dir}" ] && continue
    [ "${#paths[@]}" -ge 50 ] && break
    local name
    name="$(basename "${dir}")"
    # Compose label: "<name> (~<size>)"
    local sz=""
    if command -v du >/dev/null 2>&1; then
      sz="$(du -sh -- "${dir}" 2>/dev/null | awk '{print $1}')"
    fi
    options+=("$(printf '%s\t%s' "${name}" "${sz:-?size}")")
    paths+=("${dir}")
  done < <(ls -1d "${backup_root}"/*/ 2>/dev/null | sort -r)
  if [ "${#paths[@]}" -eq 0 ]; then
    if [ "${dialog}" = "zenity" ]; then
      zenity --error --title="bakup — restore" \
        --text="No backups found at ${backup_root}.\n\nMount the backup drive, then re-run." \
        2>/dev/null || true
    fi
    return 1
  fi
  # Default to index 0 (newest).
  local picked
  case "${dialog}" in
    zenity)
      # --list shows rows as "col1 col2 col3 ...". Radio mode (no checklist).
      # Each row is one option; the value printed is its name (so user can
      # see what's selected).
      local csv=""
      local i=0
      for o in "${options[@]}"; do
        [ "${i}" -gt 0 ] && csv+="\n${o}"
        [ "${i}" -eq 0 ] && csv+="${o}"
        i=$((i+1))
      done
      picked=$(printf '%s\n' "${csv}" | zenity --list \
        --title="bakup — step 1/4: choose a backup" \
        --text="Which backup run to restore from?\n(${backup_root})" \
        --column="Backup run" --column="Size" \
        --radiolist --separator="|" \
        --hide-column=1 \
        2>/dev/null) || return 1
      ;;
    *)
      # zenity is the only tool installed in all tested environments;
      # others (yad / kdialog) are exercised separately. For now we fail
      # gracefully to TTY mode if zenity is missing.
      return 1
      ;;
  esac
  # Translate chosen name back to full path. (hide-column=1 means picked
  # is the row label, not the path.)
  local n="${picked%%|*}"
  for i in "${!paths[@]}"; do
    if [ "$(basename "${paths[$i]}")" = "${n}" ]; then
      printf '%s\n' "${paths[$i]}"
      return 0
    fi
  done
  return 1
}

# Stage 2 — category checklist.
# GUI dialog. Emits space-separated category IDs to stdout.
_gui_stage2_pick_categories() {
  local dialog="$1"
  local -a categories=( "${CATEGORIES[@]}" )
  # Build CSV: "default-state<TAB>label<TAB>description" for zenity list.
  # zenity --list with --checklist: column order is
  #   bool-state, label, [extra columns...]
  local csv=""
  local i=0
  for cat in "${categories[@]}"; do
    IFS=: read -r cid name def desc <<< "${cat}"
    if [ "${i}" -gt 0 ]; then csv+="\n"; fi
    csv+="${def}	${name}	${desc}"
    i=$((i+1))
  done
  local picked
  picked=$(printf '%s\n' "${csv}" | zenity --list \
    --title="bakup — step 2/4: pick categories" \
    --text="Toggle the categories of state to restore.\n(Defaults match what you'd want for a fresh restore.)" \
    --column="Pick" --column="Category" --column="What it covers" \
    --checklist --separator="|" \
    --width=720 --height=440 \
    2>/dev/null) || return 1
  # "picked" looks like "Hermes (agent + WebUI)|Browsers|Chat & Social".
  # Translate each display name back to a category id by lookup.
  local selected=""
  IFS='|'
  local seg
  for seg in ${picked}; do
    for cat in "${categories[@]}"; do
      IFS=: read -r cid name def desc <<< "${cat}"
      if [ "${name}" = "${seg}" ]; then
        if [ -z "${selected}" ]; then selected="${cid}"; else selected+=" ${cid}"; fi
        break
      fi
    done
  done
  IFS=$' \t\n'
  printf '%s\n' "${selected}"
}

# Stage 3 — per-label drilldown.
# Inputs: space-separated category IDs selected.
# Outputs: comma-separated label list.
_gui_stage3_per_label() {
  local dialog="$1"
  shift
  local -a selected_cats=( "$@" )
  local -a rows=()
  local saw_tailscale=0
  for cat in "${selected_cats[@]}"; do
    local labels="${CATEGORY_LABELS[$cat]:-}"
    for lab in ${labels}; do
      # Skip labels not in the backup at all (avoid noise)
      if [ ! -d "${BACKUP}/${lab}" ]; then continue; fi
      local title="${LABEL_NAME[$lab]:-$lab}"
      # Default for drilldown: ALL labels in selected categories are ON.
      rows+=("TRUE" "${title}" "${lab}")
      [ "${lab}" = "tailscale" ] && saw_tailscale=1
    done
  done
  if [ "${#rows[@]}" -eq 0 ]; then
    zenity --warning --title="bakup — step 3/4: nothing to restore" \
      --text="None of your selected categories have data in this backup.\n\nGo back to step 2." \
      2>/dev/null || true
    return 1
  fi
  local csv=""
  local i=0
  while [ "${i}" -lt "${#rows[@]}" ]; do
    if [ "${i}" -gt 0 ]; then csv+="\n"; fi
    csv+="${rows[$i]}	${rows[$((i+1))]}	${rows[$((i+2))]}"
    i=$((i+3))
  done
  local picked
  picked=$(printf '%s\n' "${csv}" | zenity --list \
    --title="bakup — step 3/4: fine-tune labels" \
    --text="Uncheck any individual items you don't want restored." \
    --column="Restore" --column="Item" --column="Label id" \
    --checklist --separator="|" \
    --width=720 --height=480 \
    2>/dev/null) || return 1
  # Translate each display name back to a label id.
  local selected=""
  local segments
  IFS='|' read -ra segments <<< "${picked}"
  IFS=$' \t\n'
  for seg in "${segments[@]}"; do
    local i=0
    while [ "${i}" -lt "${#rows[@]}" ]; do
      if [ "${rows[$((i+1))]}" = "${seg}" ]; then
        local lab="${rows[$((i+2))]}"
        if [ -z "${selected}" ]; then selected="${lab}"; else selected+=",${lab}"; fi
        break
      fi
      i=$((i+3))
    done
  done
  printf '%s\n' "${selected}"
}

# Stage 3b — tailscale auth key (only if tailscale is in selection).
_gui_stage3b_tailscale_key() {
  local dialog="$1"
  # Use formsdialog with a password field. Zenity supports this via
  # --password but we need a label + password + hint button, so use a
  # custom form. kdialog handles it cleanly but zenity doesn't show a
  # help link, so we'll print the URL in the form's text.
  local input
  input=$(zenity --password \
    --title="bakup — Tailscale auth key" \
    --text="Tailscale needs a fresh pre-auth key (the node-key is never\ncaptured in backups). Generate one at:\n\n  https://login.tailscale.com/admin/settings/keys\n\nPaste the tskey-… string below.\n\nLeave blank to skip Tailscale restore." \
    2>/dev/null) || return 1
  [ -z "${input}" ] && return 2  # user cancelled or skipped
  # Write to a private temp file (so restore_label tailscale can read it).
  TAILSCALE_AUTHKEY_FILE="$(mktemp -t bakup-tskey.XXXXXX)"
  chmod 600 "${TAILSCALE_AUTHKEY_FILE}"
  printf '%s' "${input}" > "${TAILSCALE_AUTHKEY_FILE}"
  export TAILSCALE_AUTHKEY_FILE
  return 0
}

# Stage 4 — confirm summary.
_gui_stage4_confirm() {
  local dialog="$1" backup_path="$2" labels_csv="$3" mode="$4" sudo_on="$5"
  local label_count=0
  local first_label
  IFS=',' read -ra _arr <<< "${labels_csv}"
  label_count="${#_arr[@]}"
  first_label="${_arr[0]:-}"
  IFS=$' \t\n'
  # Mode is a value the user toggled earlier; we just show what was chosen.
  # Sudo is a checkbox from earlier.
  zenity --question \
    --title="bakup — step 4/4: confirm restore" \
    --width=520 \
    --text="Restoring from:\n  ${backup_path}\n\nLabels (${label_count} selected):\n  ${labels_csv}\n\nMode:        ${mode}\nSudo:        $([ "${sudo_on}" = "1" ] && echo "enabled (popup may fire)" || echo "disabled")\n\nProceed?" \
    --ok-label="Restore →" --cancel-label="Cancel" \
    2>/dev/null
}

# Stage 0 — mode + sudo toggle (single popup).
_gui_stage0_mode() {
  local dialog="$1"
  # --list with radio mode gives us a choice between three modes.
  local picked
  picked=$(zenity --list \
    --title="bakup — restore mode" \
    --text="Pick how to run the restore:" \
    --column="Mode" \
    --radiolist --hide-column=1 --separator="|" \
    TRUE "Live restore (writes files)" \
    FALSE "Dry-run (show what would happen)" \
    FALSE "Preview only (no side effects)" \
    2>/dev/null) || return 1
  case "${picked}" in
    "Live restore (writes files)")    echo "live" ;;
    "Dry-run (show what would happen)") echo "dryrun" ;;
    "Preview only (no side effects)")  echo "preview" ;;
    *) return 1 ;;
  esac
}

# Wizard entry point.  Must be sourced; uses restore.sh variables.
run_wizard_gui() {
  _gui_env_setup
  if ! _gui_has_display; then
    echo "bakup: no GUI display available; falling back to TTY wizard" >&2
    return 2  # caller uses TTY path
  fi
  local dialog
  dialog="$(_gui_pick_dialog)"
  [ -z "${dialog}" ] && return 2

  # Stage 1 — pick backup
  echo "[1/4] Pick a backup run..." >&2
  local picked_backup
  picked_backup="$(_gui_stage1_pick_backup "${dialog}" "${BACKUP_ROOT}")" || return 1
  [ -z "${picked_backup}" ] && return 1
  BACKUP="${picked_backup}"
  export BACKUP

  # Stage 2 — categories
  echo "[2/4] Pick categories..." >&2
  local picked_cats
  picked_cats="$(_gui_stage2_pick_categories "${dialog}")" || return 1
  [ -z "${picked_cats}" ] && return 1

  # Stage 3 — per-label drilldown
  echo "[3/4] Fine-tune labels..." >&2
  local picked_labels
  picked_labels="$(_gui_stage3_per_label "${dialog}" ${picked_cats})" || return 1
  [ -z "${picked_labels}" ] && return 1
  APP_FILTER="${picked_labels}"
  export APP_FILTER

  # Stage 3b — Tailscale auth key (if applicable)
  if [ ",${APP_FILTER}," = *",tailscale,"* ]; then
    local rc
    _gui_stage3b_tailscale_key "${dialog}"; rc=$?
    case "${rc}" in
      0) ;; # captured
      2) # user cancelled/skip; remove tailscale from APP_FILTER
        APP_FILTER="$(echo "${APP_FILTER}" | sed 's/^tailscale,\?//; s/,\?tailscale,\?/,/g; s/^,\|,$//g')"
        export APP_FILTER
        ;;
      *) return "${rc}" ;;
    esac
  fi

  # Stage 0 — mode (we ask this BEFORE the confirm so the confirm can
  # show what was actually chosen).
  echo "[mode] Pick restore mode..." >&2
  local mode
  mode="$(_gui_stage0_mode "${dialog}")" || return 1
  case "${mode}" in
    live)    DRY_RUN=0 ;;
    dryrun)  DRY_RUN=1 ;;
    preview)
      DRY_RUN=1
      # We don't currently differentiate preview from dry-run; reuse dry-run.
      ;;
  esac
  export DRY_RUN

  # Stage 4 — confirm
  local sudo_on=0
  [ "${SKIP_SUDO}" != "1" ] && sudo_on=1
  if ! _gui_stage4_confirm "${dialog}" "${BACKUP}" "${APP_FILTER}" "${mode}" "${sudo_on}"; then
    echo "Restore cancelled by user." >&2
    return 1
  fi

  echo "[ok] Backup       : ${BACKUP}" >&2
  echo "[ok] Labels       : ${APP_FILTER}" >&2
  echo "[ok] Mode         : ${mode}" >&2
  echo "[ok] Sudo enabled : $([ "${sudo_on}" = "1" ] && echo yes || echo no)" >&2
  return 0
}

# ============================================================================
# TTY FALLBACK — same flow over stdin/stdout.
# ============================================================================

# Print all available backups, ask user to pick by number.
_tty_pick_backup() {
  local root="$1"
  local -a paths=()
  local dir
  while IFS= read -r dir; do
    [ -z "${dir}" ] && continue
    [ "${#paths[@]}" -ge 50 ] && break
    paths+=("${dir}")
  done < <(ls -1d "${root}"/*/ 2>/dev/null | sort -r)
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "No backups found at ${root}." >&2
    return 1
  fi
  echo
  echo "Available backups:"
  local i=1
  for p in "${paths[@]}"; do
    printf '  %2d) %s\n' "${i}" "$(basename "${p}")"
    i=$((i+1))
  done
  echo
  local n
  while :; do
    printf "Pick a backup [1-%d] (default 1): " "${#paths[@]}"
    read -r n
    [ -z "${n}" ] && n=1
    if [[ "${n}" =~ ^[0-9]+$ ]] && [ "${n}" -ge 1 ] && [ "${n}" -le "${#paths[@]}" ]; then
      printf '%s\n' "${paths[$((n-1))]}"
      return 0
    fi
    echo "Invalid pick."
  done
}

_tty_pick_categories() {
  echo
  echo "Categories:"
  local -a categories=( "${CATEGORIES[@]}" )
  local i=1
  for cat in "${categories[@]}"; do
    IFS=: read -r cid name def desc <<< "${cat}"
    local mark="[ ]"
    [ "${def}" = "on" ] && mark="[x]"
    printf '  %2d) %s %s — %s\n' "${i}" "${mark}" "${name}" "${desc}"
    i=$((i+1))
  done
  echo
  echo "Enter a comma-list of categories to toggle (e.g. '1,3,5' to enable; 'none' to disable all)."
  echo "Empty input = use defaults."
  local input
  read -r input
  if [ -z "${input}" ]; then
    # defaults
    local selected=""
    for cat in "${categories[@]}"; do
      IFS=: read -r cid name def desc <<< "${cat}"
      if [ "${def}" = "on" ]; then
        if [ -z "${selected}" ]; then selected="${cid}"; else selected+=" ${cid}"; fi
      fi
    done
    printf '%s\n' "${selected}"
    return 0
  fi
  if [ "${input}" = "none" ]; then
    printf '\n'
    return 0
  fi
  local -a toggles
  IFS=',' read -ra toggles <<< "${input}"
  local selected=""
  local j=1
  for cat in "${categories[@]}"; do
    IFS=: read -r cid name def desc <<< "${cat}"
    local include=0
    if [ "${def}" = "on" ]; then include=1; fi
    # toggle for each entered index
    for t in "${toggles[@]}"; do
      if [ "${t}" = "${j}" ]; then include=$((1 - include)); fi
    done
    if [ "${include}" = "1" ]; then
      if [ -z "${selected}" ]; then selected="${cid}"; else selected+=" ${cid}"; fi
    fi
    j=$((j+1))
  done
  printf '%s\n' "${selected}"
}

_tty_per_label() {
  local backup="$1"
  shift
  local -a selected_cats=( "$@" )
  echo
  echo "Available labels in this backup:"
  local -a rows=()
  for cat in "${selected_cats[@]}"; do
    local labels="${CATEGORY_LABELS[$cat]:-}"
    for lab in ${labels}; do
      [ -d "${backup}/${lab}" ] || continue
      local title="${LABEL_NAME[$lab]:-$lab}"
      rows+=("${title}|${lab}")
    done
  done
  if [ "${#rows[@]}" -eq 0 ]; then
    echo "  (none)"
    printf '\n'
    return 0
  fi
  local i=1
  for r in "${rows[@]}"; do
    printf '  %2d) [x] %s  (%s)\n' "${i}" "${r%%|*}" "${r##*|}"
    i=$((i+1))
  done
  echo
  echo "Enter labels to UN-check (default: all). Enter '-' for none."
  local input
  read -r input
  local selected=""
  if [ "${input}" = "-" ]; then
    printf '\n'; return 0
  fi
  if [ -z "${input}" ]; then
    for r in "${rows[@]}"; do
      local lab="${r##*|}"
      if [ -z "${selected}" ]; then selected="${lab}"; else selected+=",${lab}"; fi
    done
    printf '%s\n' "${selected}"
    return 0
  fi
  local -a untoggles
  IFS=',' read -ra untoggles <<< "${input}"
  local j=1
  for r in "${rows[@]}"; do
    local skip=0
    for t in "${untoggles[@]}"; do
      [ "${t}" = "${j}" ] && skip=1
    done
    if [ "${skip}" = "0" ]; then
      local lab="${r##*|}"
      if [ -z "${selected}" ]; then selected="${lab}"; else selected+=",${lab}"; fi
    fi
    j=$((j+1))
  done
  printf '%s\n' "${selected}"
}

_tty_mode() {
  echo
  echo "Mode:"
  echo "  1) Live restore (writes files)   [default]"
  echo "  2) Dry-run (show what would happen)"
  echo "  3) Preview only (alias for dry-run)"
  local n
  printf "Pick [1-3] (default 1): "
  read -r n
  [ -z "${n}" ] && n=1
  case "${n}" in
    1) echo "live" ;;
    2) echo "dryrun" ;;
    3) echo "preview" ;;
    *) echo "live" ;;
  esac
}

_tty_tailscale_key() {
  echo
  echo "Tailscale selected. Generate a pre-auth key from:"
  echo "  https://login.tailscale.com/admin/settings/keys"
  printf "Paste tskey-... (leave blank to skip Tailscale): "
  read -r input
  if [ -z "${input}" ]; then
    return 2
  fi
  TAILSCALE_AUTHKEY_FILE="$(mktemp -t bakup-tskey.XXXXXX)"
  chmod 600 "${TAILSCALE_AUTHKEY_FILE}"
  printf '%s' "${input}" > "${TAILSCALE_AUTHKEY_FILE}"
  export TAILSCALE_AUTHKEY_FILE
  return 0
}

run_wizard_tty() {
  local picked_backup
  picked_backup="$(_tty_pick_backup "${BACKUP_ROOT}")" || return 1
  [ -z "${picked_backup}" ] && return 1
  BACKUP="${picked_backup}"
  export BACKUP

  local picked_cats
  picked_cats="$(_tty_pick_categories)" || return 1
  # shellcheck disable=SC2086
  local -a cat_arr=( ${picked_cats} )

  local picked_labels
  picked_labels="$(_tty_per_label "${BACKUP}" "${cat_arr[@]}")" || return 1
  APP_FILTER="${picked_labels}"
  export APP_FILTER

  if [ ",${APP_FILTER}," = *",tailscale,"* ]; then
    local rc
    _tty_tailscale_key; rc=$?
    case "${rc}" in
      0) ;;
      2)
        APP_FILTER="$(echo "${APP_FILTER}" | sed 's/^tailscale,\?//; s/,\?tailscale,\?/,/g; s/^,\|,$//g')"
        export APP_FILTER
        ;;
      *) return "${rc}" ;;
    esac
  fi

  local mode
  mode="$(_tty_mode)"
  case "${mode}" in
    live)    DRY_RUN=0 ;;
    *)       DRY_RUN=1 ;;
  esac
  export DRY_RUN

  echo
  echo "Summary:"
  echo "  backup : ${BACKUP}"
  echo "  labels : ${APP_FILTER}"
  echo "  mode   : ${mode}"
  echo "  sudo   : $([ "${SKIP_SUDO:-0}" != "1" ] && echo enabled || echo disabled)"
  printf "Proceed? [Y/n]: "
  read -r ans
  case "${ans}" in
    ""|y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Public entrypoint used by restore.sh.
run_wizard() {
  if [ "${BAKUP_NO_GUI:-0}" = "1" ]; then
    run_wizard_tty
  else
    # Try GUI; fall back to TTY if no display or zenity missing.
    if ! run_wizard_gui; then
      # gui may return 2 = no display; fall through to TTY
      run_wizard_tty
    fi
  fi
}
