#!/bin/zsh
# Pasang (atau lepas, dengan --uninstall) hook Claude Code di ~/.claude/settings.json.
# Sama dengan menu NotchIsland › Integrasi › Claude Code. Backup: settings.json.bak-notchisland.
set -e
cd "$(dirname "$0")/.."
APP_BIN="${NOTCHISLAND_BIN:-$PWD/build/NotchIsland.app/Contents/MacOS/NotchIsland}"
[[ -x "$APP_BIN" ]] || { echo "NotchIsland belum di-build. Jalankan ./build.sh dulu." >&2; exit 1; }
if [[ "${1:-}" == "--uninstall" ]]; then
  "$APP_BIN" --uninstall-claude-hook
else
  "$APP_BIN" --install-claude-hook
fi
