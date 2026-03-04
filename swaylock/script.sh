#!/bin/bash

# If the pywal config exists, use it. Otherwise, use a basic blurred lock.
if [ -f ~/.cache/wal/swaylock ]; then
    swaylock --config ~/.cache/wal/swaylock
else
    swaylock --screenshots --clock --indicator --effect-blur=7x5
fi
