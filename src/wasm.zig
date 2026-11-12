//! The host interface from SPEC.md. `step` arrives with the first instructions in milestone 1.
const std = @import("std");

const figment = @import("figment");

// Undefined until the host calls `reset`, as SPEC.md requires. An initialized machine would put 32 KB of zeros in the module.
var machine: figment.Machine = undefined;

export fn memory_ptr() u32 {
    return @intCast(@intFromPtr(&machine.memory));
}

export fn reset(seed: u32) void {
    _ = seed; // For the random generator, which arrives in milestone 5.
    machine.reset();
}

export fn state() u32 {
    return @backingInt(machine.state);
}

test "reset returns the machine to running" {
    machine.state = .halted;
    try std.testing.expectEqual(1, state());
    reset(0);
    try std.testing.expectEqual(0, state());
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
    for ([_][]const u8{ "memory", "memory_ptr", "reset", "state" }) |name| {
        try std.testing.expect(std.mem.find(u8, exports, name) != null);
    }
}
