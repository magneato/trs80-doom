#!/bin/bash
# test/run_one.sh SCENARIO.inc [extra trs80gp args] - build a test variant, run it headless and unthrottled in trs80gp
# (Model 4, emulator extensions on), leave the printer log in build/run/trs80-printer.txt.
#   SOUND=-mute to keep audio alive for a recording test (default -sx: no host audio at all - trs80gp's PulseAudio
#   glue can abort on a busy host); an emulator abort (134) is retried once.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SC="$1"; shift
./build.sh --test "$SC" > build/test_build.log || { cat build/test_build.log; exit 1; }
mkdir -p build/run && cd build/run
[ -n "$WAYLAND_DISPLAY" ] && export GDK_BACKEND=x11      # trs80gp's GTK window segfaults under native Wayland
for attempt in 1 2; do
    rm -f trs80-*
    timeout "${TIMEOUT:-300}" "$ROOT/tools/trs80gp" -m4 -ee -batch -turbo ${SOUND:--sx} "$@" ../TEST.CMD > trs80gp.log 2>&1
    rc=$?
    [ $rc = 134 ] && { echo "  (trs80gp aborted - $(grep -m1 -o 'Assertion.*' trs80gp.log) - retrying)"; continue; }
    break
done
[ $rc = 0 ] || { echo "trs80gp exited with $rc (124 = timeout: the test never reached its end)"; exit 1; }
