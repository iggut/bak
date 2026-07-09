#!/usr/bin/env bash
# install.sh — Install bak scripts to ~/.local/share/bakup/
#
# Creates symlinks in ~/.local/bin/ so backup.sh and restore.sh are on $PATH.
# Safe to re-run; existing files are overwritten.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/share/bakup}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

echo "Installing bak to ${PREFIX}/"

mkdir -p "${PREFIX}" "${PREFIX}/lib" "${BINDIR}"

# Copy scripts
cp -a backup.sh restore.sh "${PREFIX}/"
cp -a lib/*.sh "${PREFIX}/lib/"

# Preserve permissions
chmod +x "${PREFIX}/backup.sh" "${PREFIX}/restore.sh"

# Create symlinks (overwrite if exists)
ln -sf "${PREFIX}/backup.sh" "${BINDIR}/backup"
ln -sf "${PREFIX}/restore.sh" "${BINDIR}/restore"

echo ""
echo "Done. Symlinks created:"
echo "  ${BINDIR}/backup  → ${PREFIX}/backup.sh"
echo "  ${BINDIR}/restore → ${PREFIX}/restore.sh"
echo ""
echo "Make sure ${BINDIR} is in your \$PATH."
echo "Verify with: which backup && which restore"
