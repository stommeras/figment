const std = @import("std");

const figment = @import("figment");

const max_steps = 10_000_000;

const Screen = [figment.screen_size * figment.screen_size]u8;

pub fn render(w: *std.Io.Writer, screen: *const Screen) std.Io.Writer.Error!void {
    for (0..figment.screen_size / 2) |row| {
        var last: ?[2]u4 = null;
        for (0..figment.screen_size) |x| {
            const top = screen[row * 2 * figment.screen_size + x];
            const bottom = screen[(row * 2 + 1) * figment.screen_size + x];
            const pair: [2]u4 = .{ @truncate(top), @truncate(bottom) };
            if (last == null or !std.meta.eql(last.?, pair)) {
                const fg = figment.palette[pair[0]];
                const bg = figment.palette[pair[1]];
                try w.print("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ fg[0], fg[1], fg[2], bg[0], bg[1], bg[2] });
                last = pair;
            }
            try w.writeAll("▀");
        }
        try w.writeAll("\x1b[0m\n");
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: figment-run <program.bin>\n", .{});
        std.process.exit(1);
    }
    const program = std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(figment.memory_size + 1)) catch |err| {
        switch (err) {
            error.StreamTooLong => std.debug.print("{s}: the program does not fit in memory\n", .{args[1]}),
            else => std.debug.print("{s}: cannot read: {t}\n", .{ args[1], err }),
        }
        std.process.exit(1);
    };
    const m = try arena.create(figment.Machine);
    m.reset(0);
    @memcpy(m.memory[0..program.len], program);
    for (0..max_steps) |_| {
        if (m.state != .running) break;
        m.step();
    }
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    render(&stdout.interface, m.memory[figment.screen_start..]) catch std.process.exit(1);
    stdout.interface.flush() catch std.process.exit(1);
    if (m.state == .faulted) {
        std.debug.print("faulted at 0x{X:0>4}\n", .{m.pc});
        std.process.exit(1);
    }
}

const testing = std.testing;

fn times(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}

const blank: Screen = @splat(0);

fn expectRender(screen: *const Screen, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(&out.writer, screen);
    try testing.expectEqualStrings(expected, out.written());
}

test "a screen of one color sets the colors once per line and draws 128 half blocks" {
    var screen = blank;
    @memset(&screen, 0x0B);
    const line = comptime "\x1b[38;2;60;196;90;48;2;60;196;90m" ++ times("▀", 128) ++ "\x1b[0m\n";
    try expectRender(&screen, times(line, 64));
}

test "the upper pixel is the foreground, the lower the background, and the high nibble is ignored" {
    var screen = blank;
    screen[0] = 0x07;
    screen[128] = 0x08;
    screen[1] = 0xF7;
    screen[129] = 0x38;
    screen[2] = 0x08;
    screen[130] = 0x07;
    screen[128 * 127 + 127] = 0x0C;
    const black = "\x1b[38;2;0;0;0;48;2;0;0;0m";
    const first = comptime "\x1b[38;2;244;241;232;48;2;232;52;63m▀▀" ++ "\x1b[38;2;232;52;63;48;2;244;241;232m▀" ++ black ++ times("▀", 125) ++ "\x1b[0m\n";
    const middle = comptime black ++ times("▀", 128) ++ "\x1b[0m\n";
    const last = comptime black ++ times("▀", 127) ++ "\x1b[38;2;0;0;0;48;2;58;142;240m▀\x1b[0m\n";
    try expectRender(&screen, comptime first ++ times(middle, 62) ++ last);
}

test "the palette matches the table in SPEC.md" {
    const spec = @embedFile("SPEC.md");
    for (figment.palette, 0..) |rgb, i| {
        var buf: [32]u8 = undefined;
        const cell = try std.fmt.bufPrint(&buf, "`{X}` | `#{X:0>2}{X:0>2}{X:0>2}", .{ i, rgb[0], rgb[1], rgb[2] });
        testing.expect(std.mem.find(u8, spec, cell) != null) catch |err| {
            std.debug.print("SPEC.md has no cell {s}\n", .{cell});
            return err;
        };
    }
}
