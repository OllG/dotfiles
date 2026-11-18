```bash
#!/usr/bin/env bash

# Allow individual wallpaper operations to fail without
# terminating the rotation loop.
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

# Track only daemons started by this script.
PIDS=()

# Daemon state
BLUR_DAEMON_STARTED=0

# 2. Start a daemon only if it is not already running.
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

# 3. Clean up only daemons started by this script.
cleanup() {
    if ((${#PIDS[@]})); then
        kill "${PIDS[@]}" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 4. Start only the primary daemon initially.
start_daemon default || exit 1

# 5. Enable case-insensitive filename matching.
shopt -s nullglob nocaseglob

# 6. Discover images once.
images=(
    "$DIR_PATH"/*.png
    "$DIR_PATH"/*.jpg
    "$DIR_PATH"/*.jpeg
    "$DIR_PATH"/*.webp
)

if ((${#images[@]} == 0)); then
    echo "No images found in $DIR_PATH."
    exit 1
fi

# 7. Wallpaper rotation loop.
while true; do
    # Pick a random wallpaper.
    WALLPAPER="${images[RANDOM % ${#images[@]}]}"
    BASE_NAME=$(basename "$WALLPAPER")

    BLUR_WALLPAPER="$CACHE_DIR/blur_${BASE_NAME%.*}.png"

    echo
    echo "--- Changing wallpaper to: $BASE_NAME ---"

    # Apply the sharp wallpaper first.
    echo "Applying standard wallpaper..."

    if ! awww img -n default \
        --transition-type fade \
        --transition-duration 1.0 \
        "$WALLPAPER"; then
        echo "Warning: Failed to apply standard wallpaper."
        sleep 2
        continue
    fi

    # Start the blur daemon only after requesting the
    # sharp wallpaper for the first time.
    if (( BLUR_DAEMON_STARTED == 0 )); then
        if start_daemon wallpaper-blur; then
            BLUR_DAEMON_STARTED=1
        else
            echo "Warning: Blur daemon unavailable; retrying next cycle."
            sleep "$INTERVAL"
            continue
        fi
    fi

    # Generate the blurred image only if not already cached.
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

        awww img -n wallpaper-blur \
            --transition-type fade \
            --transition-duration 1.8 \
            "$BLUR_WALLPAPER" ||
            echo "Warning: Failed to apply blurred backdrop."
    else
        echo "Blur unavailable; using original wallpaper as fallback..."

        awww img -n wallpaper-blur \
            --transition-type fade \
            --transition-duration 1.8 \
            "$WALLPAPER" ||
            echo "Warning: Failed to apply fallback backdrop."
    fi

    echo "Sleeping for $INTERVAL..."
    sleep "$INTERVAL"
done
```
