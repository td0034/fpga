#!/usr/bin/env bash
# Flash a .bin file to IceSugar v1.5 via iCELink USB mass storage
set -euo pipefail

BIN="${1:-build/top.bin}"

if [ ! -f "$BIN" ]; then
    echo "Error: $BIN not found"
    exit 1
fi

# Detect iCELink mount point
MOUNT=""
if [ "$(uname)" = "Darwin" ]; then
    # Check exact name first (fast), then case-insensitive glob fallback
    if [ -d "/Volumes/iCELink" ]; then
        MOUNT="/Volumes/iCELink"
    else
        for d in /Volumes/[iI][cC][eE][lL][iI][nN][kK]; do
            [ -d "$d" ] && MOUNT="$d" && break
        done
    fi
else
    MOUNT=$(lsblk -o MOUNTPOINT,LABEL 2>/dev/null | awk '/iCELink/{print $1}' | head -1)
    if [ -z "$MOUNT" ]; then
        MOUNT=$(findmnt -rn -o TARGET -S LABEL=iCELink 2>/dev/null | head -1)
    fi
    if [ -z "$MOUNT" ]; then
        # Fallback: check common mount points
        for p in /media/*/iCELink /mnt/iCELink /run/media/*/iCELink; do
            if [ -d "$p" ]; then MOUNT="$p"; break; fi
        done
    fi
fi

if [ -z "$MOUNT" ]; then
    echo "Error: iCELink drive not found. Is the board connected?"
    exit 1
fi

echo "Flashing $BIN -> $MOUNT"
if [ "$(uname)" = "Darwin" ]; then
    # macOS writes files non-sequentially, which breaks DAPLink programming.
    # cat redirection does a simple sequential write that DAPLink accepts.
    cat "$BIN" > "$MOUNT/top.bin"
else
    cp "$BIN" "$MOUNT/"
    sync
fi
echo "Done."
