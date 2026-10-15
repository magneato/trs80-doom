#!/bin/bash
# ==============================================================================
# test/run_tests.sh - end-to-end proof, in trs80gp's Model 4 (headless, unthrottled, emulator extensions on):
#   1. the Freedoom reader: E1M1 rasterised onto the lattice (grid.py), the exit reachable
#   2. the forge gate: all 30 texture-shades (240 pages) the Z80 forges at boot, read back out of the banks,
#      against the Python forge, byte for byte
#   3. the twin gate: a scripted walk (STILL and MOVE layouts, turning, walking, a door); every glass the Model 4
#      paints is painted again by scripts/model.py from the same place and bearing and must match byte for byte;
#      the casting / painting T-states per breath are printed alongside
#   3b-3d. the south-east hall (figures), combat, and the autopilot reaching the exit switch
#   4. screenshots of a few views (screenshots/*.png)
# ==============================================================================
set -e -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/screenshots"
mkdir -p "$OUT"

echo "== 1. the Freedoom reader (gen_assets.py: E1M1 on the lattice, the exit reachable from the start)"
python3 scripts/gen_assets.py build | grep -E "autopilot|figures"

echo "== 2a. the tables gate: ray records, stature ledgers, quarter squares grown at boot from seeds"
test/run_one.sh test/tables.inc
python3 test/check_tables.py build build/run/trs80-printer.txt

echo "== 2b. the forge gate"
test/run_one.sh test/forge.inc
python3 test/check_forge.py build build/run/trs80-printer.txt

echo "== 2c. the figure gate: 36 figures forged at boot into banks 3, 2 and 1"
test/run_one.sh test/figures.inc
python3 test/check_figures.py build build/run/trs80-printer.txt

echo "== 3. the twin gate (a scripted walk)"
test/run_one.sh test/views.inc
python3 test/compare.py build build/run/trs80-printer.txt | tee "$OUT/timings.txt"

echo "== 3b. the twin gate in the south-east hall (figures: a zombieman, a shotgun guy, an imp)"
test/run_one.sh test/guards.inc
python3 test/compare.py build build/run/trs80-printer.txt | tee -a "$OUT/timings.txt"

echo "== 3c. combat: hold FIRE in the hall - sentinels fall, bullets are spent, the shots are heard"
SOUND=-mute test/run_one.sh test/combat.inc
python3 test/compare.py build build/run/trs80-printer.txt
python3 test/check_game.py build/run/trs80-printer.txt combat
python3 test/check_voice.py build/run
python3 - "$OUT" <<'PY'
import sys
from PIL import Image
for i, name in ((0, "04_the_hall"), (3, "05_combat")):
    Image.open(f"build/run/trs80-{i}.gif").convert("RGB").save(f"{sys.argv[1]}/{name}.png")
PY

echo "== 3d. the cold mind (T): 7000 breaths on its own - it must reach the exit switch (and the frame rate of real play)"
TIMEOUT=1200 test/run_one.sh test/autopilot.inc
python3 test/check_game.py build/run/trs80-printer.txt autopilot | tee "$OUT/fps.txt"

echo "== 4. screenshots"
test/run_one.sh test/shots.inc
python3 - "$OUT" <<'PY'
import sys
from PIL import Image
for i, name in enumerate(["01_start", "02_turned_left", "03_walking"]):
    Image.open(f"build/run/trs80-{i}.gif").convert("RGB").save(f"{sys.argv[1]}/{name}.png")
PY
ls "$OUT"
echo "== all tests passed"
