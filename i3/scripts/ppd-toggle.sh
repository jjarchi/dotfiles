#!/usr/bin/env bash
set -e
cur="$(powerprofilesctl get 2>/dev/null || true)"
case "$cur" in
  balanced) next=power-saver ;;
  power-saver) next=performance ;;
  performance|*) next=balanced ;;
esac
powerprofilesctl set "$next"
