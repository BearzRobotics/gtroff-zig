//! Fuzz tests: pages put together from roff, mdoc and Markdown pieces, mixed
//! with raw bytes, go through both readers, the renderers and `writeMan`.
//!
//! `zig build test` runs a fixed set of seeds, so a failure repeats; it prints
//! the seed and the input. For a longer search with Zig's coverage guided
//! fuzzer, run
//!
//!     zig build test --fuzz=100K -Doptimize=ReleaseSafe
//!
//! (leave out `=100K` to run until stopped). It needs the optimised build: with
//! Zig 0.17.1 a Debug build stops with "pcs_len was zero". Give each input that
//! fails a regression test in `regress_tests.zig`.
//!
//! A hang is not reported as a failure: the run just does not finish.
//!
//! The checks, beyond not crashing and not leaking:
//!   - text in the tree and all output is valid UTF-8 without control characters
//!   - a page's tree stays within `max_tree_bytes`
//!   - what `writeMan` writes can be read again
//!   - from Markdown, `writeMan` writes no request that it does not use itself

const std = @import("std");
const md = @import("md");
const gtroff = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Cases run by `zig build test`.
const seeds = 1500;
/// Longest script that makes an input (see `build`).
const max_script = 512;
/// Most memory the tree of a generated page may take. This catches growth that
/// escapes the limits; it is not the most the limits allow, which inputs written
/// for the purpose can take to about 1.5 GB (see docs/architecture.md).
const max_tree_bytes = 512 << 20;

const pieces = [_][]const u8{
    // Lines and words.
    "\n",        "\n.",    " ",                      "word",          "-",                    ".",                 ",",
    "\"",        "'",      "|",                      "\t",            "\r\n",                 "\\",                "\\\n",
    // roff requests and escapes.
    ".TH ",      ".SH ",   ".SS ",                   ".PP\n",         ".TP\n",                ".IP ",              ".RS\n",
    ".RE ",      ".B ",    ".BR ",                   ".SY ",          ".OP ",                 ".nf\n",             ".fi\n",
    ".br\n",     ".sp\n",  ".UR ",                   ".UE ",          ".MT ",                 ".ME\n",             ".so x\n",
    ".TS\n",     ".TE\n",  "T{\n",                   "T}",            ".T&\n",                "l r c.\n",          "tab(;);\n",
    "allbox;\n", "_\n",    "\\{",                    "\\}",           ".if n ",               ".ie t ",            ".el ",
    ".if !",     "'a'a' ", "(1 + 2) ",               ".de X\n",       "..\n",                 ".X ",               ".am X\n",
    ".ig\n",     "\\\\$1", "\\\\$@",                 ".ds a ",        "\\*a",                 "\\*[a]",            ".nr r +1\n",
    "\\n(.$",    "\\n+r",  ".\\\" ",                 "\\\"",          "\\fB",                 "\\fP",              "\\f[",
    "\\(",       "\\(bu",  "\\[u001b]",              "\\[",           "\\s",                  "\\h'",              "\\m[",
    "\\-",       "\\&",    "\\c",                    "999999999999",
    // mdoc.
     ".Dt T 1\n",            ".Sh ",              ".Ss ",
    ".Pp\n",     ".Nm ",   ".Fl ",                   ".Ar ",          ".Op ",                 "Op ",               "Pq ",
    "Ns ",       "Fl ",    "Ar ",                    ".Bl -bullet\n", ".Bl -tag -width Ds\n", ".Bl -column a b\n", ".It ",
    "Ta ",       ".El\n",  ".Xo\n",                  ".Xc ",          ".Bd -literal\n",       ".Ed\n",             ".Sm off\n",
    ".Xr ",      ".Eo ",   ".Ec ",                   ".Fn ",          ".Fo ",                 ".Fc\n",             ".Lk ",
    ".Rs\n",     ".%T ",   ".Re\n",                  ".Ex -std ",     ".Bf Em\n",
    // Markdown.
                "# ",                "## ",
    "> ",        "- ",     "1. ",                    "```\n",         "`",                    "*",                 "**",
    "[x](",      ")",      "| a | b |\n|---|---|\n", ": ",            "&#10;",                "&#13;",             "<!--",
    "-->",       "--!>",   "<b>",                    "---\n",         "[^n]",                 "[^n]: ",            "javascript:",
};

