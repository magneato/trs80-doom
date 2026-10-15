;;; =============================================================================
;;; DEEDS.ASM - the second mind: sentinels, discharging, spoils, wounds, armour, mortality, the exit switch.
;;; Resident in bank 1 beside the lattice and the object table it reads; called only while bank 1 is in view.
;;; Four kinds of sentinel (zombieman, shotgun guy, imp, demon): the kind lives in the figure id's high nibble
;;; (id = 48 + 16 * kind + frame), so a frame change keeps it and every rule can look it up in the kind tables.
;;;
;;; Object record (OBJ, 8 bytes): class (0 gone, 1 decor, 2 pickup, 3 sentinel), figure id, x tile, x frac, y tile,
;;; y frac, vitality, state.  A sentinel's state byte: bits 0-2 = 0 stand, 1 chase, 2 shoot, 3 pain, 4 dying;
;;; bits 3-7 = a timer.
;;; Every breath: the fire, the spoils, every sentinel; the gauge is redrawn when something on it changed.
;;; =============================================================================

;;; ---------------------------------------------------------------------------
;;; deeds: once per breath, after the traveller has moved
;;; ---------------------------------------------------------------------------
deeds:      ld      a,(recoil)          ; the weapon's cooldown
            or      a
            jr      z,dd_rc
            dec     a
            ld      (recoil),a
dd_rc:      ld      a,(glare)           ; the muzzle flash fades
            or      a
            jr      z,dd_gl
            dec     a
            ld      (glare),a
dd_gl:      ld      a,(bruise)
            or      a
            jr      z,dd_br
            dec     a
            ld      (bruise),a
dd_br:      ld      a,(fingers)
            and     K_FIRE
            jr      z,dd_nf
            ld      a,(recoil)
            or      a
            call    z,discharge
dd_nf:      ld      a,(payload)         ; weapon in hand: the best one while there is ammo, otherwise the knife
            or      a
            ld      a,(best_grip)
            jr      nz,dd_w
            xor     a
dd_w:       ld      hl,grip
            cp      (hl)
            jr      z,dd_wd
            ld      (hl),a
            call    stale
dd_wd:      call    spoils
            call    sentinels
            jp      mortality

stale:      ld      a,1
            ld      (gauge_stale),a
            ret

;;; 8-bit Galois shift register (taps $1D): A = the next byte of pseudo-random chance
roll_dice:  ld      a,(dice)
            add     a,a
            jr      nc,rd_ok
            xor     $1D
rd_ok:      ld      (dice),a
            ret

;;; add A to the score digit at index B (0 = hundred-thousands .. 5 = ones), the carry rippling left
credit_tally:
            ld      hl,score
            ld      e,b
            ld      d,0
            add     hl,de
ct_l:       add     a,(hl)
            cp      10
            jr      c,ct_s
            sub     10
            ld      (hl),a
            ld      a,1
            ld      de,score
            or      a
            push    hl
            sbc     hl,de
            pop     hl
            jr      z,ct_ov             ; the top digit overflowed: leave it
            dec     hl
            jr      ct_l
ct_s:       ld      (hl),a
ct_ov:      jp      stale

;;; A = lattice row, C = column -> A != 0 when the cell is a wall / door or holds a blocking decoration
blocked_cell:
            push    hl
            push    bc
            ld      b,a
            call    cell_of
            ld      a,(hl)
            or      a
            jr      nz,bc_ret
            ld      a,b                 ; index = row*64 + column -> the blockmap's bit
            rrca
            rrca
            ld      h,a
            and     $C0
            or      c
            ld      l,a
            ld      a,h
            and     $0F
            ld      h,a                 ; HL = cell index
            ld      a,l
            and     7
            ld      c,a
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            ld      de,BLOCKMAP
            add     hl,de
            ld      b,c
            inc     b
            ld      a,(hl)
bc_s:       rrca
            djnz    bc_s
            rlca                        ; bit c of the byte -> bit 0
            and     1
bc_ret:     pop     bc
            pop     hl
            ret

;;; IX -> object: is the line from the traveller to it clear?  7 samples along the way, walls and doors only.
;;; A = 1 clear, 0 blocked
gaze_clear: ld      h,(ix+2)
            ld      l,(ix+3)
            ld      de,(px)
            or      a
            sbc     hl,de
            sra     h
            rr      l
            sra     h
            rr      l
            sra     h
            rr      l
            ld      (lsx),hl            ; an eighth of the way
            ld      h,(ix+4)
            ld      l,(ix+5)
            ld      de,(py)
            or      a
            sbc     hl,de
            sra     h
            rr      l
            sra     h
            rr      l
            sra     h
            rr      l
            ld      (lsy),hl
            ld      hl,(px)
            ld      (lrx),hl
            ld      hl,(py)
            ld      (lry),hl
            ld      b,7
gc_l:       ld      hl,(lrx)
            ld      de,(lsx)
            add     hl,de
            ld      (lrx),hl
            ld      c,h
            ld      hl,(lry)
            ld      de,(lsy)
            add     hl,de
            ld      (lry),hl
            ld      a,h
            push    bc
            call    cell_of
            pop     bc
            ld      a,(hl)
            or      a
            jr      nz,gc_no
            djnz    gc_l
            ld      a,1
            ret
gc_no:      xor     a
            ret

;;; the gaze >> 2 -> dxr, dyr (signed bytes)
facing_vector:
            call    rec_of_bearing
            ld      l,(ix+0)
            ld      h,(ix+1)
            sra     h
            rr      l
            sra     h
            rr      l
            ld      a,l
            ld      (dxr),a
            ld      l,(ix+2)
            ld      h,(ix+3)
            sra     h
            rr      l
            sra     h
            rr      l
            ld      a,l
            ld      (dyr),a
            ret

