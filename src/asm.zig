const std = @import("std");

const figment = @import("figment");

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };

pub const Error = error{ Syntax, OutOfMemory };

pub fn assemble(gpa: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var a: Assembler = .{ .gpa = gpa, .arena = arena.allocator(), .diagnostic = diagnostic };
    errdefer a.out.deinit(gpa);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line: usize = 0;
    while (lines.next()) |raw| {
        line += 1;
        diagnostic.line = line;
        var text = trim(raw[0 .. std.mem.findScalar(u8, raw, ';') orelse raw.len]);

        const name_end = symbolLength(text);
        const after_name = trim(text[name_end..]);
        if (name_end > 0 and text[0] != '.' and after_name.len > 0 and after_name[0] == '=') {
            const name = text[0..name_end];
            if (register(name) != null) return fail(diagnostic, "a register name cannot be a label or constant");
            const value = trim(after_name[1..]);
            if (value.len == 0 or !std.ascii.isDigit(value[0])) return fail(diagnostic, "a constant is a number");
            try a.define(name, parseNumber(value) catch return fail(diagnostic, "a constant is a number"));
            continue;
        }
        if (name_end > 0 and name_end < text.len and text[name_end] == ':') {
            const name = try a.qualify(text[0..name_end]);
            if (register(name) != null) return fail(diagnostic, "a register name cannot be a label or constant");
            try a.define(name, a.out.items.len);
            if (text[0] != '.') a.scope = name;
            text = trim(text[name_end + 1 ..]);
        }
        if (text.len == 0) continue;

        const mnemonic_end = std.mem.findAny(u8, text, " \t") orelse text.len;
        const mnemonic = text[0..mnemonic_end];
        const rest = trim(text[mnemonic_end..]);

        if (std.ascii.eqlIgnoreCase(mnemonic, ".byte")) {
            var items = std.mem.splitScalar(u8, rest, ',');
            while (items.next()) |item| {
                const operand = try a.parseOperand(item);
                if (operand != .value) return fail(diagnostic, "wrong operands for this instruction");
                try a.emit(operand.value, .byte);
            }
        } else {
            var operands: [3]Operand = undefined;
            var count: usize = 0;
            if (rest.len > 0) {
                var items = std.mem.splitScalar(u8, rest, ',');
                while (items.next()) |item| : (count += 1) {
                    if (count == operands.len) return fail(diagnostic, "wrong operands for this instruction");
                    operands[count] = try a.parseOperand(item);
                }
            }
            const form = try findForm(diagnostic, mnemonic, operands[0..count]);
            try a.encode(form, operands[0..count]);
        }
        if (a.out.items.len > figment.memory_size) return fail(diagnostic, "the program does not fit in memory");
    }

    for (a.fixups.items) |fixup| {
        diagnostic.line = fixup.line;
        const value = a.resolve(fixup.value) orelse return fail(diagnostic, "undefined name");
        try write(diagnostic, a.out.items[fixup.offset..], value, fixup.size);
    }
    return a.out.toOwnedSlice(gpa);
}

const Size = enum { byte, address };

const Fixup = struct { offset: usize, value: Value, size: Size, line: usize };

/// A number, or a label or constant that the assembler looks up after the last line.
const Value = struct { number: u64 = 0, name: ?[]const u8 = null, part: enum { whole, lo, hi } = .whole };

const Operand = union(enum) { register: u4, value: Value, memory: Value, pair: [2]u4 };

const Param = enum { register, immediate, address, memory, pair };

const Form = struct { mnemonic: []const u8, params: []const Param, opcode: u8 };

