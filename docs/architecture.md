# Architecture

    source --lines--> man.zig | mdoc.zig (requests, text) --escape.zig (fonts, special characters)--> md.Node tree

| File | Role |
|---|---|
| `root.zig` | Public API: `parseMan`, `parseMdoc` (and their `Options` forms), `writeMan`, `toManAlloc`; the modules `man`, `mdoc`, `escape`, `expr`, `write` |
| `escape.zig` | Splits a line of text into font runs; handles `\f`, `\(xx`, `\[uXXXX]`, `\*`, size and motion escapes |
| `man.zig` | Line by line reader for man(7): requests, paragraphs, lists, code, links |
| `mdoc.zig` | Reader for mdoc(7): block macros, nested inline macros, lists, displays, references; shares conditionals, macros and tbl with `man.zig` |
| `expr.zig` | Numeric expressions for `.nr` and `.if` |
| `write.zig` | Writes a tree as a man(7) page |
| `capi.zig` | Optional C interface |

## Mapping to the md-zig tree

| roff | Node |
|---|---|
| `.TH t s` | heading level 1 `t(s)` |
| `.SH`, `.SS` | heading level 2, 3 (argument or the next line) |
| `.PP .P .LP .HP`, blank line | ends the paragraph |
| `.TP [n]`, `.TQ`, `.IP tag [n]` | `deflist` with `deflist_term` and `deflist_def` (loose); the def gets `indent` = n (default 7), so a short tag shares a line with its text |
| `.IP \(bu` | bullet `list` with `item`s |
| `.RS n` / `.RE` | `block_quote` with `indent` = n columns (nested up to 16 deep; `.RS 0` adds none) |
| `.nf`/`.fi`, `.EX`/`.EE` | `code_block`; `.SH`/`.SS` end it, tables inside it split it, and a link inside it becomes `text <address>` |
| `.TS`/`.TE` | `table`: column letters give alignment (`l r c n`) and bold/italic, `T{ T}` blocks are cells of formatted text, the first row is the header when a `_` rule follows it or its columns are bold; boxes and rules are not drawn; short rows are padded |
| `.B .I .BR .BI ...`, `\fB \fI` | `strong`, `emph` (nested for bold italic); constant width becomes `code` |
| `.UR/.UE`, `.MT/.ME` | `link` (escapes in the address are read; the address is not filtered) |
| `.TH` date, source, manual | not shown; kept in the `title` field of the level 1 heading, one per line, for `writeMan` |
| `.br` | `linebreak` |

## mdoc mapping

| mdoc | Node |
|---|---|
| `.Dt T S` | heading level 1 `T(S)`; `.Dd`, `.Os` are skipped |
| `.Sh`, `.Ss` | heading level 2, 3 |
| `.Pp` | ends the paragraph |
| `.Bl -tag/-hang/-ohang/-inset`, `.It` | `deflist` (the `.It` line is the term) |
| `.Bl -bullet/-dash/-hyphen/-item`, `-enum` | bullet / ordered `list` |
| `.Bl -column`, `.It a Ta b` | `table` without a header row |
| `.Bd -literal/-unfilled`, `.Dl`, `.D1` | `code_block` |
| `.Fl .Cm .Ic .Sy .Nm` / `.Ar .Pa .Em .Va` / `.Li` | `strong` / `emph` / `code` |
| `.Xr n s` | text `n(s)` |
| `.Lk`, `.Mt` | `link` |
| `.Op .Dq .Sq .Pq .Bq .Aq` and the `.Oo/.Oc` pairs | bracket text around the nested content |
| `.Rs` ... `.Re` | one paragraph: authors, title, journal, date |

Nested macros follow mdoc(7): a callable macro name inside the arguments starts a
new macro, opening punctuation sticks to the next word, closing punctuation to
the previous one, `\&` makes a name literal. `.Xo`/`.Xc` join lines. In SYNOPSIS,
`.Nm`, `.Ft`, `.Fd`, `.In`, `.Vt`, `.Fn`, `.Fo` and `.Cd` start a new line.

