//! The Figment assembler. SPEC.md defines the language.
const std = @import("std");

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };

pub const Error = error{ Syntax, OutOfMemory };

pub fn assemble(gpa: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error![]u8 {
    _ = gpa;
    _ = source;
    _ = diagnostic;
    return error.Syntax;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
}

const testing = std.testing;

fn expectBytes(source: []const u8, expected: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    const bytes = assemble(testing.allocator, source, &diagnostic) catch |err| {
        std.debug.print("{s}\nline {d}: {s}\n", .{ source, diagnostic.line, diagnostic.message });
        return err;
    };
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, expected, bytes);
}

fn expectSyntaxError(source: []const u8, line: usize, message: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    if (assemble(testing.allocator, source, &diagnostic)) |bytes| {
        testing.allocator.free(bytes);
        std.debug.print("{s}\n", .{source});
        return error.TestExpectedError;
    } else |err| try testing.expectEqual(error.Syntax, err);
    try testing.expectEqualStrings(message, diagnostic.message);
    try testing.expectEqual(line, diagnostic.line);
}

test "the SPEC.md example assembles to the SPEC.md bytes" {
    try expectBytes(
        \\LDI r1, 2
        \\LDI r2, 3
        \\ADD r1, r2
        \\HLT
    , &.{ 0x10, 0x10, 0x02, 0x10, 0x20, 0x03, 0x20, 0x12, 0x00 });
}

test "every instruction assembles to the encoding in SPEC.md" {
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "HLT", &.{0x00} },
        .{ "LDI r1, 0xAB", &.{ 0x10, 0x10, 0xAB } },
        .{ "MOV r1, r2", &.{ 0x11, 0x12 } },
        .{ "ADD r1, r2", &.{ 0x20, 0x12 } },
        .{ "ADC r1, r2", &.{ 0x21, 0x12 } },
        .{ "SUB r1, r2", &.{ 0x22, 0x12 } },
        .{ "SBC r1, r2", &.{ 0x23, 0x12 } },
        .{ "CMP r1, r2", &.{ 0x24, 0x12 } },
        .{ "AND r1, r2", &.{ 0x25, 0x12 } },
        .{ "OR r1, r2", &.{ 0x26, 0x12 } },
        .{ "XOR r1, r2", &.{ 0x27, 0x12 } },
        .{ "ADD r1, 7", &.{ 0x30, 0x10, 0x07 } },
        .{ "ADC r1, 7", &.{ 0x31, 0x10, 0x07 } },
        .{ "SUB r1, 7", &.{ 0x32, 0x10, 0x07 } },
        .{ "SBC r1, 7", &.{ 0x33, 0x10, 0x07 } },
        .{ "CMP r1, 7", &.{ 0x34, 0x10, 0x07 } },
        .{ "AND r1, 7", &.{ 0x35, 0x10, 0x07 } },
        .{ "OR r1, 7", &.{ 0x36, 0x10, 0x07 } },
        .{ "XOR r1, 7", &.{ 0x37, 0x10, 0x07 } },
        .{ "SHL r3", &.{ 0x40, 0x30 } },
        .{ "SHR r3", &.{ 0x41, 0x30 } },
        .{ "LD r4, [0x1234]", &.{ 0x50, 0x40, 0x34, 0x12 } },
        .{ "ST r4, [0x1234]", &.{ 0x51, 0x40, 0x34, 0x12 } },
        .{ "LD r4, [r5:r6]", &.{ 0x52, 0x40, 0x56 } },
        .{ "ST r4, [r5:r6]", &.{ 0x53, 0x40, 0x56 } },
        .{ "JMP 0x1234", &.{ 0x60, 0x34, 0x12 } },
        .{ "JZ 0x1234", &.{ 0x61, 0x34, 0x12 } },
        .{ "JNZ 0x1234", &.{ 0x62, 0x34, 0x12 } },
        .{ "JC 0x1234", &.{ 0x63, 0x34, 0x12 } },
        .{ "JNC 0x1234", &.{ 0x64, 0x34, 0x12 } },
        .{ "CALL 0x1234", &.{ 0x70, 0x34, 0x12 } },
        .{ "RET", &.{0x71} },
        .{ "PUSH r7", &.{ 0x72, 0x70 } },
        .{ "POP r7", &.{ 0x73, 0x70 } },
    }) |case| try expectBytes(case[0], case[1]);
}

test "aliasing: the same register twice, and the destination in the address" {
    try expectBytes("ADD r1, r1", &.{ 0x20, 0x11 });
    try expectBytes("MOV rF, rF", &.{ 0x11, 0xFF });
    try expectBytes("LD r2, [r2:r3]", &.{ 0x52, 0x20, 0x23 });
    try expectBytes("LD r3, [r2:r3]", &.{ 0x52, 0x30, 0x23 });
    try expectBytes("ST r5, [r5:r5]", &.{ 0x53, 0x50, 0x55 });
}

test "registers r0 to rF and mnemonics ignore case" {
    for (0..16) |i| {
        var line: [16]u8 = undefined;
        const source = try std.fmt.bufPrint(&line, "push R{X}", .{i});
        try expectBytes(source, &.{ 0x72, @as(u8, @intCast(i)) << 4 });
        const lower = try std.fmt.bufPrint(&line, "Pop r{x}", .{i});
        try expectBytes(lower, &.{ 0x73, @as(u8, @intCast(i)) << 4 });
    }
}

