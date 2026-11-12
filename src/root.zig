//! The Figment machine. SPEC.md defines how it behaves.
const std = @import("std");

pub const memory_size = 0x8000;
pub const stack_start = 0x3F00;
pub const screen_start = 0x4000;

/// The numbers are the ones `state()` returns to the host.
pub const State = enum(u32) { running = 0, halted = 1, faulted = 2 };

pub const Machine = struct {
    memory: [memory_size]u8 = @splat(0),
    r: [16]u8 = @splat(0),
    // Addresses are u15, so they can't point past memory, and +% wraps them at 0x7FFF.
    pc: u15 = 0,
    sp: u15 = stack_start,
    z: u1 = 0,
    c: u1 = 0,
    state: State = .running,

    pub fn reset(self: *Machine) void {
        // Zeroing memory with @memset keeps a 32 KB block of zeros out of the wasm module.
        self.* = .{ .memory = undefined };
        @memset(&self.memory, 0);
    }
};

test "reset gives the state SPEC.md describes" {
    var m: Machine = .{};
    m.memory[0x1234] = 0xAB;
    m.r[3] = 7;
    m.pc = 0x100;
    m.sp = 0x200;
    m.z = 1;
    m.c = 1;
    m.state = .faulted;

    m.reset();

    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, &m.memory, &.{0xAB}));
    try std.testing.expectEqual(@as([16]u8, @splat(0)), m.r);
    try std.testing.expectEqual(0, m.pc);
    try std.testing.expectEqual(0x3F00, m.sp);
    try std.testing.expectEqual(0, m.z);
    try std.testing.expectEqual(0, m.c);
    try std.testing.expectEqual(State.running, m.state);
}

test "a u15 address covers memory exactly" {
    try std.testing.expectEqual(memory_size, std.math.maxInt(u15) + 1);
}
