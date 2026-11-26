//! Reader for man(7) pages. Builds an md-zig tree:
//!
//!   .TH            heading level 1        .SH / .SS     heading level 2 / 3
//!   .PP .P .LP     paragraph              .TP / .IP     definition list or bullet list
//!   .RS / .RE      block quote            .nf .fi .EX   code block
//!   .B .I .BR ...  strong / emphasis      .UR .MT       links
//!
//! User macros (`.de`) are run. What roff can express and the tree cannot (exact
//! indents, tabs, tbl layout) is approximated or dropped, and expansion, nesting
//! and table sizes are limited; see docs/architecture.md.

const std = @import("std");
const md = @import("md");
const Allocator = std.mem.Allocator;
const Node = md.Node;
const escape = @import("escape.zig");
const expr = @import("expr.zig");
const Font = escape.Font;

/// Deepest `.RS` nesting followed; more is ignored.
const max_levels = 16;

/// Deepest nesting of `.ie` blocks waiting for their `.el`.
pub const max_ie_depth = 32;
/// Deepest chain of conditionals on one line (`.if n .if n ...`).
pub const max_cond_depth = 32;

/// Most cells in a table row; further ones are joined into the last.
pub const max_columns = 64;
/// Most empty cells added in one page to make short rows as wide as the
/// widest. Without a limit the tree grows as rows times columns.
pub const max_padded_cells = 1 << 16;

pub const Definition = struct {
    name: []const u8,
    append: bool,
    end: []const u8,
    lines: std.ArrayList([]const u8) = .empty,
};

/// Deepest nesting of user macro calls followed.
pub const max_macro_depth = 16;
/// Most lines all macro calls of one page may run. The depth limit alone does
/// not bound the work: a macro that calls itself eight times makes 8^16 calls.
pub const max_expanded_lines = 100_000;
/// Most bytes those lines may have after their arguments are filled in.
pub const max_expanded_bytes = 4 << 20;

/// True when `l` ends a macro definition or `.ig` block. The end is `..` or
/// `.NAME`, and blanks are allowed after the first dot (Asciidoctor writes `.  .`).
pub fn endsDefinition(l: []const u8, end: []const u8) bool {
    if (l.len == 0 or l[0] != '.') return false;
    const after = std.mem.trimStart(u8, l[1..], " \t");
    const name = end[1..];
    if (!std.mem.startsWith(u8, after, name)) return false;
    // The whole name: `.Zfoo` does not end a definition that waits for `.Z`.
    const tail = after[name.len..];
    return tail.len == 0 or tail[0] == ' ' or tail[0] == '\t' or tail[0] == '\\' or std.mem.eql(u8, end, "..");
}

/// Copy mode: `\\` becomes `\`, so a body written as `\\$1` ends up as `\$1`.
pub fn copyMode(a: Allocator, l: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, l, "\\\\") == null) return l;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        if (l[i] == '\\' and i + 1 < l.len and l[i + 1] == '\\') i += 1;
        try out.append(a, l[i]);
    }
    return out.items;
}

/// Replaces `\$1` ... `\$9`, `\$*` and `\$#` by the macro's arguments.
/// Null when the result would be longer than `limit`.
pub fn substArgs(a: Allocator, l: []const u8, args: []const []const u8, limit: usize) Allocator.Error!?[]const u8 {
    if (l.len > limit) return null;
    if (std.mem.indexOf(u8, l, "\\$") == null) return l;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        if (out.items.len > limit) return null;
        if (l[i] == '\\' and i + 2 < l.len and l[i + 1] == '$') {
            const c = l[i + 2];
            if (c >= '1' and c <= '9') {
                const n = c - '1';
                if (n < args.len) try out.appendSlice(a, args[n]);
                i += 2;
                continue;
            }
            if (c == '*' or c == '@') {
                for (args, 0..) |arg, k| {
                    if (out.items.len > limit) return null;
                    if (k > 0) try out.append(a, ' ');
                    if (c == '*') {
                        try out.appendSlice(a, arg);
                        continue;
                    }
                    // `\\$@` quotes each argument, so it stays one.
                    try out.append(a, '"');
                    for (arg) |ch| {
                        if (ch == '"') try out.append(a, '"');
                        try out.append(a, ch);
                    }
                    try out.append(a, '"');
                }
                i += 2;
                continue;
            }
            if (c == '#') {
                try out.print(a, "{d}", .{args.len});
                i += 2;
                continue;
            }
        }
        try out.append(a, l[i]);
    }
    if (out.items.len > limit) return null;
    return out.items;
}

/// The body of a user macro: one run of lines from its `.de` and one more from
/// each `.am`, so appending does not copy what is already there.
pub const Macro = struct {
    chunks: std.ArrayList([]const []const u8) = .empty,
};

/// Indent of tagged paragraphs until one gives another.
const default_indent: u16 = 7;

/// Fills a table cell from one input line, on behalf of another reader.
pub const CellLines = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, table: *Parser, cell: *Node, line: []const u8) Allocator.Error!void,
};