test "numbers are decimal, hexadecimal, binary or octal, with _ between digits" {
    try expectBytes("LDI r0, 255", &.{ 0x10, 0x00, 0xFF });
    try expectBytes("LDI r0, 0Xff", &.{ 0x10, 0x00, 0xFF });
    try expectBytes("LDI r0, 0b1010_0101", &.{ 0x10, 0x00, 0xA5 });
    try expectBytes("LDI r0, 0o17", &.{ 0x10, 0x00, 0x0F });
    try expectBytes("JMP 0xFFFF", &.{ 0x60, 0xFF, 0xFF });
}

test "comments, blank lines and spacing are ignored" {
    try expectBytes("; a comment on its own\n\n   ADD   r1 ,r2   ; after an instruction\r\n\tHLT;tight", &.{ 0x20, 0x12, 0x00 });
}

test "a label is the address of the next byte, used before or after it is defined" {
    try expectBytes(
        \\start:  JMP end
        \\        .byte 1, 2
        \\middle:
        \\        CALL middle
        \\end:    JZ start ; end is 6
        \\        LD r1, [middle]
        \\_x_1:   ST r1, [_x_1]
    , &.{ 0x60, 0x06, 0x00, 1, 2, 0x70, 0x05, 0x00, 0x61, 0x00, 0x00, 0x50, 0x10, 0x05, 0x00, 0x51, 0x10, 0x0F, 0x00 });
}

test "labels are case-sensitive" {
    try expectBytes(
        \\a: JMP A
        \\A: JMP a
    , &.{ 0x60, 0x03, 0x00, 0x60, 0x00, 0x00 });
}

test ".byte emits each number as one byte" {
    try expectBytes(".byte 0\n.BYTE 0x12, 255, 0b1", &.{ 0, 0x12, 0xFF, 1 });
}

test "an empty source assembles to no bytes" {
    try expectBytes("", &.{});
    try expectBytes("; nothing\n\n", &.{});
}

test "errors name the line and the problem" {
    try expectSyntaxError("HLT\nNOP", 2, "unknown instruction");
    try expectSyntaxError("ADD r1", 1, "wrong operands for this instruction");
    try expectSyntaxError("ADD r1, r2, r3", 1, "wrong operands for this instruction");
    try expectSyntaxError("HLT r1", 1, "wrong operands for this instruction");
    try expectSyntaxError("LDI r1, r2", 1, "wrong operands for this instruction");
    try expectSyntaxError("JMP [0x10]", 1, "wrong operands for this instruction");
    try expectSyntaxError("LD r1, 0x10", 1, "wrong operands for this instruction");
    try expectSyntaxError("ADD r1,", 1, "missing operand");
    try expectSyntaxError("LDI r1, 256", 1, "an immediate is a number from 0 to 255");
    try expectSyntaxError("LDI r1, here\nhere:", 1, "an immediate is a number from 0 to 255");
    try expectSyntaxError(".byte 256", 1, "an immediate is a number from 0 to 255");
    try expectSyntaxError(".byte", 1, "missing operand");
    try expectSyntaxError("JMP 0x10000", 1, "an address is a number from 0 to 0xFFFF");
    try expectSyntaxError("LDI r1, 12a", 1, "invalid operand");
    try expectSyntaxError("LDI r1, -1", 1, "invalid operand");
    try expectSyntaxError("LD r1, [r2:7]", 1, "invalid operand");
    try expectSyntaxError("LD r1, [r2", 1, "invalid operand");
    try expectSyntaxError("\nJMP nowhere", 2, "undefined label");
    try expectSyntaxError("x: HLT\n\nx: HLT", 3, "label is already defined");
    try expectSyntaxError("rA: HLT", 1, "a register name cannot be a label");
    try expectSyntaxError("1x: HLT", 1, "unknown instruction");
}

test "a program must fit in memory" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..0x8000) |_| try source.appendSlice(testing.allocator, ".byte 0\n");
    var diagnostic: Diagnostic = .{};
    const bytes = try assemble(testing.allocator, source.items, &diagnostic);
    testing.allocator.free(bytes);
    try source.appendSlice(testing.allocator, "HLT\n");
    try expectSyntaxError(source.items, 0x8001, "the program does not fit in memory");
}

const figment = @import("figment");

fn runSelfTest(source: []const u8) !figment.Machine {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    m.reset();
    @memcpy(m.memory[0..program.len], program);
    for (0..100_000) |_| m.step();
    try testing.expectEqual(figment.State.halted, m.state);
    return m;
}

const self_test = @embedFile("self-test.asm");

test "the self-test program paints the screen in its pass color" {
    const m = try runSelfTest(self_test);
    for (m.memory[figment.screen_start..]) |pixel| try testing.expectEqual(0x0B, pixel);
}

test "the self-test program paints its fail color when a check fails" {
    const broken = try std.mem.replaceOwned(u8, testing.allocator, self_test, "CMP r2, 0x5A", "CMP r2, 0x5B");
    defer testing.allocator.free(broken);
    try testing.expect(!std.mem.eql(u8, broken, self_test));
    const m = try runSelfTest(broken);
    for (m.memory[figment.screen_start..]) |pixel| try testing.expectEqual(0x08, pixel);
}