const Assembler = struct {
    gpa: std.mem.Allocator,
    /// Holds the names, the fixups and the full names of local labels.
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    out: std.ArrayList(u8) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    names: std.StringHashMapUnmanaged(u64) = .empty,
    /// The last label without a dot, which local labels belong to.
    scope: ?[]const u8 = null,

    fn define(a: *Assembler, name: []const u8, value: u64) Error!void {
        const entry = try a.names.getOrPut(a.arena, name);
        if (entry.found_existing) return fail(a.diagnostic, "name is already defined");
        entry.value_ptr.* = value;
    }

    /// Turns a local label such as `.loop` into its full name, `scope.loop`.
    fn qualify(a: *Assembler, name: []const u8) Error![]const u8 {
        if (name[0] != '.') return name;
        const scope = a.scope orelse return fail(a.diagnostic, "a local label needs a label above it");
        return std.mem.concat(a.arena, u8, &.{ scope, name });
    }

    fn resolve(a: *Assembler, value: Value) ?u64 {
        const whole = if (value.name) |name| a.names.get(name) orelse return null else value.number;
        return switch (value.part) {
            .whole => whole,
            .lo => whole & 0xFF,
            .hi => whole >> 8 & 0xFF,
        };
    }

    /// Writes a value now if it is a number, or leaves room for it and a fixup if it names something.
    fn emit(a: *Assembler, value: Value, size: Size) Error!void {
        const offset = a.out.items.len;
        try a.out.appendNTimes(a.gpa, 0, if (size == .byte) 1 else 2);
        if (value.name == null) return write(a.diagnostic, a.out.items[offset..], a.resolve(value).?, size);
        try a.fixups.append(a.arena, .{ .offset = offset, .value = value, .size = size, .line = a.diagnostic.line });
    }

    fn encode(a: *Assembler, form: Form, operands: []const Operand) Error!void {
        try a.out.append(a.gpa, form.opcode);
        if (operands.len > 0 and operands[0] == .register) {
            const low: u4 = if (operands.len > 1 and operands[1] == .register) operands[1].register else 0;
            try a.out.append(a.gpa, @as(u8, operands[0].register) << 4 | low);
        }
        for (form.params, operands) |param, operand| switch (param) {
            .register => {},
            .immediate => try a.emit(operand.value, .byte),
            .address => try a.emit(operand.value, .address),
            .memory => try a.emit(operand.memory, .address),
            .pair => try a.out.append(a.gpa, @as(u8, operand.pair[0]) << 4 | operand.pair[1]),
        };
    }

    fn parseOperand(a: *Assembler, raw: []const u8) Error!Operand {
        const text = trim(raw);
        if (text.len == 0) return fail(a.diagnostic, "missing operand");
        if (register(text)) |r| return .{ .register = r };
        if (text[0] != '[') return .{ .value = try a.parseValue(text) };
        if (text.len < 2 or text[text.len - 1] != ']') return fail(a.diagnostic, "invalid operand");
        const inner = trim(text[1 .. text.len - 1]);
        const colon = std.mem.findScalar(u8, inner, ':') orelse return .{ .memory = try a.parseValue(inner) };
        const h = register(trim(inner[0..colon])) orelse return fail(a.diagnostic, "invalid operand");
        const l = register(trim(inner[colon + 1 ..])) orelse return fail(a.diagnostic, "invalid operand");
        return .{ .pair = .{ h, l } };
    }

    fn parseValue(a: *Assembler, text: []const u8) Error!Value {
        for ([_][]const u8{ "lo(", "hi(" }) |prefix| {
            if (!std.ascii.startsWithIgnoreCase(text, prefix)) continue;
            if (text[text.len - 1] != ')') return fail(a.diagnostic, "invalid operand");
            const inner = trim(text[prefix.len .. text.len - 1]);
            if (register(inner) != null) return fail(a.diagnostic, "invalid operand");
            var value = try a.parseValue(inner);
            if (value.part != .whole) return fail(a.diagnostic, "invalid operand");
            value.part = if (prefix[0] == 'l') .lo else .hi;
            return value;
        }
        if (text.len > 0 and symbolLength(text) == text.len) return .{ .name = try a.qualify(text) };
        if (text.len == 0 or !std.ascii.isDigit(text[0])) return fail(a.diagnostic, "invalid operand");
        return .{ .number = parseNumber(text) catch return fail(a.diagnostic, "invalid operand") };
    }
};

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

fn write(diagnostic: *Diagnostic, bytes: []u8, value: u64, size: Size) error{Syntax}!void {
    switch (size) {
        .byte => bytes[0] = std.math.cast(u8, value) orelse return fail(diagnostic, "an immediate is a number from 0 to 255"),
        .address => {
            if (value > 0xFFFF) return fail(diagnostic, "an address is a number from 0 to 0xFFFF");
            bytes[0] = @truncate(value);
            bytes[1] = @truncate(value >> 8);
        },
    }
}

