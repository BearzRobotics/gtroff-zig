//! Reader for BSD mdoc(7) pages. Builds the same md-zig tree as `man.zig`.
//!
//! mdoc is a semantic macro language: `.Fl a` is "a flag", not "bold". The
//! reader keeps the parts that matter for reading a page on a terminal:
//! sections, paragraphs, lists (`.Bl`/`.It`/`.El`), displays (`.Bd`/`.Dl`),
//! the inline macros (callable macros are nested and take punctuation as
//! mdoc(7) describes), function synopses, references and the text macros
//! (`.Ex`, `.Rv`, `.St`, `.At`, `.Bx`, ...).
//!
//! Of the roff requests, `.ig`, `.de`/`.am`, `.ds`, `.nr`/`.rr`, `.if`/`.ie`/`.el`,
//! `.br`, `.sp`, `.nf`/`.fi` and `.TS` are handled.
//!
//! Not supported (silently skipped): `.Db`, `.Bk`, `-offset`, `-compact`, the
//! widths of column lists, `.Hf`, `.Tg`.

const std = @import("std");
const md = @import("md");
const Allocator = std.mem.Allocator;
const Node = md.Node;
const escape = @import("escape.zig");
const man = @import("man.zig");
const Font = escape.Font;

const max_levels = 16;
/// Deepest nesting of enclosure macros on one line; further ones are ignored.
const max_nest = 32;

const Word = struct {
    text: []const u8,
    quoted: bool = false,
    /// From a text line joined by `.Xo`: never a macro or a macro's argument.
    plain: bool = false,
};

/// Macros that can appear inside the arguments of another macro.
const Callable = enum {
    Ac,
    Ad,
    An,
    Ao,
    Ap,
    Aq,
    Ar,
    At,
    Bc,
    Bo,
    Bq,
    Brc,
    Bro,
    Brq,
    Bsx,
    Bx,
    Cd,
    Cm,
    Dc,
    Do,
    Dq,
    Dv,
    Dx,
    Ec,
    Em,
    En,
    Eo,
    Er,
    Es,
    Ev,
    Fa,
    Fc,
    Fd,
    Fl,
    Fn,
    Fo,
    Fr,
    Ft,
    Fx,
    Ic,
    In,
    Lb,
    Li,
    Lk,
    Ms,
    Mt,
    Nm,
    No,
    Ns,
    Nx,
    Ok,
    Oc,
    Oo,
    Op,
    Ot,
    Ox,
    Pa,
    Pc,
    Pf,
    Po,
    Pq,
    Qc,
    Ql,
    Qo,
    Qq,
    Sc,
    Sm,
    So,
    Sq,
    St,
    Sx,
    Sy,
    Ta,
    Tn,
    Ud,
    Ux,
    Va,
    Vt,
    Xc,
    Xo,
    Xr,
};

/// Macros that start a line and are not nested.
const Block = enum {
    Bd,
    Bf,
    Bk,
    Bl,
    Db,
    Dd,
    Dl,
    D1,
    Dt,
    Ed,
    Ef,
    Ek,
    El,
    Ex,
    Hf,
    It,
    Lp,
    Nd,
    Os,
    Pp,
    Re,
    Rs,
    Rv,
    Sh,
    Sm,
    Ss,
    Tg,
    @"%A",
    @"%B",
    @"%C",
    @"%D",
    @"%I",
    @"%J",
    @"%N",
    @"%O",
    @"%P",
    @"%Q",
    @"%R",
    @"%T",
    @"%U",
    @"%V",
};

const ListKind = enum { tag, bullet, enumerated, column };

const Ctx = struct {
    kind: ListKind,
    /// The `deflist`, `list` or `table` node.
    list: *Node,
    /// Where blocks were added before the list started.
    parent: *Node,
    item_open: bool = false,
    /// The last row of a `-column` list.
    row: ?*Node = null,
    /// Columns for the tag of a `-tag` list (`-width`).
    width: u16 = 6,
};

const Reference = struct {
    authors: std.ArrayList([]const u8) = .empty,
    title: []const u8 = "",
    book: []const u8 = "",
    journal: []const u8 = "",
    volume: []const u8 = "",
    number: []const u8 = "",
    pages: []const u8 = "",
    publisher: []const u8 = "",
    city: []const u8 = "",
    date: []const u8 = "",
    report: []const u8 = "",
    institution: []const u8 = "",
    optional: []const u8 = "",
    url: []const u8 = "",
};

