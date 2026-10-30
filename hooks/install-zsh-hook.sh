#!/bin/zsh
# Pasang (atau lepas, dengan --uninstall) hook terminal NotchIsland di ~/.zshrc.
# ~/.zshrc dibackup ke ~/.zshrc.bak-notchisland sebelum diubah.
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/NotchIsland"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
MARK="# NotchIsland terminal hook"
LINE="[[ -f \"$DEST/notch-terminal.zsh\" ]] && source \"$DEST/notch-terminal.zsh\"  $MARK"

touch "$ZSHRC"
cp "$ZSHRC" "$ZSHRC.bak-notchisland"
# Buang baris lama dulu supaya pasang ulang tidak dobel.
grep -v -F "$MARK" "$ZSHRC.bak-notchisland" > "$ZSHRC" || true

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "Hook terminal NotchIsland dilepas dari $ZSHRC (berlaku di terminal baru)."
  exit 0
fi

mkdir -p "$DEST/terminal"
cp notch-terminal.zsh "$DEST/notch-terminal.zsh"
print -r -- "$LINE" >> "$ZSHRC"
echo "Hook terminal NotchIsland terpasang di $ZSHRC (berlaku di terminal baru)."
