#!/bin/sh
# Waybar custom module: NVIDIA GPU usage (JSON output).
# Shows the busiest GPU; the tooltip lists every GPU. The AMD iGPU is ignored
# because nvidia-smi does not cover it and it is normally idle.

if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf '{"text":"󰢮 n/a","tooltip":"nvidia-smi not found","class":"unavailable"}\n'
    exit 0
fi

data=$(nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null)

if [ -z "$data" ]; then
    printf '{"text":"󰢮 n/a","tooltip":"nvidia-smi returned no data","class":"unavailable"}\n'
    exit 0
fi

tooltip=""
max_util=0

while IFS=',' read -r _idx name util mem_used mem_total temp; do
    [ -z "$util" ] && continue
    # Trim the spaces nvidia-smi puts around CSV fields.
    name=$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')
    util=$(printf '%s' "$util" | sed 's/^ *//; s/ *$//')
    mem_used=$(printf '%s' "$mem_used" | sed 's/^ *//; s/ *$//')
    mem_total=$(printf '%s' "$mem_total" | sed 's/^ *//; s/ *$//')
    temp=$(printf '%s' "$temp" | sed 's/^ *//; s/ *$//')

    tooltip="${tooltip}${name}: ${util}%  ${mem_used}/${mem_total} MiB  ${temp}°C\\n"
    [ "$util" -gt "$max_util" ] && max_util=$util
done <<EOF
$data
EOF

class="normal"
[ "$max_util" -ge 90 ] && class="high"

printf '{"text":"󰢮 %s%%","tooltip":"%s","class":"%s"}\n' "$max_util" "$tooltip" "$class"
