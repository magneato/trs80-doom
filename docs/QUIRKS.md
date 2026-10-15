# Model 4 and trs80gp notes

Things I ran into while writing this, found by running small Z80 programs in trs80gp 2.5.5 (George Phillips'
emulator, `-m4`) that report through the printer port and the emulator extensions.

## Traps

| What | How it showed up | What the program does |
|---|---|---|
| The DOS writes a 0 into `$4022` after loading a `/CMD` (TRSDOS 6.2 and LS-DOS 6.3 alike). | One column of one test picture was a row short. | Nothing is loaded into `$4000-$40FF`; that page holds run-time data only. |
| Video RAM writes can be lost unless video wait states are on (port `$EC` bit 5). | A screen byte that did not match the Python copy of the renderer, and moved with timing. | `$60` goes to port `$EC`: 4 MHz and video wait. |
| `INC` sets the Z flag, so `cp c / inc c / jp nz` never ends. | A figure painter that never finished. | Compare, branch, then increment. |
| `LD IY,nn` has a two-byte opcode: a patched operand is at `+2`, not `+1`. | A patch that corrupted its own instruction. | IY patches use `+2`. |
| The variables page holds whatever the DOS left there. | A first sound made of garbage. | The boot clears `$0100-$01FF`. |
| trs80gp's GTK window crashes under native Wayland. | Every run crashed at start. | The scripts set `GDK_BACKEND=x11`. |
| trs80gp's PulseAudio output can abort on a busy host. | A test run that dumped core. | Tests run with `-sx` (no host audio), or `-mute` when recording sound. |

## The machine

* **Banks.** In memory mode 2, port `$84` bits 4-5 pick the upper 32 KB: the main bank or one of the two extra 32 KB
  banks of a 128 KB machine. Video (`$F800`) and the keyboard (`$F400`) stay visible in every bank.
* **Speed.** trs80gp's `-m4` is an early Model 4 with two wait states per instruction; the gate-array models
  (`-m4ga`, `-m4c`) run the same code faster. In the test run E1M1 averages 8.6 frames a second on `-m4` and
  11.2 on `-m4ga`.
* **The clock latch** (port `$E0` bit 2, acknowledged by reading `$EC`) ticks about 58 times a second in trs80gp and
  can be polled with interrupts off.
* **The keyboard matrix** reads 1 for a pressed key, eight rows at `$F401..$F480`.
* **The speaker** is port `$90` bit 0.

## The character ROM

With port `$EC` bit 3 clear, codes 192-255 are special symbols (card suits, smiley faces, Greek letters, small
figures); with it set, they are katakana. Codes 0-31 written straight to video RAM show international letters.
I tried text glyphs as wall shading; it read as letters, not walls, so I took it out. Inverse video (port `$84`
bit 3) turns codes 128-255 into inverse text, so it is no use for the block graphics.

## For testing

* Emulator extensions (`-ee`, port `$47`): a T-state counter, an exit code, screenshots and audio recording. With
  the printer port they make trs80gp a test harness: each test build prints its screen, and a Python copy of the
  renderer has to produce the same bytes.
* `-tr from:to -trpr bc,af` logs every instruction in an address range, with registers.

## Not used

* trs80gp also emulates the Radio Shack hi-res board (640x240) and the Orchestra-85/90 sound cards. This program
  sticks to a stock 128 KB Model 4.
