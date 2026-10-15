;;; test/guards.inc - teleport into E1M1's south-east hall (a zombieman, a shotgun guy and an imp in view), look
;;; around: screenshots + glasses
scenario:   defb    255
            defw    $3380, $2E80, 320   ; tile (51.5, 46.5), facing north-west
            defb    1, 0, 33            ; report + glass + screenshot
            defb    16, 8, 33           ; turn right
            defb    32, 4, 33           ; turn left
            defb    1, 0, 33
            defb    0
