#!/usr/bin/env bash
# Flash a .bit file to ULX3S via openFPGALoader
# Prerequisite: brew install openfpgaloader (macOS) or install from source
set -euo pipefail

# Usage: ./flash.sh [-f] <file.bit>
#   -f  Write to SPI flash (persistent across power cycles)
#       Without -f, writes to SRAM (volatile, lost on power-off)
FLASH_MODE=""
if [ "${1:-}" = "-f" ]; then
    FLASH_MODE="-f"
    shift
fi

BIT="${1:-build/top.bit}"

if [ ! -f "$BIT" ]; then
    echo "Error: $BIT not found"
    exit 1
fi

# Prefer Homebrew openFPGALoader (oss-cad-suite version has issues on some setups)
LOADER=""
if [ -x /opt/homebrew/bin/openFPGALoader ]; then
    LOADER=/opt/homebrew/bin/openFPGALoader
elif command -v openFPGALoader &> /dev/null; then
    LOADER=openFPGALoader
else
    echo "Error: openFPGALoader not found."
    echo "Install with: brew install openfpgaloader (macOS)"
    echo "Or see: https://github.com/trabucayre/openFPGALoader"
    exit 1
fi

if [ -n "$FLASH_MODE" ]; then
    echo "Flashing $BIT -> ULX3S (SPI flash — persistent)"
    "$LOADER" --board=ulx3s --unprotect-flash -f "$BIT"
else
    echo "Flashing $BIT -> ULX3S (SRAM)"
    "$LOADER" --board=ulx3s "$BIT"
fi
echo "Done."
