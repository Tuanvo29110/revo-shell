#!/bin/bash

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# first folder holding an image wins; the installers deploy to ~/Pictures/Wallpapers
for dir in "$HOME/.config/wallpapers" "${WALLPAPER_DIR:-$HOME/Pictures/Wallpapers}"; do
    if IFS= read -r -d '' wall < <(find -L "$dir" -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
               -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
            -print0 2>/dev/null | shuf -z -n 1); then
        exec "$SCRIPT_DIR/set.sh" "$wall"
    fi
done

echo "No wallpaper image found" >&2
exit 1
