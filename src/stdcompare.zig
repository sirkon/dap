//! Internal string comparison helpers. Not part of the public `dap` surface.

const std = @import("std");

/// Computes the Levenshtein edit distance between `a` and `b` and returns it as
/// a `usize`. The distance counts single-character insertions, deletions, and
/// substitutions needed to turn `a` into `b`.
pub fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    const allocator = std.heap.page_allocator;
    var prev = allocator.alloc(usize, b.len + 1) catch return @max(a.len, b.len);
    defer allocator.free(prev);
    var curr = allocator.alloc(usize, b.len + 1) catch return @max(a.len, b.len);
    defer allocator.free(curr);

    for (prev, 0..) |*cell, j| cell.* = j;

    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        std.mem.swap([]usize, &prev, &curr);
    }

    return prev[b.len];
}

test "levenshtein identical strings" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("", ""));
    try std.testing.expectEqual(@as(usize, 0), levenshtein("kitten", "kitten"));
}

test "levenshtein empty vs non-empty" {
    try std.testing.expectEqual(@as(usize, 5), levenshtein("", "hello"));
    try std.testing.expectEqual(@as(usize, 5), levenshtein("hello", ""));
}

test "levenshtein classic kitten/sitting" {
    try std.testing.expectEqual(@as(usize, 3), levenshtein("kitten", "sitting"));
}

test "levenshtein single edit" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("dry_run", "dry-run"));
    try std.testing.expectEqual(@as(usize, 1), levenshtein("--help", "-help"));
}

test "levenshtein full replacement" {
    try std.testing.expectEqual(@as(usize, 3), levenshtein("abc", "xyz"));
}

test "levenshtein is symmetric" {
    try std.testing.expectEqual(levenshtein("flaw", "lawn"), levenshtein("lawn", "flaw"));
}
