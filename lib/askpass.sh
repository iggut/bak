#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# askpass.sh — sudo askpass helper for backup.sh and restore.sh
# ---------------------------------------------------------------------------
#
# Goal: when the user launches a backup or restore interactively, pop up a
# GUI password prompt (zenity/yad/kdialog) for the FIRST sudo that needs a
# password; thereafter sudo's built-in timestamp cache keeps the credential
# for subsequent sudo calls in the same run.
#
# Standard pattern (set up by sudo-helper.sh, sourced from backup.sh and
# restore.sh):
#     SUDO_ASKPASS="$(dirname "$0")/askpass.sh"
#     export SUDO_ASKPASS
#     sudo -A -v           # prime the credential (asks if not NOPASSWD)
#     sudo -A pacman -S …
#
# The -A flag tells sudo to invoke $SUDO_ASKPASS for one password prompt.
# After that, sudo's internal timestamp keeps it cached for
# `timestamp_timeout` minutes (default 5; can be raised).
#
# We do NOT implement our own credential cache — that's a security footgun.
# We let sudo's built-in cache handle re-use, with our askpass only ever
# invoked once per process.
# ---------------------------------------------------------------------------

set -eu

MSG="Enter password to allow backup/restore to read protected system files:"

# When invoked from a context that did NOT inherit a GUI environment
# (cron, SSH without ForwardX11, the Hermes WebUI shell, etc.), the
# user's active graphical session is still reachable — we just need
# to discover it.  This block runs once, at the top of askpass.sh,
# BEFORE any GUI tool tries to connect.  It is a no-op when the env
# is already set.
auto_resolve_gui_env() {
  # Already set — nothing to do.
  [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
  [ -n "${DISPLAY:-}" ] && return 0

  # XDG_RUNTIME_DIR — usually /run/user/<UID> for a login user.
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
  fi

  # Wayland detection — the compositor (Hyprland, sway, KDE, GNOME)
  # creates a single socket named after the seat "$WAYLAND_DISPLAY"
  # (typically "wayland-0" or "wayland-1").  Pick the first one that
  # we can see.
  if [ -n "${XDG_RUNTIME_DIR}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
    local sock
    for sock in "${XDG_RUNTIME_DIR}"/wayland-*; do
      [ -S "$sock" ] || continue
      WAYLAND_DISPLAY="${sock##*/}"   # basename, e.g. wayland-1
      export WAYLAND_DISPLAY
      break
    done
  fi

  # If we still have no GUI env, look for a listening X server on the
  # user's display.  We don't try to guess :N; we look at /tmp/.X11-unix/
  # for X0, X1, … DISPLAY is built as :N.0 (e.g. /tmp/.X11-unix/X1 → :1.0).
  if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
    local x
    for x in /tmp/.X11-unix/X*; do
      [ -S "$x" ] || continue
      DISPLAY=":$(printf '%s' "${x##*/X}").0"
      export DISPLAY
      break
    done
  fi

  # If neither wayland nor X is reachable, `is_gui` returns false and
  # we fall through to the tty/stdin branch.
  return 0
}

auto_resolve_gui_env

is_gui() {
  [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
  [ -n "${DISPLAY:-}" ] && return 0
  return 1
}

prompt_gui() {
  local pw=""
  if command -v zenity >/dev/null 2>&1; then
    pw=$(zenity --password --title="Backup / Restore sudo" --text="$MSG" 2>/dev/null) || return 1
    printf '%s' "$pw"
    return 0
  fi
  if command -v yad >/dev/null 2>&1; then
    pw=$(yad --password --title="Backup / Restore sudo" --text="$MSG" --button=OK:0 --button=Cancel:1 2>/dev/null) || return 1
    printf '%s' "$pw"
    return 0
  fi
  if command -v kdialog >/dev/null 2>&1; then
    pw=$(kdialog --password "$MSG" 2>/dev/null) || return 1
    printf '%s' "$pw"
    return 0
  fi
  return 1
}

prompt_tty() {
  local pw=""
  # Prefer /dev/tty (lets us read even when stdin is redirected).
  # If that fails for any reason (e.g. no controlling tty), fall back
  # to reading from fd 0 (stdin) and writing the prompt to stderr.
  local use_dev_tty=0
  if { : >/dev/tty; } 2>/dev/null; then
    use_dev_tty=1
  fi
  if [ "$use_dev_tty" = 1 ]; then
    printf '%s' "$MSG" >/dev/tty
    # shellcheck disable=SC2162
    read -rs pw </dev/tty
    printf '\n' >/dev/tty
  else
    printf '%s' "$MSG" 1>&2
    # shellcheck disable=SC2162
    read -rs pw
    printf '\n' 1>&2
  fi
  printf '%s' "$pw"
}

# Sudo calls askpass with: "<program>" "<user>"; we ignore the args and
# just emit the password on stdout. Try GUI first (if DISPLAY available)
# then fall back to TTY. Fail with empty output so sudo falls back to its
# own behavior.
if is_gui && prompt_gui; then exit 0; fi
if prompt_tty; then exit 0; fi
exit 1