/// A number too big for 64 bits becomes the largest one, so the range checks reject it.
fn parseNumber(text: []const u8) error{InvalidCharacter}!u64 {
    return std.fmt.parseInt(u64, text, 0) catch |err| switch (err) {
        error.Overflow => std.math.maxInt(u64),
        error.InvalidCharacter => error.InvalidCharacter,
    };
}

fn register(text: []const u8) ?u4 {
    if (text.len != 2 or std.ascii.toLower(text[0]) != 'r') return null;
    return @intCast(std.fmt.charToDigit(text[1], 16) catch return null);
}

/// The length of the label or constant name that starts `text`, with the dot of a local label.
fn symbolLength(text: []const u8) usize {
    if (text.len == 0 or text[0] != '.') return nameLength(text);
    const length = nameLength(text[1..]);
    return if (length == 0) 0 else length + 1;
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
        std.process.exit(1);
    }
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, args[1], arena, .limited(1 << 24)) catch |err| {
        std.debug.print("{s}: cannot read: {t}\n", .{ args[1], err });
        std.process.exit(1);
    };
    var diagnostic: Diagnostic = .{};
    const program = assemble(arena, source, &diagnostic) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("{s}:{d}: {s}\n", .{ args[1], diagnostic.line, diagnostic.message });
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };
    cwd.writeFile(init.io, .{ .sub_path = args[2], .data = program }) catch |err| {
        std.debug.print("{s}: cannot write: {t}\n", .{ args[2], err });
        std.process.exit(1);
    };
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

