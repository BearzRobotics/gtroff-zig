//! Writes an md-zig tree as a man(7) page, so a document read from Markdown
//! (or edited after reading a man page) can be saved as roff.
//!
//!   heading 1 (first)   .TH            heading 2 / 3+     .SH / .SS
//!   paragraph           .PP            code block         .nf ... .fi
//!   block quote         .RS ... .RE    bullet list        .IP \(bu 2
//!   ordered list        .IP "1." 4     definition list    .TP / .TQ
//!   table               .TS ... .TE    link               .UR ... .UE
//!   strong / emphasis   \fB \fI        code               \f(CR
//!   HTML comment        .\" comment    front matter       .\" lines
//!
//! Comments survive: read a page with `Options.keep_comments` and every
//! `.\"` line is an HTML comment in the tree; the writer turns each one back
//! into `.\"` lines (and `<!-- -->` from a Markdown file becomes one too).
//! Raw HTML other than comments has no roff form and is left out; images are
//! written as their alt text. Man pages read by this library carry layout
//! hints (indented quotes around section bodies); those are written as the
//! `.SH`/`.SS` structure they came from, not as `.RS`.
//!
//! Nesting deeper than `max_depth` fails with `error.TooDeep`.

const std = @import("std");
const Io = std.Io;
const md = @import("md");
const Allocator = std.mem.Allocator;
const Node = md.Node;

pub const Error = Io.Writer.Error || Allocator.Error || error{TooDeep};

pub const max_depth = 100;

pub const Options = struct {
    /// Used for `.TH` when the document has no level-1 heading `name(section)`.
    title: []const u8 = "UNTITLED",
    section: []const u8 = "7",
    date: []const u8 = "",
    source: []const u8 = "",
    manual: []const u8 = "",
};

/// Writes `doc` as a man(7) page.
pub fn writeMan(gpa: Allocator, doc: *const md.Document, w: *Io.Writer, options: Options) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var g: Gen = .{ .a = arena.allocator(), .opts = options };
    try g.document(doc.root);
    try w.writeAll(g.out.items);
}

/// The page in memory, owned by the caller.
pub fn toManAlloc(gpa: Allocator, doc: *const md.Document, options: Options) (Allocator.Error || error{TooDeep})![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    writeMan(gpa, doc, &out.writer, options) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    return out.toOwnedSlice();
}

const Font = struct {
    bold: bool = false,
    italic: bool = false,
    mono: bool = false,

    fn eql(a: Font, b: Font) bool {
        return a.bold == b.bold and a.italic == b.italic and a.mono == b.mono;
    }

    fn esc(self: Font) []const u8 {
        if (self.mono) {
            if (self.bold) return "\\f(CB";
            if (self.italic) return "\\f(CI";
            return "\\f(CR";
        }
        if (self.bold and self.italic) return "\\f(BI";
        if (self.bold) return "\\fB";
        if (self.italic) return "\\fI";
        return "\\fR";
    }
};