`.Sm` turns the blanks between words off and on; `-width` sets the indent of a
tag list. The roff requests `.ig`, `.de`/`.am`, `.ds`, `.nr`/`.rr`, conditionals,
`.br`, `.sp`, `.nf`/`.fi` and `.TS` work as in man pages, and user macros run.
Lines of a table cell are read as mdoc.

Not supported: `.Db`, `.Bk`, `-offset`/`-compact`, column list widths, `.Hf`,
`.Tg`; unknown macros are ignored.

## User macros

`.de`, `.am` and their variants (`.de1`, `.dei`, ...) store the body in copy mode
(`\\` becomes `\`); a later `.NAME args` runs it with `\$1`..`\$9`, `\$*` and
`\$#` replaced. Built-in requests take precedence over user macros of the same
name, nesting is limited to 16 calls, and `.ig` blocks are skipped.

## Registers and conditions

`.nr name value` (a leading `+`/`-` is relative), `.rr`, and `\n[x]`, `\n(xx`,
`\nx`, `\n+x` are evaluated. `.if`/`.ie` accept `n o` (true), `t e` (false), `d name`,
`r name`, `c ch`, `'a'b'` string comparison and numeric expressions (true when
greater than zero), with `!`. Expressions (`expr.zig`) are evaluated left to
right without precedence, as in roff; units are dropped. Predefined: `.g` = 1
(groff), `.$` = argument count of the running macro, string `.T` = `utf8`.

## Limits for untrusted input

A page cannot make a reader use unbounded time, memory or stack. When a limit is
reached the rest of that construct is cut off and reading goes on; there is no
error.

| What | Limit |
|---|---|
| Nested macro calls | 16 |
| Lines run by all macro calls in a page | 100,000 |
| Bytes of those lines after arguments are filled in | 4 MiB |
| `.ds` expansion per page (bytes, plus one per use) | 4 MiB |
| Conditionals chained on one line | 32 |
| `.ie` blocks waiting for `.el` | 32 |
| Parentheses in an expression | 64 |
| mdoc enclosure macros nested on a line | 32 |
| `.RS` and `.Bl` nesting | 16 |
| Tables inside the `T{` blocks of tables | 2 |
| Cells in a table row (more are joined into the last) | 64 |
| Empty cells added to even out table rows, per page | 65,536 |

These limits bound expansion, not the size of the input: memory still grows with
the page. A caller that reads untrusted files should cap their size.

The limits are generous. A page written to use them up can be small and still
need a lot of memory: measured trees were about 1.5 GB from a 4 KB man or mdoc
page (a self calling macro making many font changes), 1.2 GB from 356 bytes of
mdoc column cells, and 550 MB from 168 bytes of table rows made by a macro. A
caller that needs a lower ceiling must also limit the memory of the reader, for
example with its own allocator.

Control characters other than tab, and invalid UTF-8, are replaced with U+FFFD,
and `\[uXXXX]` cannot produce them. Link addresses are kept as written: use
md-zig's `writeHtmlOptions` with `.safe = true` for HTML from untrusted pages
(the C interface does).

## Known issue in md-zig

A table without a header row (all mdoc column lists, and some tbl tables) is
written to HTML with a closing `</tbody>` that has no opening tag. This is a bug
in md-zig 0.7.0's HTML renderer, not in gtroff-zig.

## Section layout

Each `.SH` heading is followed by a `block_quote` with `indent` 7 holding the
section body; `.SS` puts its heading in a quote of 3 and its body in a nested
quote of 4. Code blocks from `.nf`/`.EX` are flush with the surrounding indent.
mdoc uses the same layout.

## Known losses

The tree has no tab stops, page headers or footers, and text is not justified
(groff justifies). Indents are columns taken from `.TP`/`.IP`/`.RS` and mdoc
`-width`; other indent requests (`.in`, `.ti`, `.ll`) are ignored, as are `.ft`
and diversions. Comments inside macro definitions and skipped blocks are not
kept even with `keep_comments`; one inside a heading, term, link or no-fill
block moves to just after it. `.so` is ignored by the library (dkman follows redirects). Boxes
and rules of tbl tables are not drawn. Hanging indents of wrapped synopsis lines
are not reproduced.