test "the SPEC.md example with names adds up its table" {
    const spec = @embedFile("SPEC.md");
    const start = std.mem.find(u8, spec, "COUNT = 4\n").?;
    const source = spec[start .. start + std.mem.find(u8, spec[start..], "```").?];
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    m.reset(0);
    @memcpy(m.memory[0..program.len], program);
    for (0..100) |_| m.step();
    try testing.expectEqual(figment.State.halted, m.state);
    try testing.expectEqual(10, m.r[0]);
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
    for ([_][]const u8{ "MOV", "ADD", "ADC", "SUB", "SBC", "CMP", "AND", "OR", "XOR" }, [_]u8{ 0x11, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27 }) |mnemonic, opcode| {
        var line: [16]u8 = undefined;
        try expectBytes(try std.fmt.bufPrint(&line, "{s} rF, rF", .{mnemonic}), &.{ opcode, 0xFF });
    }
    try expectBytes("LD r2, [r2:r3]", &.{ 0x52, 0x20, 0x23 });
    try expectBytes("LD r3, [r2:r3]", &.{ 0x52, 0x30, 0x23 });
    try expectBytes("LD r5, [r5:r5]", &.{ 0x52, 0x50, 0x55 });
    try expectBytes("ST r2, [r2:r3]", &.{ 0x53, 0x20, 0x23 });
    try expectBytes("ST r3, [r2:r3]", &.{ 0x53, 0x30, 0x23 });
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
        \\end:    JZ start
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

test "a constant is a name for a number, used before or after it is defined" {
    try expectBytes(
        \\KEYS = 0x3F00
        \\        LD r0, [KEYS]
        \\        LDI r1, LIMIT
        \\        CMP r1, LIMIT
        \\        JMP KEYS
        \\        .byte LIMIT, 2
        \\LIMIT   =   7   ; spacing and comments as on any line
    , &.{ 0x50, 0x00, 0x00, 0x3F, 0x10, 0x10, 0x07, 0x34, 0x10, 0x07, 0x60, 0x00, 0x3F, 7, 2 });
}

test "a name in an immediate works when its value fits in a byte" {
    try expectBytes("LDI r1, end\nend:", &.{ 0x10, 0x10, 0x03 });
}

test "lo and hi give the low and high byte of a number or a name" {
    try expectBytes(
        \\BIG = 0x1234
        \\        LDI r1, hi(BIG)
        \\        LDI r2, LO( BIG )
        \\        .byte lo(data), hi(data), hi(0x4000)
        \\data:   JMP lo(BIG)
    , &.{ 0x10, 0x10, 0x12, 0x10, 0x20, 0x34, 9, 0, 0x40, 0x60, 0x34, 0x00 });
}

test "a local label belongs to the label above it" {
    try expectBytes(
        \\a:      JMP .x
        \\.x:     JMP .x
        \\b:      JMP .x
        \\.x:     LDI r1, lo(.x)
        \\K = 1   ; a constant does not start a new scope
        \\        JMP .x
    , &.{ 0x60, 0x03, 0x00, 0x60, 0x03, 0x00, 0x60, 0x09, 0x00, 0x10, 0x10, 0x09, 0x60, 0x09, 0x00 });
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
    try expectSyntaxError("LDI r1, far\nfar = 0x100", 1, "an immediate is a number from 0 to 255");
    try expectSyntaxError(".byte 1\n.byte far\nfar = 256", 2, "an immediate is a number from 0 to 255");
    try expectSyntaxError("JMP far\nfar = 0x10000", 1, "an address is a number from 0 to 0xFFFF");
    try expectSyntaxError(".byte 256", 1, "an immediate is a number from 0 to 255");
    try expectSyntaxError(".byte", 1, "missing operand");
    try expectSyntaxError("JMP 0x10000", 1, "an address is a number from 0 to 0xFFFF");
    try expectSyntaxError("JMP 0x1_0000_0000_0000_0000", 1, "an address is a number from 0 to 0xFFFF");
    try expectSyntaxError("LDI r1, 12a", 1, "invalid operand");
    try expectSyntaxError("LDI r1, -1", 1, "invalid operand");
    try expectSyntaxError("LD r1, [r2:7]", 1, "invalid operand");
    try expectSyntaxError("LD r1, [r2", 1, "invalid operand");
    try expectSyntaxError("\nJMP nowhere", 2, "undefined name");
    try expectSyntaxError("LDI r1, hi(nowhere)", 1, "undefined name");
    try expectSyntaxError("a: JMP .nowhere\nb:\n.nowhere:", 1, "undefined name");
    try expectSyntaxError("x: HLT\n\nx: HLT", 3, "name is already defined");
    try expectSyntaxError("x = 1\nx: HLT", 2, "name is already defined");
    try expectSyntaxError("x: HLT\nx = 1", 2, "name is already defined");
    try expectSyntaxError("a: HLT\n.x: HLT\n.x: HLT", 3, "name is already defined");
    try expectSyntaxError("rA: HLT", 1, "a register name cannot be a label or constant");
    try expectSyntaxError("rA = 1", 1, "a register name cannot be a label or constant");
    try expectSyntaxError("x = y", 1, "a constant is a number");
    try expectSyntaxError("x =", 1, "a constant is a number");
    try expectSyntaxError(".x: HLT", 1, "a local label needs a label above it");
    try expectSyntaxError("JMP .x", 1, "a local label needs a label above it");
    try expectSyntaxError("LDI r1, lo(r1)", 1, "invalid operand");
    try expectSyntaxError("LDI r1, hi(lo(1))", 1, "invalid operand");
    try expectSyntaxError("LDI r1, lo(1", 1, "invalid operand");
    try expectSyntaxError("1x: HLT", 1, "unknown instruction");
}

test "a program must fit in memory" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..figment.memory_size) |_| try source.appendSlice(testing.allocator, ".byte 0\n");
    var diagnostic: Diagnostic = .{};
    const bytes = try assemble(testing.allocator, source.items, &diagnostic);
    testing.allocator.free(bytes);
    try source.appendSlice(testing.allocator, "HLT\n");
    try expectSyntaxError(source.items, figment.memory_size + 1, "the program does not fit in memory");
}

