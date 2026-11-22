#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Space Wallpaper Rotator (Wallhaven + Pywal + Kvantum + Sway)
# - SFW only
# - Minimum 4K UHD (3840x2160)
# - 16:9
# - Weighted search rotation with blacklist & retry logic
# - Excludes astronauts + people/closeups
###############################################################################

# ---------- Logging setup ----------
LOG_FILE="${HOME}/.cache/wallpaper.log"
mkdir -p "$(dirname "$LOG_FILE")"
# Append directly instead of via process-substitution tee: the tee child can
# outlive the script and hold the log fd open.
exec >>"$LOG_FILE" 2>&1

# ---------- Config ----------
INTERVAL_SECONDS=1200  # 20 minutes
WALLPAPER_DIR="${HOME}/.config/Wallpapers"
CURRENT_BASENAME="current_space"
KVANTUM_THEME_DIR="${HOME}/.config/Kvantum/Pywal"

# Persistence files for term/image rotation & session blacklisting
RECENT_SEARCH_FILE="/tmp/wallpaper_recent_terms"
RECENT_LIMIT=8
BLACKLIST="/tmp/wallpaper_failed_terms"
RECENT_IDS_FILE="/tmp/wallpaper_recent_ids"
RECENT_IDS_LIMIT=50

# Reset session blacklist on script startup
rm -f "$BLACKLIST"

# SFW + general category only
PURITY="100"       # safe only
CATEGORIES="100"   # general only
ATLEAST="3840x2160"
RATIOS="16x9"

# Exclusions (exact Wallhaven tags only): astronauts + people/portrait
EXCLUDE='-astronaut -cosmonaut -spacewalk -spacesuit -helmet -human -man -woman -child -boy -girl -person -people -face -portrait -selfie -headshot -model -hands'

# Weighted search terms (higher frequency = higher probability)
SEARCH_TERMS=(
    "planet" "planet" "planet" "planet"
    "galaxy" "galaxy" "galaxy" "galaxy"
    "nebula" "nebula" "nebula" "nebula"
    "space" "space" "space"
    "universe" "universe"
    "cosmos" "cosmos"
    "stars" "stars"
    "saturn" "saturn"
    "jupiter"
    "moon"
    "earth"
    "mars"
    "aurora"
    "lunar"
    "solar"
    "eclipse"
)

# Curl settings
CURL_COMMON=(-fsSL --connect-timeout 10 --max-time 30 -A "space-wallpaper-script/1.0")
CURL_DIAG=(-sSL --connect-timeout 10 --max-time 30 -A "space-wallpaper-script/1.0")

# Rate limiting settings
MIN_API_GAP_SECONDS=5
LAST_CALL_FILE="/tmp/wallpaper_last_api_call"

# ---------- Helper Functions ----------
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "Missing dependency: $1"
        exit 1
    }
}

urlencode_simple() {
    sed 's/"/%22/g; s/ /+/g'
}

# --- Recent Search History & Blacklist ---
recent_contains() {
    [[ -f "$RECENT_SEARCH_FILE" ]] && grep -Fxq "$1" "$RECENT_SEARCH_FILE" 2>/dev/null
}

remember_search() {
    local term="$1"
    {
        echo "$term"
        [[ -f "$RECENT_SEARCH_FILE" ]] && grep -Fxv "$term" "$RECENT_SEARCH_FILE" 2>/dev/null || true
    } | head -n "$RECENT_LIMIT" > "${RECENT_SEARCH_FILE}.tmp"
    mv "${RECENT_SEARCH_FILE}.tmp" "$RECENT_SEARCH_FILE"
}

blacklisted() {
    [[ -f "$BLACKLIST" ]] && grep -Fxq "$1" "$BLACKLIST" 2>/dev/null
}

blacklist() {
    local term="$1"
    if ! blacklisted "$term"; then
        echo "$term" >> "$BLACKLIST"
        log "Blacklisted term for this session: '${term}'"
    fi
}

# --- Recent Wallpaper ID History ---
is_recent_id() {
    local id="$1"
    [[ -f "$RECENT_IDS_FILE" ]] && grep -Fxq "$id" "$RECENT_IDS_FILE" 2>/dev/null
}

