# Figment specification

Figment is a made-up 8-bit console. This file defines the machine, so that the emulator, the assembler and the test programs agree on encodings, flags and wrapping. Each part names the milestone that implements it. A part marked with a later milestone is designed but not built yet.

| Milestone | Adds |
| --- | --- |
| 1 | Registers, flags, `HLT`, `LDI`, `MOV`, `ADD`, `ADC`, `SUB`, `SBC`, the host interface |
| 2 | Every other instruction in this file |
| 3 | The assembler |
| 4 | The screen on a page, the palette colors, the terminal renderer |
| 5 | Keys, the beeper, random, timing |
| 6 | Constants, `lo` and `hi`, and local labels in the assembler |

## The machine

- 32,768 bytes of memory. An address is 15 bits.
- 16 general registers, `r0` to `rF`, 8 bits each.
- `PC`, the program counter, 15 bits.
- `SP`, the stack pointer, 15 bits.
- Two flags, `Z` (zero) and `C` (carry). They are not part of any register. Only the instructions in the flag tables change them, and only `ADC`, `SBC` and the conditional jumps read them.
- A state, which is running, halted or faulted.

All arithmetic wraps. An 8-bit result keeps its low 8 bits, and `PC` and `SP` wrap from `0x7FFF` to `0x0000` and back. Wherever a 16-bit value is used as an address, the machine ignores the top bit, so `0x8000` means `0x0000`. Multi-byte values are little-endian, low byte first.

## Memory map

| Range | Use |
| --- | --- |
| `0x0000` to `0x3EFF` | Program and RAM. The program is loaded at `0x0000` |
| `0x3F00` to `0x3FFF` | I/O page for keys, the beeper, random and frames (milestone 5) |
| `0x4000` to `0x7FFF` | Screen (milestone 4) |

The machine doesn't protect any range. A program can execute, read and write every address.

## Reset

Reset zeroes memory, all registers, `PC` and both flags, sets `SP` to `0x3F00`, seeds the random generator, and sets the state to running.

## Instruction format

An instruction is one opcode byte followed by 0 to 3 operand bytes. The opcode alone decides the length. Operand bytes come in this order:

1. A register byte, if the instruction names registers. It holds two register numbers, the first operand in the high nibble and the second in the low nibble. When an instruction names one register, it is the high nibble. The machine ignores the low nibble and the assembler writes 0 there.
2. An immediate byte, or a 2-byte address, or a second register byte, as the table shows.

Every nibble value is a valid register, so a register byte cannot be wrong.

The machine fetches the whole instruction, moves `PC` past it, and then executes it. It reads every operand before it writes any result. `ADD r1, r1` therefore doubles `r1`, and `LD r2, [r2:r3]` forms its address from the old `r2`.

## Instructions

`a` and `b` are registers, `n` is an immediate byte, `addr` is a 2-byte address, and `h:l` is a register pair used as an address with `h` as the high byte.