const Parser = struct {
    a: Allocator,
    root: *Node,
    st: escape.State = .{},

    cur: *Node,
    para: ?*Node = null,
    /// Where inline output goes (paragraph, list term, table cell, link).
    target: *Node,
    stack: [max_levels]Ctx = undefined,
    depth: usize = 0,
    /// Lists refused at the depth limit, whose `.El` is ignored too.
    refused: usize = 0,

    /// A space is due before the next word.
    space: bool = false,
    nm: []const u8 = "",
    synopsis: bool = false,
    base_font: Font = .roman,
    in_fo: bool = false,
    fo_first: bool = true,
    /// The last run written by `emit`, so that neighbours in one font merge.
    last_top: ?*Node = null,
    last_leaf: ?*Node = null,
    /// The growing text of `last_leaf`.
    run: std.ArrayList(u8) = .empty,
    last_font: Font = .roman,
    nest: usize = 0,

    bd_literal: bool = false,
    code: std.ArrayList(u8) = .empty,
    xo: ?std.ArrayList(Word) = null,
    xo_depth: usize = 0,
    /// The joined `.Xo` line began with `.Xo` itself: its words are text, not a macro line.
    xo_inline: bool = false,
    /// `.Sm off` removes the spaces between words until `.Sm on`.
    spacing: bool = true,
    /// The blank before the next word was due when spacing went off.
    owed_space: bool = false,
    rs: ?Reference = null,
    line_no: u32 = 0,
    keep_comments: bool = false,

    // roff requests, which mdoc pages may use too.
    macros: std.StringHashMapUnmanaged(*man.Macro) = .empty,
    def: ?man.Definition = null,
    skip_end: ?[]const u8 = null,
    skip_depth: usize = 0,
    cond_depth: usize = 0,
    ie_results: [man.max_ie_depth]bool = undefined,
    ie_count: usize = 0,
    macro_depth: usize = 0,
    expanded_lines: usize = 0,
    expanded_bytes: usize = 0,
    /// Lines of an open `.TS` table.
    tbl: ?std.ArrayList([]const u8) = null,
    padded_cells: usize = 0,

    fn node(self: *Parser, kind: md.Kind) Allocator.Error!*Node {
        const n = try self.a.create(Node);
        n.* = .{ .kind = kind, .line = self.line_no };
        n.build.open = false;
        return n;
    }

    // ---- output helpers ----------------------------------------------------

    fn addRun(self: *Parser, parent: *Node, text: []const u8, font: Font) Allocator.Error!void {
        _ = try self.addRunTracked(parent, text, font);
    }

    const Added = struct { top: *Node, leaf: *Node };

    fn addRunTracked(self: *Parser, parent: *Node, text: []const u8, font: Font) Allocator.Error!Added {
        var inner = try self.node(if (font.mono) .code else .text);
        const leaf = inner;
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
        return .{ .top = inner, .leaf = leaf };
    }

    /// `.Sm on`, `.Sm off`, or a toggle when `on` is null. The blank already due
    /// after the last word stays when spacing goes off.
    fn setSpacing(self: *Parser, on: ?bool) void {
        const next = on orelse !self.spacing;
        if (self.spacing and !next) self.owed_space = self.space;
        self.spacing = next;
    }

    /// Writes already escaped `text` to the target, with a leading space if one
    /// is due and `glue_before` is false. `glue_after` keeps the next word
    /// attached (after an opening bracket).
    fn emit(self: *Parser, text: []const u8, font: Font, glue_before: bool, glue_after: bool) Allocator.Error!void {
        if (text.len == 0) return;
        const lead = (self.space and !glue_before and self.spacing) or (self.owed_space and !glue_before);
        self.owed_space = false;
        const f: Font = if (font.eql(.roman)) self.base_font else font;
        if (self.last_leaf) |leaf| {
            if (self.target.last_child == self.last_top and self.last_font.eql(f)) {
                if (lead) try self.run.append(self.a, ' ');
                try self.run.appendSlice(self.a, text);
                leaf.literal = self.run.items;
                self.space = !glue_after;
                return;
            }
        }
        if (lead) try self.addRun(self.target, " ", .roman);
        const added = try self.addRunTracked(self.target, text, f);
        // A new buffer: the finished run still points at the old one.
        self.run = .empty;
        try self.run.appendSlice(self.a, added.leaf.literal);
        added.leaf.literal = self.run.items;
        self.last_top = added.top;
        self.last_leaf = added.leaf;
        self.last_font = f;
        self.space = !glue_after;
    }

    fn clean(self: *Parser, w: []const u8) Allocator.Error![]const u8 {
        return escape.plain(self.a, &self.st, w);
    }

    fn isOpening(w: Word) bool {
        return !w.quoted and (std.mem.eql(u8, w.text, "(") or std.mem.eql(u8, w.text, "["));
    }

    fn isClosing(w: Word) bool {
        if (w.quoted) return false;
        for ([_][]const u8{ ".", ",", ":", ";", ")", "]", "?", "!" }) |d| if (std.mem.eql(u8, w.text, d)) return true;
        return false;
    }

    fn isCallable(w: Word) bool {
        return !w.quoted and !w.plain and std.meta.stringToEnum(Callable, w.text) != null;
    }

    /// Index of the first callable macro at or after `start`.
    fn argsEnd(words: []const Word, start: usize) usize {
        var i = start;
        while (i < words.len) : (i += 1) if (words[i].plain or isCallable(words[i])) return i;
        return words.len;
    }

    fn endPara(self: *Parser) void {
        self.para = null;
    }

    /// The paragraph that receives inline text; created on demand.
    fn paragraph(self: *Parser) Allocator.Error!*Node {
        if (self.para) |p| return p;
        const p = try self.node(.paragraph);
        self.cur.appendChild(p);
        self.para = p;
        return p;
    }

    fn lineSep(self: *Parser, hard: bool) Allocator.Error!void {
        const p = self.para orelse return;
        if (self.target != p) return;
        if (p.last_child) |last| {
            if (last.kind == .softbreak or last.kind == .linebreak) return;
            p.appendChild(try self.node(if (hard) .linebreak else .softbreak));
        }
    }

    // ---- word parsing --------------------------------------------------------

    /// One plain word: punctuation sticks to its neighbours.
    fn plainWord(self: *Parser, w: Word) Allocator.Error!void {
        const t = try self.clean(w.text);
        if (isOpening(w)) return self.emit(t, .roman, false, true);
        if (isClosing(w)) return self.emit(t, .roman, true, false);
        try self.emit(t, .roman, false, false);
    }

    /// Words as macros and text, left to right.
    fn parse(self: *Parser, words: []const Word) Allocator.Error!void {
        var i: usize = 0;
        while (i < words.len) {
            const w = words[i];
            if (isCallable(w)) {
                i = try self.macro(std.meta.stringToEnum(Callable, w.text).?, words, i + 1);
            } else {
                try self.plainWord(w);
                i += 1;
            }
        }
    }

    /// Arguments in one font; delimiters stay roman.
    fn styled(self: *Parser, font: Font, args: []const Word, prefix: []const u8) Allocator.Error!void {
        for (args) |arg| {
            if (isOpening(arg) or isClosing(arg) or (!arg.quoted and std.mem.eql(u8, arg.text, "|"))) {
                try self.plainWord(arg);
                continue;
            }
            const t = try self.clean(arg.text);
            if (prefix.len > 0) {
                const joined = try std.mem.concat(self.a, u8, &.{ prefix, t });
                try self.emit(joined, font, false, false);
            } else try self.emit(t, font, false, false);
        }
    }

    fn enclosed(self: *Parser, open: []const u8, close: []const u8, words: []const Word, start: usize) Allocator.Error!usize {
        // The caller's loop goes on with the words, without recursion.
        if (self.nest >= max_nest) return start;
        self.nest += 1;
        defer self.nest -= 1;
        var end = words.len;
        while (end > start and isClosing(words[end - 1])) end -= 1;
        try self.emit(open, .roman, false, true);
        try self.parse(words[start..end]);
        try self.emit(close, .roman, true, false);
        for (words[end..]) |d| try self.plainWord(d);
        return words.len;
    }

    fn joinWords(self: *Parser, words: []const Word) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (words, 0..) |w, i| {
            if (i > 0) try out.append(self.a, ' ');
            try out.appendSlice(self.a, try self.clean(w.text));
        }
        return out.items;
    }

    fn macro(self: *Parser, m: Callable, words: []const Word, start: usize) Allocator.Error!usize {
        const end = argsEnd(words, start);
        var args = words[start..end];
        // For macros whose arguments are names or versions, closing
        // punctuation after them is not one of those.
        var punct: []const Word = &.{};
        switch (m) {
            .Nm, .Fl, .Ar, .Xr, .At, .Bx, .Bsx, .Ox, .Fx, .Nx, .Dx, .Ux, .St, .Lb => {
                var n = args.len;
                while (n > 0 and isClosing(args[n - 1])) n -= 1;
                punct = args[n..];
                args = args[0..n];
            },
            else => {},
        }
        switch (m) {
            // Fonts.
            .Ad, .Em, .Pa, .Va, .Vt, .Fa, .Ft, .Ot => {
                if (m == .Fa and self.in_fo) {
                    if (!self.fo_first) try self.emit(",", .roman, true, false);
                    self.fo_first = false;
                }
                try self.styled(Font.i, args, "");
            },
            .Ar => if (args.len == 0) try self.emit("file ...", Font.i, false, false) else try self.styled(Font.i, args, ""),
            .Cm, .Ic, .Sy, .Fd, .Cd => try self.styled(Font.b, args, ""),
            .Fl => {
                if (args.len == 0) {
                    // `.Fl Fl long` is "--long": a bare flag sticks to the next one.
                    const next_is_fl = punct.len == 0 and end < words.len and std.mem.eql(u8, words[end].text, "Fl");
                    try self.emit("-", Font.b, false, next_is_fl);
                } else try self.styled(Font.b, args, "-");
            },
            .Nm => {
                if (args.len > 0) {
                    if (self.nm.len == 0) self.nm = try self.joinWords(args);
                    try self.styled(Font.b, args, "");
                } else try self.emit(self.nm, Font.b, false, false);
            },
            .Li => try self.styled(Font.cw, args, ""),
            .Ql => {
                try self.emit("\u{2018}", .roman, false, true);
                try self.styled(Font.cw, args, "");
                try self.emit("\u{2019}", .roman, true, false);
            },
            .An => {
                // `.An -split` and `-nosplit` only say how to break lines.
                var keep = args;
                while (keep.len > 0 and (std.mem.eql(u8, keep[0].text, "-split") or std.mem.eql(u8, keep[0].text, "-nosplit"))) keep = keep[1..];
                try self.styled(.roman, keep, "");
            },
            .Sm => {
                if (args.len > 0) {
                    if (std.mem.eql(u8, args[0].text, "off")) self.setSpacing(false);
                    if (std.mem.eql(u8, args[0].text, "on")) self.setSpacing(true);
                    return start + 1;
                }
                self.setSpacing(null);
            },
            .Ev, .Er, .Dv, .Ms, .Tn, .Sx, .No => try self.styled(.roman, args, ""),
            .Ok => {},
            .Fr, .En, .Es => try self.styled(.roman, args, ""),
            // Custom enclosure: the first argument of each is the delimiter.
            .Eo => for (args, 0..) |arg, k| {
                try self.emit(try self.clean(arg.text), .roman, false, k == 0);
            },
            .Ec => for (args, 0..) |arg, k| {
                try self.emit(try self.clean(arg.text), .roman, k == 0, false);
            },
            .Ud => {
                try self.emit("currently under development.", .roman, false, false);
                for (args) |d| try self.plainWord(d);
            },

            // Spacing.
            .Ns => {
                self.space = false;
                return start;
            },
            .Pf => {
                if (args.len > 0) {
                    try self.emit(try self.clean(args[0].text), .roman, false, true);
                    return start + 1;
                }
            },
            .Ap => {
                try self.emit("'", .roman, true, true);
                return start;
            },
            .Ta, .Xo, .Xc => return start,

            // Enclosures.
            .Aq => return self.enclosed("<", ">", words, start),
            .Bq => return self.enclosed("[", "]", words, start),
            .Brq => return self.enclosed("{", "}", words, start),
            .Dq => return self.enclosed("\u{201c}", "\u{201d}", words, start),
            .Op => return self.enclosed("[", "]", words, start),
            .Pq => return self.enclosed("(", ")", words, start),
            .Qq => return self.enclosed("\"", "\"", words, start),
            .Sq => return self.enclosed("\u{2018}", "\u{2019}", words, start),
            .Ao => {
                try self.emit("<", .roman, false, true);
                return start;
            },
            .Ac => {
                try self.emit(">", .roman, true, false);
                return start;
            },
            .Bo, .Oo => {
                try self.emit("[", .roman, false, true);
                return start;
            },
            .Bc, .Oc => {
                try self.emit("]", .roman, true, false);
                return start;
            },
            .Bro => {
                try self.emit("{", .roman, false, true);
                return start;
            },
            .Brc => {
                try self.emit("}", .roman, true, false);
                return start;
            },
            .Do => {
                try self.emit("\u{201c}", .roman, false, true);
                return start;
            },
            .Dc => {
                try self.emit("\u{201d}", .roman, true, false);
                return start;
            },
            .Po => {
                try self.emit("(", .roman, false, true);
                return start;
            },
            .Pc => {
                try self.emit(")", .roman, true, false);
                return start;
            },
            .Qo => {
                try self.emit("\"", .roman, false, true);
                return start;
            },
            .Qc => {
                try self.emit("\"", .roman, true, false);
                return start;
            },
            .So => {
                try self.emit("\u{2018}", .roman, false, true);
                return start;
            },
            .Sc => {
                try self.emit("\u{2019}", .roman, true, false);
                return start;
            },

            // Cross references, functions, includes.
            .Xr => {
                if (args.len >= 1) {
                    const name = try self.clean(args[0].text);
                    const text = if (args.len >= 2)
                        try std.fmt.allocPrint(self.a, "{s}({s})", .{ name, try self.clean(args[1].text) })
                    else
                        name;
                    try self.emit(text, .roman, false, false);
                    for (args[@min(args.len, 2)..]) |d| try self.plainWord(d);
                }
            },
            .Fn => {
                if (args.len > 0) {
                    try self.emit(try self.clean(args[0].text), Font.b, false, false);
                    try self.emit("(", .roman, true, true);
                    var first = true;
                    var tail = args.len;
                    while (tail > 1 and isClosing(args[tail - 1])) tail -= 1;
                    for (args[1..tail]) |p| {
                        if (!first) try self.emit(",", .roman, true, false);
                        first = false;
                        try self.emit(try self.clean(p.text), Font.i, false, false);
                    }
                    try self.emit(")", .roman, true, false);
                    for (args[tail..]) |d| try self.plainWord(d);
                }
            },
            .Fo => {
                if (args.len > 0) {
                    try self.emit(try self.clean(args[0].text), Font.b, false, false);
                    try self.emit("(", .roman, true, true);
                    self.in_fo = true;
                    self.fo_first = true;
                }
            },
            .Fc => {
                self.in_fo = false;
                try self.emit(")", .roman, true, false);
                return start;
            },
            .In => {
                if (args.len > 0) {
                    const f = try self.clean(args[0].text);
                    const text = if (self.synopsis)
                        try std.fmt.allocPrint(self.a, "#include <{s}>", .{f})
                    else
                        try std.fmt.allocPrint(self.a, "<{s}>", .{f});
                    try self.emit(text, if (self.synopsis) Font.b else Font.cw, false, false);
                    for (args[1..]) |d| try self.plainWord(d);
                }
            },

            // Links.
            .Lk, .Mt => {
                if (args.len > 0) {
                    const url = try self.clean(args[0].text);
                    const link = try self.node(.link);
                    link.literal = if (m == .Mt) try std.fmt.allocPrint(self.a, "mailto:{s}", .{url}) else try self.a.dupe(u8, url);
                    if (self.space) try self.addRun(self.target, " ", .roman);
                    self.target.appendChild(link);
                    const saved = self.target;
                    self.target = link;
                    self.space = false;
                    var label_end = args.len;
                    while (label_end > 1 and isClosing(args[label_end - 1])) label_end -= 1;
                    if (label_end > 1) {
                        try self.parse(args[1..label_end]);
                    } else try self.addRun(link, url, .roman);
                    self.target = saved;
                    self.space = true;
                    for (args[label_end..]) |d| try self.plainWord(d);
                }
            },

            // Names of systems and standards.
            .At => {
                try self.emit(atName(args), .roman, false, false);
                if (args.len > 1) for (args[1..]) |d| try self.plainWord(d);
            },
            .Bx => try self.systemName("BSD", args),
            .Bsx => try self.systemName("BSD/OS", args),
            .Ox => try self.systemName("OpenBSD", args),
            .Fx => try self.systemName("FreeBSD", args),
            .Nx => try self.systemName("NetBSD", args),
            .Dx => try self.systemName("DragonFly", args),
            .Ux => {
                try self.emit("UNIX", .roman, false, false);
                for (args) |d| try self.plainWord(d);
            },
            .St => {
                if (args.len > 0) {
                    try self.emit(standardName(args[0].text), .roman, false, false);
                    for (args[1..]) |d| try self.plainWord(d);
                }
            },
            .Lb => {
                if (args.len > 0) {
                    try self.emit(libraryName(args[0].text), .roman, false, false);
                    for (args[1..]) |d| try self.plainWord(d);
                }
            },
        }
        for (punct) |d| try self.plainWord(d);
        return end;
    }

    fn systemName(self: *Parser, name: []const u8, args: []const Word) Allocator.Error!void {
        // `.Bx 4.3` is "4.3BSD"; `.Ox 5.0` is "OpenBSD 5.0".
        if (args.len > 0 and std.mem.eql(u8, name, "BSD") and !std.mem.startsWith(u8, args[0].text, "-")) {
            const v = try self.clean(args[0].text);
            try self.emit(try std.fmt.allocPrint(self.a, "{s}BSD", .{v}), .roman, false, false);
            for (args[1..]) |d| try self.plainWord(d);
            return;
        }
        try self.emit(name, .roman, false, false);
        for (args) |x| if (!std.mem.startsWith(u8, x.text, "-")) try self.plainWord(x);
    }

    // ---- block macros ---------------------------------------------------------

    const body_indent: u16 = 7;
    const sub_indent: u16 = 3;

    fn heading(self: *Parser, level: u8, args: []const Word) Allocator.Error!void {
        try self.closeAllLists();
        self.endPara();
        const h = try self.node(.heading);
        h.level = level;
        // Same layout as man pages: `.Sh` body indented 7, `.Ss` heading at 3.
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
        self.cur = body;
        const text = try self.joinWords(args);
        try self.addRun(h, text, .roman);
        if (level == 2) {
            self.synopsis = std.ascii.eqlIgnoreCase(text, "SYNOPSIS");
        }
    }

    fn closeAllLists(self: *Parser) Allocator.Error!void {
        self.refused = 0;
        while (self.depth > 0) try self.popList();
        self.bd_literal = false;
        try self.flushCode();
    }

    fn popList(self: *Parser) Allocator.Error!void {
        if (self.depth == 0) return;
        self.depth -= 1;
        // The renderer sizes a table from its first row.
        if (self.stack[self.depth].kind == .column) try man.padRows(self.a, self.stack[self.depth].list, &self.padded_cells);
        self.cur = self.stack[self.depth].parent;
        self.endPara();
    }

    fn startList(self: *Parser, args: []const Word) Allocator.Error!void {
        self.endPara();
        if (self.depth >= max_levels) {
            self.refused += 1;
            return;
        }
        var kind: ListKind = .tag;
        for (args) |w| {
            if (std.mem.eql(u8, w.text, "-bullet") or std.mem.eql(u8, w.text, "-dash") or std.mem.eql(u8, w.text, "-hyphen") or std.mem.eql(u8, w.text, "-item")) kind = .bullet;
            if (std.mem.eql(u8, w.text, "-enum")) kind = .enumerated;
            if (std.mem.eql(u8, w.text, "-column")) kind = .column;
        }
        var width: u16 = 6;
        for (args, 0..) |w, k| {
            if (!std.mem.eql(u8, w.text, "-width") or k + 1 >= args.len) continue;
            const arg = args[k + 1].text;
            if (escape.columns(arg)) |c| {
                width = c;
            } else if (std.mem.eql(u8, arg, "Ds")) {
                width = 8;
            } else width = @intCast(@min(@max(arg.len + 1, 4), 30));
        }
        const list = switch (kind) {
            .tag => blk: {
                const d = try self.node(.deflist);
                d.list.tight = false;
                break :blk d;
            },
            .bullet, .enumerated => blk: {
                const l = try self.node(.list);
                l.list = if (kind == .bullet)
                    .{ .kind = .bullet, .tight = true, .bullet_char = '*' }
                else
                    .{ .kind = .ordered, .tight = true, .start = 1, .delimiter = '.' };
                break :blk l;
            },
            .column => try self.node(.table),
        };
        self.cur.appendChild(list);
        self.stack[self.depth] = .{ .kind = kind, .list = list, .parent = self.cur, .width = width };
        self.depth += 1;
    }

    fn item(self: *Parser, args: []const Word) Allocator.Error!void {
        self.endPara();
        if (self.depth == 0) return;
        const ctx = &self.stack[self.depth - 1];
        self.space = false;
        switch (ctx.kind) {
            .tag => {
                const term = try self.node(.deflist_term);
                const def = try self.node(.deflist_def);
                def.indent = ctx.width;
                ctx.list.appendChild(term);
                ctx.list.appendChild(def);
                self.cur = def;
                const saved = self.target;
                self.target = term;
                try self.parse(args);
                self.target = saved;
            },
            .bullet, .enumerated => {
                const it = try self.node(.item);
                ctx.list.appendChild(it);
                self.cur = it;
                if (args.len > 0) {
                    self.target = try self.paragraph();
                    try self.parse(args);
                }
            },
            .column => {
                const row = try self.node(.table_row);
                ctx.list.appendChild(row);
                ctx.row = row;
                try self.addCells(row, args);
            },
        }
        ctx.item_open = true;
        self.space = false;
    }

    /// Adds the cells of `args`, separated by `Ta`, to a column list row. The
    /// lines that follow go on in the last of them.
    fn addCells(self: *Parser, row: *Node, args: []const Word) Allocator.Error!void {
        var count: usize = 0;
        var c = row.first_child;
        while (c) |x| : (c = x.next) count += 1;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= args.len) : (i += 1) {
            if (i < args.len and !(std.mem.eql(u8, args[i].text, "Ta") and !args[i].quoted and count + 1 < man.max_columns)) continue;
            // At the limit, further text joins the last cell.
            const cell = if (count < man.max_columns) blk: {
                const new = try self.node(.table_cell);
                row.appendChild(new);
                count += 1;
                break :blk new;
            } else row.last_child.?;
            const saved = self.target;
            self.target = cell;
            self.space = false;
            try self.parse(args[start..i]);
            self.target = saved;
            start = i + 1;
        }
        self.para = row.last_child;
        self.target = row.last_child.?;
    }

    fn flushCode(self: *Parser) Allocator.Error!void {
        if (self.code.items.len == 0) return;
        const b = try self.node(.code_block);
        b.literal = try self.a.dupe(u8, self.code.items);
        b.indent = Node.flush;
        self.cur.appendChild(b);
        self.code.clearRetainingCapacity();
    }

    /// Plain text of macro words (for displays that keep layout).
    fn plainOf(self: *Parser, words: []const Word) Allocator.Error![]const u8 {
        const tmp = try self.node(.paragraph);
        const saved_target = self.target;
        const saved_space = self.space;
        self.target = tmp;
        self.space = false;
        try self.parse(words);
        self.target = saved_target;
        self.space = saved_space;
        var out: std.ArrayList(u8) = .empty;
        try flatten(self.a, tmp, &out);
        return out.items;
    }

    fn flatten(a: Allocator, n: *Node, out: *std.ArrayList(u8)) Allocator.Error!void {
        var c = n.first_child;
        while (c) |x| : (c = x.next) switch (x.kind) {
            .text, .code => try out.appendSlice(a, x.literal),
            .softbreak, .linebreak => try out.append(a, ' '),
            else => try flatten(a, x, out),
        };
    }

    fn textMacro(self: *Parser, words: []const Word, single_pre: []const u8, single_post: []const u8, multi_post: []const u8, call_style: bool) Allocator.Error!void {
        // `.Ex -std [name ...]` and `.Rv -std [name ...]`.
        var names: std.ArrayList([]const u8) = .empty;
        for (words) |w| {
            if (std.mem.startsWith(u8, w.text, "-")) continue;
            try names.append(self.a, try self.clean(w.text));
        }
        if (names.items.len == 0 and self.nm.len > 0) try names.append(self.a, self.nm);
        if (names.items.len == 0) return;
        const p = try self.paragraphIn();
        self.target = p;
        self.space = false;
        try self.emit(single_pre, .roman, false, false);
        for (names.items, 0..) |n, i| {
            // "a and b"; "a, b, and c".
            if (i > 0 and names.items.len > 2) try self.emit(",", .roman, true, false);
            if (i > 0 and i + 1 == names.items.len) try self.emit("and", .roman, false, false);
            const label = if (call_style) try std.fmt.allocPrint(self.a, "{s}()", .{n}) else n;
            try self.emit(label, Font.b, false, false);
        }
        try self.emit(if (names.items.len == 1) single_post else multi_post, .roman, false, false);
        self.space = false;
    }

    /// A fresh paragraph in the current container.
    fn paragraphIn(self: *Parser) Allocator.Error!*Node {
        self.endPara();
        return self.paragraph();
    }

    fn reference(self: *Parser) *Reference {
        return &self.rs.?;
    }

    fn refField(self: *Parser, field: []const u8, words: []const Word) Allocator.Error!void {
        if (self.rs == null) return;
        const text = try self.joinWords(words);
        const r = self.reference();
        if (std.mem.eql(u8, field, "A")) try r.authors.append(self.a, text);
        if (std.mem.eql(u8, field, "T")) r.title = text;
        if (std.mem.eql(u8, field, "B")) r.book = text;
        if (std.mem.eql(u8, field, "J")) r.journal = text;
        if (std.mem.eql(u8, field, "V")) r.volume = text;
        if (std.mem.eql(u8, field, "N")) r.number = text;
        if (std.mem.eql(u8, field, "P")) r.pages = text;
        if (std.mem.eql(u8, field, "I")) r.publisher = text;
        if (std.mem.eql(u8, field, "C")) r.city = text;
        if (std.mem.eql(u8, field, "D")) r.date = text;
        if (std.mem.eql(u8, field, "R")) r.report = text;
        if (std.mem.eql(u8, field, "Q")) r.institution = text;
        if (std.mem.eql(u8, field, "O")) r.optional = text;
        if (std.mem.eql(u8, field, "U")) r.url = text;
    }

    fn endReference(self: *Parser) Allocator.Error!void {
        const r = self.rs orelse return;
        self.rs = null;
        const p = try self.paragraphIn();
        self.target = p;
        var out: std.ArrayList(u8) = .empty;
        const n = r.authors.items.len;
        for (r.authors.items, 0..) |au, i| {
            if (i > 0) try out.appendSlice(self.a, if (i + 1 == n) (if (n > 2) ", and " else " and ") else ", ");
            try out.appendSlice(self.a, au);
        }
        const parts = [_][]const u8{ "", r.title, r.book, r.journal, r.report, r.institution, r.publisher, r.city, r.optional, r.url };
        var first = n == 0;
        if (n > 0) {
            try self.addRun(p, out.items, .roman);
        }
        for (parts) |part| {
            if (part.len == 0) continue;
            if (!first) try self.addRun(p, ", ", .roman);
            first = false;
            try self.addRun(p, part, if (part.ptr == r.title.ptr) Font.i else Font.roman);
        }
        const tail = [_][]const u8{ r.volume, r.number, r.pages, r.date };
        for (tail) |part| {
            if (part.len == 0) continue;
            if (!first) try self.addRun(p, ", ", .roman);
            first = false;
            try self.addRun(p, part, .roman);
        }
        try self.addRun(p, ".", .roman);
        self.endPara();
        self.space = false;
    }

    const break_macros = [_]Callable{ .Nm, .Ft, .Fd, .In, .Vt, .Fn, .Fo, .Cd };

    fn breaksInSynopsis(w: Word) bool {
        const m = std.meta.stringToEnum(Callable, w.text) orelse return false;
        for (break_macros) |b| if (b == m) return true;
        return false;
    }

    /// One macro or text line, already split into words (and without the dot).
    fn lineWords(self: *Parser, words: []const Word, from_xo: bool) Allocator.Error!void {
        if (words.len == 0) return;
        const first = words[0];
        // `.Ta` at the start of a line adds cells to the row above.
        if (!first.quoted and std.mem.eql(u8, first.text, "Ta") and self.depth > 0) {
            if (self.stack[self.depth - 1].row) |row| return self.addCells(row, words[1..]);
        }
        if (!first.quoted and !from_xo) {
            if (std.meta.stringToEnum(Block, first.text)) |b| return self.block(b, words[1..]);
        }
        if (isCallable(first) or from_xo) {
            if (self.bd_literal) {
                const text = try self.plainOf(words);
                try self.code.appendSlice(self.a, text);
                try self.code.append(self.a, '\n');
                return;
            }
            if (self.target != self.cur and self.target.kind != .paragraph) self.target = try self.paragraph();
            if (self.target.kind != .paragraph) self.target = try self.paragraph();
            const p = try self.paragraph();
            self.target = p;
            try self.lineSep(self.synopsis and breaksInSynopsis(first));
            self.space = false;
            try self.parse(words);
            return;
        }
        // Unknown macro: ignored.
    }

    fn block(self: *Parser, b: Block, args: []const Word) Allocator.Error!void {
        switch (b) {
            .Sm => {
                if (args.len == 0) {
                    self.setSpacing(null);
                } else if (std.mem.eql(u8, args[0].text, "off")) {
                    self.setSpacing(false);
                } else if (std.mem.eql(u8, args[0].text, "on")) self.setSpacing(true);
            },
            .Dd, .Os, .Db, .Bk, .Ek, .Hf, .Tg => {},
            .Dt => {
                try self.closeAllLists();
                self.endPara();
                const h = try self.node(.heading);
                h.level = 1;
                self.root.appendChild(h);
                const title = if (args.len > 0) try self.clean(args[0].text) else "";
                const section = if (args.len > 1) try self.clean(args[1].text) else "";
                try self.addRun(h, try std.fmt.allocPrint(self.a, "{s}({s})", .{ title, section }), .roman);
            },
            .Sh => try self.heading(2, args),
            .Ss => try self.heading(3, args),
            .Pp, .Lp => if (self.bd_literal) {
                try self.code.append(self.a, '\n');
            } else self.endPara(),
            .Nd => {
                const p = try self.paragraph();
                self.target = p;
                self.space = true;
                try self.emit("\u{2014}", .roman, false, false);
                try self.parse(args);
            },
            .Bl => try self.startList(args),
            .El => if (self.refused > 0) {
                self.refused -= 1;
                self.endPara();
            } else try self.popList(),
            .It => try self.item(args),
            .Bd => {
                self.endPara();
                for (args) |w| {
                    if (std.mem.eql(u8, w.text, "-literal") or std.mem.eql(u8, w.text, "-unfilled")) self.bd_literal = true;
                }
            },
            .Ed => {
                self.bd_literal = false;
                try self.flushCode();
            },
            .Dl, .D1 => {
                self.endPara();
                const text = try self.plainOf(args);
                try self.code.appendSlice(self.a, text);
                try self.code.append(self.a, '\n');
                try self.flushCode();
            },
            .Bf => {
                for (args) |w| {
                    if (std.mem.eql(u8, w.text, "-emphasis") or std.mem.eql(u8, w.text, "Em")) self.base_font = Font.i;
                    if (std.mem.eql(u8, w.text, "-symbolic") or std.mem.eql(u8, w.text, "Sy")) self.base_font = Font.b;
                    if (std.mem.eql(u8, w.text, "-literal") or std.mem.eql(u8, w.text, "Li")) self.base_font = Font.cw;
                }
            },
            .Ef => self.base_font = .roman,
            .Ex => try self.textMacro(args, "The", "utility exits 0 on success, and >0 if an error occurs.", "utilities exit 0 on success, and >0 if an error occurs.", false),
            .Rv => try self.textMacro(args, "The", "function returns the value 0 if successful; otherwise the value -1 is returned and the global variable errno is set to indicate the error.", "functions return the value 0 if successful; otherwise the value -1 is returned and the global variable errno is set to indicate the error.", true),
            .Rs => self.rs = .{},
            .Re => try self.endReference(),
            .@"%A" => try self.refField("A", args),
            .@"%B" => try self.refField("B", args),
            .@"%C" => try self.refField("C", args),
            .@"%D" => try self.refField("D", args),
            .@"%I" => try self.refField("I", args),
            .@"%J" => try self.refField("J", args),
            .@"%N" => try self.refField("N", args),
            .@"%O" => try self.refField("O", args),
            .@"%P" => try self.refField("P", args),
            .@"%Q" => try self.refField("Q", args),
            .@"%R" => try self.refField("R", args),
            .@"%T" => try self.refField("T", args),
            .@"%U" => try self.refField("U", args),
            .@"%V" => try self.refField("V", args),
        }
    }

    fn textLine(self: *Parser, l: []const u8) Allocator.Error!void {
        if (self.bd_literal) {
            try self.code.appendSlice(self.a, try escape.plain(self.a, &self.st, l));
            try self.code.append(self.a, '\n');
            return;
        }
        if (std.mem.trim(u8, l, " \t").len == 0) {
            self.endPara();
            return;
        }
        const p = try self.paragraph();
        self.target = p;
        try self.lineSep(false);
        self.space = false;
        // The whole line at once: escapes may span blanks, and fonts must stay.
        const r = try escape.segments(self.a, &self.st, std.mem.trimEnd(u8, l, " \t"));
        for (r.segments) |seg| try self.emit(seg.text, seg.font, true, false);
    }

    // ---- roff requests -------------------------------------------------------

    /// Runs the roff request or user macro on a control line (without its
    /// dot). False when the line is for mdoc.
    fn roffRequest(self: *Parser, body: []const u8) Allocator.Error!bool {
        var name_end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        for ([_][]const u8{ "if\\", "ie\\", "el\\" }) |start| {
            if (std.mem.startsWith(u8, body, start)) name_end = 2;
        }
        const name = body[0..name_end];
        const rest = std.mem.trimStart(u8, body[name_end..], " \t");
        const Roff = enum { ig, de, de1, am, am1, ds, nr, rr, @"if", ie, el, br, sp, nf, fi, TS };
        const req = std.meta.stringToEnum(Roff, name) orelse {
            const user_macro = self.macros.get(name) orelse return false;
            try self.callMacro(user_macro, try man.splitArgs(self.a, rest));
            return true;
        };
        switch (req) {
            .@"if", .ie => try self.conditional(rest, req == .ie),
            .el => {
                var matched = false;
                if (self.ie_count > 0) {
                    self.ie_count -= 1;
                    matched = self.ie_results[self.ie_count];
                }
                try self.branch(!matched, rest);
            },
            .ig, .de, .de1, .am, .am1 => {
                const args = try man.splitArgs(self.a, rest);
                const end_arg: usize = if (req == .ig) 0 else 1;
                const end = if (args.len > end_arg) try std.fmt.allocPrint(self.a, ".{s}", .{args[end_arg]}) else "..";
                if (req == .ig or args.len == 0) {
                    self.skip_end = end;
                } else self.def = .{ .name = args[0], .append = req == .am or req == .am1, .end = end };
            },
            .ds => try man.defineString(self.a, &self.st, rest),
            .nr => try man.setRegister(self.a, &self.st, try man.splitArgs(self.a, rest)),
            .rr => {
                const args = try man.splitArgs(self.a, rest);
                if (args.len > 0) _ = self.st.regs.remove(args[0]);
            },
            .br => if (self.para) |p| {
                if (self.target == p) try self.lineSep(true);
            },
            .sp => if (self.bd_literal) {
                try self.code.append(self.a, '\n');
            } else self.endPara(),
            .nf => {
                self.endPara();
                self.bd_literal = true;
            },
            .fi => {
                self.bd_literal = false;
                try self.flushCode();
            },
            .TS => {
                try self.flushCode();
                self.endPara();
                self.tbl = .empty;
            },
        }
        return true;
    }

    fn conditional(self: *Parser, rest: []const u8, is_ie: bool) Allocator.Error!void {
        var s = rest;
        var negate = false;
        while (s.len > 0 and s[0] == '!') : (s = s[1..]) negate = !negate;
        const r = try man.evalCond(self, s);
        const truth = r.truth != negate;
        if (is_ie and self.ie_count < man.max_ie_depth) {
            self.ie_results[self.ie_count] = truth;
            self.ie_count += 1;
        }
        try self.branch(truth, std.mem.trimStart(u8, r.rest, " \t"));
    }

    fn branch(self: *Parser, truth: bool, body_in: []const u8) Allocator.Error!void {
        var body = body_in;
        const block_start = std.mem.startsWith(u8, body, "\\{");
        if (block_start) body = std.mem.trimStart(u8, body[2..], " \t");
        if (!truth) {
            if (block_start) self.skip_depth = man.skipBraces(body, 1);
            return;
        }
        if (body.len == 0 or self.cond_depth >= man.max_cond_depth) return;
        self.cond_depth += 1;
        defer self.cond_depth -= 1;
        try self.line(body);
    }

    fn endDefinition(self: *Parser) Allocator.Error!void {
        const d = self.def.?;
        self.def = null;
        const gop = try self.macros.getOrPut(self.a, d.name);
        if (!d.append or !gop.found_existing) {
            gop.value_ptr.* = try self.a.create(man.Macro);
            gop.value_ptr.*.* = .{};
        }
        if (d.lines.items.len > 0) try gop.value_ptr.*.chunks.append(self.a, d.lines.items);
    }

    /// Runs a user macro within the same limits as the man(7) reader.
    fn callMacro(self: *Parser, user: *man.Macro, args: []const []const u8) Allocator.Error!void {
        if (self.macro_depth >= man.max_macro_depth) return;
        self.macro_depth += 1;
        defer self.macro_depth -= 1;
        const chunks = user.chunks.items.len;
        for (0..chunks) |c| {
            for (user.chunks.items[c]) |bl| {
                if (self.expanded_lines >= man.max_expanded_lines) return;
                self.expanded_lines += 1;
                const filled = try man.substArgs(self.a, bl, args, man.max_expanded_bytes - self.expanded_bytes) orelse {
                    self.expanded_lines = man.max_expanded_lines;
                    return;
                };
                self.expanded_bytes += filled.len;
                try self.line(filled);
            }
        }
    }

    /// One line of a table cell, read as mdoc.
    fn cellLine(context: *anyopaque, table: *man.Parser, cell: *Node, l: []const u8) Allocator.Error!void {
        const self: *Parser = @ptrCast(@alignCast(context));
        const saved_cur = self.cur;
        const saved_target = self.target;
        const saved_para = self.para;
        self.st = table.st;
        self.cur = cell;
        self.target = cell;
        self.para = cell;
        const line_no = self.line_no;
        try self.line(l);
        // A table opened inside the cell ends with the line that opened it.
        self.tbl = null;
        self.line_no = line_no;
        self.cur = saved_cur;
        self.target = saved_target;
        self.para = saved_para;
        table.st = self.st;
    }

    /// Builds the open table with the man(7) reader's tbl code.
    fn endTable(self: *Parser) Allocator.Error!void {
        const rows = self.tbl orelse return;
        self.tbl = null;
        var sub: man.Parser = .{ .a = self.a, .root = self.cur, .container = self.cur, .cur = self.cur, .st = self.st, .in_tbl = true, .tbl_lines = rows, .padded_cells = self.padded_cells };
        sub.cell_lines = .{ .context = self, .run = cellLine };
        try sub.endTable();
        self.st = sub.st;
        self.padded_cells = sub.padded_cells;
    }

    /// Writes the words of a `.Xo` that is still open.
    fn endXo(self: *Parser) Allocator.Error!void {
        const joined = self.xo orelse return;
        self.xo = null;
        try self.lineWords(joined.items, self.xo_inline);
    }

    fn line(self: *Parser, raw: []const u8) Allocator.Error!void {
        var l = raw;
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        l = try escape.sanitize(self.a, l);
        const is_macro = l.len > 0 and (l[0] == '.' or l[0] == '\'');
        if (self.def) |*d| {
            if (man.endsDefinition(l, d.end)) {
                try self.endDefinition();
            } else try d.lines.append(self.a, try man.copyMode(self.a, l));
            return;
        }
        if (self.skip_end) |end| {
            if (man.endsDefinition(l, end)) self.skip_end = null;
            return;
        }
        if (self.skip_depth > 0) {
            self.skip_depth = man.skipBraces(l, self.skip_depth);
            return;
        }
        if (std.mem.endsWith(u8, l, "\\}") and man.closesBlock(l)) l = l[0 .. l.len - 2];
        if (self.tbl) |*rows| {
            if (std.mem.startsWith(u8, l, ".TE")) return self.endTable();
            return rows.append(self.a, l);
        }
        if (man.commentBody(l)) |t| {
            // A comment inside a paragraph or literal block is dropped.
            if (self.keep_comments and self.para == null and !self.bd_literal and self.xo == null) {
                const n = try self.node(.html_block);
                n.literal = try man.htmlComment(self.a, t);
                self.cur.appendChild(n);
            }
            return;
        }

        const had_text = l.len > 0;
        l = man.stripComment(l);
        // Nothing but a comment is not a blank line.
        if (had_text and l.len == 0) return;

        var words: []const Word = &.{};
        if (is_macro) {
            const body = std.mem.trimStart(u8, l[1..], " \t");
            // An empty request, or one such as `.\\}` that only closes a block.
            if (body.len == 0 or body[0] == '\\') return;
            if (try self.roffRequest(body)) return;
            const in_columns = self.depth > 0 and self.stack[self.depth - 1].kind == .column;
            // In a column list a tab also separates cells.
            words = try splitWords(self.a, if (in_columns and std.mem.startsWith(u8, body, "It")) try tabsToTa(self.a, body) else body);
        }

        // `.Xo` ... `.Xc` joins several lines into one macro line.
        if (self.xo != null) {
            // A section heading ends an unterminated `.Xo`.
            if (is_macro and words.len > 0 and (std.mem.eql(u8, words[0].text, "Sh") or std.mem.eql(u8, words[0].text, "Ss"))) {
                try self.endXo();
            } else {
                const w = if (is_macro) words else try splitWords(self.a, l);
                if (is_macro and w.len > 0 and std.mem.eql(u8, w[0].text, "Xc")) {
                    self.xo_depth -|= 1;
                    if (self.xo_depth == 0) {
                        // The rest of the `.Xc` line belongs to the joined line.
                        try self.xo.?.appendSlice(self.a, w[1..]);
                        const joined = self.xo.?.items;
                        self.xo = null;
                        try self.lineWords(joined, self.xo_inline);
                        return;
                    }
                }
                for (w) |word| {
                    var x = word;
                    x.plain = !is_macro;
                    if (!x.quoted and std.mem.eql(u8, x.text, "Xo")) self.xo_depth += 1;
                    try self.xo.?.append(self.a, x);
                }
                return;
            }
        }
        if (is_macro) {
            for (words, 0..) |w, i| {
                if (w.quoted or !std.mem.eql(u8, w.text, "Xo")) continue;
                // `.Xo ... Xc` on one line is just that line without the pair.
                var close: ?usize = null;
                for (words[i + 1 ..], i + 1..) |x, j| {
                    if (!x.quoted and std.mem.eql(u8, x.text, "Xc")) close = j;
                }
                var acc: std.ArrayList(Word) = .empty;
                for (words, 0..) |x, j| {
                    if (j == i or (close != null and j == close.?)) continue;
                    try acc.append(self.a, x);
                }
                if (close != null) return self.lineWords(acc.items, i == 0);
                self.xo = acc;
                self.xo_depth = 1;
                self.xo_inline = i == 0;
                return;
            }
            try self.lineWords(words, false);
            return;
        }
        try self.textLine(l);
    }
};