remember_id() {
    local id="$1"
    {
        echo "$id"
        [[ -f "$RECENT_IDS_FILE" ]] && grep -Fxv "$id" "$RECENT_IDS_FILE" 2>/dev/null || true
    } | head -n "$RECENT_IDS_LIMIT" > "${RECENT_IDS_FILE}.tmp"
    mv "${RECENT_IDS_FILE}.tmp" "$RECENT_IDS_FILE"
}

# --- Term Selection ---
get_random_search_term() {
    local candidates=()
    local term

    # Prefer non-blacklisted and non-recently used terms
    for term in "${SEARCH_TERMS[@]}"; do
        if ! blacklisted "$term" && ! recent_contains "$term"; then
            candidates+=("$term")
        fi
    done

    # Fallback 1: Relax recent constraint if all terms were recently used
    if [[ ${#candidates[@]} -eq 0 ]]; then
        for term in "${SEARCH_TERMS[@]}"; do
            if ! blacklisted "$term"; then
                candidates+=("$term")
            fi
        done
    fi

    # Fallback 2: If everything is blacklisted, pick from full array
    if [[ ${#candidates[@]} -eq 0 ]]; then
        candidates=("${SEARCH_TERMS[@]}")
    fi

    local selected="${candidates[$RANDOM % ${#candidates[@]}]}"
    remember_search "$selected"
    printf '%s' "$selected"
}

build_query_url() {
    local term="$1"
    printf '%s %s' "$term" "$EXCLUDE" | urlencode_simple
}

ext_from_url() {
    local u="$1"
    u="${u%%\?*}"
    local ext="${u##*.}"
    case "${ext,,}" in
        jpg|jpeg|png|webp) printf '%s' "${ext,,}" ;;
        *) printf 'jpg' ;;
    esac
}

throttle_api_call() {
    local now last elapsed wait
    now="$(date +%s)"
    if [[ -f "$LAST_CALL_FILE" ]]; then
        last="$(cat "$LAST_CALL_FILE" 2>/dev/null || echo 0)"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        elapsed=$((now - last))
        if [[ "$elapsed" -lt "$MIN_API_GAP_SECONDS" ]]; then
            wait=$((MIN_API_GAP_SECONDS - elapsed))
            log "Pacing: waiting ${wait}s before next Wallhaven API call."
            sleep "$wait"
        fi
    fi
    date +%s > "$LAST_CALL_FILE"
}

# ---------- Locking ----------
LOCKFILE="/tmp/wallpaper.lock"
PID_FILE="/tmp/wallpaper.pid"
USE_PID_LOCK=0

log "wallpaper.sh invoked (PID $$)"

if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        log "Another instance already holds the lock (flock); exiting."
        exit 0
    fi
else
    USE_PID_LOCK=1
    if [[ -e "$LOCKFILE" ]]; then
        oldpid="$(cat "$LOCKFILE" 2>/dev/null || true)"
        if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
            log "Another instance already running (PID $oldpid, from $LOCKFILE); exiting."
            exit 0
        fi
    fi
    echo $$ > "$LOCKFILE"
fi

echo $$ > "$PID_FILE"
log "=== wallpaper.sh started (PID $$) ==="

cleanup() {
    # Take the background sleep down with us so it can't linger after a restart.
    [[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    [[ "$USE_PID_LOCK" -eq 1 ]] && rm -f "$LOCKFILE"
}
trap cleanup EXIT
trap 'exit 0' SIGTERM SIGINT SIGHUP
SLEEP_PID=""

# ---------- On-demand refresh & Interrupts ----------
REFRESH_REQUESTED=0
trap 'REFRESH_REQUESTED=1' SIGUSR1

sleep_interruptible() {
    local secs="$1"
    local sleep_pid
    # Close the lock fd in the child so a stray sleep can't keep the
    # flock after this script is restarted or killed.
    sleep "$secs" 9>&- &
    sleep_pid=$!
    SLEEP_PID="$sleep_pid"
    wait "$sleep_pid" 2>/dev/null || true
    if [[ "$REFRESH_REQUESTED" -eq 1 ]]; then
        kill "$sleep_pid" 2>/dev/null || true
        REFRESH_REQUESTED=0
        log "On-demand refresh requested -- waking up early."
    fi
    SLEEP_PID=""
}

wait_for_network() {
    local max_wait=30
    local waited=0
    # Ping 1.1.1.1 directly — bypasses DNS lookups and third-party WAF blocks
    until curl -fs --connect-timeout 2 --max-time 3 "http://1.1.1.1" >/dev/null 2>&1; do
        if [[ "$waited" -ge "$max_wait" ]]; then
            log "Network unreachable after ${max_wait}s; proceeding anyway."
            return
        fi
        log "Waiting for network... (${waited}s/${max_wait}s)"
        sleep 2
        waited=$((waited + 2))
    done
    log "Network reachable."
}

# ---------- Dependencies ----------
need_cmd curl
need_cmd jq
need_cmd wal
need_cmd swaymsg
need_cmd shuf
need_cmd find
need_cmd mktemp

HAVE_WAYBAR=0; command -v waybar  >/dev/null 2>&1 && HAVE_WAYBAR=1
HAVE_MAKO=0;   command -v makoctl >/dev/null 2>&1 && HAVE_MAKO=1

mkdir -p "$WALLPAPER_DIR"
mkdir -p "$KVANTUM_THEME_DIR"

# ---------- Main Cycle ----------
run_cycle() {
    local IMAGE_URL=""
    local IMAGE_PATH=""
    local SELECTED_TERM=""
    local DOWNLOAD_SUCCESS=0
    local ext="jpg"
    local attempt Q_URL BASE_URL META_FILE HTTP_STATUS TOTAL RESULT_FILE
    local COUNT url img_id tmpfile dest
    local -a CANDIDATES=() SHUFFLED=()

    # Try up to 10 search terms per cycle before resorting to local fallback
    for attempt in {1..10}; do
        SELECTED_TERM="$(get_random_search_term)"
        Q_URL="$(build_query_url "$SELECTED_TERM")"
        log "Attempt ${attempt}/10: Selected search term: '${SELECTED_TERM}'"

        # API returns 24 results per page; we treat one random page as the sample
        BASE_URL="https://wallhaven.cc/api/v1/search?q=${Q_URL}&purity=${PURITY}&categories=${CATEGORIES}&atleast=${ATLEAST}&ratios=${RATIOS}&sorting=random"
        META_FILE="$(mktemp --suffix=".json")"

        log "Checking match count for query: ${Q_URL}"
        throttle_api_call
        HTTP_STATUS="$(curl "${CURL_DIAG[@]}" -w '%{http_code}' -o "$META_FILE" "${BASE_URL}&page=1" 2>/dev/null || echo "000")"
        log "API HTTP status: ${HTTP_STATUS}"

        TOTAL=0
        if [[ "$HTTP_STATUS" =~ ^2 ]] && jq -e . "$META_FILE" >/dev/null 2>&1; then
            TOTAL="$(jq -r '.meta.total // 0' "$META_FILE" 2>/dev/null || echo 0)"
            log "Query matched ${TOTAL} wallpaper(s)"
        else
            log "Unexpected API response or error (status ${HTTP_STATUS})."
            TOTAL=0
        fi

        if [[ "$TOTAL" -eq 0 ]]; then
            log "Zero matches for term '${SELECTED_TERM}'. Blacklisting for session."
            blacklist "$SELECTED_TERM"
            rm -f "$META_FILE"
            continue
        fi

        RESULT_FILE="$META_FILE"
        COUNT="$(jq -r '.data | length' "$RESULT_FILE" 2>/dev/null || echo 0)"
        log "Sample page returned ${COUNT} wallpaper(s)"

        if [[ "$COUNT" -gt 0 ]]; then
            mapfile -t CANDIDATES < <(jq -r '.data[].path // empty' "$RESULT_FILE" 2>/dev/null)
            rm -f "$RESULT_FILE"

            if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
                mapfile -t SHUFFLED < <(printf '%s\n' "${CANDIDATES[@]}" | shuf)
                for url in "${SHUFFLED[@]}"; do
                    img_id="$(basename "$url")"
                    if ! is_recent_id "$img_id"; then
                        IMAGE_URL="$url"
                        break
                    fi
                done

                # Fallback to first candidate if all were recently downloaded
                if [[ -z "$IMAGE_URL" && ${#SHUFFLED[@]} -gt 0 ]]; then
                    IMAGE_URL="${SHUFFLED[0]}"
                    log "All images on page were recently downloaded; picking first candidate."
                fi
            fi
        else
            rm -f "$RESULT_FILE"
        fi

        if [[ -n "$IMAGE_URL" ]]; then
            ext="$(ext_from_url "$IMAGE_URL")"
            tmpfile="$(mktemp --suffix=".${ext}")"
            dest="${WALLPAPER_DIR}/${CURRENT_BASENAME}.${ext}"

            log "Downloading: $IMAGE_URL"
            if curl "${CURL_COMMON[@]}" -o "$tmpfile" "$IMAGE_URL" && [[ -s "$tmpfile" ]]; then
                mv -f "$tmpfile" "$dest"
                # mktemp creates 600; match the other wallpapers in this directory
                chmod 664 "$dest" 2>/dev/null || true
                # Drop stale copies left by a previous cycle with a different extension
                find "$WALLPAPER_DIR" -maxdepth 1 -type f \
                    -name "${CURRENT_BASENAME}.*" ! -name "${CURRENT_BASENAME}.${ext}" \
                    -delete 2>/dev/null || true
                remember_id "$(basename "$IMAGE_URL")"
                log "Saved to: $dest"
                DOWNLOAD_SUCCESS=1
                break
            else
                rm -f "$tmpfile" || true
                log "Download failed for URL: ${IMAGE_URL}"
            fi
        fi

        log "Attempt ${attempt} failed to retrieve a wallpaper. Retrying..."
    done

    if [[ "$DOWNLOAD_SUCCESS" -eq 1 ]]; then
        IMAGE_PATH="${WALLPAPER_DIR}/${CURRENT_BASENAME}.${ext}"
    else
        log "All 10 online search attempts failed. Falling back to local wallpaper."
        IMAGE_PATH="$(
            find "$WALLPAPER_DIR" -type f \
                ! -name "${CURRENT_BASENAME}.*" \
                \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
                | shuf -n 1 \
                || true
        )"
        if [[ -n "${IMAGE_PATH}" ]]; then
            log "Using local fallback: $IMAGE_PATH"
        else
            log "No local fallback images found in $WALLPAPER_DIR"
        fi
    fi

    if [[ -n "${IMAGE_PATH}" && -f "${IMAGE_PATH}" ]]; then
        # 1) Generate colors (pywal) using -s (skip terminal sequence export) to fix socket error
        log "Running pywal..."
        wal -i "$IMAGE_PATH" -n -q -s || log "wal failed (continuing)."

        # 2) Sync Kvantum theme files
        if [[ -f "${HOME}/.cache/wal/colors-kvantum.kvconfig" ]]; then
            cp -f "${HOME}/.cache/wal/colors-kvantum.kvconfig" "${KVANTUM_THEME_DIR}/Pywal.kvconfig"
            log "Updated Kvantum config."
        fi
        if [[ -f "${HOME}/.cache/wal/colors-kvantum.svg" ]]; then
            cp -f "${HOME}/.cache/wal/colors-kvantum.svg" "${KVANTUM_THEME_DIR}/Pywal.svg"
            log "Updated Kvantum SVG."
        fi

        # 3) Set wallpaper in Sway
        log "Setting wallpaper in Sway..."
        swaymsg -q output "*" bg "$IMAGE_PATH" fill >/dev/null 2>&1 || log "swaymsg failed (continuing)."

        # 4) Reload UI elements
        if [[ $HAVE_WAYBAR -eq 1 ]]; then
            pkill -USR2 waybar 2>/dev/null || true
            log "Waybar reloaded."
        fi
        if [[ $HAVE_MAKO -eq 1 ]]; then
            makoctl reload 2>/dev/null || true
            log "Mako reloaded."
        fi
    else
        log "No image available this cycle; skipping theme/wallpaper apply."
    fi
}

# ---------- Main Loop ----------
wait_for_network

while true; do
    run_cycle
    sleep_interruptible "$INTERVAL_SECONDS"
done
