;;; WORDS.ASM - the gauge's messages and the weapons' names, in lower memory (bank-1 room is spent)
msg_hbonus:  defb   'PICKED UP A HEALTH BONUS.',0
msg_stim:    defb   'PICKED UP A STIMPACK.',0
msg_medikit: defb   'PICKED UP A MEDIKIT.',0
msg_clip:    defb   'PICKED UP A CLIP.',0
msg_shells:  defb   'PICKED UP 4 SHOTGUN SHELLS.',0
msg_abonus:  defb   'PICKED UP AN ARMOR BONUS.',0
msg_armor:   defb   'PICKED UP THE ARMOR.',0
msg_key:     defb   'PICKED UP A BLUE KEYCARD.',0
msg_kills:   defw   msg_k0,msg_k1,msg_k2,msg_k3
msg_k0:      defb   'A ZOMBIEMAN FALLS.',0
msg_k1:      defb   'A SHOTGUN GUY FALLS.',0
msg_k2:      defb   'AN IMP FALLS.',0
msg_k3:      defb   'A DEMON FALLS.',0
msg_died:    defb   'YOU DIED.  BACK TO THE START.',0
msg_level:   defb   'E1M1 COMPLETE!  THE HANGAR AGAIN...',0

w_fist:     defb    'FIST      '
w_pistol:   defb    'PISTOL    '
w_shotgun:  defb    'SHOTGUN   '
w_chain:    defb    'CHAINGUN  '

