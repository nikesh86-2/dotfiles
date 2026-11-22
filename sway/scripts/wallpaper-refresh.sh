#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/tmp/wallpaper.pid"

if [[ -f "$PID_FILE" ]] && pid="$(cat "$PID_FILE" 2>/dev/null)" && kill -0 "$pid" 2>/dev/null; then
  kill -SIGUSR1 "$pid"
  command -v notify-send >/dev/null 2>&1 && notify-send "Wallpaper" "Refreshing..." || true
else
  command -v notify-send >/dev/null 2>&1 && notify-send "Wallpaper" "Rotator isn't running" || true
  echo "wallpaper.sh does not appear to be running (no valid PID at $PID_FILE)" >&2
  exit 1
fi
