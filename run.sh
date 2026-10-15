#!/bin/bash
# ==============================================================================
# run.sh - build and play DOOM (Freedoom E1M1) on a TRS-80 Model 4 (trs80gp)
# ==============================================================================
# trs80gp boots its built-in TRSDOS 6 and runs build/DOOM.CMD from the DOS prompt.  The program takes the
# machine over (interrupts off, memory mode 2, 4 MHz), forges the wall art into the two upper banks (128 KB),
# and plays.  On a real Model 4 (128 KB): copy DOOM/CMD to a TRSDOS 6 / LS-DOS 6 disk and type DOOM.
#
# Controls
#   W / UP     forward          S / DOWN    backward
#   A / LEFT   turn left        D / RIGHT   turn right
#   SPACE      open a door      BREAK       quit (the machine restarts)
#
# Usage:  ./run.sh [--no-build] [--fast] [extra trs80gp args...]
#   --fast      run the emulator at top speed (trs80gp -turbo)
# ==============================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
BUILD=1; ARGS=(); BOPT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --fast) ARGS+=(-turbo); shift ;;
        -h|--help) sed -n 2,17p "$0"; exit 0 ;;
        *) break ;;
    esac
done
[ "$BUILD" = 1 ] && { ./build.sh $BOPT || exit 1; }
[ -x tools/trs80gp ] || { echo "trs80gp not found - run ./setup.sh first"; exit 1; }
[ -n "$WAYLAND_DISPLAY" ] && export GDK_BACKEND=x11      # trs80gp's GTK window segfaults under native Wayland
mkdir -p build/run
cd build/run
exec ../../tools/trs80gp -m4 -vs "${ARGS[@]}" "$@" ../DOOM.CMD
