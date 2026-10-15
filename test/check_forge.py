#!/usr/bin/env python3
"""test/check_forge.py BUILD_DIR PRINTER_TXT - the boot forge's 30 texture-shades (6 pages each), read back out of
the Model 4's banks, against the Python forge (build/forged.bin)"""
import sys
build, log = sys.argv[1], sys.argv[2]
ref = open(f"{build}/forged.bin", "rb").read()
lines = [l.strip() for l in open(log, "rb").read().decode("latin-1").replace("\r", "\n").split("\n") if l.strip()]
got, ts, bad, n = {}, None, 0, 0
for l in lines:
    if l.startswith("G"): ts = int(l[1:], 16); got[ts] = b""
    elif ts is not None: got[ts] += bytes.fromhex(l)
for ts in sorted(got):
    want = ref[ts * 1536:(ts + 1) * 1536]
    n += 1
    if got[ts] != want:
        bad += 1
        d = [i for i in range(1536) if i >= len(got[ts]) or got[ts][i] != want[i]]
        print(f"  texture-shade {ts}: {len(d)} bytes differ, first at offset {d[0]:#06x} "
              f"(m4 {got[ts][d[0]]:#04x}, twin {want[d[0]]:#04x})")
print(f"  {n - bad} of {n} forged texture-shades identical ({n * 6} pages)")
sys.exit(1 if bad or n != 30 else 0)
