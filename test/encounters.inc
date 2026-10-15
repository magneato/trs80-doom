;;; test/encounters.inc - for people, not a gate: teleport 1.5 tiles from a dozen sentinels, facing it;
;;; screenshot, fire, screenshot
scenario:
            defb    255
            defw    $3300, $0880, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $3200, $0980, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $0900, $0A80, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $0D00, $0B80, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $1900, $0C80, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $1780, $0D00, 128
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $0A00, $1080, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $1000, $1180, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $1000, $1380, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $2100, $1380, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $0800, $1580, 256
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    255
            defw    $1800, $1780, 0
            defb    5, 0, 0
            defb    1, 0, 32            ; face to face
            defb    3, 64, 0            ; fire
            defb    4, 0, 32
            defb    0
