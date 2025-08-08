#!/usr/bin/env bash
set -euo pipefail

LOCK="${XDG_RUNTIME_DIR:-/tmp}/hotkeys.launch.lock"
exec 9>"$LOCK" || true
flock -n 9 || exit 0

# Already open? do nothing.
if i3-msg -t get_tree | grep -qE '"class":"Hotkeys"'; then
  exit 0
fi

# Open on workspace 10, then go back
i3-msg -q 'workspace number 10'
sleep 0.15
alacritty --class hotkeys,Hotkeys --title Hotkeys --option window.dynamic_title=false -o font.size=13 -e /home/user/.config/i3/scripts/hotkeys.sh & disown
sleep 0.2
i3-msg -q 'workspace back_and_forth'

