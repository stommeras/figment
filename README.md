# figment

A console that never existed as hardware. Figment is a made-up 8-bit machine with 16 registers, 32 KB of memory, a 128 by 128 screen with 16 colors, and a beeper. The emulator is written in Zig and compiles to WebAssembly.

[SPEC.md](SPEC.md) defines the machine and lists the milestones. Milestone 1 is done. The CPU runs `HLT`, `LDI`, `MOV`, `ADD`, `ADC`, `SUB` and `SBC`, and nothing draws to a screen yet.

## Build

You need Zig 0.17.1.

| Command | What it does |
| --- | --- |
| `zig build test` | Runs the tests |
| `zig build` | Builds `zig-out/bin/figment.wasm` |

Figment follows [chip8](https://github.com/stommeras/chip8), a CHIP-8 emulator that was the practice run for this project.