;;; IX -> object: dxs, dys = (object - traveller) >> 4 (1/16 tile, signed bytes)
offset_from_traveller:
            ld      h,(ix+2)
            ld      l,(ix+3)
            ld      de,(px)
            or      a
            sbc     hl,de
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      a,h
            ld      (dxs),a
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
            ld      (dys),a
            ret

;;; skew = dxr*dys - dyr*dxs (lateral), alignment = dxr*dxs + dyr*dys (forward)
skew_and_alignment:
            push    ix
            ld      a,(dys)
            ld      e,a
            ld      a,(dxr)
            call    smul8
            push    hl
            ld      a,(dxs)
            ld      e,a
            ld      a,(dyr)
            call    smul8
            ex      de,hl
            pop     hl
            or      a
            sbc     hl,de
            ld      (skew),hl
            ld      a,(dxs)
            ld      e,a
            ld      a,(dxr)
            call    smul8
            push    hl
            ld      a,(dys)
            ld      e,a
            ld      a,(dyr)
            call    smul8
            pop     de
            add     hl,de
            ld      (alignment),hl
            pop     ix
            ret

;;; IX -> object: within A tiles of the traveller in x and y?  (carry set = yes)
near_tiles: ld      c,a
            add     a,a
            ld      b,a                 ; window 2A
            ld      a,(px+1)
            ld      e,a
            ld      a,(ix+2)
            sub     e
            add     a,c
            cp      b
            ret     nc
            ld      a,(py+1)
            ld      e,a
            ld      a,(ix+4)
            sub     e
            add     a,c
            cp      b
            ret

;;; ---------------------------------------------------------------------------
;;; discharge: the traveller fires.  The nearest sentinel inside the crosshair with a clear line takes a hit.
;;; ---------------------------------------------------------------------------
discharge:  xor     a
            ld      (blade),a
            ld      a,(payload)
            or      a
            jr      nz,ds_gun
            ld      a,1                 ; no ammo: stab (range 1.5 tiles)
            ld      (blade),a
            jr      ds_go
ds_gun:     dec     a
            ld      (payload),a
ds_go:      ld      a,(grip)            ; cooldown: fist and pistol 8, shotgun 14, chaingun 3 breaths
            ld      e,a
            ld      d,0
            ld      hl,ds_cool
            add     hl,de
            ld      a,(hl)
            ld      (recoil),a
            ld      a,(blade)           ; the weapon's voice
            or      a
            ld      a,0
            jr      nz,ds_v
            ld      a,(grip)
ds_v:       ld      e,a
            ld      d,0
            ld      hl,ds_voice
            add     hl,de
            ld      a,(hl)
            call    play
            ld      a,2
            ld      (glare),a
            call    stale
            call    facing_vector
            ld      hl,$7FFF
            ld      a,(blade)
            or      a
            jr      z,ds_rng
            ld      hl,1536             ; the fist reaches forward distances under 1.5 tiles only
ds_rng:     ld      (bestf),hl
            ld      hl,0
            ld      (bestp),hl
            ld      ix,OBJ
            ld      b,NGUARD
ds_l:       push    bc
            ld      a,(ix+0)
            cp      3
            jr      nz,ds_n
            ld      a,(ix+7)
            and     7
            cp      4
            jr      nc,ds_n             ; dying or dead: not a target
            ld      a,8
            call    near_tiles
            jr      nc,ds_n
            call    offset_from_traveller
            call    skew_and_alignment
            ld      hl,(alignment)
            bit     7,h
            jr      nz,ds_n             ; behind
            ld      a,h
            or      l
            jr      z,ds_n
            ld      hl,(skew)           ; |skew| < 307: a lateral miss under 0.3 tile
            bit     7,h
            jr      z,ds_ap
            call    neg_hl
ds_ap:      ld      de,307
            or      a
            sbc     hl,de
            jr      nc,ds_n
            ld      hl,(alignment)
            ld      de,(bestf)
            or      a
            sbc     hl,de
            jr      nc,ds_n
            call    gaze_clear
            or      a
            jr      z,ds_n
            ld      hl,(alignment)
            ld      (bestf),hl
            ld      (bestp),ix
ds_n:       ld      de,8
            add     ix,de
            pop     bc
            djnz    ds_l
            ld      hl,(bestp)
            ld      a,h
            or      l
            ret     z
            push    hl
            pop     ix
            ld      a,(grip)            ; the shotgun's spread: a second wound
            cp      2
            call    z,wound_sentinel
            ld      a,(ix+7)
            and     7
            cp      4
            ret     nc                  ; (it fell to the first)
            jp      wound_sentinel

ds_voice:   defb    SND_FIST,SND_PISTOL,SND_SHOTGUN,SND_CHAIN
ds_cool:    defb    8,8,14,3

neg_hl:     xor     a
            sub     l
            ld      l,a
            sbc     a,a
            sub     h
            ld      h,a
            ret

;;; IX -> sentinel: damage it (10..25)
wound_sentinel:
            call    roll_dice
            and     15
            add     a,10
            ld      b,a
            ld      a,(ix+6)
            sub     b
            jr      z,ws_dead
            jr      c,ws_dead
            ld      (ix+6),a
            ld      a,1
            ld      (fig_dirty),a
            ld      (ix+7),$43          ; state 3 (pain), timer 8
            ld      a,F_PAIN
            jp      set_frame