| Opcode | Instruction | Bytes | Does | Milestone |
| --- | --- | --- | --- | --- |
| `00` | `HLT` | `00` | Halts the machine | 1 |
| `10` | `LDI a, n` | `10 a0 n` | `a = n` | 1 |
| `11` | `MOV a, b` | `11 ab` | `a = b` | 1 |
| `20` | `ADD a, b` | `20 ab` | `a = a + b` | 1 |
| `21` | `ADC a, b` | `21 ab` | `a = a + b + C` | 1 |
| `22` | `SUB a, b` | `22 ab` | `a = a - b` | 1 |
| `23` | `SBC a, b` | `23 ab` | `a = a - b - C` | 1 |
| `24` | `CMP a, b` | `24 ab` | Sets the flags as `SUB` would and stores nothing | 2 |
| `25` | `AND a, b` | `25 ab` | `a = a & b` | 2 |
| `26` | `OR a, b` | `26 ab` | `a = a \| b` | 2 |
| `27` | `XOR a, b` | `27 ab` | `a = a ^ b` | 2 |
| `30` to `37` | `ADD a, n` to `XOR a, n` | `3x a0 n` | The same eight operations in the same order, with `n` in place of `b` | 1 for `30` to `33`, 2 for the rest |
| `40` | `SHL a` | `40 a0` | `a = a << 1` | 2 |
| `41` | `SHR a` | `41 a0` | `a = a >> 1`, filling with 0 | 2 |
| `50` | `LD a, [addr]` | `50 a0 lo hi` | `a = memory[addr]` | 2 |
| `51` | `ST a, [addr]` | `51 a0 lo hi` | `memory[addr] = a` | 2 |
| `52` | `LD a, [h:l]` | `52 a0 hl` | `a = memory[h:l]` | 2 |
| `53` | `ST a, [h:l]` | `53 a0 hl` | `memory[h:l] = a` | 2 |
| `60` | `JMP addr` | `60 lo hi` | `PC = addr` | 2 |
| `61` | `JZ addr` | `61 lo hi` | Jumps if `Z` is 1 | 2 |
| `62` | `JNZ addr` | `62 lo hi` | Jumps if `Z` is 0 | 2 |
| `63` | `JC addr` | `63 lo hi` | Jumps if `C` is 1 | 2 |
| `64` | `JNC addr` | `64 lo hi` | Jumps if `C` is 0 | 2 |
| `70` | `CALL addr` | `70 lo hi` | Pushes the address of the next instruction, then `PC = addr` | 2 |
| `71` | `RET` | `71` | Pops an address into `PC` | 2 |
| `72` | `PUSH a` | `72 a0` | `SP = SP - 1`, then `memory[SP] = a` | 2 |
| `73` | `POP a` | `73 a0` | `a = memory[SP]`, then `SP = SP + 1` | 2 |

Every other opcode is unknown and faults the machine.

Opcode `00` is `HLT` so that a program which runs off its end into zeroed memory halts.

## Flags

| Instructions | `Z` | `C` |
| --- | --- | --- |
| `ADD`, `ADC` | 1 if the 8-bit result is 0 | 1 if the full sum is above 255 |
| `SUB`, `SBC`, `CMP` | 1 if the 8-bit result is 0 | 1 if the subtraction borrowed, meaning the amount subtracted was larger than `a` |
| `AND`, `OR`, `XOR` | 1 if the result is 0 | 0 |
| `SHL` | 1 if the result is 0 | The old bit 7 |
| `SHR` | 1 if the result is 0 | The old bit 0 |
| Everything else | Unchanged | Unchanged |

Details that follow from the table:

- After `CMP a, b`, `Z` means `a == b` and `C` means `a < b`, comparing unsigned. There are no signed compares.
- `ADC` adds `C` and `SBC` subtracts it, using the value `C` had before the instruction. The amount `SBC` subtracts is `b + C`, which can be 256, and then it always borrows.
- `Z` looks only at the 8 bits of this result. After a 16-bit add built from `ADD` and `ADC`, `Z` describes the high byte alone.
- `ADD a, a` shifts left and `ADC a, a` rotates left through `C`, which is why there are no rotate instructions.

A 16-bit add of `r3:r4` into `r1:r2`, high byte first in each pair, is `ADD r2, r4` then `ADC r1, r3`. A pointer in `r2:r3` moves forward one byte with `ADD r3, 1` then `ADC r2, 0`.

## Stack

The stack is ordinary memory. `SP` starts at `0x3F00` and grows down. `PUSH` lowers `SP` and then stores, so the first pushed byte lands at `0x3EFF`.

`CALL` pushes the high byte of the return address and then the low byte, so the address lies in memory low byte first. `RET` pops the low byte and then the high byte.

Nothing detects overflow or underflow. `SP` wraps, and a stack that grows too far overwrites the program.

## Halting and faults

