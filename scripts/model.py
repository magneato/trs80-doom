#!/usr/bin/env python3
"""
model.py - the Python twin of the Z80 renderer.  Given the traveller's place and bearing it paints the 80 x 20
characters of the world exactly as doomm4.asm must: the same ray records, the same 8.8 grid walk, the same
texture-column arithmetic (low byte of t*dir), the same ledgers and compiled routine plans.

  model.py BUILD_DIR X Y ANGLE [out.png]     render one view (X, Y as 16-bit 8.8 hex or decimal)
  import model; model.Twin(build).render(x, y, ang) -> bytes(1600)
"""
import json, os, sys

PATTERNS = None
PAIR_K = [[0, 0, 1, 3], [0, 1, 2, 3], [0, 0, 1, 3]]   # [block row k][grey]: the glass-locked dither


def reach0(u, dd):
    """the first grid-line distance, as the Z80 forms it: dd normalised to 16 bits by z left shifts, its top byte m,
    then (u * m) >> z (one 8x8 multiply and a shift ladder instead of an 8x16 multiply)"""
    z = 0
    while not dd & 0x8000:
        dd <<= 1
        z += 1
    return (u * (dd >> 8)) >> z


class Twin:
    def __init__(self, build="build"):
        t = json.load(open(os.path.join(build, "twin.json")))
        self.t = t
        self.map = t["map"]
        self.rays = t["rays"]
        self.layouts = t["layouts"]
        self.ht = t["ht"]
        self.texloc = t["texloc"]
        self.plans = t["plans"]
        self.ceil = t["ceil"]
        self.floor = t["floor"]
        self.grey = t["tex_grey"]
        self.pat = t["patterns"]
        self.rows = t["VIEW_ROWS"]
        self.cols = t["COLS"]
        self.fig_plans = t["fig_plans"]
        self.fig_slot = t["fig_slot"]
        self.fsrt, self.fsw, self.fustep, self.fkq = t["fsrt"], t["fsw"], t["fustep"], t["fkq"]
        self.fig_pat = t["fig_pat"]
        self.fig_ink = t["fig_ink"]
        self.fig_tex = t["fig_tex"]
        self.objinit = t["objinit"]
        self.gz_ang, self.gz_tol = t["gz_ang"], t["gz_tol"]
        self.ts_grey = t["ts_grey"]                       # lattice code*2 + side -> the art shown (dim walls: shaded)

    def tex_char(self, ts, col, d):
        g = self.grey[ts][col]
        p, a = d >> 5, d & 31
        v = 0x80
        for k, off in enumerate(self.pat[p]):
            row = min(31, a + off)
            gv = g[row]
            bits = PAIR_K[k][gv]
            v |= bits << (2 * k)
        return v

    def cast(self, px, py, bearing, ray, layout="STILL"):
        """-> (ts, charcol, routine, side, t)"""
        off, cls, c0, w = self.layouts[layout][ray]
        ang = (bearing + off) & 511
        dirx, diry, ddx, ddy = self.rays[ang]
        xneg, yneg = dirx >= 0x8000, diry >= 0x8000
        fx, fy = px & 255, py & 255
        ux = fx if xneg else 255 - fx
        uy = fy if yneg else 255 - fy
        rx = reach0(ux, ddx)
        ry = reach0(uy, ddy)
        mx, my = px >> 8, py >> 8
        while True:
            if rx < ry:
                t = rx
                rx = (rx + ddx) & 0xFFFF
                mx += -1 if xneg else 1
                tile = self.map[my * 64 + mx]
                if tile:
                    side, other, d, flip = 0, fy, diry, 0 if xneg else 15
                    break
            else:
                t = ry
                ry = (ry + ddy) & 0xFFFF
                my += -1 if yneg else 1
                tile = self.map[my * 64 + mx]
                if tile:
                    side, other, d, flip = 1, fx, dirx, 15 if yneg else 0
                    break
        frac = (other + ((t * d) >> 8)) & 255
        col = (frac >> 4) ^ flip
        if t < 1024:
            rt = self.ht[cls][0][t >> 2]
        else:
            rt = self.ht[cls][1][min(255, (t - 1024) >> 6)]
        ts = self.ts_grey[tile * 2 + side]
        return ts, col, rt, side, t

    def fig_char(self, slot, x, a):
        tx = self.fig_tex[slot][x]
        v, op = 0x80, False
        for k, d in enumerate(self.fig_pat):
            row = min(31, a + d)
            c = tx[row]
            if c:
                op = True
                g = c - 1
                bits = PAIR_K[k][g]
                v |= bits << (2 * k)
        return v if op else 0

    def project(self, px, py, bearing, objs, survivors):
        """-> the draw list, far to near: (f16, stature, first col, last col, u0, ustep, slot), as the Z80 forms it"""
        def s16(v): return v - 65536 if v & 0x8000 else v
        dirx, diry = s16(self.rays[bearing][0]), s16(self.rays[bearing][1])
        cxs, cys = dirx >> 2, diry >> 2
        out = []
        for i in survivors:
            kind, fid, ox, oy = objs[i][0], objs[i][1], objs[i][2] * 256 + objs[i][3], objs[i][4] * 256 + objs[i][5]
            if kind == 0 or self.fig_slot[fid] == 255:
                continue
            ty, tx = objs[i][4] - (py >> 8) + 7, objs[i][2] - (px >> 8) + 7
            if 0 <= ty < 15 and 0 <= tx < 15:                # (moved since the cull: no verdict, project it)
                cell = ty * 15 + tx
                rel = (self.gz_ang[cell] - (bearing >> 1)) & 255
                if self.gz_tol[cell] != 255 and min(rel, 256 - rel) > self.gz_tol[cell]:
                    continue                                # the gaze pre-filter: well outside the view
            dx = ((ox - px) >> 4) & 255
            dy = ((oy - py) >> 4) & 255
            dx, dy = (dx - 256 if dx > 127 else dx), (dy - 256 if dy > 127 else dy)
            f16 = (dx * cxs + dy * cys) >> 6
            if not 4 <= f16 <= 127 or (kind != 3 and f16 > 96):
                continue
            l16 = (dy * cxs - dx * cys) >> 6
            if abs(l16) > f16:
                continue
            S, W, ust, kq = self.fsrt[f16], self.fsw[f16], self.fustep[f16], self.fkq[f16]
            off = abs(l16) * (kq >> 8) + ((abs(l16) * (kq & 255)) >> 8)
            cc = 40 + (off if l16 >= 0 else -off)
            c0 = cc - (W >> 1)
            c1 = c0 + W - 1
            if c1 < 0 or c0 > 79:
                continue
            u0 = 0
            if c0 < 0:
                u0 = ((-c0) * ust) & 0xFFFF
                c0 = 0
            out.append((f16, S, c0, min(c1, 79), u0, ust, self.fig_slot[fid]))
        return sorted(out, key=lambda e: -e[0])

    def zcols(self, px, py, bearing, layout):
        z = [0] * self.cols
        for ray, (off, cls, c0, w) in enumerate(self.layouts[layout]):
            rt = self.cast(px, py, bearing, ray, layout)[2]
            for c in range(c0, c0 + w): z[c] = rt
        return z

    def render(self, px, py, bearing, layout="STILL", objs=None, survivors=()):
        scr = bytearray(self.cols * self.rows)
        for ray, (off, cls, c0, w) in enumerate(self.layouts[layout]):
            ts, col, rt, side, t = self.cast(px, py, bearing, ray, layout)
            k, chars, f = self.plans[rt]
            for c in range(c0, c0 + w):
                for r in range(k):
                    scr[r * self.cols + c] = self.ceil
                for r, d, andm, orm in chars:
                    scr[r * self.cols + c] = (self.tex_char(ts, col, d) & andm) | orm
                for r in range(f, self.rows):
                    scr[r * self.cols + c] = self.floor[r]
        if objs is not None:
            z = self.zcols(px, py, bearing, layout)
            wide = layout != "STILL"
            for f16, S, c0, c1, uacc, ust, slot in self.project(px, py, bearing, objs, survivors):
                k, ents = self.fig_plans[S]
                c = c0
                while c <= c1:
                    u = min(15, uacc >> 8)
                    pair = wide and c < c1                  # moving: one texel sample paints two columns
                    if z[c] < S and self.fig_ink[slot] >> u & 1:
                        for n, a in enumerate(ents):
                            v = self.fig_char(slot, u, a)
                            if v:
                                for cc in ((c, c + 1) if pair else (c,)):
                                    scr[(k + n) * self.cols + cc] = v
                    uacc = (uacc + ust) & 0xFFFF
                    if pair:
                        uacc = (uacc + ust) & 0xFFFF
                        c += 2
                    else:
                        c += 1
        return bytes(scr)


def to_png(chars, cols, rows, path, scale=4):
    """draw an 80-column character glass (graphics characters only; text drawn as a grey cell)"""
    from PIL import Image
    w, h = cols * 2, rows * 3
    im = Image.new("RGB", (w, h))
    px = im.load()
    for r in range(rows):
        for c in range(cols):
            v = chars[r * cols + c]
            for k in range(3):
                for side in range(2):
                    if 128 <= v < 192:
                        on = (v >> (2 * k + side)) & 1
                        col = (235, 235, 235) if on else (0, 0, 0)
                    else:
                        col = (90, 90, 90) if v not in (32, 0) else (0, 0, 0)
                    px[2 * c + side, 3 * r + k] = col
    # block pixels are 1.67x taller than wide: scale 4 across, 6.67 down (4:3 overall)
    im.resize((w * scale, int(h * scale * 10 / 6)), Image.NEAREST).save(path)


if __name__ == "__main__":
    b, x, y, a = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), int(sys.argv[4], 0)
    tw = Twin(b)
    s = tw.render(x, y, a, sys.argv[6] if len(sys.argv) > 6 else "STILL")
    if len(sys.argv) > 5:
        to_png(s, tw.cols, tw.rows, sys.argv[5])
    print(s.hex())
