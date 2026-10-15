;;; test/prof.inc - single breaths reported with the phase timers (EXTRA_DEFS=-DPROF): an open hall, then the start
scenario:   defb    255
            defw    $3380, $2E80, 320
            defb    1, 0, 2             ; (the first breath includes the boot: ignore it)
            defb    1, 8, 2             ; turning (MOVE, 40 rays)
            defb    1, 8, 2
            defb    255
            defw    $1D80, $3980, 0
            defb    1, 8, 2
            defb    1, 8, 2
            defb    0
