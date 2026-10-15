#!/bin/bash
# ==============================================================================
# build.sh - turns Freedoom's E1M1 and doomm4.asm into one TRS-80 Model 4 program
# ==============================================================================
# Usage:
#   ./build.sh               build/DOOM.CMD (run it at the TRSDOS 6 prompt)
#   ./build.sh --test FILE   a test build: scripted fingers from FILE (test/*.inc), reports to the printer
#   ./build.sh clean
#
# Step 1  scripts/gen_assets.py (Freedoom E1M1 via wad.py, grid.py): lattice, 2-bit wall art, ray records, stature ledgers, compiled column routines
# Step 2  zmac assembles doomm4.asm into a /CMD (code at $3000, the bank-1 payload at $8000-$F3FF)
# ==============================================================================
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$ROOT/build"
cd "$ROOT"
ZMAC="$ROOT/tools/zmac"

TESTFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        clean) rm -rf "$B"; echo "Clean complete"; exit 0 ;;
        --test) TESTFILE="$2"; shift 2 ;;
        *) echo "Usage: ./build.sh [--test FILE] | clean"; exit 2 ;;
    esac
done
[ -x "$ZMAC" ] || { echo "zmac not found - run ./setup.sh first"; exit 1; }
[ -d "$ROOT/freedoom/levels" ] || { echo "no Freedoom checkout in freedoom/ - run ./setup.sh first"; exit 1; }

mkdir -p "$B"
echo "[1/2] lattice, wall art, ledgers, column routines"
python3 scripts/gen_assets.py "$B"

NAME=DOOM; DEFS=""
if [ -n "$TESTFILE" ]; then
    cp "$TESTFILE" "$B/scenario.inc"; NAME=TEST; DEFS="-DTEST $EXTRA_DEFS"      # EXTRA_DEFS=-DPROF: phase timers
fi
echo "[2/2] assembling doomm4.asm"
"$ZMAC" $DEFS -o "$B/$NAME.CMD" -o "$B/$NAME.lst" -o "$B/$NAME.bds" doomm4.asm 2>&1 | grep -v "^$" || true
[ -f "$B/$NAME.CMD" ] || { echo "assembly failed"; exit 1; }
CODE_END=$(awk '$1 == "code_end" {print $2; exit}' "$B/$NAME.lst")
echo "  $B/$NAME.CMD ($(stat -c%s "$B/$NAME.CMD") bytes; code and routines end at \$$CODE_END)"
