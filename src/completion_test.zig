//! Shell integration checks for generated completion scripts.
//!
//! These tests are deliberately kept out of `zig build test`: they spawn real
//! shells. Run them with `zig build completion-test`. A shell that is not
//! installed is skipped with a visible notice; install all three for a full
//! run.

const std = @import("std");
const builtin = @import("builtin");
const dap = @import("dap");

const APP_NAME = "dap-completion-test";
const IDENT = "dap_completion_test";

const Mode = dap.Enumeration(.{
    .red = dap.Enum{},
    .green = dap.Enum{},
});

const CLI = dap.generate(dap.App{
    .name = "dap completion test",
    .help = "Completion integration test.",
}, .{
    .verbose = dap.Flag(bool){ .help = "Verbose." },
    .description = dap.Flag(dap.String){ .short = "d", .help = "Description of context." },
    .version = dap.Flag(bool){ .default = dap.Default(bool){ .direct = false } },
    .color = dap.Flag(Mode){ .long = "color", .help = "Color." },
    .config = dap.Flag(dap.String){ .long = "config", .help = "Config." },
    .run = dap.Command(.{ .help = "Run." }, .{
        .deep = dap.Command(.{ .help = "Deep." }, .{}),
    }),
    .pick = dap.Command(.{ .synonym = "p", .help = "Pick." }, .{
        .kind = dap.Argument(Mode){ .help = "Kind." },
        .note = dap.Flag(dap.String){ .long = "note", .help = "Note." },
    }),
});

fn writeScripts(tmp: *std.testing.TmpDir) !void {
    const scripts = [_]struct { shell: dap.CompletionShell, path: []const u8 }{
        .{ .shell = .bash, .path = "dap_completion_test.bash" },
        .{ .shell = .zsh, .path = "dap_completion_test.zsh" },
        .{ .shell = .fish, .path = "dap_completion_test.fish" },
    };

    for (scripts) |entry| {
        const script = try CLI.completion(std.testing.allocator, APP_NAME, entry.shell);
        defer std.testing.allocator.free(script);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry.path, .data = script });
    }
}

fn runShell(cwd: std.Io.Dir, argv: []const []const u8) !?std.process.RunResult {
    return std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn expectSuccess(comptime label: []const u8, res: std.process.RunResult) !void {
    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("completion-test: {s} failed ({d})\n", .{ label, code });
                std.debug.print("{s}", .{res.stderr});
                return error.ShellFailed;
            }
        },
        else => {
            std.debug.print("completion-test: {s} did not exit normally\n", .{label});
            return error.ShellFailed;
        },
    }
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Compares `got` (newline-separated) with `want` as sets, so the shell's
/// ordering does not matter.
fn expectCandidateSet(
    allocator: std.mem.Allocator,
    comptime label: []const u8,
    got: []const u8,
    want: []const []const u8,
) !void {
    var got_list: std.ArrayList([]const u8) = .empty;
    defer got_list.deinit(allocator);

    const trimmed = std.mem.trimEnd(u8, got, "\r\n");
    if (trimmed.len != 0) {
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try got_list.append(allocator, line);
        }
    }

    const got_sorted = try allocator.dupe([]const u8, got_list.items);
    defer allocator.free(got_sorted);
    const want_sorted = try allocator.dupe([]const u8, want);
    defer allocator.free(want_sorted);
    std.mem.sort([]const u8, got_sorted, {}, lessThanString);
    std.mem.sort([]const u8, want_sorted, {}, lessThanString);

    try std.testing.expectEqual(want_sorted.len, got_sorted.len);
    for (want_sorted, got_sorted) |want_item, got_item| {
        std.testing.expectEqualStrings(want_item, got_item) catch |err| {
            std.debug.print("completion-test: case '{s}' mismatch\n", .{label});
            return err;
        };
    }
}

