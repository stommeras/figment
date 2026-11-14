//! The Figment machine. SPEC.md defines how it behaves.
const std = @import("std");

pub const memory_size = 0x8000;
pub const stack_start = 0x3F00;
pub const screen_start = 0x4000;
pub const screen_size = 128;

pub const palette = [16][3]u8{
    .{ 0x00, 0x00, 0x00 }, .{ 0x1D, 0x23, 0x40 }, .{ 0x5A, 0x2A, 0x5E }, .{ 0x1F, 0x6B, 0x52 },
    .{ 0x8A, 0x4B, 0x2A }, .{ 0x4A, 0x4F, 0x5C }, .{ 0xA7, 0xAD, 0xB8 }, .{ 0xF4, 0xF1, 0xE8 },
    .{ 0xE8, 0x34, 0x3F }, .{ 0xF2, 0x8A, 0x1E }, .{ 0xF6, 0xD2, 0x3A }, .{ 0x3C, 0xC4, 0x5A },
    .{ 0x3A, 0x8E, 0xF0 }, .{ 0x8A, 0x6A, 0xD8 }, .{ 0xF2, 0x7F, 0xB0 }, .{ 0xF6, 0xC7, 0x9A },
};

/// The numbers are the ones `state()` returns to the host.
pub const State = enum(u32) { running = 0, halted = 1, faulted = 2 };

fn address(hi: u8, lo: u8) u15 {
    return @truncate(@as(u16, hi) << 8 | lo);
}

