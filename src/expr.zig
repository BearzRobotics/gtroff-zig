//! roff numeric expressions, as used by `.nr` and `.if`/`.ie`.
//!
//! Operators `+ - * / %` and the comparisons `< > <= >= = ==` and the logical
//! `&` and `:` are evaluated strictly left to right with no precedence; only
//! parentheses group (roff has no operator precedence). A number may carry a
//! unit letter (`i c P m n p u v f`), which is ignored: lengths are kept in the
//! unit they were written in. Division by zero is an error, not a crash.

const std = @import("std");

pub const Error = error{ Syntax, DivisionByZero };

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(self: *const Parser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn number(self: *Parser) Error!f64 {
        const start = self.i;
        while (self.i < self.s.len and (std.ascii.isDigit(self.s[self.i]) or self.s[self.i] == '.')) self.i += 1;
        if (self.i == start) return error.Syntax;
        const v = std.fmt.parseFloat(f64, self.s[start..self.i]) catch return error.Syntax;
        // A unit letter after the number only says which unit; drop it.
        if (self.i < self.s.len and std.mem.indexOfScalar(u8, "icPmnpuvf", self.s[self.i]) != null) self.i += 1;
        return v;
    }

    fn unary(self: *Parser) Error!f64 {
        const c = self.peek() orelse return error.Syntax;
        switch (c) {
            '+' => {
                self.i += 1;
                return self.unary();
            },
            '-' => {
                self.i += 1;
                return -(try self.unary());
            },
            '!' => {
                self.i += 1;
                return if ((try self.unary()) == 0) 1 else 0;
            },
            '(' => {
                self.i += 1;
                const v = try self.expr();
                if (self.peek() != ')') return error.Syntax;
                self.i += 1;
                return v;
            },
            else => return self.number(),
        }
    }

    fn expr(self: *Parser) Error!f64 {
        var v = try self.unary();
        while (self.peek()) |c| {
            const two: ?u8 = if (self.i + 1 < self.s.len) self.s[self.i + 1] else null;
            var width: usize = 1;
            const op: u8 = switch (c) {
                '+', '-', '*', '/', '%', '&', ':' => c,
                '<' => if (two == '=') blk: {
                    width = 2;
                    break :blk 'l';
                } else '<',
                '>' => if (two == '=') blk: {
                    width = 2;
                    break :blk 'g';
                } else '>',
                '=' => if (two == '=') blk: {
                    width = 2;
                    break :blk '=';
                } else '=',
                else => break,
            };
            self.i += width;
            const r = try self.unary();
            v = switch (op) {
                '+' => v + r,
                '-' => v - r,
                '*' => v * r,
                '/' => if (@trunc(r) == 0) return error.DivisionByZero else @trunc(v) / @trunc(r),
                '%' => if (@trunc(r) == 0) return error.DivisionByZero else @mod(@trunc(v), @trunc(r)),
                '<' => if (v < r) 1 else 0,
                '>' => if (v > r) 1 else 0,
                'l' => if (v <= r) 1 else 0,
                'g' => if (v >= r) 1 else 0,
                '=' => if (v == r) 1 else 0,
                '&' => if (v > 0 and r > 0) 1 else 0,
                ':' => if (v > 0 or r > 0) 1 else 0,
                else => unreachable,
            };
        }
        return v;
    }
};

/// Value of the whole of `s` as an integer (fractions are truncated).
pub fn eval(s: []const u8) Error!i64 {
    var p: Parser = .{ .s = std.mem.trim(u8, s, " \t") };
    const v = try p.expr();
    if (p.i != p.s.len) return error.Syntax;
    if (!std.math.isFinite(v) or @abs(v) > 1e12) return error.Syntax;
    return @intFromFloat(@trunc(v));
}

/// Length of the expression at the start of `s` (up to the first blank outside
/// parentheses), for conditions where the body follows after a blank.
pub fn tokenLen(s: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        // `\n(xx`, `\n[name]`, `\*x`: the parenthesis belongs to the name.
        if (c == '\\' and i + 1 < s.len and (s[i + 1] == 'n' or s[i + 1] == '*' or s[i + 1] == '$')) {
            i += 2;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            if (i < s.len and s[i] == '(') {
                i += 2;
            } else if (i < s.len and s[i] == '[') {
                while (i < s.len and s[i] != ']') i += 1;
            }
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if ((c == ' ' or c == '\t') and depth == 0) return i;
    }
    return s.len;
}

test "left to right, no precedence" {
    try std.testing.expectEqual(@as(i64, 9), try eval("1+2*3"));
    try std.testing.expectEqual(@as(i64, 7), try eval("1+(2*3)"));
    try std.testing.expectEqual(@as(i64, 5), try eval("10/2"));
    try std.testing.expectEqual(@as(i64, 1), try eval("7%3"));
    try std.testing.expectEqual(@as(i64, -3), try eval("-3"));
    try std.testing.expectEqual(@as(i64, 4), try eval("3.5n+1"));
}

test "comparisons and logic" {
    try std.testing.expectEqual(@as(i64, 1), try eval("3>2"));
    try std.testing.expectEqual(@as(i64, 0), try eval("3<=2"));
    try std.testing.expectEqual(@as(i64, 1), try eval("2==2"));
    try std.testing.expectEqual(@as(i64, 1), try eval("1&2"));
    try std.testing.expectEqual(@as(i64, 0), try eval("0&2"));
    try std.testing.expectEqual(@as(i64, 1), try eval("0:2"));
    try std.testing.expectEqual(@as(i64, 1), try eval("!0"));
}

test "errors instead of crashes" {
    try std.testing.expectError(error.DivisionByZero, eval("1/0"));
    try std.testing.expectError(error.DivisionByZero, eval("1%0"));
    try std.testing.expectError(error.Syntax, eval(""));
    try std.testing.expectError(error.Syntax, eval("abc"));
    try std.testing.expectError(error.Syntax, eval("(1+2"));
    try std.testing.expectError(error.Syntax, eval("1+"));
    try std.testing.expectError(error.Syntax, eval("99999999999999999999*99999999999999999999"));
}

test "tokenLen skips register and string names" {
    try std.testing.expectEqual(@as(usize, 5), tokenLen("\\n(.g body"));
    try std.testing.expectEqual(@as(usize, 7), tokenLen("\\n(.$>1 many"));
    try std.testing.expectEqual(@as(usize, 9), tokenLen("\\n[a-b]>1 x"));
}

test "tokenLen stops at a blank outside parentheses" {
    try std.testing.expectEqual(@as(usize, 7), tokenLen("(1 + 2) body"));
    try std.testing.expectEqual(@as(usize, 3), tokenLen("1>0 body"));
    try std.testing.expectEqual(@as(usize, 2), tokenLen("1>"[0..2]));
}