/// Turns any bytes into an input: most pick a piece, the highest values copy
/// the byte that follows as it is.
fn build(out: *std.ArrayList(u8), gpa: Allocator, script: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < script.len) : (i += 1) {
        const b = script[i];
        if (b >= 240 and i + 1 < script.len) {
            i += 1;
            try out.append(gpa, script[i]);
        } else try out.appendSlice(gpa, pieces[b % pieces.len]);
    }
}

/// Valid UTF-8 with no control characters but tab and newline.
fn expectClean(s: []const u8) !void {
    const view = std.unicode.Utf8View.init(s) catch return error.InvalidUtf8;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\t' or cp == '\n') continue;
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.ControlCharacter;
    }
}

/// Checks a tree read from a man or mdoc page, and everything made from it.
fn checkTree(gpa: Allocator, doc: *const md.Document) !void {
    try testing.expect(doc.arena.queryCapacity() <= max_tree_bytes);
    var walker = md.Walker.init(doc.root);
    while (walker.next()) |ev| {
        if (!ev.entering) continue;
        try expectClean(ev.node.literal);
        try expectClean(ev.node.title);
    }

    for ([_]usize{ 0, 24 }) |width| {
        const text = try doc.toTextAlloc(gpa, .{ .width = width });
        defer gpa.free(text);
        try expectClean(text);
    }
    const html = try doc.toHtmlAlloc(gpa);
    defer gpa.free(html);
    try expectClean(html);

    const man = gtroff.toManAlloc(gpa, doc, .{}) catch |e| switch (e) {
        error.TooDeep => return,
        else => return e,
    };
    defer gpa.free(man);
    try expectClean(man);
    var back = try gtroff.parseManOptions(gpa, man, .{ .keep_comments = true });
    defer back.deinit();
}

/// The requests `writeMan` uses.
const written_requests = [_][]const u8{
    "TH", "SH", "SS", "PP", "IP", "TP", "TQ", "RS", "RE", "br", "nf", "fi", "TS", "TE", "UR", "UE",
};

/// No text of a Markdown document may become any other request.
fn checkWritten(man: []const u8) !void {
    var lines = std.mem.splitScalar(u8, man, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or (line[0] != '.' and line[0] != '\'')) continue;
        if (std.mem.startsWith(u8, line, ".\\\"")) continue; // a comment
        const end = std.mem.findScalar(u8, line, ' ') orelse line.len;
        const known = line[0] == '.' and for (written_requests) |name| {
            if (std.mem.eql(u8, line[1..end], name)) break true;
        } else false;
        if (!known) {
            std.debug.print("writeMan wrote the request line: {s}\n", .{line});
            return error.UnexpectedRequest;
        }
    }
}

fn checkInput(gpa: Allocator, input: []const u8) !void {
    for ([_]bool{ false, true }) |keep| {
        const options: gtroff.Options = .{ .keep_comments = keep };
        var man = try gtroff.parseManOptions(gpa, input, options);
        defer man.deinit();
        try checkTree(gpa, &man);
        var mdoc = try gtroff.parseMdocOptions(gpa, input, options);
        defer mdoc.deinit();
        try checkTree(gpa, &mdoc);
    }

    var doc = md.Document.parse(gpa, input, .{ .extensions = md.Extensions.all }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // over one of md-zig's own limits
    };
    defer doc.deinit();
    const written = gtroff.toManAlloc(gpa, &doc, .{}) catch |e| switch (e) {
        error.TooDeep => return,
        else => return e,
    };
    defer gpa.free(written);
    try checkWritten(written);
    var back = try gtroff.parseMan(gpa, written);
    defer back.deinit();
}

fn checkScript(script: []const u8) !void {
    const gpa = testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try build(&input, gpa, script);
    checkInput(gpa, input.items) catch |e| {
        std.debug.print("fuzz input ({d} bytes): \"{f}\"\n", .{ input.items.len, std.zig.fmtString(input.items) });
        return e;
    };
}

test "fuzz: fixed seeds" {
    var script: [max_script]u8 = undefined;
    for (0..seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        const len = random.intRangeAtMost(usize, 1, max_script);
        random.bytes(script[0..len]);
        checkScript(script[0..len]) catch |e| {
            std.debug.print("fuzz seed {d} failed\n", .{seed});
            return e;
        };
    }
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var script: [max_script]u8 = undefined;
    const len = smith.slice(&script);
    try checkScript(script[0..len]);
}

test "fuzz: coverage guided" {
    try testing.fuzz({}, fuzzOne, .{});
}
