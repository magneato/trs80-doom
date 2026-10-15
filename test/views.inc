;;; test/views.inc - a scripted walk for the twin comparison: entries of (breaths, fingers, flags)
;;;   fingers: 1 forward, 2 back, 4 left, 8 right, 16 open;  flags: 1 = report + glass, 2 = report only, 8 = + ray buffer
;;;   Every breath casts 80 rays, one per column.
scenario:   defb    1, 0, 1             ; the start view (STILL)
            defb    20, 8, 9            ; turn right 40 units (and the ray buffer)
            defb    1, 0, 9             ; stop: STILL repaints at full width
            defb    30, 1, 1            ; walk forward
            defb    40, 4, 1            ; turn left 80 units
            defb    25, 1, 1            ; walk
            defb    1, 0, 1             ; stop
            defb    64, 8, 1            ; turn right 128 units
            defb    1, 16, 1            ; try a door 
            defb    40, 1, 1            ; walk on
            defb    1, 0, 1             ; stop
            defb    0
