#!/usr/bin/env bash
set -u

out_dir="$HOME/Pictures"
mkdir -p "$out_dir"

filename="screenshot-$(date +%F_%H%M%S)-$$.png"
grim "$out_dir/$filename"
