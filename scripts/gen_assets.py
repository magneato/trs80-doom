#!/usr/bin/env python3
"""
gen_assets.py - the build-time forge for DOOM on the TRS-80 Model 4.  It reads Freedoom's E1M1 (through wad.py and
grid.py, straight from the freedoom/ checkout: BSD-licensed data) and shapes everything the Z80 will swallow:

  equ.inc       constants shared with doomm4.asm and deeds.asm
  tables.inc    the strip layout, the texture locator, the compiled column routines and their ladders
  seeds.inc     the boot builders' seeds and the projection's ledgers (bank 1)
  hidata.inc    the bank-1 payload: the strided lattice, objects, the autopilot's way out, the raw 2-bit art
  twin.json     everything model.py needs to paint the same picture byte for byte
  preview_*.png what the Model 4 will really show

The glass: 80 x 24 characters; characters 128-191 are 2x3 blocks, so the world is 160 x 60 block pixels
(rows 0-19), with the gauge as text in rows 20-23.  A block pixel is 1.67 times taller than it is wide.

DOOM on a grid: E1M1 rasterised onto 64-unit cells by grid.py; walls 128 units
tall (two cells), the eye at mid-height; the sector light kept per wall (a wall that only dim rooms see shows its
shaded face on both sides); zombiemen, shotgun guys, imps and demons with their own frames, vitality and bite.

Rules applied:
  I    Reciprocal cache : 1/|dir| per angle and distance->stature are ledgers; no division at run time
  II   Shape of data    : the lattice is 64 x 64 bytes, so a ray steps a column with INC L, a row with an add;
                          a texture page holds a whole 2x3 character per byte, ready to store
  V    Identity         : ceiling and floor are runs of identical stores shared by every routine (ladders)
  VI   Fused path       : a wall column is ONE straight run: fetch the finished character, store, next row
  VII  Bresenham        : the forge picks, per character, the sampling pattern nearest the ideal texel rows
  IX   LUT precompute   : everything below is computed once, here
"""
import json, math, os, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OUT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "build"
MAPNAME = os.environ.get("DOOM_MAP", "e1m1")
os.makedirs(OUT, exist_ok=True)

# ----------------------------------------------------------------------------
# geometry
# ----------------------------------------------------------------------------
COLS, ROWS = 80, 24                 # the glass, in characters
VIEW_ROWS = 20                      # rows 0-19 show the world (60 block rows), 20-23 the gauge
VIEW_PX = VIEW_ROWS * 3             # 60
HORIZON = VIEW_PX // 2              # 30: walls are centred on it
ANGLES = 512                        # angle units per full turn
FOV_DEG = 66.0
FOCAL = 80.0 / math.tan(math.radians(FOV_DEG / 2))     # horizontal block pixels per unit of lateral/forward
ASPECT = (10.0 / 3.0 / 80.0) / (4.0 / 160.0)            # block pixel height / width on a 4:3 tube (640x240 dots)
KH_TILE = FOCAL / ASPECT                                # one tile of height (block rows) at one tile: ~74
KH = 2 * KH_TILE                                        # DOOM's walls are 128 units (two cells) tall
NCLS = 8                            # fisheye cosine classes
TEXW, TEXH = 16, 32                 # wall art: 16 columns (each one character wide on the glass) x 32 rows
NPAT = 3
PATTERNS = [(0, 2, 4), (0, 1, 1), (0, 0, 0)]   # texel-row offsets of a character's 3 block rows: the best 3 of 8
                                                # candidates by total sampling error over every compiled routine
COLBYTES = NPAT * 32                            # one texture column = 3 patterns x 32 rows = 96 bytes
SCREEN = 0xF800
PAD = 0x50

# memory map (Model 4, memory mode 2: RAM 0000-F3FF, keyboard F400, glass F800)
PORT_B1, PORT_B2, PORT_B3 = 0x86, 0xA6, 0xB6           # OUT ($84): mode 2 + 80 columns + upper 32K bank 1/2/3
MAP_BASE = 0x8000                   # bank 1: 64 x 64 bytes (cell = MAP_BASE + y*64 + x); $9000-$BFFF free
RAYS = 0xC000                       # bank 1: 512 x 8-byte ray records
HT_BASE = 0xD000                    # bank 1: NCLS x (near page, far page)
SQ_BASE = 0xE000                    # bank 1: quarter squares: lo 0..511 (2 pages), hi 0..511 (2 pages)
RAWTEX = 0xE400                     # bank 1: raw 2-bit art at load time; forged texture pages after boot
TEX_FIRST_PAGE = 0x80

# ----------------------------------------------------------------------------
# source art and the lattice: Freedoom's E1M1 on 64-unit cells (grid.py walks the BSP for every 8-unit point)
# ----------------------------------------------------------------------------
import wad, grid
G = grid.build(MAPNAME)
lev = G.level
PAL = wad.playpal()[0]

def lum(c):
    return 0.30 * c[0] + 0.59 * c[1] + 0.11 * c[2]

NWALL = 12                                            # codes 1-12: the 12 wall textures E1M1 shows most
SWITCH_CODE, DOOR_CODE, ELEV_CODE = 13, 14, 15        # the exit switch, a door, the second door look
NTEX = 15
DIM_BASE = 15                                         # codes 16-27: walls 1-12 as dim rooms see them
cells = [(i, t) for i, t in enumerate(G.tex) if t and G.kind[i] == grid.SOLID]
use = Counter(t for _, t in cells)
wall_names = [t for t, _ in use.most_common(NWALL)]
door_use = Counter(G.tex[i] for i in range(4096) if G.kind[i] == grid.DOOR and G.tex[i])
door_names = [t for t, _ in door_use.most_common(2)] or ["BIGDOOR2"]
while len(door_names) < 2:
    door_names.append(door_names[0])
switch_name = None
if G.exit:
    for ld in lev.linedefs:
        if ld.special in grid.EXIT_SPECIALS:
            sd = lev.sidedefs[ld.right]
            switch_name = next((t for t in (sd.middle, sd.lower, sd.upper) if t != "-"), None)
            break
TEX_NAMES = wall_names + [switch_name or "SW1EXIT"] + door_names
assert len(TEX_NAMES) == NTEX

def tex_face(name):
    """the 64 x 128 units of a texture a lattice face shows, tiled when the texture is smaller"""
    w, h, rows = wad.texture(name)
    return [[rows[y % h][x % w] for x in range(64)] for y in range(128)]

def grey_face(rows, unit_x=4, unit_y=4):
    """64 x 128 palette indices -> 16 x 32 mean luminances (4 x 4 units a texel)"""
    out = []
    for y in range(TEXH):
        out.append([sum(lum(PAL[rows[unit_y * y + yy][unit_x * x + xx] or 0]) for yy in range(unit_y) for xx in range(unit_x))
                    / (unit_x * unit_y) for x in range(TEXW)])
    return out