/// `.It` line with each tab between two cells written as `Ta`.
fn tabsToTa(a: Allocator, body: []const u8) Allocator.Error![]const u8 {
    if (body.len < 3) return body;
    const rest = std.mem.trim(u8, body[2..], " \t");
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "It ");
    var quoted = false;
    for (rest) |c| {
        if (c == '"') quoted = !quoted;
        if (c == '\t' and !quoted) try out.appendSlice(a, " Ta ") else try out.append(a, c);
    }
    return out.items;
}

/// Splits a macro line into words; a leading double quote starts a quoted word
/// (`""` inside is one quote).
fn splitWords(a: Allocator, s: []const u8) Allocator.Error![]Word {
    var out: std.ArrayList(Word) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        var buf: std.ArrayList(u8) = .empty;
        if (s[i] == '"') {
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == '"') {
                    if (i + 1 < s.len and s[i + 1] == '"') {
                        try buf.append(a, '"');
                        i += 1;
                    } else {
                        i += 1;
                        break;
                    }
                } else try buf.append(a, s[i]);
            }
            try out.append(a, .{ .text = buf.items, .quoted = true });
        } else {
            while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {
                // An escaped character, even a blank, belongs to the word.
                if (s[i] == '\\' and i + 1 < s.len) {
                    try buf.append(a, s[i]);
                    i += 1;
                }
                try buf.append(a, s[i]);
            }
            try out.append(a, .{ .text = buf.items });
        }
    }
    return out.items;
}

