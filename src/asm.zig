//! The Figment assembler. SPEC.md defines the language.
const std = @import("std");

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };

pub const Error = error{ Syntax, OutOfMemory };

pub fn assemble(gpa: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var labels: std.StringHashMapUnmanaged(u16) = .empty;
    defer labels.deinit(gpa);
    var fixups: std.ArrayList(Fixup) = .empty;
    defer fixups.deinit(gpa);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line: usize = 0;
    while (lines.next()) |raw| {
        line += 1;
        diagnostic.line = line;
        var text = trim(raw[0 .. std.mem.findScalar(u8, raw, ';') orelse raw.len]);

        const name_end = nameLength(text);
        if (name_end > 0 and name_end < text.len and text[name_end] == ':') {
            const name = text[0..name_end];
            if (register(name) != null) return fail(diagnostic, "a register name cannot be a label");
            const entry = try labels.getOrPut(gpa, name);
            if (entry.found_existing) return fail(diagnostic, "label is already defined");
            entry.value_ptr.* = @intCast(out.items.len);
            text = trim(text[name_end + 1 ..]);
        }
        if (text.len == 0) continue;

        const mnemonic_end = std.mem.findAny(u8, text, " \t") orelse text.len;
        const mnemonic = text[0..mnemonic_end];
        const rest = trim(text[mnemonic_end..]);

        if (std.ascii.eqlIgnoreCase(mnemonic, ".byte")) {
            var items = std.mem.splitScalar(u8, rest, ',');
            while (items.next()) |item| {
                const operand = try parseOperand(diagnostic, item);
                if (operand != .value) return fail(diagnostic, "wrong operands for this instruction");
                try out.append(gpa, try immediate(diagnostic, operand.value));
            }
        } else {
            var operands: [3]Operand = undefined;
            var count: usize = 0;
            if (rest.len > 0) {
                var items = std.mem.splitScalar(u8, rest, ',');
                while (items.next()) |item| : (count += 1) {
                    if (count == operands.len) return fail(diagnostic, "wrong operands for this instruction");
                    operands[count] = try parseOperand(diagnostic, item);
                }
            }
            const form = try findForm(diagnostic, mnemonic, operands[0..count]);
            try encode(gpa, diagnostic, &out, &fixups, form, operands[0..count]);
        }
        if (out.items.len > memory_size) return fail(diagnostic, "the program does not fit in memory");
    }

    for (fixups.items) |fixup| {
        diagnostic.line = fixup.line;
        const value = labels.get(fixup.label) orelse return fail(diagnostic, "undefined label");
        out.items[fixup.offset] = @truncate(value);
        out.items[fixup.offset + 1] = @truncate(value >> 8);
    }
    return out.toOwnedSlice(gpa);
}

const memory_size = 0x8000;

const Fixup = struct { offset: usize, label: []const u8, line: usize };

const Value = union(enum) { number: u64, label: []const u8 };

const Operand = union(enum) { register: u4, value: Value, memory: Value, pair: [2]u4 };

const Param = enum { register, immediate, address, memory, pair };

const Form = struct { mnemonic: []const u8, params: []const Param, opcode: u8 };

const forms = forms: {
    var list: []const Form = &.{
        .{ .mnemonic = "HLT", .params = &.{}, .opcode = 0x00 },
        .{ .mnemonic = "LDI", .params = &.{ .register, .immediate }, .opcode = 0x10 },
        .{ .mnemonic = "MOV", .params = &.{ .register, .register }, .opcode = 0x11 },
        .{ .mnemonic = "SHL", .params = &.{.register}, .opcode = 0x40 },
        .{ .mnemonic = "SHR", .params = &.{.register}, .opcode = 0x41 },
        .{ .mnemonic = "LD", .params = &.{ .register, .memory }, .opcode = 0x50 },
        .{ .mnemonic = "ST", .params = &.{ .register, .memory }, .opcode = 0x51 },
        .{ .mnemonic = "LD", .params = &.{ .register, .pair }, .opcode = 0x52 },
        .{ .mnemonic = "ST", .params = &.{ .register, .pair }, .opcode = 0x53 },
        .{ .mnemonic = "JMP", .params = &.{.address}, .opcode = 0x60 },
        .{ .mnemonic = "JZ", .params = &.{.address}, .opcode = 0x61 },
        .{ .mnemonic = "JNZ", .params = &.{.address}, .opcode = 0x62 },
        .{ .mnemonic = "JC", .params = &.{.address}, .opcode = 0x63 },
        .{ .mnemonic = "JNC", .params = &.{.address}, .opcode = 0x64 },
        .{ .mnemonic = "CALL", .params = &.{.address}, .opcode = 0x70 },
        .{ .mnemonic = "RET", .params = &.{}, .opcode = 0x71 },
        .{ .mnemonic = "PUSH", .params = &.{.register}, .opcode = 0x72 },
        .{ .mnemonic = "POP", .params = &.{.register}, .opcode = 0x73 },
    };
    for ([_][]const u8{ "ADD", "ADC", "SUB", "SBC", "CMP", "AND", "OR", "XOR" }, 0..) |mnemonic, i| {
        list = list ++ &[_]Form{
            .{ .mnemonic = mnemonic, .params = &.{ .register, .register }, .opcode = 0x20 + i },
            .{ .mnemonic = mnemonic, .params = &.{ .register, .immediate }, .opcode = 0x30 + i },
        };
    }
    break :forms list;
};

