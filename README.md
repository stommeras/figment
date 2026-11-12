# figment

A console that never existed as hardware. Figment is a made-up 8-bit machine with 16 registers, 32 KB of memory, a 128 by 128 screen with 16 colors, and a beeper. The emulator is written in Zig and compiles to WebAssembly.

[SPEC.md](SPEC.md) defines the machine and lists the milestones. So far the repo holds the spec and the project skeleton. The CPU cannot run an instruction yet.

## Build

You need Zig 0.17.1.

| Command | What it does |
| --- | --- |
| `zig build test` | Runs the tests |
| `zig build` | Builds `zig-out/bin/figment.wasm` |

Figment follows [chip8](https://github.com/stommeras/chip8), a CHIP-8 emulator that was the practice run for this project.