fn runSelfTest(source: []const u8) !figment.Machine {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    m.reset(0);
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

test "the self-test program fails when every random byte is the same" {
    const broken = try std.mem.replaceOwned(u8, testing.allocator, self_test, "LD rB, [0x3F02]", "MOV rB, r9");
    defer testing.allocator.free(broken);
    try testing.expect(!std.mem.eql(u8, broken, self_test));
    const m = try runSelfTest(broken);
    for (m.memory[figment.screen_start..]) |pixel| try testing.expectEqual(0x08, pixel);
}

/// Runs one frame and returns how many instructions it took. Fails if the machine
/// stops or the frame goes past the 100,000 instructions SPEC.md allows.
fn runFrame(m: *figment.Machine) !usize {
    m.frame_ended = false;
    var n: usize = 0;
    while (!m.frame_ended) : (n += 1) {
        try testing.expect(n < 100_000);
        m.step();
        try testing.expectEqual(figment.State.running, m.state);
    }
    return n;
}

const rogue_source = @embedFile("rogue.asm");

/// The value of a constant that programs/rogue.asm defines, such as `PLAYER_X = 0x3100`.
fn rogueConstant(comptime name: []const u8) usize {
    const start = std.mem.find(u8, rogue_source, "\n" ++ name ++ " = ").? + name.len + 4;
    const end = std.mem.findAny(u8, rogue_source[start..], " \n").? + start;
    return std.fmt.parseInt(usize, rogue_source[start..end], 0) catch unreachable;
}

const rogue = struct {
    const map = rogueConstant("MAP");
    const player_x = rogueConstant("PLAYER_X");
    const player_y = rogueConstant("PLAYER_Y");
    const depth_tens = rogueConstant("DEPTH_TENS");
    const depth_ones = rogueConstant("DEPTH_ONES");
    const player_hp = rogueConstant("PLAYER_HP");
    const dead = rogueConstant("DEAD");
    const monster_x = rogueConstant("MONSTER_X");
    const monster_y = rogueConstant("MONSTER_Y");
    const monster_hp = rogueConstant("MONSTER_HP");
    const monsters = rogueConstant("MONSTERS");
    const turn = rogueConstant("TURN");
    const max_hp = rogueConstant("MAX_HP");
    const wall = rogueConstant("WALL");
    const stairs = rogueConstant("STAIRS");
    const heart = rogueConstant("HEART");
    const right = 0b1000;
    const left = rogueConstant("LEFT");
    const up = rogueConstant("UP");
};

fn tile(m: *figment.Machine, x: usize, y: usize) *u8 {
    return &m.memory[rogue.map + y * 16 + x];
}

fn startRogue(m: *figment.Machine, program: []const u8) !void {
    m.reset(0);
    @memcpy(m.memory[0..program.len], program);
    _ = try runFrame(m);
    _ = try runFrame(m);
}

fn press(m: *figment.Machine, keys: u8) !void {
    m.memory[figment.keys] = keys;
    _ = try runFrame(m);
    m.memory[figment.keys] = 0;
    _ = try runFrame(m);
    _ = try runFrame(m);
}

fn liveMonsters(m: *const figment.Machine) usize {
    var n: usize = 0;
    for (m.memory[rogue.monster_hp..][0..rogue.monsters]) |hp| n += @intFromBool(hp > 0);
    return n;
}

fn removeMonsters(m: *figment.Machine) void {
    @memset(m.memory[rogue.monster_hp..][0..rogue.monsters], 0);
}

fn openRoom(m: *figment.Machine) void {
    for (0..15) |y| for (0..16) |x| {
        tile(m, x, y).* = if (x == 0 or x == 15 or y == 0 or y == 14) rogue.wall else 0;
    };
    m.memory[rogue.player_x] = 2;
    m.memory[rogue.player_y] = 7;
    m.memory[rogue.turn] = 0;
    removeMonsters(m);
}

fn putMonster(m: *figment.Machine, i: usize, x: u8, y: u8, hp: u8) void {
    m.memory[rogue.monster_x + i] = x;
    m.memory[rogue.monster_y + i] = y;
    m.memory[rogue.monster_hp + i] = hp;
}

test "rogue lays out the monster tables and HP the way its code assumes" {
    // The code steps between tables by changing only the low address byte.
    try testing.expectEqual(rogue.monster_x + rogue.monsters, rogue.monster_y);
    try testing.expectEqual(rogue.monster_y + rogue.monsters, rogue.monster_hp);
    try testing.expectEqual(rogue.monster_x >> 8, (rogue.monster_hp + rogue.monsters - 1) >> 8);
    // The status line shows HP as one digit.
    try testing.expect(rogue.max_hp <= 9);
}

test "rogue puts as many monsters on a floor as the depth, up to 4, away from the player" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    for ([_]u8{ 1, 3, 9 }, 0..) |depth, i| {
        if (i > 0) {
            removeMonsters(&m);
            m.memory[rogue.depth_ones] = depth - 1;
            m.memory[rogue.player_hp] = rogue.max_hp - 1;
            const x = m.memory[rogue.player_x];
            const y = m.memory[rogue.player_y];
            tile(&m, x + 1, y).* = rogue.stairs;
            try press(&m, rogue.right);
            try testing.expectEqual(depth, m.memory[rogue.depth_ones]);
            try testing.expectEqual(rogue.max_hp, m.memory[rogue.player_hp]);
        }
        try testing.expectEqual(@min(depth, 4), liveMonsters(&m));
        const px = m.memory[rogue.player_x];
        const py = m.memory[rogue.player_y];
        for (0..rogue.monsters) |n| {
            if (m.memory[rogue.monster_hp + n] == 0) continue;
            const x = m.memory[rogue.monster_x + n];
            const y = m.memory[rogue.monster_y + n];
            try testing.expectEqual(0, tile(&m, x, y).*);
            try testing.expect(@max(px, x) - @min(px, x) > 2 or @max(py, y) - @min(py, y) > 2);
        }
    }
    removeMonsters(&m);
    const x = m.memory[rogue.player_x];
    tile(&m, x + 1, m.memory[rogue.player_y]).* = rogue.stairs;
    try press(&m, rogue.right);
    try testing.expectEqual(rogue.max_hp, m.memory[rogue.player_hp]);
}