def soften(art, sigma=0.8):
    """a light Gaussian blur (wrapping, as the texture tiles): DOOM's art is busy at 4 x 4 units a texel, and per-
    texture thresholds would turn its grain into speckle; softened, the panels, lights and seams survive the 4 greys"""
    k = [math.exp(-d * d / (2 * sigma * sigma)) for d in range(-2, 3)]
    k = [v / sum(k) for v in k]
    h, w = len(art), len(art[0])
    a = [[sum(k[d + 2] * art[y][(x + d) % w] for d in range(-2, 3)) for x in range(w)] for y in range(h)]
    return [[sum(k[d + 2] * a[(y + d) % h][x] for d in range(-2, 3)) for x in range(w)] for y in range(h)]
lit_art = [soften(grey_face(tex_face(n))) for n in TEX_NAMES]
def _stats(art):
    v = [x for r in art for x in r]
    m = sum(v) / len(v)
    return m, (sum((x - m) ** 2 for x in v) / len(v)) ** 0.5
slot_stats = [_stats(a) for a in lit_art[:NWALL]]
slot_of = {n: i for i, n in enumerate(wall_names)}
for t in use:                                          # the rest borrow the slot that looks most like them in grey
    if t not in slot_of:
        m, sd = _stats(soften(grey_face(tex_face(t))))
        slot_of[t] = min(range(NWALL), key=lambda i: (slot_stats[i][0] - m) ** 2 + (slot_stats[i][1] - sd) ** 2)

mapb = bytearray(4096)
for i in range(4096):
    k = G.kind[i]
    if k == grid.OPEN:
        continue
    if k == grid.DOOR:
        mapb[i] = ELEV_CODE if G.tex[i] == door_names[1] and door_names[1] != door_names[0] else DOOR_CODE
    else:
        mapb[i] = 1 + slot_of.get(G.tex[i], 0)
if G.exit:
    ex, ey, _ = G.exit
    mapb[ey * 64 + ex] = SWITCH_CODE
for i in range(4096):                                  # the outer ring is always rock
    if i % 64 in (0, 63) or i // 64 in (0, 63):
        mapb[i] = mapb[i] or 1
