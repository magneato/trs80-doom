#!/usr/bin/env python3
"""test/check_tables.py BUILD_DIR PRINTER_TXT - the ledgers the boot builds from seeds (ray records, stature ledgers,
quarter squares: $C000-$E3FF in bank 1), read back out of the Model 4, against the Python reference"""
import sys
build, log = sys.argv[1], sys.argv[2]
ref = open(f"{build}/tables.bin", "rb").read()
lines = [l.strip() for l in open(log, "rb").read().decode("latin-1").replace("\r", "\n").split("\n") if l.strip()]
got = bytes.fromhex("".join(lines[lines.index("T") + 1:]))
names = [("ray records", 0, 4096), ("stature ledgers", 4096, 8192), ("quarter squares", 8192, 9216)]
bad = 0
for name, a, b in names:
    d = [i for i in range(a, b) if i >= len(got) or got[i] != ref[i]]
    print(f"  {name}: " + ("identical" if not d else f"{len(d)} bytes differ, first at ${0xC000 + d[0]:04X}"))
    bad += bool(d)
sys.exit(1 if bad else 0)
