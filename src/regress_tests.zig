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

test "BUG-006: macros that fan out stop after a bounded amount of work" {
    try expect(.man, ".de A\n" ++ ".A\n.A\n.A\n.A\n.A\n.A\n.A\n.A\n" ++ "..\n.A\ndone\n", "done\n");
}

test "BUG-007: macro arguments that double at each level stop at a byte limit" {
    try expect(.man, ".de A\n.A \"" ++ "\\\\$1" ++ "\\\\$1\\\\$1\\\\$1\\\\$1\\\\$1\\\\$1\\\\$1" ++ "\"\n..\n.A xxxxxxxx\ndone\n", "done\n");
}

test "BUG-007: a macro may append to itself while it runs" {
    try expect(.man, ".de A\none\n.am A\ntwo\n..\n..\n.am A\n..\n.A\n", "one\n");
}

test "BUG-008: strings that expand exponentially stop at a limit" {
    const out = try render(.man, ".ds a " ++ "\\*a\\*a\\*a\\*a\\*a\\*a\\*a\\*a\n\\*a\ndone\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "done") != null);
}

test "BUG-009: a long chain of conditionals on one line is cut off" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    for (0..100_000) |_| try big.appendSlice(testing.allocator, ".if n ");
    try big.appendSlice(testing.allocator, "x\ndone\n");
    try expect(.man, big.items, "done\n");
    try expect(.man, ".if n .if n .if n shown\n", "shown\n");
}

test "BUG-010: table rows and padding are bounded" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, ".TS\nl.\na");
    for (0..2000) |_| try big.append(testing.allocator, '\t');
    try big.appendSlice(testing.allocator, "z\n");
    for (0..2000) |_| try big.appendSlice(testing.allocator, "x\n");
    try big.appendSlice(testing.allocator, ".TE\n");
    var doc = try gtroff.parseMan(testing.allocator, big.items);
    defer doc.deinit();
    var walker = md.Walker.init(doc.root);
    var cells: usize = 0;
    var last_text: []const u8 = "";
    while (walker.next()) |ev| {
        if (!ev.entering) continue;
        if (ev.node.kind == .table_cell) cells += 1;
        if (ev.node.kind == .text and std.mem.endsWith(u8, ev.node.literal, "z")) last_text = ev.node.literal;
    }
    // 2001 rows of at least one cell, the first with 64, and bounded padding.
    try testing.expect(cells <= 2001 + 63 + (1 << 16));
    // Text past the last column is kept.
    try testing.expect(last_text.len > 0);
}

test "BUG-011: a long mdoc line takes linear memory" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, ".No");
    for (0..20_000) |_| try big.appendSlice(testing.allocator, " word");
    var doc = try gtroff.parseMdoc(testing.allocator, big.items);
    defer doc.deinit();
    // About 1 KB a word; copying the run for each word took 1 GB.
    try testing.expect(doc.arena.queryCapacity() < 40 << 20);
    const out = try doc.toTextAlloc(testing.allocator, .{ .width = 0 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 20_000 * 5), out.len);
}

fn writeFrom(doc_in: anytype, options: gtroff.WriteOptions) ![]u8 {
    var doc = try doc_in;
    defer doc.deinit();
    return gtroff.toManAlloc(testing.allocator, &doc, options);
}

fn markdown(src: []const u8) !md.Document {
    return md.Document.parse(testing.allocator, src, .{ .extensions = md.Extensions.all });
}

test "BUG-012: text cannot start a request line" {
    const out = try writeFrom(markdown("hello&#10;.so /etc/hostname\n\n`a`&#13;'br\n"), .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "\n.so") == null);
    try testing.expect(std.mem.find(u8, out, "hello .so /etc/hostname\n") != null);
    try testing.expect(std.mem.findScalar(u8, out, '\r') == null);
}

test "BUG-013: table cells are always data" {
    const out = try writeFrom(markdown("| h |\n|---|\n| .so /etc/hostname |\n| _ |\n| T{ |\n| \\.TE |\n\nafter\n"), .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "h\n\\&.so /etc/hostname\n\\&_\nT{\\&\n\\&.TE\n.TE\n") != null);
}