# the sector light: a wall that only dim rooms see (its brightest open neighbour at light <= DIM_LIGHT) is drawn
# with its shaded face on both sides - the light costs a different texture locator entry, nothing at run time
DIM_LIGHT = 144
def _nbr_light(i):
    x, y = i % 64, i // 64
    ls = [G.light[n] for n in (i - 1, i + 1, i - 64, i + 64)
          if 0 <= n < 4096 and abs(n % 64 - x) + abs(n // 64 - y) == 1 and G.kind[n] == grid.OPEN]
    return max(ls) if ls else 255
NDIM = 0
for i in range(4096):
    if 1 <= mapb[i] <= NWALL and _nbr_light(i) <= DIM_LIGHT:
        mapb[i] += DIM_BASE
        NDIM += 1
NCODES = DIM_BASE + NWALL + 1                          # codes 0..27
START_X, START_Y = int(G.start[0]), int(G.start[1])
START_ANG = int(round(G.start[2] * ANGLES / 360.0)) % ANGLES
assert mapb[START_Y * 64 + START_X] == 0
dark_art = lit_art
def thresholds(art, qs):
    v = sorted(x for r in art for x in r)
    return [v[int(len(v) * q)] for q in qs]
# per texture: the lit art splits into 12/30/33/25 % (few black texels: on a black ceiling a dark wall would vanish
# into the void); the shaded art (y walls, dim rooms) keeps its own detail but leans darker (35/30/23/12 %), so the
# two faces of a corner still differ at a glance
THRESH = [(thresholds(l, (0.12, 0.42, 0.75)), thresholds(l, (0.35, 0.65, 0.88))) for l in lit_art]

def q4(v, th):
    return sum(1 for t in th if v >= t)

# tex_grey[ts][x][y]: ts = (code-1)*2 + shade (0 lit, 1 shaded, for y walls)
tex_grey = []
for t in range(NTEX):
    for shade in (0, 1):
        tex_grey.append([[q4(lit_art[t][y][x], THRESH[t][shade]) for y in range(TEXH)] for x in range(TEXW)])
NTS = len(tex_grey)
raw_tex = bytearray()
for g in tex_grey:                    # 4 texels per byte, column-major: ts*128 + x*8 + y/4, bits 7-6 = row y
    for x in range(TEXW):
        for y in range(0, TEXH, 4):
            b = 0
            for k in range(4):
                b = (b << 2) | g[x][y + k]
            raw_tex.append(b)
assert len(raw_tex) == NTS * 128
# the lattice code + side -> which texture-shade's art is shown (dim codes show the shaded face on both sides)
def ts_of(code, side):
    if code > DIM_BASE:
        return (code - DIM_BASE - 1) * 2 + 1
    return (code - 1) * 2 + side

PAIR_K = [[0, 0, 1, 3], [0, 1, 2, 3], [0, 0, 1, 3]]   # [block row k][grey g]: L = bit 0, R = bit 1

def pair_bits(g, k):
    """2 block pixels for grey level g in block row k of the character: the dither is locked to the glass (it does
    not follow the texel rows, which repeat on a near wall and would draw vertical stripes): grey 1 is one dot in
    the middle row, grey 2 a checker (L, R, L), grey 3 solid"""
    return PAIR_K[k][g]

def tex_char(g_col, a, pat):
    """the finished character for texture column g_col, base row a, pattern pat"""
    v = 0x80
    for k, d in enumerate(PATTERNS[pat]):
        row = min(TEXH - 1, a + d)
        v |= pair_bits(g_col[row], k) << (2 * k)
    return v

# texture-shade -> (bank port, first page): 6 pages each (16 columns x 96 bytes), 19 in bank 2, 11 in bank 3;
# the rest of bank 3 holds the figures
TS_PAGES = TEXW * COLBYTES // 256
TEXLOC = []
for ts in range(NTS):
    if ts < 19: TEXLOC.append((PORT_B2, TEX_FIRST_PAGE + ts * TS_PAGES))
    else: TEXLOC.append((PORT_B3, TEX_FIRST_PAGE + (ts - 19) * TS_PAGES))
SPR_FIRST_PAGE = TEX_FIRST_PAGE + (NTS - 19) * TS_PAGES     # bank 3, after the last texture-shade
assert TEX_FIRST_PAGE + 19 * TS_PAGES <= 0xF4

def forged_block(ts):
    """the 1536 bytes the boot forge writes for one texture-shade: 16 columns x 3 patterns x 32 rows"""
    out = bytearray()
    for x in range(TEXW):
        for p in range(NPAT):
            for a in range(TEXH):
                out.append(tex_char(tex_grey[ts][x], a, p))
    return bytes(out)

# ----------------------------------------------------------------------------
# ceiling and floor: the ceiling is dark, the floor a sparse dot field that thickens toward the traveller
# ----------------------------------------------------------------------------
FLOOR_LINES = sorted({int(HORIZON + KH / 2 / n) for n in (1.25, 1.5, 2, 2.5, 3, 4, 5, 6)})

def floor_bits(y):
    """block row y (>= HORIZON) -> its 2 pixel bits: dotted lines where the floor at 1.25 .. 6 tiles meets the glass,
    so they bunch toward the horizon like a receding floor (a row-constant floor cannot vary across columns)"""
    if y not in FLOOR_LINES: return 0
    return 1 if FLOOR_LINES.index(y) % 2 == 0 else 2

CEIL_CHAR = 0x80
FLOOR_CHAR = []
for r in range(VIEW_ROWS):
    v = 0x80
    for k in range(3):
        y = 3 * r + k
        if y >= HORIZON: v |= floor_bits(y) << (2 * k)
    FLOOR_CHAR.append(v)

# ----------------------------------------------------------------------------
# statures: the heights (block rows) that get a compiled routine.  Even heights up to the full view, then a
# geometric ladder of clipped statures for walls nearer than ~1.2 tiles.
# ----------------------------------------------------------------------------
STATURES = list(range(2, VIEW_PX + 1, 2))
h = VIEW_PX
while h < 300:
    h = int(round(h * 1.08 + 2)) & ~1
    STATURES.append(h)
NROUT = len(STATURES)

def tex_row(y, h):
    top = HORIZON - h // 2
    return max(0, min(TEXH - 1, int(math.floor((y - top + 0.5) * TEXH / h))))

def routine_plan(h):
    """-> (ceiling rows k, [(row, d, andmask, ormask)], first floor row) for stature h"""
    top, bot = HORIZON - h // 2, HORIZON - h // 2 + h       # wall covers block rows [top, bot)
    k = 0
    while k < VIEW_ROWS and 3 * k + 2 < top: k += 1           # characters wholly above the wall
    f = VIEW_ROWS
    while f > k and 3 * (f - 1) >= bot: f -= 1                # characters wholly below it
    chars = []
    for r in range(k, f):
        want, andm, orm = [], 0x80, 0
        for s in range(3):
            y = 3 * r + s
            if top <= y < bot:
                want.append((s, tex_row(y, h)))
                andm |= 3 << (2 * s)
            elif y >= bot:
                orm |= floor_bits(y) << (2 * s)
        best = None
        for p in range(NPAT):
            for a in range(TEXH):
                cost = sum((min(TEXH - 1, a + PATTERNS[p][s]) - row) ** 2 for s, row in want)
                if best is None or cost < best[0]:
                    best = (cost, p, a)
        _, p, a = best
        chars.append((r, p * 32 + a, andm, orm))
    if REFLECT:                                               # the polished floor: the wall's own texels, mirrored
        while f < VIEW_ROWS:                                  # about its foot, through a sparse dither
            ymid = 3 * f + 1
            depth = ymid - bot
            ym = bot - 1 - depth                              # the wall row this floor row mirrors
            if depth >= h * REFL_DEPTH or ym < top:
                break
            step = 2 if depth < h * REFL_NEAR else 4         # every other block row near the foot, one in four farther
            mask = sum(3 << (2 * s_) for s_ in range(3) if (3 * f + s_) % step == 0)
            orm = 0
            for s_ in range(3):
                orm |= floor_bits(3 * f + s_) << (2 * s_)
            chars.append((f, 2 * 32 + tex_row(ym, h), 0x80 | mask, orm & ~mask))   # pattern 2: one texel row
            f += 1
    return k, chars, f

# reflections (DOOM_REFLECT=0 turns them off): a reflected character shows the mirrored texels on whole block
# rows - every other block row near the wall's foot, one in four farther down (the eye blends them into a 50%, then
# 25% gloss) - and the floor's dots elsewhere.  Whole rows, because the texels' own dither is
# locked to the glass: a pixel checker would cancel it.  The reflection reaches REFL_DEPTH of the wall's height
# below its foot.  It is compiled into the column routines: one fetch and two logic ops per reflected row.
REFLECT = os.environ.get("DOOM_REFLECT", "1") != "0"
REFL_DEPTH, REFL_NEAR = 1.0, 0.5

PLANS = [routine_plan(h) for h in STATURES]

def emit_routines():
    """two sets: width 1 (rt_i, DE = 80) and width 2 (rw_i, DE = 79: each row stores, INC HL, stores again)"""
    s = []
    for w, tag in ((1, "rt"), (2, "rw")):
        step = 3 if w == 1 else 6
        dup = "" if w == 1 else "\n        inc     hl\n        ld      (hl),a"
        s.append(f"; ---- width {w}: ceiling ladder, {VIEW_ROWS} identical stores; enter at {tag}_ceil + {step}*(20-k) for k rows")
        s.append(f"{tag}_ceil:")
        for r in range(VIEW_ROWS):
            s.append(f"        ld      (hl),{CEIL_CHAR}" + ("" if w == 1 else f"\n        inc     hl\n        ld      (hl),{CEIL_CHAR}") +
                     "\n        add     hl,de")
        s.append("        ret")
        s.append(f"; ---- width {w}: floor ladder, one store per row; enter at {tag}_floor + {step}*r to paint rows r..19")
        s.append(f"{tag}_floor:")
        for r in range(VIEW_ROWS):
            s.append(f"        ld      (hl),{FLOOR_CHAR[r]}" + ("" if w == 1 else f"\n        inc     hl\n        ld      (hl),{FLOOR_CHAR[r]}") +
                     "\n        add     hl,de")
        s.append("        ret")
        for i, (h, (k, chars, f)) in enumerate(zip(STATURES, PLANS)):
            s.append(f"{tag}_{i}:                         ; stature {h}")
            if k:
                s.append(f"        call    {tag}_ceil+{step * (VIEW_ROWS - k)}")
            for r, d, andm, orm in chars:
                if andm == 0x80:                              # no texel shows (a sparse reflection row): a constant
                    s.append(f"        ld      (hl),{0x80 | orm}" + ("" if w == 1 else f"\n        inc     hl\n        ld      (hl),{0x80 | orm}") +
                             "\n        add     hl,de")
                    continue
                s.append(f"        ld      a,(ix+{d})")
                if andm != 0xFF and andm != 0x80 | 0x3F:
                    s.append(f"        and     {andm}")
                if orm:
                    s.append(f"        or      {orm}")
                s.append("        ld      (hl),a" + dup + "\n        add     hl,de")
            if f < VIEW_ROWS:
                s.append(f"        jp      {tag}_floor+{step * f}")
            else:
                s.append("        ret")
    return "\n".join(s) + "\n"

# ----------------------------------------------------------------------------
# the strips: one ray per character column; angle offset and fisheye class
# ----------------------------------------------------------------------------
def make_layout(widths):
    """rays = strips of the given widths (characters), left to right: (angle offset, fisheye class, column, width)"""
    assert sum(widths) == COLS
    out, c = [], 0
    for w in widths:
        x = 2 * c + w - 80                                       # block-pixel centre of the strip, from the middle
        off = int(round(math.atan(x / FOCAL) * ANGLES / (2 * math.pi)))
        cls = min(NCLS - 1, int(abs(x) / 80.0 * NCLS))
        out.append((off, cls, c, w))
        c += w
    return out
LAYOUTS = {"STILL": make_layout([1] * COLS)}          # 80 rays, one per character column
cos_by_cls = [[] for _ in range(NCLS)]
for lay in LAYOUTS.values():
    for off, cls, c, w in lay:
        cos_by_cls[cls].append(math.cos(2 * math.pi * off / ANGLES))
COSV = [sum(v) / len(v) for v in cos_by_cls]

# ----------------------------------------------------------------------------
# ray records and the distance->stature ledgers
# ----------------------------------------------------------------------------
def ray_record(n):
    a = 2 * math.pi * n / ANGLES
    dx = int(round(math.cos(a) * 256)); dy = int(round(math.sin(a) * 256))
    def delta(d): return 0xFFFF if d == 0 else min(0xFFFF, int(round(65536.0 / abs(d))))
    return [dx & 0xFFFF, dy & 0xFFFF, delta(dx), delta(dy)]
RAYREC = [ray_record(n) for n in range(ANGLES)]

def nearest_stature(hpx):
    return min(range(NROUT), key=lambda i: (abs(STATURES[i] - hpx), i))

HT = []                               # HT[cls][page 0 near / 1 far][i] = routine index
for k in range(NCLS):
    pages = []
    for far in (0, 1):
        row = []
        for i in range(256):
            t = (i + 0.5) / 64.0 if not far else 4.0 + (i + 0.5) / 4.0
            perp = max(t * COSV[k], 0.05)
            row.append(nearest_stature(KH / perp))
        pages.append(row)
    HT.append(pages)

SQ = [n * n // 4 for n in range(512)]

# ---- seeds for the boot builders (the boot is the build): the Z80 rebuilds RAYS, HT and SQ from these ----
COSTAB = [int(round(256 * math.cos(2 * math.pi * i / ANGLES))) for i in range(ANGLES // 4 + 1)]
RCP256 = [0xFFFF] + [min(0xFFFF, int(round(65536.0 / v))) for v in range(1, 257)]
def cosq(n):
    n %= ANGLES
    if n <= 128: return COSTAB[n]
    if n <= 256: return -COSTAB[256 - n]
    if n <= 384: return -COSTAB[n - 256]
    return COSTAB[512 - n]
for n in range(ANGLES):                       # the boot construction must reproduce the reference exactly
    dx, dy = cosq(n), cosq(n - 128)
    assert [dx & 0xFFFF, dy & 0xFFFF, RCP256[abs(dx)], RCP256[abs(dy)]] == RAYREC[n], n
HT_SEED = bytearray()                         # per ledger row: first value, change count, (index, new value)...
for k in range(NCLS):
    for far in (0, 1):
        row = HT[k][far]
        ch = [(i, row[i]) for i in range(1, 256) if row[i] != row[i - 1]]
        HT_SEED += bytes([row[0], len(ch)]) + b"".join(bytes(c) for c in ch)
TABLES_REF = b"".join(bytes([w & 255, w >> 8]) for rec in RAYREC for w in rec) + \
             b"".join(bytes(HT[k][far]) for k in range(NCLS) for far in (0, 1)) + \
             bytes(v & 255 for v in SQ) + bytes(v >> 8 for v in SQ)

# ----------------------------------------------------------------------------
# FIGURES: pickups, decor and the four kinds of sentinel.  4-bit texels on disk (0 transparent, 1-4 = opaque grey
# 0-3), 16 columns x 32 rows over a 64 x 128-unit canvas (4 x 4 units a texel, feet on the bottom edge, so a figure
# stands on the floor of a wall-high canvas); the boot forges each into 512 bytes: per column, per base row a, the
# finished character for ONE sampling pattern, or 0 where all three block rows are transparent.
#   figure ids 0..15   still objects (0-7 pickups, the rest decor)
#   figure ids 48 + 16 * kind + frame: a sentinel, kind 0 zombieman, 1 shotgun guy, 2 imp, 3 demon; frame 0 stand,
#   1-4 walk, 5-6 attack, 7 pain, 8-10 dying, 11 dead (deeds.asm keeps the kind in the id's high nibble)
# ----------------------------------------------------------------------------
STILLS = [  # id: (sprite, DOOM things shown with it, pickup?, blocks the way?)
    ("BON1A0", (2014,), True, False),        # 0 health bonus
    ("STIMA0", (2011,), True, False),        # 1 stimpack
    ("MEDIA0", (2012,), True, False),        # 2 medikit
    ("CLIPA0", (2007, 2048, 2047, 2010), True, False),   # 3 clip (and the boxes and cells: one ammo for all)
    ("SHELA0", (2008, 2049), True, False),   # 4 shells
    ("BON2A0", (2015,), True, False),        # 5 armour bonus
    ("ARM1A0", (2018, 2019), True, False),   # 6 armour
    ("BKEYA0", (5, 13, 6, 40, 38, 39), True, False),     # 7 a keycard
    ("BAR1A0", (2035,), False, True),        # 8 barrel
    ("SMITA0", (47,), False, True),          # 9 stalagmite
    ("TRE2A0", (54, 43), False, True),       # 10 trees
    ("COLUA0", (2028, 48, 85, 86), False, True),         # 11 lamps and the tech column
]
KINDS = ["POSS", "SPOS", "TROO", "SARG"]
KIND_OF = {3004: 0, 9: 1, 3001: 2, 3002: 3, 58: 3}
KIND_HP = [20, 30, 60, 150]
CORPSE_OF = {18: 0, 15: 0, 19: 1, 20: 2, 21: 3}     # DOOM's dead things: the matching sentinel's last frame
#                stand walk  attack pain die dead   (front views; 6 distinct pictures a kind)
KIND_FRAMES = {"POSS": "AABAB" "EE" "G" "GJJ" "L",
               "SPOS": "AABAB" "EE" "G" "GJJ" "L",
               "TROO": "AABAB" "FF" "H" "HKK" "M",
               "SARG": "AABAB" "FF" "H" "HLL" "N"}
F_STAND, F_WALK, F_SHOOT, F_PAIN, F_DIE, F_DEAD = 0, 1, 5, 7, 8, 11
G_STAND, G_WALK, G_SHOOT, G_PAIN, G_DIE, G_DEAD = (48 + f for f in (F_STAND, F_WALK, F_SHOOT, F_PAIN, F_DIE, F_DEAD))
NFIG_IDS = 48 + 16 * len(KINDS)

def front(lump):
    """a front view: the rotation-1 lump, or the rotation-0 one (corpses, items)"""
    offs = wad.sprite_offsets()
    for n in (lump[:5] + "1", lump[:5] + "0"):
        if n in offs:
            return n
    raise KeyError(lump)

FIG_SPRITE = {i: s for i, (s, _, _, _) in enumerate(STILLS)}
for k, m in enumerate(KINDS):
    for f, letter in enumerate(KIND_FRAMES[m]):
        FIG_SPRITE[48 + 16 * k + f] = front(m + letter + "1")
CHUNKS = sorted(set(FIG_SPRITE.values()), key=lambda n: min(i for i, s in FIG_SPRITE.items() if s == n))
NSPR = len(CHUNKS)
assert NSPR <= 36, NSPR
RAWSPR = 0xC000                                       # bank 1 at load time (the ledgers are built there after the forge)
SLOTS = [(PORT_B3, SPR_FIRST_PAGE + 2 * i) for i in range((0xF4 - SPR_FIRST_PAGE) // 2)] + \
        [(PORT_B2, 0xF2)] + [(PORT_B1, 0xE4 + 2 * i) for i in range(8)] + [(PORT_B1, 0xBC), (PORT_B1, 0xBE)]
assert len(SLOTS) >= NSPR, (len(SLOTS), NSPR)
SLOTS = SLOTS[:NSPR]
FIGSLOT = [CHUNKS.index(FIG_SPRITE[i]) if i in FIG_SPRITE else 255 for i in range(NFIG_IDS)]

def figure_texels(name):
    w, h, xo, yo, rows = wad.sprite(name)
    canvas = [[None] * 64 for _ in range(128)]        # 64 x 128 units, the origin at the bottom middle
    for y in range(h):
        cy = 128 - yo + y
        if not 0 <= cy < 128: continue
        for x in range(w):
            cx = 32 - xo + x
            if 0 <= cx < 64 and rows[y][x] is not None:
                canvas[cy][cx] = rows[y][x]
    out, lums = [], []                                # out[x][y]: None transparent, else the mean luminance
    for x in range(TEXW):
        col = []
        for y in range(TEXH):
            op = [lum(PAL[canvas[4 * y + yy][4 * x + xx]]) for yy in range(4) for xx in range(4)
                  if canvas[4 * y + yy][4 * x + xx] is not None]
            col.append(sum(op) / len(op) if len(op) >= 6 else None)
            if col[-1] is not None: lums.append(col[-1])
        out.append(col)
    return out, lums
fig_lum = [figure_texels(c) for c in CHUNKS]
_all = sorted(v for _, l in fig_lum for v in l)
FIG_THRESH = [_all[int(len(_all) * q)] for q in (0.25, 0.50, 0.75)]
fig_tex = [[[0 if v is None else 1 + sum(1 for t in FIG_THRESH if v >= t) for v in col] for col in tx] for tx, _ in fig_lum]
raw_spr = bytearray()
for tx in fig_tex:                                    # column-major, 2 texels a byte (high nibble = upper row)
    for x in range(TEXW):
        for y in range(0, TEXH, 2):
            raw_spr.append((tx[x][y] << 4) | tx[x][y + 1])
assert len(raw_spr) == NSPR * 256 and RAWSPR + len(raw_spr) <= RAWTEX

def fig_plan(h, pat):
    """sprite plan for stature h: first row k and the base texel row a of each whole character row k.. - a figure
    is snapped to whole characters (a row belongs to it when its middle block row does), so no row is partial"""
    top, bot = HORIZON - h // 2, HORIZON - h // 2 + h
    rows = [r for r in range(VIEW_ROWS) if top <= 3 * r + 1 < bot]
    if not rows:
        rows = [min(VIEW_ROWS - 1, max(0, (HORIZON - 1) // 3))]
    ents, err = [], 0
    for r in rows:
        want = [(s_, tex_row(min(max(3 * r + s_, top), bot - 1), h)) for s_ in range(3)]
        best = min((sum((min(TEXH - 1, a + pat[s_]) - row) ** 2 for s_, row in want), a) for a in range(TEXH))
        err += best[0]
        ents.append(best[1])
    return rows[0], ents, err
FIG_PAT = min(PATTERNS + [(0, 1, 2), (0, 0, 1)], key=lambda pt: sum(fig_plan(h, pt)[2] for h in STATURES))
FIG_PLANS = [fig_plan(h, FIG_PAT)[:2] for h in STATURES]

def fig_char(tx_col, a):
    v, op = 0x80, False
    for k_, d in enumerate(FIG_PAT):
        row = min(TEXH - 1, a + d)
        c = tx_col[row]
        if c:
            op = True
            v |= pair_bits(c - 1, k_) << (2 * k_)
    return v if op else 0

def forged_figure(i):
    return bytes(fig_char(fig_tex[i][x], a) for x in range(TEXW) for a in range(TEXH))

# the gaze pre-filter: per tile offset (-7..7)^2 its direction (256 to a turn) and a tolerance (half the field of
# view + the figure's half width + the traveller's position inside his tile); 255 = always project
GZ_ANG, GZ_TOL = [], []
for ty in range(-7, 8):
    for tx in range(-7, 8):
        d = math.hypot(tx, ty)
        GZ_ANG.append(int(round(math.atan2(ty, tx) * 128 / math.pi)) & 255)
        if max(abs(tx), abs(ty)) <= 1:
            GZ_TOL.append(255)
        else:
            extra = math.atan2(0.5 + 0.75, max(d - 0.75, 0.25))
            GZ_TOL.append(min(255, int(math.ceil((math.radians(FOV_DEG / 2) + extra) * 128 / math.pi)) + 2))

FIG_INK = [sum(1 << x for x in range(TEXW) if any(fig_char(fig_tex[i][x], a) for a in range(TEXH))) for i in range(NSPR)]

# projection ledgers, indexed by forward distance f16 (1/16 tile, 4..127)
def _fh(f16): return KH * 16.0 / max(f16, 1)
FSRT = [nearest_stature(_fh(f)) for f in range(128)]
FSW = [max(1, min(255, int(round(FOCAL / 2 * 16.0 / max(f, 1))))) for f in range(128)]
FUSTEP = [min(0xFFFF, int(round(TEXW * 256.0 / FSW[f]))) for f in range(128)]
FKQ = [min(0xFFFF, int(round(FOCAL / 2 * 256.0 / max(f, 1)))) for f in range(128)]

# objects from E1M1's things: sentinels, pickups, decor, corpses - 8-byte object records
# (kind, figure id, x tile, x frac, y tile, y frac, vitality, state)
STILL_OF = {t: i for i, (_, things, _, _) in enumerate(STILLS) for t in things}
objs, blockmap = [], bytearray(512)
for typ, fx, fy, _ in G.things:
    x, y = int(fx), int(fy)
    if not (0 < x < 63 and 0 < y < 63) or mapb[y * 64 + x]:
        continue                                      # things the lattice put inside rock
    xf, yf = int((fx - x) * 256) & 255, int((fy - y) * 256) & 255
    if typ in KIND_OF:
        k = KIND_OF[typ]
        objs.append((3, 48 + 16 * k, x, xf, y, yf, KIND_HP[k], 0))
    elif typ in STILL_OF:
        i = STILL_OF[typ]
        _, _, pick, blocks = STILLS[i]
        objs.append((2 if pick else 1, i, x, 0x80 if pick else xf, y, 0x80 if pick else yf, 0, 0))
        if blocks:
            blockmap[(y * 64 + x) >> 3] |= 1 << ((y * 64 + x) & 7)
    elif typ in CORPSE_OF:
        objs.append((1, 48 + 16 * CORPSE_OF[typ] + F_DEAD, x, xf, y, yf, 0, 0))
NOBJ_MAX = 136
objs.sort(key=lambda o: (o[0] != 3, o[0] == 1, o[4], o[2]))     # sentinels, pickups, then decor
while len(objs) > NOBJ_MAX:                           # too many: drop decor first
    objs.pop()
objs.sort(key=lambda o: (o[0] != 3, o[4], o[2]))     # sentinels first, then the statics by row
NGUARD = sum(1 for o in objs if o[0] == 3)
OBJ_BASE, BLOCKMAP = 0x9000, 0x9000 + NOBJ_MAX * 8          # bank 1: $9000-$963F
DIRFIELD = 0x9640                     # bank 1: the autopilot's way to the exit, 2 bits a cell (1 KB)
OVL_SRC = 0x9A40                      # bank 1 at load: the run-time overlay (copied to $2000 first thing at boot),
                                      # then the resident code that only ever runs with bank 1 in view, up to $BC00
                                      # (two figure slots are forged at $BC00-$BFFF)
YSTART = [next((i for i, o in enumerate(objs) if i >= NGUARD and o[4] >= y), len(objs)) for y in range(65)]
# ---- the gauge's face: the marine as a 12 x 9 block-pixel icon (6 x 3 characters), one per health band.  At this
#      size a dithered picture of DOOM's face reads as a blob, so it is drawn by hand: hair, a frown and open eyes
#      when healthy, more bruises (dark pixels) band by band, crossed eyes when dead.
FACE_W, FACE_H = 6, 3
_FACE = ["..########..",
         ".#..#..#..#.",
         "#.########.#",
         "##..####..##",
         "##.#.##.#.##",
         "#####..#####",
         ".##.####.##.",
         "..##....##..",
         "...######..."]
_BRUISES = [(2, 3), (9, 4), (4, 1), (7, 5), (3, 6), (8, 2), (5, 7), (6, 4), (10, 2), (1, 4), (8, 7), (3, 2)]
def face_bits(band):
    rows = [list(r) for r in _FACE]
    if band == 7:                                       # dead: crossed eyes, a flat mouth
        for y, x in ((3, 3), (3, 8)): rows[y][x] = "#"
        for x in (3, 4, 7, 8): rows[2][x] = "."; rows[4][x] = "."
        rows[6] = list("..########..")
    else:
        for x, y in _BRUISES[:2 * band]: rows[y][x] = "."
    out = []
    for cy in range(FACE_H):
        for cx in range(FACE_W):
            v = 0x80
            for k in range(3):
                for side in range(2):
                    if rows[3 * cy + k][2 * cx + side] == "#": v |= 1 << (2 * k + side)
            out.append(v)
    return out
FACES = [face_bits(b) for b in range(8)]

# ---- the voices: the Model 4's one-bit speaker (port $90).  Each voice is a list of segments (kind, half-period,
#      its change per half-period, half-periods): kind 1 = a tone (sweeping), 2 = noise (a random bit each half-period).
#      Half-periods are in delay-loop units (about 15 T-states, ~3.7 us at 4 MHz).  Played whole at the end of a
#      breath (there is no timer to play them behind the picture), so they are kept short.
UNIT_T = 27.0                                         # T-states per delay-loop step (NOP, NOP, DJNZ on a Model 4)
def _p16(f): return int(round(4.055e6 / UNIT_T / (2 * f) * 16))   # half-period, 1/16 steps
def _tone(f0, f1, ms):
    n = max(1, int(ms / 1000.0 * (f0 + f1)))           # half-periods
    p0, p1 = _p16(f0), _p16(f1)
    return [(1, p0, int((p1 - p0) / n) if n > 1 else 0, n)]
def _noise(f, ms):
    return [(2, _p16(f), 0, max(1, int(ms / 1000.0 * 2 * f)))]
VOICES = [
    ("SND_FIST",     _noise(3000, 6)),
    ("SND_PISTOL",   _noise(2500, 18) + _noise(900, 10)),
    ("SND_SHOTGUN",  _noise(1800, 30) + _noise(700, 25)),
    ("SND_CHAIN",    _noise(2600, 8)),
    ("SND_SIGHT0",   _tone(380, 330, 60) + _noise(500, 30)),          # a zombie's grunt
    ("SND_SIGHT1",   _tone(350, 310, 70) + _noise(450, 35)),
    ("SND_SIGHT2",   _tone(1200, 1700, 50) + _tone(1700, 900, 60)),   # the imp's screech
    ("SND_SIGHT3",   _noise(400, 70) + _tone(340, 300, 50)),          # the demon's growl
    ("SND_MFIRE",    _noise(1400, 16) + _noise(600, 10)),             # a sentinel's shot
    ("SND_FIREBALL", _tone(400, 900, 60)),
    ("SND_BITE",     _noise(700, 25)),
    ("SND_DEATH1",   _tone(560, 320, 110)),
    ("SND_DEATH2",   _tone(1100, 300, 120)),
    ("SND_PLDEATH",  _tone(700, 300, 240) + _noise(400, 60)),
    ("SND_DOOR",     _noise(400, 30) + _tone(330, 310, 20)),
    ("SND_LEVEL",    _noise(900, 20) + _tone(523, 523, 50) + _tone(659, 659, 50) + _tone(784, 784, 90)),
    ("SND_ITEM",     _tone(1500, 1900, 20)),
    ("SND_HEALTH",   _tone(900, 1300, 40)),
    ("SND_AMMO",     _tone(1500, 1500, 15) + _tone(2000, 2000, 15)),
    ("SND_ARMOR",    _tone(700, 1100, 40)),
    ("SND_WEAPON",   _tone(700, 1400, 60)),
    ("SND_KEY",      _tone(1800, 1800, 20) + _tone(2400, 2400, 20)),
]
for _, segs in VOICES:
    for kind, p0, dp, n in segs:
        assert 32 <= p0 < 4096 and -128 <= dp <= 127 and 1 <= n <= 65535 and 32 <= p0 + dp * (n - 1) < 4096, segs

# ---- the exit switch, the doors, and the autopilot's way out (breadth-first, done here instead of at run time) ----
from collections import deque
def _blocked(i): return blockmap[i >> 3] >> (i & 7) & 1
def passable(n): return 0 <= n < 4096 and (mapb[n] in (0, DOOR_CODE, ELEV_CODE)) and not (mapb[n] == 0 and _blocked(n))
START_IDX = START_Y * 64 + START_X
reach = {START_IDX: 0}; dq = deque([START_IDX])
while dq:
    c = dq.popleft()
    for n in (c + 1, c - 1, c + 64, c - 64):
        if passable(n) and n not in reach: reach[n] = reach[c] + 1; dq.append(n)
cands = []
for i, t in enumerate(mapb):
    if t != SWITCH_CODE: continue
    ex, ey = i % 64, i // 64
    for (dx, dy), ang in (((1, 0), 256), ((0, 1), 384), ((-1, 0), 0), ((0, -1), 128)):   # stand E/S/W/N of it, facing it
        nx, ny = ex + dx, ey + dy
        if (ny * 64 + nx) in reach: cands.append((reach[ny * 64 + nx], nx, ny, ang))
assert cands, "no reachable exit switch"
_, GOAL_X, GOAL_Y, GOAL_ANG = max(cands)
DOOR_TILES = [i for i, t in enumerate(mapb) if t in (DOOR_CODE, ELEV_CODE)]
DOOR_KIND = [mapb[i] for i in DOOR_TILES]
dist = {GOAL_Y * 64 + GOAL_X: 0}; dq = deque([GOAL_Y * 64 + GOAL_X])
while dq:
    c = dq.popleft()
    for n in (c + 1, c - 1, c + 64, c - 64):
        if passable(n) and n not in dist: dist[n] = dist[c] + 1; dq.append(n)
assert START_IDX in dist
# per cell, 2 bits: the step toward the goal (0 east, 1 south, 2 west, 3 north); the goal cell itself is GOAL_X/GOAL_Y
dirfield = bytearray(1024)
for c, d in dist.items():
    if d == 0: continue
    best = min((dist.get(n, 999), k) for k, n in enumerate((c + 1, c + 64, c - 1, c - 64)))[1]
    dirfield[c >> 2] |= best << (2 * (c & 3))
AI_INFO = f"goal ({GOAL_X},{GOAL_Y}) facing {GOAL_ANG}; start->goal {dist[START_IDX]} steps; {len(DOOR_TILES)} doors"

objinit = b"".join(bytes(o) for o in objs)
objinit += bytes((NOBJ_MAX - len(objs)) * 8)

# ----------------------------------------------------------------------------
# emit
# ----------------------------------------------------------------------------
def db(data, per=16):
    data = list(data)
    return "".join("        defb    " + ",".join(str(b) for b in data[i:i + per]) + "\n" for i in range(0, len(data), per))

def dw(words, per=8):
    words = list(words)
    return "".join("        defw    " + ",".join(str(w & 0xFFFF) for w in words[i:i + per]) + "\n" for i in range(0, len(words), per))

with open(os.path.join(OUT, "equ.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    vals = [("COLS", COLS), ("VIEW_ROWS", VIEW_ROWS), ("SCREEN", SCREEN), ("ANGLES", ANGLES), ("NROUT", NROUT),
            ("PORT_B1", PORT_B1), ("PORT_B2", PORT_B2), ("PORT_B3", PORT_B3), ("MAP_BASE", MAP_BASE), ("RAYS", RAYS),
            ("HT_BASE", HT_BASE), ("SQ_BASE", SQ_BASE), ("RAWTEX", RAWTEX), ("RAWTEX_LEN", len(raw_tex)),
            ("NTS", NTS), ("NSPR", NSPR), ("RAWSPR", RAWSPR), ("OBJ", OBJ_BASE), ("NOBJ", NOBJ_MAX), ("NGUARD", NGUARD),
            ("BLOCKMAP", BLOCKMAP), ("GOAL_X", GOAL_X), ("GOAL_Y", GOAL_Y), ("GOAL_ANG", GOAL_ANG), ("NDOORS", len(DOOR_TILES)), ("DIRFIELD", DIRFIELD), ("OVL_SRC", OVL_SRC), ("G_STAND", G_STAND), ("G_WALK", G_WALK), ("G_SHOOT", G_SHOOT), ("G_PAIN", G_PAIN),
            ("G_DIE", G_DIE), ("G_DEAD", G_DEAD), ("TS_PAGES", TS_PAGES), ("SPR_FIRST_PAGE", SPR_FIRST_PAGE), ("START_X", START_X), ("START_Y", START_Y), ("START_ANG", START_ANG),
            ("DOOR_CODE", DOOR_CODE), ("ELEV_CODE", ELEV_CODE), ("SWITCH_CODE", SWITCH_CODE), ("PAD", PAD),
            ("DIM_BASE", DIM_BASE), ("NCODES", NCODES), ("NFIG_IDS", NFIG_IDS), ("F_STAND", F_STAND), ("F_WALK", F_WALK),
            ("F_SHOOT", F_SHOOT), ("F_PAIN", F_PAIN), ("F_DIE", F_DIE), ("F_DEAD", F_DEAD), ("NVOICES", len(VOICES))]
    vals += [(name, i + 1) for i, (name, _) in enumerate(VOICES)]
    for k, v in vals:
        f.write(f"{k:<16}equ     {v}\n")

with open(os.path.join(OUT, "tables.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write("; strip layouts, one page per field indexed by ray: angle offset * 8 (lo, hi), near-ledger page,\n")
    f.write("; first column, routine-table page (width)\n")
    LOFS = {"STILL": 0}                                       # the layout's offset in each field's page
    def field(fn):
        page = [0] * 256
        for name, lay in LAYOUTS.items():
            for i, e in enumerate(lay): page[LOFS[name] + i] = fn(*e)
        return page
    f.write("lay_ol:\n" + db(field(lambda o, c, col, w: (o * 8) & 0xFF)))
    f.write("lay_oh:\n" + db(field(lambda o, c, col, w: ((o * 8) >> 8) & 0xFF)))
    f.write("lay_c:\n" + db(field(lambda o, c, col, w: (HT_BASE >> 8) + 2 * c)))
    f.write("lay_col:\n" + db(field(lambda o, c, col, w: col)))
    f.write("lay_w:\n" + "".join(f"        defb    {'rt_table' if e[3] == 1 else 'rw_table'}/256\n"
                                   for e in (next((lay[i - LOFS[nm]] for nm, lay in LAYOUTS.items()
                                                   if 0 <= i - LOFS[nm] < len(lay)), (0, 0, 0, 2)) for i in range(256))))
    for name, lay in LAYOUTS.items():
        f.write(f"NRAYS_{name:<10}equ     {len(lay)}\nLOFS_{name:<11}equ     {LOFS[name]}\n")
    f.write("rw_table:\n" + "".join(f"        defw    rw_{i}\n" for i in range(NROUT)) + "        org     rw_table+256\n")
    f.write("rt_table:\n" + "".join(f"        defw    rt_{i}\n" for i in range(NROUT)) + "        org     rt_table+256\n")
    assert 2 * NROUT <= 256
    f.write("; texture column offsets (x * 96): high bytes at texcol, low bytes at texcol+16\n")
    f.write("texcol:\n" + db((x * COLBYTES) >> 8 for x in range(TEXW)) + db((x * COLBYTES) & 255 for x in range(TEXW)))
    f.write("; texture locator: index code*2+shade -> bank port, first page (code 0 unused)\n")
    f.write("texloc:\n        defb    0,0,0,0\n")
    for port, page in TEXLOC:
        f.write(f"        defb    {port},{page}\n")
    f.write("; dim walls (codes DIM_BASE+1..): both sides show the shaded art of wall code - DIM_BASE\n")
    for c in range(DIM_BASE + 1, NCODES):
        for side in (0, 1):
            port, page = TEXLOC[ts_of(c, side)]
            f.write(f"        defb    {port},{page}\n")
    f.write("; figures: slot -> bank port (0 = lower memory), first page; figure id -> slot ($FF none)\n")
    f.write("fig_slots:\n" + "".join(f"        defb    {pt},{pg}\n" for pt, pg in SLOTS))
    f.write("; figure plans per stature: first row, rows, then each row's base texel row\n")
    f.write("fp_table:\n" + "".join(f"        defw    fp_{i}\n" for i in range(NROUT)))
    for i, (k, ents) in enumerate(FIG_PLANS):
        f.write(f"fp_{i}:\n" + db([k, len(ents)] + ents))
    f.write("; per slot: the 16 texture columns that hold any ink (bit u of the word): empty ones are skipped\n")
    f.write("fig_ink:\n" + dw(FIG_INK))
    f.write("; the voices: index (SND_* - 1) -> segments (kind, half-period in 1/16 steps (word), change, count (word)),\n; kind 0 ends\n")
    f.write("voice_tbl:\n" + "".join(f"        defw    v_{name.lower()}\n" for name, _ in VOICES))
    for name, segs in VOICES:
        b = []
        for kind, p0, dp, n in segs:
            b += [kind, p0 & 255, p0 >> 8, dp & 255, n & 255, n >> 8]
        f.write(f"v_{name.lower()}:\n" + db(b + [0]))
    f.write(emit_routines())

with open(os.path.join(OUT, "seeds.inc"), "w") as f:      # bank 1, beside the builders that read them
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write("; seeds for the boot builders: quarter-wave cosine, 65536/v, the stature ledgers' change points\n")
    f.write("costab:\n" + dw(COSTAB) + "rcp256:\n" + dw(RCP256) + "ht_seed:\n" + db(HT_SEED))
    f.write("; the projection's ledgers (read only with bank 1 in view)\n")
    f.write("fig_slot:\n" + db(FIGSLOT))
    f.write("; by forward distance (1/16 tile): stature, width (chars), texture step, column scale\n")
    f.write("f_srt:\n" + db(FSRT) + "f_sw:\n" + db(FSW) + "f_ustep:\n" + dw(FUSTEP) + "f_kq:\n" + dw(FKQ))
    f.write("gz_ang:\n" + db(GZ_ANG) + "gz_tol:\n" + db(GZ_TOL))
    f.write("ystart:\n" + dw(8 * v for v in YSTART))
    f.write("faces:\n" + "".join(db(fc) for fc in FACES))

    f.write("door_list:\n" + dw(MAP_BASE + i for i in DOOR_TILES) + "door_kind:\n" + db(DOOR_KIND))

with open(os.path.join(OUT, "hidata.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit.  Loaded by the DOS into bank 1 ($8000-$F3FF).\n")
    f.write(f"        org     {MAP_BASE}\n")
    f.write(db(mapb))
    f.write(f"        org     {OBJ_BASE}\n")
    f.write(db(objinit) + db(blockmap))
    f.write(f"        org     {DIRFIELD}\n")
    f.write(db(dirfield))
    f.write(f"        org     {RAWSPR}\n")
    f.write(db(raw_spr))
    f.write(f"        org     {RAWTEX}\n")
    f.write(db(raw_tex))

open(os.path.join(OUT, "figures.bin"), "wb").write(b"".join(forged_figure(i) for i in range(NSPR)))
twin = {
    "fig_plans": FIG_PLANS, "fig_slot": FIGSLOT, "fsrt": FSRT, "fsw": FSW, "fustep": FUSTEP, "fkq": FKQ,
    "ystart": YSTART, "gz_ang": GZ_ANG, "gz_tol": GZ_TOL, "nguard": NGUARD, "objinit": list(objinit), "fig_pat": FIG_PAT, "fig_ink": FIG_INK, "fig_tex": fig_tex,
    "COLS": COLS, "VIEW_ROWS": VIEW_ROWS, "ANGLES": ANGLES, "map": list(mapb), "rays": RAYREC,
    "layouts": LAYOUTS, "ht": HT, "texloc": TEXLOC, "plans": PLANS, "statures": STATURES,
    "ceil": CEIL_CHAR, "floor": FLOOR_CHAR, "tex_grey": tex_grey, "patterns": PATTERNS,
    "start": [START_X, START_Y, START_ANG], "ts_grey": [0, 0] + [ts_of(c, sd) for c in range(1, NCODES) for sd in (0, 1)],
}
open(os.path.join(OUT, "tables.bin"), "wb").write(TABLES_REF)
json.dump(twin, open(os.path.join(OUT, "twin.json"), "w"))
open(os.path.join(OUT, "forged.bin"), "wb").write(b"".join(forged_block(ts) for ts in range(NTS)))

# ---- preview: every texture as the Model 4 will show it at 1:1 (pattern (0,1,2)), lit above shaded ----
def preview():
    from PIL import Image
    sc = 4
    im = Image.new("RGB", (NTEX * (TEXW * 2 + 2) * sc, 2 * (TEXH + 2) * sc), (40, 40, 40))
    for ts in range(NTS):
        t, shade = ts // 2, ts % 2
        for x in range(TEXW):
            for a in range(0, TEXH, 3):
                ch = tex_char(tex_grey[ts][x], a, 1)
                for k in range(3):
                    if a + k >= TEXH: continue
                    for side in range(2):
                        on = (ch >> (2 * k + side)) & 1
                        c = (230, 230, 230) if on else (0, 0, 0)
                        X = (t * (TEXW * 2 + 2) + 2 * x + side) * sc
                        Y = (shade * (TEXH + 2) + a + k) * sc
                        for dy in range(sc):
                            for dx in range(sc):
                                im.putpixel((X + dx, Y + dy), c)
    im.save(os.path.join(OUT, "preview_textures.png"))
preview()

routine_bytes = sum(3 + sum(3 if andm == 0x80 else 3 + (2 if andm not in (0xFF, 0xBF) else 0) + (2 if orm else 0) + 2
                            for _, _, andm, orm in chars) + 3 for k, chars, f in PLANS)
print("  autopilot:", AI_INFO)
print(f"  walls {TEX_NAMES}; {NDIM} dim wall cells")
print(f"  figures: {NSPR} ({len(raw_spr)} B raw), pattern {FIG_PAT}; objects {len(objs)} ({NGUARD} sentinels)")
print(f"  map {MAPNAME} start=({START_X},{START_Y}) ang {START_ANG}; {NTEX} textures -> {NTS} texture-shades "
      f"({len(raw_tex)} B raw, forged to {NTS * TS_PAGES // 4} KB)")
print(f"  {NROUT} compiled column routines (statures {STATURES[0]}..{STATURES[-1]}), ~{routine_bytes} B; KH {KH:.1f}, "
      f"focal {FOCAL:.1f}, per-texture grey thresholds")
