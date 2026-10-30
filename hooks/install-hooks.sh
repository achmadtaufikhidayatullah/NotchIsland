#!/bin/zsh
# Pasang (atau lepas, dengan --uninstall) hook NotchIsland di ~/.claude/settings.json.
# Settings lama dibackup ke ~/.claude/settings.json.bak-notchisland sebelum diubah.
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/NotchIsland"
mkdir -p "$DEST/claude"
cp claude-island-hook.py "$DEST/claude-island-hook.py"
chmod +x "$DEST/claude-island-hook.py"

SETTINGS="$HOME/.claude/settings.json"
[[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak-notchisland"

/usr/bin/python3 -I - "$SETTINGS" "$DEST/claude-island-hook.py" "${1:-}" <<'EOF'
import json, os, sys
settings_path, hook_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(settings_path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}

command = f'/usr/bin/python3 "{hook_path}"'
events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
hooks = settings.setdefault("hooks", {})

for event in events:
    # Buang entri NotchIsland lama dulu supaya install ulang tidak dobel.
    groups = []
    for g in hooks.get(event, []):
        g["hooks"] = [h for h in g.get("hooks", []) if "claude-island-hook.py" not in h.get("command", "")]
        if g["hooks"]:
            groups.append(g)
    if mode != "--uninstall":
        entry = {"hooks": [{"type": "command", "command": command, "timeout": 5}]}
        if event in ("PreToolUse", "PostToolUse"):
            entry["matcher"] = "*"
        groups.append(entry)
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

if not hooks:
    settings.pop("hooks")
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("Hook NotchIsland " + ("dilepas dari " if mode == "--uninstall" else "terpasang di ") + settings_path)
EOF
