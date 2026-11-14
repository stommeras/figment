# figment

A made-up 8-bit console: a CPU, 32 KB of memory, a 128 by 128 screen and a beeper, emulated in Zig and run in the browser as WebAssembly. `SPEC.md` defines the machine and lists the milestones. The project is built one milestone per pull request.

## Zig 0.17.1

Zig breaks its std library and build system between releases, and your training data is likely older than this version. Before using a std API, read it in the std source for this version (`zig env` prints `lib_dir`) or the language reference at ziglang.org/documentation/0.17.1/. When the compiler disagrees with you, the compiler is right.

The version is pinned in three places that change together: this file, `.github/workflows/ci.yml` and `minimum_zig_version` in `build.zig.zon`.

## Rules

- `SPEC.md` is the source of truth for behavior. Change the spec in the same pull request as the code, and keep encodings, flags and wrapping rules out of other documents.
- The core imports nothing from the host. `src/root.zig` is the machine and `src/wasm.zig` is the host interface. A test in `src/wasm.zig` reads the built module and fails if it has an import.
- `src/asm.zig` is the assembler, a native program built as `figment-asm`. Programs written in assembly live in `programs/`.
- Machine values use exact integer widths (`u15` addresses, `u4` register numbers) and wrapping operators (`+%`), so a value cannot go out of range and no bounds check is needed. The release module is `ReleaseSmall`, which has no safety checks to fall back on.
- The web layer, when it arrives, is plain HTML and JavaScript in `web/` with no bundler. It passes keys in and copies the screen to a canvas.

## Tests

- Write the tests for an instruction group before the instructions.
- For every instruction, test the aliasing cases: both operands the same register, and the destination also used in the address.
- From milestone 2 on, a test program prints its own pass or fail on the screen. Store a screen hash only for such a program, because a hash of anything else only shows that the screen hasn't changed.
- A change is done when `zig build test` and `zig fmt --check .` pass. `zig build test -Dtest-filter=<text>` runs the tests whose name contains the text.

## Process

- Branches are `<type>/<short-description>`, commits are Conventional Commits, and changes merge to `main` through a pull request.
- In the pull request, list what you did not check.
- Open any page in a browser yourself before calling UI work done.
