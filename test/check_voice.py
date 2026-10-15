#!/usr/bin/env python3
"""test/check_voice.py RUN_DIR - the speaker was recorded (trs80-N.wav): it must not be silent, and its loud stretches
(the shots) must add up to something like the expected bursts"""
import glob, sys, wave, array
f = sorted(glob.glob(f"{sys.argv[1]}/trs80-*.wav"))
if not f:
    print("  voice: FAIL (no recording)"); sys.exit(1)
w = wave.open(f[-1]); n = w.getnframes(); ch = w.getnchannels(); sr = w.getframerate()
a = array.array("b" if w.getsampwidth() == 1 else "h", w.readframes(n))[::ch]
m = sum(a) / len(a)
win = sr // 100                                           # 10 ms windows
loud = 0
for i in range(0, len(a) - win, win):
    seg = a[i:i + win]
    if max(seg) - min(seg) > 20: loud += 1
ok = loud >= 5
print(f"  voice: {'PASS' if ok else 'FAIL'}  ({n / sr:.1f} s recorded, {loud * 10} ms of it sounding)")
sys.exit(0 if ok else 1)
