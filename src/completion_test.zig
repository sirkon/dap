//! Shell integration checks for generated completion scripts.
//!
//! These tests are deliberately kept out of `zig build test`: they spawn real
//! shells. Run them with `zig build completion-test`. A shell that is not
//! installed is skipped with a visible notice; install all three for a full
//! run.

const std = @import("std");
const builtin = @import("builtin");
const dap = @import("dap");
const fixture = @import("completion-fixture");
const build_options = @import("build_options");

const APP_NAME = "dap-completion-test";
const IDENT = "dap_completion_test";
const SCRIPT_BASH = "../dap_completion_test.bash";
const SCRIPT_ZSH = "../dap_completion_test.zsh";
const SCRIPT_FISH = "../dap_completion_test.fish";

const PREDICTOR_APP_NAME = "dap-predictor-test";
const PREDICTOR_IDENT = "dap_predictor_test";
const PREDICTOR_SCRIPT_BASH = "../predictor.bash";
const PREDICTOR_SCRIPT_ZSH = "../predictor.zsh";
const PREDICTOR_SCRIPT_FISH = "../predictor.fish";

const ChainMode = dap.Enumeration(.{
    .alpha = dap.Enum{},
    .beta = dap.Enum{},
});

const CHAIN_APP_NAME = "dap-chain-test";
const CHAIN_IDENT = "dap_chain_test";
const CHAIN_SCRIPT_BASH = "../chain.bash";
const CHAIN_SCRIPT_ZSH = "../chain.zsh";
const CHAIN_SCRIPT_FISH = "../chain.fish";

/// Sibling commands reuse `--toggle` with different arity. Each level's
/// value-flag table classifies it for itself, so completion follows the
/// branch the user actually entered.
const ChainCLI = dap.generate(dap.App{
    .name = "dap chain test",
    .help = "Chain.",
}, .{
    .left = dap.Command(.{ .help = "Left." }, .{
        .toggle = dap.Flag(bool){
            .long = "toggle",
            .default = dap.Default(bool){ .direct = false },
            .help = "Toggle.",
        },
        .kind = dap.Argument(ChainMode){},
    }),
    .right = dap.Command(.{ .help = "Right." }, .{
        .toggle = dap.Flag(dap.String){ .long = "toggle", .help = "Toggle value." },
        .kind = dap.Argument(ChainMode){},
    }),
});

const Mode = dap.Enumeration(.{
    .red = dap.Enum{ .help = .{ .text = "Red." } },
    .green = dap.Enum{ .help = .{ .text = "Green." } },
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
    const scripts = [_]struct { shell: dap.Completion.Shell, path: []const u8 }{
        .{ .shell = .bash, .path = "dap_completion_test.bash" },
        .{ .shell = .zsh, .path = "dap_completion_test.zsh" },
        .{ .shell = .fish, .path = "dap_completion_test.fish" },
    };

    for (scripts) |entry| {
        const script = try CLI.completion(std.testing.allocator, APP_NAME, entry.shell, &CLI.default_locale).text();
        defer std.testing.allocator.free(script);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry.path, .data = script });
    }
}

fn writeChainScripts(tmp: *std.testing.TmpDir) !void {
    const scripts = [_]struct { shell: dap.Completion.Shell, path: []const u8 }{
        .{ .shell = .bash, .path = "chain.bash" },
        .{ .shell = .zsh, .path = "chain.zsh" },
        .{ .shell = .fish, .path = "chain.fish" },
    };

    for (scripts) |entry| {
        const script = try ChainCLI.completion(std.testing.allocator, CHAIN_APP_NAME, entry.shell, &ChainCLI.default_locale).text();
        defer std.testing.allocator.free(script);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry.path, .data = script });
    }
}