fn atName(args: []const Word) []const u8 {
    const table = [_][2][]const u8{
        .{ "v1", "Version 1 AT&T UNIX" },           .{ "v2", "Version 2 AT&T UNIX" },
        .{ "v3", "Version 3 AT&T UNIX" },           .{ "v4", "Version 4 AT&T UNIX" },
        .{ "v5", "Version 5 AT&T UNIX" },           .{ "v6", "Version 6 AT&T UNIX" },
        .{ "v7", "Version 7 AT&T UNIX" },           .{ "32v", "Version 32V AT&T UNIX" },
        .{ "III", "AT&T System III UNIX" },         .{ "V", "AT&T System V UNIX" },
        .{ "V.1", "AT&T System V Release 1 UNIX" }, .{ "V.2", "AT&T System V Release 2 UNIX" },
        .{ "V.3", "AT&T System V Release 3 UNIX" }, .{ "V.4", "AT&T System V Release 4 UNIX" },
    };
    if (args.len == 0) return "AT&T UNIX";
    for (table) |e| if (std.mem.eql(u8, e[0], args[0].text)) return e[1];
    return "AT&T UNIX";
}

fn standardName(arg: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "-p1003.1", "IEEE Std 1003.1 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-88", "IEEE Std 1003.1-1988 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-90", "ISO/IEC 9945-1:1990 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-96", "ISO/IEC 9945-1:1996 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2001", "IEEE Std 1003.1-2001 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2004", "IEEE Std 1003.1-2004 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2008", "IEEE Std 1003.1-2008 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2024", "IEEE Std 1003.1-2024 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.2", "IEEE Std 1003.2 (\u{201c}POSIX.2\u{201d})" },
        .{ "-isoC", "ISO/IEC 9899:1990 (\u{201c}ISO C90\u{201d})" },
        .{ "-isoC-90", "ISO/IEC 9899:1990 (\u{201c}ISO C90\u{201d})" },
        .{ "-isoC-99", "ISO/IEC 9899:1999 (\u{201c}ISO C99\u{201d})" },
        .{ "-isoC-2011", "ISO/IEC 9899:2011 (\u{201c}ISO C11\u{201d})" },
        .{ "-ansiC", "ANSI X3.159-1989 (\u{201c}ANSI C89\u{201d})" },
        .{ "-ansiC-89", "ANSI X3.159-1989 (\u{201c}ANSI C89\u{201d})" },
        .{ "-svid4", "System V Interface Definition, Fourth Edition (\u{201c}SVID4\u{201d})" },
        .{ "-xpg4", "X/Open Portability Guide Issue 4 (\u{201c}XPG4\u{201d})" },
        .{ "-xpg4.2", "X/Open Portability Guide Issue 4, Version 2 (\u{201c}XPG4.2\u{201d})" },
        .{ "-susv2", "Version 2 of the Single UNIX Specification (\u{201c}SUSv2\u{201d})" },
        .{ "-susv3", "Version 3 of the Single UNIX Specification (\u{201c}SUSv3\u{201d})" },
        .{ "-susv4", "Version 4 of the Single UNIX Specification (\u{201c}SUSv4\u{201d})" },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], arg)) return e[1];
    return if (std.mem.startsWith(u8, arg, "-")) arg[1..] else arg;
}