test "rogue keeps everyone off the walls and each other through deaths and new runs" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    m.reset(0);
    @memcpy(m.memory[0..program.len], program);
    var r: std.Random.DefaultPrng = .init(1);
    var deaths: usize = 0;
    var kills: usize = 0;
    var deepest: usize = 0;
    var hp_before: [rogue.monsters]u8 = @splat(0);
    var depth_before: usize = 1;
    for (0..20_000) |i| {
        // A random arrow on every other frame, so each one is a fresh press.
        m.memory[figment.keys] = if (i % 2 == 0) @as(u8, 1) << r.random().int(u2) else 0;
        const dead_before = m.memory[rogue.dead];
        _ = try runFrame(&m);
        deaths += @intFromBool(dead_before == 0 and m.memory[rogue.dead] == 1);
        const x = m.memory[rogue.player_x];
        const y = m.memory[rogue.player_y];
        try testing.expect(x < 16 and y < 15);
        try testing.expect(tile(&m, x, y).* != rogue.wall);
        try testing.expect(m.memory[rogue.player_hp] <= rogue.max_hp);
        const depth = @as(usize, m.memory[rogue.depth_tens]) * 10 + m.memory[rogue.depth_ones];
        deepest = @max(deepest, depth);
        for (0..rogue.monsters) |a| {
            const hp = m.memory[rogue.monster_hp + a];
            if (dead_before == 0 and depth == depth_before and hp_before[a] > 0 and hp == 0) kills += 1;
            hp_before[a] = hp;
            if (hp == 0) continue;
            const ax = m.memory[rogue.monster_x + a];
            const ay = m.memory[rogue.monster_y + a];
            try testing.expect(tile(&m, ax, ay).* != rogue.wall);
            try testing.expect(ax != x or ay != y);
            for (a + 1..rogue.monsters) |b| {
                if (m.memory[rogue.monster_hp + b] == 0) continue;
                try testing.expect(ax != m.memory[rogue.monster_x + b] or ay != m.memory[rogue.monster_y + b]);
            }
        }
        depth_before = depth;
    }
    try testing.expect(deaths >= 3);
    try testing.expect(kills >= 10);
    try testing.expect(deepest >= 3);
}

test "rogue attacks a monster by walking into it and kills it in two hits" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    openRoom(&m);
    putMonster(&m, 0, 3, 7, 2);
    try press(&m, rogue.right);
    try testing.expectEqual(1, m.memory[rogue.monster_hp]);
    try testing.expectEqual(2, m.memory[rogue.player_x]);
    try testing.expectEqual(8, m.memory[rogue.player_hp]);
    try press(&m, rogue.right);
    try testing.expectEqual(0, m.memory[rogue.monster_hp]);
    try testing.expectEqual(2, m.memory[rogue.player_x]);
    try testing.expectEqual(8, m.memory[rogue.player_hp]);
    try press(&m, rogue.right);
    try testing.expectEqual(3, m.memory[rogue.player_x]);
    putMonster(&m, 0, 2, 7, 2);
    m.memory[rogue.turn] = 0;
    try press(&m, rogue.left);
    try testing.expectEqual(1, m.memory[rogue.monster_hp]);
    try testing.expectEqual(7, m.memory[rogue.player_hp]);
}

