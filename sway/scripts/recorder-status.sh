#!/usr/bin/env bash
# Emits the Waybar JSON status for the screen-recorder button.
# Refreshed by wl-recorder.sh via SIGRTMIN+8 (waybar "signal": 8).
set -uo pipefail

if pgrep -x wf-recorder >/dev/null 2>&1; then
    printf '{"text":"●","alt":"recording","class":"recording","tooltip":"Recording — click to stop"}\n'
else
    printf '{"text":"○","alt":"idle","class":"idle","tooltip":"Click to record a region"}\n'
fi