pub const Parser = struct {
    a: Allocator,
    root: *Node,
    st: escape.State = .{},

    /// Where blocks of the current indentation level go.
    container: *Node,
    /// Where paragraphs go now: `container`, or a definition inside it.
    cur: *Node,
    levels: [max_levels]*Node = undefined,
    depth: usize = 0,
    /// `.RS` requests refused at the depth limit, whose `.RE` is ignored too.
    refused: usize = 0,

    para: ?*Node = null,
    open_dl: ?*Node = null,
    open_list: ?*Node = null,
    /// The next text line (or font macro) fills this node instead of a paragraph.
    pending_term: ?*Node = null,
    pending_heading: ?*Node = null,
    /// Link opened by `.UR`/`.MT` that receives inlines until `.UE`/`.ME`.
    link: ?*Node = null,
    one_shot: ?Font = null,

    nofill: bool = false,
    code: std.ArrayList(u8) = .empty,
    /// Address of a `.UR`/`.MT` opened in a no-fill block.
    code_link: ?[]const u8 = null,
    in_tbl: bool = false,
    /// Between `T{` and `T}` in a table.
    tbl_text_block: bool = false,
    tbl_lines: std.ArrayList([]const u8) = .empty,
    /// While skipping an `.ig` block: the line that ends it.
    skip_end: ?[]const u8 = null,
    /// User-defined macros (`.de`): name to body lines, in copy mode.
    macros: std.StringHashMapUnmanaged(*Macro) = .empty,
    /// The macro being defined, until its end line.
    def: ?Definition = null,
    macro_depth: usize = 0,
    expanded_lines: usize = 0,
    padded_cells: usize = 0,
    /// Set when another reader owns the page: it runs the lines that fill a
    /// table cell, since they may use its macros.
    cell_lines: ?CellLines = null,
    expanded_bytes: usize = 0,
    skip_depth: usize = 0,
    /// Results of the `.ie` requests that still wait for their `.el`.
    ie_results: [max_ie_depth]bool = undefined,
    ie_count: usize = 0,
    cond_depth: usize = 0,
    /// Indent (columns) used by `.TP`, `.IP` and `.RS` when they give none.
    indent: u16 = default_indent,
    continued: bool = false,
    line_no: u32 = 0,
    /// Keep `.\"` comment lines as HTML comments in the tree.
    keep_comments: bool = false,
    /// Comments waiting for a place: they stood in a heading, term, link or
    /// no-fill block.
    deferred: std.ArrayList(*Node) = .empty,

    fn node(self: *Parser, kind: md.Kind) Allocator.Error!*Node {
        const n = try self.a.create(Node);
        n.* = .{ .kind = kind, .line = self.line_no };
        n.build.open = false;
        return n;
    }

    // ---- blocks ------------------------------------------------------------

    fn endPara(self: *Parser) void {
        self.para = null;
        self.continued = false;
    }

    /// Back to the level's container: no open definition or list.
    fn endGroup(self: *Parser) Allocator.Error!void {
        // Buffered code belongs here, before whatever comes next.
        try self.flushCode();
        self.endPara();
        self.open_dl = null;
        self.open_list = null;
        self.pending_term = null;
        self.cur = self.container;
        self.link = null;
    }

    fn flushCode(self: *Parser) Allocator.Error!void {
        if (self.code.items.len == 0) return;
        const b = try self.node(.code_block);
        b.literal = try self.a.dupe(u8, self.code.items);
        b.indent = Node.flush;
        self.cur.appendChild(b);
        self.code.clearRetainingCapacity();
        self.placeComments();
    }

    fn placeComments(self: *Parser) void {
        for (self.deferred.items) |n| self.cur.appendChild(n);
        self.deferred.clearRetainingCapacity();
    }

    /// Where inline content goes now.
    fn sink(self: *Parser) Allocator.Error!*Node {
        // An open link first: it may be inside the heading or term.
        if (self.link) |l| return l;
        if (self.pending_heading) |h| return h;
        if (self.pending_term) |t| return t;
        if (self.para) |p| return p;
        try self.flushCode();
        const p = try self.node(.paragraph);
        self.cur.appendChild(p);
        self.para = p;
        return p;
    }

    /// After the text for a pending heading or term: go on with normal flow.
    fn contentDone(self: *Parser) void {
        // An open link or a `\\c` means the heading or term goes on.
        if (self.link != null or self.continued) return;
        if (self.pending_heading != null) self.pending_heading = null;
        if (self.pending_term != null) self.pending_term = null;
        self.placeComments();
    }

    /// Body text of a section is indented by this many columns, a subsection
    /// heading by `sub_indent` (as groff's man macros do on a terminal).
    const body_indent: u16 = 7;
    const sub_indent: u16 = 3;

    fn heading(self: *Parser, level: u8, args: []const []const u8) Allocator.Error!void {
        try self.endGroup();
        self.nofill = false;
        self.code_link = null;
        if (self.pending_heading) |h| {
            // A heading whose text never came is dropped, with its empty body.
            self.pending_heading = null;
            if (h.first_child == null and self.container.first_child == null) {
                const outer = if (h.level == 3) h.parent.? else self.container;
                if (h.level != 3) h.unlink();
                outer.unlink();
            }
        }
        self.depth = 0;
        self.refused = 0;
        self.indent = default_indent;
        self.one_shot = null;
        const h = try self.node(.heading);
        h.level = level;
        // `.SH` heading at the left edge, its body in a quote indented 7;
        // `.SS` heading in a quote indented 3 whose body quote adds 4 more.
        const body = try self.node(.block_quote);
        if (level == 3) {
            const head_quote = try self.node(.block_quote);
            head_quote.indent = sub_indent;
            self.root.appendChild(head_quote);
            head_quote.appendChild(h);
            body.indent = body_indent - sub_indent;
            head_quote.appendChild(body);
        } else {
            self.root.appendChild(h);
            body.indent = body_indent;
            self.root.appendChild(body);
        }
        self.container = body;
        self.cur = body;
        if (args.len == 0) {
            self.pending_heading = h;
            return;
        }
        const joined = try std.mem.join(self.a, " ", args);
        try self.addText(h, joined, true);
    }

    /// Starts a definition list entry whose term is `tag` (or filled by the
    /// next line when null).
    fn startTagged(self: *Parser, tag: ?[]const u8, width: ?[]const u8) Allocator.Error!void {
        if (width) |w| if (escape.columns(w)) |c| {
            self.indent = c;
        };
        try self.flushCode();
        self.endPara();
        self.link = null;
        self.open_list = null;
        const dl = self.open_dl orelse blk: {
            const d = try self.node(.deflist);
            d.list.tight = false;
            self.container.appendChild(d);
            self.open_dl = d;
            break :blk d;
        };
        const term = try self.node(.deflist_term);
        const def = try self.node(.deflist_def);
        def.indent = self.indent;
        dl.appendChild(term);
        dl.appendChild(def);
        self.cur = def;
        if (tag) |t| {
            try self.addText(term, t, true);
        } else self.pending_term = term;
    }

    fn startBullet(self: *Parser) Allocator.Error!void {
        try self.flushCode();
        self.endPara();
        self.open_dl = null;
        const list = self.open_list orelse blk: {
            const l = try self.node(.list);
            l.list = .{ .kind = .bullet, .tight = true, .bullet_char = '*' };
            self.container.appendChild(l);
            self.open_list = l;
            break :blk l;
        };
        const item = try self.node(.item);
        list.appendChild(item);
        self.cur = item;
    }

    fn isBullet(tag: []const u8) bool {
        return std.mem.eql(u8, tag, "\\(bu") or std.mem.eql(u8, tag, "\\[bu]") or std.mem.eql(u8, tag, "\u{2022}") or
            std.mem.eql(u8, tag, "*") or std.mem.eql(u8, tag, "-") or std.mem.eql(u8, tag, "\\-") or std.mem.eql(u8, tag, "o");
    }

    fn pushQuote(self: *Parser, width: ?[]const u8) Allocator.Error!void {
        try self.endGroup();
        if (self.depth >= max_levels) {
            self.refused += 1;
            return;
        }
        const cols: u16 = if (width) |w| (escape.columns(w) orelse self.indent) else self.indent;
        self.levels[self.depth] = self.container;
        self.depth += 1;
        // `.RS 0` indents nothing, but still pairs with its `.RE`.
        if (cols == 0) return;
        const q = try self.node(.block_quote);
        q.indent = cols;
        self.container.appendChild(q);
        self.container = q;
        self.cur = q;
    }

    fn popQuote(self: *Parser) Allocator.Error!void {
        try self.endGroup();
        if (self.refused > 0) {
            self.refused -= 1;
            return;
        }
        if (self.depth == 0) return;
        self.depth -= 1;
        self.container = self.levels[self.depth];
        self.cur = self.container;
    }

    // ---- inlines -----------------------------------------------------------

    /// Appends `s` (with escapes) to `parent`. `fresh` ignores and resets the
    /// font state: used by macros that set their own font.
    fn addText(self: *Parser, parent: *Node, s: []const u8, fresh: bool) Allocator.Error!void {
        const saved = self.st;
        if (fresh) {
            self.st.font = .roman;
            self.st.prev = .roman;
        }
        const r = try escape.segments(self.a, &self.st, s);
        if (fresh) {
            self.st.font = saved.font;
            self.st.prev = saved.prev;
        }
        for (r.segments) |seg| try self.addRun(parent, seg.text, seg.font);
        self.continued = r.continued;
    }

    /// Appends `s` (with escapes), starting in `font`.
    fn addStyled(self: *Parser, parent: *Node, s: []const u8, font: Font) Allocator.Error!void {
        const saved_font = self.st.font;
        const saved_prev = self.st.prev;
        self.st.font = font;
        self.st.prev = font;
        try self.addText(parent, s, false);
        self.st.font = saved_font;
        self.st.prev = saved_prev;
    }

    /// A link address with its escapes (`\\-`, `\\:`, `\\%`) read.
    fn address(self: *Parser, s: []const u8) Allocator.Error![]const u8 {
        const font = self.st.font;
        const prev = self.st.prev;
        defer {
            self.st.font = font;
            self.st.prev = prev;
        }
        return escape.plain(self.a, &self.st, s);
    }

    fn addRun(self: *Parser, parent: *Node, text: []const u8, font: Font) Allocator.Error!void {
        var inner = try self.node(if (font.mono) .code else .text);
        inner.literal = try self.a.dupe(u8, text);
        if (font.italic and !font.mono) {
            const e = try self.node(.emph);
            e.appendChild(inner);
            inner = e;
        }
        if (font.bold and !font.mono) {
            const s = try self.node(.strong);
            s.appendChild(inner);
            inner = s;
        }
        parent.appendChild(inner);
    }

    /// A line break between two input lines of one paragraph.
    fn lineSep(self: *Parser, parent: *Node) Allocator.Error!void {
        if (self.continued) {
            self.continued = false;
            return;
        }
        if (parent.last_child) |last| {
            if (last.kind != .softbreak and last.kind != .linebreak) parent.appendChild(try self.node(.softbreak));
        }
    }

    fn textLine(self: *Parser, l: []const u8) Allocator.Error!void {
        if (std.mem.trim(u8, l, " \t").len == 0) {
            // A blank line ends the paragraph (roff treats it like .sp).
            self.endPara();
            return;
        }
        const target = try self.sink();
        const was_term = self.pending_term != null or self.pending_heading != null;
        try self.lineSep(target);
        if (self.one_shot) |f| {
            self.one_shot = null;
            self.st.setFont(f);
            try self.addText(target, l, false);
            self.st.setFont(.roman);
        } else try self.addText(target, l, false);
        if (was_term) self.contentDone();
    }

    /// `.B`, `.I`, `.SM`: all arguments, one font, separated by spaces.
    fn singleFont(self: *Parser, font: Font, args: []const []const u8) Allocator.Error!void {
        if (args.len == 0) {
            self.one_shot = font;
            return;
        }
        // This is the "next line" an earlier bare font macro waited for.
        self.one_shot = null;
        const target = try self.sink();
        const was_term = self.pending_term != null or self.pending_heading != null;
        try self.lineSep(target);
        const joined = try std.mem.join(self.a, " ", args);
        self.st.setFont(font);
        try self.addText(target, joined, false);
        self.st.font = .roman;
        self.st.prev = .roman;
        if (was_term) self.contentDone();
    }

    /// `.BR`, `.IB`, ...: arguments alternate between two fonts, no spaces.
    fn alternating(self: *Parser, f0: Font, f1: Font, args: []const []const u8) Allocator.Error!void {
        self.one_shot = null;
        const target = try self.sink();
        const was_term = self.pending_term != null or self.pending_heading != null;
        try self.lineSep(target);
        for (args, 0..) |arg, idx| {
            self.st.setFont(if (idx % 2 == 0) f0 else f1);
            try self.addText(target, arg, false);
        }
        self.st.font = .roman;
        self.st.prev = .roman;
        if (was_term) self.contentDone();
    }

    // ---- requests ----------------------------------------------------------

    const Request = enum {
        TH,
        SH,
        SS,
        PP,
        P,
        LP,
        HP,
        TP,
        TQ,
        IP,
        RS,
        RE,
        B,
        I,
        SM,
        SB,
        BR,
        BI,
        IB,
        RB,
        IR,
        RI,
        br,
        sp,
        nf,
        fi,
        EX,
        EE,
        TS,
        TE,
        UR,
        UE,
        MT,
        ME,
        SY,
        OP,
        YS,
        ds,
        de,
        am,
        ig,
        de1,
        am1,
        dei,
        ami,
        dei1,
        ami1,
        @"if",
        ie,
        el,
        so,
        nr,
        rr,
        ft,
        ce,
        ta,
        ne,
        ad,
        na,
        hy,
        nh,
        in,
        ti,
        ll,
        lt,
        pl,
        po,
        ps,
        vs,
        ss,
        fc,
        cc,
        c2,
        mk,
        rt,
        bp,
        pn,
        nx,
        rm,
        rn,
    };

    fn request(self: *Parser, l: []const u8) Allocator.Error!void {
        const body = stripComment(std.mem.trimStart(u8, l, " \t"));
        if (body.len == 0) return;
        var name_end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        // `.el\\{` and `.ie\\n(...` need no blank after the name.
        for ([_][]const u8{ "if\\", "ie\\", "el\\" }) |start| {
            if (std.mem.startsWith(u8, body, start)) name_end = 2;
        }
        const name = body[0..name_end];
        const rest = std.mem.trimStart(u8, body[name_end..], " \t");

        // Names that are not built in may be user macros; anything else is ignored.
        const req = std.meta.stringToEnum(Request, name) orelse return self.callMacro(name, try splitArgs(self.a, rest));
        // A conditional's body is a line of its own: splitting it into arguments
        // at every level of a chain would take quadratic memory.
        const args: []const []const u8 = switch (req) {
            .@"if", .ie, .el => &.{},
            // troff reads the strings before it splits the arguments, and some
            // pages build the whole title line in one.
            .TH => try splitArgs(self.a, try escape.pasteStrings(self.a, &self.st, rest, 0)),
            else => try splitArgs(self.a, rest),
        };

        if (self.nofill) {
            switch (req) {
                .fi, .EE, .RE, .TS => {},
                .B, .I, .SM, .SB, .BR, .BI, .IB, .RB, .IR, .RI => {
                    // Font macros inside a code block: keep the text.
                    // .B .I .SM .SB separate their arguments with spaces; the
                    // alternating macros (.BR, .BI, ...) do not.
                    const spaced = req == .B or req == .I or req == .SM or req == .SB;
                    // With nothing to print, the next line is the text.
                    if (args.len == 0) return;
                    for (args, 0..) |arg, k| {
                        if (k > 0 and spaced) try self.code.append(self.a, ' ');
                        try self.code.appendSlice(self.a, try escape.plain(self.a, &self.st, arg));
                    }
                    try self.code.append(self.a, '\n');
                    return;
                },
                .sp => {
                    try self.code.append(self.a, '\n');
                    return;
                },
                .br => return,
                else => {},
            }
        }

        switch (req) {
            .TH => {
                try self.endGroup();
                const h = try self.node(.heading);
                h.level = 1;
                self.root.appendChild(h);
                const title = if (args.len > 0) args[0] else "";
                const section = if (args.len > 1) args[1] else "";
                const text = try std.fmt.allocPrint(self.a, "{s}({s})", .{ title, section });
                try self.addText(h, text, true);
                // Date, source and manual are not shown; `writeMan` gets them
                // from the heading's title field, one per line.
                if (args.len > 2) {
                    var fields: std.ArrayList(u8) = .empty;
                    for (args[2..@min(args.len, 5)], 0..) |field, k| {
                        if (k > 0) try fields.append(self.a, '\n');
                        try fields.appendSlice(self.a, try self.address(field));
                    }
                    h.title = fields.items;
                }
            },
            .SH => try self.heading(2, args),
            .SS => try self.heading(3, args),
            .PP, .P, .LP, .HP => {
                try self.endGroup();
                self.indent = default_indent;
            },
            .TP, .TQ => try self.startTagged(null, if (args.len > 0) args[0] else null),
            .IP => {
                if (args.len == 0) {
                    // Plain indented paragraph inside the current group.
                    self.endPara();
                } else if (isBullet(args[0])) {
                    try self.startBullet();
                } else try self.startTagged(args[0], if (args.len > 1) args[1] else null);
            },
            .RS => try self.pushQuote(if (args.len > 0) args[0] else null),
            .RE => {
                // `.RE n` returns to level n; 1 is the level outside any `.RS`.
                const level = if (args.len > 0) std.fmt.parseInt(usize, args[0], 10) catch 0 else 0;
                try self.popQuote();
                if (level > 0) {
                    while (self.depth >= level) try self.popQuote();
                }
            },
            .B => try self.singleFont(Font.b, args),
            .I => try self.singleFont(Font.i, args),
            .SM => try self.singleFont(Font.roman, args),
            .SB => try self.singleFont(Font.b, args),
            .BR => try self.alternating(Font.b, Font.roman, args),
            .BI => try self.alternating(Font.b, Font.i, args),
            .IB => try self.alternating(Font.i, Font.b, args),
            .RB => try self.alternating(Font.roman, Font.b, args),
            .IR => try self.alternating(Font.i, Font.roman, args),
            .RI => try self.alternating(Font.roman, Font.i, args),
            .br => {
                if (self.para) |p| {
                    if (p.last_child != null) p.appendChild(try self.node(.linebreak));
                }
            },
            .sp, .ne, .bp => self.endPara(),
            .nf, .EX => {
                self.endPara();
                self.nofill = true;
            },
            .fi, .EE => {
                self.nofill = false;
                try self.flushCode();
            },
            .TS => {
                try self.flushCode();
                self.endPara();
                self.in_tbl = true;
                self.tbl_text_block = false;
                self.tbl_lines = .empty;
            },
            .TE => {},
            .UR, .MT => {
                if (self.nofill) {
                    // A code block holds no links: the address follows the text.
                    const dest = try self.address(if (args.len > 0) args[0] else "");
                    self.code_link = if (req == .MT) try std.fmt.allocPrint(self.a, "mailto:{s}", .{dest}) else dest;
                    return;
                }
                const target = try self.sink();
                try self.lineSep(target);
                const lnk = try self.node(.link);
                const dest = try self.address(if (args.len > 0) args[0] else "");
                lnk.literal = if (req == .MT) try std.fmt.allocPrint(self.a, "mailto:{s}", .{dest}) else dest;
                target.appendChild(lnk);
                self.link = lnk;
            },
            .UE, .ME => {
                if (self.code_link) |dest| {
                    self.code_link = null;
                    if (std.mem.endsWith(u8, self.code.items, "\n")) {
                        self.code.items.len -= 1;
                        try self.code.append(self.a, ' ');
                    }
                    const punct = try self.address(if (args.len > 0) args[0] else "");
                    try self.code.print(self.a, "<{s}>{s}\n", .{ dest, punct });
                } else if (self.link) |lnk| {
                    // A link without text shows its address.
                    if (lnk.first_child == null) try self.addRun(lnk, lnk.literal, .roman);
                    self.link = null;
                    // Trailing punctuation is the first argument.
                    const was_term = self.pending_term != null or self.pending_heading != null;
                    if (args.len > 0) try self.addText(try self.sink(), args[0], false);
                    // The link was the whole heading or term, or ended it.
                    if (was_term) {
                        self.continued = false;
                        self.contentDone();
                    }
                }
            },
            .SY => {
                self.endPara();
                const target = try self.sink();
                if (args.len > 0) try self.addStyled(target, args[0], Font.b);
            },
            .OP => {
                const target = try self.sink();
                try self.addRun(target, " [", .roman);
                if (args.len > 0) try self.addStyled(target, args[0], Font.b);
                if (args.len > 1) {
                    try self.addRun(target, " ", .roman);
                    try self.addStyled(target, args[1], Font.i);
                }
                try self.addRun(target, "]", .roman);
            },
            .YS => self.endPara(),
            .ds => try defineString(self.a, &self.st, rest),
            .de, .am, .de1, .am1, .dei, .ami, .dei1, .ami1 => {
                // `.de NAME [END]`: the body ends at `..`, or at `.END` if given.
                const end = if (args.len > 1) try std.fmt.allocPrint(self.a, ".{s}", .{args[1]}) else "..";
                if (args.len == 0) {
                    self.skip_end = end;
                } else {
                    const is_am = req == .am or req == .am1 or req == .ami or req == .ami1;
                    self.def = .{ .name = try self.a.dupe(u8, args[0]), .append = is_am, .end = end };
                }
            },
            .ig => self.skip_end = if (args.len > 0) try std.fmt.allocPrint(self.a, ".{s}", .{args[0]}) else "..",
            .@"if", .ie => try self.conditional(rest, req == .ie),
            .el => try self.elseBranch(rest),
            .nr => try setRegister(self.a, &self.st, args),
            .rr => if (args.len > 0) {
                _ = self.st.regs.remove(args[0]);
            },
            else => {}, // layout requests with no counterpart in the tree
        }
    }

    /// `.if COND body` and `.ie COND body` (see `evalCond`).
    fn conditional(self: *Parser, rest: []const u8, is_ie: bool) Allocator.Error!void {
        var s = rest;
        var negate = false;
        while (s.len > 0 and s[0] == '!') {
            negate = !negate;
            s = s[1..];
        }
        const r = try evalCond(self, s);
        const truth = r.truth != negate;
        if (is_ie) {
            // Full: forget the oldest.
            if (self.ie_count == max_ie_depth) {
                std.mem.copyForwards(bool, self.ie_results[0 .. max_ie_depth - 1], self.ie_results[1..]);
                self.ie_count -= 1;
            }
            self.ie_results[self.ie_count] = truth;
            self.ie_count += 1;
        }
        try self.branch(truth, std.mem.trimStart(u8, r.rest, " \t"));
    }

    fn elseBranch(self: *Parser, rest: []const u8) Allocator.Error!void {
        // An `.el` with no `.ie` runs its body.
        var matched = false;
        if (self.ie_count > 0) {
            self.ie_count -= 1;
            matched = self.ie_results[self.ie_count];
        }
        try self.branch(!matched, rest);
    }

    /// Runs the body of a conditional if `truth`; skips a `\{ ... \}` block otherwise.
    fn branch(self: *Parser, truth: bool, body: []const u8) Allocator.Error!void {
        if (self.cond_depth >= max_cond_depth) return;
        self.cond_depth += 1;
        defer self.cond_depth -= 1;
        if (std.mem.startsWith(u8, body, "\\{")) {
            const inner = std.mem.trimStart(u8, body[2..], " \t");
            if (truth) {
                if (inner.len > 0) try self.line(inner);
            } else {
                self.skip_depth = skipBraces(inner, 1);
            }
        } else if (truth and body.len > 0) {
            try self.line(body);
        }
    }

    // ---- lines -------------------------------------------------------------

    fn line(self: *Parser, raw: []const u8) Allocator.Error!void {
        var l = raw;
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        l = try escape.sanitize(self.a, l);

        if (self.def) |*d| {
            if (endsDefinition(l, d.end)) {
                const gop = try self.macros.getOrPut(self.a, d.name);
                if (!d.append or !gop.found_existing) {
                    gop.value_ptr.* = try self.a.create(Macro);
                    gop.value_ptr.*.* = .{};
                }
                if (d.lines.items.len > 0) try gop.value_ptr.*.chunks.append(self.a, d.lines.items);
                self.def = null;
            } else try d.lines.append(self.a, try copyMode(self.a, l));
            return;
        }
        if (self.skip_end) |end| {
            if (endsDefinition(l, end)) self.skip_end = null;
            return;
        }
        if (self.skip_depth > 0) {
            self.skip_depth = skipBraces(l, self.skip_depth);
            return;
        }
        // The end of a taken conditional block.
        // Not when the line also opens that block: `branch` needs to see both.
        if (std.mem.endsWith(u8, l, "\\}") and closesBlock(l)) l = l[0 .. l.len - 2];
        if (std.mem.eql(u8, std.mem.trim(u8, l, " \t"), ".")) return;

        if (self.keep_comments) {
            if (commentBody(l)) |t| return self.addComment(t);
        }
        if (self.in_tbl) return self.tblLine(l);
        // Control lines are requests in no-fill blocks too.
        if (l.len > 0 and (l[0] == '.' or l[0] == '\'')) return self.request(l[1..]);
        if (self.nofill) {
            try self.code.appendSlice(self.a, try escape.plain(self.a, &self.st, l));
            try self.code.append(self.a, '\n');
            return;
        }
        try self.textLine(l);
    }

    /// A whole-line comment becomes an HTML comment: inline when it sits in a
    /// paragraph, a block otherwise. One in a heading, term, link or no-fill
    /// block is placed after it.
    fn addComment(self: *Parser, text: []const u8) Allocator.Error!void {
        const later = self.pending_heading != null or self.pending_term != null or self.link != null or self.code.items.len > 0;
        const n = try self.node(if (!later and self.para != null) .html_inline else .html_block);
        n.literal = try htmlComment(self.a, text);
        if (later) return self.deferred.append(self.a, n);
        if (self.para) |p| p.appendChild(n) else self.cur.appendChild(n);
    }

    /// Runs a user macro: its body lines with the arguments filled in.
    fn callMacro(self: *Parser, name: []const u8, args: []const []const u8) Allocator.Error!void {
        const macro = self.macros.get(name) orelse return;
        if (self.macro_depth >= max_macro_depth) return;
        self.macro_depth += 1;
        defer self.macro_depth -= 1;
        const saved_args = self.st.regs.get(".$") orelse 0;
        try self.st.regs.put(self.a, ".$", @intCast(args.len));
        defer self.st.regs.put(self.a, ".$", saved_args) catch {};
        // By index: the body may append to itself while it runs, which can
        // move the list of chunks but not the lines of a chunk.
        const chunks = macro.chunks.items.len;
        for (0..chunks) |c| {
            for (macro.chunks.items[c]) |bl| {
                if (self.expanded_lines >= max_expanded_lines) return;
                self.expanded_lines += 1;
                const filled = try substArgs(self.a, bl, args, max_expanded_bytes - self.expanded_bytes) orelse {
                    self.expanded_lines = max_expanded_lines;
                    return;
                };
                self.expanded_bytes += filled.len;
                try self.line(filled);
            }
        }
    }

    /// Lines between `.TS` and `.TE` are collected; `.TE` builds the table.
    fn tblLine(self: *Parser, l: []const u8) Allocator.Error!void {
        if (std.mem.startsWith(u8, l, ".TE")) return self.endTable();
        // A section heading means the `.TE` is missing.
        if (!self.tbl_text_block and (std.mem.startsWith(u8, l, ".SH") or std.mem.startsWith(u8, l, ".SS"))) {
            try self.endTable();
            return self.request(l[1..]);
        }
        const t = std.mem.trim(u8, l, " \t");
        if (std.mem.startsWith(u8, t, "T}")) self.tbl_text_block = false;
        if (std.mem.endsWith(u8, t, "T{")) self.tbl_text_block = true;
        try self.tbl_lines.append(self.a, l);
    }

    pub fn endTable(self: *Parser) Allocator.Error!void {
        if (!self.in_tbl) return;
        self.in_tbl = false;
        try self.buildTable();
    }

    const ColSpec = struct { letter: u8 = 'l', bold: bool = false, italic: bool = false };

    /// One row format such as `lb r c w(3i)`: a column letter with its modifiers.
    fn parseFormat(self: *Parser, part: []const u8) Allocator.Error![]const ColSpec {
        var cols: std.ArrayList(ColSpec) = .empty;
        var it = std.mem.tokenizeAny(u8, part, " \t");
        while (it.next()) |tok| {
            var spec: ColSpec = .{};
            var started = false;
            var depth: usize = 0;
            for (tok) |c| {
                if (depth > 0) {
                    if (c == ')') depth -= 1;
                    continue;
                }
                switch (c) {
                    '(' => depth += 1,
                    'l', 'L', 'r', 'R', 'c', 'C', 'n', 'N', 'a', 'A', 's', 'S', '^' => if (!started) {
                        spec.letter = std.ascii.toLower(c);
                        started = true;
                    },
                    'b', 'B' => spec.bold = true,
                    'i', 'I' => spec.italic = true,
                    else => {},
                }
            }
            if (started) try cols.append(self.a, spec);
        }
        return cols.items;
    }

    /// Reads row formats from `lines[start]` to the line ending in `.`, and
    /// returns the index of the line after it.
    fn parseFormats(self: *Parser, lines: []const []const u8, start: usize, formats: *std.ArrayList([]const ColSpec)) Allocator.Error!usize {
        var i = start;
        var done = false;
        while (i < lines.len and !done) : (i += 1) {
            var fl = std.mem.trim(u8, lines[i], " \t");
            if (std.mem.endsWith(u8, fl, ".")) {
                fl = fl[0 .. fl.len - 1];
                done = true;
            }
            var parts = std.mem.splitScalar(u8, fl, ',');
            while (parts.next()) |part| {
                const f = try self.parseFormat(part);
                if (f.len > 0) try formats.append(self.a, f);
            }
        }
        return i;
    }

    /// Whether the request line (without its dot) is a font macro with
    /// arguments or a call of a user macro.
    fn printsText(self: *const Parser, request_line: []const u8) bool {
        const body = std.mem.trim(u8, stripComment(request_line), " \t");
        const end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        if (self.macros.contains(body[0..end])) return true;
        const req = std.meta.stringToEnum(Request, body[0..end]) orelse return false;
        return switch (req) {
            .B, .I, .SM, .SB, .BR, .BI, .IB, .RB, .IR, .RI => end < body.len,
            else => false,
        };
    }

    fn cellLine(self: *Parser, cell: *Node, l: []const u8) Allocator.Error!void {
        if (self.cell_lines) |other| return other.run(other.context, self, cell, l);
        try self.line(l);
    }

    /// Builds a `table` from the collected tbl(1) lines: options, row formats
    /// (up to a line ending in `.`), then rows of tab separated cells, `_` and
    /// `=` rules, and `T{ ... T}` text blocks. Boxes and rules are not drawn;
    /// the first row is a header when a rule follows it or its columns are bold.
    fn buildTable(self: *Parser) Allocator.Error!void {
        // Take the lines: the lines of a `T{` block are run like any input and
        // may start another table, which must not overwrite these.
        const lines = self.tbl_lines.items;
        self.tbl_lines = .empty;
        // The cells are filled text even inside a no-fill block.
        const nofill = self.nofill;
        self.nofill = false;
        defer self.nofill = nofill;
        var i: usize = 0;
        var tab: []const u8 = "\t";
        if (i < lines.len) {
            const t = std.mem.trim(u8, lines[i], " \t");
            if (std.mem.endsWith(u8, t, ";")) {
                if (std.mem.find(u8, t, "tab(")) |p| if (p + 4 < t.len) {
                    tab = t[p + 4 ..][0..escape.charLen(t[p + 4 ..])];
                };
                i += 1;
            }
        }

        var formats: std.ArrayList([]const ColSpec) = .empty;
        i = try self.parseFormats(lines, i, &formats);
        if (formats.items.len == 0) return;

        const tbl = try self.node(.table);
        var rows: usize = 0;
        var header_by_rule = false;
        // The formats in use, and the row they started at; `.T&` changes them.
        var active = formats.items;
        var active_from: usize = 0;
        while (i < lines.len) : (i += 1) {
            const l = lines[i];
            const t = std.mem.trim(u8, l, " \t");
            if (t.len == 0) continue;
            if (std.mem.eql(u8, t, "_") or std.mem.eql(u8, t, "=")) {
                if (rows == 1) header_by_rule = true;
                continue;
            }
            if (std.mem.startsWith(u8, t, ".T&")) {
                var changed: std.ArrayList([]const ColSpec) = .empty;
                i = try self.parseFormats(lines, i + 1, &changed) - 1;
                if (changed.items.len > 0) {
                    active = changed.items;
                    active_from = rows;
                }
                continue;
            }
            // A dot and a digit (`.5`) is data, not a request.
            if (t[0] == '.' and !(t.len > 1 and std.ascii.isDigit(t[1]))) {
                // Requests that print text make a row of their own; layout
                // requests (`.sp`, `.ne`) are skipped.
                if (self.cell_lines == null and !self.printsText(t[1..])) continue;
                const row = try self.node(.table_row);
                tbl.appendChild(row);
                const cell = try self.node(.table_cell);
                row.appendChild(cell);
                const saved_para = self.para;
                self.para = cell;
                try self.cellLine(cell, l);
                self.para = saved_para;
                if (cell.first_child == null) {
                    row.unlink();
                    continue;
                }
                rows += 1;
                continue;
            }

            const fmt = active[@min(rows - active_from, active.len - 1)];
            const row = try self.node(.table_row);
            tbl.appendChild(row);
            var col: usize = 0;
            var rest: []const u8 = l;
            while (true) : (col += 1) {
                const spec = fmt[@min(col, fmt.len - 1)];
                const cell = try self.node(.table_cell);
                cell.align_ = switch (spec.letter) {
                    'r', 'n' => .right,
                    'c' => .center,
                    else => .none,
                };
                row.appendChild(cell);

                const tab_pos = if (col + 1 < max_columns) std.mem.find(u8, rest, tab) else null;
                const piece = std.mem.trim(u8, if (tab_pos) |p| rest[0..p] else rest, " ");
                if (std.mem.endsWith(u8, piece, "T{")) {
                    // A text block runs to the line that starts with `T}`.
                    var j = i + 1;
                    const saved_para = self.para;
                    self.para = cell;
                    while (j < lines.len and !std.mem.startsWith(u8, std.mem.trim(u8, lines[j], " \t"), "T}")) : (j += 1) {
                        try self.cellLine(cell, lines[j]);
                        self.para = cell;
                    }
                    // A table opened inside the block ends with the block.
                    if (self.in_tbl) {
                        self.in_tbl = false;
                        try self.buildTable();
                    }
                    self.para = saved_para;
                    self.st.font = .roman;
                    self.st.prev = .roman;
                    if (j >= lines.len) {
                        i = j;
                        break;
                    }
                    i = j;
                    const after = std.mem.trimStart(u8, lines[j], " \t")[2..];
                    if (std.mem.startsWith(u8, after, tab)) {
                        rest = after[tab.len..];
                        continue;
                    }
                    break;
                }
                if (!(std.mem.eql(u8, piece, "\\^") or std.mem.eql(u8, piece, "_") or std.mem.eql(u8, piece, "="))) {
                    self.st.font = if (spec.bold) Font.b else if (spec.italic) Font.i else Font.roman;
                    try self.addText(cell, piece, false);
                    self.st.font = .roman;
                    self.st.prev = .roman;
                }
                if (tab_pos) |p| {
                    rest = rest[p + tab.len ..];
                } else break;
            }
            rows += 1;
        }
        if (rows == 0) return;
        // Rows can have different numbers of cells (spans, short header rows);
        // the renderer sizes the table from its first row, so pad every row.
        try padRows(self.a, tbl, &self.padded_cells);
        if (tbl.first_child) |first| {
            var bold_first = true;
            for (formats.items[0]) |c| if (!c.bold) {
                bold_first = false;
            };
            first.header = header_by_rule or (bold_first and rows > 1);
        }
        try self.endGroup();
        self.cur.appendChild(tbl);
    }
};

