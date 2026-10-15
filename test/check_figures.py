#!/usr/bin/env python3
"""test/check_figures.py BUILD_DIR PRINTER_TXT - the boot forge's figures (decor, pickups, the sentinels' frames), read
back out of their slots in banks 3, 2, 1 and lower memory, against the Python forge (build/figures.bin)"""
import sys
build, log = sys.argv[1], sys.argv[2]
ref = open(f"{build}/figures.bin", "rb").read()
lines = [l.strip() for l in open(log, "rb").read().decode("latin-1").replace("\r", "\n").split("\n") if l.strip()]
got, cur = {}, None
for l in lines:
    if l.startswith("S"): cur = int(l[1:], 16); got[cur] = b""
    elif cur is not None: got[cur] += bytes.fromhex(l)
bad = 0
for i in sorted(got):
    want = ref[i * 512:(i + 1) * 512]
    if got[i] != want:
        bad += 1
        d = [k for k in range(512) if got[i][k] != want[k]]
        print(f"  figure slot {i}: {len(d)} bytes differ, first at {d[0]} (m4 {got[i][d[0]]:#04x}, twin {want[d[0]]:#04x})")
print(f"  {len(got) - bad} of {len(got)} forged figures identical")
sys.exit(1 if bad or len(got) * 512 != len(ref) else 0)
