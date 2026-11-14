# Figment specification

Figment is a made-up 8-bit console. This file defines the machine, so that the emulator, the assembler and the test programs agree on encodings, flags and wrapping. Each part names the milestone that implements it. A part marked with a later milestone is designed but not built yet.

| Milestone | Adds |
| --- | --- |
| 1 | Registers, flags, `HLT`, `LDI`, `MOV`, `ADD`, `ADC`, `SUB`, `SBC`, the host interface |
| 2 | Every other instruction in this file |
| 3 | The assembler |
| 4 | The screen on a page, the palette colors, the terminal renderer |
| 5 | Keys, the beeper, random, timing |

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
| `0x3F00` to `0x3FFF` | I/O page for keys, the beeper and random (milestone 5) |
| `0x4000` to `0x7FFF` | Screen (milestone 4) |

The machine doesn't protect any range. A program can execute, read and write every address. Until milestone 5 gives the I/O page its meaning, it behaves as plain memory.

## Reset

Reset zeroes memory, all registers, `PC` and both flags, sets `SP` to `0x3F00`, and sets the state to running.

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

- A label is a name followed by `:`. Its value is the address of the next byte the assembler emits. A name starts with a letter or `_` and goes on with letters, digits and `_`. Names are case-sensitive, a name is defined once, and a register name cannot be a label.
- An instruction is a mnemonic from the instruction table followed by its operands, separated by commas. Mnemonics and register names ignore case.
- A register is `r0` to `r9` or `rA` to `rF`.
- A number is decimal, or hexadecimal with `0x`, binary with `0b` or octal with `0o`, with the prefix in either case. `_` may separate digits.
- An immediate `n` is a number from 0 to 255.
- An address is a number from 0 to `0xFFFF` or a label. It is written bare after `JMP`, the conditional jumps and `CALL`, and in brackets after `LD` and `ST`, as in `LD r1, [0x1000]`.
- A register pair is written `[h:l]`, as in `ST r1, [r2:r3]`.
- `ADD` to `XOR` take a register or an immediate as the second operand, and the assembler picks the opcode from it.
- `.byte n, n, ...` emits each number as one byte.

The program must fit in 32,768 bytes.

```
        LDI r1, 2
        LDI r2, 3
        ADD r1, r2      ; r1 is 5
        HLT
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

`zig build` installs the page to `zig-out/web`, together with `figment.wasm` and `self-test.bin`, which is `programs/self-test.asm` assembled. Any static file server can serve the folder, for example `python3 -m http.server -d zig-out/web`.

The page loads `self-test.bin`, or a `.bin` file the user picks. It refuses a file larger than 32,768 bytes with a message and keeps running the program it has. It calls `reset` with a random seed, copies the program in, and then on every animation frame runs `step(100000)` and draws the screen to a canvas. It shows the state under the canvas. Milestone 5 replaces the fixed 100,000 with a measured speed.

### The terminal renderer

`zig build` also installs `zig-out/bin/figment-run`. `figment-run program.bin` resets the machine with seed 0, loads the program, and runs it until it halts or faults or has run 10,000,000 instructions. It then prints the screen to standard output, two pixel rows per line of text. Each character is `▀` with the upper pixel as the 24-bit foreground color and the lower pixel as the background color, and each line ends with `ESC[0m`.

It exits with 0 when the machine halted or is still running. When the machine faulted it prints the screen, then `faulted at 0x` and `PC` in four hex digits to standard error, and exits with 1. Any other error, such as a program that cannot be read or is larger than 32,768 bytes, or standard output closing early, also exits with 1.

## Keys, beeper, random and timing (milestone 5)

These are addresses in the I/O page. The program reads one address for the keys, writes one for the beeper, and reads one to get a random byte from xoshiro256++, seeded by the host at reset. Milestone 5 sets the addresses, the key layout, the beeper pitch and how a program waits for the next frame.

The host decides how fast the machine runs. Milestone 5 picks a default speed once a real program exists to measure.

## Host interface

The core is a `wasm32` module that imports nothing. It exports its `memory` and these functions. All values are `u32`.

| Export | Does |
| --- | --- |
| `memory_ptr() -> u32` | Returns the byte offset of the machine's 32,768 bytes inside the module's `memory`. The host writes the program at this offset and reads the screen at this offset plus `0x4000` |
| `reset(seed)` | Resets the machine. The seed is for the random generator and is ignored until milestone 5 |
| `step(n) -> u32` | Executes up to `n` instructions, stops early if the machine halts or faults, and returns the state |
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
