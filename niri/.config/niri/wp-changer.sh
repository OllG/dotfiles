#!/usr/bin/env bash

# Exit on errors in pipelines, but allow individual wallpaper operations
# to fail without terminating the rotation loop.
set -o pipefail

# 1. Validate input directory
if [[ -z "${1:-}" || ! -d "$1" ]]; then
    echo "Usage: $0 /path/to/wallpaper/directory/ [interval]"
    echo "Example: $0 ~/Pictures/Wallpapers 10m"
    exit 1
fi

DIR_PATH=$(realpath "$1") || exit 1
INTERVAL="${2:-15m}"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/niri-wallpaper"
mkdir -p "$CACHE_DIR" || exit 1

# Track only the daemons started by this script.
PIDS=()

# 2. Start a daemon only if it is not already running
start_daemon() {
    local name="$1"

    if awww query -n "$name" >/dev/null 2>&1; then
        echo "awww daemon '$name' is already running."
        return 0
    fi

    echo "Starting awww daemon '$name'..."
    awww-daemon -n "$name" &
    PIDS+=("$!")

    for _ in {1..50}; do
        if awww query -n "$name" >/dev/null 2>&1; then
            echo "Daemon '$name' is ready."
            return 0
        fi
        sleep 0.1
    done

    echo "Error: awww daemon '$name' did not become ready."
    return 1
}

# 3. Clean up on exit
cleanup() {
    if ((${#PIDS[@]})); then
        kill "${PIDS[@]}" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 4. Start both daemons
start_daemon default || exit 1
start_daemon wallpaper-blur || exit 1

# 5. Enable case-insensitive filename matching
shopt -s nullglob nocaseglob

# 6. Infinite wallpaper rotation loop
while true; do

    # Only images directly inside DIR_PATH; no subdirectories.
    images=(
        "$DIR_PATH"/*.png
        "$DIR_PATH"/*.jpg
        "$DIR_PATH"/*.jpeg
        "$DIR_PATH"/*.webp
        "$DIR_PATH"/*.PNG
        "$DIR_PATH"/*.JPG
        "$DIR_PATH"/*.JPEG
        "$DIR_PATH"/*.WEBP
    )

    if ((${#images[@]} == 0)); then
        echo "No valid images found in $DIR_PATH. Retrying in 10s..."
        sleep 10
        continue
    fi

    # Pick a random image
    WALLPAPER="${images[RANDOM % ${#images[@]}]}"
    BASE_NAME=$(basename "$WALLPAPER")

    # Cache uses the image filename; filenames are unique in this directory.
    BLUR_WALLPAPER="$CACHE_DIR/blur_${BASE_NAME%.*}.png"

    echo
    echo "--- Changing wallpaper to: $BASE_NAME ---"

    # Apply the sharp wallpaper immediately.
    echo "Applying standard wallpaper..."
    if ! awww img -n  default --transition-type fade --transition-duration 1.0 "$WALLPAPER"; then
        echo "Warning: Failed to apply standard wallpaper."
    fi

    # Generate the blurred image only if it is not cached.
    if [[ ! -s "$BLUR_WALLPAPER" ]]; then
        TEMP_FILE=$(mktemp "$CACHE_DIR/blur_temp_XXXXXX.png") || {
            echo "Warning: Could not create temporary file."
            sleep "$INTERVAL"
            continue
        }

        echo "Generating blurred version..."

        if magick "$WALLPAPER" \
            -resize 10% \
            -blur 0x5 \
            "$TEMP_FILE" &&
            mv "$TEMP_FILE" "$BLUR_WALLPAPER"; then
            echo "Blurred version cached."
        else
            echo "Warning: Blur generation failed."
            rm -f "$TEMP_FILE"
        fi
    fi

    # Apply the blurred backdrop.
    if [[ -s "$BLUR_WALLPAPER" ]]; then
        echo "Applying blurred backdrop..."
        awww img -n wallpaper-blur --transition-type fade --transition-duration 1.8 "$BLUR_WALLPAPER" ||
            echo "Warning: Failed to apply blurred backdrop."
    else
        echo "Blur generation failed; using original wallpaper as fallback..."
        awww img -n wallpaper-blur --transition-type fade --transition-duration 1.8 "$WALLPAPER" ||
            echo "Warning: Failed to apply fallback backdrop."
    fi

    echo "Sleeping for $INTERVAL..."
    sleep "$INTERVAL"

done
