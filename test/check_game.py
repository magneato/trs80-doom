#!/usr/bin/env python3
"""test/check_game.py PRINTER_TXT WHAT - assertions on the game line (G) of a scripted run:
  combat     a sentinel fell (score >= 100: each kill adds 100) and bullets were spent (ammo < 50)
  autopilot  the cold mind reached the exit switch at least once (score >= 5000)"""
import sys
log, what = sys.argv[1], sys.argv[2]
games, ticks = [], []
for l in open(log, "rb").read().decode("latin-1").replace("\r", "\n").split("\n"):
    l = l.strip()
    if l.startswith("F"):
        f = l.split()
        k = [x for x in f if x.startswith("K")]
        if k: ticks.append((int(f[0][1:], 16), int(k[0][1:], 16)))
    if l.startswith("G"):
        games.append(dict(health=int(l[1:3], 16), ammo=int(l[3:5], 16), lives=int(l[5:7], 16), weapon=int(l[7:9], 16),
                          keys=int(l[9:11], 16), score=int(l[11:17])))
last = games[-1]
if what == "combat":
    ok = last["score"] >= 100 and last["ammo"] < 50
elif what == "autopilot":
    ok = max(g["score"] for g in games) >= 5000
else:
    raise SystemExit(f"unknown check {what}")
if len(ticks) >= 2 and ticks[-1][1] > ticks[0][1]:
    b0, k0 = ticks[0]; b1, k1 = ticks[-1]
    secs = 16.0 * (k1 - k0) / 4.055e6
    print(f"  {b1 - b0} breaths in {secs:.1f} s of Model 4 time (T-states / 4.055 MHz): "
          f"{(b1 - b0) / secs:.1f} breaths a second on average")
print(f"  {what}: {'PASS' if ok else 'FAIL'}  (last: health {last['health']} ammo {last['ammo']} lives {last['lives']} "
      f"score {last['score']:06d}; {len(games)} reports)")
sys.exit(0 if ok else 1)