/// Render the predictor fixture's scripts, symlink the fixture executable as
/// `bin/dap-predictor-test` (the registered name), and populate `work/` with
/// the files the predictors should list.
fn writePredictorFixture(tmp: *std.testing.TmpDir, work: std.Io.Dir) !void {
    const scripts = [_]struct { shell: dap.Completion.Shell, path: []const u8 }{
        .{ .shell = .bash, .path = "predictor.bash" },
        .{ .shell = .zsh, .path = "predictor.zsh" },
        .{ .shell = .fish, .path = "predictor.fish" },
    };

    for (scripts) |entry| {
        const script = try fixture.CLI.completion(std.testing.allocator, PREDICTOR_APP_NAME, entry.shell, &fixture.CLI.default_locale).text();
        defer std.testing.allocator.free(script);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry.path, .data = script });
    }

    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        build_options.exe,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);

    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.symLink(std.testing.io, fixture_path, "bin/" ++ PREDICTOR_APP_NAME, .{});

    try work.createDirPath(std.testing.io, "assets/sub");
    try work.createDirPath(std.testing.io, "native-dir");

    const files = [_][]const u8{
        "assets/alpha.txt",
        "assets/beta.txt",
        "assets/gamma.md",
        "assets/sub/deep.txt",
        "native-file.txt",
        "plain.txt",
    };
    for (files) |path| {
        try work.writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
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
    script: []const u8,
    fn_name: []const u8,
    words: []const u8,
    want: []const []const u8,
) !void {
    try zshCompaddShim(cwd, label, script, fn_name, words, want, false);
}

/// Like `zshExpectDisplays`, but also prints every raw match handed to
/// `compadd` as `MATCH <name>` before the display rows, proving that the
/// candidate list never carries padding or escapes.
fn zshExpectDisplaysAndMatches(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    script: []const u8,
    fn_name: []const u8,
    words: []const u8,
    want: []const []const u8,
) !void {
    try zshCompaddShim(cwd, label, script, fn_name, words, want, true);
}

