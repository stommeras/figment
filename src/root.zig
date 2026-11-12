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

    /// Executes one instruction. A halted or faulted machine does nothing.
    pub fn step(self: *Machine) void {
        _ = self;
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

// Instruction tests. Each one loads a program at 0x0000 and checks registers, flags, PC and state.

/// A reset machine with `program` at 0x0000.
fn load(program: []const u8) Machine {
    var m: Machine = undefined;
    m.reset();
    @memcpy(m.memory[0..program.len], program);
    return m;
}

/// Steps until the machine stops. A program that runs 1000 instructions fails the test.
fn run(m: *Machine) !void {
    for (0..1000) |_| {
        if (m.state != .running) return;
        m.step();
    }
    return error.DidNotStop;
}

fn expectFlags(m: Machine, z: u1, c: u1) !void {
    try std.testing.expectEqual(z, m.z);
    try std.testing.expectEqual(c, m.c);
}

test "the SPEC.md example adds 2 and 3" {
    var m = load(&.{ 0x10, 0x10, 0x02, 0x10, 0x20, 0x03, 0x20, 0x12, 0x00 });
    try run(&m);
    try std.testing.expectEqual(5, m.r[1]);
    try std.testing.expectEqual(3, m.r[2]);
    try expectFlags(m, 0, 0);
    try std.testing.expectEqual(State.halted, m.state);
    try std.testing.expectEqual(8, m.pc);
}

// HLT and faults

test "HLT halts with PC on the HLT" {
    var m = load(&.{0x00});
    m.step();
    try std.testing.expectEqual(State.halted, m.state);
    try std.testing.expectEqual(0, m.pc);
}

test "HLT: a halted machine ignores step" {
    var m = load(&.{ 0x00, 0x10, 0x10, 0x07 });
    m.step();
    m.pc = 1; // Even with PC moved to a valid LDI, nothing runs until reset.
    m.step();
    try std.testing.expectEqual(0, m.r[1]);
    try std.testing.expectEqual(1, m.pc);
}

test "HLT: running off the end of a program halts in zeroed memory" {
    var m = load(&.{ 0x10, 0x10, 0x07 });
    try run(&m);
    try std.testing.expectEqual(State.halted, m.state);
    try std.testing.expectEqual(3, m.pc);
}

test "fault: an unknown opcode faults with PC on the opcode and nothing changed" {
    // 0x24 is CMP, which arrives in milestone 2, so for now it is unknown like 0xFF.
    for ([_]u8{ 0x01, 0x12, 0x24, 0x34, 0xFF }) |opcode| {
        var m = load(&.{ 0x10, 0x10, 0x07, opcode, 0x12, 0x00 });
        try run(&m);
        try std.testing.expectEqual(State.faulted, m.state);
        try std.testing.expectEqual(3, m.pc);
        try std.testing.expectEqual(7, m.r[1]);
        try expectFlags(m, 0, 0);
    }
}

test "fault: a faulted machine ignores step" {
    var m = load(&.{0xFF});
    m.step();
    m.memory[0] = 0x00;
    m.step();
    try std.testing.expectEqual(State.faulted, m.state);
}

// LDI and MOV

test "LDI loads every register and ignores the low nibble" {
    for (0..16) |i| {
        const a: u8 = @intCast(i);
        var m = load(&.{ 0x10, a << 4 | 0xF, 0xA0 + a, 0x00 });
        try run(&m);
        for (m.r, 0..) |value, j| try std.testing.expectEqual(if (j == i) 0xA0 + a else 0, value);
        try std.testing.expectEqual(3, m.pc);
    }
}

test "LDI and MOV leave the flags alone" {
    var m = load(&.{ 0x10, 0x10, 0x05, 0x11, 0x21, 0x00 });
    m.z = 1;
    m.c = 1;
    try run(&m);
    try expectFlags(m, 1, 1);
    m = load(&.{ 0x10, 0x10, 0x00, 0x11, 0x21, 0x00 });
    try run(&m);
    try expectFlags(m, 0, 0); // Loading or moving 0 doesn't set Z either.
}

test "MOV copies the second register into the first" {
    var m = load(&.{ 0x10, 0x30, 0x2A, 0x11, 0xF3, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0x2A, m.r[0xF]);
    try std.testing.expectEqual(0x2A, m.r[3]);
    try std.testing.expectEqual(5, m.pc);
}

test "MOV with the same register twice changes nothing" {
    var m = load(&.{ 0x10, 0x40, 0x99, 0x11, 0x44, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0x99, m.r[4]);
}

// ADD, ADC, SUB, SBC
//
// Each case runs twice: once as the register form (`2x ab`, with b in r2) and once as the
// immediate form (`3x a0 n`). Both forms must give the same result and flags.

const Case = struct { op: u8, a: u8, b: u8, c_in: u1 = 0, result: u8, z: u1, c: u1 };

const cases = [_]Case{
    // ADD
    .{ .op = 0, .a = 2, .b = 3, .result = 5, .z = 0, .c = 0 },
    .{ .op = 0, .a = 200, .b = 100, .result = 44, .z = 0, .c = 1 },
    .{ .op = 0, .a = 128, .b = 128, .result = 0, .z = 1, .c = 1 },
    .{ .op = 0, .a = 0, .b = 0, .result = 0, .z = 1, .c = 0 },
    .{ .op = 0, .a = 255, .b = 0, .result = 255, .z = 0, .c = 0 },
    .{ .op = 0, .a = 1, .b = 1, .c_in = 1, .result = 2, .z = 0, .c = 0 }, // ADD ignores C
    // ADC
    .{ .op = 1, .a = 2, .b = 3, .c_in = 0, .result = 5, .z = 0, .c = 0 },
    .{ .op = 1, .a = 2, .b = 3, .c_in = 1, .result = 6, .z = 0, .c = 0 },
    .{ .op = 1, .a = 255, .b = 0, .c_in = 1, .result = 0, .z = 1, .c = 1 },
    .{ .op = 1, .a = 255, .b = 255, .c_in = 1, .result = 255, .z = 0, .c = 1 },
    .{ .op = 1, .a = 128, .b = 127, .c_in = 0, .result = 255, .z = 0, .c = 0 },
    // SUB
    .{ .op = 2, .a = 5, .b = 3, .result = 2, .z = 0, .c = 0 },
    .{ .op = 2, .a = 3, .b = 5, .result = 254, .z = 0, .c = 1 },
    .{ .op = 2, .a = 5, .b = 5, .result = 0, .z = 1, .c = 0 },
    .{ .op = 2, .a = 0, .b = 255, .result = 1, .z = 0, .c = 1 },
    .{ .op = 2, .a = 5, .b = 3, .c_in = 1, .result = 2, .z = 0, .c = 0 }, // SUB ignores C
    // SBC
    .{ .op = 3, .a = 5, .b = 3, .c_in = 0, .result = 2, .z = 0, .c = 0 },
    .{ .op = 3, .a = 5, .b = 3, .c_in = 1, .result = 1, .z = 0, .c = 0 },
    .{ .op = 3, .a = 5, .b = 5, .c_in = 1, .result = 255, .z = 0, .c = 1 },
    .{ .op = 3, .a = 6, .b = 5, .c_in = 1, .result = 0, .z = 1, .c = 0 },
    .{ .op = 3, .a = 0, .b = 255, .c_in = 1, .result = 0, .z = 1, .c = 1 }, // b + C is 256
    .{ .op = 3, .a = 255, .b = 255, .c_in = 1, .result = 255, .z = 0, .c = 1 },
};

/// Sets r1 to `a`, r2 to `b` and C to `c_in`, then runs `opcode` with r1 as the destination.
fn runCase(case: Case, immediate: bool) !Machine {
    var m = load(&.{});
    m.r[1] = case.a;
    m.r[2] = case.b;
    m.c = case.c_in;
    const program: []const u8 = if (immediate)
        &.{ 0x30 + case.op, 0x10, case.b, 0x00 }
    else
        &.{ 0x20 + case.op, 0x12, 0x00 };
    @memcpy(m.memory[0..program.len], program);
    try run(&m);
    try std.testing.expectEqual(State.halted, m.state);
    try std.testing.expectEqual(program.len - 1, m.pc);
    return m;
}

test "ADD, ADC, SUB and SBC give the results and flags in SPEC.md, in both forms" {
    for (cases) |case| {
        for ([_]bool{ false, true }) |immediate| {
            const m = runCase(case, immediate) catch |err| {
                std.debug.print("op {d}, a {d}, b {d}, C {d}, immediate {}\n", .{ case.op, case.a, case.b, case.c_in, immediate });
                return err;
            };
            errdefer std.debug.print("op {d}, a {d}, b {d}, C {d}, immediate {}\n", .{ case.op, case.a, case.b, case.c_in, immediate });
            try std.testing.expectEqual(case.result, m.r[1]);
            try std.testing.expectEqual(case.b, m.r[2]); // the source is never written
            try expectFlags(m, case.z, case.c);
        }
    }
}

test "aliasing: ADD a, a doubles a" {
    var m = load(&.{ 0x10, 0x50, 0x81, 0x20, 0x55, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0x02, m.r[5]);
    try expectFlags(m, 0, 1);
}

test "aliasing: ADC a, a rotates left through C using the old C" {
    var m = load(&.{ 0x10, 0x50, 0x81, 0x21, 0x55, 0x00 });
    m.c = 1;
    try run(&m);
    try std.testing.expectEqual(0x03, m.r[5]);
    try expectFlags(m, 0, 1);
}

test "aliasing: SUB a, a gives 0 with no borrow" {
    var m = load(&.{ 0x10, 0x50, 0x81, 0x22, 0x55, 0x00 });
    m.c = 1;
    try run(&m);
    try std.testing.expectEqual(0, m.r[5]);
    try expectFlags(m, 1, 0);
}

test "aliasing: SBC a, a with C set gives 255 and borrows" {
    var m = load(&.{ 0x10, 0x50, 0x81, 0x23, 0x55, 0x00 });
    m.c = 1;
    try run(&m);
    try std.testing.expectEqual(0xFF, m.r[5]);
    try expectFlags(m, 0, 1);
}

test "aliasing: r0 and rF work as destination and source like any other register" {
    // rF is an ordinary register. Writing it doesn't touch the flags, and an add into it sets them.
    var m = load(&.{ 0x10, 0xF0, 0xFF, 0x10, 0x00, 0x01, 0x20, 0xF0, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0, m.r[0xF]);
    try std.testing.expectEqual(1, m.r[0]);
    try expectFlags(m, 1, 1);
}

test "the SPEC.md 16-bit add carries from the low byte into the high byte" {
    // r1:r2 = 0x01FF, r3:r4 = 0x0001. ADD r2, r4 then ADC r1, r3 gives 0x0200.
    var m = load(&.{ 0x10, 0x10, 0x01, 0x10, 0x20, 0xFF, 0x10, 0x30, 0x00, 0x10, 0x40, 0x01, 0x20, 0x24, 0x21, 0x13, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0x02, m.r[1]);
    try std.testing.expectEqual(0x00, m.r[2]);
    try expectFlags(m, 0, 0); // Z describes the high byte alone
}

test "operands wrap from 0x7FFF to 0x0000, and so does PC" {
    var m = load(&.{ 0x07, 0x00 });
    m.memory[0x7FFE] = 0x10; // LDI r1, 7 split across the end of memory
    m.memory[0x7FFF] = 0x10;
    m.pc = 0x7FFE;
    try run(&m);
    try std.testing.expectEqual(7, m.r[1]);
    try std.testing.expectEqual(1, m.pc);
}
