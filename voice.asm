;;; =============================================================================
;;; VOICE.ASM - THE VOICE: the Model 4's one-bit speaker (port $90).  No timer is free to play samples behind the picture, so a
;;; voice is played whole at the end of the breath that asked for it: short tone sweeps and noise bursts, each
;;; segment (kind, half-period in 1/16 delay steps, its change per half-period, half-periods) from voice_tbl.
;;; ===========================================================================
SPEAKER     equ     $90
voice_play: ld      a,(voice_req)
            or      a
            ret     z
            ld      b,a
            xor     a
            ld      (voice_req),a
            ld      a,b
            cp      NVOICES+1
            ret     nc                  ; (not a voice)
            dec     a
            add     a,a
            ld      e,a
            ld      d,0
            ld      hl,voice_tbl
            add     hl,de
            ld      a,(hl)
            inc     hl
            ld      h,(hl)
            ld      l,a
vp_seg:     ld      a,(hl)              ; kind: 0 ends, 1 tone, 2 noise
            or      a
            ret     z
            ld      (vp_kind),a
            inc     hl
            ld      e,(hl)
            inc     hl
            ld      d,(hl)              ; DE = half-period (1/16 steps)
            inc     hl
            ld      a,(hl)
            ld      (vp_dp),a
            inc     hl
            ld      c,(hl)
            inc     hl
            ld      b,(hl)              ; BC = half-periods
            inc     hl
            push    hl
vp_half:    ld      a,(vp_kind)
            cp      2
            jr      z,vp_noise
            ld      a,(vp_lvl)          ; a tone: the speaker flips
            xor     1
            ld      (vp_lvl),a
            jr      vp_out
vp_noise:   ld      a,(vp_lfsr)         ; noise: a bit of the voice's own shift register (the game's dice untouched)
            add     a,a
            jr      nc,$+4
            xor     $1D
            ld      (vp_lfsr),a
            and     1
vp_out:     out     (SPEAKER),a
            push    bc
            ld      a,e                 ; delay: half-period >> 4 steps of NOP, NOP, DJNZ
            rrca
            rrca
            rrca
            rrca
            and     15
            ld      b,a
            ld      a,d
            add     a,a
            add     a,a
            add     a,a
            add     a,a
            or      b
            ld      b,a
vp_d:       nop
            nop
            djnz    vp_d
            pop     bc
            ld      a,(vp_dp)           ; the sweep
            ld      l,a
            rla
            sbc     a,a
            ld      h,a
            add     hl,de
            ex      de,hl
            dec     bc
            ld      a,b
            or      c
            jr      nz,vp_half
            pop     hl
            xor     a
            out     (SPEAKER),a
            jr      vp_seg
vp_kind:    defb    0
vp_dp:      defb    0
vp_lvl:     defb    0
vp_lfsr:    defb    $A5
