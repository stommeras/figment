//! The host interface from SPEC.md.
const std = @import("std");

const figment = @import("figment");

// Undefined until the host calls `reset`, as SPEC.md requires. An initialized machine would put 32 KB of zeros in the module.
var machine: figment.Machine = undefined;

export fn memory_ptr() u32 {
    return @intCast(@intFromPtr(&machine.memory));
}

export fn reset(seed: u32) void {
    machine.reset(seed);
}

export fn step(n: u32) u32 {
    machine.frame_ended = false;
    for (0..n) |_| {
        if (machine.state != .running) break;
        machine.step();
        if (machine.frame_ended) break;
    }
    return state();
}

export fn state() u32 {
    return @backingInt(machine.state);
}

export fn palette_ptr() u32 {
    return @intCast(@intFromPtr(&figment.palette));
}

test "reset returns the machine to running" {
    machine.state = .halted;
    try std.testing.expectEqual(1, state());
    reset(0);
    try std.testing.expectEqual(0, state());
}

fn load(program: []const u8) void {
    reset(0);
    @memcpy(machine.memory[0..program.len], program);
}

test "step runs exactly n instructions" {
    load(&.{ 0x10, 0x10, 0x01, 0x10, 0x20, 0x02, 0x10, 0x30, 0x03 });
    try std.testing.expectEqual(0, step(2));
    try std.testing.expectEqual(6, machine.pc);
    try std.testing.expectEqual(0, machine.r[3]);
    try std.testing.expectEqual(0, step(0));
    try std.testing.expectEqual(6, machine.pc);
}

test "step stops early and returns the state when the machine halts or faults" {
    load(&.{ 0x10, 0x10, 0x01, 0x00 });
    try std.testing.expectEqual(1, step(100));
    try std.testing.expectEqual(3, machine.pc);
    load(&.{ 0x10, 0x10, 0x01, 0xFF });
    try std.testing.expectEqual(2, step(100));
    try std.testing.expectEqual(3, machine.pc);
    try std.testing.expectEqual(2, step(100));
}

test "step stops after the ST that ends the frame and goes on from there next time" {
    load(&.{ 0x51, 0x00, 0x03, 0x3F, 0x10, 0x10, 0x01, 0x51, 0x00, 0x03, 0x3F, 0x10, 0x20, 0x02, 0x00 });
    try std.testing.expectEqual(0, step(100));
    try std.testing.expectEqual(4, machine.pc);
    try std.testing.expectEqual(0, step(100));
    try std.testing.expectEqual(11, machine.pc);
    try std.testing.expectEqual(1, machine.r[1]);
    try std.testing.expectEqual(1, step(100));
    try std.testing.expectEqual(2, machine.r[2]);
}

test "reset seeds the random generator" {
    load(&.{ 0x50, 0x10, 0x02, 0x3F, 0x00 });
    _ = step(10);
    try std.testing.expectEqual(0x53, machine.r[1]);
    reset(1);
    @memcpy(machine.memory[0..5], &[_]u8{ 0x50, 0x10, 0x02, 0x3F, 0x00 });
    _ = step(10);
    try std.testing.expectEqual(0xCF, machine.r[1]);
}

test "the built wasm module imports nothing and exports its memory" {
    const wasm = @embedFile("figment.wasm");
    try std.testing.expectEqualStrings("\x00asm", wasm[0..4]);

    // After the 8-byte header a module is a list of sections: an id byte, a LEB128 size, then the body.
    var exports: []const u8 = "";
    var i: usize = 8;
    while (i < wasm.len) {
        const id = wasm[i];
        i += 1;
        var size: usize = 0;
        var shift: u5 = 0;
        while (true) : (shift += 7) {
            const byte = wasm[i];
            i += 1;
            size |= @as(usize, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) break;
        }
        try std.testing.expect(id != 2); // 2 is the import section
        if (id == 7) exports = wasm[i..][0..size];
        i += size;
    }
    // Each export is a length-prefixed name followed by its kind, 0 for a function and 2 for memory.
    for ([_][]const u8{ "\x06memory\x02", "\x0Amemory_ptr\x00", "\x05reset\x00", "\x04step\x00", "\x05state\x00", "\x0Bpalette_ptr\x00" }) |entry| {
        try std.testing.expect(std.mem.find(u8, exports, entry) != null);
    }
}
