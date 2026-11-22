#!/bin/bash
# Multi-monitor lock using grim + swaylock (no swaylock-effects)
# - one instance at a time (flock), so idle/before-sleep/keybind cannot stack locks
# - forces outputs back on before locking and whenever the lock command returns
# - --fork daemonizes swaylock, so swayidle -w is not blocked while locked

set -uo pipefail

LOCK_DIR="$HOME/.cache/swaylock-multi"
SWAYLOCK_CONFIG="$HOME/.cache/wal/swaylock"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOCK_FILE="$RUNTIME_DIR/swaylock-script.${UID}.lock"

daemonize=0
case "${1:-}" in
    -f|--fork|--daemonize) daemonize=1 ;;
esac

mkdir -p "$LOCK_DIR"

# Only one lock instance may run at a time. A second trigger (idle timeout,
# before-sleep, keybinding) exits immediately instead of stacking swaylocks.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

# A daemonized swaylock from a previous before-sleep is not covered by flock.
if pgrep -x swaylock >/dev/null 2>&1; then
    exit 0
fi

# Make sure displays are on before capturing: locking from a DPMS-off state
# used to grab black frames and leave the screen looking off.
swaymsg -q 'output * dpms on' >/dev/null 2>&1 || true
sleep 0.3

# Whatever ends the lock (unlock, kill, failed start), turn displays back on.
trap 'swaymsg -q "output * dpms on" >/dev/null 2>&1 || true' EXIT

swaylock_args=(--config "$SWAYLOCK_CONFIG")
[ "$daemonize" -eq 1 ] && swaylock_args+=(-f)

rm -f "$LOCK_DIR"/*.png

# Active output names, one per line
outputs="$(swaymsg -t get_outputs 2>/dev/null | jq -r '.[] | select(.active) | .name' 2>/dev/null)" || outputs=""

# Grab + blur one image per active output and queue its swaylock argument
lock_args=()
while IFS= read -r output; do
    [ -n "$output" ] || continue
    img="$LOCK_DIR/$output.png"
    if grim -o "$output" - 2>/dev/null | magick - -blur 0x4 "$img" 2>/dev/null; then
        lock_args+=(-i "$output:$img")
    else
        echo "$0: failed to capture $output, skipping" >&2
        rm -f "$img"
    fi
done <<< "$outputs"

if [ "${#lock_args[@]}" -eq 0 ]; then
    echo "$0: no usable captures, using plain swaylock" >&2
    swaylock "${swaylock_args[@]}"
else
    # No fallback spawn: if swaylock cannot lock (e.g. another locker already
    # holds the session), starting a second copy only stacks lock screens.
    swaylock "${swaylock_args[@]}" "${lock_args[@]}"
fi
