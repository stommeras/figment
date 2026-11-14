const std = @import("std");

const figment = @import("figment");

pub const max_steps = 10_000_000;

pub fn render(w: *std.Io.Writer, screen: *const [figment.screen_size * figment.screen_size]u8) std.Io.Writer.Error!void {
    _ = w;
    _ = screen;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
}

const testing = std.testing;

fn times(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}

const blank: [figment.screen_size * figment.screen_size]u8 = @splat(0);

fn expectRender(screen: *const [figment.screen_size * figment.screen_size]u8, expected: []const u8) !void {
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