`HLT` sets the state to halted. An unknown opcode sets it to faulted. In both cases `PC` is left pointing at the opcode that stopped the machine, and the machine does nothing more until the next reset.

An unknown opcode is the only fault. Register numbers and addresses cannot be out of range.

## Assembly language (milestone 3)

`zig build` installs the assembler as `zig-out/bin/figment-asm`. `figment-asm program.asm program.bin` reads a source file and writes the bytes that load at `0x0000`. On an error in the source it prints `file:line: message`, writes nothing and exits with 1. Any other error, such as a file it cannot read, also exits with 1.

A line holds an optional label, then an optional instruction or directive. `;` starts a comment that runs to the end of the line.

- A label is a name followed by `:`. Its value is the address of the next byte the assembler emits. A name starts with a letter or `_` and goes on with letters, digits and `_`. Names are case-sensitive, a name is defined once, and a register name cannot be a label or constant.
- A local label is a dot and a name followed by `:`, as in `.loop:` (milestone 6). It belongs to the nearest label above it that has no dot, and only operands under that label reach it, as `.loop`. Another label can use the same local name. A local label with no label above it is an error.
- A constant is a line `NAME = n`, where `n` is a number (milestone 6). Constants and labels share their names.
- An instruction is a mnemonic from the instruction table followed by its operands, separated by commas. Mnemonics and register names ignore case.
- A register is `r0` to `r9` or `rA` to `rF`.
- A number is decimal, or hexadecimal with `0x`, binary with `0b` or octal with `0o`, with the prefix in either case. `_` may separate digits.
- A value is a number, a label or constant, or `lo(x)` or `hi(x)`, where `x` is a number, a label or a constant (milestone 6). `lo` gives bits 0 to 7 of `x` and `hi` gives bits 8 to 15, and both ignore case. A label or constant can be used before the line that defines it.
- An immediate `n` is a value from 0 to 255.
- An address is a value from 0 to `0xFFFF`. It is written bare after `JMP`, the conditional jumps and `CALL`, and in brackets after `LD` and `ST`, as in `LD r1, [0x1000]`.
- A register pair is written `[h:l]`, as in `ST r1, [r2:r3]`.
- `ADD` to `XOR` take a register or an immediate as the second operand, and the assembler picks the opcode from it.
- `.byte n, n, ...` emits each immediate as one byte.

The program must fit in 32,768 bytes.

```
        LDI r1, 2
        LDI r2, 3
        ADD r1, r2      ; r1 is 5
        HLT
```

This adds up the bytes at `data`, with a register pair as the pointer.

```
COUNT = 4
sum:    LDI r1, hi(data)
        LDI r2, lo(data)
        LDI r0, 0
        LDI r3, COUNT
.next:  LD r4, [r1:r2]
        ADD r0, r4
        ADD r2, 1
        ADC r1, 0
        SUB r3, 1
        JNZ .next
        HLT             ; r0 is 10
data:   .byte 1, 2, 3, 4
```

## Screen (milestone 4)

The screen is 128 by 128 pixels, one byte per pixel, row by row from the top left. The pixel at column `x` and row `y` is at address `0x4000 + y * 128 + x`. The host uses the low 4 bits of the byte as an index into a fixed palette of 16 colors and ignores the high 4 bits.

| Index | Color | Index | Color |
| --- | --- | --- | --- |
| `0` | `#000000` black | `8` | `#E8343F` red |
| `1` | `#1D2340` navy | `9` | `#F28A1E` orange |
| `2` | `#5A2A5E` plum | `A` | `#F6D23A` yellow |
| `3` | `#1F6B52` pine | `B` | `#3CC45A` green |
| `4` | `#8A4B2A` brown | `C` | `#3A8EF0` blue |
| `5` | `#4A4F5C` slate | `D` | `#8A6AD8` violet |
| `6` | `#A7ADB8` gray | `E` | `#F27FB0` pink |
| `7` | `#F4F1E8` white | `F` | `#F6C79A` sand |