/// Runs `fn_name` under a stubbed `compadd` that mimics zsh: it prints the
/// `displays` array when `-d` was passed, and otherwise prints the match
/// names after `--`. With `dump_cands` it prints both.
fn zshCompaddShim(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    script: []const u8,
    fn_name: []const u8,
    words: []const u8,
    want: []const []const u8,
    dump_cands: bool,
) !void {
    const code = try std.fmt.allocPrint(
        std.testing.allocator,
        \\compdef() {{ :; }}
        \\compadd() {{
        \\    local have_d=0 dump=0
        \\    local -a matches
        \\    [[ $DUMP_CANDS == 1 ]] && dump=1
        \\    while (( $# )); do
        \\        case $1 in
        \\            (-n) return 0 ;;
        \\            (-d) have_d=1 ;;
        \\            (--) shift; matches=("$@"); break ;;
        \\        esac
        \\        shift
        \\    done
        \\    if (( dump )); then
        \\        local m
        \\        for m in "${{matches[@]}}"; do print -r -- "MATCH $m"; done
        \\    fi
        \\    local d
        \\    if (( have_d )); then
        \\        for d in "${{displays[@]}}"; do print -r -- "$d"; done
        \\    else
        \\        for d in "${{matches[@]}}"; do print -r -- "$d"; done
        \\    fi
        \\}}
        \\_files() {{ print -r -- "FILES $*"; }}
        \\export PATH="$PWD/../bin:$PATH"
        \\DUMP_CANDS={s}
        \\source {s}
        \\words=({s})
        \\CURRENT=${{#words}}
        \\PREFIX=${{words[CURRENT]}}
        \\{s} || true
    ,
        .{ if (dump_cands) "1" else "0", script, words, fn_name },
    );
    defer std.testing.allocator.free(code);

    const maybe = try runShell(cwd, &.{ "zsh", "-f", "-c", code });
    const res = maybe orelse return error.SkipZigTest;
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess(label, res);
    try expectLinesExact(std.testing.allocator, label, res.stdout, want);
}

/// Drive an interactive zsh under `zpty`, press TAB once at `words`, and
/// return the resulting command line. This observes zsh's own common-prefix
/// insertion, which the `compadd` display shim above cannot.
fn zshTabCompletes(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    words: []const u8,
) ![]u8 {
    const driver =
        \\zmodload zsh/zpty || exit 77
        \\zmodload zsh/zselect || exit 77
        \\trap 'zpty -d z 2>/dev/null' EXIT
        \\
        \\wait_match() {
        \\    local name=$1 pat=$2 i=0 chunk acc=''
        \\    while (( i < 500 )); do
        \\        if zpty -r -mt $name chunk "$pat"; then
        \\            acc+=$chunk
        \\            REPLY=$acc
        \\            return 0
        \\        fi
        \\        acc+=$chunk
        \\        chunk=
        \\        zselect -t 2
        \\        (( i++ ))
        \\    done
        \\    return 1
        \\}
        \\
        \\zpty z 'zsh -f -i' || exit 1
        \\zpty -w z 'PROMPT="READY> "'
        \\wait_match z '*READY> *' || exit 1
        \\zpty -w z 'autoload -Uz compinit; compinit -u -D; source ../dap_completion_test.zsh'
        \\zpty -w z 'inspect() { print -r -- "BUF:[$BUFFER]" }'
        \\zpty -w z 'zle -N inspect; bindkey "^T" inspect'
        \\zpty -w z 'PROMPT="READY2> "'
        \\wait_match z '*READY2> *' || exit 1
        \\zpty -w -n z "$1"
        \\zpty -w -n z $'\t'
        \\zpty -w -n z $'\x14'
        \\wait_match z '*BUF:\[*\]*' || exit 1
        \\local out=${REPLY##*BUF:\[}
        \\print -r -- "${out%%]*}"
        \\zpty -d z
        \\
    ;
    try cwd.writeFile(std.testing.io, .{ .sub_path = "zpty.zsh", .data = driver });

    const maybe = try runShell(cwd, &.{ "zsh", "-f", "zpty.zsh", words });
    const res = maybe orelse return error.SkipZigTest;
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code == 77) return error.SkipZigTest;
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
    return try std.testing.allocator.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

fn bashComplete(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    script: []const u8,
    ident: []const u8,
    words: []const u8,
    cword: u8,
) !?[]u8 {
    const code = try std.fmt.allocPrint(
        std.testing.allocator,
        \\. {s}
        \\export PATH="$PWD/../bin:$PATH"
        \\COMP_WORDS=({s})
        \\COMP_CWORD={d}
        \\_dap_{s}
        \\if (( ${{#COMPREPLY[@]}} )); then
        \\    printf '%s\n' "${{COMPREPLY[@]}}"
        \\fi
    ,
        .{ script, words, cword, ident },
    );
    defer std.testing.allocator.free(code);

    const maybe = try runShell(cwd, &.{ "bash", "-c", code });
    const res = maybe orelse return null;
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess(label, res);
    return try std.testing.allocator.dupe(u8, res.stdout);
}

/// Run one bash case with a `compopt` stub and return the calls the generated
/// function made. This observes fallback suppression without an interactive
/// completion context.
fn bashCompopt(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    script: []const u8,
    ident: []const u8,
    words: []const u8,
    cword: u8,
) !?[]u8 {
    const code = try std.fmt.allocPrint(
        std.testing.allocator,
        \\compopt() {{ printf 'COMPOPT %s\n' "$*"; }}
        \\. {s}
        \\export PATH="$PWD/../bin:$PATH"
        \\COMP_WORDS=({s})
        \\COMP_CWORD={d}
        \\_dap_{s}
    ,
        .{ script, words, cword, ident },
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
    script: []const u8,
    ident: []const u8,
    words: []const u8,
    cword: u8,
    want: []const []const u8,
) !void {
    const got = try bashComplete(cwd, label, script, ident, words, cword) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(got);
    try expectCandidateSet(std.testing.allocator, label, got, want);
}

fn bashExpectOrder(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    script: []const u8,
    ident: []const u8,
    words: []const u8,
    cword: u8,
    want: []const []const u8,
) !void {
    const got = try bashComplete(cwd, label, script, ident, words, cword) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(got);
    try expectLinesExact(std.testing.allocator, label, got, want);
}

fn fishComplete(
    cwd: std.Io.Dir,
    comptime label: []const u8,
    script: []const u8,
    line: []const u8,
) !?[]u8 {
    const code = try std.fmt.allocPrint(
        std.testing.allocator,
        "set -gx PATH (pwd)/../bin $PATH; source {s}; complete -C '{s}'",
        .{ script, line },
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
    script: []const u8,
    line: []const u8,
    want: []const []const u8,
) !void {
    const got = try fishComplete(cwd, label, script, line) orelse return error.SkipZigTest;
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
    script: []const u8,
    line: []const u8,
    want: []const []const u8,
) !void {
    const got = try fishComplete(cwd, label, script, line) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(got);
    try expectLinesExact(std.testing.allocator, label, got, want);
}

test "completion integration: registration uses app_name" {
    const shells = [_]dap.Completion.Shell{ .bash, .zsh, .fish };
    inline for (shells) |shell| {
        const script = try CLI.completion(std.testing.allocator, APP_NAME, shell, &CLI.default_locale).text();
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
                    "complete -c 'dap-completion-test' -f -a '(__dap_dap_completion_test_complete)' -k\n",
                ));
            },
        }
    }

    const mine = try CLI.completion(std.testing.allocator, APP_NAME, .bash, &CLI.default_locale).text();
    defer std.testing.allocator.free(mine);
    const other = try CLI.completion(std.testing.allocator, "other-app", .bash, &CLI.default_locale).text();
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

    try bashExpect(work, "root flag prefix", SCRIPT_BASH, IDENT, "dap-completion-test --ver", 1, &.{ "--verbose", "--version" });
    try bashExpect(work, "child command", SCRIPT_BASH, IDENT, "dap-completion-test ru", 1, &.{"run"});
    try bashExpect(work, "child level candidates", SCRIPT_BASH, IDENT, "dap-completion-test run de", 2, &.{"deep"});
    try bashExpect(work, "ancestor flag on child", SCRIPT_BASH, IDENT, "dap-completion-test run --ver", 2, &.{ "--verbose", "--version" });
    try bashExpect(work, "enum separate value", SCRIPT_BASH, IDENT, "dap-completion-test --color ''", 2, &.{ "red", "green" });
    try bashExpect(work, "enum eq with text", SCRIPT_BASH, IDENT, "dap-completion-test --color = r", 3, &.{"red"});
    try bashExpect(work, "enum eq empty", SCRIPT_BASH, IDENT, "dap-completion-test --color =", 2, &.{ "=red", "=green" });
    try bashExpect(work, "enum full form", SCRIPT_BASH, IDENT, "dap-completion-test --color=r", 1, &.{ "--color=red", "--color=green" });
    try bashExpect(work, "non-enum value", SCRIPT_BASH, IDENT, "dap-completion-test --config ''", 2, &.{});
    try bashExpect(work, "literal after terminator", SCRIPT_BASH, IDENT, "dap-completion-test -- x", 2, &.{});

    try bashExpectOrder(work, "phase: commands", SCRIPT_BASH, IDENT, "dap-completion-test ''", 1, &.{ "p", "pick", "run" });
    try bashExpectOrder(work, "phase: arguments", SCRIPT_BASH, IDENT, "dap-completion-test pick ''", 2, &.{ "green", "red" });
    try bashExpectOrder(work, "phase: flags after slot", SCRIPT_BASH, IDENT, "dap-completion-test pick red ''", 3, &.{
        "--color", "--config", "--description", "--note", "--verbose", "-d", "--version", "--help", "-h",
    });
    try bashExpectOrder(work, "value token is not positional", SCRIPT_BASH, IDENT, "dap-completion-test pick --note x ''", 4, &.{ "green", "red" });
    try bashExpectOrder(work, "alias-only insertion", SCRIPT_BASH, IDENT, "dap-completion-test pick -d", 2, &.{"-d"});
    try bashExpectOrder(work, "version and help tail", SCRIPT_BASH, IDENT, "dap-completion-test -", 1, &.{
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

    try fishExpect(work, "root flag prefix", SCRIPT_FISH, "dap-completion-test --co", &.{ "--config", "--color" });
    try fishExpect(work, "child command", SCRIPT_FISH, "dap-completion-test run de", &.{"deep"});
    try fishExpect(work, "ancestor flag on child", SCRIPT_FISH, "dap-completion-test run --ver", &.{ "--verbose", "--version" });
    try fishExpect(work, "enum separate value", SCRIPT_FISH, "dap-completion-test --color ", &.{ "red", "green" });
    try fishExpect(work, "enum full form", SCRIPT_FISH, "dap-completion-test --color=r", &.{"--color=red"});
    try fishExpect(work, "non-enum value", SCRIPT_FISH, "dap-completion-test --config ", &.{});
    try fishExpect(work, "literal after terminator", SCRIPT_FISH, "dap-completion-test -- ", &.{});

    try fishExpectLines(work, "merged prefix rows", SCRIPT_FISH, "dap-completion-test -", &.{
        "--color\t-- Color.",
        "--config\t-- Config.",
        "--description\t-d  -- Description of context.",
        "--verbose\t-- Verbose.",
        "--version",
        "--help\t-h  -- Show context-sensitive help.",
    });
    try fishExpectLines(work, "phase: commands", SCRIPT_FISH, "dap-completion-test ", &.{
        "pick\tp  -- Pick.",
        "run\t-- Run.",
    });
    try fishExpectLines(work, "phase: arguments", SCRIPT_FISH, "dap-completion-test pick ", &.{
        "green\t-- Green.",
        "red\t-- Red.",
    });
    try fishExpectLines(work, "alias-only row", SCRIPT_FISH, "dap-completion-test -d", &.{"-d\t-- Description of context."});
    try fishExpectLines(work, "version tail", SCRIPT_FISH, "dap-completion-test --v", &.{ "--verbose\t-- Verbose.", "--version" });
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

    try zshExpectDisplays(work, "zsh three columns", SCRIPT_ZSH, "_dap_completion_test", "dap-completion-test -", &.{
        "--color            -- Color.",
        "--config           -- Config.",
        "--description  -d  -- Description of context.",
        "--verbose          -- Verbose.",
        "--version",
        "--help         -h  -- Show context-sensitive help.",
    });
    try zshExpectDisplays(work, "zsh two columns", SCRIPT_ZSH, "_dap_completion_test", "dap-completion-test --v", &.{
        "--verbose  -- Verbose.",
        "--version",
    });
    try zshExpectDisplays(work, "zsh long-only row hides alias", SCRIPT_ZSH, "_dap_completion_test", "dap-completion-test --d", &.{
        "--description  -- Description of context.",
    });
    try zshExpectDisplays(work, "zsh empty prefix commands", SCRIPT_ZSH, "_dap_completion_test", "dap-completion-test ''", &.{
        "pick  p  -- Pick.",
        "run      -- Run.",
    });
    try zshExpectDisplays(work, "zsh empty prefix arguments", SCRIPT_ZSH, "_dap_completion_test", "dap-completion-test pick ''", &.{
        "green  -- Green.",
        "red    -- Red.",
    });
    try zshExpectDisplays(work, "zsh alias-only row", SCRIPT_ZSH, "_dap_completion_test", "dap-completion-test pick -d", &.{"-d  -- Description of context."});
    try zshExpectDisplays(work, "zsh flags after slot", SCRIPT_ZSH, "_dap_completion_test", "dap-completion-test pick red ''", &.{
        "--color            -- Color.",
        "--config           -- Config.",
        "--description  -d  -- Description of context.",
        "--note             -- Note.",
        "--verbose          -- Verbose.",
        "--version",
        "--help         -h  -- Show context-sensitive help.",
    });

    const dash = try zshTabCompletes(work, "zsh empty prefix inserts dash", "dap-completion-test pick red ");
    defer std.testing.allocator.free(dash);
    try std.testing.expectEqualStrings("dap-completion-test pick red -", dash);

    const stays = try zshTabCompletes(work, "zsh dash prefix stays dash", "dap-completion-test pick red -");
    defer std.testing.allocator.free(stays);
    try std.testing.expectEqualStrings("dap-completion-test pick red -", stays);

    const doubles = try zshTabCompletes(work, "zsh double dash prefix stays", "dap-completion-test --");
    defer std.testing.allocator.free(doubles);
    try std.testing.expectEqualStrings("dap-completion-test --", doubles);

    const alias = try zshTabCompletes(work, "zsh alias completes", "dap-completion-test pick -d");
    defer std.testing.allocator.free(alias);
    try std.testing.expectEqualStrings("dap-completion-test pick -d", alias);

    const long = try zshTabCompletes(work, "zsh long spelling completes", "dap-completion-test --col");
    defer std.testing.allocator.free(long);
    try std.testing.expectEqualStrings("dap-completion-test --color", long);
}

test "completion integration: chain bash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeChainScripts(&tmp);

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);

    const syntax = try runShell(work, &.{ "bash", "-n", CHAIN_SCRIPT_BASH });
    const res = syntax orelse {
        std.debug.print("completion-test: bash not found; skipping chain bash checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("bash -n chain", res);

    try bashExpect(work, "left boolean leaves the slot", CHAIN_SCRIPT_BASH, CHAIN_IDENT, "dap-chain-test left --toggle ''", 3, &.{ "alpha", "beta" });
    try bashExpect(work, "right value takes the word", CHAIN_SCRIPT_BASH, CHAIN_IDENT, "dap-chain-test right --toggle ''", 3, &.{});
    try bashExpect(work, "right value token then slot", CHAIN_SCRIPT_BASH, CHAIN_IDENT, "dap-chain-test right --toggle v ''", 4, &.{ "alpha", "beta" });
    try bashExpect(work, "left value token fills the slot", CHAIN_SCRIPT_BASH, CHAIN_IDENT, "dap-chain-test left --toggle v ''", 4, &.{ "--toggle", "--help", "-h" });
}

test "completion integration: chain fish" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeChainScripts(&tmp);

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);

    const syntax = try runShell(work, &.{ "fish", "--no-config", "-n", CHAIN_SCRIPT_FISH });
    const res = syntax orelse {
        std.debug.print("completion-test: fish not found; skipping chain fish checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("fish -n chain", res);

    try fishExpect(work, "left boolean leaves the slot", CHAIN_SCRIPT_FISH, "dap-chain-test left --toggle ", &.{ "alpha", "beta" });
    try fishExpect(work, "right value takes the word", CHAIN_SCRIPT_FISH, "dap-chain-test right --toggle ", &.{});
    try fishExpect(work, "right value token then slot", CHAIN_SCRIPT_FISH, "dap-chain-test right --toggle v ", &.{ "alpha", "beta" });
    try fishExpect(work, "left value token fills the slot", CHAIN_SCRIPT_FISH, "dap-chain-test left --toggle v ", &.{ "--toggle", "--help" });
}

test "completion integration: chain zsh" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeChainScripts(&tmp);

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);

    const syntax = try runShell(work, &.{ "zsh", "-n", CHAIN_SCRIPT_ZSH });
    const res = syntax orelse {
        std.debug.print("completion-test: zsh not found; skipping chain zsh checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("zsh -n chain", res);

    try zshExpectDisplays(work, "zsh left boolean leaves the slot", CHAIN_SCRIPT_ZSH, "_dap_chain_test", "dap-chain-test left --toggle ''", &.{ "alpha", "beta" });
    // No predictor keeps zsh's file fallback; the stub records the call and
    // the empty work directory offers no candidate.
    try zshExpectDisplays(work, "zsh right value takes the word", CHAIN_SCRIPT_ZSH, "_dap_chain_test", "dap-chain-test right --toggle ''", &.{"FILES "});
    try zshExpectDisplays(work, "zsh right value token then slot", CHAIN_SCRIPT_ZSH, "_dap_chain_test", "dap-chain-test right --toggle v ''", &.{ "alpha", "beta" });
    try zshExpectDisplays(work, "zsh left value token fills the slot", CHAIN_SCRIPT_ZSH, "_dap_chain_test", "dap-chain-test left --toggle v ''", &.{
        "--toggle      -- Toggle.",
        "--help    -h  -- Show context-sensitive help.",
    });
}

test "completion integration: bash predictors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);
    try writePredictorFixture(&tmp, work);

    const syntax = try runShell(work, &.{ "bash", "-n", PREDICTOR_SCRIPT_BASH });
    const res = syntax orelse {
        std.debug.print("completion-test: bash not found; skipping predictor checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("bash -n predictors", res);

    try bashExpect(work, "callback values", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --cb ''", 2, &.{ "alpha", "beta" });
    try bashExpect(work, "callback prefix", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --cb al", 2, &.{"alpha"});
    try bashExpect(work, "callback eq re-attach", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --cb=al", 1, &.{"--cb=alpha"});
    try bashExpect(work, "disabled stays empty", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --off ''", 2, &.{});
    try bashExpect(work, "explicit empty does not fall back", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --cb zzz", 2, &.{});
    try bashExpect(work, "null keeps the default fallback", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --plain ''", 2, &.{});
    try bashExpect(work, "terminator runs no predictor", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test -- --cb ''", 3, &.{});
    try bashExpect(work, "inline launch", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --launch ''", 2, &.{"launched"});
    try bashExpect(work, "inline call", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --call c", 2, &.{ "cone", "ctwo" });
    try bashExpect(work, "native files", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --native ''", 2, &.{
        "assets", "native-dir", "native-file.txt", "plain.txt",
    });
    try bashExpect(work, "native directories", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --dirs ''", 2, &.{ "assets", "native-dir" });
    try bashExpect(work, "rooted wildcard", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --assets ''", 2, &.{ "alpha.txt", "beta.txt", "sub/" });
    try bashExpect(work, "rooted descent", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --assets sub/", 2, &.{"sub/deep.txt"});
    try bashExpect(work, "rooted eq re-attach", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --assets=al", 1, &.{"--assets=alpha.txt"});
    try bashExpect(work, "callback positional", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test pick ''", 2, &.{ "alpha", "beta" });
    try bashExpect(work, "filesystem positional", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test pick alpha ''", 3, &.{
        "assets/", "native-dir/", "native-file.txt", "plain.txt",
    });

    const off = try bashCompopt(work, "disabled compopt", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --off ''", 2) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(off);
    try expectLinesExact(std.testing.allocator, "disabled compopt", off, &.{"COMPOPT +o default"});

    const empty = try bashCompopt(work, "explicit empty compopt", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --cb zzz", 2) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(empty);
    try expectLinesExact(std.testing.allocator, "explicit empty compopt", empty, &.{"COMPOPT +o default"});

    const plain = try bashCompopt(work, "null compopt", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --plain ''", 2) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(plain);
    try expectLinesExact(std.testing.allocator, "null compopt", plain, &.{});

    const native = try bashCompopt(work, "native compopt", PREDICTOR_SCRIPT_BASH, PREDICTOR_IDENT, "dap-predictor-test --native ''", 2) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(native);
    try expectLinesExact(std.testing.allocator, "native compopt", native, &.{"COMPOPT -o filenames"});

    // `-o default` stays on the registration, so a null target keeps bash's
    // file fallback even though the generated function leaves COMPREPLY empty.
    const registration = try runShell(work, &.{ "bash", "-c", "source ../predictor.bash; complete -p dap-predictor-test" }) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(registration.stdout);
    defer std.testing.allocator.free(registration.stderr);
    try expectSuccess("bash registration", registration);
    try std.testing.expect(std.mem.indexOf(u8, registration.stdout, "-o default") != null);
    try std.testing.expect(std.mem.indexOf(u8, registration.stdout, "_dap_dap_predictor_test") != null);
}

test "completion integration: zsh predictors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);
    try writePredictorFixture(&tmp, work);

    const syntax = try runShell(work, &.{ "zsh", "-n", PREDICTOR_SCRIPT_ZSH });
    const res = syntax orelse {
        std.debug.print("completion-test: zsh not found; skipping predictor checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("zsh -n predictors", res);

    try zshExpectDisplays(work, "zsh callback descriptions", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --cb ''", &.{
        "alpha  -- Alpha value.",
        "beta",
    });
    try zshExpectDisplays(work, "zsh callback prefix", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --cb al", &.{"alpha  -- Alpha value."});
    try zshExpectDisplays(work, "zsh callback eq re-attach", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --cb=al", &.{"--cb=alpha  -- Alpha value."});
    try zshExpectDisplays(work, "zsh disabled stays empty", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --off ''", &.{});
    try zshExpectDisplays(work, "zsh explicit empty no fallback", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --cb zzz", &.{});
    try zshExpectDisplays(work, "zsh null path fallback", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --plain ''", &.{"FILES "});
    try zshExpectDisplays(work, "zsh terminator runs no predictor", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test -- --cb ''", &.{});
    try zshExpectDisplays(work, "zsh inline launch", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --launch ''", &.{"launched"});
    try zshExpectDisplays(work, "zsh inline call", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --call c", &.{ "cone", "ctwo" });
    try zshExpectDisplays(work, "zsh native files", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --native ''", &.{"FILES "});
    try zshExpectDisplays(work, "zsh native directories", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --dirs ''", &.{"FILES -/"});
    try zshExpectDisplays(work, "zsh rooted wildcard", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --assets ''", &.{ "alpha.txt", "beta.txt", "sub/" });
    try zshExpectDisplays(work, "zsh rooted descent", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --assets sub/", &.{"sub/deep.txt"});
    try zshExpectDisplays(work, "zsh rooted eq re-attach", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --assets=al", &.{"--assets=alpha.txt"});
    try zshExpectDisplays(work, "zsh callback positional", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test pick ''", &.{
        "alpha  -- Alpha value.",
        "beta",
    });
    try zshExpectDisplays(work, "zsh filesystem positional", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test pick alpha ''", &.{
        "assets/",
        "native-dir/",
        "native-file.txt",
        "plain.txt",
    });

    try zshExpectDisplays(work, "zsh dynamic width and escape", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --shape ''", &.{
        "alpha                 -- Alpha value.",
        "beta",
        "gamma-long-long-long",
        "delta\\ one\\ two       -- Spaced value.",
        "zeta\\ one",
    });
    try zshExpectDisplays(work, "zsh dynamic single row", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --shape al", &.{
        "alpha  -- Alpha value.",
    });
    try zshExpectDisplays(work, "zsh dynamic no help fallback", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --shape gamma", &.{
        "gamma-long-long-long",
    });
    try zshExpectDisplays(work, "zsh dynamic raw match in fallback", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --shape zeta", &.{
        "zeta one",
    });
    try zshExpectDisplaysAndMatches(work, "zsh dynamic raw candidates", PREDICTOR_SCRIPT_ZSH, "_dap_predictor_test", "dap-predictor-test --shape ''", &.{
        "MATCH alpha",
        "MATCH beta",
        "MATCH gamma-long-long-long",
        "MATCH delta one two",
        "MATCH zeta one",
        "alpha                 -- Alpha value.",
        "beta",
        "gamma-long-long-long",
        "delta\\ one\\ two       -- Spaced value.",
        "zeta\\ one",
    });
}

test "completion integration: fish predictors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work.close(std.testing.io);
    try writePredictorFixture(&tmp, work);

    const syntax = try runShell(work, &.{ "fish", "--no-config", "-n", PREDICTOR_SCRIPT_FISH });
    const res = syntax orelse {
        std.debug.print("completion-test: fish not found; skipping predictor checks\n", .{});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try expectSuccess("fish -n predictors", res);

    try fishExpectLines(work, "fish callback descriptions", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --cb ", &.{
        "alpha\tAlpha value.",
        "beta",
    });
    try fishExpectLines(work, "fish callback prefix", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --cb al", &.{"alpha\tAlpha value."});
    try fishExpectLines(work, "fish callback eq re-attach", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --cb=al", &.{"--cb=alpha\tAlpha value."});
    try fishExpectLines(work, "fish disabled stays empty", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --off ", &.{});
    try fishExpectLines(work, "fish explicit empty no fallback", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --cb zzz", &.{});
    try fishExpectLines(work, "fish terminator runs no predictor", PREDICTOR_SCRIPT_FISH, "dap-predictor-test -- --cb ", &.{});
    try fishExpectLines(work, "fish inline launch", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --launch ", &.{"launched"});
    try fishExpectLines(work, "fish inline call", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --call c", &.{ "cone", "ctwo" });
    try fishExpect(work, "fish null path fallback", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --plain ", &.{
        "assets/", "native-dir/", "native-file.txt", "plain.txt",
    });
    try fishExpect(work, "fish native files", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --native ", &.{
        "assets/", "native-dir/", "native-file.txt", "plain.txt",
    });
    try fishExpectLines(work, "fish native directories", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --dirs ", &.{
        "assets/\tDirectory",
        "native-dir/\tDirectory",
    });
    try fishExpect(work, "fish rooted wildcard", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --assets ", &.{ "alpha.txt", "beta.txt", "sub/" });
    try fishExpect(work, "fish rooted descent", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --assets sub/", &.{"sub/deep.txt"});
    try fishExpectLines(work, "fish rooted eq re-attach", PREDICTOR_SCRIPT_FISH, "dap-predictor-test --assets=al", &.{"--assets=alpha.txt"});
    try fishExpectLines(work, "fish callback positional", PREDICTOR_SCRIPT_FISH, "dap-predictor-test pick ", &.{
        "alpha\tAlpha value.",
        "beta",
    });
    try fishExpect(work, "fish filesystem positional", PREDICTOR_SCRIPT_FISH, "dap-predictor-test pick alpha ", &.{
        "assets/", "native-dir/", "native-file.txt", "plain.txt",
    });
}