test "BUG-015: --!> does not end a kept comment" {
    var doc = try gtroff.parseManOptions(testing.allocator, ".\\\" x --!> <img src=x>\n", .{ .keep_comments = true });
    defer doc.deinit();
    const out = try doc.toHtmlAlloc(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<!-- x --! > <img src=x> -->\n", out);
}

test "BUG-034: options cannot break out of a macro argument" {
    const out = try writeFrom(markdown("x\n"), .{ .date = "x\n.so /dev/null", .title = "a\r\nb" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, ".TH \"a  b\" \"7\" \"x .so /dev/null\" \"\" \"\"\n"));
}

test "BUG-035: footnote labels and comment lines are made safe" {
    const out = try writeFrom(markdown("---\na: b\\\n---\ntext[^\\so]\n\n[^\\so]: note\n"), .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, ".\\\" a: b\\&\n") != null);
    try testing.expect(std.mem.find(u8, out, "[\\eso]") != null);
    try testing.expect(std.mem.find(u8, out, "[\\so]") == null);
}

test "BUG-036: control characters and bad UTF-8 do not reach the tree" {
    const src = "raw\x1b]0;p\x07 \\[u001b][31m \\[u0000]z caf\xe9\n.UR a\x00b\ny\n.UE\n";
    for ([_]Format{ .man, .mdoc }) |format| {
        var doc = try switch (format) {
            .man => gtroff.parseMan(testing.allocator, src),
            .mdoc => gtroff.parseMdoc(testing.allocator, src),
        };
        defer doc.deinit();
        var walker = md.Walker.init(doc.root);
        while (walker.next()) |ev| {
            try testing.expect(std.unicode.utf8ValidateSlice(ev.node.literal));
            for (ev.node.literal) |c| try testing.expect(c >= 32 or c == '\t' or c == '\n');
        }
    }
}

test "BUG-016: a nested .ie/.el leaves the outer one alone" {
    try expect(.man, ".ie n \\{\\\n.ie t inner-yes\n.el inner-no\n.\\}\n.el OUTER-ELSE\n", "inner-no\n");
}

test "BUG-017: .el needs no blank before \\{" {
    try expect(.man, ".ie t yes\n.el\\{\\\nfirst\nsecond\n.\\}\n", "first second\n");
    try expect(.man, ".ie n yes\n.el\\{\\\nfirst\nsecond\n.\\}\n", "yes\n");
}

test "BUG-018: a comment ending in a backslash does not swallow the next line" {
    try expect(.man, ".\\\" trailing \\\nnext\nkept\n", "next kept\n");
}

test "BUG-019: common escapes do not print their letters or arguments" {
    try expect(.man, "a\\0b c\\#d hidden\n", "a\u{a0}b c\n");
    try expect(.man, "A\\m(rdB \\F[CW]C \\s[12]D \\s'12'E \\kxG \\)H\\{\\}\n", "AB C D E G H\n");
    try expect(.man, "\\z\\(emF\n", "\u{2014}F\n");
}

test "BUG-020: escapes in link addresses are read" {
    try expect(.man, ".UR https://\\:example.com/a\\-b\nsite\n.UE\n", "site <https://example.com/a-b>\n");
    try expect(.man, ".MT bug\\-x@gnu.org\n.ME\n", "mailto:bug-x@gnu.org\n");
}

test "BUG-021: .SY and .OP read the escapes in their arguments" {
    try expect(.man, ".SY cmd\\-x\n.OP \\-a \\fIfile\\fR\n.YS\n", "**cmd-x** [**-a** _file_]\n");
}

test "BUG-022: control lines with blanks or an apostrophe work in no-fill blocks" {
    try expect(.man, ".nf\na\n'br\n.  fi\nfilled one\nfilled two\n", "a\n\nfilled one filled two\n");
}

test "BUG-023: headings, tables and links in no-fill blocks stay in order" {
    try expect(.man, ".SH ONE\n.nf\ncode\n.SH TWO\nmore\ntext\n", "## ONE\n\n       code\n\n## TWO\n\n       more text\n");
    const out = try render(.man, ".nf\nbefore\n.TS\nl.\ncell\n.TE\nafter\n.fi\n");
    defer testing.allocator.free(out);
    const before = std.mem.find(u8, out, "before").?;
    const cell = std.mem.find(u8, out, "cell").?;
    try testing.expect(before < cell and cell < std.mem.find(u8, out, "after").?);
    try expect(.man, ".nf\nsee\n.UR http://x.example\n.UE .\nend\n.fi\n", "see <http://x.example>.\nend\n");
}

