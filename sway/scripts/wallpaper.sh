#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Space Wallpaper Rotator (Wallhaven + Pywal + Kvantum + Sway)
# - SFW only
# - Minimum 4K UHD (3840x2160)
# - 16:9
# - Query rotation for variety
# - Excludes astronauts + people/closeups
###############################################################################

# ---------- Config ----------
INTERVAL_SECONDS=1200  # 20 minutes
WALLPAPER_DIR="${HOME}/.config/Wallpapers"
CURRENT_BASENAME="current_space"  # we store as current_space.<ext>
KVANTUM_THEME_DIR="${HOME}/.config/Kvantum/Pywal"

# SFW + general category only (cuts down portraits/anime/people results)
PURITY="100"       # safe only
CATEGORIES="100"   # general only
ATLEAST="3840x2160"
RATIOS="16x9"

# Exclusions: astronauts + common people/portrait terms
EXCLUDE='-astronaut -spacewalk -spacesuit -helmet -cosmonaut -portrait -face -person -people -human -man -woman -girl -boy -selfie -model -headshot -hands'

# Rotating queries (edit/add to taste)
QUERIES=(
  'space OR nebula OR galaxy OR "deep space"'
  'milky way OR "night sky" OR astrophotography OR stargazing'
  'planet OR saturn OR jupiter OR "ringed planet" OR "gas giant"'
  'cosmos OR universe OR interstellar OR "star field"'
  'nebula OR "emission nebula" OR "cosmic dust" OR "space clouds"'
  '"space landscape" OR "alien world" OR "cosmic horizon"'
)

# Curl settings (a UA helps with some endpoints; timeouts prevent hangs)
CURL_COMMON=(-fsSL --connect-timeout 10 --max-time 30 -A "space-wallpaper-script/1.0")

# ---------- Helpers ----------
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing dependency: $1"
    exit 1
  }
}

urlencode_simple() {
  # Simple URL encoding sufficient for our use: quotes->%22, spaces->+
  # (Wallhaven search endpoint handles + well; OR terms are left as-is)
  sed 's/"/%22/g; s/ /+/g'
}

get_random_query_url() {
  local q="${QUERIES[$RANDOM % ${#QUERIES[@]}]}"
  local full
  full="$(printf '%s %s' "$q" "$EXCLUDE")"
  printf '%s' "$full" | urlencode_simple
}

# Determine extension from URL (best effort)
ext_from_url() {
  local u="$1"
  u="${u%%\?*}"      # strip query string if present
  local ext="${u##*.}"
  # sanity: only allow common image extensions
  case "${ext,,}" in
    jpg|jpeg|png|webp) printf '%s' "${ext,,}" ;;
    *) printf 'jpg' ;;
  esac
}

# ---------- Locking (prefer flock) ----------
LOCKFILE="/tmp/wallpaper.lock"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    exit 0
  fi
else
  # PID lock fallback
  if [[ -e "$LOCKFILE" ]]; then
    oldpid="$(cat "$LOCKFILE" 2>/dev/null || true)"
    if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
      exit 0
    fi
  fi
  echo $$ > "$LOCKFILE"
  trap 'rm -f "$LOCKFILE"' EXIT
fi

# ---------- Dependencies ----------
need_cmd curl
need_cmd jq
need_cmd wal
need_cmd swaymsg
need_cmd shuf
need_cmd find
need_cmd mktemp

# Optional commands (we won't fail if missing)
HAVE_WAYBAR=0; command -v pkill  >/dev/null 2>&1 && HAVE_WAYBAR=1
HAVE_MAKO=0;   command -v makoctl >/dev/null 2>&1 && HAVE_MAKO=1

# ---------- Ensure dirs ----------
mkdir -p "$WALLPAPER_DIR"
mkdir -p "$KVANTUM_THEME_DIR"

# ---------- Main loop ----------
while true; do
  # Build API URL with a randomized query + randomized page to reduce repeats
  Q_URL="$(get_random_query_url)"
  PAGE=$((RANDOM % 20 + 1))

  API_URL="https://wallhaven.cc/api/v1/search?q=${Q_URL}&purity=${PURITY}&categories=${CATEGORIES}&atleast=${ATLEAST}&ratios=${RATIOS}&sorting=random&page=${PAGE}"

  log "Fetching: $API_URL"

  # Pull a random image URL from results (not just [0])
  # If API fails or returns nothing, fall back to local.
  IMAGE_URL="$(
    curl "${CURL_COMMON[@]}" "$API_URL" \
      | jq -r '.data[].path // empty' \
      | shuf -n 1 \
      || true
  )"

  IMAGE_PATH=""

  if [[ -n "${IMAGE_URL}" ]]; then
    ext="$(ext_from_url "$IMAGE_URL")"
    tmpfile="$(mktemp --suffix=".${ext}")"
    dest="${WALLPAPER_DIR}/${CURRENT_BASENAME}.${ext}"

    log "Downloading: $IMAGE_URL"
    if curl "${CURL_COMMON[@]}" -o "$tmpfile" "$IMAGE_URL" && [[ -s "$tmpfile" ]]; then
      mv -f "$tmpfile" "$dest"
      IMAGE_PATH="$dest"
      log "Saved to: $IMAGE_PATH"
    else
      rm -f "$tmpfile" || true
      log "Download failed; will fall back to local."
    fi
  else
    log "No URL returned (rate limit or no matches); will fall back to local."
  fi

  # Local fallback: choose a random wallpaper excluding current_space.*
  if [[ -z "$IMAGE_PATH" ]]; then
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
    # 1) Generate colors (pywal)
    log "Running pywal..."
    wal -i "$IMAGE_PATH" -n -q || log "wal failed (continuing)."

    # 2) Sync Kvantum theme files (kvconfig + optional svg)
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
  fi

  sleep "$INTERVAL_SECONDS"
done
