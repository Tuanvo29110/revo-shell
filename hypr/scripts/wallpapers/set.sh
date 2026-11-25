#!/bin/bash
set -eu

WALL="${1:-}"
if [[ ! -f "$WALL" ]]; then
    echo "No such wallpaper: '$WALL'" >&2
    exit 1
fi

# at login awww-daemon may still be starting: wait for it, at most ~10s
deadline=$((SECONDS + 10))
until timeout 2 awww query >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
        echo "awww-daemon is not answering" >&2
        exit 1
    fi
    sleep 0.1
done

awww img --transition-type center --transition-step 90 "$WALL"
echo "Wallpaper set successfully"


if command -v wal >/dev/null 2>&1; then
    echo "applying pywal colors..."
    wal -i "$WALL"
    echo "pywal applied successfully"
    "$HOME/.config/mako/update-colors.sh" &
    "$HOME/.config/keyboard/set-color-keyboard.sh" &
else
    echo "pywal not installed, skipping"
fi

