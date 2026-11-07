const std = @import("std");
const gtroff = @import("root.zig");
const testing = std.testing;

fn text(src: []const u8) ![]u8 {
    var doc = try gtroff.parseMan(testing.allocator, src);
    defer doc.deinit();
    return doc.toTextAlloc(testing.allocator, .{ .width = 60 });
}

test "a small page" {
    const out = try text(
        \\.\" comment
        \\.TH LS 1 "June 2026" "tools"
        \\.SH NAME
        \\ls \- list \fBdirectory\fR contents
        \\.SH SYNOPSIS
        \\.B ls
        \\.RI [ option ]...
        \\.SH OPTIONS
        \\.TP
        \\.BR \-a ", " \-\-all
        \\do not ignore entries starting with .
        \\.TP
        \\.B \-l
        \\use a long listing format
        \\.PP
        \\After the list.
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# LS(1)
        \\
        \\## NAME
        \\
        \\       ls - list **directory** contents
        \\
        \\## SYNOPSIS
        \\
        \\       **ls** [_option_]...
        \\
        \\## OPTIONS
        \\
        \\       **-a**, **--all**
        \\              do not ignore entries starting with .
        \\
        \\       **-l** use a long listing format
        \\
        \\       After the list.
        \\
    , out);
}

test "code blocks, bullets, indents, links and conditionals" {
    const out = try text(
        \\.SH EXAMPLES
        \\.nf
        \\$ ls \-l
        \\  total 0
        \\.fi
        \\.IP \(bu 2
        \\first
        \\.IP \(bu 2
        \\second
        \\.RS
        \\.PP
        \\indented
        \\.RE
        \\.if n .SS Terminal only
        \\.if t .SS Typeset only
        \\.ie n plain terminal
        \\.el typeset
        \\.if \n(.zz \{\
        \\.SS Skipped block
        \\.\}
        \\see
        \\.UR http://example.com
        \\the site
        \\.UE .
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\## EXAMPLES
        \\
        \\       $ ls -l
        \\         total 0
        \\
        \\       • first
        \\       • second
        \\
        \\              indented
        \\
        \\   Terminal only
        \\
        \\       plain terminal see the site <http://example.com>.
        \\
    , out);
}

test "headings without arguments take the next line; \\c joins lines" {
    const out = try text(".SH\nSEE ALSO\nfoo\\c\nbar\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("## SEE ALSO\n\n       foobar\n", out);
}

test "malformed input does not crash" {
    const inputs = [_][]const u8{
        ".TH",         ".SH \"unterminated", ".TP\n.TP\n.TP", ".RE\n.RE", ".if n \\{\\\n.SH x", ".de X\nnever ends",
        "\\",          "\\f",                "\\(",           "\\[",      "\\[u",               ".nf\nopen",
        ".TS\nrow\tx", ".UR\n.UE",           ".IP",           ".\\\"",    "\\s",                "\\*",
    };
    for (inputs) |src| {
        const out = try text(src);
        testing.allocator.free(out);
    }
}

fn mdocText(src: []const u8) ![]u8 {
    var doc = try gtroff.parseMdoc(testing.allocator, src);
    defer doc.deinit();
    return doc.toTextAlloc(testing.allocator, .{ .width = 70 });
}

test "mdoc: prologue, name, synopsis, inline macros" {
    const out = try mdocText(
        \\.Dd June 1, 2026
        \\.Dt LS 1
        \\.Os
        \\.Sh NAME
        \\.Nm ls
        \\.Nd list directory contents
        \\.Sh SYNOPSIS
        \\.Nm
        \\.Op Fl al
        \\.Op Fl Fl color Ns = Ns Ar when
        \\.Op Ar file ...
        \\.Sh DESCRIPTION
        \\The
        \\.Nm
        \\utility lists files, see
        \\.Xr stat 2 ,
        \\and
        \\.Pa /etc/passwd .
        \\.Pp
        \\Second
        \\.Dq quoted text
        \\paragraph.
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# LS(1)
        \\
        \\## NAME
        \\
        \\       **ls** — list directory contents
        \\
        \\## SYNOPSIS
        \\
        \\       **ls** [**-al**] [**--color**=_when_] [_file ..._]
        \\
        \\## DESCRIPTION
        \\
        \\       The **ls** utility lists files, see stat(2), and _/etc/passwd_.
        \\
        \\       Second “quoted text” paragraph.
        \\
    , out);
}

test "mdoc: lists, displays, functions and references" {
    const out = try mdocText(
        \\.Dd today
        \\.Dt T 3
        \\.Os
        \\.Sh OPTIONS
        \\.Bl -tag -width Ds
        \\.It Fl a
        \\show all
        \\.It Fl b Ar n
        \\bytes
        \\.El
        \\.Bl -bullet
        \\.It
        \\one
        \\.It
        \\two
        \\.El
        \\.Bd -literal
        \\$ cmd  arg
        \\.Ed
        \\.Dl $ run it
        \\.Sh SEE ALSO
        \\.Fn open "const char *path" "int flags"
        \\.Rs
        \\.%A A. Author
        \\.%T A Title
        \\.%D 1999
        \\.Re
        \\.Sh STANDARDS
        \\.St -p1003.1-2008
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# T(3)
        \\
        \\## OPTIONS
        \\
        \\       **-a**  show all
        \\
        \\       **-b** _n_
        \\               bytes
        \\
        \\       • one
        \\       • two
        \\
        \\       $ cmd  arg
        \\
        \\       $ run it
        \\
        \\## SEE ALSO
        \\
        \\       **open**(_const char *path_, _int flags_)
        \\
        \\       A. Author, A Title, 1999.
        \\
        \\## STANDARDS
        \\
        \\       IEEE Std 1003.1-2008 (“POSIX.1”)
        \\
    , out);
}

test "mdoc: malformed input does not crash" {
    const inputs = [_][]const u8{
        ".Dt",                ".Sh",                    ".Bl", ".It", ".El\n.El", ".Bl -column\n.It a Ta b\n.El", ".Xo\n.Fl a", ".Xc",      ".Op",      ".Fn",      ".Fo f\n.Fa x\n.Fc",
        ".Bd -literal\nopen", ".Rs\n.%A",               ".Re", ".Pf", ".Lk",      ".Ar Fl Ar Fl",                 ".St",        ".Nm\n.Nd", ".Ex -std", ".Rv -std", "\\",
        ".Dq\n.Dq .",         ".Xo foo\n.Xo\n.Xc\n.Xc",
    };
    for (inputs) |src| {
        const out = try mdocText(src);
        testing.allocator.free(out);
    }
}

test "macro definitions are skipped (rst2man style, custom end marker)" {
    const out = try text(
        \\.de1 rstReportMargin
        \\\\$1 \\n[an-margin]
        \\level \\n[rst2man-indent-level]
        \\..
        \\.de X Z
        \\hidden body
        \\..still hidden
        \\.Z
        \\.ig
        \\ignored block
        \\..
        \\.SH NAME
        \\shown
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("## NAME\n\n       shown\n", out);
}

test "tbl tables: formats, rules, text blocks" {
    const out = try text(".TS\nallbox;\nlb rb\nl n.\nName\tCount\n_\napple\t12\nT{\n.BR fputc (),\nsecond line\nT}\t7\n.TE\nafter\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "Name") != null);
    try testing.expect(std.mem.find(u8, out, "apple") != null);
    try testing.expect(std.mem.find(u8, out, "**fputc**(), second line") != null);
    try testing.expect(std.mem.find(u8, out, ".BR") == null);
    try testing.expect(std.mem.find(u8, out, "T{") == null);
    try testing.expect(std.mem.find(u8, out, "after") != null);
}

test "user macros with arguments, redefinition by .am, and line continuation" {
    const out = try text(
        \\.de1 Note
        \\.PP
        \\.B Note:
        \\\\$1 and \\$2 (\\$#)
        \\..
        \\.am Note
        \\more
        \\..
        \\.Note first "second arg"
        \\joined \
        \\line
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("**Note:** first and second arg (2) more joined line\n", out);
}

test "a macro may call itself only a bounded number of times" {
    const out = try text(".de Loop\n.Loop\nx\n..\n.Loop\ndone\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "done") != null);
}

test "font macros inside no-fill blocks keep their spaces" {
    const out = try text(".nf\n.B int f(char *\\fIp\\fP,\n.BR a b\n.fi\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("int f(char *p,\nab\n", out);
}

test "title escapes and superscript markers" {
    const out = try text(".TH FOO\\-BAR\\&.D 5\n.SH NAME\nSection 4.4\\&\\s-2\\u[1]\\d\\s+2 end\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# FOO-BAR.D(5)\n\n## NAME\n\n       Section 4.4[1] end\n", out);
}

test "a comment after a request is not an argument" {
    const out = try text(".de Sp \\\" Vertical space\n.sp\n..\n.SH NAME\none\n.Sp\ntwo\n.SH MORE\nthree\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("## NAME\n\n       one\n\n       two\n\n## MORE\n\n       three\n", out);
}

test "tbl rows of different lengths are padded to the widest" {
    const out = try text(".TS\ntab(|);\nl s l\nl l l.\nTop|X\na|b|c\n.TE\n");
    defer testing.allocator.free(out);
    // All three columns of the second row survive although the first row is short.
    try testing.expect(std.mem.find(u8, out, "c") != null);
    try testing.expect(std.mem.find(u8, out, "b") != null);
}

test "mdoc: Xo and Xc on one line, and an unterminated Xo ends at the next section" {
    const out = try mdocText(
        \\.Dd today
        \\.Dt T 1
        \\.Os
        \\.Sh DESCRIPTION
        \\Given twice
        \\.Xo ( Fl CC ) Xc
        \\disables echo.
        \\.Sh MORE
        \\.It Xo
        \\.Fl a
        \\.Sh LAST
        \\kept
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "Given twice (**-CC**) disables echo.") != null);
    try testing.expect(std.mem.find(u8, out, "## LAST") != null);
    try testing.expect(std.mem.find(u8, out, "kept") != null);
}

test "mdoc: Sm off glues words, An -nosplit is not printed" {
    const out = try mdocText(".Dd d\n.Dt T 1\n.Os\n.Sh SYNOPSIS\n.Op Fl L Sm off Ar port : Ar host Sm on\n.Sh AUTHORS\n.An -nosplit\n.An Jane Doe\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "_port_:_host_") != null or std.mem.find(u8, out, "_port:host_") != null);
    try testing.expect(std.mem.find(u8, out, "nosplit") == null);
    try testing.expect(std.mem.find(u8, out, "Jane Doe") != null);
}

test "registers and conditions: arithmetic, strings, d and r tests, argument count" {
    const out = try text(
        \\.nr a 3
        \\.nr a +2
        \\.nr b \na*2
        \\.if \na==5 five
        \\.if \nb>=10 ten
        \\.if \nb>10 never
        \\.if !\na==4 not-four
        \\.ie 'x'x' same
        \\.el different
        \\.ie 'x'y' wrong
        \\.el other
        \\.ds S str
        \\.if '\*S'str' interpolated
        \\.if d S defined
        \\.if r a reg
        \\.if r zz noreg
        \\.if \n(.g groff
        \\.if '\*[.T]'utf8' utf8
        \\.de M
        \\.if \n(.$>1 many
        \\.if \n(.$==1 one
        \\..
        \\.M x
        \\.M x y
        \\.rr a
        \\.if r a gone
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("five ten not-four same other interpolated defined reg groff\nutf8 one many\n", out);
}

test "a definition may end with dot, blanks, dot (Asciidoctor)" {
    const out = try text(".if \\n[.g] \\{\\\n.  am URL\n.    ad l\n.  .\n.  am MTO\n.    ad l\n.  .\n.\\}\n.SH NAME\nkept\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("## NAME\n\n       kept\n", out);
}
