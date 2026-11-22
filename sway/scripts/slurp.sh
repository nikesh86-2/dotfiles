#!/usr/bin/env bash
set -u

out_dir="$HOME/Pictures"
mkdir -p "$out_dir"

geometry="$(slurp)" || exit 0
[ -n "$geometry" ] || exit 0

filename="screenshot-$(date +%F_%H%M%S)-$$.png"
grim -g "$geometry" "$out_dir/$filename"
