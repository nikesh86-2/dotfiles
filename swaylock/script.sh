#!/bin/bash
# Multi-monitor lock using grim + swaylock (no swaylock-effects)
# Automatically grabs each monitor and sets correct images

LOCK_DIR="$HOME/.cache/swaylock-multi"
mkdir -p "$LOCK_DIR"
rm -f "$LOCK_DIR"/*.png

# Grab each output separately
for output in $(swaymsg -t get_outputs | jq -r '.[] | select(.active) | .name'); do
    grim -o "$output" "$LOCK_DIR/$output.png"
    magick "$LOCK_DIR/$output.png" -blur 0x4 "$LOCK_DIR/$output.png"
done

# Build swaylock arguments for each output
LOCK_ARGS=()
for img in "$LOCK_DIR"/*.png; do
    # map each output to its own image
    output_name=$(basename "$img" .png)
    LOCK_ARGS+=("-i" "$output_name:$img")
done

# Run swaylock
swaylock --config ~/.cache/wal/swaylock "${LOCK_ARGS[@]}"
