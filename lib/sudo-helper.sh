#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sudo-helper.sh — shared sudo wrapper for backup.sh and restore.sh
# ---------------------------------------------------------------------------
#
# Provides two functions:
#   * sudo_init               — set SUDO_ASKPASS, prime the credential cache.
#   * sudo_run CMD [ARG ...]  — run a single sudo command; falls back to
#                               plaintext `sudo ...` if the user already has
#                               NOPASSWD configured.
#
# Usage in calling script (must be sourced after the lib path is known):
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # in backup.sh / restore.sh, the lib lives at lib/ relative to script:
#   LIB_DIR="${SCRIPT_DIR}/lib"
#   # shellcheck source=lib/sudo-helper.sh
#   source "${LIB_DIR}/sudo-helper.sh"
#   sudo_init || exit 1          # abort cleanly if user cancels the popup
#
# This is intentionally tiny: the heavy lifting is done by `sudo`'s built-in
# credential cache (timestamp_timeout × minutes).  We just supply the popup.
# ---------------------------------------------------------------------------

SUDO_ASKPASS_PROGRAM=""

sudo_init() {
  local script_dir="${1:-}"
  if [ -z "${script_dir}" ]; then
    echo "sudo_init: usage: sudo_init <dir-containing-lib>" 1>&2
    return 64
  fi
  SUDO_ASKPASS_PROGRAM="${script_dir}/askpass.sh"
  if [ ! -x "${SUDO_ASKPASS_PROGRAM}" ]; then
    echo "sudo_init: askpass not found or not executable: ${SUDO_ASKPASS_PROGRAM}" 1>&2
    return 1
  fi
  export SUDO_ASKPASS="${SUDO_ASKPASS_PROGRAM}"

  # Quick non-interactive check first.
  if sudo -n true 2>/dev/null; then
    return 0   # NOPASSWD already configured; nothing to do
  fi

  # Try to prime the credential cache via the askpass.  This will trigger
  # the GUI/TTY popup.  Run as `sudo -A -v` (validate) — extends timestamp
  # without executing a command.
  echo "[sudo] authentication required to read protected system files"
  if ! sudo -A -v 2>/dev/null; then
    echo "[sudo] authentication failed or cancelled — privileged reads skipped"
    return 1
  fi
  return 0
}

# Run a privileged command.  If the user already authenticated for the
# calling script (via sudo_init), sudo's timestamp will satisfy the call
# silently and no popup is shown.  If the cache expired or wasn't primed,
# askpass will be invoked.
sudo_run() {
  sudo -A "$@"
}

# Test whether sudo is currently usable (cache primed, or NOPASSWD set).
# Returns 0 if a privileged command will work, 1 otherwise.
sudo_can_run() {
  sudo -n true 2>/dev/null || sudo -n -v 2>/dev/null
}
