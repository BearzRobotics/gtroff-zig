//! One regression test for each bug fixed after the 0.5.0 audit.

const std = @import("std");
const md = @import("md");
const gtroff = @import("root.zig");
const testing = std.testing;

const Format = enum { man, mdoc };

/// The page as terminal text, unwrapped.
fn render(format: Format, src: []const u8) ![]u8 {
    var doc = try switch (format) {
        .man => gtroff.parseMan(testing.allocator, src),
        .mdoc => gtroff.parseMdoc(testing.allocator, src),
    };
    defer doc.deinit();
    return doc.toTextAlloc(testing.allocator, .{ .width = 0 });
}

fn expect(format: Format, src: []const u8, want: []const u8) !void {
    const out = try render(format, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(want, out);
}

test "BUG-001: a table started inside a T{ block does not disturb the outer one" {
    const out = try render(.man, ".TS\nl.\nT{\n.TS\nT}\nrow2\nrow3\n.TE\nafter\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "row2") != null);
    try testing.expect(std.mem.find(u8, out, "row3") != null);
    try testing.expect(std.mem.find(u8, out, "after") != null);
}

test "BUG-002: deeply nested expressions are an error, not a stack overflow" {
    const n = 400_000;
    const buf = try testing.allocator.alloc(u8, n + 1);
    defer testing.allocator.free(buf);
    @memset(buf, '(');
    try testing.expectError(error.Syntax, gtroff.expr.eval(buf[0..n]));
    @memset(buf, '-');
    buf[n] = '1';
    try testing.expectEqual(@as(i64, 1), try gtroff.expr.eval(buf));
    try testing.expectEqual(@as(i64, 0), try gtroff.expr.eval("!-!0"));
}
