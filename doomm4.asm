;;; =============================================================================
;;; DOOMM4.ASM - field notes on the natives' hell-world hunting game, carried to the TRS-80 Model 4 (Z80, 128 KB)
;;; =============================================================================
;;; The natives' own proverb, recorded verbatim: "Constraints breed elegance, not limitations."
;;;
;;; The glass   : 80 x 24 characters at $F800 (memory mode 2).  Characters 128-191 are 2x3 blocks, so the world
;;;               is 160 x 60 block pixels in rows 0-19; the gauge is plain text in rows 20-23.
;;; Provenance  : the lattice and the wall art come from the natives' files, shaped by scripts/gen_assets.py.
;;; Tempo       : the Z80 at 4 MHz with video wait states (port $EC = $60).  Interrupts stay off; the clock latch
;;;               (port $E0 bit 2, acknowledged by reading $EC, ~60 a second) is polled and counted as "tides".
;;; Memory      : lower 32 KB always in view (variables, ray buffer, run-time code, compiled routines, the $2000
;;;               overlay); bank 1 ($8000-$F3FF, port $84 = $86) holds the lattice, the objects, the ledgers grown at
;;;               boot, the game (deeds.asm) and 10 figure slots; banks 2 and 3 ($A6, $B6) the 30 forged
;;;               texture-shades and 26 more figure slots.  $4000-$40FF is never loaded (the DOS writes into it).
;;;
;;; Techniques observed in the renderer:
;;;  * Reciprocal Universe : division never occurs.  1/|dir| sits in the ray record; distance -> stature is a
;;;                          ledger per fisheye class; the Z80's missing multiply is a quarter-square lookup.
;;;  * Shape of Data       : 64-byte lattice rows (a ray crosses a column with INC L, a row with an add);
;;;                          a texture page byte IS the finished 2x3 character for (column, row, pattern).
;;;  * Fused Path          : a wall column is one compiled straight run: LD A,(IX+d) / LD (HL),A / ADD HL,DE.
;;;  * Identity            : ceiling and floor are shared ladders of stores; a column whose ray found exactly
;;;                          the same texture column and stature as last breath is not painted at all; from the
;;;                          same place no ray is cast, and with the same figures nothing is drawn.
;;;  * Bresenham           : the grid walk accumulates reach distances; the forge picks sampling patterns.
;;; =============================================================================

            include build/equ.inc

;;; ---------------------------------------------------------------------------
;;; The machine's organs
;;; ---------------------------------------------------------------------------
OPREG       equ     $84             ; memory mode, 80 columns, upper-bank select
NMIMASK     equ     $E4
INTSTAT     equ     $E0             ; read: pending interrupts (active low); write: interrupt mask
MODOUT      equ     $EC             ; write bit 6 = 4 MHz; read acknowledges the clock latch
PRINTER     equ     $F8
EMU         equ     $47             ; trs80gp emulator extensions (tests only)
KROW0       equ     $F401           ; @ A B C D E F G
KROW2       equ     $F404           ; P Q R S T U V W
KROW6       equ     $F440           ; ENTER CLEAR BREAK UP DOWN LEFT RIGHT SPACE
KROW7       equ     $F480           ; SHIFT SHIFT CTRL CAPS F1 F2 F3

;;; lower memory (always in view)
VARS        equ     $0100
STACK       equ     $0400           ; grows down to $0200
SOA         equ     $0400           ; the ray buffer, one page per field, indexed by column (shape of data):
RB_PORT     equ     SOA+$000        ;   bank port of the texture
RB_IXH      equ     SOA+$100        ;   texture column page
RB_IXL      equ     SOA+$200        ;   0 or 128 (which column of the page)
RB_RT       equ     SOA+$300        ;   compiled routine (stature)
RB_DIRTY    equ     SOA+$400        ;   nonzero: paint this column this breath
ZB          equ     $0900           ; per glass column: the wall's stature (routine index) - the depth ledger
SPRNOW      equ     $0A00           ; per column: a figure covers it this breath
SPRPREV     equ     $0B00           ; ... covered it last breath (both repaint the wall under them)
DLIST       equ     $0C00           ; after boot: the figures to paint, far to near, 10 bytes each (24 at most)
OLIST       equ     $0E00           ; after boot: survivors of the last cull, as object indices
MANT        equ     $1000           ; per angle, 8-byte stride like the ray records: mx, jx, my, jy (built at boot):
                                    ;   dd ~ m << (8-z), reach0 = (u*m) >> z, j = 4*(8-z) = the jump into a shift ladder
RAWBUF      equ     $0C00           ; boot: one texture-shade's raw art (128 B), copied out of bank 1 for the forge
EBUF        equ     $0D00           ; boot: forge scratch: E0 at +0, E1 at +40, E2 at +80 (36 rows each)
OVERLAY     equ     $2000           ; run-time code assembled for $2000, loaded into bank 1, copied down at boot
HOLE        equ     $4000           ; $4000-$40FF is never loaded: the DOS (TRSDOS 6.2 and LS-DOS 6.3 alike)
                                    ; writes a 0 into $4022 after loading a /CMD

px          equ     VARS+0          ; the traveller: 8.8, low byte = fraction, high byte = lattice column
py          equ     VARS+2
bearing     equ     VARS+4          ; 0..511, 512 to a full turn
breaths     equ     VARS+6          ; breaths painted
fingers     equ     VARS+8
fingers_old equ     VARS+9
tides       equ     VARS+10         ; clock edges seen since the last breath
dt          equ     VARS+11         ; tides the last breath took (1..4)
rec         equ     VARS+12         ; -> current ray record
bearing8    equ     VARS+14         ; bearing * 8: record offset
clsp        equ     VARS+16         ; near-ledger page of the current column's class
col         equ     VARS+17
tt          equ     VARS+20         ; hit distance (8.8 tiles)
tile        equ     VARS+23
ccol        equ     VARS+24
mvx         equ     VARS+28
mvy         equ     VARS+30
ntmp        equ     VARS+32
fracx       equ     VARS+34
fracy       equ     VARS+35
fts         equ     VARS+45         ; forge: texture-shade
fpage       equ     VARS+46
fcol        equ     VARS+47
fsrc        equ     VARS+48
fdst        equ     VARS+50
t_cast      equ     VARS+52         ; T-states of the last breath's casting / painting (tests)
t_draw      equ     VARS+56
scr_ptr     equ     VARS+60         ; test script cursor
scr_left    equ     VARS+62
painted     equ     VARS+63         ; columns painted in the last breath
layout      equ     VARS+64         ; 0 = STILL (80 rays, one per column); $FF = none yet
cxs         equ     VARS+65         ; the gaze >> 2 (signed bytes)
cys         equ     VARS+66
olist_n     equ     VARS+67         ; survivors
dlist_n     equ     VARS+68         ; figures to paint
pdx         equ     VARS+69
pdy         equ     VARS+70
pf16        equ     VARS+71
pl16        equ     VARS+72         ; (word)
pent        equ     VARS+74         ; the entry being formed: f16, S, cs, ce, u0 (2), ustep (2), slot, spare
fc0v        equ     VARS+84         ; (word)
fc1v        equ     VARS+86         ; (word)
fwv         equ     VARS+88
pobj        equ     VARS+89         ; (word) -> object
ocnt        equ     VARS+91
GV          equ     VARS+160        ; ---- the game (deeds.asm) ----
vitality    equ     GV+0
payload     equ     GV+1            ; ammo
lives       equ     GV+2
latchkeys   equ     GV+3            ; bit 0 gold, bit 1 silver
grip        equ     GV+4            ; weapon in hand: 0 knife, 1 pistol, 2 machine gun, 3 chain gun
best_grip   equ     GV+5
recoil      equ     GV+6
glare       equ     GV+7            ; muzzle flash breaths
bruise      equ     GV+8            ; breaths since a wound
dice        equ     GV+9
gauge_stale equ     GV+10
blade       equ     GV+11
score       equ     GV+12           ; 6 decimal digits
voice_req   equ     GV+18
msg_time    equ     GV+19
msg_new     equ     GV+20
msg_ptr     equ     GV+21           ; (word)
face_shown  equ     GV+23
dxr         equ     GV+24
dyr         equ     GV+25
dxs         equ     GV+26
dys         equ     GV+27
skew        equ     GV+28           ; (word)
alignment   equ     GV+30           ; (word)
bestf       equ     GV+32           ; (word)
bestp       equ     GV+34           ; (word)
lsx         equ     GV+36           ; (word) gaze_clear's step and point
lsy         equ     GV+38
lrx         equ     GV+40
lry         equ     GV+42
gdx         equ     GV+44           ; (words) a sentinel's way to the traveller
gdy         equ     GV+46
gsx         equ     GV+48
gsy         equ     GV+50
levels      equ     GV+52           ; (word) floors completed
xok         equ     GV+55           ; the collision verdicts (x, y)
yok         equ     GV+56
fingers_raw equ     GV+57
machine_mind equ    GV+58           ; 1: the cold mind drives
lpx         equ     GV+60           ; (words) where it stood last breath
lpy         equ     GV+62
wedged      equ     GV+64
retreat     equ     GV+65
chase_age   equ     GV+66
chase_nap   equ     GV+67
tgx         equ     GV+68
tgy         equ     GV+69
skew_abs    equ     GV+70           ; (word)
seen        equ     GV+72           ; px, py, bearing (6 bytes) the rays were last cast from
recast      equ     GV+78           ; nonzero: cast again even from the same place (a door moved, the layout changed)
cast_skip   equ     GV+79           ; nonzero: this breath reused last breath's rays
fig_same    equ     GV+80           ; nonzero: ... and the same figures in the same places: nothing to paint
tide_total  equ     GV+82           ; (word) clock ticks since the start
tsum        equ     GV+84           ; (32 bits) tests: every T-state since the first breath, / 16
fig_dirty   equ     GV+81
armor       equ     GV+92           ; DOOM: armour points (absorbs a third of each wound)
kills       equ     GV+93           ; DOOM: sentinels felled
mkind       equ     GV+94           ; DOOM: the kind of the sentinel being thought about (0-3)
PREVD       equ     $0D00           ; last breath's draw list (count, then 10-byte entries) - for the identity test

K_FWD       equ     $01
K_BACK      equ     $02
K_LEFT      equ     $04
K_RIGHT     equ     $08
K_USE       equ     $10
K_AI        equ     $20
K_FIRE      equ     $40
K_EXIT      equ     $80
;;; the voices (SND_*, NVOICES) are numbered in equ.inc, from gen_assets.py's VOICES

            org     $3000

;;; ===========================================================================
;;; MACROS
;;; ===========================================================================
;;; MUL8: HL = A * E (unsigned) by quarter squares, SQ(a+b) - SQ(|a-b|), inline.  Clobbers B, C, D.  Bank 1.
MUL8        macro   ?p
            ld      d,a
            sub     e
            jr      nc,?p
            neg