test "rogue monsters act every other turn, so the player can outrun them and strike first" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    openRoom(&m);
    putMonster(&m, 0, 8, 7, 2);
    for ([_]u8{ 7, 7, 6 }, 3..) |monster_x, player_x| {
        try press(&m, rogue.right);
        try testing.expectEqual(player_x, m.memory[rogue.player_x]);
        try testing.expectEqual(monster_x, m.memory[rogue.monster_x]);
    }
    try press(&m, rogue.right);
    try testing.expectEqual(5, m.memory[rogue.player_x]);
    try testing.expectEqual(1, m.memory[rogue.monster_hp]);
    try press(&m, rogue.right);
    try testing.expectEqual(0, m.memory[rogue.monster_hp]);
    try testing.expectEqual(rogue.max_hp, m.memory[rogue.player_hp]);
}

test "rogue monsters step toward the player and go around a wall" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    openRoom(&m);
    putMonster(&m, 0, 8, 7, 2);
    putMonster(&m, 1, 8, 9, 2);
    tile(&m, 7, 9).* = rogue.wall;
    try press(&m, rogue.right);
    try testing.expectEqual(3, m.memory[rogue.player_x]);
    try testing.expectEqualSlices(u8, &.{ 7, 8 }, m.memory[rogue.monster_x..][0..2]);
    try testing.expectEqualSlices(u8, &.{ 7, 8 }, m.memory[rogue.monster_y..][0..2]);
    try testing.expectEqual(rogue.max_hp, m.memory[rogue.player_hp]);
}

test "rogue monsters do not walk into each other" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    openRoom(&m);
    putMonster(&m, 0, 9, 7, 2);
    putMonster(&m, 1, 8, 7, 2);
    try press(&m, rogue.right);
    try testing.expectEqualSlices(u8, &.{ 9, 7 }, m.memory[rogue.monster_x..][0..2]);
}

test "rogue ends the run at 0 HP and starts over on the next arrow" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    m.memory[rogue.depth_ones] = 5;
    openRoom(&m);
    putMonster(&m, 0, 4, 7, 2);
    m.memory[rogue.player_hp] = 1;
    try press(&m, rogue.right);
    try testing.expectEqual(0, m.memory[rogue.player_hp]);
    try testing.expectEqual(1, m.memory[rogue.dead]);
    for (0..30) |_| _ = try runFrame(&m);
    try testing.expectEqual(3, m.memory[rogue.player_x]);
    try testing.expectEqual(5, m.memory[rogue.depth_ones]);
    try press(&m, rogue.left);
    try testing.expectEqual(0, m.memory[rogue.dead]);
    try testing.expectEqual(rogue.max_hp, m.memory[rogue.player_hp]);
    try testing.expectEqual(1, m.memory[rogue.depth_ones]);
    try testing.expectEqual(1, liveMonsters(&m));
}

/// Steps onto stairs put to the player's right, from the depth `tens`, `ones`.
fn descendFrom(m: *figment.Machine, tens: u8, ones: u8) !void {
    m.memory[rogue.depth_tens] = tens;
    m.memory[rogue.depth_ones] = ones;
    tile(m, m.memory[rogue.player_x] + 1, m.memory[rogue.player_y]).* = rogue.stairs;
    try press(m, rogue.right);
}

/// The 64 pixels of status line tile `x`, row by row.
fn statusTile(m: *const figment.Machine, x: usize) [64]u8 {
    var pixels: [64]u8 = undefined;
    for (0..8) |row| @memcpy(pixels[row * 8 ..][0..8], m.memory[figment.screen_start + row * 128 + x * 8 ..][0..8]);
    return pixels;
}

test "rogue gives monsters more HP deeper down" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    const floors = [_]struct { tens: u8, ones: u8, hp: u8 }{
        .{ .tens = 0, .ones = 0, .hp = 2 },
        .{ .tens = 0, .ones = 3, .hp = 2 },
        .{ .tens = 0, .ones = 4, .hp = 3 },
        .{ .tens = 0, .ones = 8, .hp = 3 },
        .{ .tens = 0, .ones = 9, .hp = 4 },
        .{ .tens = 9, .ones = 8, .hp = 4 },
    };
    for (floors) |floor| {
        removeMonsters(&m);
        try descendFrom(&m, floor.tens, floor.ones);
        try testing.expect(liveMonsters(&m) > 0);
        for (m.memory[rogue.monster_hp..][0..rogue.monsters]) |hp| {
            if (hp > 0) try testing.expectEqual(floor.hp, hp);
        }
    }
}

