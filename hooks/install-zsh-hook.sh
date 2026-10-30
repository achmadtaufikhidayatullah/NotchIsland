#!/bin/zsh
# Pasang (atau lepas, dengan --uninstall) hook terminal di ~/.zshrc.
# Sama dengan menu NotchIsland › Integrasi › Terminal zsh. Backup: .zshrc.bak-notchisland.
set -e
cd "$(dirname "$0")/.."
APP_BIN="${NOTCHISLAND_BIN:-$PWD/build/NotchIsland.app/Contents/MacOS/NotchIsland}"
[[ -x "$APP_BIN" ]] || { echo "NotchIsland belum di-build. Jalankan ./build.sh dulu." >&2; exit 1; }
if [[ "${1:-}" == "--uninstall" ]]; then
  "$APP_BIN" --uninstall-terminal-hook
else
  "$APP_BIN" --install-terminal-hook
fi
echo "Berlaku di jendela terminal baru."
