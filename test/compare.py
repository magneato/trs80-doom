#!/usr/bin/env python3
"""
test/compare.py - the gate: every glass the Model 4 sent to the printer is painted again by the Python twin
(scripts/model.py) from the place and bearing in the same report, and the 80 x 20 world characters must match
byte for byte.  Also prints the casting / painting T-states per breath.

  compare.py BUILD_DIR PRINTER_TXT [PNG_DIR]
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import model

build, log = sys.argv[1], sys.argv[2]
pngdir = sys.argv[3] if len(sys.argv) > 3 else None
tw = model.Twin(build)
lines = [l.strip() for l in open(log, "rb").read().decode("latin-1").replace("\r", "\n").split("\n") if l.strip()]

reports = []
i = 0
while i < len(lines):
    l = lines[i]
    if l.startswith("F"):
        f = l.split()
        rep = {"frame": int(f[0][1:], 16), "x": int(f[1][1:], 16), "y": int(f[2][1:], 16), "a": int(f[3][1:], 16),
               "cast": 16 * int(f[4][1:5], 16), "proj": 16 * int(f[4][5:9], 16),
               "draw": 16 * int(f[5][1:5], 16), "figs": 16 * int(f[5][5:9], 16), "painted": int(f[6][1:], 16), "glass": None,
               "layout": ["STILL", "MOVE", "FAST"][int(f[7][1:], 16)]}
        while i + 1 < len(lines) and lines[i + 1][:1] in ("V", "O", "D", "G"):
            l2 = lines.pop(i + 1)
            if l2[0] == "V":
                n = int(l2[1:3], 16)
                rep["survivors"] = list(bytes.fromhex(l2[3:3 + 2 * n]))
            elif l2[0] == "D":
                n = int(l2[1:3], 16); db_ = bytes.fromhex(l2[3:])
                rep["dlist"] = [(e[0], e[1], e[2], e[3], e[4] | e[5] << 8, e[6] | e[7] << 8, e[8]) for e in
                                (db_[10 * k:10 * k + 10] for k in range(n))]
            elif l2[0] == "G":
                rep["game"] = dict(health=int(l2[1:3], 16), ammo=int(l2[3:5], 16), lives=int(l2[5:7], 16),
                                   weapon=int(l2[7:9], 16), keys=int(l2[9:11], 16), score=int(l2[11:17]))
            elif l2[0] == "O":
                ob = bytes.fromhex(l2[1:])
                rep["objs"] = [ob[8 * k:8 * k + 8] for k in range(len(ob) // 8)]
        if i + 1 < len(lines) and lines[i + 1].startswith("R"):
            rb = bytes.fromhex(lines[i + 1][1:])
            rep["rays"] = [tuple(rb[5 * c:5 * c + 5]) for c in range(len(rb) // 5)]
            del lines[i + 1]
        if i + 24 < len(lines) + 1 and all(len(lines[i + 1 + k]) == 160 and not lines[i + 1 + k].startswith("F")
                                           for k in range(min(24, len(lines) - i - 1))) and len(lines) - i - 1 >= 24:
            rep["glass"] = bytes.fromhex("".join(lines[i + 1:i + 25]))
            i += 25
        else:
            i += 1
        reports.append(rep)
    else:
        i += 1

bad = 0
checked = 0
for n, r in enumerate(reports):
    msg = (f"  breath {r['frame']:4d}  x {r['x']/256:6.2f} y {r['y']/256:6.2f} a {r['a']:3d}   "
           f"{r['layout']:5s} cast {r['cast']:6d}  figures {r['proj']:6d}  walls {r['draw']:6d} ({r['painted']:2d} strips)  "
           f"paint figures {r['figs']:6d}  = {r['cast'] + r['proj'] + r['draw'] + r['figs']:6d} T")
    if r.get("rays"):
        for c, (port, ixh, ixl, rt, dirty) in enumerate(r["rays"][:len(tw.layouts[r["layout"]])]):
            ts, col, trt, side, t = tw.cast(r["x"], r["y"], r["a"], c, r["layout"])
            tport, tpage = tw.texloc[ts]
            ix = tpage * 256 + col * 96
            want = (tport, ix >> 8, ix & 255, trt)
            if (port, ixh, ixl, rt) != want:
                print(f"    ray {c}: m4 port {port:02X} IX {ixh:02X}{ixl:02X} routine {rt}  twin {want[0]:02X} "
                      f"IX {want[1]:02X}{want[2]:02X} routine {want[3]}  (t {t}, side {side})")
    if r.get("dlist") is not None and r.get("objs") is not None:
        tdl = tw.project(r["x"], r["y"], r["a"], r["objs"], r.get("survivors", ()))
        if [tuple(e) for e in tdl] != r["dlist"]:
            print(f"    draw list: m4 {r['dlist']}\n               twin {tdl}")
    if r["glass"] is not None:
        m4 = r["glass"][:tw.cols * tw.rows]
        twin = tw.render(r["x"], r["y"], r["a"], r["layout"], r.get("objs"), r.get("survivors", ()))
        checked += 1
        if m4 == twin:
            msg += "  IDENTICAL"
        else:
            bad += 1
            diffs = [k for k in range(len(twin)) if m4[k] != twin[k]]
            cols = sorted(set(k % tw.cols for k in diffs))
            msg += f"  DIFFERS in {len(diffs)} bytes, columns {cols[:12]}{'...' if len(cols) > 12 else ''}"
        if pngdir:
            os.makedirs(pngdir, exist_ok=True)
            model.to_png(r["glass"], tw.cols, 24, os.path.join(pngdir, f"m4_{n:02d}.png"))
            model.to_png(twin, tw.cols, tw.rows, os.path.join(pngdir, f"twin_{n:02d}.png"))
    if r.get("game"):
        g = r["game"]
        msg += f"  [health {g['health']} ammo {g['ammo']} lives {g['lives']} score {g['score']:06d}]"
    print(msg)
print(f"{checked - bad} of {checked} glasses identical to the twin")
sys.exit(1 if bad or not checked else 0)