/// Adds empty cells until every row of `tbl` is as wide as the widest, within
/// `max_padded_cells` (`used` counts them for the page). Rows are padded in
/// order, so the first one, which sizes the rendered table, comes first.
pub fn padRows(a: Allocator, tbl: *Node, used: *usize) Allocator.Error!void {
    var widest: usize = 0;
    var r = tbl.first_child;
    while (r) |row| : (r = row.next) widest = @max(widest, countChildren(row));
    r = tbl.first_child;
    while (r) |row| : (r = row.next) {
        var n = countChildren(row);
        while (n < widest and used.* < max_padded_cells) : (n += 1) {
            const cell = try a.create(Node);
            cell.* = .{ .kind = .table_cell, .line = row.line };
            cell.build.open = false;
            row.appendChild(cell);
            used.* += 1;
        }
    }
}

fn countChildren(n: *const Node) usize {
    var count: usize = 0;
    var c = n.first_child;
    while (c) |x| : (c = x.next) count += 1;
    return count;
}

/// Follows the `\\{` and `\\}` on a skipped line, starting `open` blocks
/// deep. Returns how many are still open; 0 ends the skipping, and the rest
/// of that line is dropped with the block.
pub fn skipBraces(l: []const u8, open: usize) usize {
    var depth = open;
    var i: usize = 0;
    while (i + 1 < l.len) : (i += 1) {
        if (l[i] != '\\') continue;
        if (l[i + 1] == '{') depth += 1;
        if (l[i + 1] == '}') {
            depth -= 1;
            if (depth == 0) return 0;
        }
        i += 1; // the escaped character, which may be a backslash
    }
    return depth;
}