?p:         ld      l,a
            ld      h,SQ_BASE/256
            ld      c,(hl)
            inc     h
            inc     h
            ld      b,(hl)              ; BC = SQ(|a-b|)
            ld      a,d
            add     a,e
            ld      l,a
            ld      a,SQ_BASE/256
            adc     a,0
            ld      h,a
            ld      a,(hl)
            inc     h
            inc     h
            ld      h,(hl)              ; H:A = SQ(a+b)
            sub     c
            ld      l,a
            ld      a,h
            sbc     a,b
            ld      h,a
            endm

;;; LADDER: shift HL right 0..8 times; entered through a patched JR that skips (8-z) of the 8 steps
LADDER      macro
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            endm

PMARK       macro   n
            ifdef   PROF
            push    af
            push    bc
            push    de
            push    hl
            ld      a,n
            call    prof_mark
            pop     hl
            pop     de
            pop     bc
            pop     af
            endif
            endm

;;; QUAD: one ray for one direction quadrant.  HL = (rec) -> {dirx, diry, ddx, ddy} (little-endian words).
;;;   reach0 = (u * m) >> z from the boot-built mantissa (one multiply per axis; u = the traveller's fraction
;;;   or its complement, patched in per breath); then the grid walk: IX = reach_x, IY = reach_y, DE = ddx,
;;;   BC = ddy, HL -> lattice cell (patched per breath).
QUAD        macro   xneg,yneg,uxl,uyl,mpl,?shx,?lx,?my,?shy,?ly,?lp,?xs,?ys,?hx,?hy
            ld      a,h
            and     $0F
            or      MANT/256
            ld      h,a
            ld      e,(hl)              ; mx
            inc     l
            ld      a,(hl)
            ld      (?shx+1),a          ; jx
            inc     l
            ld      a,(hl)
            ld      (?my+1),a           ; my
            inc     l
            ld      a,(hl)
            ld      (?shy+1),a          ; jy
uxl:        ld      a,0                 ; (patched) x fraction or its complement
            MUL8
?shx:       jr      ?lx                 ; (patched)
?lx:        LADDER
            push    hl                  ; reach_x
?my:        ld      e,0                 ; (patched)
uyl:        ld      a,0                 ; (patched)
            MUL8
?shy:       jr      ?ly                 ; (patched)
?ly:        LADDER
            push    hl                  ; reach_y
            ld      hl,(rec)
            ld      a,l
            or      4
            ld      l,a
            ld      e,(hl)
            inc     l
            ld      d,(hl)              ; DE = ddx
            inc     l
            ld      c,(hl)
            inc     l
            ld      b,(hl)              ; BC = ddy
            pop     iy
            pop     ix
mpl:        ld      hl,0                ; (patched) -> the traveller's cell
            PMARK   1
?lp:        ld      a,ixh               ; reach_x < reach_y ?  (unsigned, high bytes first)
            cp      iyh
            jr      c,?xs
            jr      nz,?ys
            ld      a,ixl
            cp      iyl
            jr      nc,?ys
?xs:        add     ix,de
            if      xneg
            dec     l
            else
            inc     l
            endif
            ld      a,(hl)
            or      a
            jr      z,?lp
            jp      ?hx
?ys:        add     iy,bc
            if      yneg
            ld      a,l                 ; one row up: HL -= 64
            sub     64
            ld      l,a
            sbc     a,a
            add     a,h
            ld      h,a
            else
            ld      a,l                 ; one row down: HL += 64
            add     a,64
            ld      l,a
            adc     a,h
            sub     l
            ld      h,a
            endif
            ld      a,(hl)
            or      a
            jr      z,?lp
            jp      ?hy
?hx:        PMARK   2
            ld      (tile),a            ; ---- an x wall: t = reach_x - ddx
            push    ix
            pop     hl
            or      a
            sbc     hl,de
            if      xneg
            HIT     0,yneg,0
            else
            HIT     0,yneg,15
            endif
?hy:        PMARK   2
            ld      (tile),a            ; ---- a y wall: t = reach_y - ddy
            push    iy
            pop     hl
            or      a
            sbc     hl,bc
            if      yneg
            HIT     1,xneg,15
            else
            HIT     1,xneg,0
            endif
            endm

;;; HIT: HL = t.  texture column = (other fraction + low byte of (t * d) >> 8) >> 4, xor flip, where d is the
;;; other axis' direction (diry for an x wall, dirx for a y wall): lo(tH*dL) + hi(tL*dL) + tL*dH, dH = 0/1/$FF.
HIT         macro   side,dneg,flip,?acc,?nz
            ld      (tt),hl
            ex      de,hl               ; DE = t
            ld      hl,(rec)
            if      side == 0
            inc     l
            inc     l
            endif
            ld      c,(hl)              ; dL
            inc     l
            ld      b,(hl)              ; dH
            push    bc
            ld      a,d                 ; tH
            ld      e,c
            MUL8                        ; lo(tH * dL)
            ld      a,l
            ld      (?acc+1),a
            pop     bc
            push    bc
            ld      a,(tt)              ; tL
            ld      e,c
            MUL8                        ; hi(tL * dL)
            pop     bc
?acc:       ld      a,0                 ; (patched)
            add     a,h
            if      dneg
            ld      hl,tt               ; dH = $FF: - tL
            sub     (hl)
            else
            inc     b                   ; dH = 1 (d = +256): + tL
            dec     b
            jr      z,?nz
            ld      hl,tt
            add     a,(hl)
?nz:
            endif
            if      side == 0
            ld      hl,fracy
            else
            ld      hl,fracx
            endif
            add     a,(hl)
            rrca
            rrca
            rrca
            rrca
            and     15
            if      flip
            xor     15
            endif
            ld      (ccol),a
            ld      c,side
            jp      hit_tail
            endm

;;; ===========================================================================
;;; BOOT
;;; ===========================================================================
start:      di
            ld      sp,STACK
            ld      hl,VARS             ; every variable starts at zero (the DOS leaves its own bytes here)
            ld      de,VARS+1
            ld      bc,$FF
            ld      (hl),0
            ldir
            ld      a,PORT_B1
            out     (OPREG),a
            xor     a
            out     (NMIMASK),a         ; no NMI (the disk controller is done with)
            ld      a,$04
            out     (INTSTAT),a         ; let the clock latch (we poll it; interrupts stay off)
            ld      a,$60
            out     (MODOUT),a          ; 4 MHz + video wait states (without them a store that meets the beam is lost)
            ld      hl,OVL_SRC          ; the overlay down to $2000 before anything reuses its bank-1 home
            ld      de,OVERLAY
            ld      bc,$1000
            ldir
            ld      a,$ED               ; NMI vector: RETN, in case
            ld      ($0066),a
            ld      a,$45
            ld      ($0067),a
            call    clear_glass
            ld      hl,msg_forge
            ld      de,SCREEN+21*80+2
            call    print_at
            call    forge
            call    forge_figures
            call    build_sq
            call    build_rays
            call    build_ht
            call    mantissas
            call    clear_glass
            ld      hl,SOA              ; every column dirty for the first breath
            ld      de,SOA+1
            ld      bc,$500-1
            ld      (hl),$FF
            ldir
            ld      hl,START_X*256+$80
            ld      (px),hl
            ld      hl,START_Y*256+$80
            ld      (py),hl
            ld      hl,START_ANG
            ld      (bearing),hl
            call    gauge_init
            ld      a,3
            ld      (lives),a
            ld      hl,score
            ld      b,6
bt_sc:      ld      (hl),0
            inc     hl
            djnz    bt_sc
            ld      a,$5A
            ld      (dice),a
            xor     a
            ld      (recoil),a
            ld      (glare),a
            ld      (bruise),a
            ld      (msg_time),a
            ld      (msg_new),a
            ld      (voice_req),a
            ld      (gauge_stale),a
            ld      (latchkeys),a
            ld      (xok),a
            ld      (yok),a
            ld      hl,0
            ld      (levels),hl
            call    traveller_reborn
            xor     a
            ld      (fingers_raw),a
            ld      (machine_mind),a
            ld      (wedged),a
            ld      (retreat),a
            ld      (chase_age),a
            ld      (chase_nap),a
            ld      a,$FF
            ld      (layout),a
            xor     a
            ld      (olist_n),a
            ld      (dlist_n),a
            ld      hl,SPRNOW           ; no figure anywhere yet
            ld      de,SPRNOW+1
            ld      bc,$1FF
            ld      (hl),0
            ldir
            ld      hl,0
            ld      (breaths),hl
            xor     a
            ld      (fingers_old),a
            ld      (tides),a
            inc     a
            ld      (dt),a
            ifdef   TEST
            ld      hl,scenario
            ld      (scr_ptr),hl
            xor     a
            ld      (scr_left),a
            endif

;;; ===========================================================================
;;; THE ENDLESS BREATH
;;; ===========================================================================
main:
            ifdef   TEST
            call    script_fingers
            else
            call    sniff_fingers       ; the keyboard, every breath
            ld      a,(fingers)
            ld      (fingers_raw),a
            endif
            ld      a,(fingers_raw)     ; every breath starts from the real fingers (the cold mind adds to them)
            ld      (fingers),a
            ld      a,(fingers)
            bit     7,a
            jp      nz,do_exit
            ld      a,PORT_B1
            out     (OPREG),a
            call    mind                ; T toggles the cold mind; when it drives, it adds its fingers
            call    steer
            call    deeds               ; (bank 1 resident) fire, spoils, sentinels, wounds, mortality
            call    gauge_update        ; (bank 1 resident) the gauge, only what changed
            call    pick_layout
            ifdef   TEST
            call    t_reset
            endif
            call    cast_maybe
            ifdef   TEST
            call    t_lap
            ld      (t_cast),hl
            endif
            call    figures_cull        ; (bank 1 resident) who is near enough to matter
            call    figures_project     ; (bank 1 resident) the survivors onto the glass, far to near
            call    figures_mark        ; columns under a figure (now or last breath) repaint their wall
            ifdef   TEST
            call    t_lap
            ld      (t_cast+2),hl
            endif
            call    draw_all
            ifdef   TEST
            call    t_lap
            ld      (t_draw),hl
            endif
            call    figures_draw
            ifdef   TEST
            call    t_lap
            ld      (t_draw+2),hl
            endif
            call    voice_play          ; (bank 1 resident) a voice asked for this breath
            ifdef   TEST
            call    poll_tide
            xor     a
            ld      (tides),a
            call    t_lap
            call    script_after
            ld      a,1
            ld      (dt),a
            else
            call    pace
            endif
            ld      hl,(breaths)
            inc     hl
            ld      (breaths),hl
            jp      main

;;; mind: the T edge toggles the cold mind; when it drives, it thinks every breath
mind:       ld      a,(fingers)
            ld      hl,fingers_old
            ld      b,(hl)
            ld      (hl),a
            and     K_AI
            jr      z,mi_t
            ld      a,b
            and     K_AI
            call    z,mind_toggle
mi_t:       ld      a,(machine_mind)
            or      a
            ret     z
            jp      mind_step