ws_dead:    ld      a,1
            ld      (fig_dirty),a
            ld      (ix+6),0
            ld      (ix+7),$94          ; state 4 (dying), timer 18
            ld      a,F_DIE
            call    set_frame
            ld      a,1                 ; +100 points (kept for the tests; the gauge counts kills)
            ld      b,3
            call    credit_tally
            ld      hl,kills
            inc     (hl)
            call    kind_of             ; the death cry: a gurgle for the zombies, a shriek for the beasts
            cp      2
            ld      a,SND_DEATH1
            jr      c,$+4
            ld      a,SND_DEATH2
            call    play
            call    kind_of
            add     a,a
            ld      e,a
            ld      d,0
            ld      hl,msg_kills
            add     hl,de
            ld      a,(hl)
            inc     hl
            ld      h,(hl)
            ld      l,a
            jp      say

;;; set_frame: A = frame (F_*) -> the sentinel's figure id keeps its kind (high nibble)
set_frame:  ld      b,a
            ld      a,(ix+1)
            and     $F0
            or      b
            ld      (ix+1),a
            ret

;;; kind_of: A = the sentinel's kind (0 zombieman, 1 shotgun guy, 2 imp, 3 demon), also kept in (mkind)
kind_of:    ld      a,(ix+1)
            rrca
            rrca
            rrca
            rrca
            and     15
            sub     3
            ld      (mkind),a
            ret

;;; the kind tables: sight cry, attack voice, reach (tiles, 8.8 high byte), attack chance mask, wound mask, base,
;;; walking step (1/256 tile)
k_sight:    defb    SND_SIGHT0,SND_SIGHT1,SND_SIGHT2,SND_SIGHT3
k_voice:    defb    SND_MFIRE,SND_SHOTGUN,SND_FIREBALL,SND_BITE
k_reach:    defb    6,5,6,1
k_chance:   defb    31,31,31,3
k_dmask:    defb    7,15,15,15
k_dbase:    defb    3,4,3,5
k_step:     defb    12,12,12,20
;;; A = kind, HL = a table -> A = the kind's entry
k_get:      ld      e,a
            ld      d,0
            add     hl,de
            ld      a,(hl)
            ret

;;; ---------------------------------------------------------------------------
;;; spoils: a pickup on the traveller's cell (the statics are sorted by row: only his row is searched)
;;; ---------------------------------------------------------------------------
spoils:     ld      a,(py+1)
            call    ystart_of
            push    hl
            ld      a,(py+1)
            inc     a
            call    ystart_of
            pop     de
            or      a
            sbc     hl,de
            ret     z
            srl     h
            rr      l
            srl     h
            rr      l
            srl     h
            rr      l
            ld      b,l
            ld      ix,OBJ
            add     ix,de
sp_l:       push    bc
            ld      a,(ix+0)
            cp      2
            jr      nz,sp_n
            ld      a,(px+1)
            cp      (ix+2)
            jr      nz,sp_n
            ld      a,(ix+1)
            call    spoil_effect
            or      a
            jr      z,sp_n
            ld      (ix+0),0            ; taken
            ld      a,1
            ld      (fig_dirty),a
            call    stale
sp_n:       ld      de,8
            add     ix,de
            pop     bc
            djnz    sp_l
            ret

;;; A = figure id of the pickup -> A = 1 if it was taken (and its voice played, its message shown)
spoil_effect:
            ld      c,a
            ld      hl,spoil_tbl        ; id, kind, amount, voice, message
se_f:       ld      a,(hl)
            cp      $FF
            jp      z,se_no
            cp      c
            jr      z,se_hit
            ld      de,6
            add     hl,de
            jr      se_f
se_hit:     inc     hl
            ld      b,(hl)              ; kind: 0 heal, 1 ammo, 2 weapon, 3 armour bonus, 4 health bonus, 5 armour, 6 key
            inc     hl
            ld      c,(hl)              ; amount
            inc     hl
            ld      a,(hl)
            ld      (se_voice),a
            inc     hl
            ld      e,(hl)
            inc     hl
            ld      d,(hl)
            ld      (se_msg),de
            ld      a,b
            or      a
            jr      z,se_heal
            dec     a
            jr      z,se_ammo
            dec     a
            jr      z,se_weap
            dec     a
            jr      z,se_abon
            dec     a
            jr      z,se_hbon
            dec     a
            jr      z,se_arm
            ld      a,(latchkeys)       ; a key
            or      c
            ld      (latchkeys),a
            jr      se_yes
se_heal:    ld      a,(vitality)
            cp      100
            jr      nc,se_no            ; already healthy: leave it
            add     a,c
            cp      101
            jr      c,$+4
            ld      a,100
            ld      (vitality),a
            jr      se_yes
se_weap:    ld      a,(best_grip)       ; upgrade (never downgrade), +8 ammo
            cp      c
            jr      nc,se_wa
            ld      a,c
            ld      (best_grip),a
se_wa:      ld      c,8
se_ammo:    ld      a,(payload)
            cp      200
            jr      nc,se_no            ; full: leave it
            add     a,c
            cp      201
            jr      c,$+4
            ld      a,200
            ld      (payload),a
            jr      se_yes
se_abon:    ld      a,(armor)           ; an armour bonus: +1, always taken (up to 200)
            cp      200
            jr      nc,se_yes
            inc     a
            ld      (armor),a
            jr      se_yes
se_hbon:    ld      a,(vitality)        ; a health bonus: +1, always taken (up to 100 here)
            cp      100
            jr      nc,se_yes
            inc     a
            ld      (vitality),a
            jr      se_yes
