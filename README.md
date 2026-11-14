# figment

A console that never existed as hardware. Figment is a made-up 8-bit machine with 16 registers, 32 KB of memory, a 128 by 128 screen with 16 colors, and a beeper. The emulator is written in Zig and compiles to WebAssembly.

[SPEC.md](SPEC.md) defines the machine and lists the milestones. Milestones 1 to 4 are done. The CPU runs every instruction, `figment-asm` assembles programs, and the screen shows on a web page and in a terminal.

## Build

You need Zig 0.17.1.

| Command | What it does |
| --- | --- |
| `zig build test` | Runs the tests |
| `zig build` | Builds `figment-asm`, `figment-run` and the page in `zig-out/web` |
| `python3 -m http.server -d zig-out/web` | Serves the page at http://localhost:8000 |
| `zig-out/bin/figment-run program.bin` | Runs a program and prints the screen to the terminal |

Figment follows [chip8](https://github.com/stommeras/chip8), a CHIP-8 emulator that was the practice run for this project.
