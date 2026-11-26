# gtroff-zig

Reads roff manual pages into an [md-zig](https://github.com/BearzRobotics/md-zig)
tree, so one renderer ([dkman](https://github.com/BearzRobotics/dkman)) can show
Markdown documents and man pages the same way. Zig 0.17.1; md-zig 0.7.0 is the only dependency.

Status:

| Format | State |
|---|---|
| man(7) | Reads real pages: sections, tagged and bullet paragraphs with indents, code blocks, font macros, links, conditionals (`n`/`t`), `.ds` strings, user-defined macros (`.de`/`.am` with `\$1`), number registers and arithmetic (`.nr`, `\n[x]`, `.if` expressions, string and `d`/`r` tests), line continuations, and tbl tables (formats, `_` rules, `T{ T}` blocks) |
| mdoc(7) | Reads real pages: sections, `.Bl`/`.It` lists (tag, bullet, enum, column), `.Bd`/`.Dl` displays, nested inline macros with punctuation rules, function synopses, `.Rs` references, `.Ex`/`.Rv`/`.St`/`.At`/`.Bx` texts, and the roff requests such pages use (`.ig`, `.de`, `.ds`, `.nr`, conditionals, `.nf`, tbl) |
| Full troff/groff (`\w`, diversions, traps, `.ft`/`.in`/`.ll` layout) | Not done and not planned: such requests are skipped |

```zig
const gtroff = @import("gtroff");

var doc = try gtroff.parseMan(gpa, source);   // an md.Document; parseMdoc for mdoc(7)
defer doc.deinit();
try doc.writeText(gpa, writer, .{ .width = 80 }); // md-zig's terminal renderer
```

Write a tree back out as a man(7) page, and keep `.\"` comments on the way:

```zig
var doc = try gtroff.parseManOptions(gpa, source, .{ .keep_comments = true });
// ... edit the tree ...
try gtroff.writeMan(gpa, &doc, writer, .{});   // or gtroff.toManAlloc(gpa, &doc, .{})
```

Comments are read as HTML comments (`<!-- text -->`, a block or inline node) and
written back as `.\" text`; an md-zig tree parsed from Markdown works too, so
`<!-- note -->` in a `.md` file becomes a roff comment. Off by default, because
renderers would show them. Only whole-line comments are kept, not a `\"` at the
end of a line or one inside a macro definition or skipped block; a comment inside a
heading, term, link or no-fill block moves to just after it. The writer emits `.TH`, `.SH`/`.SS`, `.PP`, `.IP`/`.TP`, `.RS`/`.RE`,
`.nf`/`.fi`, `.TS`/`.TE`, `.UR`/`.UE` and `\f` fonts; raw HTML other than comments
is left out, images become their alt text. Reading what was written gives the
same words, though not always the same layout; the roff itself is normalised, not
the original. A link in a table cell, or in a definition term with other text, is
written as its text and address.

## Untrusted pages

Expansion, nesting and table sizes are limited (see `docs/architecture.md`);
past a limit the construct is cut off. Cap the size of files you read, since
memory still grows with the input. Control characters and invalid UTF-8 are
replaced. Link addresses are kept as written, so for HTML use md-zig's safe mode:

```zig
try doc.writeHtmlOptions(gpa, writer, .{ .safe = true });
```

`writeHtml` and `toHtmlAlloc` pass `javascript:` links through.

## Known issues

- **md-zig bug (not fixed here):** HTML for a table without a header row (every
  mdoc `.Bl -column` list, and some tbl tables) has a closing `</tbody>` with no
  opening `<tbody>`. The cause is in md-zig 0.7.0's HTML renderer (`row` in
  `src/html.zig`) and has to be fixed there.

## Using it

Add it to a project with `zig fetch --save https://github.com/BearzRobotics/gtroff-zig/releases/download/v0.6.0/gtroff-0.6.0.tar.gz`
and import the `gtroff` module.

**C interface (experimental, unstable):** `include/gtroff.h` and `zig build c-api`
(`libgtroff.a`, `libgtroff.so`); `zig build test` runs a C program against it.
It renders a man or mdoc page held in memory to terminal text or HTML; the HTML
is written in safe mode.

Layout follows groff on a terminal: section bodies are indented 7 columns,
subsection headings 3, tagged paragraphs by their `.TP`/`.IP` indent. On a sample
of installed pages, 93-97% of lines that appear in both outputs have the same
indent as `groff -Tutf8`, and the words match (a handful of differences per
thousand, from hyphenation). This was measured with 0.5.0 against groff 1.23 on
one machine; it is not a conformance claim.

The result is an ordinary `md.Document`; HTML output or a GTK viewer work the
same as for Markdown. See `docs/architecture.md` for how roff maps to the tree
and what is lost, and `docs/decisions/` for the reasoning. Tests: `zig build test`.
License: MIT.
