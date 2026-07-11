#!/usr/bin/env bash
# install.sh — Install bak scripts to ~/.local/share/bakup/
#
# Creates symlinks in ~/.local/bin/ so backup/restore/bakup-gui are on $PATH.
# Safe to re-run; existing files are overwritten.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/share/bakup}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

echo "Installing bak to ${PREFIX}/"

mkdir -p "${PREFIX}" "${PREFIX}/lib" "${BINDIR}"

# Copy scripts + GUI
cp -a backup.sh restore.sh bakup-gui.py bakup-gui "${PREFIX}/"
[ -f bakup.desktop ] && cp -a bakup.desktop "${PREFIX}/"
cp -a lib/*.sh "${PREFIX}/lib/"
cp -a lib/restore_parts.py "${PREFIX}/lib/"

chmod +x "${PREFIX}/backup.sh" "${PREFIX}/restore.sh" "${PREFIX}/bakup-gui"
chmod +x "${PREFIX}/lib/"*.sh "${PREFIX}/lib/restore_parts.py"

ln -sf "${PREFIX}/backup.sh" "${BINDIR}/backup"
ln -sf "${PREFIX}/restore.sh" "${BINDIR}/restore"
ln -sf "${PREFIX}/bakup-gui" "${BINDIR}/bakup-gui"

echo ""
echo "Done. Symlinks created:"
echo "  ${BINDIR}/backup     → ${PREFIX}/backup.sh"
echo "  ${BINDIR}/restore    → ${PREFIX}/restore.sh"
echo "  ${BINDIR}/bakup-gui  → ${PREFIX}/bakup-gui"
echo ""
echo "Make sure ${BINDIR} is in your \$PATH."
echo "Verify with: which backup && which restore && which bakup-gui"
