//! The man(7) writer and comment round trips.

const std = @import("std");
const md = @import("md");
const gtroff = @import("root.zig");
const testing = std.testing;

fn textOf(doc: *const md.Document) ![]u8 {
    return doc.toTextAlloc(testing.allocator, .{ .width = 80 });
}

const page =
    \\.\" top comment
    \\.TH DEMO 1 "June 2026"
    \\.SH NAME
    \\demo \- a demo
    \\.SH DESCRIPTION
    \\.\" about this paragraph
    \\Some \fBbold\fR and \fIitalic\fR text.
    \\.PP
    \\Second paragraph.
    \\.SS Options
    \\.TP
    \\.B \-v
    \\Be verbose.
    \\.IP \(bu 2
    \\first
    \\.IP \(bu 2
    \\second
    \\.PP
    \\.nf
    \\  code line
    \\.fi
    \\
;

test "a page written back reads the same" {
    const gpa = testing.allocator;
    var doc = try gtroff.parseManOptions(gpa, page, .{ .keep_comments = true });
    defer doc.deinit();
    const out = try gtroff.toManAlloc(gpa, &doc, .{});
    defer gpa.free(out);
    var doc2 = try gtroff.parseManOptions(gpa, out, .{ .keep_comments = true });
    defer doc2.deinit();
    const a = try textOf(&doc);
    defer gpa.free(a);
    const b = try textOf(&doc2);
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) std.debug.print("--- written\n{s}--- before\n{s}--- after\n{s}\n", .{ out, a, b });
    try testing.expectEqualStrings(a, b);
    // And writing again changes nothing.
    const out2 = try gtroff.toManAlloc(gpa, &doc2, .{});
    defer gpa.free(out2);
    try testing.expectEqualStrings(out, out2);
}

test "comments are kept when asked, and only then" {
    const gpa = testing.allocator;
    var doc = try gtroff.parseManOptions(gpa, page, .{ .keep_comments = true });
    defer doc.deinit();
    const out = try gtroff.toManAlloc(gpa, &doc, .{});
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, ".\\\" top comment\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".\\\" about this paragraph\n") != null);

    var plain = try gtroff.parseMan(gpa, page);
    defer plain.deinit();
    const out2 = try gtroff.toManAlloc(gpa, &plain, .{});
    defer gpa.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, ".\\\"") == null);
}

test "Markdown becomes a man page, comments included" {
    const gpa = testing.allocator;
    var doc = try md.Document.parse(gpa,
        \\# tool(1)
        \\
        \\<!-- written by hand -->
        \\
        \\## NAME
        \\
        \\tool - does *things* with `code`, see [the site](https://example.com/a-b).
        \\
        \\- one
        \\- two
        \\
        \\```
        \\.not a request
        \\back\slash
        \\```
        \\
    , .{});
    defer doc.deinit();
    const out = try gtroff.toManAlloc(gpa, &doc, .{});
    defer gpa.free(out);
    const want =
        \\.TH "tool" "1"
        \\.\" written by hand
        \\.SH "NAME"
        \\.PP
        \\tool \- does \fIthings\fR with \f(CRcode\fR, see
        \\.UR https://example.com/a-b
        \\the site
        \\.UE .
        \\.IP \(bu 2
        \\one
        \\.IP \(bu 2
        \\two
        \\.PP
        \\.nf
        \\\&.not a request
        \\back\eslash
        \\.fi
        \\
    ;
    try testing.expectEqualStrings(want, out);
}

test "text that looks like a request is protected" {
    const gpa = testing.allocator;
    var doc = try md.Document.parse(gpa, "line one\n.TH not a request\n'quoted\n", .{});
    defer doc.deinit();
    const out = try gtroff.toManAlloc(gpa, &doc, .{});
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\n\\&.TH not a request\n\\&'quoted\n") != null);
    var back = try gtroff.parseMan(gpa, out);
    defer back.deinit();
    const t = try textOf(&back);
    defer gpa.free(t);
    try testing.expect(std.mem.indexOf(u8, t, ".TH not a request") != null);
}

test "tables and definition lists" {
    const gpa = testing.allocator;
    var doc = try md.Document.parse(gpa, "| a | b |\n| :-- | --: |\n| 1 | 2 |\n\nTerm\n: Definition\n", .{ .extensions = md.Extensions.all });
    defer doc.deinit();
    const out = try gtroff.toManAlloc(gpa, &doc, .{});
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, ".TS\nallbox;\nlb rb\nl r.\na\tb\n1\t2\n.TE\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".TP\nTerm\nDefinition\n") != null);
}

test "too deep nesting fails cleanly" {
    const gpa = testing.allocator;
    const src = try gpa.alloc(u8, 1000);
    defer gpa.free(src);
    @memset(src, '>');
    src[src.len - 1] = 'x';
    var doc = try md.Document.parse(gpa, src, .{});
    defer doc.deinit();
    try testing.expectError(error.TooDeep, gtroff.toManAlloc(gpa, &doc, .{}));
}

fn expectMan(doc_in: anytype, options: gtroff.WriteOptions, want: []const u8) !void {
    var doc = try doc_in;
    defer doc.deinit();
    const out = try gtroff.toManAlloc(testing.allocator, &doc, options);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(want, out);
}

test "an indented block is written between .RS and .RE" {
    try expectMan(
        gtroff.parseMan(testing.allocator, ".SH A\ntext\n.RS 4\ninner\n.RE\n.PP\nouter\n"),
        .{},
        ".TH \"UNTITLED\" \"7\"\n.SH \"A\"\n.PP\ntext\n.RS 4\n.PP\ninner\n.RE\n.PP\nouter\n",
    );
}

test "ordered list numbers count up from the start" {
    try expectMan(
        md.Document.parse(testing.allocator, "3. a\n4. b\n5. c\n", .{}),
        .{},
        ".TH \"UNTITLED\" \"7\"\n.IP \"3.\" 4\na\n.IP \"4.\" 4\nb\n.IP \"5.\" 4\nc\n",
    );
}

test "a hard line break is written as .br" {
    try expectMan(
        md.Document.parse(testing.allocator, "one\\\ntwo\n", .{}),
        .{},
        ".TH \"UNTITLED\" \"7\"\n.PP\none\n.br\ntwo\n",
    );
}

test "date, source and manual options go into .TH" {
    try expectMan(
        md.Document.parse(testing.allocator, "# t(1)\n", .{}),
        .{ .date = "June 2026", .source = "tools 1.0", .manual = "User Commands" },
        ".TH \"t\" \"1\" \"June 2026\" \"tools 1.0\" \"User Commands\"\n",
    );
}

test "a date alone still goes into .TH" {
    try expectMan(
        md.Document.parse(testing.allocator, "# t(1)\n", .{}),
        .{ .date = "June 2026" },
        ".TH \"t\" \"1\" \"June 2026\" \"\" \"\"\n",
    );
}
