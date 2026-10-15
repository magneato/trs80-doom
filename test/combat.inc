;;; test/combat.inc - teleport into E1M1's south-east hall and hold FIRE: the sentinels wake, fight and fall; ammo,
;;; health and the tally change.  The speaker is recorded meanwhile (254 toggles trs80gp's audio recording).
scenario:   defb    255
            defw    $3380, $2E80, 320
            defb    254                 ; record the speaker
            defb    1, 0, 33            ; report + glass + screenshot
            defb    40, 64, 33          ; fire
            defb    40, 64, 33
            defb    40, 64, 33
            defb    60, 0, 33           ; and wait
            defb    254
            defb    0