test "rogue puts one heart on each floor, off the player" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    for (0..10) |i| {
        if (i > 0) {
            removeMonsters(&m);
            try descendFrom(&m, 0, 1);
        }
        var hearts: usize = 0;
        for (m.memory[rogue.map..][0 .. 16 * 15]) |t| hearts += @intFromBool(t == rogue.heart);
        try testing.expectEqual(1, hearts);
        try testing.expect(tile(&m, m.memory[rogue.player_x], m.memory[rogue.player_y]).* != rogue.heart);
    }
}

test "rogue heals 3 HP, up to the max, when the player walks onto a heart" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    openRoom(&m);
    tile(&m, 3, 7).* = rogue.heart;
    tile(&m, 4, 7).* = rogue.heart;
    m.memory[rogue.player_hp] = 4;
    try press(&m, rogue.right);
    try testing.expectEqual(3, m.memory[rogue.player_x]);
    try testing.expectEqual(7, m.memory[rogue.player_hp]);
    try testing.expectEqual(0, tile(&m, 3, 7).*);
    m.memory[rogue.player_hp] = rogue.max_hp - 1;
    try press(&m, rogue.right);
    try testing.expectEqual(rogue.max_hp, m.memory[rogue.player_hp]);
    try testing.expectEqual(0, tile(&m, 4, 7).*);
}

test "rogue shows the HP a monster has left after a hit, and clears it on a new floor" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    try startRogue(&m, program);
    const blank: [64]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &blank, &statusTile(&m, 7));
    try testing.expectEqualSlices(u8, &blank, &statusTile(&m, 8));
    openRoom(&m);
    putMonster(&m, 0, 3, 7, 3);
    m.memory[rogue.player_hp] = 3;
    try press(&m, rogue.right);
    try testing.expectEqual(2, m.memory[rogue.monster_hp]);
    // The monster hits back, so the player's HP digit on the right shows the same 2.
    try testing.expectEqual(2, m.memory[rogue.player_hp]);
    try testing.expectEqualSlices(u8, &statusTile(&m, 15), &statusTile(&m, 8));
    try testing.expect(!std.mem.eql(u8, &blank, &statusTile(&m, 7)));
    removeMonsters(&m);
    try descendFrom(&m, 0, 1);
    try testing.expectEqualSlices(u8, &blank, &statusTile(&m, 7));
    try testing.expectEqualSlices(u8, &blank, &statusTile(&m, 8));
}

test "rogue stops counting the depth at 99" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, rogue_source, &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    m.reset(0);
    @memcpy(m.memory[0..program.len], program);
    _ = try runFrame(&m);
    _ = try runFrame(&m);
    m.memory[rogue.depth_tens] = 9;
    m.memory[rogue.depth_ones] = 8;
    for (0..2) |_| {
        // Put the stairs to the player's right, step onto them, and let the new floor draw.
        const x = m.memory[rogue.player_x];
        const y = m.memory[rogue.player_y];
        tile(&m, x + 1, y).* = rogue.stairs;
        m.memory[figment.keys] = rogue.right;
        _ = try runFrame(&m);
        m.memory[figment.keys] = 0;
        _ = try runFrame(&m);
        _ = try runFrame(&m);
        try testing.expectEqual(9, m.memory[rogue.depth_tens]);
        try testing.expectEqual(9, m.memory[rogue.depth_ones]);
    }
}

test "the demo ends every frame well inside the 100,000 instructions SPEC.md allows" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(testing.allocator, @embedFile("demo.asm"), &diagnostic);
    defer testing.allocator.free(program);
    var m: figment.Machine = undefined;
    m.reset(0);
    @memcpy(m.memory[0..program.len], program);
    var most: usize = 0;
    for (0..300) |i| {
        m.memory[figment.keys] = if (i < 10) 0b1_1000 else @truncate(i);
        most = @max(most, try runFrame(&m));
        if (i == 9) {
            try testing.expectEqual(7, m.memory[figment.screen_start + 64 * 128 + 74]);
            try testing.expectEqual(48 + 74 / 4, m.memory[figment.beep]);
        }
    }
    try testing.expect(most < 200);
}
