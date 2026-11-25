#!/usr/bin/env bash

# Ask the running macOS shell to lock. qs exits non-zero when no instance (or no
# handler) answers, so fall through to the caller's fallback or the legacy lock.
if timeout 3 qs ipc -p "$HOME/.config/quickshell/macos" call shell command lock >/dev/null 2>&1; then
    exit 0
elif [ -n "$1" ]; then
    bash -c "$1"
else
    bash ~/.config/hypr/scripts/lock.sh
fi