/// True when `l` has more `\\}` than `\\{`.
pub fn closesBlock(l: []const u8) bool {
    // Starting deep enough that the count cannot reach zero.
    return skipBraces(l, l.len + 1) < l.len + 1;
}

pub const Cond = struct { truth: bool, rest: []const u8 };

/// Evaluates the condition at the start of `s` and returns what follows it:
/// `n o` true, `t e` false; `d name`, `r name`, `c ch`; a string comparison
/// `'a'b'`; or a numeric expression (true when greater than zero).
pub fn evalCond(self: anytype, s: []const u8) Allocator.Error!Cond {
    if (s.len == 0) return .{ .truth = false, .rest = "" };
    const c = s[0];
    if (std.mem.indexOfScalar(u8, "ntoe", c) != null and (s.len == 1 or !std.ascii.isAlphanumeric(s[1]))) {
        return .{ .truth = c == 'n' or c == 'o', .rest = s[1..] };
    }
    if (std.mem.indexOfScalar(u8, "drc", c) != null and s.len > 1) {
        // `d name`, `r name` (blanks optional: `rF` is register F).
        var start: usize = 1;
        while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
        var end = start;
        while (end < s.len and s[end] != ' ' and s[end] != '\t') end += 1;
        const name = s[start..end];
        const truth = switch (c) {
            'd' => self.macros.contains(name) or self.st.strings.contains(name),
            'r' => self.st.regs.contains(name),
            else => true,
        };
        return .{ .truth = truth, .rest = s[end..] };
    }
    if (c == '\'' or c == '"') {
        // 'string1'string2' : equal after expanding strings and registers.
        const first = std.mem.indexOfScalarPos(u8, s, 1, c) orelse return .{ .truth = false, .rest = "" };
        const second = std.mem.indexOfScalarPos(u8, s, first + 1, c) orelse return .{ .truth = false, .rest = "" };
        const left = try escape.interpolate(self.a, &self.st, s[1..first]);
        const right = try escape.interpolate(self.a, &self.st, s[first + 1 .. second]);
        return .{ .truth = std.mem.eql(u8, left, right), .rest = s[second + 1 ..] };
    }
    const len = expr.tokenLen(s);
    const text = try escape.interpolate(self.a, &self.st, s[0..len]);
    const v = expr.eval(text) catch return .{ .truth = false, .rest = s[len..] };
    return .{ .truth = v > 0, .rest = s[len..] };
}