fn findForm(diagnostic: *Diagnostic, mnemonic: []const u8, operands: []const Operand) error{Syntax}!Form {
    var known = false;
    for (forms) |form| {
        if (!std.ascii.eqlIgnoreCase(form.mnemonic, mnemonic)) continue;
        known = true;
        if (form.params.len != operands.len) continue;
        for (form.params, operands) |param, operand| {
            const fits = switch (param) {
                .register => operand == .register,
                .immediate, .address => operand == .value,
                .memory => operand == .memory,
                .pair => operand == .pair,
            };
            if (!fits) break;
        } else return form;
    }
    return fail(diagnostic, if (known) "wrong operands for this instruction" else "unknown instruction");
}

fn encode(
    gpa: std.mem.Allocator,
    diagnostic: *Diagnostic,
    out: *std.ArrayList(u8),
    fixups: *std.ArrayList(Fixup),
    form: Form,
    operands: []const Operand,
) Error!void {
    try out.append(gpa, form.opcode);
    if (operands.len > 0 and operands[0] == .register) {
        const low: u4 = if (operands.len > 1 and operands[1] == .register) operands[1].register else 0;
        try out.append(gpa, @as(u8, operands[0].register) << 4 | low);
    }
    for (form.params, operands) |param, operand| switch (param) {
        .register => {},
        .immediate => try out.append(gpa, try immediate(diagnostic, operand.value)),
        .address, .memory => {
            const value = if (param == .address) operand.value else operand.memory;
            switch (value) {
                .number => |number| {
                    if (number > 0xFFFF) return fail(diagnostic, "an address is a number from 0 to 0xFFFF");
                    try out.appendSlice(gpa, &.{ @truncate(number), @truncate(number >> 8) });
                },
                .label => |label| {
                    try fixups.append(gpa, .{ .offset = out.items.len, .label = label, .line = diagnostic.line });
                    try out.appendSlice(gpa, &.{ 0, 0 });
                },
            }
        },
        .pair => try out.append(gpa, @as(u8, operand.pair[0]) << 4 | operand.pair[1]),
    };
}

fn immediate(diagnostic: *Diagnostic, value: Value) error{Syntax}!u8 {
    return switch (value) {
        .number => |number| std.math.cast(u8, number),
        .label => null,
    } orelse fail(diagnostic, "an immediate is a number from 0 to 255");
}

fn parseOperand(diagnostic: *Diagnostic, raw: []const u8) error{Syntax}!Operand {
    const text = trim(raw);
    if (text.len == 0) return fail(diagnostic, "missing operand");
    if (register(text)) |r| return .{ .register = r };
    if (text[0] != '[') return .{ .value = try parseValue(diagnostic, text) };
    if (text.len < 2 or text[text.len - 1] != ']') return fail(diagnostic, "invalid operand");
    const inner = trim(text[1 .. text.len - 1]);
    const colon = std.mem.findScalar(u8, inner, ':') orelse return .{ .memory = try parseValue(diagnostic, inner) };
    const h = register(trim(inner[0..colon])) orelse return fail(diagnostic, "invalid operand");
    const l = register(trim(inner[colon + 1 ..])) orelse return fail(diagnostic, "invalid operand");
    return .{ .pair = .{ h, l } };
}

fn parseValue(diagnostic: *Diagnostic, text: []const u8) error{Syntax}!Value {
    if (text.len > 0 and nameLength(text) == text.len) return .{ .label = text };
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return fail(diagnostic, "invalid operand");
    return .{ .number = std.fmt.parseInt(u64, text, 0) catch return fail(diagnostic, "invalid operand") };
}

fn register(text: []const u8) ?u4 {
    if (text.len != 2 or std.ascii.toLower(text[0]) != 'r') return null;
    return @intCast(std.fmt.charToDigit(text[1], 16) catch return null);
}

fn nameLength(text: []const u8) usize {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return 0;
    for (text, 0..) |c, i| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return i;
    }
    return text.len;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

fn fail(diagnostic: *Diagnostic, message: []const u8) error{Syntax} {
    diagnostic.message = message;
    return error.Syntax;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: figment-asm <source> <output>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAlloc(init.io, args[1], arena, .limited(1 << 24));
    var diagnostic: Diagnostic = .{};
    const program = assemble(arena, source, &diagnostic) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("{s}:{d}: {s}\n", .{ args[1], diagnostic.line, diagnostic.message });
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = program });
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
        \\end:    JZ start ; end is 8
        \\        LD r1, [middle]
        \\_x_1:   ST r1, [_x_1]
    , &.{ 0x60, 0x08, 0x00, 1, 2, 0x70, 0x05, 0x00, 0x61, 0x00, 0x00, 0x50, 0x10, 0x05, 0x00, 0x51, 0x10, 0x0F, 0x00 });
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
