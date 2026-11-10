//! gtroff-zig: reads roff manual pages (man(7), later mdoc(7)) into an
//! md-zig tree, so one renderer can show Markdown and man pages alike.

const std = @import("std");
const md = @import("md");
const Allocator = std.mem.Allocator;

pub const escape = @import("escape.zig");
pub const man = @import("man.zig");
pub const mdoc = @import("mdoc.zig");
pub const expr = @import("expr.zig");
pub const write = @import("write.zig");

/// Options for the readers: `keep_comments` keeps `.\"` lines as HTML comments.
pub const Options = man.Options;
pub const parseManOptions = man.parseOptions;
pub const parseMdocOptions = mdoc.parseOptions;

/// Writes a document as a man(7) page (see `write.zig`).
pub const writeMan = write.writeMan;
pub const toManAlloc = write.toManAlloc;
pub const WriteOptions = write.Options;

/// Parses a man(7) page into an md-zig document (see `man.zig`).
pub const parseMan = man.parse;

/// Parses an mdoc(7) page into an md-zig document (see `mdoc.zig`).
pub const parseMdoc = mdoc.parse;

test {
    _ = @import("escape.zig");
    _ = @import("man.zig");
    _ = @import("mdoc.zig");
    _ = @import("expr.zig");
    _ = @import("tests.zig");
    _ = @import("write_tests.zig");
}