/// `.ds name value`: the value is the rest of the line as written, less one
/// leading double quote.
pub fn defineString(a: Allocator, st: *escape.State, rest: []const u8) Allocator.Error!void {
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    var value = std.mem.trimStart(u8, rest[end..], " \t");
    if (value.len > 0 and value[0] == '"') value = value[1..];
    if (end > 0) try st.strings.put(a, rest[0..end], value);
}

/// `.nr name value`: a leading `+` or `-` changes the register by that much.
pub fn setRegister(a: Allocator, st: *escape.State, args: []const []const u8) Allocator.Error!void {
    if (args.len < 2) return;
    const text = try escape.interpolate(a, st, args[1]);
    const relative = text.len > 0 and (text[0] == '+' or text[0] == '-');
    const v = expr.eval(text) catch return;
    const old = st.regs.get(args[0]) orelse 0;
    try st.regs.put(a, try a.dupe(u8, args[0]), if (relative) old +| v else v);
}

/// The text of a whole-line comment (`.\" text`, `\" text`), or null.
pub fn commentBody(l: []const u8) ?[]const u8 {
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, l, ".\\\"") or std.mem.startsWith(u8, l, "'\\\"")) {
        rest = l[3..];
    } else if (std.mem.startsWith(u8, l, "\\\"")) {
        rest = l[2..];
    } else return null;
    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    return std.mem.trimEnd(u8, rest, " \t\r");
}

