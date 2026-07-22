#!/bin/bash
# Decksmith launcher for macOS
# Double-click this file to install and run Decksmith.

cd "$(dirname "$0")"

# Remove macOS quarantine flag on all files (set when downloaded from the internet)
xattr -dr com.apple.quarantine . 2>/dev/null || true

# ── Check for Python 3 ──────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    osascript -e 'display dialog "Python 3 is required to run Decksmith.\n\nClick Download to get it from python.org, then double-click Decksmith.command again." buttons {"Download", "Cancel"} default button "Download" with title "Decksmith"'
    if [ $? -eq 0 ]; then
        open "https://www.python.org/downloads/macos/"
    fi
    exit 1
fi

# ── Check Python version ────────────────────────────────────────────────────
PY_VER=$(python3 -c "import sys; print(sys.version_info[:2] >= (3,9))" 2>/dev/null)
if [ "$PY_VER" != "True" ]; then
    osascript -e 'display dialog "Decksmith requires Python 3.9 or later.\n\nClick Download to update." buttons {"Download", "Cancel"} default button "Download" with title "Decksmith"'
    if [ $? -eq 0 ]; then
        open "https://www.python.org/downloads/macos/"
    fi
    exit 1
fi

# ── Run launcher ────────────────────────────────────────────────────────────
python3 launch.py