/// Compares `got` (newline-separated) with `want` in order.
fn expectLinesExact(
    allocator: std.mem.Allocator,
    comptime label: []const u8,
    got: []const u8,
    want: []const []const u8,
) !void {
    var got_list: std.ArrayList([]const u8) = .empty;
    defer got_list.deinit(allocator);

    const trimmed = std.mem.trimEnd(u8, got, "\r\n");
    if (trimmed.len != 0) {
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try got_list.append(allocator, line);
        }
    }

    try std.testing.expectEqual(want.len, got_list.items.len);
    for (want, got_list.items) |want_item, got_item| {
        std.testing.expectEqualStrings(want_item, got_item) catch |err| {
            std.debug.print("completion-test: case '{s}' mismatch\n", .{label});
            return err;
        };
    }
}

fn zshExpectDisplays(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    words: []const u8,
    want: []const []const u8,
) !void {
    const code = try std.fmt.allocPrint(
        std.testing.allocator,
        \\compdef() {{ :; }}
        \\compadd() {{
        \\    local d
        \\    for d in "${{displays[@]}}"; do print -r -- "$d"; done
        \\}}
        \\source ../dap_completion_test.zsh
        \\words=({s})
        \\CURRENT=${{#words}}
        \\PREFIX=${{words[CURRENT]}}
        \\_dap_completion_test
    ,
        .{words},
    );
    defer std.testing.allocator.free(code);

    const maybe = try runShell(cwd, &.{ "zsh", "-f", "-c", code });
    const res = maybe orelse return error.SkipZigTest;
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess(label, res);
    try expectLinesExact(std.testing.allocator, label, res.stdout, want);
}

fn bashComplete(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    words: []const u8,
    cword: u8,
) !?[]u8 {
    const code = try std.fmt.allocPrint(
        std.testing.allocator,
        \\. ../dap_completion_test.bash
        \\COMP_WORDS=({s})
        \\COMP_CWORD={d}
        \\_dap_{s}
        \\if (( ${{#COMPREPLY[@]}} )); then
        \\    printf '%s\n' "${{COMPREPLY[@]}}"
        \\fi
    ,
        .{ words, cword, IDENT },
    );
    defer std.testing.allocator.free(code);

    const maybe = try runShell(cwd, &.{ "bash", "-c", code });
    const res = maybe orelse return null;
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess(label, res);
    return try std.testing.allocator.dupe(u8, res.stdout);
}

fn bashExpect(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    words: []const u8,
    cword: u8,
    want: []const []const u8,
) !void {
    const got = try bashComplete(cwd, label, words, cword) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(got);
    try expectCandidateSet(std.testing.allocator, label, got, want);
}

fn bashExpectOrder(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    words: []const u8,
    cword: u8,
    want: []const []const u8,
) !void {
    const got = try bashComplete(cwd, label, words, cword) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(got);
    try expectLinesExact(std.testing.allocator, label, got, want);
}

fn fishComplete(cwd: std.Io.Dir, comptime label: []const u8, line: []const u8) !?[]u8 {
    const code = try std.fmt.allocPrint(
        std.testing.allocator,
        "source ../dap_completion_test.fish; complete -C '{s}'",
        .{line},
    );
    defer std.testing.allocator.free(code);

    const maybe = try runShell(cwd, &.{ "fish", "--no-config", "-c", code });
    const res = maybe orelse return null;
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess(label, res);
    return try std.testing.allocator.dupe(u8, res.stdout);
}

fn fishExpect(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    line: []const u8,
    want: []const []const u8,
) !void {
    const got = try fishComplete(cwd, label, line) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(got);

    var candidates: std.ArrayList(u8) = .empty;
    defer candidates.deinit(std.testing.allocator);
    const trimmed = std.mem.trimEnd(u8, got, "\r\n");
    if (trimmed.len != 0) {
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        while (lines.next()) |line_text| {
            if (line_text.len == 0) continue;
            const candidate = if (std.mem.indexOfScalar(u8, line_text, '\t')) |tab|
                line_text[0..tab]
            else
                line_text;
            try candidates.appendSlice(std.testing.allocator, candidate);
            try candidates.append(std.testing.allocator, '\n');
        }
    }

    try expectCandidateSet(std.testing.allocator, label, candidates.items, want);
}

fn fishExpectLines(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    line: []const u8,
    want: []const []const u8,
) !void {
    const got = try fishComplete(cwd, label, line) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(got);
    try expectLinesExact(std.testing.allocator, label, got, want);
}

test "completion integration: registration uses app_name" {
    const shells = [_]dap.CompletionShell{ .bash, .zsh, .fish };
    inline for (shells) |shell| {
        const script = try CLI.completion(std.testing.allocator, APP_NAME, shell);
        defer std.testing.allocator.free(script);

        switch (shell) {
            .bash => {
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, script, "complete -o default"));
                try std.testing.expect(std.mem.endsWith(
                    u8,
                    script,
                    "complete -o default -F _dap_dap_completion_test 'dap-completion-test'\n",
                ));
            },
            .zsh => {
                try std.testing.expect(std.mem.startsWith(u8, script, "#compdef dap-completion-test\n"));
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, script, "compdef _dap_completion_test"));
                try std.testing.expect(std.mem.indexOf(
                    u8,
                    script,
                    "compdef _dap_completion_test 'dap-completion-test'",
                ) != null);
            },
            .fish => {
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, script, "complete -c "));
                try std.testing.expect(std.mem.endsWith(
                    u8,
                    script,
                    "complete -c 'dap-completion-test' -a '(__dap_dap_completion_test_complete)' -k\n",
                ));
            },
        }
    }

    const mine = try CLI.completion(std.testing.allocator, APP_NAME, .bash);
    defer std.testing.allocator.free(mine);
    const other = try CLI.completion(std.testing.allocator, "other-app", .bash);
    defer std.testing.allocator.free(other);

    try std.testing.expect(std.mem.indexOf(u8, other, "_dap_other_app") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "_dap_dap_completion_test") == null);
    try std.testing.expect(std.mem.indexOf(u8, other, "'other-app'") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "'dap-completion-test'") == null);
    try std.testing.expect(!std.mem.eql(u8, mine, other));
}