/// `text` as an HTML comment; a `-->` or `--!>` inside it, either of which ends
/// an HTML comment, is broken up.
pub fn htmlComment(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "<!-- ");
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (std.mem.startsWith(u8, text[i..], "-->")) {
            try out.appendSlice(a, "-- >");
            i += 2;
        } else if (std.mem.startsWith(u8, text[i..], "--!>")) {
            try out.appendSlice(a, "--! >");
            i += 3;
        } else try out.append(a, text[i]);
    }
    try out.appendSlice(a, " -->");
    return out.items;
}

/// The line without a trailing `\"` comment (`\\` pairs are skipped).
pub fn stripComment(l: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < l.len) : (i += 1) {
        if (l[i] != '\\') continue;
        if (l[i + 1] == '"') return std.mem.trimEnd(u8, l[0..i], " \t");
        i += 1; // skip the escaped character
    }
    return l;
}

/// Splits request arguments: blanks separate them, double quotes group (a
/// doubled quote inside is a literal quote).
pub fn splitArgs(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        var arg: std.ArrayList(u8) = .empty;
        if (s[i] == '"') {
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == '"') {
                    if (i + 1 < s.len and s[i + 1] == '"') {
                        try arg.append(a, '"');
                        i += 1;
                    } else {
                        i += 1;
                        break;
                    }
                } else try arg.append(a, s[i]);
            }
        } else {
            while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {
                // An escaped blank belongs to the argument.
                if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == ' ') {
                    try arg.appendSlice(a, "\\ ");
                    i += 1;
                } else try arg.append(a, s[i]);
            }
        }
        try out.append(a, arg.items);
    }
    return out.items;
}

