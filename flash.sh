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
    MOUNT=$(find /Volumes -maxdepth 1 -iname "icelink" 2>/dev/null | head -1)
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
cp "$BIN" "$MOUNT/"
sync
echo "Done."
