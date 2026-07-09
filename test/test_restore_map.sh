#!/usr/bin/env bash
# test_restore_map.sh — Validate restore_map_path against real backup dirs.
#
# Usage: ./test/test_restore_map.sh [backup_dir]
#
# If no backup_dir is given, runs synthetic tests only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESTORE_SH="${SCRIPT_DIR}/../restore.sh"

# Extract restore_map_path
RMP_FUNC=$(awk '/^restore_map_path\(\) \{/{flag=1} flag{print; if(/^\}/){exit}}' "${RESTORE_SH}")

pass=0; fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fail=$((fail + 1))
  fi
}

echo "=== Synthetic tests ==="

# sync_one style (home_<user> prefix)
run_test() {
  local user="$1" home="$2" label="$3" subname="$4" expected="$5"
  local result
  result=$(env -i bash -c "
    ${RMP_FUNC}
    USER=${user} HOME=${home}
    restore_map_path ${label} /fake/${subname}
  ")
  check "${label}: ${subname}" "${expected}" "${result}"
}

run_test iggut /home/iggut chromium home_iggut_.config_chromium ".config/chromium"
run_test iggut /home/iggut chromium home_iggut_.cache_chromium ".cache/chromium"
run_test iggut /home/iggut zen home_iggut_.config_zen ".config/zen"
run_test iggut /home/iggut spotify home_iggut_.config_spotify ".config/spotify"
run_test iggut /home/iggut spotify home_iggut_.local_state_spicetify ".local/state/spicetify"
run_test iggut /home/iggut kdeconnect home_iggut_.config_kdeconnect ".config/kdeconnect"
run_test iggut /home/iggut kdeconnect home_iggut_.cache_kdeconnect.app ".cache/kdeconnect.app"
run_test iggut /home/iggut dms home_iggut_.config_DankMaterialShell ".config/DankMaterialShell"
run_test iggut /home/iggut dms quickshell ".local/state/quickshell"
run_test iggut /home/iggut konsole dot-config ".config"
run_test iggut /home/iggut konsole home_iggut_.local_share_konsole ".local/share/konsole"

# antigravity style (_home_<user> prefix)
run_test iggut /home/iggut antigravity _home_iggut_.antigravity ".antigravity"
run_test iggut /home/iggut antigravity _home_iggut_.antigravity-ide ".antigravity-ide"
run_test iggut /home/iggut antigravity _home_iggut_.config_Antigravity ".config/Antigravity"
run_test iggut /home/iggut antigravity _home_iggut_.config_Antigravity_IDE ".config/Antigravity IDE"
run_test iggut /home/iggut antigravity _home_iggut_.local_share_antigravity-ide ".local/share/antigravity-ide"

# Different user
run_test alice /home/alice chromium home_alice_.config_chromium ".config/chromium"
run_test alice /home/alice claude home_alice_.claude ".claude"

# BACKUP_USER_MANGLE override
result=$(env -i bash -c "
  ${RMP_FUNC}
  USER=alice HOME=/home/alice
  export BACKUP_USER_MANGLE=home_iggut_
  restore_map_path claude /fake/home_iggut_.claude
")
check "BACKUP_USER_MANGLE: claude home_iggut_.claude" ".claude" "${result}"

# Wrong user should return empty
result=$(env -i bash -c "
  ${RMP_FUNC}
  USER=bob HOME=/home/bob
  restore_map_path claude /fake/home_alice_.claude
")
check "wrong user returns empty" "" "${result}"

echo ""
echo "=== Results: ${pass} passed, ${fail} failed ==="
exit "${fail}"
