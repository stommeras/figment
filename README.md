# figment

A console that never existed as hardware. Figment is a made-up 8-bit machine with 16 registers, 32 KB of memory, a 128 by 128 screen with 16 colors, and a beeper. The emulator is written in Zig and compiles to WebAssembly.

[SPEC.md](SPEC.md) defines the machine and lists the milestones. Milestones 1 to 6 are done. The CPU runs every instruction, `figment-asm` assembles programs with constants and local labels, the screen shows on a web page and in a terminal, and the page passes keys in, plays the beeper and runs 60 frames a second. Open the page with `?program=demo.bin` for a dot you steer with the arrows, or `?program=rogue.bin` for the first game, a roguelike where you move with the arrows, walk into monsters to hit them, and take the stairs down to a new random cave. A run ends at 0 HP, and an arrow starts a new one.

## Build

You need Zig 0.17.1.

| Command | What it does |
| --- | --- |
| `zig build test` | Runs the tests |
| `zig build` | Builds `figment-asm`, `figment-run` and the page in `zig-out/web` |
| `zig build serve` | Builds, then serves the page at http://localhost:8000. Needs `python3` |
| `zig-out/bin/figment-run program.bin` | Runs a program and prints the screen to the terminal |

Figment follows [chip8](https://github.com/stommeras/chip8), a CHIP-8 emulator that was the practice run for this project.
