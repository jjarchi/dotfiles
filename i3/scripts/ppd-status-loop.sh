#!/usr/bin/env bash
set -e
out="$HOME/.cache/ppd_status.txt"
mkdir -p "$(dirname "$out")"
while :; do
  cur="$(powerprofilesctl get 2>/dev/null || true)"
  case "$cur" in
    performance) echo -n "P" > "$out" ;;
    balanced)    echo -n "B" > "$out" ;;
    power-saver) echo -n "S" > "$out" ;;
    *)           echo -n "-" > "$out" ;;
  esac
  sleep 2
done
