#!/usr/bin/env bash
# Screen/window recorder (wf-recorder + PipeWire audio via pactl)
#   wl-recorder.sh         record entire screen
#   wl-recorder.sh -s      record a selected region (slurp)
#   wl-recorder.sh -w      record a selected window (slurp over sway tree)
# Running it again while a recording is active stops it.
set -uo pipefail

REC_DIR="$HOME/Videos/Recordings"
mkdir -p "$REC_DIR"

# --- Audio: resolve the default sink's monitor source (pactl, PipeWire) ---
audio_source=""
default_sink="$(pactl get-default-sink 2>/dev/null || true)"
if [ -n "$default_sink" ]; then
    monitor="${default_sink}.monitor"
    # wf-recorder -a expects the source *name* (pactl list short sources: $1=index $2=name)
    audio_source="$(pactl list short sources 2>/dev/null \
        | awk -v m="$monitor" '$2 == m { print $2; exit }' || true)"
fi

# --- Output: the focused monitor (avoids wf-recorder's interactive pick) ---
focused_output="$(swaymsg -t get_outputs 2>/dev/null \
    | jq -r '.[] | select(.focused) | .name' | head -n 1 || true)"
[ -n "$focused_output" ] || focused_output="$(swaymsg -t get_outputs 2>/dev/null \
    | jq -r '.[] | select(.active) | .name' | head -n 1 || true)"

filename="$(date +%F_%H%M%S).mkv"
path="$REC_DIR/$filename"

record() {
    local geom="$1"
    local args=(-f "$path")
    [ -n "$audio_source" ] && args+=(-a "$audio_source")
    if [ -n "$geom" ]; then
        args+=(-g "$geom")
    elif [ -n "$focused_output" ]; then
        args+=(-o "$focused_output")
    fi
    args+=(-y)
    exec wf-recorder "${args[@]}"
}

wait_recorder_gone() {
    local i=0
    while pgrep -x wf-recorder >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
        sleep 0.2
        i=$((i + 1))
    done
}

notify() {
    command -v notify-send >/dev/null 2>&1 && notify-send "$@" || true
}

# --- Stop branch: a recorder is already running ---
if pgrep -x wf-recorder >/dev/null 2>&1; then
    pkill -INT -x wf-recorder || true
    wait_recorder_gone
    pkill -RTMIN+8 waybar || true
    notify "Recording" "Stopped."

    if command -v zenity >/dev/null 2>&1; then
        name="$(zenity --entry --text "Enter a filename" || true)"
        name="$(basename "${name:-}")"
        name="${name%.mkv}"; name="${name%.mp4}"
        if [ -n "$name" ]; then
            latest="$(ls -dt "$REC_DIR"/* 2>/dev/null | head -n 1 || true)"
            if [ -n "$latest" ] && [ -f "$latest" ]; then
                if mv -n "$latest" "$REC_DIR/${name}.mkv"; then
                    notify "Recording" "Saved as ${name}.mkv"
                else
                    notify "Recording" "Could not rename (name already in use?)"
                fi
            fi
        fi
    fi
    exit 0
fi

# --- Start branches ---
case "${1:-}" in
    -s)
        geom="$(slurp -c "#FFFFFF" || true)"
        [ -n "$geom" ] || exit 0
        notify "Recording" "Started (region)"
        pkill -RTMIN+8 waybar || true
        record "$geom"
        ;;
    -w)
        geom="$(swaymsg -t get_tree \
            | jq -r '.. | select(.pid? and .visible?) | .rect | "\(.x),\(.y) \(.width)x\(.height)"' \
            | slurp -c "#FFFFFF" || true)"
        [ -n "$geom" ] || exit 0
        notify "Recording" "Started (window)"
        pkill -RTMIN+8 waybar || true
        record "$geom"
        ;;
    *)
        notify "Recording" "Started (screen)"
        pkill -RTMIN+8 waybar || true
        record ""
        ;;
esac
