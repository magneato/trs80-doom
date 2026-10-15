#!/usr/bin/env python3
"""test/profsum.py PRINTER_TXT - the PROF build's phase timers, per ray (minus ~180 T of timer overhead per mark)"""
import sys
names = ["setup", "reach init", "grid walk", "hit (texture column)", "stature+locator", "store+loop"]
for l in open(sys.argv[1], "rb").read().decode("latin-1").replace("\r", "\n").split("\n"):
    l = l.strip()
    if l.startswith("F"): print(l[:30])
    elif l.startswith("B"):
        v = [int(x[1:], 16) // 80 for x in l.split()]
        print("   " + ", ".join(f"{n} {x}" for n, x in zip(names, v)) + f"  | {sum(v)} T/ray")
