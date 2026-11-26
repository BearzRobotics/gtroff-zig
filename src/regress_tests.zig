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

test "BUG-003: a long run of enclosure macros does not overflow the stack" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, ".Sh D\n.");
    for (0..20_000) |_| try big.appendSlice(testing.allocator, "Op ");
    try big.appendSlice(testing.allocator, "x\n");
    const out = try render(.mdoc, big.items);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "x") != null);
}

test "BUG-004: a false block closed on its own line does not drop the rest of the page" {
    try expect(.man, ".if t \\{ typeset \\}\nkept\n", "kept\n");
    try expect(.man, ".if t \\{\\\n.\\}\nkept\n", "kept\n");
    try expect(.man, ".if t \\{\n.if n \\{ x \\}\nhidden\n.\\}\nkept\n", "kept\n");
}

test "BUG-005: a written table reads back with its columns" {
    var doc = try md.Document.parse(testing.allocator, "| name | count |\n|---|---|\n| apple | 12 |\n", .{ .extensions = md.Extensions.all });
    defer doc.deinit();
    const written = try gtroff.toManAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(written);
    try testing.expect(std.mem.find(u8, written, "\n.TS\nallbox;\n") != null);
    var back = try gtroff.parseMan(testing.allocator, written);
    defer back.deinit();
    const html = try back.toHtmlAlloc(testing.allocator);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.find(u8, html, "<td>apple</td>\n<td>12</td>") != null);
}
