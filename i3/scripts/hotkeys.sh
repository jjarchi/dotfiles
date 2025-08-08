#!/usr/bin/env bash
# Robust: never exit, even if file missing
FILE="/home/user/.config/i3/hotkeys.txt"

while :; do
  clear
  printf "\n"
  if [ -r "$FILE" ]; then
    cat "$FILE"
  else
    printf "Hotkeys file not found:\n  %s\n\nCreate it and reload i3." "$FILE"
  fi
  printf "\n"
  # no auto-refresh; just nap so the window stays up forever
  sleep infinity
done