/// Parses a man(7) page. The tree is owned by the returned document.
pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!md.Document {
    return parseOptions(gpa, source, .{});
}

pub const Options = struct {
    /// Keep whole-line `.\"` comments as HTML comments (`<!-- text -->`) in
    /// the tree, so `writeMan` can write them back. Off by default: renderers
    /// would show them.
    keep_comments: bool = false,
};

pub fn parseOptions(gpa: Allocator, source: []const u8, options: Options) Allocator.Error!md.Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try a.create(Node);
    root.* = .{ .kind = .document, .line = 1 };
    root.build.open = false;

    var p: Parser = .{ .a = a, .root = root, .container = root, .cur = root, .st = try escape.State.init(a), .keep_comments = options.keep_comments };
    var lines = std.mem.splitScalar(u8, source, '\n');
    // Nodes carry the number of the source line being read; lines that macros
    // and conditionals run count as the line that ran them.
    var used: u32 = 0;
    while (true) {
        const start = used +| 1;
        const l = try escape.nextLogicalLine(a, &lines, &used) orelse break;
        p.line_no = start;
        try p.line(l);
    }
    try p.endTable();
    try p.flushCode();
    p.placeComments();
    return .{ .arena = arena, .root = root };
}

test "splitArgs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try splitArgs(a, "ls 1 \"June 2026\" \"say \"\"hi\"\"\"  x\\ y");
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqualStrings("June 2026", r[2]);
    try std.testing.expectEqualStrings("say \"hi\"", r[3]);
    try std.testing.expectEqualStrings("x\\ y", r[4]);
}