fn libraryName(arg: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "libc", "Standard C Library (libc, -lc)" },
        .{ "libm", "Math Library (libm, -lm)" },
        .{ "libutil", "System Utilities Library (libutil, -lutil)" },
        .{ "libpthread", "POSIX Threads Library (libpthread, -lpthread)" },
        .{ "librt", "Real-time Library (librt, -lrt)" },
        .{ "libcrypt", "Crypt Library (libcrypt, -lcrypt)" },
        .{ "libdl", "Dynamic Linker Library (libdl, -ldl)" },
        .{ "libz", "Compression Library (libz, -lz)" },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], arg)) return e[1];
    return arg;
}

/// Parses an mdoc(7) page. The tree is owned by the returned document.
pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!md.Document {
    return parseOptions(gpa, source, .{});
}

pub fn parseOptions(gpa: Allocator, source: []const u8, options: man.Options) Allocator.Error!md.Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try a.create(Node);
    root.* = .{ .kind = .document, .line = 1 };
    root.build.open = false;

    var p: Parser = .{ .a = a, .root = root, .cur = root, .target = root, .st = try escape.State.init(a), .keep_comments = options.keep_comments };
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
    try p.endXo();
    try p.endTable();
    try p.endReference();
    try p.flushCode();
    return .{ .arena = arena, .root = root };
}

test "splitWords keeps quotes apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const w = try splitWords(arena_state.allocator(), "Fn open \"const char *p\" Ar x");
    try std.testing.expectEqual(@as(usize, 5), w.len);
    try std.testing.expect(w[2].quoted);
    try std.testing.expectEqualStrings("const char *p", w[2].text);
}