A test program paints the screen green (`0x0B`) when it passes and red (`0x08`) when it fails.

### The page

`zig build` installs the page to `zig-out/web`, together with `figment.wasm`, `self-test.bin`, `demo.bin`, `rogue.bin` and `tangle.bin`, which are `programs/self-test.asm`, `programs/demo.asm`, `programs/rogue.asm` and `programs/tangle.asm` assembled. Any static file server can serve the folder. `zig build serve` builds and serves it with `python3 -m http.server`.

The page loads the file its `program` query parameter names, `self-test.bin` without one, or a `.bin` file the user picks. It refuses a file larger than 32,768 bytes with a message and keeps running the program it has. It calls `reset` with a random seed, copies the program in, and then runs frames as the timing part of milestone 5 describes, drawing the screen to a canvas. It shows the program's name and the state under the canvas, and the program's name in the tab title.

### The terminal renderer

`zig build` also installs `zig-out/bin/figment-run`. `figment-run program.bin` resets the machine with seed 0, loads the program, and runs it until it halts or faults or has run 10,000,000 instructions. It then prints the screen to standard output, two pixel rows per line of text. Each character is `▀` with the upper pixel as the 24-bit foreground color and the lower pixel as the background color. It writes the color sequence `ESC[38;2;r;g;b;48;2;r;g;bm` only at the start of a line and where the pair of colors changes, and each line ends with `ESC[0m`.

It exits with 0 when the machine halted or is still running. When the machine faulted it prints the screen, then `faulted at 0x` and `PC` in four hex digits to standard error, and exits with 1. Any other error, such as a program that cannot be read or is larger than 32,768 bytes, or standard output closing early, also exits with 1.

## Keys, beeper, random and timing (milestone 5)

The machine runs in frames, 60 a second. Before each frame the host writes the keys, then runs the machine until the program ends the frame or the frame's instructions run out, then draws the screen and sets the beeper.

| Address | Name | Use |
| --- | --- | --- |
| `0x3F00` | `KEYS` | The host writes the keys here before each frame |
| `0x3F01` | `BEEP` | The program writes a note here. The host plays it from the end of the frame |
| `0x3F02` | `RAND` | `LD` from here gives the next random byte |
| `0x3F03` | `FRAME` | `ST` to here ends the frame |

The rest of the I/O page is plain memory. Only `LD` and `ST` give the I/O page its meaning. Every other access, such as fetching an instruction or `POP` with `SP` in the page, sees plain memory, and `LD` from `KEYS` or `BEEP` reads the byte that is there.

### Keys

`KEYS` holds one bit per key, 1 while the key is held. On the page a key is held by its keyboard key or by its button on the console, which works with a mouse or with several fingers at once. A program that writes `KEYS` keeps the value until the host writes the next frame's keys.

| Bit | Key | Page key |
| --- | --- | --- |
| 0 | Up | Arrow up |
| 1 | Down | Arrow down |
| 2 | Left | Arrow left |
| 3 | Right | Arrow right |
| 4 | A | `Z` |
| 5 | B | `X` |
| 6 | Start | Enter |
| 7 | Select | Shift |

### Beeper

The beeper plays a square wave. A note `n` from 1 to 127 has the frequency of MIDI note `n`, 440 × 2^((`n` − 69) / 12) Hz, so 69 is A4 and 60 is middle C. 0 and every value above 127 are silence. The beeper keeps playing a note until the program writes another one. Reset silences it, since it zeroes `BEEP`, and so does the machine halting or faulting. The page starts its sound on the first key or click, since browsers keep a page silent until then.

### Random

The random generator is xoshiro256++. Reset fills its four 64-bit state words, in order, with the first four outputs of SplitMix64 started at the seed. Each `LD` from `RAND` advances the generator once and gives the top 8 bits of its 64-bit output. With seed 0 the first bytes are `53 61 5C 02 7E 05 DB D8`. `ST` to `RAND` stores a plain byte, which only non-`LD` reads see.