test "BUG-024: a table without .TE does not drop the rest of the page" {
    const out = try render(.man, ".SH A\n.TS\nl.\nx\n.SH IMPORTANT\nlots of text\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "x") != null);
    try testing.expect(std.mem.find(u8, out, "## IMPORTANT\n\n       lots of text") != null);
    const eof = try render(.man, ".TS\nl.\nlast-row\n");
    defer testing.allocator.free(eof);
    try testing.expect(std.mem.find(u8, eof, "last-row") != null);
}

test "BUG-025: mdoc end of line comments are not printed" {
    try expect(.mdoc, ".Fl a \\\" SECRET COMMENT\ntext \\\" HIDDEN WORDS\n", "**-a** text\n");
}

test "BUG-026: mdoc text lines keep fonts and non-breaking blanks" {
    try expect(.mdoc, "\\fBbold words\\fR and a\\ b\n", "**bold words** and a\u{a0}b\n");
    try expect(.mdoc, ".No a\\ b\n", "a\u{a0}b\n");
}

test "BUG-027: lone dots and blanks after the dot are control lines" {
    try expect(.mdoc, "one\n.\ntwo\n.\\}\n. Pp\nthree\n", "one two\n\nthree\n");
}

test "BUG-028: mdoc pages may use roff requests" {
    try expect(.mdoc, ".ig\nIGNORED\n..\n.de ZZ\nbody \\\\$1\n..\n.if t TYPESET\n.ds X y\n\\*X\n", "y\n");
    try expect(.mdoc, ".de ZZ\nbody \\\\$1\n..\n.ZZ called\n", "body called\n");
    try expect(.mdoc, ".ie n yes\n.el no\n.if t \\{\n.Pp\nhidden\n.\\}\nafter\n", "yes after\n");
    const out = try render(.mdoc, ".TS\nl l.\na\tb\n.TE\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "│ a │ b │") != null);
}

test "BUG-029: punctuation after name macros is kept and not read as a name" {
    try expect(.mdoc, ".Nm foo\n.Pp\nRun\n.Nm .\nThen\n.Nm ,\n", "**foo**\n\nRun **foo**. Then **foo**,\n");
    try expect(.mdoc, ".Fl Fl .\n.Pp\n.Xr ls .\n.Xr cp 1 ,\n", "**--**.\n\nls. cp(1),\n");
    try expect(.mdoc, ".Ux .\n.At .\n.Bx .\n.Lb libm .\n", "UNIX. AT&T UNIX. BSD. Math Library (libm, -lm).\n");
    try expect(.mdoc, ".Nm .\n.Nm real\n.Nm\n", ". **real** **real**\n");
}

test "BUG-030: words after .Xc are kept" {
    try expect(.mdoc, ".Xo\n.Fl a\n.Xc Ar tail ,\nend\n", "**-a** _tail_, end\n");
}

test "BUG-031: an .Xo still open at the end of the page keeps its words" {
    const out = try render(.mdoc, "before\n.Xo\n.Fl a\n.No kept words\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "**-a** kept words") != null);
}

test "BUG-032: column list cells stay in their rows" {
    var doc = try gtroff.parseMdoc(testing.allocator, ".Bl -column a b c\n.It x\n.It a Ta b Ta KEEPME\n.It one\ttwo\n.It first\n.Ta second\n.El\nafter\n");
    defer doc.deinit();
    const html = try doc.toHtmlAlloc(testing.allocator);
    defer testing.allocator.free(html);
    for ([_][]const u8{
        "<td>x</td>\n<td></td>\n<td></td>",
        "<td>a</td>\n<td>b</td>\n<td>KEEPME</td>",
        "<td>one</td>\n<td>two</td>",
        "<td>first</td>\n<td>second</td>",
        "<p>after</p>",
    }) |want| try testing.expect(std.mem.find(u8, html, want) != null);
}

test "BUG-066: a text line inside .Xo is not an argument of the macro before it" {
    try expect(.mdoc, ".Xo\n.Fl a\nkept words\n.Xc\n", "**-a** kept words\n");
}

test "BUG-033: a first heading with parentheses is not lost" {
    const out = try writeFrom(markdown("# Using foo() safely\n\nbody\n"), .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, ".TH \"Using foo() safely\" \"7\"\n"));
}

test "BUG-037: conditions may have blanks inside parentheses" {
    try expect(.man, ".if (1 > 0) shown\n.if ( 1 > 2 ) hidden\nend\n", "shown end\n");
    try testing.expectEqual(@as(i64, 6), try gtroff.expr.eval("( ( 1 + 2 ) * 2 )"));
    try testing.expectError(error.Syntax, gtroff.expr.eval("1 + 2"));
}

test "BUG-038: size escapes leave the digits that follow them" {
    try expect(.man, "\\s05 files and \\s-12 items \\s12x \\s(425\n", "5 files and 2 items x 5\n");
}

test "BUG-039: a .ds value is the rest of the line" {
    try expect(.man, ".ds Q \"hello world\"\n.ds E \"\"\n[\\*Q] [\\*E]\n", "[hello world\"] [\"]\n");
    var doc = try gtroff.parseMan(testing.allocator, ".ds S a    b\n\\*S\n");
    defer doc.deinit();
    const html = try doc.toHtmlAlloc(testing.allocator);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>a    b</p>\n", html);
}

test "BUG-040: \\$@ keeps the arguments apart" {
    try expect(.man, ".de X\n.BR \\\\$@\n..\n.X \"a b\" c\n", "**a b**c\n");
}

test "BUG-041: a custom end marker must be the whole name" {
    try expect(.man, ".de X Z\nhidden\n.Zfoo\nstill hidden\n.Z\nshown\n", "shown\n");
}

test "BUG-042: a .SH without a title does not take the text after the next one" {
    try expect(.man, ".SH\n.SH B\nbody text\n", "## B\n\n       body text\n");
}

test "BUG-043: .SH and .PP reset the tagged paragraph indent" {
    var doc = try gtroff.parseMan(testing.allocator, ".TP 20\na\nb\n.SH NEW\n.TP\nc\nd\n.TP 12\ne\nf\n.PP\n.TP\ng\nh\n");
    defer doc.deinit();
    var walker = md.Walker.init(doc.root);
    var got: [4]u16 = undefined;
    var n: usize = 0;
    while (walker.next()) |ev| if (ev.entering and ev.node.kind == .deflist_def) {
        got[n] = ev.node.indent;
        n += 1;
    };
    try testing.expectEqualSlices(u16, &.{ 20, 7, 12, 7 }, got[0..n]);
}

test "BUG-044: a link can be a tagged paragraph's term" {
    var doc = try gtroff.parseMan(testing.allocator, ".TP\n.UR http://x.example\nterm-text\n.UE\ndefinition\n");
    defer doc.deinit();
    const html = try doc.toHtmlAlloc(testing.allocator);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<dl>\n<dt><a href=\"http://x.example\">term-text</a></dt>\n<dd>\n<p>definition</p>\n</dd>\n</dl>\n", html);
    for ([_][]const u8{ "see [here](http://x.example) now\n: def\n", "[here](http://x.example)\n: def\n" }) |src| {
        const out = try writeFrom(markdown(src), .{});
        defer testing.allocator.free(out);
        var back = try gtroff.parseMan(testing.allocator, out);
        defer back.deinit();
        const h = try back.toHtmlAlloc(testing.allocator);
        defer testing.allocator.free(h);
        try testing.expect(std.mem.find(u8, h, "http://x.example") != null);
        try testing.expect(std.mem.find(u8, h, "<p>def</p>") != null);
    }
}

test "BUG-045: .T& changes the format and is not a row" {
    var doc = try gtroff.parseMan(testing.allocator, ".TS\nl l.\na\tb\n.T&\nr r.\nc\td\n.TE\n");
    defer doc.deinit();
    const html = try doc.toHtmlAlloc(testing.allocator);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.find(u8, html, "r r") == null);
    try testing.expect(std.mem.find(u8, html, "<td align=\"right\">c</td>\n<td align=\"right\">d</td>") != null);
}