test "completion integration: bash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScripts(&tmp);

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);

    const syntax = try runShell(work, &.{ "bash", "-n", "../dap_completion_test.bash" });
    const res = syntax orelse {
        std.debug.print("completion-test: bash not found; skipping bash checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("bash -n", res);

    try bashExpect(work, "root flag prefix", "dap-completion-test --ver", 1, &.{ "--verbose", "--version" });
    try bashExpect(work, "child command", "dap-completion-test ru", 1, &.{"run"});
    try bashExpect(work, "child level candidates", "dap-completion-test run de", 2, &.{"deep"});
    try bashExpect(work, "ancestor flag on child", "dap-completion-test run --ver", 2, &.{ "--verbose", "--version" });
    try bashExpect(work, "enum separate value", "dap-completion-test --color ''", 2, &.{ "red", "green" });
    try bashExpect(work, "enum eq with text", "dap-completion-test --color = r", 3, &.{"red"});
    try bashExpect(work, "enum eq empty", "dap-completion-test --color =", 2, &.{ "=red", "=green" });
    try bashExpect(work, "enum full form", "dap-completion-test --color=r", 1, &.{ "--color=red", "--color=green" });
    try bashExpect(work, "non-enum value", "dap-completion-test --config ''", 2, &.{});
    try bashExpect(work, "literal after terminator", "dap-completion-test -- x", 2, &.{});

    try bashExpectOrder(work, "phase: commands", "dap-completion-test ''", 1, &.{ "p", "pick", "run" });
    try bashExpectOrder(work, "phase: arguments", "dap-completion-test pick ''", 2, &.{ "green", "red" });
    try bashExpectOrder(work, "phase: flags after slot", "dap-completion-test pick red ''", 3, &.{
        "--color", "--config", "--description", "--note", "--verbose", "-d", "--version", "--help", "-h",
    });
    try bashExpectOrder(work, "value token is not positional", "dap-completion-test pick --note x ''", 4, &.{ "green", "red" });
    try bashExpectOrder(work, "alias-only insertion", "dap-completion-test pick -d", 2, &.{"-d"});
    try bashExpectOrder(work, "version and help tail", "dap-completion-test -", 1, &.{
        "--color", "--config", "--description", "--verbose", "-d", "--version", "--help", "-h",
    });
}

test "completion integration: fish" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScripts(&tmp);

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);

    const syntax = try runShell(work, &.{ "fish", "--no-config", "-n", "../dap_completion_test.fish" });
    const res = syntax orelse {
        std.debug.print("completion-test: fish not found; skipping fish checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("fish -n", res);

    try fishExpect(work, "root flag prefix", "dap-completion-test --co", &.{ "--config", "--color" });
    try fishExpect(work, "child command", "dap-completion-test run de", &.{"deep"});
    try fishExpect(work, "ancestor flag on child", "dap-completion-test run --ver", &.{ "--verbose", "--version" });
    try fishExpect(work, "enum separate value", "dap-completion-test --color ", &.{ "red", "green" });
    try fishExpect(work, "enum full form", "dap-completion-test --color=r", &.{"--color=red"});
    try fishExpect(work, "non-enum value", "dap-completion-test --config ", &.{});
    try fishExpect(work, "literal after terminator", "dap-completion-test -- ", &.{});

    try fishExpectLines(work, "merged prefix rows", "dap-completion-test -", &.{
        "--color\t-- Color.",
        "--config\t-- Config.",
        "--description\t-d  -- Description of context.",
        "--verbose\t-- Verbose.",
        "--version",
        "--help\t-h  -- Show context-sensitive help.",
    });
    try fishExpectLines(work, "phase: commands", "dap-completion-test ", &.{
        "pick\tp  -- Pick.",
        "run\t-- Run.",
    });
    try fishExpectLines(work, "phase: arguments", "dap-completion-test pick ", &.{
        "green\t-- Kind.",
        "red\t-- Kind.",
    });
    try fishExpectLines(work, "alias-only row", "dap-completion-test -d", &.{"-d\t-- Description of context."});
    try fishExpectLines(work, "version tail", "dap-completion-test --v", &.{ "--verbose\t-- Verbose.", "--version" });
}

test "completion integration: zsh" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScripts(&tmp);

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);

    const syntax = try runShell(work, &.{ "zsh", "-n", "../dap_completion_test.zsh" });
    const res = syntax orelse {
        std.debug.print("completion-test: zsh not found; skipping zsh checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("zsh -n", res);

    const maybe = try runShell(work, &.{
        "zsh",
        "-f",
        "-c",
        "autoload -Uz compinit; compinit -u -D; source ../dap_completion_test.zsh; " ++
            "whence -w _dap_completion_test",
    });
    const smoke = maybe orelse return error.SkipZigTest;
    defer std.testing.allocator.free(smoke.stdout);
    defer std.testing.allocator.free(smoke.stderr);
    try expectSuccess("zsh smoke", smoke);

    const trimmed = std.mem.trim(u8, smoke.stdout, " \t\r\n");
    try std.testing.expectEqualStrings("_dap_completion_test: function", trimmed);

    try zshExpectDisplays(work, "zsh three columns", "dap-completion-test -", &.{
        "--color            -- Color.",
        "--config           -- Config.",
        "--description  -d  -- Description of context.",
        "--verbose          -- Verbose.",
        "--version",
        "--help         -h  -- Show context-sensitive help.",
    });
    try zshExpectDisplays(work, "zsh two columns", "dap-completion-test --v", &.{
        "--verbose  -- Verbose.",
        "--version",
    });
    try zshExpectDisplays(work, "zsh empty prefix commands", "dap-completion-test ''", &.{
        "pick  p  -- Pick.",
        "run      -- Run.",
    });
    try zshExpectDisplays(work, "zsh empty prefix arguments", "dap-completion-test pick ''", &.{
        "green  -- Kind.",
        "red    -- Kind.",
    });
    try zshExpectDisplays(work, "zsh alias-only row", "dap-completion-test pick -d", &.{"-d  -- Description of context."});
    try zshExpectDisplays(work, "zsh flags after slot", "dap-completion-test pick red ''", &.{
        "--color            -- Color.",
        "--config           -- Config.",
        "--description  -d  -- Description of context.",
        "--note             -- Note.",
        "--verbose          -- Verbose.",
        "--version",
        "--help         -h  -- Show context-sensitive help.",
    });
}