### Timing

The machine runs at most 100,000 instructions a frame, which is enough to paint every pixel once with the five-instruction loop in `programs/self-test.asm` (81,920 instructions). A program that has finished its work for the frame writes any value to `FRAME`. The frame ends after that `ST`, and the machine goes on with the next instruction in the next frame. A program that never writes `FRAME` uses the whole frame. The page keeps 60 frames a second whatever the display's refresh rate, and runs at most 4 frames in one animation frame to catch up after the tab was hidden.

`figment-run` ignores frame ends and runs on, with no keys held and the beeper silent.

## Host interface

The core is a `wasm32` module that imports nothing. It exports its `memory` and these functions. All values are `u32`.

| Export | Does |
| --- | --- |
| `memory_ptr() -> u32` | Returns the byte offset of the machine's 32,768 bytes inside the module's `memory`. The host writes the program at this offset and reads the screen at this offset plus `0x4000` |
| `reset(seed)` | Resets the machine and seeds the random generator |
| `step(n) -> u32` | Executes up to `n` instructions, stops early if the machine halts or faults or the program ends the frame, and returns the state. One call is one frame |
| `state() -> u32` | Returns 0 for running, 1 for halted, 2 for faulted |
| `palette_ptr() -> u32` | Returns the byte offset of the palette inside `memory`: 16 colors of 3 bytes each, red, green and blue, in index order |

The host must call `reset` before `step` or `state`. Until then the machine's contents are undefined. The host loads a program by calling `reset` and then copying the program to `memory_ptr()`. The release build is `ReleaseSmall`.

## Example

This program adds 2 and 3.

```
10 10 02    LDI r1, 2
10 20 03    LDI r2, 3
20 12       ADD r1, r2
00          HLT
```

Afterwards `r1` is 5, `r2` is 3, `Z` and `C` are 0, the state is halted and `PC` is 8.

## Possible upgrades

None of these is designed or built. They are listed here so that a new game can pick the ones it needs, and each one becomes a milestone with its own encodings when it is chosen. They are ordered from cheapest to most expensive.

The limit that binds first is time, not memory. Repainting the whole screen with the loop in `programs/self-test.asm` takes 81,920 of a frame's 100,000 instructions, while `programs/rogue.asm` assembles to about 1.8 KB of the 16 KB program area.

| Upgrade | Work | Existing programs |
| --- | --- | --- |
| More instructions per frame, such as 1,000,000 | The constant in the core and the page, and the timing part of this file | Keep working |
| New instructions, such as `MUL`, `INC` and `DEC` on a register pair, a load with an offset, and rotates | A few lines in the core and a row in the assembler each, plus the aliasing tests. About 150 opcodes are unused | Keep working |
| The high 4 bits of a pixel byte, for 256 colors or a palette the program sets through the I/O page | The palette in the core, which the host already reads through `palette_ptr` | Keep working if indexes 0 to 15 keep their colors |
| 64 KB of memory, with RAM at `0x8000` to `0xFFFF` | 16-bit addresses in the core, the 32,768-byte checks in the page, `figment-run` and the assembler, and the wrap tests | Keep working, unless one relies on `0x8000` meaning `0x0000` |
| Hardware tiles or sprites, which the core draws into the screen before each frame | A new part of this file, the drawing code in the core, and test programs | Keep working if an I/O register turns them on |
| More sound, such as 2 or 3 square channels and noise | Audio code in the page and a few I/O addresses | Keep working |
| More than 64 KB, through a bank register in the I/O page | Banking in the core and the assembler | Keep working |
| A bigger screen, such as 256 by 256 | Packed 4-bit pixels or banking, because one byte per pixel would fill the whole 64 KB | Every drawing routine changes |