;;; pace: at least one tide per breath; dt = tides taken (1..4) scales motion
pace:       ld      a,(tides)
            or      a
            jr      nz,pc1
pcw:        call    poll_tide
            ld      a,(tides)
            or      a
            jr      z,pcw
pc1:        cp      5
            jr      c,pc2
            ld      a,4
pc2:        ld      (dt),a
            xor     a
            ld      (tides),a
            ret

;;; poll_tide: count a pending clock edge (A only)
poll_tide:  in      a,(INTSTAT)
            and     $04
            ret     nz
            in      a,(MODOUT)          ; acknowledge
            ld      a,(tides)
            inc     a
            ld      (tides),a
            push    hl
            ld      hl,(tide_total)
            inc     hl
            ld      (tide_total),hl
            pop     hl
            ret

;;; ---------------------------------------------------------------------------
;;; FINGERS: the keyboard matrix reads 1 for a pressed key
;;; ---------------------------------------------------------------------------
sniff_fingers:
            ld      c,0
            ld      a,(KROW2)
            bit     7,a                 ; W
            jr      z,$+4
            set     0,c
            bit     3,a                 ; S
            jr      z,$+4
            set     1,c
            ld      a,(KROW0)
            bit     1,a                 ; A
            jr      z,$+4
            set     2,c
            bit     4,a                 ; D
            jr      z,$+4
            set     3,c
            ld      a,(KROW6)
            bit     3,a                 ; UP
            jr      z,$+4
            set     0,c
            bit     4,a                 ; DOWN
            jr      z,$+4
            set     1,c
            bit     5,a                 ; LEFT
            jr      z,$+4
            set     2,c
            bit     6,a                 ; RIGHT
            jr      z,$+4
            set     3,c
            bit     7,a                 ; SPACE
            jr      z,$+4
            set     4,c
            bit     2,a                 ; BREAK
            jr      z,$+4
            set     7,c
            ld      a,(KROW0)
            bit     6,a                 ; F
            jr      z,$+4
            set     6,c
            ld      a,(KROW7)
            bit     2,a                 ; CTRL
            jr      z,$+4
            set     6,c
            ld      a,(KROW2)
            bit     4,a                 ; T
            jr      z,$+4
            set     5,c
            ld      a,c
            ld      (fingers),a
            ret

;;; ---------------------------------------------------------------------------
;;; THE TRAVELLER (bank 1 in view: ray records and lattice)
;;; ---------------------------------------------------------------------------
steer:      ld      a,(dt)              ; turn: 2 units per tide
            add     a,a
            ld      e,a
            ld      d,0
            ld      a,(fingers)
            bit     2,a
            jr      z,st_nl
            ld      hl,(bearing)
            or      a
            sbc     hl,de
            ld      a,h
            and     1
            ld      h,a
            ld      (bearing),hl
st_nl:      ld      a,(fingers)
            bit     3,a
            jr      z,st_nr
            ld      hl,(bearing)
            add     hl,de
            ld      a,h
            and     1
            ld      h,a
            ld      (bearing),hl
st_nr:      ld      a,(fingers)
            bit     4,a
            call    nz,press_portal
            ld      a,(fingers)
            and     K_FWD+K_BACK
            ret     z
            call    rec_of_bearing      ; IX -> record
            ld      l,(ix+0)
            ld      h,(ix+1)
            call    step_of             ; HL = (dir >> 4) * dt
            ld      (mvx),hl
            ld      l,(ix+2)
            ld      h,(ix+3)
            call    step_of
            ld      (mvy),hl
            ld      a,(fingers)
            bit     1,a
            jr      z,st_go
            ld      hl,(mvx)
            call    negate
            ld      (mvx),hl
            ld      hl,(mvy)
            call    negate
            ld      (mvy),hl
st_go:      ld      hl,(px)             ; ---- x: probe one PAD beyond the new place
            ld      de,(mvx)
            add     hl,de
            ld      (ntmp),hl
            ld      bc,PAD
            bit     7,d
            jr      z,st_xp
            or      a
            sbc     hl,bc
            jr      st_xq
st_xp:      add     hl,bc
st_xq:      ld      c,h                 ; probe column
            ld      a,(py+1)
            call    cell_of
            ld      a,(hl)
            ld      (xok),a
st_xk:      ld      a,(xok)
            or      a
            jr      nz,st_y
            ld      hl,(ntmp)
            ld      (px),hl
st_y:       ld      hl,(py)
            ld      de,(mvy)
            add     hl,de
            ld      (ntmp),hl
            ld      bc,PAD
            bit     7,d
            jr      z,st_yp
            or      a
            sbc     hl,bc
            jr      st_yq
st_yp:      add     hl,bc
st_yq:      ld      a,(px+1)
            ld      c,a
            ld      a,h
            call    cell_of
            ld      a,(hl)
            ld      (yok),a
st_yk:      ld      a,(yok)
            or      a
            ret     nz
            ld      hl,(ntmp)
            ld      (py),hl
            ret

;;; cell_of: A = lattice row, C = column -> HL -> the cell (64 bytes a row at MAP_BASE)
cell_of:    rrca
            rrca
            ld      h,a
            and     $C0
            or      c
            ld      l,a
            ld      a,h
            and     $0F
            or      MAP_BASE/256
            ld      h,a
            ret

rec_of_bearing:
            ld      hl,(bearing)
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      de,RAYS
            add     hl,de
            push    hl
            pop     ix
            ret

;;; HL = (HL >> 4) * dt  (arithmetic shift)
step_of:    ld      b,4
so_sh:      sra     h
            rr      l
            djnz    so_sh
            ld      a,(dt)
            ld      d,h
            ld      e,l
so_m:       dec     a
            ret     z
            add     hl,de
            jr      so_m

negate:     xor     a
            sub     l
            ld      l,a
            sbc     a,a
            sub     h
            ld      h,a
            ret

;;; press_portal: the cell one tile ahead: a door opens
press_portal:
            call    rec_of_bearing
            ld      l,(ix+0)
            ld      h,(ix+1)
            ld      de,(px)
            add     hl,de
            ld      c,h                 ; column ahead
            ld      l,(ix+2)
            ld      h,(ix+3)
            ld      de,(py)
            add     hl,de
            ld      a,h
            call    cell_of
            ld      a,(hl)
            cp      SWITCH_CODE
            jp      z,stage_cleared     ; (bank 1 resident: bank 1 is in view while steering)
            cp      DOOR_CODE
            jr      z,pp_open
            cp      ELEV_CODE
            ret     nz
pp_open:    ld      (hl),0
            ld      a,1
            ld      (recast),a
            ld      a,SND_DOOR
            jp      play

;;; ===========================================================================
;;; CASTING: one ray per character column, results into the ray buffer (bank 1 in view)
;;; ===========================================================================
cast_all:   ld      hl,(bearing)
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      (bearing8),hl
            ld      a,(px)              ; ---- the breath's constants, patched into the four quadrant bodies
            ld      (fracx),a
            ld      (q10ux+1),a         ; negative x: u = fraction
            ld      (q11ux+1),a
            cpl
            ld      (q00ux+1),a         ; positive x: u = its complement
            ld      (q01ux+1),a
            ld      a,(py)
            ld      (fracy),a
            ld      (q01uy+1),a
            ld      (q11uy+1),a
            cpl
            ld      (q00uy+1),a
            ld      (q10uy+1),a
            ld      a,(px+1)
            ld      c,a
            ld      a,(py+1)
            call    cell_of
            ld      (q00mp+1),hl
            ld      (q01mp+1),hl
            ld      (q10mp+1),hl
            ld      (q11mp+1),hl
            xor     a
            ld      (col),a
            ld      (painted),a
ray_loop:   ld      a,(col)
lf1_p:      add     a,0                 ; (patched) the layout's offset in the shared layout pages
            ld      l,a
            ld      h,lay_c/256
            ld      a,(hl)
            ld      (clsp),a
            ld      h,lay_ol/256
            ld      e,(hl)
            inc     h
            ld      d,(hl)              ; DE = offset * 8
            ld      hl,(bearing8)
            add     hl,de
            ld      a,h
            and     $0F
            or      RAYS/256
            ld      h,a                 ; HL -> ray record
            ld      (rec),hl
            inc     l
            ld      a,(hl)              ; dirx hi
            inc     l
            inc     l
            ld      b,(hl)              ; diry hi
            dec     l
            dec     l
            dec     l
            PMARK   0
            bit     7,a
            jp      nz,r_xneg
            bit     7,b
            jp      nz,r_pn
            QUAD    0,0,q00ux,q00uy,q00mp
r_pn:       QUAD    0,1,q01ux,q01uy,q01mp
r_xneg:     bit     7,b
            jp      nz,r_nn
            QUAD    1,0,q10ux,q10uy,q10mp
r_nn:       QUAD    1,1,q11ux,q11uy,q11mp

;;; hit_tail: (tt) = t, (ccol) = texture column, (tile), C = side.  Stature from the ledgers, texture locator,
;;; and into the ray buffer (dirty when anything differs from the last breath).
hit_tail:   ld      hl,(tt)
            ld      a,h
            cp      4
            jr      nc,hfar
            ld      a,l                 ; near ledger: t >> 2
            srl     h
            rra
            srl     h
            rra
            ld      l,a
            ld      a,(clsp)
            ld      h,a
            ld      b,(hl)
            jr      hrt
hfar:       sub     4                   ; far ledger: (t - 4 tiles) >> 6, capped
            cp      64
            jr      c,hf1
            ld      a,255
            jr      hf2
hf1:        add     a,a
            add     a,a
            ld      h,a
            ld      a,l
            rlca
            rlca
            and     3
            or      h
hf2:        ld      l,a
            ld      a,(clsp)
            inc     a
            ld      h,a
            ld      b,(hl)              ; B = routine