se_arm:     ld      a,(armor)           ; armour: at least C
            cp      c
            jr      nc,se_no
            ld      a,c
            ld      (armor),a
se_yes:     ld      a,(se_voice)
            call    play
            ld      hl,(se_msg)
            call    say
            ld      a,1
            ret
se_no:      xor     a
            ret
se_voice:   defb    0
se_msg:     defw    0

;;; ---------------------------------------------------------------------------
;;; sentinels (the natives' demons and their possessed soldiers)
;;; ---------------------------------------------------------------------------
sentinels:  ld      ix,OBJ
            ld      b,NGUARD
gd_l:       push    bc
            ld      a,(ix+0)
            cp      3
            jr      nz,gd_n
            ld      a,(ix+7)
            and     7
            jr      z,gd_stand
            ld      a,1                 ; an awake sentinel moves or changes its frame: the figures need projecting
            ld      (fig_dirty),a
            ld      a,(ix+7)
            and     7
            dec     a
            jp      z,gd_chase
            dec     a
            jp      z,gd_shoot
            dec     a
            jp      z,gd_pain
            jp      gd_dying
gd_n:       ld      de,8
            add     ix,de
            pop     bc
            djnz    gd_l
            ret

gd_stand:   ld      a,7                 ; look for the traveller
            call    near_tiles
            jr      nc,gd_n
            call    gaze_clear
            or      a
            jr      z,gd_n
            call    kind_of             ; its cry - and the chase
            ld      hl,k_sight
            call    k_get
            call    play
            ld      (ix+7),1
            ld      a,1
            ld      (fig_dirty),a
            jr      gd_n

gd_chase:   ld      a,(breaths)         ; the walk
            rrca
            rrca
            rrca
            and     3
            add     a,F_WALK
            call    set_frame
            call    kind_of
            ld      hl,(px)             ; direction sentinel -> traveller
            ld      d,(ix+2)
            ld      e,(ix+3)
            or      a
            sbc     hl,de
            ld      (gdx),hl
            bit     7,h
            call    nz,neg_hl
            ld      (gsx),hl
            ld      hl,(py)
            ld      d,(ix+4)
            ld      e,(ix+5)
            or      a
            sbc     hl,de
            ld      (gdy),hl
            bit     7,h
            call    nz,neg_hl
            ld      (gsy),hl
            ld      de,$00C0            ; close enough to stop?
            ld      hl,(gsx)
            or      a
            sbc     hl,de
            jr      nc,gc_move
            ld      hl,(gsy)
            or      a
            sbc     hl,de
            jr      c,gc_fire
gc_move:    ld      hl,(gsx)            ; step along the larger axis first, the other if blocked
            ld      de,(gsy)
            or      a
            sbc     hl,de
            jr      c,gc_y
            call    sentinel_step_x
            jr      nz,gc_fire
            call    sentinel_step_y
            jr      gc_fire
gc_y:       call    sentinel_step_y
            jr      nz,gc_fire
            call    sentinel_step_x
gc_fire:    ld      a,(mkind)           ; attack: within the kind's reach, by its chance, along a clear line
            ld      hl,k_reach
            call    k_get
            ld      d,a
            ld      e,$40               ; (a demon's reach of 1 is 1.25 tiles)
            ld      hl,(gsx)
            or      a
            sbc     hl,de
            jp      nc,gd_n
            ld      hl,(gsy)
            or      a
            sbc     hl,de
            jp      nc,gd_n
            ld      a,(mkind)
            ld      hl,k_chance
            call    k_get
            ld      b,a
            call    roll_dice
            and     b
            jp      nz,gd_n
            call    gaze_clear
            or      a
            jp      z,gd_n
            ld      (ix+7),$72          ; state 2 (shoot), timer 14
            ld      a,F_SHOOT
            call    set_frame
            jp      gd_n

;;; step the sentinel (IX) 3/64 tile toward the traveller on x / y unless blocked.  Z clear when it moved.
sentinel_step_x:
            ld      h,(ix+2)
            ld      l,(ix+3)
            call    step_de
            ld      a,(gdx+1)
            bit     7,a
            call    nz,neg_de
sx_p:       add     hl,de
            push    hl
            ld      c,h
            ld      a,(ix+4)
            call    blocked_cell
            pop     hl
            or      a
            jr      nz,sx_blk
            ld      (ix+2),h
            ld      (ix+3),l
            inc     a                   ; NZ
            ret
sx_blk:     xor     a                   ; Z
            ret
sentinel_step_y:
            ld      h,(ix+4)
            ld      l,(ix+5)
            call    step_de
            ld      a,(gdy+1)
            bit     7,a
            call    nz,neg_de
sy_p:       add     hl,de
            push    hl
            ld      c,(ix+2)
            ld      a,h
            call    blocked_cell
            pop     hl
            or      a
            jr      nz,sx_blk
            ld      (ix+4),h
            ld      (ix+5),l
            inc     a
            ret

step_de:    push    hl                  ; DE = the kind's walking step
            ld      a,(mkind)
            ld      hl,k_step
            call    k_get
            pop     hl
            ld      e,a
            ld      d,0
            ret
neg_de:     xor     a
            sub     e
            ld      e,a
            sbc     a,a
            sub     d
            ld      d,a
            ret

gd_shoot:   call    kind_of
            ld      a,(ix+7)
            sub     8                   ; timer--
            ld      (ix+7),a
            rrca
            rrca
            rrca
            and     31
            cp      7
            jr      nz,gs_t
            ld      a,F_SHOOT+1         ; the shot
            call    set_frame
            ld      a,(mkind)
            ld      hl,k_voice
            call    k_get
            call    play
            call    roll_dice
            and     3
            jp      z,gd_n              ; a miss
            ld      a,(mkind)
            ld      hl,k_dmask
            call    k_get
            ld      b,a
            call    roll_dice
            and     b
            ld      b,a
            ld      a,(mkind)
            ld      hl,k_dbase
            call    k_get
            add     a,b
            call    strike_traveller
            jp      gd_n
gs_t:       or      a
            jp      nz,gd_n
            ld      (ix+7),1            ; back to the chase
            jp      gd_n
gd_pain:    ld      a,(ix+7)
            sub     8
            ld      (ix+7),a
            and     $F8
            jp      nz,gd_n
            ld      (ix+7),1
            ld      a,F_WALK
            call    set_frame
            jp      gd_n
gd_dying:   ld      a,(ix+7)
            sub     8
            ld      (ix+7),a
            rrca
            rrca
            rrca
            and     31
            jr      z,gdy_dead
            ld      b,F_DIE
            cp      13
            jr      nc,gdy_s
            inc     b
            cp      7
            jr      nc,gdy_s
            inc     b
gdy_s:      ld      a,b
            call    set_frame
            jp      gd_n
gdy_dead:   ld      (ix+0),1            ; a corpse: a harmless static
            ld      a,F_DEAD
            call    set_frame
            jp      gd_n

;;; A = damage to the traveller; armour takes a third of it (DOOM's green armour)
strike_traveller:
            ld      b,a
            ld      a,(armor)
            or      a
            jr      z,st_raw
            ld      a,b                 ; about a third: B/4 + B/16
            srl     a
            srl     a
            ld      c,a
            srl     a
            srl     a
            add     a,c
            ld      c,a
            ld      a,(armor)
            sub     c
            jr      nc,st_a
            add     a,c                 ; not enough armour left: it takes what it has
            ld      c,a
            xor     a
st_a:       ld      (armor),a
            ld      a,b
            sub     c
            ld      b,a
st_raw:
            ld      a,(vitality)
            sub     b
            jr      nc,$+3
            xor     a
            ld      (vitality),a
            ld      a,12
            ld      (bruise),a
            jp      stale

;;; ---------------------------------------------------------------------------
;;; mortality: no vitality - a life lost (the last one: the score starts over), back at the start with a clip
;;; ---------------------------------------------------------------------------
mortality:  ld      a,(vitality)
            or      a
            ret     nz
            ld      a,SND_PLDEATH
            call    play
            ld      hl,msg_died
            call    say
            ld      a,(lives)
            dec     a
            jr      nz,md_live
            ld      hl,score            ; game over: start over
            ld      b,6
md_z:       ld      (hl),0
            inc     hl
            djnz    md_z
            ld      a,3
md_live:    ld      (lives),a
            call    traveller_reborn
            jp      to_start

traveller_reborn:
            ld      a,100
            ld      (vitality),a
            ld      a,50                ; DOOM's start: a pistol and 50 bullets, no armour
            ld      (payload),a
            ld      a,1
            ld      (grip),a
            ld      (best_grip),a
            xor     a
            ld      (latchkeys),a
            ld      (armor),a
            jp      stale

;;; the traveller back at the start, facing as the level begins
to_start:   ld      hl,START_X*256+$80
            ld      (px),hl
            ld      hl,START_Y*256+$80
            ld      (py),hl
            ld      hl,START_ANG
            ld      (bearing),hl
            jp      stale

;;; ---------------------------------------------------------------------------
;;; stage_cleared: the exit switch.  +5000 (for the tests), the doors closed again, the traveller back at the start.
;;; ---------------------------------------------------------------------------
stage_cleared:
            ld      a,SND_LEVEL
            call    play
            ld      a,5
            ld      b,2
            call    credit_tally
            ld      hl,door_list
            ld      de,door_kind
            ld      b,NDOORS
sc_d:       push    bc
            ld      c,(hl)
            inc     hl
            ld      b,(hl)
            inc     hl
            ld      a,(de)
            inc     de
            ld      (bc),a
            pop     bc
            djnz    sc_d
            ld      a,1                 ; the doors moved: cast again
            ld      (recast),a
            ld      hl,msg_level
            call    say
            ld      hl,(levels)
            inc     hl
            ld      (levels),hl
            jp      to_start

;;; play: A = a voice (0 = none): queued for the voice (the sound engine picks it up)
play:       or      a
            ret     z
            ld      (voice_req),a
            ret

;;; say: HL -> a message for the gauge's last row (shown for a while)
say:        ld      (msg_ptr),hl
            ld      a,90
            ld      (msg_time),a
            ld      a,1
            ld      (msg_new),a
            ret

;;; the spoils: figure id, kind (0 heal 1 ammo 2 weapon 3 armour bonus 4 health bonus 5 armour 6 key), amount, voice,
;;; message
spoil_tbl:  defb    0, 4, 1,   SND_ITEM
            defw    msg_hbonus
            defb    1, 0, 10,  SND_HEALTH
            defw    msg_stim
            defb    2, 0, 25,  SND_HEALTH
            defw    msg_medikit
            defb    3, 1, 10,  SND_AMMO
            defw    msg_clip
            defb    4, 1, 8,   SND_AMMO
            defw    msg_shells
            defb    5, 3, 1,   SND_ITEM
            defw    msg_abonus
            defb    6, 5, 100, SND_ARMOR
            defw    msg_armor
            defb    7, 6, 1,   SND_KEY
            defw    msg_key
            defb    $FF

;;; (the messages live in lower memory: words.asm)

;;; ===========================================================================
;;; THE GAUGE (rows 20-23): plain text, the marine's face and a health bar in block characters
;;;   row 20  a thin rule under the view
;;;   row 21  HEALTH  ARMOR  AMMO  the weapon in hand  KILLS n/N  KEYS
;;;   row 22  E1M1, the health bar: 50 characters, one block pixel per point of health
;;;   row 23  messages (pickups, a sentinel down, the exit)
;;; ===========================================================================
G_ROW       equ     SCREEN+20*80
gauge_init: ld      hl,G_ROW            ; the rule: the top block row of every character
            ld      b,80
gi_r:       ld      (hl),$83
            inc     hl
            djnz    gi_r
            ld      hl,g_labels
gi_l:       ld      e,(hl)              ; (address, text) pairs, address 0 ends
            inc     hl
            ld      d,(hl)
            inc     hl
            ld      a,d
            or      e
            jr      z,gi_d
gi_c:       ld      a,(hl)
            inc     hl
            or      a
            jr      z,gi_l
            ld      (de),a
            inc     de
            jr      gi_c
gi_d:       ld      a,$FF
            ld      (face_shown),a
            ld      a,1
            ld      (gauge_stale),a
            ret
g_labels:   defw    G_ROW+80+9
            defb    'HEALTH',0
            defw    G_ROW+80+22
            defb    'ARMOR',0
            defw    G_ROW+80+34
            defb    'AMMO',0
            defw    G_ROW+80+56
            defb    'KILLS',0
            defw    G_ROW+80+66
            defb    '/',0
            defw    G_ROW+80+71
            defb    'KEY',0
            defw    G_ROW+2*80+61
            defb    'E1M1  HANGAR',0
            defw    0

;;; gauge_update: once a breath.  The numbers, the weapon, the keys and the bar only when something changed (stale);
;;; the face when its health band changes; the message line counts down.
gauge_update:
            ld      a,(msg_new)
            or      a
            jr      z,gu_mt
            xor     a
            ld      (msg_new),a
            call    gu_msg_clear
            ld      hl,(msg_ptr)
            ld      de,G_ROW+3*80+9
gu_mc:      ld      a,(hl)
            or      a
            jr      z,gu_mt
            ld      (de),a
            inc     hl
            inc     de
            jr      gu_mc
gu_mt:      ld      a,(msg_time)
            or      a
            jr      z,gu_st
            dec     a
            ld      (msg_time),a
            call    z,gu_msg_clear
gu_st:      ld      a,(gauge_stale)
            or      a
            ret     z
            xor     a
            ld      (gauge_stale),a
            ld      a,(vitality)        ; HEALTH nnn%
            ld      de,G_ROW+80+16
            call    dec3
            ld      a,'%'
            ld      (de),a
            ld      a,(armor)           ; ARMOR nnn%
            ld      de,G_ROW+80+28
            call    dec3
            ld      a,'%'
            ld      (de),a
            ld      a,(payload)         ; AMMO nnn
            ld      de,G_ROW+80+39
            call    dec3
            ld      a,(grip)            ; the weapon in hand
            add     a,a
            ld      e,a
            ld      d,0
            ld      hl,g_weapons
            add     hl,de
            ld      a,(hl)
            inc     hl
            ld      h,(hl)
            ld      l,a
            ld      de,G_ROW+80+44
            ld      b,10
gu_w:       ld      a,(hl)
            ld      (de),a
            inc     hl
            inc     de
            djnz    gu_w
            ld      a,(kills)           ; KILLS nnn/NN
            ld      de,G_ROW+80+62
            call    dec3
            ld      a,NGUARD
            ld      de,G_ROW+80+67
            call    dec3
            ld      a,(latchkeys)       ; the keycard
            ld      hl,G_ROW+80+75
            ld      (hl),' '
            or      a
            jr      z,$+4
            ld      (hl),$BF            ; a solid block: the card
            ;; the health bar: H/2 full characters, a half one for an odd H, the rest blank (50 wide)
            ld      hl,G_ROW+2*80+9
            ld      a,(vitality)
            ld      c,a
            ld      b,50
gu_b:       ld      a,c
            cp      2
            jr      c,gu_b1
            ld      (hl),$BF            ; both pixels
            sub     2
            ld      c,a
            jr      gu_bn
gu_b1:      or      a
            ld      (hl),$80            ; empty
            jr      z,gu_bn
            ld      (hl),$95            ; the left pixel column
            ld      c,0
gu_bn:      inc     hl
            djnz    gu_b
            ;; the face: dead = 7, otherwise band = min(6, (100 - health) / 15)
            ld      a,(vitality)
            ld      b,7
            or      a
            jr      z,gu_fb
            ld      c,a
            ld      a,100
            sub     c
            ld      b,0
            jr      c,gu_fb             ; (over 100: the healthy face)
gu_fd:      sub     15
            jr      c,gu_fc6
            inc     b
            jr      gu_fd
gu_fc6:     ld      a,b
            cp      7
            jr      c,gu_fb
            ld      b,6
gu_fb:      ld      a,b
            ld      hl,face_shown
            cp      (hl)
            ret     z
            ld      (hl),a
            ld      l,a                 ; 18 bytes a face
            ld      h,0
            add     hl,hl
            ld      e,l
            ld      d,h
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,de
            ld      de,faces
            add     hl,de
            ld      de,G_ROW+80+1
            ld      c,3
gu_fr:      push    de
            ld      b,6
gu_fc:      ld      a,(hl)
            ld      (de),a
            inc     hl
            inc     de
            djnz    gu_fc
            pop     de
            ex      de,hl
            ld      a,c
            ld      bc,80
            add     hl,bc
            ld      c,a
            ex      de,hl
            dec     c
            jr      nz,gu_fr
            ret

gu_msg_clear:
            ld      hl,G_ROW+3*80+9
            ld      b,60
gu_mcl:     ld      (hl),' '
            inc     hl
            djnz    gu_mcl
            ret

;;; dec3: A (0..255) -> 3 characters at DE (leading blanks); DE left after them
dec3:       ld      c,' '
            ld      b,'0'-1
d3_h:       inc     b
            sub     100
            jr      nc,d3_h
            add     a,100
            push    af
            ld      a,b
            cp      '0'
            jr      z,d3_hb
            ld      c,'0'               ; a hundreds digit: tens shown even when 0
            jr      d3_hs
d3_hb:      ld      a,' '
d3_hs:      ld      (de),a
            inc     de
            pop     af
            ld      b,'0'-1
d3_t:       inc     b
            sub     10
            jr      nc,d3_t
            add     a,10
            push    af
            ld      a,b
            cp      '0'
            jr      nz,d3_ts
            ld      a,c                 ; a leading zero tens digit stays blank
d3_ts:      ld      (de),a
            inc     de
            pop     af
            add     a,'0'
            ld      (de),a
            inc     de
            ret

g_weapons:  defw    w_fist, w_pistol, w_shotgun, w_chain

;;; ===========================================================================
;;; THE COLD MIND (the natives named it Terminator; it is an autopilot).  The way to the exit switch was worked out
;;; when the disk was built (DIRFIELD: per cell, 2 bits - the step toward the goal); each thinking breath it walks
;;; toward the next cell's centre, steering by the cross and dot product of (facing, direction) - no atan, no
;;; division - opens doors, and at the goal turns to face the switch and presses it.  Sentinels in sight come first.
;;; ===========================================================================
;;; mind_step: ORs its fingers into (fingers)
mind_step:  ld      hl,(px)             ; stuck: no movement for 80 breaths -> back off and turn for 48
            ld      de,(lpx)
            or      a
            sbc     hl,de
            jr      nz,ms_moved
            ld      hl,(py)
            ld      de,(lpy)
            or      a
            sbc     hl,de
            jr      nz,ms_moved
            ld      a,(wedged)
            inc     a
            ld      (wedged),a
            cp      80
            jr      c,ms_still
            xor     a
            ld      (wedged),a
            ld      a,48
            ld      (retreat),a
            jr      ms_still
ms_moved:   xor     a
            ld      (wedged),a
ms_still:   ld      hl,(px)
            ld      (lpx),hl
            ld      hl,(py)
            ld      (lpy),hl
            ld      a,(retreat)
            or      a
            jr      z,ms_nav
            dec     a
            ld      (retreat),a
            ld      a,K_BACK+K_RIGHT
            jp      ms_or
ms_nav:     call    stalk_prey          ; a living sentinel in sight first
            or      a
            ret     nz
            ld      a,(px+1)            ; at the goal?
            cp      GOAL_X
            jr      nz,ms_go
            ld      a,(py+1)
            cp      GOAL_Y
            jp      z,at_the_door
ms_go:      ld      a,(py+1)            ; the cell index -> its 2 bits in the field
            ld      c,a
            ld      a,(px+1)
            ld      b,a
            ld      l,c
            ld      h,0
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            add     hl,hl
            ld      e,b
            ld      d,0
            add     hl,de               ; HL = y*64 + x
            ld      a,l
            and     3
            ld      e,a                 ; which pair of bits
            srl     h
            rr      l
            srl     h
            rr      l
            ld      de,DIRFIELD
            add     hl,de
            ld      a,(px+1)
            and     3
            ld      d,a
            ld      a,(hl)
            inc     d
ms_sh:      dec     d
            jr      z,ms_dir
            rrca
            rrca
            jr      ms_sh
ms_dir:     and     3                   ; 0 east, 1 south, 2 west, 3 north -> the next cell
            ld      hl,ms_steps
            add     a,a
            ld      e,a
            ld      d,0
            add     hl,de
            ld      a,(px+1)
            add     a,(hl)
            ld      (tgx),a
            inc     hl
            ld      a,(py+1)
            add     a,(hl)
            ld      (tgy),a
            ;; direction to the target cell's centre >> 2 (signed bytes)
            ld      a,(tgx)
            ld      h,a
            ld      l,$80
            ld      de,(px)
            or      a
            sbc     hl,de
            sra     h
            rr      l
            sra     h
            rr      l
            ld      a,l
            ld      (dxs),a
            ld      a,(tgy)
            ld      h,a
            ld      l,$80
            ld      de,(py)
            or      a
            sbc     hl,de
            sra     h
            rr      l
            sra     h
            rr      l
            ld      a,l
            ld      (dys),a
            call    facing_vector
            call    skew_and_alignment
            ld      hl,(skew)
            bit     7,h
            call    nz,neg_hl
            ld      (skew_abs),hl
            ld      c,0                 ; the fingers it presses
            ld      hl,(alignment)      ; forward when facing it: dot > 0 and |cross| < dot/4
            bit     7,h
            jr      nz,ms_turn
            sra     h
            rr      l
            sra     h
            rr      l
            ld      de,(skew_abs)
            or      a
            sbc     hl,de
            jr      c,ms_chk8
            jr      z,ms_chk8
            set     0,c                 ; K_FWD
ms_chk8:    ld      hl,(alignment)      ; steer when |cross| > dot/8
            sra     h
            rr      l
            sra     h
            rr      l
            sra     h
            rr      l
            ld      de,(skew_abs)
            or      a
            sbc     hl,de
            jr      nc,ms_door
ms_turn:    ld      a,(skew+1)
            bit     7,a
            jr      nz,ms_left
            set     3,c                 ; K_RIGHT
            jr      ms_door
ms_left:    set     2,c                 ; K_LEFT
ms_door:    ld      a,(tgy)             ; the target cell a door: USE
            push    bc
            ld      b,a
            ld      a,(tgx)
            ld      c,a
            ld      a,b
            call    cell_of
            pop     bc
            ld      a,(hl)
            cp      DOOR_CODE
            jr      z,ms_use
            cp      ELEV_CODE
            jr      nz,ms_k
ms_use:     set     4,c                 ; K_USE
ms_k:       ld      a,c
ms_or:      ld      hl,fingers
            or      (hl)
            ld      (hl),a
            ret
ms_steps:   defb    1,0, 0,1, -1,0, 0,-1

;;; at the goal cell: face the switch, then USE it
at_the_door:
            xor     a
            ld      (wedged),a
            ld      hl,GOAL_ANG         ; (GOAL_ANG - bearing) mod 512
            ld      de,(bearing)
            or      a
            sbc     hl,de
            ld      a,h
            and     1
            ld      h,a
            ld      de,8
            or      a
            sbc     hl,de
            jr      c,ag_use            ; within 8 units
            add     hl,de
            ld      de,504
            or      a
            sbc     hl,de
            jr      nc,ag_use
            add     hl,de
            ld      de,256
            or      a
            sbc     hl,de
            ld      a,K_RIGHT
            jr      c,ms_or
            ld      a,K_LEFT
            jr      ms_or
ag_use:     ld      hl,GOAL_ANG         ; snap exactly: a few units off and the 1-tile probe lands beside the switch
            ld      (bearing),hl
            ld      a,K_USE
            jr      ms_or

;;; stalk_prey: a living sentinel within 8 tiles, in a clear line: aim, fire (close in when far).  A = 1 if engaged.
stalk_prey: ld      a,(chase_nap)       ; gave up on an unreachable target lately: just navigate
            or      a
            jr      z,sp_w
            dec     a
            ld      (chase_nap),a
            xor     a
            ret
sp_w:       call    stalk_core
            or      a
            jr      z,sp_none
            ld      a,(chase_age)       ; 250 breaths of chasing without a result: ignore sentinels for 250 breaths
            inc     a
            ld      (chase_age),a
            cp      250
            ld      a,1
            ret     c
            xor     a
            ld      (chase_age),a
            ld      a,250
            ld      (chase_nap),a
            ld      a,1
            ret
sp_none:    ld      (chase_age),a
            ret
stalk_core: call    facing_vector
            ld      ix,OBJ
            ld      b,NGUARD
sk_l:       push    bc
            ld      a,(ix+0)
            cp      3
            jr      nz,sk_n
            ld      a,(ix+7)
            and     7
            cp      4
            jr      nc,sk_n
            ld      a,8
            call    near_tiles
            jr      nc,sk_n
            call    offset_from_traveller
            call    skew_and_alignment
            call    gaze_clear
            or      a
            jr      nz,sk_found
sk_n:       ld      de,8
            add     ix,de
            pop     bc
            djnz    sk_l
            xor     a
            ret
sk_found:   pop     bc
            ld      hl,(skew)
            bit     7,h
            call    nz,neg_hl
            ld      de,250              ; lateral miss under ~0.25 tile -> fire
            or      a
            sbc     hl,de
            jr      c,sk_aim
            add     hl,de
            ld      (skew_abs),hl
            ld      hl,(alignment)      ; within ~14 degrees: fine aim, one unit a breath (keys would overshoot)
            bit     7,h
            jr      nz,sk_key
            sra     h
            rr      l
            sra     h
            rr      l
            ld      de,(skew_abs)
            or      a
            sbc     hl,de
            jr      c,sk_key
            ld      hl,(bearing)
            ld      a,(skew+1)
            bit     7,a
            jr      nz,sk_fl
            inc     hl
            jr      sk_fs
sk_fl:      dec     hl
sk_fs:      ld      a,h
            and     1
            ld      h,a
            ld      (bearing),hl
            ld      a,1
            ret
sk_key:     ld      a,(skew+1)
            bit     7,a
            ld      a,K_RIGHT
            jr      z,$+4
            ld      a,K_LEFT
            call    ms_or
            ld      a,1
            ret
sk_aim:     ld      c,K_FIRE
            ld      hl,(alignment)
            ld      de,3072             ; gun: farther than 3 tiles -> close in while firing
            ld      a,(payload)
            or      a
            jr      nz,sk_cm
            ld      de,1024             ; knife: close in to about a tile
sk_cm:      or      a
            sbc     hl,de
            jr      c,sk_k
            jr      z,sk_k
            set     0,c                 ; K_FWD
sk_k:       ld      a,c
            call    ms_or
            ld      a,1
            ret

;;; mind_toggle: T pressed (edge): the cold mind takes over, or hands back
mind_toggle:
            ld      a,(machine_mind)
            xor     1
            ld      (machine_mind),a
            ld      hl,msg_mind_on
            jr      nz,$+5
            ld      hl,msg_mind_off
            jp      say
msg_mind_on:  defb  'TERMINATOR ENGAGED  (T HANDS BACK)',0
msg_mind_off: defb  'YOUR TURN',0