const Op = enum(u3) { add, adc, sub, sbc, cmp, @"and", @"or", xor };

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
        if (self.state != .running) return;

        const opcode = self.memory[self.pc];
        const op1 = self.memory[self.pc +% 1];
        const op2 = self.memory[self.pc +% 2];
        const op3 = self.memory[self.pc +% 3];
        const a: u4 = @truncate(op1 >> 4);
        const b: u4 = @truncate(op1);
        const h: u4 = @truncate(op2 >> 4);
        const l: u4 = @truncate(op2);

        switch (opcode) {
            0x00 => self.state = .halted,
            0x10 => {
                self.pc +%= 3;
                self.r[a] = op2;
            },
            0x11 => {
                self.pc +%= 2;
                self.r[a] = self.r[b];
            },
            0x20...0x27 => {
                self.pc +%= 2;
                self.alu(@fromBackingInt(@intCast(@as(u3, @truncate(opcode)))), a, self.r[b]);
            },
            0x30...0x37 => {
                self.pc +%= 3;
                self.alu(@fromBackingInt(@intCast(@as(u3, @truncate(opcode)))), a, op2);
            },
            0x40 => {
                self.pc +%= 2;
                self.setWithFlags(a, self.r[a] << 1, @truncate(self.r[a] >> 7));
            },
            0x41 => {
                self.pc +%= 2;
                self.setWithFlags(a, self.r[a] >> 1, @truncate(self.r[a]));
            },
            0x50 => {
                self.pc +%= 4;
                self.r[a] = self.memory[address(op3, op2)];
            },
            0x51 => {
                self.pc +%= 4;
                self.memory[address(op3, op2)] = self.r[a];
            },
            0x52 => {
                self.pc +%= 3;
                self.r[a] = self.memory[address(self.r[h], self.r[l])];
            },
            0x53 => {
                self.pc +%= 3;
                self.memory[address(self.r[h], self.r[l])] = self.r[a];
            },
            0x60...0x64 => {
                self.pc +%= 3;
                const taken = switch (opcode) {
                    0x60 => true,
                    0x61 => self.z == 1,
                    0x62 => self.z == 0,
                    0x63 => self.c == 1,
                    0x64 => self.c == 0,
                    else => unreachable,
                };
                if (taken) self.pc = address(op2, op1);
            },
            0x70 => {
                self.pc +%= 3;
                self.push(@truncate(self.pc >> 8));
                self.push(@truncate(self.pc));
                self.pc = address(op2, op1);
            },
            0x71 => {
                const lo = self.pop();
                self.pc = address(self.pop(), lo);
            },
            0x72 => {
                self.pc +%= 2;
                self.push(self.r[a]);
            },
            0x73 => {
                self.pc +%= 2;
                self.r[a] = self.pop();
            },
            else => self.state = .faulted,
        }
    }

    fn alu(self: *Machine, op: Op, a: u4, b: u8) void {
        const x = self.r[a];
        const result: u8, const carry: u1 = switch (op) {
            .add => @addWithOverflow(x, b),
            .adc => adc: {
                const sum = @as(u9, x) +% b +% self.c;
                break :adc .{ @truncate(sum), @truncate(sum >> 8) };
            },
            .sub, .cmp => @subWithOverflow(x, b),
            .sbc => sbc: {
                const amount = @as(u9, b) +% self.c;
                break :sbc .{ @truncate(@as(u9, x) -% amount), @intFromBool(amount > x) };
            },
            .@"and" => .{ x & b, 0 },
            .@"or" => .{ x | b, 0 },
            .xor => .{ x ^ b, 0 },
        };
        if (op == .cmp) {
            self.z = @intFromBool(result == 0);
            self.c = carry;
        } else self.setWithFlags(a, result, carry);
    }

    fn setWithFlags(self: *Machine, a: u4, result: u8, carry: u1) void {
        self.r[a] = result;
        self.z = @intFromBool(result == 0);
        self.c = carry;
    }

    fn push(self: *Machine, value: u8) void {
        self.sp -%= 1;
        self.memory[self.sp] = value;
    }

    fn pop(self: *Machine) u8 {
        const value = self.memory[self.sp];
        self.sp +%= 1;
        return value;
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

fn load(program: []const u8) Machine {
    var m: Machine = undefined;
    m.reset();
    @memcpy(m.memory[0..program.len], program);
    return m;
}

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

test "HLT halts with PC on the HLT" {
    var m = load(&.{0x00});
    m.step();
    try std.testing.expectEqual(State.halted, m.state);
    try std.testing.expectEqual(0, m.pc);
}

test "HLT: a halted machine ignores step" {
    var m = load(&.{ 0x00, 0x10, 0x10, 0x07 });
    m.step();
    m.pc = 1;
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
    for (0..256) |i| {
        const opcode: u8 = @intCast(i);
        switch (opcode) {
            0x00, 0x10, 0x11, 0x20...0x27, 0x30...0x37, 0x40, 0x41, 0x50...0x53, 0x60...0x64, 0x70...0x73 => continue,
            else => {},
        }
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
    var m = load(&.{ 0x10, 0xF0, 0x05, 0x11, 0x0F, 0x00 });
    m.z = 1;
    m.c = 1;
    try run(&m);
    try expectFlags(m, 1, 1);
    m = load(&.{ 0x10, 0xF0, 0x00, 0x11, 0x0F, 0x00 });
    try run(&m);
    try expectFlags(m, 0, 0);
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

const Case = struct { op: u8, a: u8, b: u8, c_in: u1 = 0, result: u8, z: u1, c: u1 };

const cases = [_]Case{
    .{ .op = 0, .a = 2, .b = 3, .result = 5, .z = 0, .c = 0 },
    .{ .op = 0, .a = 200, .b = 100, .result = 44, .z = 0, .c = 1 },
    .{ .op = 0, .a = 128, .b = 128, .result = 0, .z = 1, .c = 1 },
    .{ .op = 0, .a = 0, .b = 0, .result = 0, .z = 1, .c = 0 },
    .{ .op = 0, .a = 255, .b = 0, .result = 255, .z = 0, .c = 0 },
    .{ .op = 0, .a = 1, .b = 1, .c_in = 1, .result = 2, .z = 0, .c = 0 },
    .{ .op = 1, .a = 2, .b = 3, .c_in = 0, .result = 5, .z = 0, .c = 0 },
    .{ .op = 1, .a = 2, .b = 3, .c_in = 1, .result = 6, .z = 0, .c = 0 },
    .{ .op = 1, .a = 255, .b = 0, .c_in = 1, .result = 0, .z = 1, .c = 1 },
    .{ .op = 1, .a = 255, .b = 255, .c_in = 1, .result = 255, .z = 0, .c = 1 },
    .{ .op = 1, .a = 128, .b = 127, .c_in = 0, .result = 255, .z = 0, .c = 0 },
    .{ .op = 2, .a = 5, .b = 3, .result = 2, .z = 0, .c = 0 },
    .{ .op = 2, .a = 3, .b = 5, .result = 254, .z = 0, .c = 1 },
    .{ .op = 2, .a = 5, .b = 5, .result = 0, .z = 1, .c = 0 },
    .{ .op = 2, .a = 0, .b = 255, .result = 1, .z = 0, .c = 1 },
    .{ .op = 2, .a = 5, .b = 3, .c_in = 1, .result = 2, .z = 0, .c = 0 },
    .{ .op = 3, .a = 5, .b = 3, .c_in = 0, .result = 2, .z = 0, .c = 0 },
    .{ .op = 3, .a = 5, .b = 3, .c_in = 1, .result = 1, .z = 0, .c = 0 },
    .{ .op = 3, .a = 5, .b = 5, .c_in = 1, .result = 255, .z = 0, .c = 1 },
    .{ .op = 3, .a = 6, .b = 5, .c_in = 1, .result = 0, .z = 1, .c = 0 },
    .{ .op = 3, .a = 0, .b = 255, .c_in = 1, .result = 0, .z = 1, .c = 1 },
    .{ .op = 3, .a = 255, .b = 255, .c_in = 1, .result = 255, .z = 0, .c = 1 },
    .{ .op = 4, .a = 5, .b = 3, .c_in = 1, .result = 5, .z = 0, .c = 0 },
    .{ .op = 4, .a = 3, .b = 5, .result = 3, .z = 0, .c = 1 },
    .{ .op = 4, .a = 5, .b = 5, .c_in = 1, .result = 5, .z = 1, .c = 0 },
    .{ .op = 4, .a = 0, .b = 255, .result = 0, .z = 0, .c = 1 },
    .{ .op = 5, .a = 0xFC, .b = 0x3F, .c_in = 1, .result = 0x3C, .z = 0, .c = 0 },
    .{ .op = 5, .a = 0xF0, .b = 0x0F, .c_in = 1, .result = 0, .z = 1, .c = 0 },
    .{ .op = 6, .a = 0xF0, .b = 0x0F, .c_in = 1, .result = 0xFF, .z = 0, .c = 0 },
    .{ .op = 6, .a = 0, .b = 0, .c_in = 1, .result = 0, .z = 1, .c = 0 },
    .{ .op = 7, .a = 0xF0, .b = 0x3C, .c_in = 1, .result = 0xCC, .z = 0, .c = 0 },
    .{ .op = 7, .a = 0xA5, .b = 0xA5, .c_in = 1, .result = 0, .z = 1, .c = 0 },
};

fn checkCase(case: Case, immediate: bool) !void {
    var m = load(&.{});
    m.r[1] = case.a;
    m.r[2] = case.b;
    m.c = case.c_in;
    const program: []const u8 = if (immediate)
        &.{ 0x30 + case.op, 0x1F, case.b, 0x00 }
    else
        &.{ 0x20 + case.op, 0x12, 0x00 };
    @memcpy(m.memory[0..program.len], program);
    try run(&m);
    try std.testing.expectEqual(State.halted, m.state);
    try std.testing.expectEqual(program.len - 1, m.pc);
    try std.testing.expectEqual(case.result, m.r[1]);
    try std.testing.expectEqual(case.b, m.r[2]);
    try expectFlags(m, case.z, case.c);
}

test "the eight register and immediate operations give the results and flags in SPEC.md" {
    for (cases) |case| {
        for ([_]bool{ false, true }) |immediate| {
            checkCase(case, immediate) catch |err| {
                std.debug.print("op {d}, a {d}, b {d}, C {d}, immediate {}\n", .{ case.op, case.a, case.b, case.c_in, immediate });
                return err;
            };
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
    var m = load(&.{ 0x10, 0xF0, 0xFF, 0x10, 0x00, 0x01, 0x20, 0xF0, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0, m.r[0xF]);
    try std.testing.expectEqual(1, m.r[0]);
    try expectFlags(m, 1, 1);
}

test "MOV and SUB read and write the registers their nibbles name" {
    for (0..16) |i| {
        for (0..16) |j| {
            const a: u4 = @intCast(i);
            const b: u4 = @intCast(j);
            for ([_]u8{ 0x11, 0x22 }) |opcode| {
                var m = load(&.{ opcode, @as(u8, a) << 4 | b, 0x00 });
                for (&m.r, 0..) |*r, k| r.* = @truncate(17 * k + 3);
                const before = m.r;
                try run(&m);
                const expected = if (opcode == 0x11) before[b] else before[a] -% before[b];
                for (m.r, before, 0..) |value, old, k| try std.testing.expectEqual(if (k == a) expected else old, value);
            }
        }
    }
}

test "a 16-bit subtract borrows from the high byte" {
    var m = load(&.{ 0x10, 0x10, 0x02, 0x10, 0x20, 0x00, 0x10, 0x30, 0x00, 0x10, 0x40, 0x01, 0x22, 0x24, 0x23, 0x13, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0x01, m.r[1]);
    try std.testing.expectEqual(0xFF, m.r[2]);
    try expectFlags(m, 0, 0);
}

test "the SPEC.md 16-bit add carries from the low byte into the high byte" {
    var m = load(&.{ 0x10, 0x10, 0x01, 0x10, 0x20, 0xFF, 0x10, 0x30, 0x00, 0x10, 0x40, 0x01, 0x20, 0x24, 0x21, 0x13, 0x00 });
    try run(&m);
    try std.testing.expectEqual(0x02, m.r[1]);
    try std.testing.expectEqual(0x00, m.r[2]);
    try expectFlags(m, 0, 0);
}

test "operands wrap from 0x7FFF to 0x0000, and so does PC" {
    var m = load(&.{ 0x07, 0x00 });
    m.memory[0x7FFE] = 0x10;
    m.memory[0x7FFF] = 0x10;
    m.pc = 0x7FFE;
    try run(&m);
    try std.testing.expectEqual(7, m.r[1]);
    try std.testing.expectEqual(1, m.pc);
}

test "an instruction at the top of memory reads its operands from there" {
    var m = load(&.{});
    @memcpy(m.memory[0x7FFC..][0..4], &[_]u8{ 0x00, 0x10, 0x10, 0x2A });
    m.pc = 0x7FFD;
    m.step();
    try std.testing.expectEqual(0x2A, m.r[1]);
    try std.testing.expectEqual(0, m.pc);
}

test "aliasing: CMP a, a sets Z, clears C and keeps a" {
    var m = load(&.{ 0x10, 0x50, 0x81, 0x24, 0x55, 0x00 });
    m.c = 1;
    try run(&m);
    try std.testing.expectEqual(0x81, m.r[5]);
    try expectFlags(m, 1, 0);
}

test "aliasing: AND a, a and OR a, a keep a, XOR a, a clears it" {
    for ([_]u8{ 0x25, 0x26, 0x27 }) |opcode| {
        var m = load(&.{ 0x10, 0x50, 0x81, opcode, 0x55, 0x00 });
        m.c = 1;
        try run(&m);
        const xor = opcode == 0x27;
        try std.testing.expectEqual(@as(u8, if (xor) 0 else 0x81), m.r[5]);
        try expectFlags(m, @intFromBool(xor), 0);
    }
}

test "SHL and SHR shift one bit into C and ignore the low nibble" {
    const Shift = struct { opcode: u8, a: u8, result: u8, z: u1, c: u1 };
    for ([_]Shift{
        .{ .opcode = 0x40, .a = 0x81, .result = 0x02, .z = 0, .c = 1 },
        .{ .opcode = 0x40, .a = 0x80, .result = 0x00, .z = 1, .c = 1 },
        .{ .opcode = 0x40, .a = 0x41, .result = 0x82, .z = 0, .c = 0 },
        .{ .opcode = 0x41, .a = 0x81, .result = 0x40, .z = 0, .c = 1 },
        .{ .opcode = 0x41, .a = 0x01, .result = 0x00, .z = 1, .c = 1 },
        .{ .opcode = 0x41, .a = 0x82, .result = 0x41, .z = 0, .c = 0 },
    }) |case| {
        var m = load(&.{ case.opcode, 0x1F, 0x00 });
        m.r[1] = case.a;
        m.r[0xF] = 0x77;
        m.c = 1 - case.c;
        try run(&m);
        try std.testing.expectEqual(2, m.pc);
        try std.testing.expectEqual(case.result, m.r[1]);
        try std.testing.expectEqual(0x77, m.r[0xF]);
        try expectFlags(m, case.z, case.c);
    }
}

test "ST and LD with an address move a byte, ignore the top address bit and leave the flags alone" {
    var m = load(&.{ 0x51, 0x3F, 0x34, 0x12, 0x50, 0x4F, 0x34, 0x92, 0x00 });
    m.r[3] = 0xC4;
    m.z = 1;
    m.c = 1;
    m.step();
    try std.testing.expectEqual(4, m.pc);
    try std.testing.expectEqual(0xC4, m.memory[0x1234]);
    try run(&m);
    try std.testing.expectEqual(8, m.pc);
    try std.testing.expectEqual(0xC4, m.r[4]);
    try expectFlags(m, 1, 1);
}

test "ST and LD with a register pair use h as the high byte and ignore the top bit" {
    var m = load(&.{ 0x53, 0x1F, 0x23, 0x52, 0x4F, 0x32, 0x00 });
    m.r[1] = 0xC4;
    m.r[2] = 0x92;
    m.r[3] = 0x34;
    m.memory[0x3492] = 0x5B;
    m.z = 1;
    m.c = 1;
    m.step();
    try std.testing.expectEqual(3, m.pc);
    try std.testing.expectEqual(0xC4, m.memory[0x1234]);
    try run(&m);
    try std.testing.expectEqual(6, m.pc);
    try std.testing.expectEqual(0x5B, m.r[4]);
    try expectFlags(m, 1, 1);
}

test "aliasing: LD a, [a:l] forms its address from the old a" {
    var m = load(&.{ 0x52, 0x20, 0x23, 0x00 });
    m.r[2] = 0x12;
    m.r[3] = 0x34;
    m.memory[0x1234] = 0x99;
    try run(&m);
    try std.testing.expectEqual(0x99, m.r[2]);
}

test "aliasing: LD a, [h:a] and LD a, [a:a]" {
    var m = load(&.{ 0x52, 0x30, 0x23, 0x52, 0x50, 0x55, 0x00 });
    m.r[2] = 0x12;
    m.r[3] = 0x34;
    m.r[5] = 0x05;
    m.memory[0x1234] = 0x99;
    m.memory[0x0505] = 0x77;
    try run(&m);
    try std.testing.expectEqual(0x99, m.r[3]);
    try std.testing.expectEqual(0x77, m.r[5]);
}

test "aliasing: ST a, [a:l] and ST a, [h:a] store a at the address a helps form" {
    var m = load(&.{ 0x53, 0x20, 0x23, 0x53, 0x50, 0x45, 0x00 });
    m.r[2] = 0x12;
    m.r[3] = 0x34;
    m.r[4] = 0x20;
    m.r[5] = 0x56;
    try run(&m);
    try std.testing.expectEqual(0x12, m.memory[0x1234]);
    try std.testing.expectEqual(0x56, m.memory[0x2056]);
}

test "jumps go to the address when their flag says so, ignore the top bit and leave the flags alone" {
    const Jump = struct { opcode: u8, z: u1, c: u1, taken: bool };
    for ([_]Jump{
        .{ .opcode = 0x60, .z = 0, .c = 0, .taken = true },
        .{ .opcode = 0x60, .z = 1, .c = 1, .taken = true },
        .{ .opcode = 0x61, .z = 1, .c = 0, .taken = true },
        .{ .opcode = 0x61, .z = 0, .c = 1, .taken = false },
        .{ .opcode = 0x62, .z = 0, .c = 1, .taken = true },
        .{ .opcode = 0x62, .z = 1, .c = 0, .taken = false },
        .{ .opcode = 0x63, .z = 0, .c = 1, .taken = true },
        .{ .opcode = 0x63, .z = 1, .c = 0, .taken = false },
        .{ .opcode = 0x64, .z = 1, .c = 0, .taken = true },
        .{ .opcode = 0x64, .z = 0, .c = 1, .taken = false },
    }) |case| {
        var m = load(&.{ case.opcode, 0x34, 0x92 });
        m.z = case.z;
        m.c = case.c;
        m.step();
        try std.testing.expectEqual(@as(u15, if (case.taken) 0x1234 else 3), m.pc);
        try expectFlags(m, case.z, case.c);
    }
}

test "CALL pushes the return address high byte first and RET pops it back" {
    var m = load(&.{});
    @memcpy(m.memory[0x1230..][0..4], &[_]u8{ 0x70, 0x00, 0x02, 0x00 });
    m.memory[0x0200] = 0x71;
    m.pc = 0x1230;
    m.z = 1;
    m.c = 1;
    m.step();
    try std.testing.expectEqual(0x0200, m.pc);
    try std.testing.expectEqual(0x3EFE, m.sp);
    try std.testing.expectEqual(0x12, m.memory[0x3EFF]);
    try std.testing.expectEqual(0x33, m.memory[0x3EFE]);
    try run(&m);
    try std.testing.expectEqual(0x1233, m.pc);
    try std.testing.expectEqual(0x3F00, m.sp);
    try expectFlags(m, 1, 1);
}

test "RET ignores the top bit of the popped address" {
    var m = load(&.{0x71});
    m.sp = 0x3EFE;
    m.memory[0x3EFE] = 0x34;
    m.memory[0x3EFF] = 0x92;
    m.step();
    try std.testing.expectEqual(0x1234, m.pc);
}

test "PUSH and POP move bytes through the stack in last in, first out order" {
    var m = load(&.{ 0x72, 0x1F, 0x72, 0x20, 0x73, 0x3F, 0x73, 0x40, 0x00 });
    m.r[1] = 0xAA;
    m.r[2] = 0xBB;
    m.z = 1;
    m.c = 1;
    m.step();
    try std.testing.expectEqual(0x3EFF, m.sp);
    try std.testing.expectEqual(0xAA, m.memory[0x3EFF]);
    try run(&m);
    try std.testing.expectEqual(8, m.pc);
    try std.testing.expectEqual(0xBB, m.r[3]);
    try std.testing.expectEqual(0xAA, m.r[4]);
    try std.testing.expectEqual(0x3F00, m.sp);
    try expectFlags(m, 1, 1);
}

test "aliasing: PUSH a then POP a gives a back" {
    var m = load(&.{ 0x72, 0x50, 0x10, 0x50, 0x00, 0x73, 0x50, 0x00 });
    m.r[5] = 0x42;
    try run(&m);
    try std.testing.expectEqual(State.halted, m.state);
    try std.testing.expectEqual(7, m.pc);
    try std.testing.expectEqual(0x42, m.r[5]);
}

test "SP wraps from 0x0000 to 0x7FFF and back" {
    var m = load(&.{ 0x72, 0x10, 0x73, 0x20, 0x00 });
    m.r[1] = 0x66;
    m.sp = 0;
    m.step();
    try std.testing.expectEqual(0x7FFF, m.sp);
    try std.testing.expectEqual(0x66, m.memory[0x7FFF]);
    try run(&m);
    try std.testing.expectEqual(0, m.sp);
    try std.testing.expectEqual(0x66, m.r[2]);
}

test "aliasing: LD a, [h:h], ST a, [h:h] and ST a, [a:a]" {
    var m = load(&.{ 0x52, 0x10, 0x22, 0x53, 0x30, 0x22, 0x53, 0x40, 0x44, 0x00 });
    m.r[2] = 0x12;
    m.r[3] = 0xC4;
    m.r[4] = 0x05;
    m.memory[0x1212] = 0x99;
    m.step();
    try std.testing.expectEqual(0x99, m.r[1]);
    try run(&m);
    try std.testing.expectEqual(0xC4, m.memory[0x1212]);
    try std.testing.expectEqual(0x05, m.memory[0x0505]);
}

test "CALL at the top of memory reads its operands and pushes a return address that wrapped" {
    var m = load(&.{0x02});
    m.memory[0x7FFE] = 0x70;
    m.memory[0x7FFF] = 0x01;
    m.pc = 0x7FFE;
    m.step();
    try std.testing.expectEqual(0x0201, m.pc);
    try std.testing.expectEqual(0x00, m.memory[0x3EFF]);
    try std.testing.expectEqual(0x01, m.memory[0x3EFE]);
}

test "LD with an address at the top of memory reads its high byte from 0x0000" {
    var m = load(&.{ 0x12, 0x00 });
    @memcpy(m.memory[0x7FFD..], &[_]u8{ 0x50, 0x10, 0x34 });
    m.memory[0x1234] = 0x77;
    m.pc = 0x7FFD;
    m.step();
    try std.testing.expectEqual(0x77, m.r[1]);
    try std.testing.expectEqual(1, m.pc);
}