hrt:        ld      a,(col)             ; the depth ledger: this ray's stature for its column(s)
lf2_p:      add     a,0                 ; (patched) the layout's offset
            ld      l,a
            ld      h,lay_col/256
            ld      l,(hl)
            ld      h,ZB/256
            ld      (hl),b
            inc     l
            ld      (hl),b
            inc     l
            ld      (hl),b
            inc     l
            ld      (hl),b              ; (a narrower ray's neighbours are overwritten by the next rays)
            ld      a,(tile)            ; texture locator: entry tile*2+side
            add     a,a
            add     a,c
            add     a,a
            ld      l,a
            ld      h,0
            ld      de,texloc
            add     hl,de
            ld      c,(hl)              ; bank port
            inc     hl
            ld      a,(hl)              ; first page of the texture-shade
            ld      hl,texcol
            ld      e,a
            ld      a,(ccol)
            add     a,l
            ld      l,a
            ld      a,e
            add     a,(hl)
            ld      d,a                 ; IX hi = page + (col * 96) >> 8
            ld      a,l
            add     a,16
            ld      l,a
            ld      e,(hl)              ; IX lo = (col * 96) & 255
            PMARK   3
            ld      a,(col)
            ld      l,a
            ld      h,RB_PORT/256
            ld      a,c
            cp      (hl)
            ld      c,0                 ; C = changed
            jr      z,$+4
            ld      (hl),a
            inc     c
            inc     h
            ld      a,d
            cp      (hl)
            jr      z,$+4
            ld      (hl),a
            inc     c
            inc     h
            ld      a,e
            cp      (hl)
            jr      z,$+4
            ld      (hl),a
            inc     c
            inc     h
            ld      a,b
            cp      (hl)
            jr      z,$+4
            ld      (hl),a
            inc     c
            inc     h
            ld      (hl),c              ; dirty
            ld      a,l
            and     7
            call    z,poll_tide
            PMARK   4
            ld      hl,col
            inc     (hl)
            ld      a,(hl)
nr_p:       cp      0                   ; (patched) rays in the layout
            jp      nz,ray_loop
            ret

;;; cast_maybe: the same place, bearing and layout as last breath and no door moved: every ray would come out the
;;; same (identity) - skip the casting and leave the ray buffer clean (figures still repaint the walls they cover)
cast_maybe: ld      hl,px
            ld      de,seen
            ld      b,6
cm_c:       ld      a,(de)
            cp      (hl)
            jr      nz,cm_cast
            inc     hl
            inc     de
            djnz    cm_c
            ld      a,(recast)
            or      a
            jr      nz,cm_cast
            ld      hl,RB_DIRTY         ; nothing changed: no ray is dirty
            ld      b,COLS
cm_z:       ld      (hl),0
            inc     l
            djnz    cm_z
            xor     a
            ld      (painted),a
            inc     a
            ld      (cast_skip),a
            ret
cm_cast:    xor     a
            ld      (cast_skip),a
            ld      hl,px
            ld      de,seen
            ld      bc,6
            ldir
            xor     a
            ld      (recast),a
            jp      cast_all

;;; pick_layout: the STILL layout (80 rays, one per column), always.  A change repaints every column.
pick_layout:
            xor     a
            ld      hl,layout
            cp      (hl)
            ret     z
            ld      (hl),a
            ld      l,a                 ; 7 bytes a layout
            ld      h,0
            ld      e,l
            ld      d,h
            add     hl,hl
            add     hl,hl
            add     hl,hl
            or      a
            sbc     hl,de
            ld      de,lay_still
            add     hl,de
            ld      a,(hl)
            ld      (lf1_p+1),a
            ld      (lf2_p+1),a
            ld      (lf3_p+1),a
            inc     hl
            inc     hl
            ld      a,(hl)
            ld      (nr_p+1),a
            ld      (dn_p+1),a
            inc     hl
            inc     hl
            inc     hl
            ld      a,(hl)
            ld      (dd_p+1),a
            inc     hl
            ld      a,(hl)
            ld      (d4_p+1),a
            ld      hl,SOA              ; every ray dirty
            ld      de,SOA+1
            ld      bc,$500-1
            ld      (hl),$FF
            ldir
            ld      a,1
            ld      (recast),a
            ret
;;; per layout: offset into the shared layout pages, -, rays, -, -, glass stride, second call (four wide)
lay_still:  defb    LOFS_STILL, 0, NRAYS_STILL, 0, 0, COLS, 0

;;; ===========================================================================
;;; PAINTING: each dirty column through its compiled routine; the glass address is $F8:column
;;; ===========================================================================
draw_all:   ld      c,0                 ; C = ray
            ld      b,$FF               ; B = the bank port now in place
dl:         ld      h,RB_DIRTY/256
            ld      l,c
            ld      a,(hl)
            or      a
            jr      z,dskip
            ld      h,RB_PORT/256
            ld      a,(hl)
            cp      b
            jr      z,dsame
            out     (OPREG),a
            ld      b,a
dsame:      inc     h
            ld      a,(hl)
            ld      ixh,a
            inc     h
            ld      a,(hl)
            ld      ixl,a
            inc     h
            ld      e,(hl)              ; routine
            ld      a,c
lf3_p:      add     a,0                 ; (patched) the layout's offset
            ld      l,a
            ld      h,lay_w/256         ; which routine table
            ld      a,(hl)
            ld      h,a
            ld      a,e
            add     a,a
            ld      l,a
            ld      a,(hl)
            inc     l
            ld      h,(hl)
            ld      l,a
            ld      (dcall+1),hl
            ld      a,(lf3_p+1)
            add     a,c
            ld      l,a
            ld      h,lay_col/256
            ld      l,(hl)
            ld      h,SCREEN/256
            push    bc
dd_p:       ld      de,0                ; (patched) glass stride: 80, or 79 for the two-wide routines
            push    hl
dcall:      call    0                   ; (patched) the strip's compiled routine
            pop     hl
d4_p:       ld      a,0                 ; (patched) 1: a four-wide strip - the two-wide routine again, 2 columns on
            or      a
            jr      z,d4_no
            inc     hl
            inc     hl
            ld      de,COLS-1
            ld      a,(dcall+1)
            ld      (dcall2+1),a
            ld      a,(dcall+2)
            ld      (dcall2+2),a
dcall2:     call    0
d4_no:      pop     bc
            ld      hl,painted
            inc     (hl)
dskip:      ld      a,c
            and     7
            call    z,poll_tide
            inc     c
            ld      a,c
dn_p:       cp      0                   ; (patched) rays in the layout
            jr      nz,dl
            ld      a,PORT_B1
            out     (OPREG),a
            ret

;;; ===========================================================================
;;; the glass
;;; ===========================================================================
clear_glass:
            ld      hl,SCREEN
            ld      de,SCREEN+1
            ld      bc,80*24-1
            ld      (hl),' '
            ldir
            ret

;;; print_at: HL -> zero-terminated text, DE -> glass
print_at:   ld      a,(hl)
            or      a
            ret     z
            ld      (de),a
            inc     hl
            inc     de
            jr      print_at

do_exit:    di
            xor     a
            out     (OPREG),a           ; memory mode 0: the ROM returns at $0000
            jp      0

msg_forge:  defb    'FORGING THE WALLS...',0
msg_title:  defb    'DOOM (FREEDOOM E1M1)   -   TRS-80 MODEL 4   -   W A S D / ARROWS, F FIRES, SPACE OPENS',0

            assert  $ <= HOLE           ; the run-time code must stay below the hole at $4000
            org     HOLE+$100
            include build/tables.inc

            include voice.asm

;;; ===========================================================================
;;; BOOT-ONLY CODE (and the tests), after the tables
;;; ===========================================================================
;;; ===========================================================================
;;; THE FORGE: 2-bit wall art -> finished characters, 4 sampling patterns x 32 rows per column, into the banks
;;; ===========================================================================
forge:      xor     a
            ld      (fts),a
fg_ts:      ld      a,PORT_B1           ; this texture-shade's 128 raw bytes into lower memory
            out     (OPREG),a
            ld      a,(fts)
            ld      l,a
            ld      h,0
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      de,RAWTEX
            add     hl,de
            ld      de,RAWBUF
            ld      bc,128
            ldir
            ld      hl,RAWBUF
            ld      (fsrc),hl
            ld      a,(fts)
            add     a,a
            add     a,4                 ; skip code 0's two entries
            ld      e,a
            ld      d,0
            ld      hl,texloc
            add     hl,de
            ld      a,(hl)
            out     (OPREG),a
            inc     hl
            ld      a,(hl)
            ld      (fdst+1),a          ; this texture-shade's first page, offset 0
            xor     a
            ld      (fdst),a
            ld      (fcol),a
fg_col:
;;; unpack one column: 8 bytes -> 32 grey values -> E0 (pair bits), E1 (<<2), E2 (<<4); rows 32-35 repeat row 31
fg_unpack2: ld      hl,(fsrc)
            ld      ix,EBUF
            ld      b,32                ; rows
            ld      c,0
fu_row:     ld      a,c
            and     3
            jr      nz,fu_have
            ld      e,(hl)              ; next packed byte every 4 rows
            inc     hl
fu_have:    ld      a,e
            rlca
            rlca
            ld      e,a
            and     3                   ; grey g
            call    pair_rows           ; its bits for block rows 0, 1, 2 -> E0, E1, E2
            inc     ix
            inc     c
            djnz    fu_row
            ld      (fsrc),hl
            ld      b,4                 ; rows 32..35 = row 31
            ld      a,(ix-1)
            ld      d,(ix+39)
            ld      e,(ix+79)
fu_pad:     ld      (ix+0),a
            ld      (ix+40),d
            ld      (ix+80),e
            inc     ix
            djnz    fu_pad
            ;; 3 patterns x 32 rows, straight on from the last column (each column takes 96 bytes)
            ld      ix,patterns
            ld      b,3
fg_pat:     push    bc
            ld      a,(ix+0)
            add     a,40
            ld      (fg_d1+1),a         ; (patched) E1 offset for this pattern
            ld      a,(ix+1)
            add     a,80
            ld      (fg_d2+1),a
            inc     ix
            inc     ix
            ld      de,(fdst)
            ld      h,EBUF/256
            ld      b,32
            ld      c,0                 ; a
fg_a:       ld      l,c
            ld      a,(hl)              ; E0[a]
            or      $80
            push    af
            ld      a,c
fg_d1:      add     a,0
            ld      l,a
            pop     af
            or      (hl)                ; E1[a+d1]
            push    af
            ld      a,c
fg_d2:      add     a,0
            ld      l,a
            pop     af
            or      (hl)                ; E2[a+d2]
            ld      (de),a
            inc     de
            inc     c
            djnz    fg_a
            ld      (fdst),de
            pop     bc
            djnz    fg_pat
            ld      a,(fcol)
            inc     a
            ld      (fcol),a
            cp      16
            jp      nz,fg_unpack2
            ld      a,(fts)
            inc     a
            ld      (fts),a
            cp      NTS
            jp      nz,fg_ts
            ld      a,PORT_B1
            out     (OPREG),a
            ret

;;; ---------------------------------------------------------------------------
;;; forge_figures: 4-bit texels (bank 1, RAWSPR) -> per slot 16 columns x 32 finished characters for the figure
;;; pattern (0,1,1), 0 where the character is wholly transparent.  Scratch: FRAW (the raw figure), FE (E0 at +0,
;;; E1 at +40, E2 at +80, opacity at +120, 34 rows each)
;;; ---------------------------------------------------------------------------
FRAW        equ     $0E00
FE          equ     $0F00
forge_figures:
            xor     a
            ld      (fts),a
ff_spr:     ld      a,PORT_B1           ; the raw figure into lower memory
            out     (OPREG),a
            ld      a,(fts)
            add     a,RAWSPR/256
            ld      h,a
            ld      l,0
            ld      de,FRAW
            ld      bc,256
            ldir
            ld      a,(fts)             ; its slot: bank port (0 = lower memory: leave the bank), first page
            add     a,a
            ld      e,a
            ld      d,0
            ld      hl,fig_slots
            add     hl,de
            ld      a,(hl)
            or      a
            jr      z,ff_lo
            out     (OPREG),a
ff_lo:      inc     hl
            ld      d,(hl)
            ld      e,0
            ld      (fdst),de
            ld      hl,FRAW
            ld      (fsrc),hl
            xor     a
            ld      (fcol),a
ff_col:     ld      hl,(fsrc)           ; unpack one column: 32 texels, two a byte (high nibble first)
            ld      ix,FE
            ld      b,32
            ld      c,0                 ; row
ff_row:     ld      a,c
            and     1
            ld      a,(hl)
            jr      nz,ff_lo4
            rrca
            rrca
            rrca
            rrca
            jr      ff_t
ff_lo4:     inc     hl
ff_t:       and     15                  ; texel: 0 transparent, 1-4 = grey + 1
            ld      (ix+120),a          ; opacity (nonzero = opaque)
            jr      z,ff_clear
            dec     a
            call    pair_rows
            jr      ff_next
ff_clear:   ld      (ix+0),a            ; (transparent: A = 0)
            ld      (ix+40),a
            ld      (ix+80),a
ff_next:    inc     ix
            inc     c
            djnz    ff_row
            ld      (fsrc),hl
            ld      a,(ix-1)            ; rows 32, 33 = row 31
            ld      (ix+0),a
            ld      (ix+1),a
            ld      a,(ix+39)
            ld      (ix+40),a
            ld      (ix+41),a
            ld      a,(ix+79)
            ld      (ix+80),a
            ld      (ix+81),a
            ld      a,(ix+119)
            ld      (ix+120),a
            ld      (ix+121),a
            ld      de,(fdst)           ; 32 characters for base rows a = 0..31, rows (a, a+1, a+1)
            ld      ix,FE
            ld      b,32
ff_a:       ld      a,(ix+120)
            or      (ix+121)
            jr      z,ff_t0             ; all three block rows transparent
            ld      a,(ix+0)
            or      (ix+41)
            or      (ix+81)
            or      $80
ff_t0:      ld      (de),a
            inc     de
            inc     ix
            djnz    ff_a
            ld      (fdst),de
            ld      a,(fcol)
            inc     a
            ld      (fcol),a
            cp      16
            jp      nz,ff_col
            ld      a,(fts)
            inc     a
            ld      (fts),a
            cp      NSPR
            jp      nz,ff_spr
            ld      a,PORT_B1
            out     (OPREG),a
            ret

;;; pair_rows: A = grey g -> (IX+0) = its pixel pair for block row 0, (IX+40) for row 1 (<< 2), (IX+80) row 2 (<< 4).
;;; The dither is locked to the glass (by block row), not to the texel rows that repeat on a near wall.
pair_rows:  push    hl
            ld      hl,pair_k
            add     a,l
            ld      l,a
            jr      nc,$+3
            inc     h
            ld      a,(hl)
            ld      (ix+0),a
            inc     hl
            inc     hl
            inc     hl
            inc     hl
            ld      a,(hl)
            add     a,a
            add     a,a
            ld      (ix+40),a
            inc     hl
            inc     hl
            inc     hl
            inc     hl
            ld      a,(hl)
            add     a,a
            add     a,a
            add     a,a
            add     a,a
            ld      (ix+80),a
            pop     hl
            ret
pair_k:     defb    0,0,1,3, 0,1,2,3, 0,0,1,3   ; [block row][grey] -> (L = bit 0, R = bit 1)
patterns:   defb    2,4, 1,1, 0,0        ; offsets of block rows 1 and 2 (row 0 is +0)

;;; ===========================================================================
;;; TESTS: a scripted traveller, the glass and the timings sent to the printer, exit through the emulator
;;; ===========================================================================
            ifdef   TEST
script_fingers:
            ld      a,(scr_left)
            or      a
            jr      nz,sf_have
sf_next:    ld      hl,(scr_ptr)
            ld      a,(hl)              ; count (0 = end; 255 = teleport: x, y, bearing words follow)
            or      a
            jp      z,t_quit
            inc     a
            jr      nz,sf_rec
            inc     hl
            ld      de,px
            ld      bc,6
            ldir
            ld      (scr_ptr),hl
            jr      sf_next
sf_rec:     inc     a                   ; 254: toggle trs80gp's audio recording (trs80-N.wav)
            jr      nz,sf_cnt0
            inc     hl
            ld      (scr_ptr),hl
            ld      b,$41
            ld      a,6
            out     (EMU),a
            jr      sf_next
sf_cnt0:    dec     a
sf_cnt:     dec     a
            ld      (scr_left),a
            inc     hl
            ld      a,(hl)
            ld      (fingers_raw),a
            ret
sf_have:    ret

;;; after each breath: count down; at the end of an entry, report if its flags ask
script_after:
            ld      hl,scr_left
            dec     (hl)
            ret     nz
            ld      hl,(scr_ptr)
            inc     hl
            inc     hl
            ld      a,(hl)              ; flags: 1 = report + glass, 2 = report only
            inc     hl
            ld      (scr_ptr),hl
            or      a
            ret     z
            cp      64
            jp      z,dump_tables
            cp      65
            jp      z,dump_figures
            bit     5,a
            jr      z,sa_noshot
            push    af
            ld      b,$53               ; trs80gp: save a screenshot (batch mode: trs80-N.gif)
            ld      a,6
            out     (EMU),a
            pop     af
            and     $DF
            ret     z
sa_noshot:  cp      4
            jp      z,dump_forge
            push    af
            call    report
            pop     af
            bit     4,a
            push    af
            call    nz,dump_mem
            pop     af
            bit     3,a
            push    af
            call    nz,dump_rays
            pop     af
            and     7
            cp      1
            ret     nz
            jp      dump_glass

;;; dump_mem: 'M' then $3F00-$41FF (a window on the compiled routines) as one hex line
dump_mem:   ld      a,'M'
            call    putc
            ld      hl,$3F00
            ld      bc,$300
dm_l:       ld      a,(hl)
            call    hexa
            inc     hl
            dec     bc
            ld      a,b
            or      c
            jr      nz,dm_l
            jp      crlf

;;; dump_figures: 'S' + slot, then its 512 forged bytes as 16 lines of 32
dump_figures:
            xor     a
            ld      (fts),a
dfg_s:      ld      a,'S'
            call    putc
            ld      a,(fts)
            call    hexa
            call    crlf
            ld      a,(fts)
            add     a,a
            ld      e,a
            ld      d,0
            ld      hl,fig_slots
            add     hl,de
            ld      a,(hl)
            or      a
            jr      z,dfg_lo
            out     (OPREG),a
dfg_lo:     inc     hl
            ld      h,(hl)
            ld      l,0
            ld      c,16
dfg_l:      ld      b,32
dfg_b:      ld      a,(hl)
            call    hexa
            inc     hl
            djnz    dfg_b
            call    crlf
            dec     c
            jr      nz,dfg_l
            ld      a,(fts)
            inc     a
            ld      (fts),a
            cp      NSPR
            jr      nz,dfg_s
            ld      a,PORT_B1
            out     (OPREG),a
            ret

;;; dump_tables: 'T' then the boot-built ledgers $C000-$E3FF (rays, statures, quarter squares), 32 bytes a line
dump_tables:
            ld      a,'T'
            call    putc
            call    crlf
            ld      hl,RAYS
dt_l:       ld      b,32
dt_b:       ld      a,(hl)
            call    hexa
            inc     hl
            djnz    dt_b
            call    crlf
            ld      a,h
            cp      SQ_BASE/256+4
            jr      nz,dt_l
            ret

;;; dump_rays: 'R' then per column: port, IX hi, IX lo, routine, dirty, as one hex line
dump_rays:  ld      a,'R'
            call    putc
            ld      c,0
dr_c:       ld      l,c
            ld      h,RB_PORT/256
            ld      b,5
dr_f:       ld      a,(hl)
            call    hexa
            inc     h
            djnz    dr_f
            inc     c
            ld      a,c
            cp      COLS
            jr      nz,dr_c
            jp      crlf

;;; dump_forge: every forged texture-shade, 'G' + texture-shade, then its 6 pages as 48 hex lines of 64 chars
dump_forge: xor     a
            ld      (fts),a
df_ts:      ld      a,'G'
            call    putc
            ld      a,(fts)
            call    hexa
            call    crlf
            ld      a,(fts)
            add     a,a
            add     a,4
            ld      e,a
            ld      d,0
            ld      hl,texloc
            add     hl,de
            ld      a,(hl)
            out     (OPREG),a
            inc     hl
            ld      h,(hl)
            ld      l,0
            ld      c,48                ; 6 pages = 48 lines of 32 bytes
df_l:       ld      b,32
df_b:       ld      a,(hl)
            call    hexa
            inc     hl
            djnz    df_b
            call    crlf
            dec     c
            jr      nz,df_l
            ld      a,(fts)
            inc     a
            ld      (fts),a
            cp      NTS
            jr      nz,df_ts
            ld      a,PORT_B1
            out     (OPREG),a
            ret

report:     ld      a,'F'
            call    putc
            ld      hl,(breaths)
            call    phex16
            ld      a,'X'
            call    putc
            ld      hl,(px)
            call    phex16
            ld      a,'Y'
            call    putc
            ld      hl,(py)
            call    phex16
            ld      a,'A'
            call    putc
            ld      hl,(bearing)
            call    phex16
            ld      a,'C'
            call    putc
            ld      hl,(t_cast)
            call    phex16n
            ld      hl,(t_cast+2)
            call    phex16
            ld      a,'D'
            call    putc
            ld      hl,(t_draw)
            call    phex16n
            ld      hl,(t_draw+2)
            call    phex16
            ld      a,'P'
            call    putc
            ld      a,(painted)
            call    hexa
            ld      a,' '
            call    putc
            ld      a,'L'
            call    putc
            ld      a,(layout)
            call    hexa
            ld      a,' '
            call    putc
            ld      a,'K'
            call    putc
            ld      hl,(tsum+2)
            call    phex16n
            ld      hl,(tsum)
            call    phex16n
            call    crlf
            ld      a,'G'               ; the game: health, ammo, lives, weapon, keys, score digits
            call    putc
            ld      a,(vitality)
            call    hexa
            ld      a,(payload)
            call    hexa
            ld      a,(lives)
            call    hexa
            ld      a,(grip)
            call    hexa
            ld      a,(latchkeys)
            call    hexa
            ld      hl,score
            ld      b,6
rp_g:       ld      a,(hl)
            add     a,'0'
            call    putc
            inc     hl
            djnz    rp_g
            call    crlf
            ld      a,'V'               ; the cull's survivors (object indices)
            call    putc
            ld      a,(olist_n)
            ld      b,a
            call    hexa
            ld      hl,OLIST
            inc     b
            dec     b
            jr      z,rp_vd
rp_v:       ld      a,(hl)
            call    hexa
            inc     hl
            djnz    rp_v
rp_vd:      call    crlf
            ld      a,'D'               ; the draw list (10 bytes an entry)
            call    putc
            ld      a,(dlist_n)
            call    hexa
            ld      a,(dlist_n)
            or      a
            jr      z,rp_dd
            ld      b,a
            ld      hl,DLIST
rp_d1:      ld      c,10
rp_d2:      ld      a,(hl)
            call    hexa
            inc     hl
            dec     c
            jr      nz,rp_d2
            djnz    rp_d1
rp_dd:      call    crlf
            ld      a,'O'               ; the object table (bank 1)
            call    putc
            ld      hl,OBJ
            ld      bc,NOBJ*8
rp_o:       ld      a,(hl)
            call    hexa
            inc     hl
            dec     bc
            ld      a,b
            or      c
            jr      nz,rp_o
            call    crlf
            ifdef   PROF
            call    p_report
            endif
            ret

dump_glass: ld      hl,SCREEN
            ld      c,24
dg_row:     ld      b,80
dg_c:       ld      a,(hl)
            call    hexa
            inc     hl
            djnz    dg_c
            call    crlf
            dec     c
            jr      nz,dg_row
            ret

phex16:     call    phex16n
            ld      a,' '
            jp      putc
phex16n:    ld      a,h
            call    hexa
            ld      a,l
            jp      hexa

putc:       push    af
pw:         in      a,(PRINTER)
            and     $F0
            cp      $30
            jr      nz,pw
            pop     af
            out     (PRINTER),a
            ret
hexa:       push    af
            rrca
            rrca
            rrca
            rrca
            call    nib
            pop     af
nib:        and     15
            add     a,'0'
            cp      '9'+1
            jr      c,putc
            add     a,7
            jr      putc
crlf:       ld      a,13
            jr      putc

            ifdef   PROF
PBUCKETS    equ     VARS+128        ; 5 x 32-bit
prof_mark:  push    af
            ld      b,1
            ld      a,5
            out     (EMU),a             ; DEHL = T since the last mark
            pop     af
            push    de
            add     a,a
            add     a,a
            ld      e,a
            ld      d,0
            ld      ix,PBUCKETS
            add     ix,de
            pop     de
            ld      a,(ix+0)
            add     a,l
            ld      (ix+0),a
            ld      a,(ix+1)
            adc     a,h
            ld      (ix+1),a
            ld      a,(ix+2)
            adc     a,e
            ld      (ix+2),a
            ld      a,(ix+3)
            adc     a,d
            ld      (ix+3),a
            jp      t_reset
p_report:   ld      ix,PBUCKETS
            ld      c,5
pr_l:       ld      a,'B'
            call    putc
            ld      h,(ix+3)
            ld      l,(ix+2)
            call    phex16n
            ld      h,(ix+1)
            ld      l,(ix+0)
            call    phex16
            xor     a
            ld      (ix+0),a
            ld      (ix+1),a
            ld      (ix+2),a
            ld      (ix+3),a
            inc     ix
            inc     ix
            inc     ix
            inc     ix
            dec     c
            jr      nz,pr_l
            jp      crlf
            endif

;;; t_lap: HL = T-states / 16 since the last lap (also summed into tsum), and restart the count
t_lap:      call    t_read
            ld      b,4
tl_s:       srl     d
            rr      e
            rr      h
            rr      l
            djnz    tl_s
            push    hl
            ld      de,(tsum)
            add     hl,de
            ld      (tsum),hl
            ld      hl,(tsum+2)
            ld      de,0
            adc     hl,de
            ld      (tsum+2),hl
            pop     hl
            push    hl
            call    t_reset
            pop     hl
            ret

t_reset:    ld      b,0
            ld      a,5
            out     (EMU),a
            ret
t_read:     ld      b,1
            ld      a,5
            out     (EMU),a             ; DEHL = T-states
            ret
t_quit:     ld      bc,0
            ld      a,128
            out     (EMU),a
            jr      $

            include build/scenario.inc
            endif

            include words.asm
code_end:
            assert  $ <= $8000          ; lower memory ends here (bank 1 begins)

;;; ===========================================================================
;;; THE OVERLAY: run-time code assembled for $2000, carried in bank 1, copied down as the boot's first act
;;; ===========================================================================
            org     OVL_SRC
            phase   OVERLAY
;;; ---------------------------------------------------------------------------
;;; figures_mark: the wall under every figure span of this breath and of the last one is repainted (the ranges of
;;; the last breath are kept in SPRPREV as first/last column pairs); then this breath's ranges become the last
;;; ---------------------------------------------------------------------------
ovl_start:
figures_mark:
            xor     a
            ld      (fig_same),a
            ld      a,(cast_skip)       ; the same rays and the same draw list as last breath: nothing to do at all
            or      a
            jr      z,fm_go
            ld      a,(dlist_n)
            ld      hl,PREVD
            cp      (hl)
            jr      nz,fm_go
            or      a
            jr      z,fm_same
            ld      b,a                 ; n * 10 bytes
            add     a,a
            add     a,a
            add     a,b
            add     a,a
            ld      b,a
            ld      hl,DLIST
            ld      de,PREVD+1
fm_cmp:     ld      a,(de)
            cp      (hl)
            jr      nz,fm_go
            inc     hl
            inc     de
            djnz    fm_cmp
fm_same:    ld      a,1
            ld      (fig_same),a
            ret
fm_go:      ld      a,(dlist_n)         ; keep this draw list for the next breath's test
            ld      (PREVD),a
            or      a
            jr      z,fm_kept
            ld      b,a
            add     a,a
            add     a,a
            add     a,b
            add     a,a
            ld      c,a
            ld      b,0
            ld      hl,DLIST
            ld      de,PREVD+1
            ldir
fm_kept:    ld      a,(layout)
            ld      (fm_sh),a           ; 1: MOVE, a ray covers two columns
            ld      hl,SPRPREV          ; last breath's ranges: count, then (first, last) pairs
            ld      a,(hl)
            inc     hl
            or      a
            jr      z,fm_now
            ld      b,a
fm_pl:      ld      c,(hl)
            inc     hl
            ld      e,(hl)
            inc     hl
            call    fm_range
            djnz    fm_pl
fm_now:     ld      a,(dlist_n)         ; this breath's: mark them, and keep them for the next
            ld      (SPRPREV),a
            or      a
            ret     z
            ld      b,a
            ld      ix,DLIST
            ld      hl,SPRPREV+1
fm_nl:      ld      c,(ix+2)
            ld      e,(ix+3)
            ld      (hl),c
            inc     hl
            ld      (hl),e
            inc     hl
            call    fm_range
            ld      de,10
            add     ix,de
            djnz    fm_nl
            ret
;;; rays of columns C..E dirty (keeps B, HL)
fm_range:   push    hl
            ld      a,(fm_sh)           ; MOVE: rays C/2 .. E/2; FAST: C/4 .. E/4
            or      a
            jr      z,fm_r1
fm_r0:      srl     c
            srl     e
            dec     a
            jr      nz,fm_r0
fm_r1:      ld      h,RB_DIRTY/256
            ld      l,c
            ld      a,e
            sub     c
            inc     a
            ld      c,a
fm_r2:      ld      (hl),1
            inc     l
            dec     c
            jr      nz,fm_r2
            pop     hl
            ret
fm_sh:      defb    0

;;; ---------------------------------------------------------------------------
;;; figures_draw: each figure in the draw list, far to near.  Its plan (whole character rows: a figure is snapped
;;; to them) is patched once into an unrolled ladder - fetch / skip if transparent / store / next row - entered so
;;; that exactly its rows run.  A column is painted only where the wall there is farther (smaller stature) and the
;;; texture column holds any ink.  Moving (MOVE layout), one texel sample paints two columns (the two-wide ladder).
;;; ---------------------------------------------------------------------------
figures_draw:
            ld      a,(fig_same)        ; nothing moved, nothing changed: what is on the glass is right
            or      a
            ret     nz
            ld      a,(dlist_n)
            or      a
            jp      z,fd_done
            ld      ix,DLIST
fd_e:       push    af
            push    ix
            ld      a,(ix+8)            ; slot -> bank port, first page, ink mask
            ld      l,a
            ld      h,0
            add     hl,hl
            push    hl
            ld      de,fig_ink
            add     hl,de
            ld      e,(hl)
            inc     hl
            ld      d,(hl)
            ld      (fd_ink),de
            pop     de
            ld      hl,fig_slots
            add     hl,de
            ld      a,(hl)
            out     (OPREG),a
            inc     hl
            ld      a,(hl)
            ld      (fd_pg+1),a
            ld      a,(ix+1)
            ld      (fd_s+1),a
            ld      a,(ix+3)
            ld      (fd_last+1),a
            ld      l,(ix+6)
            ld      h,(ix+7)
            ld      (fd_st+1),hl        ; texture step
            ld      l,(ix+4)
            ld      h,(ix+5)
            ld      (fd_u),hl
            ld      c,(ix+2)            ; first column
            ld      a,$FF
            ld      (fd_lu),a           ; no texture column bound yet
            ld      l,(ix+1)            ; stature -> plan: first row k, rows n, base rows
            ld      h,0
            add     hl,hl
            ld      de,fp_table
            add     hl,de
            ld      e,(hl)
            inc     hl
            ld      d,(hl)
            ex      de,hl
            ld      a,(hl)              ; k
            inc     hl
            ld      b,(hl)              ; n
            inc     hl
            push    hl
            ld      l,a                 ; glass address of row k, column 0
            ld      h,0
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      e,l
            ld      d,h
            add     hl,hl
            add     hl,hl
            add     hl,de
            ld      de,SCREEN
            add     hl,de
            ld      (fd_row0+1),hl
            ld      a,20                ; entry points: ladder + 8*(20-n), wide ladder + 11*(20-n)
            sub     b
            ld      l,a
            ld      h,0
            add     hl,hl
            add     hl,hl
            add     hl,hl
            push    hl
            ld      de,fig_ladder
            add     hl,de
            ld      (fd_l1+1),hl
            pop     hl
            ld      e,a
            ld      d,0
            add     hl,de
            add     hl,de
            add     hl,de
            ld      de,fig_ladder2
            add     hl,de
            ld      (fd_l2+1),hl
            pop     hl                  ; patch the base rows into both ladders
            ld      ix,(fd_l1+1)
            ld      iy,(fd_l2+1)
            ld      de,8
fd_pt:      ld      a,(hl)
            ld      (ix+2),a
            ld      (iy+2),a
            inc     hl
            add     ix,de
            push    de
            ld      de,11
            add     iy,de
            pop     de
            djnz    fd_pt
            ;; ---- columns ----
fd_c:       ld      b,1                 ; pair? (MOVE layout, and not the last column)
            ld      a,(layout)
            or      a
            jr      z,fd_p1
fd_last:    ld      a,0                 ; (patched) last column
            cp      c
            jr      z,fd_p1
            inc     b
fd_p1:      ld      l,c
            ld      h,ZB/256
            ld      a,(hl)
fd_s:       cp      0                   ; (patched) the figure's stature
            jr      nc,fd_adv           ; a wall at least as near hides this column
            ld      a,(fd_u+1)          ; u = uacc >> 8, at most 15
            cp      16
            jr      c,$+4
            ld      a,15
            ld      e,a
            ld      hl,(fd_ink)         ; any ink in this texture column?
            cp      8
            jr      c,fd_il
            ld      l,h
            sub     8
fd_il:      inc     a
fd_ib:      rr      l
            dec     a
            jr      nz,fd_ib
            jr      nc,fd_adv
            ld      a,e
            ld      hl,fd_lu            ; bind the texture column unless it is the one bound already
            cp      (hl)
            jr      z,fd_bound
            ld      (hl),a
            rrca
            rrca
            rrca
            and     $E0
            ld      ixl,a
            ld      a,e
            srl     a
            srl     a
            srl     a
fd_pg:      add     a,0                 ; (patched) the slot's first page
            ld      ixh,a
fd_bound:
fd_row0:    ld      hl,0                ; (patched) glass row k, column 0
            ld      a,l
            add     a,c
            ld      l,a
            jr      nc,$+3
            inc     h
            ld      de,COLS
            dec     b
            jr      nz,fd_w
fd_l1:      call    0                   ; (patched) the ladder, entered for the figure's rows
            ld      b,1
            jr      fd_adv
fd_w:
fd_l2:      call    0                   ; (patched) the two-wide ladder
            ld      b,2
fd_adv:     ld      hl,(fd_u)           ; one texture step per column covered
fd_st:      ld      de,0                ; (patched)
            add     hl,de
            dec     b
            jr      z,fd_a1
            add     hl,de
            inc     c
fd_a1:      ld      (fd_u),hl
            ld      a,(fd_last+1)
            cp      c                   ; (compare first: INC sets Z of its own)
            jr      z,fd_fig_end
            inc     c
            jp      fd_c
fd_fig_end: pop     ix
            ld      de,10
            add     ix,de
            pop     af
            dec     a
            jp      nz,fd_e
fd_done:    ld      a,PORT_B1
            out     (OPREG),a
            ret

fd_u:       defw    0
fd_ink:     defw    0
fd_lu:      defb    0
;;; the ladders: 20 rows each, a row's displacement at its +2 (patched per figure)
fig_ladder:
            rept    20
            ld      a,(ix+0)
            or      a
            jr      z,$+3
            ld      (hl),a
            add     hl,de
            endm
            ret
fig_ladder2:
            rept    20
            ld      a,(ix+0)
            or      a
            jr      z,$+6
            ld      (hl),a
            inc     hl
            ld      (hl),a
            dec     hl
            add     hl,de
            endm
            ret
ovl_end:
            dephase
            assert  ovl_end - ovl_start <= $1000

;;; ===========================================================================
;;; BANK 1 RESIDENT CODE: runs only with bank 1 in view (port $86)
;;; ===========================================================================
            org     OVL_SRC + ovl_end - ovl_start
;;; ---------------------------------------------------------------------------
;;; THE BOOT BUILDERS (bank 1 in view): the disk carries seeds, the boot grows the ledgers
;;; ---------------------------------------------------------------------------
;;; build_sq: quarter squares SQ(n) = n*n/4 for n = 0..511 by adding: SQ(n+1) = SQ(n) + (n+1)/2.  Lo bytes at
;;; SQ_BASE, hi bytes 512 further on.
build_sq:   ld      hl,0                ; SQ(n)
            ld      de,SQ_BASE          ; -> lo byte of entry n
            ld      bc,0                ; n
bs_l:       ld      a,l
            ld      (de),a
            inc     d
            inc     d
            ld      a,h
            ld      (de),a
            dec     d
            dec     d
            inc     de
            inc     bc
            push    bc
            srl     b
            rr      c                   ; (n+1)/2
            add     hl,bc
            pop     bc
            ld      a,b
            cp      2
            jr      nz,bs_l
            ret

;;; cosq: HL = angle (any 16-bit value, taken mod 512) -> HL = 256*cos, from the quarter-wave seed
cosq:       ld      a,h
            and     1
            ld      h,a                 ; 0..511
            ld      de,129
            or      a
            sbc     hl,de
            jr      nc,cq_q2
            add     hl,de               ; n <= 128: costab[n]
            jr      cq_get
cq_q2:      ld      de,128
            sbc     hl,de               ; n - 257 (carry clear)
            jr      nc,cq_q3
            add     hl,de               ; n - 129 (0..127): -costab[127 - (n-129)] = -costab[256-n]
            ex      de,hl
            ld      hl,127
            or      a
            sbc     hl,de
            call    cq_get
            jr      cq_neg
cq_q3:      ld      de,128
            sbc     hl,de               ; n - 385
            jr      nc,cq_q4
            add     hl,de               ; n - 257 (0..127): -costab[n-256] = -costab[(n-257)+1]
            inc     hl
            call    cq_get
            jr      cq_neg
cq_q4:      ex      de,hl               ; n - 385 (0..126): costab[512-n] = costab[127 - (n-385)]
            ld      hl,127
            or      a
            sbc     hl,de
cq_get:     add     hl,hl
            ld      de,costab
            add     hl,de
            ld      a,(hl)
            inc     hl
            ld      h,(hl)
            ld      l,a
            ret
cq_neg:     xor     a
            sub     l
            ld      l,a
            sbc     a,a
            sub     h
            ld      h,a
            ret

;;; build_rays: 512 records {dx, dy, rcp|dx|, rcp|dy|}, dx = cosq(n), dy = cosq(n-128)
build_rays: ld      ix,RAYS
            ld      bc,0
br_l:       push    bc
            ld      h,b
            ld      l,c
            call    cosq
            ld      (ix+0),l
            ld      (ix+1),h
            call    br_rcp
            ld      (ix+4),l
            ld      (ix+5),h
            pop     bc
            push    bc
            ld      hl,-128
            add     hl,bc
            call    cosq
            ld      (ix+2),l
            ld      (ix+3),h
            call    br_rcp
            ld      (ix+6),l
            ld      (ix+7),h
            ld      de,8
            add     ix,de
            pop     bc
            inc     bc
            ld      a,b
            cp      2
            jr      nz,br_l
            ret
;;; HL = d (signed, |d| <= 256) -> HL = rcp256[|d|]
br_rcp:     bit     7,h
            jr      z,brr_p
            call    cq_neg
brr_p:      add     hl,hl
            ld      de,rcp256
            add     hl,de
            ld      a,(hl)
            inc     hl
            ld      h,(hl)
            ld      l,a
            ret

;;; build_ht: 16 ledger pages from (first value, change count, (index, value)...)
build_ht:   ld      hl,ht_seed
            ld      de,HT_BASE
bh_row:     ld      c,(hl)              ; current value
            inc     hl
            ld      b,(hl)              ; changes
            inc     hl
bh_ch:      ld      a,b
            or      a
            jr      z,bh_tail
            ld      a,(hl)              ; next change index
bh_f:       cp      e
            jr      z,bh_new
            push    af
            ld      a,c
            ld      (de),a
            pop     af
            inc     e
            jr      bh_f
bh_new:     inc     hl
            ld      c,(hl)
            inc     hl
            dec     b
            jr      bh_ch
bh_tail:    ld      a,c                 ; to the end of the page
            ld      (de),a
            inc     e
            jr      nz,bh_tail
            inc     d
            ld      a,d
            cp      HT_BASE/256+16
            jr      nz,bh_row
            ret

;;; mantissas: for every angle, ddx/ddy -> (m, j): dd normalised to 16 bits by z left shifts, m = its top byte,
;;; j = 4*(8-z) (the JR displacement that leaves z right shifts of the ladder).  Bank 1 in view.
mantissas:  ld      hl,RAYS+4
            ld      de,MANT
            ld      b,0                 ; 2 x 256 angles
mt_ang:     push    bc
            call    mt_one              ; x
            call    mt_one              ; y
            ld      a,l
            add     a,4
            ld      l,a
            jr      nc,$+3
            inc     h
            ld      a,e
            add     a,4
            ld      e,a
            jr      nc,$+3
            inc     d
            pop     bc
            dec     b
            jr      nz,mt_ang
            ld      a,h
            cp      RAYS/256+16
            jr      c,mt_ang
            ret
mt_one:     push    hl
            ld      a,(hl)
            inc     hl
            ld      h,(hl)
            ld      l,a                 ; HL = dd
            ld      c,32                ; 4 * 8
mt_n:       bit     7,h
            jr      nz,mt_d
            add     hl,hl
            ld      a,c
            sub     4
            ld      c,a
            jr      mt_n
mt_d:       ld      a,h
            ld      (de),a              ; m
            inc     de
            ld      a,c
            ld      (de),a              ; j
            inc     de
            pop     hl
            inc     hl
            inc     hl
            ret

;;; ---------------------------------------------------------------------------
;;; figures_cull: every breath, the objects worth projecting: every sentinel, and the statics in
;;; the lattice rows near the traveller (they are sorted by row: ystart), within 7 tiles in x and y
;;; ---------------------------------------------------------------------------
figures_cull:
            xor     a
            ld      (olist_n),a
            ld      ix,OBJ
            ld      b,NGUARD
            ld      c,0                 ; object index
fc_g:       call    cull_one
            ld      de,8
            add     ix,de
            inc     c
            djnz    fc_g
            ld      a,(py+1)            ; statics: rows py-6 .. py+6
            sub     6
            jr      nc,$+3
            xor     a
            call    ystart_of           ; HL = first object offset (8 * index)
            push    hl
            ld      a,(py+1)
            add     a,7
            cp      65
            jr      c,$+4
            ld      a,64
            call    ystart_of
            pop     de
            or      a
            sbc     hl,de               ; bytes of objects in the band
            ret     z
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            ld      b,l                 ; count
            ld      ix,OBJ
            add     ix,de
            srl     d
            rr      e
            srl     d
            rr      e
            srl     d
            rr      e
            ld      c,e                 ; first index
fc_s:       call    cull_one
            ld      de,8
            add     ix,de
            inc     c
            djnz    fc_s
            ret
ystart_of:  ld      l,a
            ld      h,0
            add     hl,hl
            ld      de,ystart
            add     hl,de
            ld      a,(hl)
            inc     hl
            ld      h,(hl)
            ld      l,a
            ret
;;; IX -> object, C = its index: a live object within 7 tiles joins the survivors
cull_one:   ld      a,(ix+0)
            or      a
            ret     z
            ld      a,(px+1)
            sub     (ix+2)
            add     a,7
            cp      15
            ret     nc
            ld      a,(py+1)
            sub     (ix+4)
            add     a,7
            cp      15
            ret     nc
            ld      a,(olist_n)
            cp      48
            ret     nc
            ld      e,a
            ld      d,OLIST/256
            ld      a,c
            ld      (de),a
            ld      hl,olist_n
            inc     (hl)
            ret

;;; ---------------------------------------------------------------------------
;;; figures_project: forward f = dx*gx + dy*gy, lateral l = dy*gx - dx*gy (dx, dy in 1/16 tile, gaze >> 2),
;;; both >> 6; stature, width, step and column scale from ledgers indexed by f (no division); the draw list is
;;; kept sorted far to near (stable)
;;; ---------------------------------------------------------------------------
figures_project:
            ld      a,(cast_skip)       ; the traveller still and no object changed: last breath's draw list stands
            or      a
            jr      z,fp_go
            ld      a,(fig_dirty)
            or      a
            ret     z
fp_go:      xor     a
            ld      (fig_dirty),a
            call    rec_of_bearing
            ld      l,(ix+0)
            ld      h,(ix+1)
            sra     h
            rr      l
            sra     h
            rr      l
            ld      a,l
            ld      (cxs),a
            ld      l,(ix+2)
            ld      h,(ix+3)
            sra     h
            rr      l
            sra     h
            rr      l
            ld      a,l
            ld      (cys),a
            xor     a
            ld      (dlist_n),a
            ld      a,(olist_n)
            or      a
            ret     z
            ld      (ocnt),a
            ld      hl,OLIST
fp_l:       push    hl
            ld      l,(hl)              ; object index -> IX
            ld      h,0
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      de,OBJ
            add     hl,de
            push    hl
            pop     ix
            call    proj_one
            pop     hl
            inc     l
            ld      a,(ocnt)
            dec     a
            ld      (ocnt),a
            jr      nz,fp_l
            ret

proj_one:   ld      a,(ix+0)
            or      a
            ret     z
            ld      l,(ix+1)
            ld      h,0
            ld      de,fig_slot
            add     hl,de
            ld      a,(hl)
            cp      $FF
            ret     z
            ld      (pent+8),a          ; slot
            ;; the gaze pre-filter: the tile offset's direction against the bearing, within its tolerance?
            ld      a,(py+1)
            ld      b,a
            ld      a,(ix+4)
            sub     b
            add     a,7
            cp      15
            jr      nc,po_go            ; moved since the cull: no verdict, project it
            ld      e,a
            add     a,a
            add     a,a
            add     a,a
            add     a,a
            sub     e                   ; row * 15
            ld      e,a
            ld      a,(px+1)
            ld      b,a
            ld      a,(ix+2)
            sub     b
            add     a,7
            cp      15
            jr      nc,po_go
            add     a,e
            ld      e,a
            ld      d,0
            ld      hl,gz_tol
            add     hl,de
            ld      a,(hl)
            inc     a
            jr      z,po_go             ; 255: always project (near)
            dec     a
            ld      b,a                 ; tolerance
            ld      hl,gz_ang
            add     hl,de
            ld      a,(bearing+1)
            rra
            ld      a,(bearing)
            rra                         ; bearing / 2 (256 to a turn)
            ld      c,a
            ld      a,(hl)
            sub     c
            jp      p,$+5
            neg                         ; |relative direction| (128 stays 128)
            cp      b
            jr      z,po_go
            ret     nc                  ; outside the view by more than the tolerance
po_go:      ld      h,(ix+2)            ; dx = (ox - px) >> 4, low byte: (x << 4) >> 8
            ld      l,(ix+3)
            ld      de,(px)
            or      a
            sbc     hl,de
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      a,h
            ld      (pdx),a
            ld      h,(ix+4)
            ld      l,(ix+5)
            ld      de,(py)
            or      a
            sbc     hl,de
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      a,h
            ld      (pdy),a
            ;; f16 = (dx*gx + dy*gy) >> 6
            ld      a,(cxs)
            ld      e,a
            ld      a,(pdx)
            call    smul8
            push    hl
            ld      a,(cys)
            ld      e,a
            ld      a,(pdy)
            call    smul8
            pop     de
            add     hl,de
            bit     7,h
            ret     nz                  ; behind
            ld      a,h
            cp      $20
            ret     nc                  ; farther than 8 tiles
            add     hl,hl
            add     hl,hl               ; H = f >> 6
            ld      l,h
            ld      a,l
            cp      4
            ret     c                   ; nearer than 1/4 tile
            cp      128
            ret     nc
            cp      97
            jr      c,po_near
            ld      a,(ix+0)            ; decor and pickups beyond 6 tiles are not worth drawing (sentinels are)
            cp      3
            ret     nz
            ld      a,l
po_near:    ld      (pf16),a
            ;; l16 = (dy*gx - dx*gy) >> 6
            ld      a,(cxs)
            ld      e,a
            ld      a,(pdy)
            call    smul8
            push    hl
            ld      a,(cys)
            ld      e,a
            ld      a,(pdx)
            call    smul8
            pop     de
            ex      de,hl
            or      a
            sbc     hl,de
            ld      a,h                 ; |l| >= 8192: far outside the view
            and     $E0
            jr      z,po_li
            cp      $E0
            ret     nz
po_li:      add     hl,hl
            add     hl,hl
            ld      l,h                 ; l >> 6, sign-extended
            ld      a,h
            rla
            sbc     a,a
            ld      h,a
            ld      (pl16),hl
            bit     7,h                 ; |l16| <= f16, else outside the view
            jr      z,po_p
            xor     a
            sub     l
            ld      l,a
            sbc     a,a
            sub     h
            ld      h,a
po_p:       ld      a,h
            or      a
            ret     nz
            ld      a,(pf16)
            cp      l
            ret     c
            ld      a,l
            ld      (fwv),a              ; (|l16| for a moment)
            ;; the ledgers
            ld      a,(pf16)
            ld      e,a
            ld      d,0
            ld      hl,f_srt
            add     hl,de
            ld      a,(hl)              ; stature
            push    af
            ld      hl,f_sw
            add     hl,de
            ld      a,(hl)
            push    af                  ; width
            ld      hl,f_ustep
            add     hl,de
            add     hl,de
            ld      a,(hl)
            ld      (pent+6),a
            inc     hl
            ld      a,(hl)
            ld      (pent+7),a
            ld      hl,f_kq
            add     hl,de
            add     hl,de
            ld      c,(hl)
            inc     hl
            ld      b,(hl)              ; BC = kq
            ;; off = |l16| * kqH + (|l16| * kqL) >> 8
            push    bc
            ld      a,(fwv)
            ld      e,c
            call    mul8b
            ld      c,h
            pop     de
            push    bc
            ld      a,(fwv)
            ld      e,d
            call    mul8b               ; HL = |l16| * kqH
            pop     bc
            ld      a,l
            add     a,c
            ld      l,a
            jr      nc,$+3
            inc     h                   ; HL = off
            ld      a,(pl16+1)
            bit     7,a
            jr      z,po_r
            xor     a
            sub     l
            ld      l,a
            sbc     a,a
            sub     h
            ld      h,a
po_r:       ld      de,40
            add     hl,de               ; cc
            pop     af                  ; width
            ld      (fwv),a
            srl     a
            ld      e,a
            ld      d,0
            or      a
            sbc     hl,de
            ld      (fc0v),hl            ; c0 = cc - W/2
            ld      a,(fwv)
            ld      e,a
            dec     de                  ; (D = 0)
            add     hl,de
            ld      (fc1v),hl            ; c1 = c0 + W - 1
            pop     af
            ld      (pent+1),a
            ld      a,(pf16)
            ld      (pent+0),a
            bit     7,h
            ret     nz                  ; c1 < 0
            ld      hl,(fc0v)
            bit     7,h
            jr      nz,po_neg
            ld      a,h
            or      a
            ret     nz
            ld      a,l
            cp      COLS
            ret     nc                  ; c0 > 79
            ld      (pent+2),a
            ld      hl,0
            ld      (pent+4),hl
            jr      po_end
po_neg:     xor     a                   ; c0 < 0: start at column 0, the texture accumulator advanced -c0 steps
            ld      (pent+2),a
            sub     l
            ld      (fwv),a              ; -c0 (< 256)
            ld      e,a
            ld      a,(pent+6)
            call    mul8b               ; -c0 * ustep lo
            push    hl
            ld      a,(fwv)
            ld      e,a
            ld      a,(pent+7)
            call    mul8b               ; -c0 * ustep hi (only its low byte counts)
            pop     de
            ld      a,d
            add     a,l
            ld      d,a
            ld      (pent+4),de
po_end:     ld      hl,(fc1v)
            ld      a,h
            or      a
            ld      a,l
            jr      nz,po_cap
            cp      COLS
            jr      c,po_c1
po_cap:     ld      a,COLS-1
po_c1:      ld      (pent+3),a
            ;; insert, far to near: before the first entry with a smaller f16
            ld      a,(dlist_n)
            cp      24
            ret     nc
            ld      b,a
            ld      ix,DLIST
            ld      c,0
po_find:    ld      a,b
            cp      c
            jr      z,po_at
            ld      a,(pent+0)
            cp      (ix+0)
            jr      c,po_nx2            ; the new one is nearer: keep looking
            jr      z,po_nx2            ; as far: stay after it (stable)
            jr      po_at               ; farther: insert here
po_nx2:     ld      de,10
            add     ix,de
            inc     c
            jr      po_find
po_at:      ;; shift entries c..n-1 up by one (from the end), then store at IX
            ld      a,b
            sub     c
            jr      z,po_st
            push    ix
            ld      l,b                 ; HL = DLIST + n*10 - 1 (last byte), DE = +10
            ld      h,0
            add     hl,hl
            ld      e,l
            ld      d,h
            add     hl,hl
            add     hl,hl
            add     hl,de
            ld      de,DLIST-1
            add     hl,de
            ld      e,l
            ld      d,h
            push    hl
            ld      hl,10
            add     hl,de
            ex      de,hl
            pop     hl
            ld      a,b
            sub     c
            ld      c,a                 ; entries to move
            ld      b,0
            push    hl
            ld      l,c
            ld      h,b
            add     hl,hl
            ld      c,l
            ld      b,h
            add     hl,hl
            add     hl,hl
            add     hl,bc
            ld      c,l
            ld      b,h                 ; bytes = entries * 10
            pop     hl
            lddr
            pop     ix
po_st:      push    ix
            pop     de
            ld      hl,pent
            ld      bc,10
            ldir
            ld      hl,dlist_n
            inc     (hl)
            ret

;;; smul8: HL = A * E, both signed bytes
smul8:      ld      c,a
            xor     e
            push    af                  ; bit 7: the sign of the product
            ld      a,c
            bit     7,a
            jr      z,$+4
            neg
            ld      c,a
            ld      a,e
            bit     7,a
            jr      z,$+4
            neg
            ld      e,a
            ld      a,c
            MUL8
            pop     af
            ret     p
            xor     a
            sub     l
            ld      l,a
            sbc     a,a
            sub     h
            ld      h,a
            ret
;;; mul8b: HL = A * E unsigned (bank 1)
mul8b:      MUL8
            ret

            include deeds.asm
            include build/seeds.inc
b1_end:
            assert  $ <= $BC00          ; two figure slots are forged at $BC00-$BFFF
            include build/hidata.inc

            end     start