const Gen = struct {
    a: Allocator,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    depth: u32 = 0,
    /// The output is at the start of a line.
    bol: bool = true,

    fn enter(self: *Gen) Error!void {
        if (self.depth >= max_depth) return error.TooDeep;
        self.depth += 1;
    }

    // ---- output helpers ----------------------------------------------------

    fn raw(self: *Gen, s: []const u8) Allocator.Error!void {
        if (s.len == 0) return;
        try self.out.appendSlice(self.a, s);
        self.bol = s[s.len - 1] == '\n';
    }

    fn nl(self: *Gen) Allocator.Error!void {
        if (!self.bol) try self.raw("\n");
    }

    /// A request line, e.g. `.PP` or `.IP "x" 4`.
    fn req(self: *Gen, s: []const u8) Allocator.Error!void {
        try self.nl();
        try self.raw(s);
        try self.raw("\n");
    }

    // ---- blocks ------------------------------------------------------------

    fn document(self: *Gen, root: *Node) Error!void {
        var title = self.opts.title;
        var section = self.opts.section;
        // Comments before the first block (a copyright note) stay above `.TH`.
        var start = root.first_child;
        while (start) |c| : (start = c.next) {
            if (c.kind != .html_block) break;
            try self.comment(c.literal);
        }
        // A level-1 heading `name(section)` is the page title.
        if (start) |f| if (f.kind == .heading and f.level == 1) {
            const t = try self.plain(f);
            if (std.mem.lastIndexOfScalar(u8, t, '(')) |lp| {
                if (t.len > lp + 2 and t[t.len - 1] == ')') {
                    title = t[0..lp];
                    section = t[lp + 1 .. t.len - 1];
                }
            } else if (t.len != 0) title = t;
            start = f.next;
        };
        try self.nl();
        try self.raw(".TH ");
        try self.quoted(title);
        try self.raw(" ");
        try self.quoted(section);
        if (self.opts.date.len != 0 or self.opts.source.len != 0 or self.opts.manual.len != 0) {
            try self.raw(" ");
            try self.quoted(self.opts.date);
            try self.raw(" ");
            try self.quoted(self.opts.source);
            try self.raw(" ");
            try self.quoted(self.opts.manual);
        }
        try self.raw("\n");
        try self.blocksFrom(start, false);
    }

    /// Writes `s` as one quoted macro argument.
    fn quoted(self: *Gen, s: []const u8) Allocator.Error!void {
        try self.raw("\"");
        var buf: std.ArrayList(u8) = .empty;
        for (s) |c| {
            switch (c) {
                '"' => try buf.appendSlice(self.a, "\"\""),
                '\\' => try buf.appendSlice(self.a, "\\e"),
                '-' => try buf.appendSlice(self.a, "\\-"),
                else => try buf.append(self.a, c),
            }
        }
        try self.raw(buf.items);
        try self.raw("\"");
    }

    /// Children of `parent` as blocks. With `in_item` the first paragraph
    /// continues the text of the `.IP`/`.TP` line before it.
    fn blocks(self: *Gen, parent: *Node, skip: ?*Node, in_item: bool) Error!void {
        _ = skip;
        return self.blocksFrom(parent.first_child, in_item);
    }

    fn blocksFrom(self: *Gen, start: ?*Node, in_item: bool) Error!void {
        try self.enter();
        defer self.depth -= 1;
        var first = true;
        var child = start;
        while (child) |c| : (child = c.next) {
            try self.block(c, in_item, first);
            first = false;
        }
    }

    /// The macro that starts a paragraph-level block: nothing for the first
    /// block of an item, `.IP` (same indent) for the later ones, `.PP` elsewhere.
    fn lead(self: *Gen, in_item: bool, first: bool) Allocator.Error!void {
        if (in_item) {
            if (!first) try self.req(".IP");
        } else try self.req(".PP");
    }

    fn block(self: *Gen, n: *Node, in_item: bool, first: bool) Error!void {
        switch (n.kind) {
            .paragraph => {
                try self.lead(in_item, first);
                try self.inlines(n, .{}, false);
                try self.nl();
            },
            .heading => {
                try self.nl();
                try self.raw(if (n.level <= 2) ".SH " else ".SS ");
                try self.quoted(try self.plain(n));
                try self.raw("\n");
            },
            .code_block => {
                try self.lead(in_item, first);
                try self.req(".nf");
                var lines = std.mem.splitScalar(u8, n.literal, '\n');
                while (lines.next()) |l| {
                    if (lines.peek() == null and l.len == 0) break;
                    try self.textLine(l);
                    try self.raw("\n");
                }
                try self.req(".fi");
            },
            .thematic_break => {
                try self.lead(in_item, first);
                try self.req("\\(em\\(em\\(em");
            },
            .block_quote => {
                if (self.transparent(n)) return self.blocks(n, null, false);
                const width: u16 = if (n.indent != 0 and n.indent != Node.flush) n.indent else 4;
                try self.req(try std.fmt.allocPrint(self.a, ".RS {d}", .{width}));
                try self.blocks(n, null, false);
                try self.req(".RE");
            },
            .list => try self.list(n, in_item),
            .deflist => try self.deflist(n),
            .table => try self.table(n, in_item, first),
            .html_block => try self.comment(n.literal),
            .front_matter => {
                var lines = std.mem.splitScalar(u8, n.literal, '\n');
                try self.req(".\\\" ---");
                while (lines.next()) |l| {
                    if (lines.peek() == null and l.len == 0) break;
                    try self.nl();
                    try self.raw(".\\\" ");
                    try self.raw(l);
                    try self.raw("\n");
                }
                try self.req(".\\\" ---");
            },
            .footnote_def => {
                try self.lead(in_item, first);
                try self.raw(try std.fmt.allocPrint(self.a, "[{s}] ", .{n.literal}));
                try self.blocks(n, null, true);
            },
            else => {},
        }
    }

    /// A quote that only carries the indent of a section body in a tree read
    /// from a man page: it follows a heading, or holds one.
    fn transparent(self: *Gen, n: *Node) bool {
        _ = self;
        if (n.indent == 0) return false;
        if (n.prev) |p| if (p.kind == .heading) return true;
        if (n.first_child) |f| if (f.kind == .heading) return true;
        return false;
    }

    /// An HTML comment as `.\"` lines; other raw HTML is dropped.
    fn comment(self: *Gen, html: []const u8) Allocator.Error!void {
        const t = std.mem.trim(u8, html, " \t\r\n");
        if (!std.mem.startsWith(u8, t, "<!--") or !std.mem.endsWith(u8, t, "-->") or t.len < 7) return;
        var body = t[4 .. t.len - 3];
        if (body.len != 0 and body[0] == ' ') body = body[1..];
        if (body.len != 0 and body[body.len - 1] == ' ') body = body[0 .. body.len - 1];
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |l| {
            try self.nl();
            try self.raw(".\\\"");
            if (l.len != 0) {
                try self.raw(" ");
                try self.raw(std.mem.trimEnd(u8, l, "\r"));
            }
            try self.raw("\n");
        }
    }

    fn list(self: *Gen, n: *Node, in_item: bool) Error!void {
        // A list inside an item is set in from the item's text.
        if (in_item) try self.req(".RS 2");
        var number = n.list.start;
        var item = n.first_child;
        while (item) |it| : (item = it.next) {
            if (n.list.kind == .bullet) {
                try self.req(".IP \\(bu 2");
            } else {
                try self.req(try std.fmt.allocPrint(self.a, ".IP \"{d}{c}\" 4", .{ number, if (n.list.delimiter == ')') @as(u8, ')') else '.' }));
                number +%= 1;
            }
            if (it.task != .none) try self.raw(if (it.task == .checked) "[x] " else "[ ] ");
            try self.blocks(it, null, true);
        }
        if (in_item) try self.req(".RE");
    }

    fn deflist(self: *Gen, n: *Node) Error!void {
        var prev_term = false;
        var child = n.first_child;
        while (child) |c| : (child = c.next) {
            if (c.kind == .deflist_term) {
                try self.req(if (prev_term) ".TQ" else ".TP");
                try self.inlines(c, .{}, false);
                try self.nl();
                prev_term = true;
            } else {
                prev_term = false;
                try self.blocks(c, null, true);
            }
        }
    }

    fn table(self: *Gen, n: *Node, in_item: bool, first: bool) Error!void {
        try self.lead(in_item, first);
        const head = n.first_child orelse return;
        var cols: std.ArrayList(u8) = .empty;
        var hdr: std.ArrayList(u8) = .empty;
        var c = head.first_child;
        while (c) |cell| : (c = cell.next) {
            const ch: u8 = switch (cell.align_) {
                .none, .left => 'l',
                .center => 'c',
                .right => 'r',
            };
            if (cols.items.len != 0) {
                try cols.append(self.a, ' ');
                try hdr.append(self.a, ' ');
            }
            try cols.append(self.a, ch);
            try hdr.append(self.a, ch);
            try hdr.append(self.a, 'b');
        }
        try self.req(".TS");
        try self.req("allbox tab(\\t);");
        try self.req(hdr.items);
        try self.req(try std.fmt.allocPrint(self.a, "{s}.", .{cols.items}));
        var row = n.first_child;
        while (row) |r| : (row = r.next) {
            try self.nl();
            var cell = r.first_child;
            while (cell) |cl| : (cell = cl.next) {
                if (cl.prev != null) try self.raw("\t");
                try self.raw(try self.plainEsc(cl));
            }
            try self.raw("\n");
        }
        try self.req(".TE");
    }

    // ---- inlines -----------------------------------------------------------

    /// One line of preformatted text: escaped, with a leading `.` or `'` protected.
    fn textLine(self: *Gen, l: []const u8) Allocator.Error!void {
        try self.text(l, true);
    }

    /// Escapes `s` for roff. At the start of a line a `.` or `'` is protected
    /// with `\&` so it is not read as a request.
    fn text(self: *Gen, s: []const u8, protect_first: bool) Allocator.Error!void {
        var buf: std.ArrayList(u8) = .empty;
        var at_start = protect_first or self.bol;
        for (s) |c| {
            switch (c) {
                '\\' => try buf.appendSlice(self.a, "\\e"),
                '-' => try buf.appendSlice(self.a, "\\-"),
                '.', '\'' => {
                    if (at_start) try buf.appendSlice(self.a, "\\&");
                    try buf.append(self.a, c);
                },
                else => try buf.append(self.a, c),
            }
            at_start = false;
        }
        try self.raw(buf.items);
    }

    /// The text of an inline container without any markup (for headings).
    fn plain(self: *Gen, n: *Node) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var w = md.Walker.init(n);
        while (w.next()) |ev| {
            if (!ev.entering) continue;
            switch (ev.node.kind) {
                .text, .code => try out.appendSlice(self.a, ev.node.literal),
                .softbreak, .linebreak => try out.append(self.a, ' '),
                else => {},
            }
        }
        return out.items;
    }

    /// `plain`, escaped for use inside a tbl cell.
    fn plainEsc(self: *Gen, n: *Node) Error![]const u8 {
        const p = try self.plain(n);
        var out: std.ArrayList(u8) = .empty;
        for (p) |c| {
            switch (c) {
                '\\' => try out.appendSlice(self.a, "\\e"),
                '-' => try out.appendSlice(self.a, "\\-"),
                else => try out.append(self.a, c),
            }
        }
        return out.items;
    }

    fn inlines(self: *Gen, parent: *Node, font: Font, _: bool) Error!void {
        try self.enter();
        defer self.depth -= 1;
        var skip_prefix: usize = 0;
        var child = parent.first_child;
        while (child) |c| : (child = c.next) {
            switch (c.kind) {
                .text => {
                    try self.text(c.literal[skip_prefix..], self.bol);
                    skip_prefix = 0;
                },
                .code => try self.fonted(font, .{ .bold = font.bold, .italic = font.italic, .mono = true }, c, true),
                .emph => try self.fonted(font, .{ .bold = font.bold, .italic = true, .mono = font.mono }, c, false),
                .strong => try self.fonted(font, .{ .bold = true, .italic = font.italic, .mono = font.mono }, c, false),
                .strikethrough => try self.inlines(c, font, false),
                .softbreak => try self.nl(),
                .linebreak => {
                    try self.nl();
                    try self.raw(".br\n");
                },
                .html_inline => {
                    if (std.mem.startsWith(u8, c.literal, "<!--")) {
                        try self.nl();
                        try self.comment(c.literal);
                    }
                },
                .link => skip_prefix = try self.link(c, font),
                .image => try self.inlines(c, font, false),
                .footnote_ref => try self.raw(try std.fmt.allocPrint(self.a, "[{s}]", .{c.literal})),
                else => {},
            }
        }
    }

    /// Writes `c` in font `to`, then switches back to `from`.
    fn fonted(self: *Gen, from: Font, to: Font, c: *Node, literal: bool) Error!void {
        if (!to.eql(from)) try self.raw(to.esc());
        if (literal) {
            try self.text(c.literal, self.bol);
        } else try self.inlines(c, to, false);
        if (!to.eql(from)) try self.raw(from.esc());
    }

    /// `.UR url`, the text, `.UE`. Punctuation that follows the link goes into
    /// the `.UE` line so no space appears before it; returns how many bytes of
    /// the next text node that took.
    fn link(self: *Gen, c: *Node, font: Font) Error!usize {
        // Without a break in the text, a `\c` joins the preceding word.
        if (!self.bol and self.out.items.len != 0) {
            if (self.out.items[self.out.items.len - 1] == ' ') {
                // The line break supplies the space.
                self.out.items.len -= 1;
            } else try self.raw("\\c");
        }
        try self.nl();
        try self.raw(".UR ");
        try self.destArg(c.literal);
        try self.raw("\n");
        try self.inlines(c, font, false);
        try self.nl();
        var used: usize = 0;
        var punct: []const u8 = "";
        if (c.next) |nx| if (nx.kind == .text) {
            while (used < nx.literal.len and std.mem.findScalar(u8, ".,;:!?)", nx.literal[used]) != null) used += 1;
            punct = nx.literal[0..used];
        };
        try self.raw(".UE");
        if (punct.len != 0) {
            try self.raw(" ");
            try self.raw(punct); // only . , ; : ! ? ): safe unquoted
        }
        try self.raw("\n");
        return used;
    }

    fn destArg(self: *Gen, dest: []const u8) Allocator.Error!void {
        var needs_quote = dest.len == 0;
        for (dest) |ch| if (ch == ' ' or ch == '"' or ch == '\t') {
            needs_quote = true;
        };
        if (needs_quote) return self.quoted(dest);
        var buf: std.ArrayList(u8) = .empty;
        for (dest) |ch| {
            if (ch == '\\') try buf.appendSlice(self.a, "\\e") else try buf.append(self.a, ch);
        }
        try self.raw(buf.items);
    }
};
