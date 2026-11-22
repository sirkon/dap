//! Shell completion script generation.
//!
//! This module owns the public `Completion` namespace and every private
//! completion table and emitter. `src/dap.zig` imports it for the generated
//! `CLI.Completion` handle, and this file imports `dap.zig` back through a
//! four-name bridge; Zig resolves the cycle lazily.

const std = @import("std");
const dap = @import("dap.zig");

const Spec = dap._completion_internal.Spec;
const CommandEntry = dap._completion_internal.CommandEntry;
const Sub = dap._completion_internal.Sub;
const subApp = dap._completion_internal.subApp;

const App = dap.App;
const String = dap.String;
const Flag = dap.Flag;
const Argument = dap.Argument;
const Enumeration = dap.Enumeration;
const Enum = dap.Enum;
const Default = dap.Default;
const Optional = dap.Optional;
const Group = dap.Group;
const Alt = dap.Alt;
const Command = dap.Command;
const CommandMeta = dap.CommandMeta;
const generate = dap.generate;

/// Public completion surface: shell selection, render errors, and the lazy
/// per-namespace handle type.
pub const Completion = struct {
    /// Shell dialect a completion script is generated for.
    pub const Shell = enum { bash, zsh, fish };

    /// A type for CLI flags/commands/arguments to generate completion stuff.
    pub const ShellType = Enumeration(.{
        .bash = dap.Enum{
            .name = "bash",
            .help = "Bash shell.",
            .i18n = "builtin.bash_shell",
        },
        .zsh = dap.Enum{
            .name = "zsh",
            .help = "Zsh shell.",
            .i18n = "builtin.zsh_shell",
        },
        .fish = dap.Enum{
            .name = "fish",
            .help = "Fish shell.",
            .i18n = "builtin.fish_shell",
        },
    });

    /// Errors a completion-script render can produce.
    pub const Error = std.mem.Allocator.Error || error{InvalidAppName};

    /// First argv element the generated binary recognizes as a completion
    /// route call rather than ordinary invocation. The generated `parse`
    /// handles it before any other argument processing.
    pub const route_marker = "---608b59fe-b7a9-407a-b0f5-77640a2c1957";

    /// Options for a filesystem completion predictor. `wildcard` is matched
    /// against the file name only (`*` and `?`), `type` selects files and
    /// directories or directories alone, and `root` is a process-cwd relative
    /// POSIX-style path resolved before `wildcard` is applied.
    pub const FsOptions = struct {
        pub const Type = enum { all, dir };
        wildcard: []const u8 = "*",
        type: Type = .all,
        root: ?[]const u8 = null,
    };

    /// One completion candidate produced by a predictor. `help` is rendered
    /// beside the value where the shell supports descriptions.
    pub const Suggestion = struct {
        value: []const u8,
        help: ?[]const u8 = null,
    };

    /// Completion value source attached to a non-bool, non-enumeration flag or
    /// argument. `null` keeps the shell's own completion and native `.fs`
    /// behaves identically; every other branch replaces it for that target.
    ///
    /// * `disabled` offers nothing and suppresses any fallback.
    /// * `fs` lists files (`.all`) or directories (`.dir`).
    /// * `launch` renders a literal command line directly in the script.
    /// * `call` embeds a shell expression verbatim; it is dialect-specific.
    /// * `callback` runs `cb` in the generated binary through the hidden route.
    pub const Predictor = union(enum) {
        disabled: void,
        fs: FsOptions,
        launch: []const []const u8,
        call: []const u8,
        callback: *const fn (
            allocator: std.mem.Allocator,
            cur: []const u8,
            line: []const []const u8,
        ) anyerror![]const Suggestion,
    };

    /// A predictor that offers no values and suppresses shell fallback.
    pub fn disabled() Predictor {
        return .{ .disabled = {} };
    }

    /// A predictor listing files or directories.
    pub fn fs(opts: FsOptions) Predictor {
        return .{ .fs = opts };
    }

    /// A predictor rendering a literal command line in the script. Accepts a
    /// tuple, array, or slice of strings; an element equal to `$cur` is
    /// substituted with the word being completed, and an empty current word is
    /// still passed as one empty argument.
    pub fn launch(comptime words: anytype) Predictor {
        return .{ .launch = launchWords(words) };
    }

    /// A predictor embedding a shell expression verbatim. The same string is
    /// inserted into every generated script, so it is dialect-specific and must
    /// be valid in each target shell. It sees the current word as `cur` and the
    /// words before it, program included, as `line`.
    pub fn call(expr: []const u8) Predictor {
        return .{ .call = expr };
    }

    /// A predictor calling `cb` in the generated binary. The callback allocates
    /// the returned slice and every non-null string in it with `allocator`.
    /// On error it cleans up its own partial result; the route frees only a
    /// successful list, and static literals are not valid results.
    pub fn custom(cb: @FieldType(Predictor, "callback")) Predictor {
        return .{ .callback = cb };
    }

    /// Lazily rendered shell completion script for the declaration `NS`.
    ///
    /// `generate` specializes this type as `CLI.Completion`, and `CLI.completion`
    /// builds one from an allocator, the registered app name, and a shell.
    /// Construction is cheap and infallible; `text`, `show`, and `install` render
    /// the script on demand, so a bad app name surfaces as `error.InvalidAppName`
    /// from those methods rather than from the constructor.
    pub fn Of(comptime NS: type) type {
        return struct {
            allocator: std.mem.Allocator,
            app_name: String,
            shell: Completion.Shell,

            /// Render the script. The caller owns the returned string and frees
            /// it with the same allocator.
            ///
            /// ```
            /// var completion = CLI.completion(arena.allocator(), "app", .zsh);
            /// const script = try completion.text();
            /// defer arena.allocator().free(script);
            /// ```
            pub fn text(self: @This()) Completion.Error!String {
                return completionScript(self.allocator, NS, self.app_name, self.shell);
            }

            /// Render the script and write it to stdout.
            pub fn show(self: @This(), io: std.Io) !void {
                const rendered = try self.text();
                defer self.allocator.free(rendered);
                var buffer: [0x1000]u8 = undefined;
                var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
                const stdout = &stdout_writer.interface;
                try stdout.writeAll(rendered);
                try stdout.flush();
            }

            /// Render the script and write it where `shell` discovers completions:
            ///
            /// * bash: `$XDG_DATA_HOME/bash-completion/completions/<app>`
            /// * zsh: `$XDG_DATA_HOME/zsh/site-functions/_<app>`
            /// * fish: `$XDG_CONFIG_HOME/fish/completions/<app>.fish`
            ///
            /// A missing or empty `XDG_DATA_HOME` falls back to
            /// `$HOME/.local/share`, and `XDG_CONFIG_HOME` to `$HOME/.config`;
            /// parent directories are created as needed. `environ` is the process
            /// environment, typically `init.minimal.environ` from `main`.
            /// Returns `error.InstallUnsupported` when no home directory can be
            /// found.
            ///
            /// ```
            /// var completion = CLI.completion(arena.allocator(), "app", .bash);
            /// try completion.install(init.io, init.minimal.environ);
            /// ```
            pub fn install(self: @This(), io: std.Io, environ: std.process.Environ) !void {
                if (!isValidCompletionAppName(self.app_name)) return error.InvalidAppName;
                if (std.mem.eql(u8, self.app_name, ".") or std.mem.eql(u8, self.app_name, ".."))
                    return error.InvalidAppName;
                var target = try completionInstallTarget(self.allocator, self.shell, self.app_name, environ);
                defer target.deinit(self.allocator);
                var dir = try std.Io.Dir.cwd().createDirPathOpen(io, target.dir_path, .{});
                defer dir.close(io);
                const rendered = try self.text();
                defer self.allocator.free(rendered);
                try dir.writeFile(io, .{ .sub_path = target.file_name, .data = rendered });
            }
        };
    }
};

/// Number of words a `launch` predictor was declared with.
fn launchWordCount(comptime words: anytype) usize {
    const bad = "dap.Completion.launch expects a tuple, array, or slice of strings";
    return switch (@typeInfo(@TypeOf(words))) {
        .@"struct" => |s| if (s.is_tuple) s.field_names.len else @compileError(bad),
        .array => |a| a.len,
        .pointer => |p| if (p.size == .slice) words.len else switch (@typeInfo(p.child)) {
            .array => |a| a.len,
            else => @compileError(bad),
        },
        else => @compileError(bad),
    };
}

/// Coerce one `launch` element to a string, rejecting non-string values.
fn launchWord(comptime v: anytype) []const u8 {
    const bad = "dap.Completion.launch expects every element to be a string";
    return switch (@typeInfo(@TypeOf(v))) {
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk v;
            switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) break :blk v,
                else => {},
            }
            @compileError(bad);
        },
        else => @compileError(bad),
    };
}

/// Comptime holder for the words of one `launch` declaration, so the
/// materialized slice has static lifetime.
fn LaunchWords(comptime words: anytype) type {
    return struct {
        const value: [launchWordCount(words)][]const u8 = blk: {
            var arr: [launchWordCount(words)][]const u8 = undefined;
            for (0..arr.len) |i| arr[i] = launchWord(words[i]);
            break :blk arr;
        };
    };
}

/// Materialize `launch` words into a comptime-held slice with static lifetime.
fn launchWords(comptime words: anytype) []const []const u8 {
    return &LaunchWords(words).value;
}

/// One command level in the completion table: its tree rank and usage path,
/// the effective flag set (ancestors first, injected help deduplicated), and
/// the arguments and commands owned by the level itself. `flag_bindings` and
/// `argument_bindings` are aligned with `flags` and `arguments` and hold
/// indices into `Model.bindings`, or `null` when the shell serves the target
/// by itself.
const Level = struct {
    rank: usize,
    path: String,
    flags: []const Spec,
    flag_bindings: []const ?usize = &.{},
    arguments: []const Spec,
    argument_bindings: []const ?usize = &.{},
    commands: []const CommandEntry,
};

/// One hidden-route value source: a callback run in the generated binary, or
/// a filesystem mapping the shell cannot express and the binary evaluates.
const Binding = union(enum) {
    callback: @FieldType(Completion.Predictor, "callback"),
    fs: Completion.FsOptions,
};

/// Comptime completion model shared by the emitters and the hidden route.
/// `bindings` is indexed by the aligned per-level binding arrays.
const Model = struct {
    levels: []const Level,
    bindings: []const Binding,
};

/// Native filesystem mappings are rendered by the shell itself; a custom
/// wildcard or root has to be evaluated in the binary.
fn isNativeFs(opts: Completion.FsOptions) bool {
    return std.mem.eql(u8, opts.wildcard, "*") and opts.root == null;
}

/// The hidden-route binding for a spec, or `null` when no route call is needed:
/// no predictor, `.disabled`, `.launch`, `.call`, or a native `.fs` mapping.
fn routeBinding(comptime s: Spec) ?Binding {
    const predictor = s.completion orelse return null;
    return switch (predictor) {
        .callback => |cb| .{ .callback = cb },
        .fs => |opts| if (isNativeFs(opts)) null else .{ .fs = opts },
        else => null,
    };
}

const ModelWalk = struct {
    levels: []const Level,
    bindings: []const Binding,
};

/// Walk `NS` and every command below it in declaration pre-order and describe
/// each level. Binding indices are dense and assigned in first-seen order; an
/// inherited flag keeps the index its ancestor gave it, matched by its
/// globally unique long name.
fn model(comptime NS: type) Model {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const walk = modelWalk(NS, &.{}, &.{}, &.{});
        return .{ .levels = walk.levels, .bindings = walk.bindings };
    }
}

fn modelWalk(
    comptime NS: type,
    comptime inherited_flags: []const Spec,
    comptime inherited_bindings: []const ?usize,
    comptime bindings: []const Binding,
) ModelWalk {
    comptime {
        @setEvalBranchQuota(1_000_000);

        var flags = inherited_flags;
        var flag_bindings = inherited_bindings;
        var acc = bindings;

        for (NS.specs) |s| {
            if (s.kind != .flag) continue;
            var duplicate = false;
            for (flags) |prev| {
                if (std.mem.eql(u8, prev.long, s.long)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            flags = flags ++ &[_]Spec{s};
            if (routeBinding(s)) |binding| {
                acc = acc ++ &[_]Binding{binding};
                flag_bindings = flag_bindings ++ &[_]?usize{acc.len - 1};
            } else {
                flag_bindings = flag_bindings ++ &[_]?usize{null};
            }
        }

        var arguments: []const Spec = &.{};
        var argument_bindings: []const ?usize = &.{};
        for (NS.specs) |s| {
            if (s.kind != .argument) continue;
            arguments = arguments ++ &[_]Spec{s};
            if (routeBinding(s)) |binding| {
                acc = acc ++ &[_]Binding{binding};
                argument_bindings = argument_bindings ++ &[_]?usize{acc.len - 1};
            } else {
                argument_bindings = argument_bindings ++ &[_]?usize{null};
            }
        }

        var levels: []const Level = &[_]Level{.{
            .rank = NS.app_meta._command_rank,
            .path = NS.app_meta.name,
            .flags = flags,
            .flag_bindings = flag_bindings,
            .arguments = arguments,
            .argument_bindings = argument_bindings,
            .commands = NS.commands,
        }};
        for (NS.commands) |c| {
            const sub = modelWalk(
                Sub(c.Cmd, subApp(NS.app_meta, c)),
                flags,
                flag_bindings,
                acc,
            );
            levels = levels ++ sub.levels;
            acc = sub.bindings;
        }
        return .{ .levels = levels, .bindings = acc };
    }
}

/// Wire names of a structurally enumerable value type, in declaration order.
/// Non-struct types and the empty `Enumeration` result expose no names, so
/// they contribute no value candidates.
fn enumWireNames(comptime T: type) []const String {
    if (@typeInfo(T) != .@"struct") return &.{};
    if (!@hasDecl(T, "EnumView") or !@hasDecl(T, "names")) return &.{};
    return &T.names;
}

/// Help declared on the enumeration value spelled `name`, or the empty string
/// when the type carries no matching help.
fn enumWireHelp(comptime T: type, comptime name: String) String {
    comptime {
        if (@typeInfo(T) != .@"struct") return "";
        if (!@hasDecl(T, "names") or !@hasDecl(T, "helps")) return "";
        if (T.names.len != T.helps.len) return "";
        for (T.names, T.helps) |nm, help| {
            if (std.mem.eql(u8, nm, name)) return help;
        }
        return "";
    }
}

/// Whether `app_name` is a safe registered command name: non-empty ASCII from
/// `A-Za-z0-9._+-`, not starting with `-`. Runs before any allocation.
fn isValidCompletionAppName(name: String) bool {
    if (name.len == 0) return false;
    if (name[0] == '-') return false;
    for (name) |c| {
        if (c >= 0x80) return false;
        if (c <= 0x20 or c == 0x7f) return false;
        const allowed = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '+' or c == '-';
        if (!allowed) return false;
    }
    return true;
}

/// Derive the shell identifier stem from a validated `app_name`: every byte
/// outside `[A-Za-z0-9_]` becomes `_`. The caller frees the result.
fn completionIdent(allocator: std.mem.Allocator, app_name: String) std.mem.Allocator.Error![]u8 {
    const ident = try allocator.alloc(u8, app_name.len);
    for (app_name, ident) |c, *d| {
        const keep = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_';
        d.* = if (keep) c else '_';
    }
    return ident;
}

const CompletionQuote = enum { posix, fish };

/// Append the bytes of `s` as literal characters, escaping only what the
/// quote mode requires. The caller supplies the surrounding quotes.
fn appendQuotedBytes(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    s: String,
    quote: CompletionQuote,
) std.mem.Allocator.Error!void {
    for (s) |c| switch (quote) {
        .posix => {
            if (c == '\'') {
                try out.appendSlice(allocator, "'\\''");
            } else {
                try out.append(allocator, c);
            }
        },
        .fish => {
            if (c == '\'' or c == '\\') try out.append(allocator, '\\');
            try out.append(allocator, c);
        },
    };
}

/// Append `parts` joined by `sep` as one shell literal.
fn appendQuotedJoined(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: []const String,
    sep: String,
    quote: CompletionQuote,
) std.mem.Allocator.Error!void {
    try out.append(allocator, '\'');
    for (parts, 0..) |part, i| {
        if (i != 0) try appendQuotedBytes(out, allocator, sep, quote);
        try appendQuotedBytes(out, allocator, part, quote);
    }
    try out.append(allocator, '\'');
}

/// Append `s` as one shell literal. POSIX wraps in `'...'` and rewrites `'` as
/// `'\''`; fish wraps in `'...'` and backslash-escapes `\` and `'`.
fn appendQuoted(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    s: String,
    quote: CompletionQuote,
) std.mem.Allocator.Error!void {
    try appendQuotedJoined(out, allocator, &.{s}, "", quote);
}

/// Append `s` with `\n`, `\r` and `\t` replaced by a space, for level markers
/// and descriptions. Candidates are never sanitized this way.
fn appendSanitized(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    s: String,
) std.mem.Allocator.Error!void {
    for (s) |c| {
        try out.append(allocator, switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        });
    }
}

/// Append the `# dap: level <rank> <path>` comment that precedes a level's
/// block in a generated dispatch. Never carries shell syntax.
fn appendLevelMarker(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    level: Level,
) std.mem.Allocator.Error!void {
    try out.print(allocator, "# dap: level {} ", .{level.rank});
    try appendSanitized(out, allocator, level.path);
    try out.append(allocator, '\n');
}

/// Every value-taking flag spelling of the tree (`--long` and `-short`), in
/// first-seen order and without duplicates. Boolean flags never consume the
/// next word, so they are excluded. Long and short names are globally unique,
/// which makes the table exact.
fn valueFlagSpellings(comptime levels: []const Level) []const String {
    comptime {
        var spellings: []const String = &.{};
        for (levels) |level| {
            for (level.flags) |s| {
                if (s.vtype == bool) continue;
                const longs: []const String = if (s.long.len == 0)
                    &.{}
                else
                    &[_]String{std.fmt.comptimePrint("--{s}", .{s.long})};
                const shorts: []const String = if (s.short) |sh|
                    if (sh.len == 0) &.{} else &[_]String{std.fmt.comptimePrint("-{s}", .{sh})}
                else
                    &.{};
                for (longs ++ shorts) |spelling| {
                    var seen = false;
                    for (spellings) |prev| {
                        if (std.mem.eql(u8, prev, spelling)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) spellings = spellings ++ &[_]String{spelling};
                }
            }
        }
        return spellings;
    }
}

/// One value-taking flag spelling and its value type, for the shell emitters'
/// value-position arms. `predictor` is the declared completion source, so an
/// arm can render native filesystem completion or leave the fallback alone;
/// `binding` is its aligned index into `Model.bindings`, or `null` when no
/// hidden route call is needed.
const CompletionValueArm = struct {
    spelling: String,
    vtype: type,
    predictor: ?Completion.Predictor,
    binding: ?usize,
};

/// Every value-taking spelling of `level`, long before short, in effective
/// flag order and without duplicates. Boolean flags never enter a value
/// position.
fn completionValueArms(comptime level: Level) []const CompletionValueArm {
    comptime {
        var arms: []const CompletionValueArm = &.{};
        for (level.flags, 0..) |s, flag_index| {
            if (s.vtype == bool) continue;
            const binding: ?usize = if (flag_index < level.flag_bindings.len)
                level.flag_bindings[flag_index]
            else
                null;
            var spellings: []const String = &.{};
            if (s.long.len != 0) {
                spellings = spellings ++ &[_]String{std.fmt.comptimePrint("--{s}", .{s.long})};
            }
            if (s.short) |sh| {
                if (sh.len != 0) {
                    spellings = spellings ++ &[_]String{std.fmt.comptimePrint("-{s}", .{sh})};
                }
            }
            for (spellings) |spelling| {
                var seen = false;
                for (arms) |prev| {
                    if (std.mem.eql(u8, prev.spelling, spelling)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    arms = arms ++ &[_]CompletionValueArm{.{
                        .spelling = spelling,
                        .vtype = s.vtype,
                        .predictor = s.completion,
                        .binding = binding,
                    }};
                }
            }
        }
        return arms;
    }
}

/// Predictor declared on positional slot `slot`, or `null` when the shell
/// serves that slot by itself.
fn argumentPredictor(comptime level: Level, comptime slot: usize) ?Completion.Predictor {
    if (slot >= level.arguments.len) return null;
    return level.arguments[slot].completion;
}

/// Hidden-route binding of positional slot `slot`, aligned with
/// `Model.bindings`.
fn argumentBinding(comptime level: Level, comptime slot: usize) ?usize {
    if (slot >= level.argument_bindings.len) return null;
    return level.argument_bindings[slot];
}

/// Whether any flag or argument of `level` declares a predictor. Levels
/// without one emit exactly the pre-predictor script.
fn levelHasPredictor(comptime level: Level) bool {
    for (level.flags) |s| {
        if (s.completion != null) return true;
    }
    for (level.arguments) |s| {
        if (s.completion != null) return true;
    }
    return false;
}

/// Whether `level` has a positional slot with no predictor, i.e. one whose
/// fallback the shell still provides.
fn levelHasPlainArgument(comptime level: Level) bool {
    for (level.arguments) |s| {
        if (s.completion == null) return true;
    }
    return false;
}

/// Whether a declared predictor is one the shell cannot serve itself and so
/// must suppress its own fallback: everything except `null` and a native
/// `.fs` mapping.
fn predictorSuppressesFallback(predictor: Completion.Predictor) bool {
    return switch (predictor) {
        .fs => |opts| !isNativeFs(opts),
        else => true,
    };
}

/// Wire spellings of `c` the completion script can offer: primary name then
/// synonym, dropping empty and dash-leading spellings (unreachable, because
/// flag matching runs first).
fn completionCommandSpellings(comptime c: CommandEntry) []const String {
    if (c.synonym) |s| {
        if (s.len != 0 and s[0] != '-') {
            if (c.name.len != 0 and c.name[0] != '-') return &[_]String{ c.name, s };
            return &[_]String{s};
        }
    }
    if (c.name.len != 0 and c.name[0] != '-') return &[_]String{c.name};
    return &.{};
}

/// Commands of `level` that the completion script can offer, i.e. those with
/// at least one reachable spelling.
fn completionCommands(comptime level: Level) []const CommandEntry {
    comptime {
        var cmds: []const CommandEntry = &.{};
        for (level.commands) |c| {
            if (completionCommandSpellings(c).len == 0) continue;
            cmds = cmds ++ &[_]CommandEntry{c};
        }
        return cmds;
    }
}

const CompletionEntryKind = enum { flag, argument, command };
const CompletionEntryFamily = enum { normal, version, help };

/// One row of the completion model: a flag, a command, or one argument value.
/// `spelling` is the primary spelling (`--long`, command name, or value name);
/// `alias` is the short flag or command synonym when the declaration has one.
const CompletionEntry = struct {
    spelling: String,
    alias: ?String,
    help: String,
    kind: CompletionEntryKind,
    family: CompletionEntryFamily,
};

/// Classify a primary spelling into the version/help tail. A lone `-h` or `-v`
/// only reaches this with no long name, so `--verbose` with a `-v` alias stays
/// normal.
fn completionFamily(comptime spelling: String) CompletionEntryFamily {
    if (std.mem.eql(u8, spelling, "--help") or
        std.mem.eql(u8, spelling, "help") or
        std.mem.eql(u8, spelling, "-h")) return .help;
    if (std.mem.eql(u8, spelling, "--version") or
        std.mem.eql(u8, spelling, "version") or
        std.mem.eql(u8, spelling, "-v")) return .version;
    return .normal;
}

/// Sort key: the family partition (normal, version, help) always wins, so
/// `help` stays last; inside a family, entries with help come before entries
/// with empty help; then byte-wise spelling order.
fn completionEntryLess(comptime a: CompletionEntry, comptime b: CompletionEntry) bool {
    const a_family = @backingInt(a.family);
    const b_family = @backingInt(b.family);
    if (a_family != b_family) return a_family < b_family;
    const a_help = a.help.len != 0;
    const b_help = b.help.len != 0;
    if (a_help != b_help) return a_help;
    return std.mem.lessThan(u8, a.spelling, b.spelling);
}

/// Stable insertion sort, no `std.mem.sort` at comptime.
fn completionSortedEntries(comptime raw: []const CompletionEntry) []const CompletionEntry {
    comptime {
        var out: []const CompletionEntry = &.{};
        for (raw) |entry| {
            var pos = out.len;
            for (out, 0..) |prev, i| {
                if (completionEntryLess(entry, prev)) {
                    pos = i;
                    break;
                }
            }
            out = out[0..pos] ++ &[_]CompletionEntry{entry} ++ out[pos..];
        }
        return out;
    }
}

/// ASCII-sorted, duplicate-free copy of `raw`.
fn completionSortedStrings(comptime raw: []const String) []const String {
    comptime {
        var out: []const String = &.{};
        for (raw) |s| {
            var pos = out.len;
            for (out, 0..) |prev, i| {
                if (std.mem.lessThan(u8, s, prev)) {
                    pos = i;
                    break;
                }
            }
            out = out[0..pos] ++ &[_]String{s} ++ out[pos..];
        }
        var deduped: []const String = &.{};
        for (out) |s| {
            if (deduped.len != 0 and std.mem.eql(u8, deduped[deduped.len - 1], s)) continue;
            deduped = deduped ++ &[_]String{s};
        }
        return deduped;
    }
}

/// Effective flag entries of `level`: one entry per flag, `--long` as primary
/// and `-short` as alias when both exist.
fn completionFlagEntries(comptime level: Level) []const CompletionEntry {
    comptime {
        var entries: []const CompletionEntry = &.{};
        for (level.flags) |s| {
            const long: []const String = if (s.long.len == 0)
                &.{}
            else
                &[_]String{std.fmt.comptimePrint("--{s}", .{s.long})};
            const short: []const String = if (s.short) |sh|
                if (sh.len == 0) &.{} else &[_]String{std.fmt.comptimePrint("-{s}", .{sh})}
            else
                &.{};
            const spelling = if (long.len != 0) long[0] else if (short.len != 0) short[0] else continue;
            const alias: ?String = if (long.len != 0 and short.len != 0) short[0] else null;
            entries = entries ++ &[_]CompletionEntry{.{
                .spelling = spelling,
                .alias = alias,
                .help = s.help,
                .kind = .flag,
                .family = completionFamily(spelling),
            }};
        }
        return completionSortedEntries(entries);
    }
}

/// Command entries of `level`: reachable primary spelling, synonym as alias.
fn completionCommandEntries(comptime level: Level) []const CompletionEntry {
    comptime {
        var entries: []const CompletionEntry = &.{};
        for (completionCommands(level)) |c| {
            const spellings = completionCommandSpellings(c);
            if (spellings.len == 0) continue;
            entries = entries ++ &[_]CompletionEntry{.{
                .spelling = spellings[0],
                .alias = if (spellings.len == 2) spellings[1] else null,
                .help = c.Cmd.cmd_meta.help,
                .kind = .command,
                .family = completionFamily(spellings[0]),
            }};
        }
        return completionSortedEntries(entries);
    }
}

/// Argument-value entries of positional slot `slot`: enumeration wire names,
/// deduplicated, always in the normal family, each carrying the help declared
/// on its own `dap.Enum` branch.
fn completionArgumentEntries(comptime level: Level, comptime slot: usize) []const CompletionEntry {
    comptime {
        if (slot >= level.arguments.len) return &.{};
        const spec = level.arguments[slot];
        var names: []const String = &.{};
        for (enumWireNames(spec.vtype)) |name| {
            var seen = false;
            for (names) |prev| {
                if (std.mem.eql(u8, prev, name)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) names = names ++ &[_]String{name};
        }
        var entries: []const CompletionEntry = &.{};
        for (names) |name| {
            entries = entries ++ &[_]CompletionEntry{.{
                .spelling = name,
                .alias = null,
                .help = enumWireHelp(spec.vtype, name),
                .kind = .argument,
                .family = .normal,
            }};
        }
        return completionSortedEntries(entries);
    }
}

/// The level's flag and command entries, sorted and partitioned.
fn completionEntries(comptime level: Level) []const CompletionEntry {
    comptime {
        return completionSortedEntries(completionFlagEntries(level) ++ completionCommandEntries(level));
    }
}

/// The level's flag and command entries plus slot `slot`'s argument values.
fn completionEntriesWithSlot(comptime level: Level, comptime slot: usize) []const CompletionEntry {
    comptime {
        return completionSortedEntries(completionEntries(level) ++ completionArgumentEntries(level, slot));
    }
}

fn completionEntriesOfKind(
    comptime entries: []const CompletionEntry,
    comptime kind: CompletionEntryKind,
) []const CompletionEntry {
    comptime {
        var out: []const CompletionEntry = &.{};
        for (entries) |entry| {
            if (entry.kind != kind) continue;
            out = out ++ &[_]CompletionEntry{entry};
        }
        return out;
    }
}

/// Expand entries into one description-free entry per spelling (bash does not
/// merge pairs), sorted by the same key as rows.
fn completionSpellingEntries(comptime entries: []const CompletionEntry) []const CompletionEntry {
    comptime {
        var expanded: []const CompletionEntry = &.{};
        for (entries) |entry| {
            const bare = CompletionEntry{
                .spelling = entry.spelling,
                .alias = null,
                .help = entry.help,
                .kind = entry.kind,
                .family = entry.family,
            };
            expanded = expanded ++ &[_]CompletionEntry{bare};
            if (entry.alias) |alias| {
                expanded = expanded ++ &[_]CompletionEntry{.{
                    .spelling = alias,
                    .alias = null,
                    .help = entry.help,
                    .kind = entry.kind,
                    .family = entry.family,
                }};
            }
        }
        return completionSortedEntries(expanded);
    }
}

/// Every spelling a bash list contains, in final order.
fn completionSpellings(comptime entries: []const CompletionEntry) []const String {
    comptime {
        var out: []const String = &.{};
        for (completionSpellingEntries(entries)) |entry| out = out ++ &[_]String{entry.spelling};
        return out;
    }
}

/// All spellings of `level` (primary, alias, and every slot's values) in one
/// ASCII order. Numeric row keys index into this table, so shell-side sorting
/// never compares strings.
fn completionSpellingUniverse(comptime level: Level) []const String {
    comptime {
        var all: []const String = &.{};
        for (completionEntries(level)) |entry| {
            all = all ++ &[_]String{entry.spelling};
            if (entry.alias) |alias| all = all ++ &[_]String{alias};
        }
        for (level.arguments, 0..) |_, slot| {
            for (completionArgumentEntries(level, slot)) |entry| {
                all = all ++ &[_]String{entry.spelling};
            }
        }
        return completionSortedStrings(all);
    }
}

fn completionSpellingRank(comptime universe: []const String, comptime spelling: String) usize {
    for (universe, 0..) |s, i| {
        if (std.mem.eql(u8, s, spelling)) return i;
    }
    unreachable;
}

fn completionEntryBucket(comptime entry: CompletionEntry) usize {
    const no_help: usize = if (entry.help.len != 0) 0 else 1;
    const family: usize = @backingInt(entry.family);
    return family * 2 + no_help;
}

fn completionEntryKey(
    comptime entry: CompletionEntry,
    comptime spelling: String,
    comptime universe: []const String,
) usize {
    return completionEntryBucket(entry) * universe.len + completionSpellingRank(universe, spelling);
}

/// One row of a zsh/fish static table: the entry, the positional slot that
/// owns it (`-1` for flags and commands), and the numeric keys for its primary
/// and alias spellings.
const CompletionRow = struct {
    entry: CompletionEntry,
    slot: isize,
    key_primary: usize,
    key_alias: ?usize,
};

/// Flag, command, and every slot's argument rows, ordered by primary key.
fn completionRows(comptime level: Level) []const CompletionRow {
    comptime {
        const universe = completionSpellingUniverse(level);
        var rows: []const CompletionRow = &.{};
        for (completionEntries(level)) |entry| {
            rows = rows ++ &[_]CompletionRow{.{
                .entry = entry,
                .slot = -1,
                .key_primary = completionEntryKey(entry, entry.spelling, universe),
                .key_alias = if (entry.alias) |alias| completionEntryKey(entry, alias, universe) else null,
            }};
        }
        for (level.arguments, 0..) |_, slot| {
            for (completionArgumentEntries(level, slot)) |entry| {
                rows = rows ++ &[_]CompletionRow{.{
                    .entry = entry,
                    .slot = @intCast(slot),
                    .key_primary = completionEntryKey(entry, entry.spelling, universe),
                    .key_alias = null,
                }};
            }
        }
        var sorted: []const CompletionRow = &.{};
        for (rows) |row| {
            var pos = sorted.len;
            for (sorted, 0..) |prev, i| {
                if (row.key_primary < prev.key_primary) {
                    pos = i;
                    break;
                }
            }
            sorted = sorted[0..pos] ++ &[_]CompletionRow{row} ++ sorted[pos..];
        }
        return sorted;
    }
}

/// Enumeration wire names of `T` prefixed by `prefix`, for inline value forms.
/// Value positions are ASCII-sorted and never tail-partitioned.
fn enumSpellings(comptime T: type, comptime prefix: String) []const String {
    comptime {
        var out: []const String = &.{};
        for (completionSortedStrings(enumWireNames(T))) |name| {
            out = out ++ &[_]String{prefix ++ name};
        }
        return out;
    }
}

/// One completion candidate with its display description.
const CompletionCandidate = struct {
    spelling: String,
    help: String,
};

/// Enumeration values of `T` prefixed by `prefix`, in ASCII order, each
/// carrying the help declared on its own `dap.Enum` branch. `prefix` is empty
/// for bare values and carries the flag spelling plus `=` for inline forms.
fn enumCandidates(comptime T: type, comptime prefix: String) []const CompletionCandidate {
    comptime {
        var cands: []const CompletionCandidate = &.{};
        for (completionSortedStrings(enumWireNames(T))) |name| {
            cands = cands ++ &[_]CompletionCandidate{.{
                .spelling = prefix ++ name,
                .help = enumWireHelp(T, name),
            }};
        }
        return cands;
    }
}

/// Append `_<ident><suffix>` to `out`.
fn appendZshFnName(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    suffix: String,
) std.mem.Allocator.Error!void {
    try out.append(allocator, '_');
    try out.appendSlice(allocator, ident);
    try out.appendSlice(allocator, suffix);
}

/// Append the `cands`/`displays` pair for `cands` and the `compadd` call that
/// consumes them. Candidates carrying help are aligned to the widest spelling,
/// separated from it by `  -- ` and listed one per line (`-V '' -l`), so the
/// descriptions form a column instead of packing into the terminal width. A
/// candidate with empty help displays as itself; when no candidate carries help
/// (enumeration values) the list stays packed in columns.
fn appendZshCandidates(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    cands: []const CompletionCandidate,
) std.mem.Allocator.Error!void {
    if (cands.len == 0) {
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "return 1\n");
        return;
    }

    var width: usize = 0;
    var any_help = false;
    for (cands) |c| {
        if (c.spelling.len > width) width = c.spelling.len;
        if (c.help.len != 0) any_help = true;
    }

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "cands=(");
    for (cands, 0..) |c, i| {
        if (i != 0) try out.append(allocator, ' ');
        try appendQuoted(out, allocator, c.spelling, .posix);
    }
    try out.appendSlice(allocator, ")\n");

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "displays=(");
    for (cands, 0..) |c, i| {
        if (i != 0) try out.append(allocator, ' ');
        if (c.help.len == 0) {
            try appendQuoted(out, allocator, c.spelling, .posix);
        } else {
            var display: std.ArrayList(u8) = .empty;
            defer display.deinit(allocator);
            try display.appendSlice(allocator, c.spelling);
            var pad = width - c.spelling.len;
            while (pad > 0) : (pad -= 1) try display.append(allocator, ' ');
            try display.appendSlice(allocator, "  -- ");
            try appendSanitized(&display, allocator, c.help);
            try appendQuoted(out, allocator, display.items, .posix);
        }
    }
    try out.appendSlice(allocator, ")\n");

    try out.appendSlice(allocator, indent);
    if (any_help) {
        try out.appendSlice(allocator, "compadd -V '' -l -d displays -- \"${cands[@]}\"\n");
    } else {
        try out.appendSlice(allocator, "compadd -o nosort -d displays -- \"${cands[@]}\"\n");
    }
}

/// Append `s` with control whitespace flattened, as one quoted POSIX literal.
fn appendQuotedSanitized(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    s: String,
    quote: CompletionQuote,
) std.mem.Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendSanitized(&buf, allocator, s);
    try appendQuoted(out, allocator, buf.items, quote);
}

/// Append the shared zsh row helper. It holds one static row table per level
/// (rank, spellings, aliases, help, kind, owning slot, and the numeric sort
/// keys), then selects the phase, filters by `PREFIX`, sorts numerically, and
/// renders 2- or 3-column displays. Aliases folded into a merged row are also
/// added as hidden matches (`-n`), so the common prefix spans both spellings
/// (an empty prefix inserts `-`, not `--`) and menu selection can reach the
/// alias.
fn appendZshRowsHelper(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    comptime levels: []const Level,
) std.mem.Allocator.Error!void {
    try appendZshFnName(out, allocator, ident, "_rows() {\n");
    try out.appendSlice(allocator,
        \\    emulate -L zsh
        \\    local rank=$1 pos=$2 cur=$PREFIX
        \\    local -a spell alias help kind slot kp ka
        \\    local -a sel_spell sel_alias sel_help sel_key hidden
        \\    local phase=3 i n s a eff kk kind_i slot_i j pkey
        \\    local ws=0 wa=0 k3=0 row any=0 blank=''
        \\    seen=()
        \\    case $rank in
        \\
    );
    inline for (levels) |level| {
        const rows = comptime completionRows(level);
        const entries = comptime completionEntries(level);
        const commands = comptime completionEntriesOfKind(entries, .command);

        try out.print(allocator, "    {})\n", .{level.rank});

        try out.appendSlice(allocator, "        spell=(");
        for (rows, 0..) |row, i| {
            if (i != 0) try out.append(allocator, ' ');
            try appendQuoted(out, allocator, row.entry.spelling, .posix);
        }
        try out.appendSlice(allocator, ")\n        alias=(");
        for (rows, 0..) |row, i| {
            if (i != 0) try out.append(allocator, ' ');
            try appendQuoted(out, allocator, row.entry.alias orelse "", .posix);
        }
        try out.appendSlice(allocator, ")\n        help=(");
        for (rows, 0..) |row, i| {
            if (i != 0) try out.append(allocator, ' ');
            try appendQuotedSanitized(out, allocator, row.entry.help, .posix);
        }
        try out.appendSlice(allocator, ")\n        kind=(");
        for (rows) |row| try out.print(allocator, " {}", .{@backingInt(row.entry.kind)});
        try out.appendSlice(allocator, " )\n        slot=(");
        for (rows) |row| try out.print(allocator, " {}", .{row.slot});
        try out.appendSlice(allocator, " )\n        kp=(");
        for (rows) |row| try out.print(allocator, " {}", .{row.key_primary});
        try out.appendSlice(allocator, " )\n        ka=(");
        for (rows) |row| try out.print(allocator, " {}", .{row.key_alias orelse 0});
        try out.appendSlice(allocator, " )\n");

        if (commands.len != 0) {
            try out.appendSlice(allocator,
                \\        phase=0
                \\        if [[ -n $cur ]]; then
                \\            phase=3
                \\        else
                \\            phase=2
                \\        fi
                \\
            );
        } else if (level.arguments.len != 0) {
            try out.appendSlice(allocator,
                \\        phase=0
                \\        if [[ -n $cur ]]; then
                \\            phase=3
                \\        else
                \\            case $pos in
                \\
            );
            inline for (0..level.arguments.len) |slot| {
                const values = comptime completionArgumentEntries(level, slot);
                if (values.len != 0) {
                    try out.print(allocator, "            {}) phase=1 ;;\n", .{slot});
                }
            }
            try out.appendSlice(allocator,
                \\            esac
                \\        fi
                \\
            );
        } else {
            try out.appendSlice(allocator,
                \\        phase=0
                \\        if [[ -n $cur ]]; then
                \\            phase=3
                \\        fi
                \\
            );
        }
        try out.appendSlice(allocator, "        ;;\n");
    }
    try out.appendSlice(allocator, "    esac\n");
    try out.appendSlice(allocator,
        \\    local -a cands displays
        \\    n=${#spell}
        \\    for (( i = 1; i <= n; i++ )); do
        \\        kind_i=${kind[i]}
        \\        slot_i=${slot[i]}
        \\        if (( phase == 0 )); then
        \\            (( kind_i == 0 )) || continue
        \\        elif (( phase == 2 )); then
        \\            (( kind_i == 2 )) || continue
        \\        elif (( phase == 1 )); then
        \\            (( slot_i == pos )) || continue
        \\        elif (( kind_i == 1 )); then
        \\            (( slot_i == pos )) || continue
        \\        fi
        \\        s=${spell[i]}
        \\        a=${alias[i]}
        \\        if [[ -n $a && $a == "$cur"* && $s == "$cur"* ]]; then
        \\            eff=$s
        \\            kk=${kp[i]}
        \\        elif [[ -n $a && $a == "$cur"* ]]; then
        \\            eff=$a
        \\            a=
        \\            kk=${ka[i]}
        \\        elif [[ $s == "$cur"* ]]; then
        \\            eff=$s
        \\            kk=${kp[i]}
        \\        else
        \\            continue
        \\        fi
        \\        sel_spell+=("$eff")
        \\        sel_alias+=("$a")
        \\        sel_help+=("${help[i]}")
        \\        sel_key+=("$kk")
        \\        [[ -n $a ]] && hidden+=("$a")
        \\    done
        \\    n=${#sel_spell}
        \\    for (( i = 2; i <= n; i++ )); do
        \\        s=${sel_spell[i]}
        \\        a=${sel_alias[i]}
        \\        kk=${sel_key[i]}
        \\        h=${sel_help[i]}
        \\        j=$(( i - 1 ))
        \\        while (( j >= 1 )); do
        \\            pkey=${sel_key[j]}
        \\            if (( kk < pkey )); then
        \\                sel_spell[$(( j + 1 ))]=$s
        \\                sel_alias[$(( j + 1 ))]=$a
        \\                sel_help[$(( j + 1 ))]=$h
        \\                sel_key[$(( j + 1 ))]=$kk
        \\                j=$(( j - 1 ))
        \\            else
        \\                break
        \\            fi
        \\        done
        \\        sel_spell[$(( j + 1 ))]=$s
        \\        sel_alias[$(( j + 1 ))]=$a
        \\        sel_help[$(( j + 1 ))]=$h
        \\        sel_key[$(( j + 1 ))]=$kk
        \\    done
        \\    for (( i = 1; i <= n; i++ )); do
        \\        (( ${#sel_spell[i]} > ws )) && ws=${#sel_spell[i]}
        \\        (( ${#sel_alias[i]} > wa )) && wa=${#sel_alias[i]}
        \\        [[ -n ${sel_alias[i]} ]] && k3=1
        \\    done
        \\    for (( i = 1; i <= n; i++ )); do
        \\        cands+=("${sel_spell[i]}")
        \\        seen+=("${sel_spell[i]}")
        \\        row=${(r:$ws:)sel_spell[i]}
        \\        if (( k3 )); then
        \\            if [[ -n ${sel_alias[i]} ]]; then
        \\                row="$row  ${(r:$wa:)sel_alias[i]}"
        \\            else
        \\                row="$row  ${(r:$wa:)blank}"
        \\            fi
        \\        fi
        \\        if [[ -n ${sel_help[i]} ]]; then
        \\            row="$row  -- ${sel_help[i]}"
        \\        fi
        \\        while [[ $row == *' ' ]]; do
        \\            row=${row% }
        \\        done
        \\        displays+=("$row")
        \\    done
        \\    if (( n == 0 )); then
        \\        return 1
        \\    fi
        \\    for (( i = 1; i <= n; i++ )); do
        \\        if [[ ${displays[i]} != ${cands[i]} ]]; then
        \\            any=1
        \\            break
        \\        fi
        \\    done
        \\    if (( any )); then
        \\        compadd -U -o nosort -V '' -l -d displays -- "${cands[@]}"
        \\    else
        \\        compadd -U -o nosort -d displays -- "${cands[@]}"
        \\    fi
        \\    if (( ${#hidden} )); then
        \\        compadd -U -n -V '' -- "${hidden[@]}"
        \\    fi
        \\}
        \\
        \\
    );
}
/// Append `_dap_<ident><suffix>` to `out`.
fn appendBashFnName(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    suffix: String,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, "_dap_");
    try out.appendSlice(allocator, ident);
    try out.appendSlice(allocator, suffix);
}

/// Append one `_dap_<ident>_filter <prefix> 'candidate'...` call with no
/// trailing newline. `prefix` is a raw shell expression.
fn appendBashFilterCall(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    prefix: String,
    candidates: []const String,
) std.mem.Allocator.Error!void {
    try appendBashFnName(out, allocator, ident, "_filter ");
    try out.appendSlice(allocator, prefix);
    for (candidates) |c| {
        try out.append(allocator, ' ');
        try appendQuoted(out, allocator, c, .posix);
    }
}

/// Native filesystem options of a value arm, or `null` when the arm has no
/// predictor or a form the shell cannot render itself.
fn armNativeFs(comptime arm: CompletionValueArm) ?Completion.FsOptions {
    const predictor = arm.predictor orelse return null;
    return switch (predictor) {
        .fs => |opts| if (isNativeFs(opts)) opts else null,
        else => null,
    };
}

/// Append the native filesystem completion arm body for bash: `compgen` for
/// files or directories plus filename quoting, without the trailing `return`.
/// `append` keeps matches already collected by the static rows instead of
/// replacing them.
fn appendBashNativeFs(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    opts: Completion.FsOptions,
    append: bool,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "compopt -o filenames\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "local IFS=$'\\n'\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, if (append) "COMPREPLY+=($(compgen " else "COMPREPLY=($(compgen ");
    try out.appendSlice(allocator, if (opts.type == .dir) "-d" else "-f");
    try out.appendSlice(allocator, " -- \"$cur\"))\n");
}

/// Append the native filesystem completion arm body for zsh, without the
/// trailing `return`.
fn appendZshNativeFs(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    opts: Completion.FsOptions,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, if (opts.type == .dir) "_files -/\n" else "_files\n");
}

/// Append the native filesystem completion arm body for fish, without the
/// trailing `return`.
fn appendFishNativeFs(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    opts: Completion.FsOptions,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, if (opts.type == .dir)
        "__fish_complete_directories\n"
    else
        "__fish_complete_path\n");
}

/// A predictor form that renders inline in the script rather than through the
/// hidden route.
const InlineCommand = union(enum) {
    words: []const []const u8,
    source: String,
};

/// Append one word of a `launch` command as a shell word. An element exactly
/// equal to `$cur` is emitted as `"$cur"` so the shell expands the current
/// word; the quotes keep an empty current word as one empty argument. Every
/// other element is a literal shell word.
fn appendLaunchWord(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    word: String,
    quote: CompletionQuote,
) std.mem.Allocator.Error!void {
    if (std.mem.eql(u8, word, "$cur")) {
        try out.appendSlice(allocator, "\"$cur\"");
        return;
    }
    try appendQuoted(out, allocator, word, quote);
}

/// Append a `launch` word list as one shell command line. The current word is
/// never appended implicitly; only an explicit `$cur` element expands.
fn appendLaunchCommand(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    words: []const []const u8,
    quote: CompletionQuote,
) std.mem.Allocator.Error!void {
    for (words, 0..) |word, i| {
        if (i != 0) try out.append(allocator, ' ');
        try appendLaunchWord(out, allocator, word, quote);
    }
}

/// Append the inline `launch`/`call` arm body for bash and report whether the
/// predictor was one of those forms. A `call` expression sees `cur` and the
/// array `line` (the words before the current one, program included). Stdout is
/// parsed as `value` or `value<TAB>help`; bash shows only the value, so the tab
/// suffix is dropped. A failed spawn or non-zero exit contributes nothing.
/// Append the inline `launch`/`call` arm body for bash and report whether the
/// predictor was one of those forms. `cur_expr` is the shell expression for the
/// value part of the current word and `prefix_expr` is the text every returned
/// value is re-attached to. A `call` expression sees `cur` and the array
/// `line` (the words before the current one, program included). Stdout is
/// parsed as `value` or `value<TAB>help`; bash shows only the value, so the tab
/// suffix is dropped. A failed spawn or non-zero exit contributes nothing.
fn appendBashInline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    predictor: Completion.Predictor,
    cur_expr: String,
    prefix_expr: String,
) std.mem.Allocator.Error!bool {
    const command: InlineCommand = switch (predictor) {
        .launch => |words| .{ .words = words },
        .call => |source| .{ .source = source },
        else => return false,
    };
    switch (command) {
        .source => {
            try out.appendSlice(allocator, indent);
            try out.appendSlice(allocator, "local -a line=(\"${COMP_WORDS[@]:0:$COMP_CWORD}\")\n");
        },
        .words => {},
    }

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "local out cand\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "if out=$(");
    switch (command) {
        .words => |words| try appendLaunchCommand(out, allocator, words, .posix),
        .source => |source| try out.appendSlice(allocator, source),
    }
    try out.appendSlice(allocator, "); then\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    while IFS= read -r cand; do\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        cand=${cand%%$'\\t'*}\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        [[ -n $cand && $cand == \"");
    try out.appendSlice(allocator, cur_expr);
    try out.appendSlice(allocator, "\"* ]] && COMPREPLY+=(\"");
    try out.appendSlice(allocator, prefix_expr);
    try out.appendSlice(allocator, "$cand\")\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    done <<< \"$out\"\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "fi\n");
    return true;
}

/// Append the inline `launch`/`call` arm body for zsh. `cur` is the stripped
/// current word and `line` (for `call`) holds the words before it, program
/// included. Each output line splits at its first tab into a candidate and a
/// display string, and a successful command is rendered through `compadd`.
/// Append the inline `launch`/`call` arm body for zsh. `cur_expr` is the shell
/// expression for the value part of the current word and `prefix_expr` the text
/// every returned value is re-attached to. `line` (for `call`) holds the words
/// before it, program included. Each output line splits at its first tab into a
/// candidate and a display string; a successful command is rendered through
/// `compadd`, skipping spellings already selected by the static rows in `seen`.
fn appendZshInline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    predictor: Completion.Predictor,
    cur_expr: String,
    prefix_expr: String,
) std.mem.Allocator.Error!bool {
    const command: InlineCommand = switch (predictor) {
        .launch => |words| .{ .words = words },
        .call => |source| .{ .source = source },
        else => return false,
    };

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "local cur=");
    try out.appendSlice(allocator, cur_expr);
    try out.appendSlice(allocator, "\n");
    switch (command) {
        .source => {
            try out.appendSlice(allocator, indent);
            try out.appendSlice(allocator, "local -a line=( \"${words[@]:0:$((CURRENT - 1))}\" )\n");
        },
        .words => {},
    }

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "local out\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "if out=$(");
    switch (command) {
        .words => |words| try appendLaunchCommand(out, allocator, words, .posix),
        .source => |source| try out.appendSlice(allocator, source),
    }
    try out.appendSlice(allocator, "); then\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    local -a cands displays\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    local cand help\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    for cand in ${(f)out}; do\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        help=\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        if [[ $cand == *$'\\t'* ]]; then\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            help=${cand#*$'\\t'}\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            cand=${cand%%$'\\t'*}\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        fi\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        if [[ -z $cand || $cand != \"");
    try out.appendSlice(allocator, cur_expr);
    try out.appendSlice(allocator, "\"* ]]; then\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            continue\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        fi\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        cand=");
    try out.appendSlice(allocator, prefix_expr);
    try out.appendSlice(allocator, "$cand\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        if (( ${seen[(Ie)$cand]} )); then\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            continue\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        fi\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        seen+=(\"$cand\")\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        cands+=(\"$cand\")\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        displays+=(\"${help:-$cand}\")\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    done\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    if (( ${#cands} )); then\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        compadd -U -o nosort -V '' -l -d displays -- \"${cands[@]}\"\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    fi\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "fi\n");
    return true;
}

/// Append the inline `launch`/`call` arm body for fish. `cur` is the current
/// word and `line` (for `call`) holds the words before it, program included.
/// Each output line splits at its first tab into a candidate and a description
/// and is printed in fish's `candidate<TAB>description` form. A failed command
/// contributes nothing.
/// Append the inline `launch`/`call` arm body for fish. `cur_expr` is the shell
/// expression for the value part of the current word and `prefix_expr` the text
/// every returned value is re-attached to. `line` (for `call`) holds the words
/// before it, program included. Each output line splits at its first tab into a
/// candidate and a description and is printed in fish's `candidate<TAB>description`
/// form, skipping spellings listed in `exclude` (the static rows already
/// rendered). A failed command contributes nothing.
fn appendFishInline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    predictor: Completion.Predictor,
    cur_expr: String,
    prefix_expr: String,
    comptime exclude: []const String,
) std.mem.Allocator.Error!bool {
    const command: InlineCommand = switch (predictor) {
        .launch => |words| .{ .words = words },
        .call => |source| .{ .source = source },
        else => return false,
    };
    switch (command) {
        .source => {
            try out.appendSlice(allocator, indent);
            try out.appendSlice(allocator, "set -l line (commandline -opc)\n");
        },
        .words => {},
    }

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "set -l out (");
    switch (command) {
        .words => |words| try appendLaunchCommand(out, allocator, words, .fish),
        .source => |source| try out.appendSlice(allocator, source),
    }
    try out.appendSlice(allocator, ")\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "if test $status -eq 0\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    for cand in $out\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        set -l parts (string split -m 1 \\t -- $cand)\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        set -l val $parts[1]\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        set -l desc ''\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        if test (count $parts) -gt 1\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            set desc $parts[2]\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        end\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        if test -z \"$val\"; or not string match -q -- \"");
    try out.appendSlice(allocator, cur_expr);
    try out.appendSlice(allocator, "*\" $val\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            continue\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        end\n");
    if (prefix_expr.len != 0) {
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        set val \"");
        try out.appendSlice(allocator, prefix_expr);
        try out.appendSlice(allocator, "$val\"\n");
    }
    if (exclude.len != 0) {
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        if contains -- $val");
        for (exclude) |spelling| {
            try out.append(allocator, ' ');
            try appendQuoted(out, allocator, spelling, .fish);
        }
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "            continue\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        end\n");
    }
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        if test -n \"$desc\"\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            printf '%s\\t%s\\n' $val $desc\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        else\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            printf '%s\\n' $val\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        end\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    end\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "end\n");
    return true;
}

/// Render a completion script for every level of `NS`'s tree.
/// Append the bash hidden-route helper, emitted only when the model has at
/// least one binding. It runs the application at the current command word,
/// drops candidate descriptions, re-attaches `prefix`, filters by the value
/// part `cur`, deduplicates against everything already in `COMPREPLY`, and
/// appends.
fn appendBashDynamicHelper(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
) std.mem.Allocator.Error!void {
    try appendBashFnName(out, allocator, ident, "_dynamic() {\n");
    try out.appendSlice(allocator,
        \\    local idx=$1 prefix=$2 cur=$3
        \\    local -a line=("${COMP_WORDS[@]:0:$COMP_CWORD}")
        \\    local out cand c
        \\    if out=$("${COMP_WORDS[0]}"
    );
    try appendQuoted(out, allocator, Completion.route_marker, .posix);
    try out.appendSlice(allocator, " \"$idx\" \"$cur\" \"${line[@]}\"); then\n");
    try out.appendSlice(allocator,
        \\        while IFS= read -r cand; do
        \\            cand=${cand%%$'\t'*}
        \\            [[ -n $cand && $cand == "$cur"* ]] || continue
        \\            cand=$prefix$cand
        \\            for c in "${COMPREPLY[@]}"; do
        \\                [[ $c == "$cand" ]] && continue 2
        \\            done
        \\            COMPREPLY+=("$cand")
        \\        done <<< "$out"
        \\    fi
        \\}
        \\
        \\
    );
}

/// Append the zsh hidden-route helper, emitted only when the model has at
/// least one binding. It runs the application at the current command word,
/// splits every line at its first tab into candidate and description, filters
/// by the value part `cur`, re-attaches `prefix`, skips spellings the static
/// rows already selected (the caller's `seen` array), and adds the rest.
fn appendZshDynamicHelper(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
) std.mem.Allocator.Error!void {
    try appendZshFnName(out, allocator, ident, "_dynamic() {\n");
    try out.appendSlice(allocator,
        \\    local idx=$1 prefix=$2 cur=$3
        \\    local out
        \\    if out=$("$words[1]"
    );
    try appendQuoted(out, allocator, Completion.route_marker, .posix);
    try out.appendSlice(allocator, " \"$idx\" \"$cur\" \"${words[@]:0:$((CURRENT - 1))}\"); then\n");
    try out.appendSlice(allocator,
        \\        local -a cands displays
        \\        local cand help val
        \\        for cand in ${(f)out}; do
        \\            help=
        \\            if [[ $cand == *$'\t'* ]]; then
        \\                help=${cand#*$'\t'}
        \\                cand=${cand%%$'\t'*}
        \\            fi
        \\            if [[ -z $cand || $cand != "$cur"* ]]; then
        \\                continue
        \\            fi
        \\            val=$prefix$cand
        \\            if (( ${seen[(Ie)$val]} )); then
        \\                continue
        \\            fi
        \\            seen+=("$val")
        \\            cands+=("$val")
        \\            if [[ -n $help ]]; then
        \\                displays+=("$val  -- $help")
        \\            else
        \\                displays+=("$val")
        \\            fi
        \\        done
        \\        if (( ${#cands} )); then
        \\            compadd -U -o nosort -V '' -l -d displays -- "${cands[@]}"
        \\        fi
        \\    fi
        \\}
        \\
        \\
    );
}

/// Append the fish hidden-route helper, emitted only when the model has at
/// least one binding. `argv[3..]` are the static spellings the rows already
/// printed; a candidate equal to one of them is skipped, and so is an earlier
/// dynamic candidate. A failed spawn contributes nothing.
fn appendFishDynamicHelper(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, "function ");
    try appendFishFnName(out, allocator, ident, "_dynamic\n");
    try out.appendSlice(allocator,
        \\    set -l idx $argv[1]
        \\    set -l prefix $argv[2]
        \\    set -l cur $argv[3]
        \\    set -e argv[1..3]
        \\    set -l bin (commandline -opc)[1]
        \\    if test -z "$bin"
        \\        return
        \\    end
        \\    set -l out ($bin
    );
    try appendQuoted(out, allocator, Completion.route_marker, .fish);
    try out.appendSlice(allocator, " \"$idx\" \"$cur\" (commandline -opc))\n");
    try out.appendSlice(allocator,
        \\    if test $status -ne 0
        \\        return
        \\    end
        \\    for cand in $out
        \\        set -l parts (string split -m 1 \t -- $cand)
        \\        set -l val $parts[1]
        \\        set -l desc ''
        \\        if test (count $parts) -gt 1
        \\            set desc $parts[2]
        \\        end
        \\        if test -z "$val"; or not string match -q -- "$cur*" $val
        \\            continue
        \\        end
        \\        set val "$prefix$val"
        \\        if contains -- $val $argv
        \\            continue
        \\        end
        \\        set -a argv $val
        \\        if test -n "$desc"
        \\            printf '%s\t%s\n' $val $desc
        \\        else
        \\            printf '%s\n' $val
        \\        end
        \\    end
        \\end
        \\
        \\
    );
}

fn completionScript(
    allocator: std.mem.Allocator,
    comptime NS: type,
    app_name: String,
    shell: Completion.Shell,
) Completion.Error!String {
    if (!isValidCompletionAppName(app_name)) return error.InvalidAppName;
    const ident = try completionIdent(allocator, app_name);
    defer allocator.free(ident);

    const model_value = comptime model(NS);
    const levels = comptime model_value.levels;
    const bindings = comptime model_value.bindings;
    return switch (shell) {
        .bash => emitBash(allocator, levels, bindings, ident, app_name),
        .zsh => emitZsh(allocator, levels, bindings, ident, app_name),
        .fish => emitFish(allocator, levels, bindings, ident, app_name),
    };
}

/// Where `install` writes one shell's script.
const CompletionInstallTarget = struct {
    dir_path: []u8,
    file_name: []u8,

    fn deinit(self: *CompletionInstallTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.dir_path);
        allocator.free(self.file_name);
    }
};

/// Read one environment variable, allocating a copy; `null` when unset.
fn completionEnvValue(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
) std.process.Environ.GetAllocError!?[]u8 {
    return environ.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => |e| return e,
    };
}

fn nonEmptyEnv(value: ?[]const u8) ?[]const u8 {
    if (value) |v| if (v.len != 0) return v;
    return null;
}

/// The standard install location for `shell`, split into the directory to
/// create and the file name inside it. `XDG_DATA_HOME`/`XDG_CONFIG_HOME` win
/// over `$HOME/.local/share`/`$HOME/.config`.
fn completionInstallTarget(
    allocator: std.mem.Allocator,
    shell: Completion.Shell,
    app_name: String,
    environ: std.process.Environ,
) !CompletionInstallTarget {
    const xdg_key: String = switch (shell) {
        .bash, .zsh => "XDG_DATA_HOME",
        .fish => "XDG_CONFIG_HOME",
    };
    const xdg = try completionEnvValue(allocator, environ, xdg_key);
    defer if (xdg) |v| allocator.free(v);

    const home = try completionEnvValue(allocator, environ, "HOME");
    defer if (home) |v| allocator.free(v);

    const base = if (nonEmptyEnv(xdg)) |value| try allocator.dupe(u8, value) else blk: {
        const h = nonEmptyEnv(home) orelse return error.InstallUnsupported;
        break :blk switch (shell) {
            .bash, .zsh => try std.fs.path.join(allocator, &.{ h, ".local", "share" }),
            .fish => try std.fs.path.join(allocator, &.{ h, ".config" }),
        };
    };
    defer allocator.free(base);

    const dir_path = try switch (shell) {
        .bash => std.fs.path.join(allocator, &.{ base, "bash-completion", "completions" }),
        .zsh => std.fs.path.join(allocator, &.{ base, "zsh", "site-functions" }),
        .fish => std.fs.path.join(allocator, &.{ base, "fish", "completions" }),
    };
    errdefer allocator.free(dir_path);

    const file_name = try switch (shell) {
        .bash => allocator.dupe(u8, app_name),
        .zsh => std.fmt.allocPrint(allocator, "_{s}", .{app_name}),
        .fish => std.fmt.allocPrint(allocator, "{s}.fish", .{app_name}),
    };
    return .{ .dir_path = dir_path, .file_name = file_name };
}

/// Append one hidden-route call line for bash.
/// Which half of a positional slot's emission is being rendered: the empty
/// current word (the predictor runs immediately) or a non-empty prefix (static
/// rows first, then the predictor).
const SlotPhase = enum { empty, prefix };

fn appendBashDynamicCall(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    index: usize,
    prefix_expr: String,
    cur_expr: String,
    indent: String,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, indent);
    try appendBashFnName(out, allocator, ident, "_dynamic ");
    try out.print(allocator, "{} ", .{index});
    try out.appendSlice(allocator, prefix_expr);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, cur_expr);
    try out.append(allocator, '\n');
}

/// Append the bash body of positional slot `slot` when it declares a
/// predictor. In the `.prefix` phase the static rows go first and the dynamic
/// values are appended after them; in the `.empty` phase the predictor runs
/// immediately instead of falling through to the flag rows.
fn appendBashSlotPredictor(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    comptime level: Level,
    comptime slot: usize,
    comptime phase: SlotPhase,
) std.mem.Allocator.Error!void {
    const indent = "                ";
    const predictor = comptime argumentPredictor(level, slot) orelse return;
    if (predictorSuppressesFallback(predictor)) {
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "compopt +o default\n");
    }
    if (phase == .prefix) {
        try out.appendSlice(allocator, indent);
        try appendBashFilterCall(
            out,
            allocator,
            ident,
            "\"$cur\"",
            comptime completionSpellings(completionEntriesWithSlot(level, slot)),
        );
        try out.append(allocator, '\n');
    }
    switch (predictor) {
        .disabled => {},
        .fs => |opts| {
            if (isNativeFs(opts)) {
                try appendBashNativeFs(out, allocator, indent, opts, phase == .prefix);
            } else if (comptime argumentBinding(level, slot)) |index| {
                try appendBashDynamicCall(
                    out,
                    allocator,
                    ident,
                    index,
                    "\"\"",
                    if (phase == .empty) "\"\"" else "\"$cur\"",
                    indent,
                );
            }
        },
        .callback => {
            if (comptime argumentBinding(level, slot)) |index| {
                try appendBashDynamicCall(
                    out,
                    allocator,
                    ident,
                    index,
                    "\"\"",
                    if (phase == .empty) "\"\"" else "\"$cur\"",
                    indent,
                );
            }
        },
        .launch, .call => {
            _ = try appendBashInline(
                out,
                allocator,
                indent,
                predictor,
                if (phase == .empty) "" else "$cur",
                "",
            );
        },
    }
}

fn emitBash(
    allocator: std.mem.Allocator,
    comptime levels: []const Level,
    comptime bindings: []const Binding,
    ident: String,
    app_name: String,
) std.mem.Allocator.Error!String {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendBashFnName(&out, allocator, ident, "_filter() {\n");
    try out.appendSlice(allocator,
        \\    local cur=$1; shift
        \\    COMPREPLY=()
        \\    local c
        \\    for c in "$@"; do
        \\        [[ $c == "$cur"* ]] && COMPREPLY+=("$c")
        \\    done
        \\}
        \\
        \\
    );

    try appendBashFnName(&out, allocator, ident, "_value_flag() {\n");
    try out.appendSlice(allocator,
        \\    case "$1" in
        \\    *=*) return 1 ;;
        \\
    );
    inline for (comptime valueFlagSpellings(levels)) |spelling| {
        try out.appendSlice(allocator, "    ");
        try appendQuoted(&out, allocator, spelling, .posix);
        try out.appendSlice(allocator, ") return 0 ;;\n");
    }
    try out.appendSlice(allocator,
        \\    esac
        \\    return 1
        \\}
        \\
        \\
    );

    if (bindings.len != 0) {
        try appendBashDynamicHelper(&out, allocator, ident);
    }

    try appendBashFnName(&out, allocator, ident, "() {\n");
    try out.appendSlice(allocator,
        \\    local cur prev level=0 pos=0 literal=0
        \\    local vflag= vform=bare
        \\    local i tok end
        \\    COMPREPLY=()
        \\    cur=${COMP_WORDS[COMP_CWORD]}
        \\    prev=
        \\    if (( COMP_CWORD >= 1 )); then
        \\        prev=${COMP_WORDS[COMP_CWORD-1]}
        \\    fi
        \\    end=$((COMP_CWORD - 1))
        \\    i=1
        \\    while (( i <= end )); do
        \\        tok=${COMP_WORDS[i]}
        \\        if (( literal )); then
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        if [[ $tok == '--' ]]; then
        \\            literal=1
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && $tok == *=* ]]; then
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        if
    );
    try appendBashFnName(&out, allocator, ident, "_value_flag \"$tok\"; then\n");
    try out.appendSlice(allocator,
        \\            if (( i + 1 <= end )) && [[ ${COMP_WORDS[i+1]} == '=' ]]; then
        \\                i=$((i + 3))
        \\            else
        \\                i=$((i + 2))
        \\            fi
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && ${#tok} -gt 1 ]]; then
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        pos=$((pos + 1))
        \\        case "$level" in
        \\
    );
    inline for (levels) |level| {
        try out.print(allocator, "        {})\n", .{level.rank});
        const cmds = comptime completionCommands(level);
        if (cmds.len != 0) {
            try out.appendSlice(allocator, "            case \"$tok\" in\n");
            inline for (cmds) |c| {
                inline for (comptime completionCommandSpellings(c)) |spelling| {
                    try out.appendSlice(allocator, "            ");
                    try appendQuoted(&out, allocator, spelling, .posix);
                    try out.print(allocator, ") level={} pos=0 ;;\n", .{c.rank});
                }
            }
            try out.appendSlice(allocator, "            esac\n");
        }
        try out.appendSlice(allocator, "            ;;\n");
    }
    try out.appendSlice(allocator,
        \\        esac
        \\        i=$((i + 1))
        \\    done
        \\    if (( literal )); then
        \\        return
        \\    fi
        \\    if [[ $cur == '=' ]] &&
    );
    try appendBashFnName(&out, allocator, ident, "_value_flag \"$prev\"; then\n");
    try out.appendSlice(allocator,
        \\        vflag=$prev
        \\        vform=eq
        \\    elif [[ $prev == '=' ]] && (( COMP_CWORD >= 2 )); then
        \\        vflag=${COMP_WORDS[COMP_CWORD-2]}
        \\    elif
    );
    try appendBashFnName(&out, allocator, ident, "_value_flag \"$prev\"; then\n");
    try out.appendSlice(allocator,
        \\        vflag=$prev
        \\    elif [[ $cur == -* && $cur == *=* ]]; then
        \\        vflag=${cur%%=*}
        \\        vform=full
        \\    fi
        \\    case "$level" in
        \\
    );
    inline for (levels) |level| {
        const arms = comptime completionValueArms(level);
        const entries = comptime completionEntries(level);
        const flags = comptime completionEntriesOfKind(entries, .flag);
        const commands = comptime completionEntriesOfKind(entries, .command);
        try out.print(allocator, "    {})\n", .{level.rank});
        try appendLevelMarker(&out, allocator, level);
        if (comptime levelHasPredictor(level)) {
            try out.appendSlice(allocator,
                \\        local vprefix= vpart=$cur
                \\        case "$vform" in
                \\        eq) vprefix='='; vpart= ;;
                \\        full) vprefix=${cur%%=*}=; vpart=${cur#*=} ;;
                \\        esac
                \\
            );
        }
        if (arms.len != 0) {
            try out.appendSlice(allocator, "        case \"$vflag\" in\n");
            inline for (arms) |arm| {
                try out.appendSlice(allocator, "        ");
                try appendQuoted(&out, allocator, arm.spelling, .posix);
                try out.appendSlice(allocator, ")\n");
                const names = comptime enumWireNames(arm.vtype);
                if (names.len != 0) {
                    try out.appendSlice(allocator, "            case \"$vform\" in\n");
                    try out.appendSlice(allocator, "            eq) ");
                    try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime enumSpellings(arm.vtype, "="));
                    try out.appendSlice(allocator, " ;;\n");
                    const full_prefix = comptime std.fmt.comptimePrint("{s}=", .{arm.spelling});
                    try out.appendSlice(allocator, "            full) ");
                    try appendBashFilterCall(&out, allocator, ident, "\"$vflag=\"", comptime enumSpellings(arm.vtype, full_prefix));
                    try out.appendSlice(allocator, " ;;\n");
                    try out.appendSlice(allocator, "            *) ");
                    try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", names);
                    try out.appendSlice(allocator, " ;;\n");
                    try out.appendSlice(allocator, "            esac\n");
                    try out.appendSlice(allocator, "            return\n");
                } else if (comptime armNativeFs(arm)) |opts| {
                    try appendBashNativeFs(&out, allocator, "            ", opts, false);
                    try out.appendSlice(allocator, "            return\n");
                } else if (comptime arm.predictor) |predictor| {
                    try out.appendSlice(allocator, "            compopt +o default\n");
                    switch (predictor) {
                        .disabled => {},
                        .fs, .callback => {
                            if (comptime arm.binding) |index| {
                                try appendBashDynamicCall(
                                    &out,
                                    allocator,
                                    ident,
                                    index,
                                    "\"$vprefix\"",
                                    "\"$vpart\"",
                                    "            ",
                                );
                            }
                        },
                        .launch, .call => {
                            try out.appendSlice(allocator, "            local cur=$vpart\n");
                            _ = try appendBashInline(
                                &out,
                                allocator,
                                "            ",
                                predictor,
                                "$vpart",
                                "$vprefix",
                            );
                        },
                    }
                    try out.appendSlice(allocator, "            return\n");
                } else {
                    try out.appendSlice(allocator, "            return\n");
                }
                try out.appendSlice(allocator, "            ;;\n");
            }
            try out.appendSlice(allocator, "        esac\n");
        }
        if (commands.len != 0) {
            try out.appendSlice(allocator, "        if [[ -z $cur ]]; then\n            ");
            try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime completionSpellings(commands));
            try out.appendSlice(allocator, "\n        else\n            ");
            try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime completionSpellings(entries));
            try out.appendSlice(allocator, "\n        fi\n");
        } else if (level.arguments.len != 0) {
            try out.appendSlice(allocator, "        if [[ -z $cur ]]; then\n            case \"$pos\" in\n");
            inline for (0..level.arguments.len) |slot| {
                if (comptime argumentPredictor(level, slot) == null) {
                    const values = comptime completionArgumentEntries(level, slot);
                    try out.print(allocator, "            {}) ", .{slot});
                    if (values.len == 0) {
                        try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime completionSpellings(flags));
                    } else {
                        try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime completionSpellings(values));
                    }
                    try out.appendSlice(allocator, " ;;\n");
                } else {
                    try out.print(allocator, "            {})\n", .{slot});
                    try appendBashSlotPredictor(&out, allocator, ident, level, slot, .empty);
                    try out.appendSlice(allocator, "                ;;\n");
                }
            }
            try out.appendSlice(allocator, "            *) ");
            try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime completionSpellings(flags));
            try out.appendSlice(allocator, " ;;\n            esac\n        else\n            case \"$pos\" in\n");
            inline for (0..level.arguments.len) |slot| {
                if (comptime argumentPredictor(level, slot) == null) {
                    try out.print(allocator, "            {}) ", .{slot});
                    try appendBashFilterCall(
                        &out,
                        allocator,
                        ident,
                        "\"$cur\"",
                        comptime completionSpellings(completionEntriesWithSlot(level, slot)),
                    );
                    try out.appendSlice(allocator, " ;;\n");
                } else {
                    try out.print(allocator, "            {})\n", .{slot});
                    try appendBashSlotPredictor(&out, allocator, ident, level, slot, .prefix);
                    try out.appendSlice(allocator, "                ;;\n");
                }
            }
            try out.appendSlice(allocator, "            *) ");
            try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime completionSpellings(entries));
            try out.appendSlice(allocator, " ;;\n            esac\n        fi\n");
        } else {
            try out.appendSlice(allocator, "        ");
            try appendBashFilterCall(&out, allocator, ident, "\"$cur\"", comptime completionSpellings(entries));
            try out.appendSlice(allocator, "\n");
        }
        try out.appendSlice(allocator, "        ;;\n");
    }
    try out.appendSlice(allocator,
        \\    esac
        \\}
        \\
        \\complete -o default -F
    );
    try appendBashFnName(&out, allocator, ident, " ");
    try appendQuoted(&out, allocator, app_name, .posix);
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

/// Append one hidden-route call line for zsh.
fn appendZshDynamicCall(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    index: usize,
    prefix_expr: String,
    cur_expr: String,
    indent: String,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, indent);
    try appendZshFnName(out, allocator, ident, "_dynamic ");
    try out.print(allocator, "{} ", .{index});
    try out.appendSlice(allocator, prefix_expr);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, cur_expr);
    try out.append(allocator, '\n');
}

/// Append the zsh body of positional slot `slot` when it declares a predictor,
/// wrapped in its own `case "$pos"` arm. An empty current word runs the
/// predictor immediately and returns `0` so zsh does not fall through to its
/// default completer; a non-empty prefix renders the static rows first and adds
/// the predictor's values after them.
fn appendZshSlotPredictor(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    comptime level: Level,
    comptime slot: usize,
) std.mem.Allocator.Error!void {
    const indent = "        ";
    const body_indent = "            ";
    const predictor = comptime argumentPredictor(level, slot) orelse return;

    try out.print(allocator, "{s}{})\n", .{ indent, slot });
    try out.appendSlice(allocator, body_indent);
    try out.appendSlice(allocator, "if [[ -z $PREFIX ]]; then\n");
    try appendZshSlotArm(out, allocator, ident, level, slot, predictor, .empty);
    try out.appendSlice(allocator, body_indent);
    try out.appendSlice(allocator, "    return 0\n");
    try out.appendSlice(allocator, body_indent);
    try out.appendSlice(allocator, "fi\n");
    try out.appendSlice(allocator, body_indent);
    try appendZshFnName(out, allocator, ident, "_rows ");
    try out.print(allocator, "{} $pos\n", .{level.rank});
    try appendZshSlotArm(out, allocator, ident, level, slot, predictor, .prefix);
    try out.appendSlice(allocator, body_indent);
    try out.appendSlice(allocator, "return 0\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, ";;\n");
}

/// The predict-form body of one zsh positional slot arm.
fn appendZshSlotArm(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    comptime level: Level,
    comptime slot: usize,
    comptime predictor: Completion.Predictor,
    comptime phase: SlotPhase,
) std.mem.Allocator.Error!void {
    const indent = if (phase == .empty) "                " else "            ";
    switch (predictor) {
        .disabled => {},
        .fs => |opts| {
            if (isNativeFs(opts)) {
                try appendZshNativeFs(out, allocator, indent, opts);
            } else if (comptime argumentBinding(level, slot)) |index| {
                try appendZshDynamicCall(
                    out,
                    allocator,
                    ident,
                    index,
                    "\"\"",
                    if (phase == .empty) "\"\"" else "\"$PREFIX\"",
                    indent,
                );
            }
        },
        .callback => {
            if (comptime argumentBinding(level, slot)) |index| {
                try appendZshDynamicCall(
                    out,
                    allocator,
                    ident,
                    index,
                    "\"\"",
                    if (phase == .empty) "\"\"" else "\"$PREFIX\"",
                    indent,
                );
            }
        },
        .launch, .call => {
            _ = try appendZshInline(
                out,
                allocator,
                indent,
                predictor,
                if (phase == .empty) "" else "$PREFIX",
                "",
            );
        },
    }
}

fn emitZsh(
    allocator: std.mem.Allocator,
    comptime levels: []const Level,
    comptime bindings: []const Binding,
    ident: String,
    app_name: String,
) std.mem.Allocator.Error!String {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "#compdef ");
    try out.appendSlice(allocator, app_name);
    try out.append(allocator, '\n');

    try appendZshFnName(&out, allocator, ident, "_value_flag() {\n");
    try out.appendSlice(allocator, "    case \"$1\" in\n    *=*) return 1 ;;\n");
    inline for (comptime valueFlagSpellings(levels)) |spelling| {
        try out.appendSlice(allocator, "    ");
        try appendQuoted(&out, allocator, spelling, .posix);
        try out.appendSlice(allocator, ") return 0 ;;\n");
    }
    try out.appendSlice(allocator, "    esac\n    return 1\n}\n\n");

    try appendZshRowsHelper(&out, allocator, ident, levels);

    if (bindings.len != 0) {
        try appendZshDynamicHelper(&out, allocator, ident);
    }

    try appendZshFnName(&out, allocator, ident, "() {\n");
    try out.appendSlice(allocator,
        \\    emulate -L zsh
        \\    local level=0 pos=0 literal=0 vflag= vform=bare i tok end
        \\    local -a cands displays seen
        \\    end=$(( CURRENT - 1 ))
        \\    i=2
        \\    while (( i <= end )); do
        \\        tok=${words[i]}
        \\        if (( literal )); then
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        if [[ $tok == '--' ]]; then
        \\            literal=1
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && $tok == *=* ]]; then
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        if
    );
    try appendZshFnName(&out, allocator, ident, "_value_flag \"$tok\"; then\n");
    try out.appendSlice(allocator,
        \\            if (( i + 1 <= end )) && [[ ${words[i+1]} == '=' ]]; then
        \\                i=$(( i + 3 ))
        \\            else
        \\                i=$(( i + 2 ))
        \\            fi
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && ${#tok} -gt 1 ]]; then
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        pos=$(( pos + 1 ))
        \\        case "$level" in
        \\
    );
    inline for (levels) |level| {
        try out.print(allocator, "        {})\n", .{level.rank});
        const cmds = comptime completionCommands(level);
        if (cmds.len != 0) {
            try out.appendSlice(allocator, "            case \"$tok\" in\n");
            inline for (cmds) |c| {
                inline for (comptime completionCommandSpellings(c)) |spelling| {
                    try out.appendSlice(allocator, "            ");
                    try appendQuoted(&out, allocator, spelling, .posix);
                    try out.print(allocator, ") level={} pos=0 ;;\n", .{c.rank});
                }
            }
            try out.appendSlice(allocator, "            esac\n");
        }
        try out.appendSlice(allocator, "            ;;\n");
    }
    try out.appendSlice(allocator,
        \\        esac
        \\        i=$(( i + 1 ))
        \\    done
        \\    if (( literal )); then
        \\        return 1
        \\    fi
        \\    if (( CURRENT >= 2 )); then
        \\        if [[ $PREFIX == '=' ]] &&
    );
    try appendZshFnName(&out, allocator, ident, "_value_flag \"$words[CURRENT-1]\"; then\n");
    try out.appendSlice(allocator,
        \\            vflag=$words[CURRENT-1]
        \\            vform=eq
        \\        elif [[ $words[CURRENT-1] == '=' ]] && (( CURRENT >= 3 )); then
        \\            vflag=$words[CURRENT-2]
        \\        elif
    );
    try appendZshFnName(&out, allocator, ident, "_value_flag \"$words[CURRENT-1]\"; then\n");
    try out.appendSlice(allocator,
        \\            vflag=$words[CURRENT-1]
        \\        fi
        \\    fi
        \\    if [[ -z $vflag && $PREFIX == -* && $PREFIX == *=* ]]; then
        \\        vflag=${PREFIX%%=*}
        \\        vform=full
        \\    fi
        \\    case "$level" in
        \\
    );
    inline for (levels) |level| {
        try out.print(allocator, "    {})\n", .{level.rank});
        try appendLevelMarker(&out, allocator, level);
        if (comptime levelHasPredictor(level)) {
            try out.appendSlice(allocator,
                \\        local vprefix= vpart=$PREFIX
                \\        case "$vform" in
                \\        eq) vprefix='='; vpart= ;;
                \\        full) vprefix=${PREFIX%%=*}=; vpart=${PREFIX#*=} ;;
                \\        esac
                \\
            );
        }
        const arms = comptime completionValueArms(level);
        if (arms.len != 0) {
            try out.appendSlice(allocator, "        case \"$vflag\" in\n");
            inline for (arms) |arm| {
                try out.appendSlice(allocator, "        ");
                try appendQuoted(&out, allocator, arm.spelling, .posix);
                try out.appendSlice(allocator, ")\n");
                const names = comptime enumWireNames(arm.vtype);
                if (names.len != 0) {
                    try out.appendSlice(allocator, "            case \"$vform\" in\n");

                    try out.appendSlice(allocator, "            eq)\n");
                    try appendZshCandidates(&out, allocator, "                ", comptime enumCandidates(arm.vtype, "="));
                    try out.appendSlice(allocator, "                ;;\n");

                    const full_prefix = comptime std.fmt.comptimePrint("{s}=", .{arm.spelling});
                    try out.appendSlice(allocator, "            full)\n");
                    try appendZshCandidates(&out, allocator, "                ", comptime enumCandidates(arm.vtype, full_prefix));
                    try out.appendSlice(allocator, "                ;;\n");

                    try out.appendSlice(allocator, "            *)\n");
                    try appendZshCandidates(&out, allocator, "                ", comptime enumCandidates(arm.vtype, ""));
                    try out.appendSlice(allocator, "                ;;\n");

                    try out.appendSlice(allocator, "            esac\n            return\n");
                } else if (comptime armNativeFs(arm)) |opts| {
                    try appendZshNativeFs(&out, allocator, "            ", opts);
                    try out.appendSlice(allocator, "            return 0\n");
                } else if (comptime arm.predictor) |predictor| {
                    switch (predictor) {
                        .disabled => {},
                        .fs, .callback => {
                            if (comptime arm.binding) |index| {
                                try appendZshDynamicCall(
                                    &out,
                                    allocator,
                                    ident,
                                    index,
                                    "\"$vprefix\"",
                                    "\"$vpart\"",
                                    "            ",
                                );
                            }
                        },
                        .launch, .call => {
                            _ = try appendZshInline(
                                &out,
                                allocator,
                                "            ",
                                predictor,
                                "$vpart",
                                "$vprefix",
                            );
                        },
                    }
                    try out.appendSlice(allocator, "            return 0\n");
                } else {
                    try out.appendSlice(allocator, "            return 1\n");
                }
                try out.appendSlice(allocator, "            ;;\n");
            }
            try out.appendSlice(allocator, "        esac\n");
        }
        const slot_predictors = comptime blk: {
            for (0..level.arguments.len) |slot| {
                if (argumentPredictor(level, slot) != null) break :blk true;
            }
            break :blk false;
        };
        if (slot_predictors) {
            try out.appendSlice(allocator, "        case \"$pos\" in\n");
            inline for (0..level.arguments.len) |slot| {
                if (comptime argumentPredictor(level, slot) != null) {
                    try appendZshSlotPredictor(&out, allocator, ident, level, slot);
                }
            }
            try out.appendSlice(allocator, "        esac\n");
        }
        try out.appendSlice(allocator, "        ");
        try appendZshFnName(&out, allocator, ident, "_rows ");
        try out.print(allocator, "{} $pos\n", .{level.rank});
        try out.appendSlice(allocator, "        return\n        ;;\n");
    }
    try out.appendSlice(allocator,
        \\    esac
        \\    return 1
        \\}
        \\
    );

    try out.appendSlice(allocator, "if [[ $funcstack[1] == '");
    try appendZshFnName(&out, allocator, ident, "' ]]; then\n    ");
    try appendZshFnName(&out, allocator, ident, " \"$@\"\nelse\n    compdef ");
    try appendZshFnName(&out, allocator, ident, " ");
    try appendQuoted(&out, allocator, app_name, .posix);
    try out.appendSlice(allocator, "\nfi\n");
    return try out.toOwnedSlice(allocator);
}

/// Append `__dap_<ident><suffix>` to `out`.
fn appendFishFnName(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    suffix: String,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, "__dap_");
    try out.appendSlice(allocator, ident);
    try out.appendSlice(allocator, suffix);
}

/// Whether `word` is representable in fish's candidate line protocol, which
/// separates the candidate from its description with a tab and candidates with
/// newlines.
fn fishWordIsRepresentable(word: String) bool {
    return std.mem.indexOfAny(u8, word, "\t\n") == null;
}

/// Wire spellings of `c` fish can match: names and synonyms with a tab or
/// newline cannot appear in a `case` pattern or a printed candidate.
fn fishCommandSpellings(comptime c: CommandEntry) []const String {
    const spellings = completionCommandSpellings(c);
    const first_ok = spellings.len >= 1 and fishWordIsRepresentable(spellings[0]);
    if (spellings.len == 2) {
        const second_ok = fishWordIsRepresentable(spellings[1]);
        if (first_ok and second_ok) return spellings;
        if (first_ok) return spellings[0..1];
        if (second_ok) return spellings[1..2];
        return &.{};
    }
    if (first_ok) return spellings;
    return &.{};
}

/// Commands of `level` whose names fish can match.
fn fishCommands(comptime level: Level) []const CommandEntry {
    comptime {
        var cmds: []const CommandEntry = &.{};
        for (completionCommands(level)) |c| {
            if (fishCommandSpellings(c).len == 0) continue;
            cmds = cmds ++ &[_]CommandEntry{c};
        }
        return cmds;
    }
}

/// Append one `printf '%s\n' 'word'...` line of bare fish candidates.
fn appendFishWords(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    words: []const String,
) std.mem.Allocator.Error!void {
    var any = false;
    for (words) |word| {
        if (fishWordIsRepresentable(word)) any = true;
    }
    if (!any) return;

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "printf '%s\\n'");
    for (words) |word| {
        if (!fishWordIsRepresentable(word)) continue;
        try out.append(allocator, ' ');
        try appendQuoted(out, allocator, word, .fish);
    }
    try out.append(allocator, '\n');
}

/// Append `cands` as fish candidate lines, `candidate<TAB>description` when a
/// value carries help and bare words otherwise.
fn appendFishCandidates(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: String,
    cands: []const CompletionCandidate,
) std.mem.Allocator.Error!void {
    var any_help = false;
    for (cands) |c| {
        if (c.help.len != 0) any_help = true;
    }
    if (!any_help) {
        var words: std.ArrayList(String) = .empty;
        defer words.deinit(allocator);
        for (cands) |c| try words.append(allocator, c.spelling);
        return appendFishWords(out, allocator, indent, words.items);
    }

    for (cands) |c| {
        if (!fishWordIsRepresentable(c.spelling)) continue;
        try out.appendSlice(allocator, indent);
        if (c.help.len == 0) {
            try out.appendSlice(allocator, "printf '%s\\n' ");
            try appendQuoted(out, allocator, c.spelling, .fish);
        } else {
            try out.appendSlice(allocator, "printf '%s\\t%s\\n' ");
            try appendQuoted(out, allocator, c.spelling, .fish);
            try out.append(allocator, ' ');
            var desc: std.ArrayList(u8) = .empty;
            defer desc.deinit(allocator);
            try desc.appendSlice(allocator, "-- ");
            try appendSanitized(&desc, allocator, c.help);
            try appendQuoted(out, allocator, desc.items, .fish);
        }
        try out.append(allocator, '\n');
    }
}

/// Rows fish can carry: a pair survives only when both spellings are
/// representable, otherwise the representable spelling becomes a one-name row,
/// and an entry with neither is dropped.
fn fishRows(comptime level: Level) []const CompletionRow {
    comptime {
        var out: []const CompletionRow = &.{};
        for (completionRows(level)) |row| {
            const spelling_ok = fishWordIsRepresentable(row.entry.spelling);
            if (row.entry.alias) |alias| {
                const alias_ok = fishWordIsRepresentable(alias);
                if (spelling_ok and alias_ok) {
                    out = out ++ &[_]CompletionRow{row};
                } else if (spelling_ok) {
                    out = out ++ &[_]CompletionRow{.{
                        .entry = .{
                            .spelling = row.entry.spelling,
                            .alias = null,
                            .help = row.entry.help,
                            .kind = row.entry.kind,
                            .family = row.entry.family,
                        },
                        .slot = row.slot,
                        .key_primary = row.key_primary,
                        .key_alias = null,
                    }};
                } else if (alias_ok) {
                    out = out ++ &[_]CompletionRow{.{
                        .entry = .{
                            .spelling = alias,
                            .alias = null,
                            .help = row.entry.help,
                            .kind = row.entry.kind,
                            .family = row.entry.family,
                        },
                        .slot = row.slot,
                        .key_primary = row.key_alias.?,
                        .key_alias = null,
                    }};
                }
                continue;
            }
            if (spelling_ok) out = out ++ &[_]CompletionRow{row};
        }
        var sorted: []const CompletionRow = &.{};
        for (out) |row| {
            var pos = sorted.len;
            for (sorted, 0..) |prev, i| {
                if (row.key_primary < prev.key_primary) {
                    pos = i;
                    break;
                }
            }
            sorted = sorted[0..pos] ++ &[_]CompletionRow{row} ++ sorted[pos..];
        }
        return sorted;
    }
}

/// Append the shared fish row helper. It holds one static row table per level
/// and prints `candidate<TAB>description` lines in phase and prefix order;
/// fish decides the final column spacing.
fn appendFishRowsHelper(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    comptime levels: []const Level,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, "function ");
    try appendFishFnName(out, allocator, ident, "_rows\n");
    try out.appendSlice(allocator,
        \\    set -l rank $argv[1]
        \\    set -l pos $argv[2]
        \\    set -l cur $argv[3]
        \\    set -l spell
        \\    set -l alias
        \\    set -l help
        \\    set -l kind
        \\    set -l slot
        \\    set -l kp
        \\    set -l ka
        \\    set -l phase 3
        \\    switch $rank
        \\
    );
    inline for (levels) |level| {
        const rows = comptime fishRows(level);
        const entries = comptime completionEntries(level);
        const commands = comptime completionEntriesOfKind(entries, .command);

        try out.print(allocator, "    case {}\n", .{level.rank});

        try out.appendSlice(allocator, "        set spell");
        for (rows) |row| {
            try out.append(allocator, ' ');
            try appendQuoted(out, allocator, row.entry.spelling, .fish);
        }
        try out.appendSlice(allocator, "\n        set alias");
        for (rows) |row| {
            try out.append(allocator, ' ');
            try appendQuoted(out, allocator, row.entry.alias orelse "", .fish);
        }
        try out.appendSlice(allocator, "\n        set help");
        for (rows) |row| {
            try out.append(allocator, ' ');
            try appendQuotedSanitized(out, allocator, row.entry.help, .fish);
        }
        try out.appendSlice(allocator, "\n        set kind");
        for (rows) |row| try out.print(allocator, " {}", .{@backingInt(row.entry.kind)});
        try out.appendSlice(allocator, "\n        set slot");
        for (rows) |row| try out.print(allocator, " {}", .{row.slot});
        try out.appendSlice(allocator, "\n        set kp");
        for (rows) |row| try out.print(allocator, " {}", .{row.key_primary});
        try out.appendSlice(allocator, "\n        set ka");
        for (rows) |row| try out.print(allocator, " {}", .{row.key_alias orelse 0});
        try out.append(allocator, '\n');

        if (commands.len != 0) {
            try out.appendSlice(allocator,
                \\        set phase 0
                \\        if test -n "$cur"
                \\            set phase 3
                \\        else
                \\            set phase 2
                \\        end
                \\
            );
        } else if (level.arguments.len != 0) {
            try out.appendSlice(allocator,
                \\        set phase 0
                \\        if test -n "$cur"
                \\            set phase 3
                \\        else
                \\            switch $pos
                \\
            );
            inline for (0..level.arguments.len) |slot| {
                const values = comptime completionArgumentEntries(level, slot);
                if (values.len != 0) {
                    try out.print(allocator, "            case {}\n                set phase 1\n", .{slot});
                }
            }
            try out.appendSlice(allocator,
                \\            end
                \\        end
                \\
            );
        } else {
            try out.appendSlice(allocator,
                \\        set phase 0
                \\        if test -n "$cur"
                \\            set phase 3
                \\        end
                \\
            );
        }
    }
    try out.appendSlice(allocator, "    end\n");
    try out.appendSlice(allocator,
        \\    set -l sel_spell
        \\    set -l sel_alias
        \\    set -l sel_help
        \\    set -l sel_key
        \\    for i in (seq (count $spell))
        \\        set -l k $kind[$i]
        \\        set -l sl $slot[$i]
        \\        if test $phase -eq 0
        \\            test $k -eq 0; or continue
        \\        else if test $phase -eq 2
        \\            test $k -eq 2; or continue
        \\        else if test $phase -eq 1
        \\            test $sl -eq $pos; or continue
        \\        else if test $k -eq 1
        \\            test $sl -eq $pos; or continue
        \\        end
        \\        set -l s $spell[$i]
        \\        set -l a $alias[$i]
        \\        set -l hit 0
        \\        if test (string sub -l (string length -- $cur) -- $s) = "$cur"
        \\            set hit 1
        \\        end
        \\        set -l amatch 0
        \\        if test -n "$a"; and test (string sub -l (string length -- $cur) -- $a) = "$cur"
        \\            set amatch 1
        \\        end
        \\        if test $amatch -eq 1
        \\            if test $hit -eq 1
        \\                set sel_spell $sel_spell "$s"
        \\                set sel_alias $sel_alias "$a"
        \\                set sel_key $sel_key $kp[$i]
        \\            else
        \\                set sel_spell $sel_spell "$a"
        \\                set sel_alias $sel_alias ''
        \\                set sel_key $sel_key $ka[$i]
        \\            end
        \\        else if test $hit -eq 1
        \\            set sel_spell $sel_spell "$s"
        \\            set sel_alias $sel_alias ''
        \\            set sel_key $sel_key $kp[$i]
        \\        else
        \\            continue
        \\        end
        \\        set sel_help $sel_help "$help[$i]"
        \\    end
        \\    set -l n (count $sel_spell)
        \\    if test $n -eq 0
        \\        return 1
        \\    end
        \\    for i in (seq 2 $n)
        \\        set -l ks $sel_spell[$i]
        \\        set -l ka2 $sel_alias[$i]
        \\        set -l kh $sel_help[$i]
        \\        set -l kk $sel_key[$i]
        \\        set -l j (math $i - 1)
        \\        while test $j -ge 1
        \\            if test $kk -lt $sel_key[$j]
        \\                set sel_spell[(math $j + 1)] $sel_spell[$j]
        \\                set sel_alias[(math $j + 1)] $sel_alias[$j]
        \\                set sel_help[(math $j + 1)] $sel_help[$j]
        \\                set sel_key[(math $j + 1)] $sel_key[$j]
        \\                set j (math $j - 1)
        \\            else
        \\                break
        \\            end
        \\        end
        \\        set sel_spell[(math $j + 1)] $ks
        \\        set sel_alias[(math $j + 1)] $ka2
        \\        set sel_help[(math $j + 1)] $kh
        \\        set sel_key[(math $j + 1)] $kk
        \\    end
        \\    for i in (seq $n)
        \\        set -l s $sel_spell[$i]
        \\        set -l a $sel_alias[$i]
        \\        set -l h $sel_help[$i]
        \\        if test -n "$h"
        \\            if test -n "$a"
        \\                printf '%s\t%s\n' "$s" "$a  -- $h"
        \\            else
        \\                printf '%s\t%s\n' "$s" "-- $h"
        \\            end
        \\        else if test -n "$a"
        \\            printf '%s\t%s\n' "$s" "$a"
        \\        else
        \\            printf '%s\n' "$s"
        \\        end
        \\    end
        \\    return 0
        \\end
        \\
        \\
    );
}

/// Append one hidden-route call line for fish.
fn appendFishDynamicCall(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    index: usize,
    prefix_expr: String,
    cur_expr: String,
    indent: String,
    comptime exclude: []const String,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, indent);
    try appendFishFnName(out, allocator, ident, "_dynamic ");
    try out.print(allocator, "{} ", .{index});
    try out.appendSlice(allocator, prefix_expr);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, cur_expr);
    for (exclude) |spelling| {
        try out.append(allocator, ' ');
        try appendQuoted(out, allocator, spelling, .fish);
    }
    try out.append(allocator, '\n');
}

/// Append the fish body of positional slot `slot` when it declares a
/// predictor, wrapped in its own `case` arm of the caller's `switch $pos`. An
/// empty current word runs the predictor immediately; a non-empty prefix
/// prints the static rows first and the predictor's values after them.
fn appendFishSlotPredictor(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    comptime level: Level,
    comptime slot: usize,
) std.mem.Allocator.Error!void {
    const body_indent = "                ";
    const predictor = comptime argumentPredictor(level, slot) orelse return;

    try out.print(allocator, "        case {}\n", .{slot});
    try out.appendSlice(allocator, "            if test -z \"$cur\"\n");
    try appendFishSlotArm(out, allocator, ident, level, slot, predictor, .empty);
    try out.appendSlice(allocator, "            else\n");
    try out.appendSlice(allocator, body_indent);
    try appendFishFnName(out, allocator, ident, "_rows ");
    try out.print(allocator, "{} $pos \"$cur\"\n", .{level.rank});
    try appendFishSlotArm(out, allocator, ident, level, slot, predictor, .prefix);
    try out.appendSlice(allocator, "            end\n");
    try out.appendSlice(allocator, "            return\n");
}

/// The predictor body of one fish positional slot arm.
fn appendFishSlotArm(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ident: String,
    comptime level: Level,
    comptime slot: usize,
    comptime predictor: Completion.Predictor,
    comptime phase: SlotPhase,
) std.mem.Allocator.Error!void {
    const indent = "                ";
    switch (predictor) {
        .disabled => {},
        .fs => |opts| {
            if (isNativeFs(opts)) {
                try appendFishNativeFs(out, allocator, indent, opts);
            } else if (comptime argumentBinding(level, slot)) |index| {
                try appendFishDynamicCall(
                    out,
                    allocator,
                    ident,
                    index,
                    "''",
                    if (phase == .empty) "''" else "\"$cur\"",
                    indent,
                    if (phase == .empty) &.{} else comptime completionSpellings(completionEntriesWithSlot(level, slot)),
                );
            }
        },
        .callback => {
            if (comptime argumentBinding(level, slot)) |index| {
                try appendFishDynamicCall(
                    out,
                    allocator,
                    ident,
                    index,
                    "''",
                    if (phase == .empty) "''" else "\"$cur\"",
                    indent,
                    if (phase == .empty) &.{} else comptime completionSpellings(completionEntriesWithSlot(level, slot)),
                );
            }
        },
        .launch, .call => {
            const exclude: []const String = if (phase == .empty)
                &.{}
            else
                comptime completionSpellings(completionEntriesWithSlot(level, slot));
            _ = try appendFishInline(
                out,
                allocator,
                indent,
                predictor,
                if (phase == .empty) "" else "$cur",
                "",
                exclude,
            );
        },
    }
}

fn emitFish(
    allocator: std.mem.Allocator,
    comptime levels: []const Level,
    comptime bindings: []const Binding,
    ident: String,
    app_name: String,
) std.mem.Allocator.Error!String {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "function ");
    try appendFishFnName(&out, allocator, ident, "_value_flag\n");
    try out.appendSlice(allocator,
        \\    switch $argv[1]
        \\    case '*=*'
        \\        return 1
        \\
    );
    const spellings = comptime valueFlagSpellings(levels);
    if (spellings.len != 0) {
        try out.appendSlice(allocator, "    case");
        inline for (spellings) |spelling| {
            try out.append(allocator, ' ');
            try appendQuoted(&out, allocator, spelling, .fish);
        }
        try out.appendSlice(allocator, "\n        return 0\n");
    }
    try out.appendSlice(allocator,
        \\    end
        \\    return 1
        \\end
        \\
        \\
    );

    try appendFishRowsHelper(&out, allocator, ident, levels);

    if (bindings.len != 0) {
        try appendFishDynamicHelper(&out, allocator, ident);
    }

    try out.appendSlice(allocator, "function ");
    try appendFishFnName(&out, allocator, ident, "_complete\n");
    try out.appendSlice(allocator,
        \\    set -l toks (commandline -opc)
        \\    set -e toks[1]
        \\    set -l cur (commandline -ct)
        \\    set -l prev ''
        \\    if test (count $toks) -ge 1
        \\        set prev $toks[-1]
        \\    end
        \\    set -l level 0
        \\    set -l pos 0
        \\    set -l literal 0
        \\    set -l i 1
        \\    set -l end (count $toks)
        \\    while test $i -le $end
        \\        set -l tok $toks[$i]
        \\        if test $literal -eq 1
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        if test "$tok" = '--'
        \\            set literal 1
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        if string match -qr '^-.*=' -- $tok
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        if
    );
    try appendFishFnName(&out, allocator, ident, "_value_flag $tok\n");
    try out.appendSlice(allocator,
        \\            set i (math $i + 2)
        \\            continue
        \\        end
        \\        if string match -qr '^-' -- $tok
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        set pos (math $pos + 1)
        \\
    );

    const has_descent = comptime blk: {
        for (levels) |level| {
            if (fishCommands(level).len != 0) break :blk true;
        }
        break :blk false;
    };
    if (has_descent) {
        try out.appendSlice(allocator, "        switch $level\n");
        inline for (levels) |level| {
            const cmds = comptime fishCommands(level);
            if (cmds.len != 0) {
                try out.print(allocator, "        case {}\n", .{level.rank});
                try out.appendSlice(allocator, "            switch $tok\n");
                inline for (cmds) |c| {
                    inline for (comptime fishCommandSpellings(c)) |spelling| {
                        try out.appendSlice(allocator, "            case ");
                        try appendQuoted(&out, allocator, spelling, .fish);
                        try out.print(allocator, "\n                set level {}\n                set pos 0\n", .{c.rank});
                    }
                }
                try out.appendSlice(allocator, "            end\n");
            }
        }
        try out.appendSlice(allocator, "        end\n");
    }

    try out.appendSlice(allocator,
        \\        set i (math $i + 1)
        \\    end
        \\    if test $literal -eq 1
        \\        return
        \\    end
        \\    set -l vflag ''
        \\    set -l vform bare
        \\    if string match -qr '^-.*=' -- $cur
        \\        set vflag (string split -m 1 '=' -- $cur)[1]
        \\        set vform full
        \\    else if test -n "$prev"
        \\        if
    );
    try appendFishFnName(&out, allocator, ident, "_value_flag $prev\n");
    try out.appendSlice(allocator,
        \\            set vflag $prev
        \\        end
        \\    end
        \\    switch $level
        \\
    );

    inline for (levels) |level| {
        try out.appendSlice(allocator, "    ");
        try appendLevelMarker(&out, allocator, level);
        try out.print(allocator, "    case {}\n", .{level.rank});

        const arms = comptime completionValueArms(level);
        if (arms.len != 0) {
            try out.appendSlice(allocator,
                \\        if test -n "$vflag"
                \\            switch $vflag
                \\
            );
            inline for (arms) |arm| {
                try out.appendSlice(allocator, "            case ");
                try appendQuoted(&out, allocator, arm.spelling, .fish);
                try out.append(allocator, '\n');
                const bare = comptime enumCandidates(arm.vtype, "");
                if (bare.len != 0) {
                    const full_prefix = comptime std.fmt.comptimePrint("{s}=", .{arm.spelling});
                    const full = comptime enumCandidates(arm.vtype, full_prefix);
                    try out.appendSlice(allocator,
                        \\                switch $vform
                        \\                case full
                        \\
                    );
                    try appendFishCandidates(&out, allocator, "                    ", full);
                    try out.appendSlice(allocator,
                        \\                case '*'
                        \\
                    );
                    try appendFishCandidates(&out, allocator, "                    ", bare);
                    try out.appendSlice(allocator,
                        \\                end
                        \\                return
                        \\
                    );
                } else if (comptime armNativeFs(arm)) |opts| {
                    try appendFishNativeFs(&out, allocator, "                ", opts);
                    try out.appendSlice(allocator, "                return\n");
                } else if (comptime arm.predictor) |predictor| {
                    switch (predictor) {
                        .disabled => {},
                        .fs, .callback => {
                            if (comptime arm.binding) |index| {
                                try out.appendSlice(allocator,
                                    \\                set -l vprefix ''
                                    \\                set -l vpart $cur
                                    \\                switch $vform
                                    \\                case full
                                    \\                    set vprefix (string split -m 1 '=' -- $cur)[1]'='
                                    \\                    set vpart (string split -m 1 '=' -- $cur)[2]
                                    \\                end
                                    \\
                                );
                                try appendFishDynamicCall(
                                    &out,
                                    allocator,
                                    ident,
                                    index,
                                    "\"$vprefix\"",
                                    "\"$vpart\"",
                                    "                ",
                                    &.{},
                                );
                            }
                        },
                        .launch, .call => {
                            try out.appendSlice(allocator,
                                \\                set -l vprefix ''
                                \\                set -l vpart $cur
                                \\                switch $vform
                                \\                case full
                                \\                    set vprefix (string split -m 1 '=' -- $cur)[1]'='
                                \\                    set vpart (string split -m 1 '=' -- $cur)[2]
                                \\                end
                                \\                set -l cur $vpart
                                \\
                            );
                            _ = try appendFishInline(
                                &out,
                                allocator,
                                "                ",
                                predictor,
                                "$vpart",
                                "$vprefix",
                                &.{},
                            );
                        },
                    }
                    try out.appendSlice(allocator, "                return\n");
                } else {
                    try out.appendSlice(allocator,
                        \\                __fish_complete_path
                        \\                return
                        \\
                    );
                }
            }
            try out.appendSlice(allocator,
                \\            end
                \\            return
                \\        end
                \\
            );
        }

        const slot_predictors = comptime blk: {
            for (0..level.arguments.len) |slot| {
                if (argumentPredictor(level, slot) != null) break :blk true;
            }
            break :blk false;
        };
        if (slot_predictors) {
            try out.appendSlice(allocator, "        switch $pos\n");
            inline for (0..level.arguments.len) |slot| {
                if (comptime argumentPredictor(level, slot) != null) {
                    try appendFishSlotPredictor(&out, allocator, ident, level, slot);
                }
            }
            try out.appendSlice(allocator, "        end\n");
        }

        try out.appendSlice(allocator, "        ");
        try appendFishFnName(&out, allocator, ident, "_rows ");
        try out.print(allocator, "{} $pos \"$cur\"\n", .{level.rank});
        if (comptime levelHasPlainArgument(level)) {
            try out.appendSlice(allocator, "        or __fish_complete_path\n");
        }
    }

    try out.appendSlice(allocator, "    end\nend\n\n");
    try out.appendSlice(allocator, "complete -c ");
    try appendQuoted(&out, allocator, app_name, .fish);
    try out.appendSlice(allocator, " -f -a '(");
    try appendFishFnName(&out, allocator, ident, "_complete)' -k\n");
    return try out.toOwnedSlice(allocator);
}

/// `NS` followed by every command node below it, depth-first in declaration
/// order. Mirrors the private walk in `dap.zig` so the moved tests keep their
/// names; used only by the completion tests.
fn commandNodes(comptime NS: type) []const type {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var nodes: []const type = &[_]type{NS};
        for (NS.commands) |c| {
            nodes = nodes ++ commandNodes(Sub(c.Cmd, subApp(NS.app_meta, c)));
        }
        return nodes;
    }
}

/// Free a successful suggestion list returned by `routeSuggestions`: every
/// non-null `value` and `help`, then the slice itself. A callback owns the
/// strings it returns and must allocate all of them with the allocator the
/// route passes in; static literals are not valid results.
pub fn freeSuggestions(
    allocator: std.mem.Allocator,
    suggestions: []const Completion.Suggestion,
) void {
    for (suggestions) |s| {
        allocator.free(s.value);
        if (s.help) |help| allocator.free(help);
    }
    allocator.free(suggestions);
}

/// Render suggestions as the route's stdout payload: one `value` or
/// `value<TAB>help` per line, in the order given. A value containing a tab,
/// carriage return, or newline is unrepresentable and is skipped; help
/// strings have those bytes flattened to spaces.
pub fn renderSuggestions(
    allocator: std.mem.Allocator,
    suggestions: []const Completion.Suggestion,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (suggestions) |s| {
        if (std.mem.indexOfAny(u8, s.value, "\t\r\n") != null) continue;
        try out.appendSlice(allocator, s.value);
        if (s.help) |help| {
            if (help.len != 0) {
                try out.append(allocator, '\t');
                for (help) |c| {
                    try out.append(allocator, switch (c) {
                        '\t', '\r', '\n' => ' ',
                        else => c,
                    });
                }
            }
        }
        try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

/// Glob-match a basename against a filesystem wildcard. Only `*` (any run,
/// including empty) and `?` (exactly one byte) are special; every other byte is
/// literal. Matching is byte-wise and applies to the whole basename.
fn fsWildcardMatch(basename: []const u8, wildcard: []const u8) bool {
    var name_index: usize = 0;
    var wildcard_index: usize = 0;
    var star: ?usize = null;
    var star_name: usize = 0;
    while (name_index < basename.len) {
        if (wildcard_index < wildcard.len and
            (wildcard[wildcard_index] == '?' or wildcard[wildcard_index] == basename[name_index]))
        {
            name_index += 1;
            wildcard_index += 1;
        } else if (wildcard_index < wildcard.len and wildcard[wildcard_index] == '*') {
            star = wildcard_index;
            wildcard_index += 1;
            star_name = name_index;
        } else if (star) |star_index| {
            wildcard_index = star_index + 1;
            star_name += 1;
            name_index = star_name;
        } else {
            return false;
        }
    }
    while (wildcard_index < wildcard.len and wildcard[wildcard_index] == '*') {
        wildcard_index += 1;
    }
    return wildcard_index == wildcard.len;
}

/// Whether `basename` is a candidate for a binary filesystem mapping: it must
/// pass the dot-entry gate, start with `base`, and satisfy the wildcard (with
/// the `.all` rule that any directory passing the gate is a candidate when a
/// wildcard is declared).
fn fsEntryMatches(
    basename: []const u8,
    base: []const u8,
    is_dir: bool,
    opts: Completion.FsOptions,
) bool {
    if (basename.len == 0) return false;
    if (basename[0] == '.' and (base.len == 0 or base[0] != '.')) return false;
    if (base.len != 0 and !std.mem.startsWith(u8, basename, base)) return false;
    const matches = fsWildcardMatch(basename, opts.wildcard);
    return switch (opts.type) {
        .all => if (is_dir and opts.wildcard.len != 0) true else matches,
        .dir => is_dir and matches,
    };
}

/// The directory to scan for a binary filesystem mapping: `root` (or the
/// process cwd) joined with the `dir_part` of the current word.
fn fsScanPath(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    dir_part: []const u8,
) std.mem.Allocator.Error![]u8 {
    const base = root orelse ".";
    if (dir_part.len == 0) return allocator.dupe(u8, base);
    return std.fs.path.join(allocator, &.{ base, dir_part });
}

/// Scan a directory for a binary filesystem predictor. `cur` is split at its
/// last `/` into `dir_part` (kept as a prefix of every value) and `base` (the
/// name prefix being typed). Values are relative to `opts.root`, never carry
/// that root prefix, and directory candidates end in `/`.
///
/// The dot-entry rules follow shell globbing: names starting with `.` are
/// candidates only when `base` starts with `.`. A missing or unreadable
/// directory yields an empty list, not an error. Entry kinds the platform does
/// not report are resolved with `statFile` following symlinks, so a symlink to
/// a directory is listed as a directory under its link name. Results are
/// sorted byte-wise and deduplicated.
fn fsSuggestions(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: Completion.FsOptions,
    cur: []const u8,
) std.mem.Allocator.Error![]const Completion.Suggestion {
    const split = std.mem.lastIndexOfScalar(u8, cur, '/');
    const dir_part = if (split) |i| cur[0 .. i + 1] else "";
    const base = if (split) |i| cur[i + 1 ..] else cur;

    var values: std.ArrayList([]u8) = .empty;
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    const path = try fsScanPath(allocator, opts.root, dir_part);
    defer allocator.free(path);

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        return allocator.alloc(Completion.Suggestion, 0);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const entry = (it.next(io) catch {
            return allocator.alloc(Completion.Suggestion, 0);
        }) orelse break;

        const is_dir: bool = switch (entry.kind) {
            .file => false,
            .directory => true,
            else => blk: {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = true }) catch
                    continue;
                break :blk switch (stat.kind) {
                    .file => false,
                    .directory => true,
                    else => continue,
                };
            },
        };
        if (!fsEntryMatches(entry.name, base, is_dir, opts)) continue;

        const value = if (is_dir)
            try std.fmt.allocPrint(allocator, "{s}{s}/", .{ dir_part, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_part, entry.name });
        try values.append(allocator, value);
    }

    const Less = struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    };
    std.mem.sort([]u8, values.items, {}, Less.less);

    var unique: usize = 0;
    for (values.items) |value| {
        if (unique != 0 and std.mem.eql(u8, values.items[unique - 1], value)) {
            allocator.free(value);
            continue;
        }
        values.items[unique] = value;
        unique += 1;
    }
    values.items.len = unique;

    const suggestions = try allocator.alloc(Completion.Suggestion, unique);
    for (suggestions, values.items[0..unique]) |*suggestion, value| {
        suggestion.* = .{ .value = value };
    }
    values.items.len = 0;
    return suggestions;
}

/// Build the suggestion list a route call asks for, without exiting. The wire
/// layout is `marker`, binding index, `cur` (possibly empty), then the parsed
/// line including the program word. `error.RouteMisuse` covers a wrong marker,
/// too few arguments, a non-numeric or out-of-range index, and any index that
/// does not address a route-backed binding.
pub fn routeSuggestions(
    comptime NS: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror![]const Completion.Suggestion {
    if (args.len < 4) return error.RouteMisuse;
    if (!std.mem.eql(u8, args[0], Completion.route_marker)) return error.RouteMisuse;
    const index = std.fmt.parseInt(usize, args[1], 10) catch return error.RouteMisuse;
    const cur = args[2];
    const line = args[3..];
    const bindings = comptime model(NS).bindings;
    if (index >= bindings.len) return error.RouteMisuse;
    return switch (bindings[index]) {
        .callback => |cb| cb(allocator, cur, line),
        .fs => |opts| fsSuggestions(io, allocator, opts, cur),
    };
}

/// Hidden completion route: resolve `args`, render the suggestions, write and
/// flush the complete payload, free everything, then exit. Success is `0`
/// (including zero suggestions), a predictor failure is `1`, and misuse is
/// `2`. stdout stays empty on every non-zero exit; diagnostics reach stderr
/// only when `_DAP_DIAGNOSTICS` is exactly `1`.
pub fn route(
    comptime NS: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    args: []const []const u8,
) noreturn {
    const suggestions = routeSuggestions(NS, io, allocator, args) catch |err| {
        routeDiagnose(io, allocator, environ, err);
        std.process.exit(if (err == error.RouteMisuse) 2 else 1);
    };
    const rendered = renderSuggestions(allocator, suggestions) catch {
        freeSuggestions(allocator, suggestions);
        routeDiagnose(io, allocator, environ, error.OutOfMemory);
        std.process.exit(1);
    };
    writeRouteStdout(io, rendered) catch {
        allocator.free(rendered);
        freeSuggestions(allocator, suggestions);
        routeDiagnose(io, allocator, environ, error.WriteFailed);
        std.process.exit(1);
    };
    allocator.free(rendered);
    freeSuggestions(allocator, suggestions);
    std.process.exit(0);
}

fn writeRouteStdout(io: std.Io, text: []const u8) !void {
    var buffer: [0x1000]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const out = &writer.interface;
    try out.writeAll(text);
    try out.flush();
}

fn routeDiagnosticsEnabled(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
) bool {
    const value = completionEnvValue(allocator, environ, "_DAP_DIAGNOSTICS") catch return false;
    defer if (value) |v| allocator.free(v);
    if (value) |v| return std.mem.eql(u8, v, "1");
    return false;
}

fn routeDiagnose(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    err: anyerror,
) void {
    if (!routeDiagnosticsEnabled(allocator, environ)) return;
    var text_buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "dap completion route: {s}\n", .{@errorName(err)}) catch
        "dap completion route: failed\n";
    var buffer: [0x1000]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    const out = &writer.interface;
    out.writeAll(text) catch {};
    out.flush() catch {};
}

// ---------------------------------------------------------------------------
// M19: completion scripts.
// ---------------------------------------------------------------------------

const M19Mode = Enumeration(.{
    .fast = Enum{},
    .slow = Enum{ .name = "glacial" },
});

const M19Def = .{
    .verbose = Flag(bool){ .default = Default(bool){ .direct = false }, .help = "Verbose." },
    .mode = Flag(M19Mode){
        .long = "mode",
        .default = Default(M19Mode){ .direct = .{} },
        .help = "Mode.",
    },
    .run = Command(.{ .help = "Run." }, .{
        .go = Command(.{ .name = "go", .help = "Go." }, .{
            .n = Argument(u8){ .help = "N." },
        }),
    }),
};

const M19 = generate(App{ .name = "m19", .help = "M19 root." }, M19Def);

const M19BigDef = .{
    .verbose = Flag(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
        .help = "Verbose.",
    },
    .config = Flag([]const u8){ .long = "config", .help = "Config." },
    .server = Group(.{
        .host = Flag([]const u8){ .long = "host", .help = "Host." },
        .port = Flag(u16){
            .long = "port",
            .default = Default(u16){ .direct = 8080 },
            .help = "Port.",
        },
    }, "Server"),
    .optional = Optional(Flag(u8){ .long = "optional", .help = "Optional." }),
    .mode = Alt(.{
        .fast = .{
            .fast = Flag(bool){
                .long = "fast",
                .help = "Fast.",
            },
        },
        .slow = .{
            .slow = Flag(bool){
                .long = "slow",
                .help = "Slow.",
            },
        },
    }),
    .build = Command(.{ .help = "Build." }, .{
        .target = Argument([]const u8){ .help = "Target." },
    }),
    .serve = Command(.{ .help = "Serve." }, .{
        .serve_port = Flag(u16){
            .long = "serve_port",
            .default = Default(u16){ .direct = 9000 },
            .help = "Serve port.",
        },
        .nested = Command(.{ .help = "Nested." }, .{
            .x = Argument(u8){ .help = "X." },
        }),
    }),
};

const M19Big = generate(App{ .name = "m19-big", .help = "M19 big root." }, M19BigDef);

const M19ShortDef = .{
    .level = Flag(M19Mode){
        .long = "level",
        .short = "l",
        .default = Default(M19Mode){ .direct = .{} },
        .help = "Level.",
    },
};

const M19Short = generate(App{ .name = "m19-short", .help = "M19 short root." }, M19ShortDef);

const M19SynonymDef = .{
    .run = Command(.{ .synonym = "go", .help = "Run." }, .{
        .flag = Flag(bool){ .default = Default(bool){ .direct = false } },
    }),
    .build = Command(.{ .name = "build-target", .synonym = "b", .help = "Build." }, .{}),
};

const M19Synonym = generate(App{ .name = "m19-synonym", .help = "M19 synonym root." }, M19SynonymDef);

fn m19Expect(comptime ok: bool, comptime msg: []const u8) void {
    if (!ok) @compileError("M19: " ++ msg);
}

fn m19CountLong(comptime specs: []const Spec, comptime long: String) usize {
    comptime var n: usize = 0;
    inline for (specs) |s| {
        if (std.mem.eql(u8, s.long, long)) n += 1;
    }
    return n;
}

fn m19IndexOfLong(comptime specs: []const Spec, comptime long: String) ?usize {
    comptime var found: ?usize = null;
    inline for (specs, 0..) |s, i| {
        if (std.mem.eql(u8, s.long, long)) found = i;
    }
    return found;
}

fn m19HasArgument(comptime specs: []const Spec, comptime name: String) bool {
    comptime var found = false;
    inline for (specs) |s| {
        if (std.mem.eql(u8, s.name, name)) found = true;
    }
    return found;
}

fn m19HasCommand(comptime cmds: []const CommandEntry, comptime name: String) bool {
    comptime var found = false;
    inline for (cmds) |c| {
        if (std.mem.eql(u8, c.name, name)) found = true;
    }
    return found;
}

/// Slice of `script` between the `# dap: level <rank> ` marker and the next
/// level marker (or the end of the script).
fn m19LevelBlock(script: String, comptime rank: usize) String {
    const marker = std.fmt.comptimePrint("# dap: level {d} ", .{rank});
    const start = std.mem.indexOf(u8, script, marker) orelse return "";
    const after_marker = start + marker.len;
    const line_end = std.mem.indexOfScalar(u8, script[after_marker..], '\n') orelse return "";
    const body = script[after_marker + line_end + 1 ..];
    const next = std.mem.indexOf(u8, body, "# dap: level ") orelse body.len;
    return body[0..next];
}

test "M19: completion public types" {
    const shell_names = @typeInfo(Completion.Shell).@"enum".field_names;
    try std.testing.expectEqual(@as(usize, 3), shell_names.len);
    try std.testing.expectEqualStrings("bash", shell_names[0]);
    try std.testing.expectEqualStrings("zsh", shell_names[1]);
    try std.testing.expectEqualStrings("fish", shell_names[2]);

    const invalid: Completion.Error = error.InvalidAppName;
    try std.testing.expect(invalid == error.InvalidAppName);
}

test "M19: level table" {
    comptime {
        const levels = model(M19).levels;
        m19Expect(levels.len == 3, "minimal tree level count");

        m19Expect(levels[0].rank == 0, "root rank");
        m19Expect(std.mem.eql(u8, levels[0].path, "m19"), "root path");
        m19Expect(levels[0].flags.len == 3, "root effective flags");
        m19Expect(levels[0].arguments.len == 0, "root arguments");
        m19Expect(levels[0].commands.len == 1, "root commands");
        m19Expect(std.mem.eql(u8, levels[0].commands[0].name, "run"), "root command name");

        m19Expect(levels[1].rank == 1, "run rank");
        m19Expect(std.mem.eql(u8, levels[1].path, "m19 run"), "run path");
        m19Expect(levels[1].flags.len == 3, "run effective flags");
        m19Expect(levels[1].arguments.len == 0, "run arguments");
        m19Expect(levels[1].commands.len == 1, "run commands");
        m19Expect(std.mem.eql(u8, levels[1].commands[0].name, "go"), "run command name");

        m19Expect(levels[2].rank == 2, "go rank");
        m19Expect(std.mem.eql(u8, levels[2].path, "m19 run go"), "go path");
        m19Expect(levels[2].flags.len == 3, "go effective flags");
        m19Expect(levels[2].arguments.len == 1, "go arguments");
        m19Expect(std.mem.eql(u8, levels[2].arguments[0].name, "n"), "go argument name");
        m19Expect(levels[2].commands.len == 0, "go commands");

        // The effective flag set starts with the injected builtin, exactly once.
        m19Expect(std.mem.eql(u8, levels[0].flags[0].long, "help"), "builtin help first");
        m19Expect(std.mem.eql(u8, levels[0].flags[0].short.?, "h"), "builtin help short");
        m19Expect(std.mem.eql(u8, levels[0].flags[1].long, "verbose"), "declaration order");
        m19Expect(std.mem.eql(u8, levels[0].flags[2].long, "mode"), "declaration order");
        for (levels) |level| {
            m19Expect(m19CountLong(level.flags, "help") == 1, "builtin help duplicates");
        }
    }
}

test "M19: larger tree levels" {
    comptime {
        const levels = model(M19Big).levels;
        m19Expect(levels.len == 4, "larger tree level count");

        const want_paths = [_]String{ "m19-big", "m19-big build", "m19-big serve", "m19-big serve nested" };
        for (levels, 0..) |level, i| {
            m19Expect(level.rank == i, "pre-order rank");
            m19Expect(std.mem.eql(u8, level.path, want_paths[i]), "level path");
        }

        const root = levels[0];
        const want_root_flags = [_]String{ "help", "verbose", "config", "host", "port", "optional", "fast", "slow" };
        m19Expect(root.flags.len == want_root_flags.len, "root flag count");
        for (want_root_flags, 0..) |long, i| {
            m19Expect(std.mem.eql(u8, root.flags[i].long, long), "root flag order");
        }
        m19Expect(root.arguments.len == 0, "root arguments");
        m19Expect(root.commands.len == 2, "root commands");
        m19Expect(std.mem.eql(u8, root.commands[0].name, "build"), "first sibling");
        m19Expect(std.mem.eql(u8, root.commands[1].name, "serve"), "second sibling");

        // Group, Alt, and optional members are ordinary flags in the table.
        const host = root.flags[m19IndexOfLong(root.flags, "host").?];
        m19Expect(std.mem.eql(u8, host.group.?, "Server"), "group member flag");
        const fast = root.flags[m19IndexOfLong(root.flags, "fast").?];
        m19Expect(std.mem.eql(u8, fast.alt.?, "mode"), "alt owner");
        m19Expect(std.mem.eql(u8, fast.alt_branch.?, "fast"), "alt branch");
        m19Expect(root.flags[m19IndexOfLong(root.flags, "optional").?].optional, "optional flag");

        // Ancestor-first inheritance: each level extends its parent's chain by
        // its own flags, and the builtin never duplicates.
        const build = levels[1];
        m19Expect(build.flags.len == root.flags.len, "build effective flags");
        for (root.flags, build.flags) |want, got| {
            m19Expect(std.mem.eql(u8, want.long, got.long), "build inherited order");
        }
        m19Expect(build.arguments.len == 1, "build arguments");
        m19Expect(std.mem.eql(u8, build.arguments[0].name, "target"), "build argument name");
        m19Expect(build.commands.len == 0, "build commands");

        const serve = levels[2];
        m19Expect(serve.flags.len == root.flags.len + 1, "serve effective flags");
        for (root.flags, serve.flags[0..root.flags.len]) |want, got| {
            m19Expect(std.mem.eql(u8, want.long, got.long), "serve inherited order");
        }
        m19Expect(std.mem.eql(u8, serve.flags[root.flags.len].long, "serve_port"), "serve own flag");
        m19Expect(serve.arguments.len == 0, "serve arguments");
        m19Expect(serve.commands.len == 1, "serve commands");
        m19Expect(std.mem.eql(u8, serve.commands[0].name, "nested"), "serve command name");

        const nested = levels[3];
        m19Expect(nested.flags.len == serve.flags.len, "nested effective flags");
        for (serve.flags, nested.flags) |want, got| {
            m19Expect(std.mem.eql(u8, want.long, got.long), "nested inherited order");
        }
        m19Expect(nested.arguments.len == 1, "nested arguments");
        m19Expect(std.mem.eql(u8, nested.arguments[0].name, "x"), "nested argument name");
        m19Expect(nested.commands.len == 0, "nested commands");
    }
}

test "M19: sibling isolation" {
    comptime {
        const levels = model(M19Big).levels;
        const build = levels[1];
        const serve = levels[2];
        const nested = levels[3];

        // A level inherits ancestors only: no sibling flags, arguments, or commands.
        m19Expect(m19IndexOfLong(build.flags, "serve_port") == null, "sibling flag leaked");
        m19Expect(!m19HasCommand(build.commands, "nested"), "sibling command leaked");
        m19Expect(!m19HasArgument(build.arguments, "x"), "sibling argument leaked");

        m19Expect(m19IndexOfLong(serve.flags, "target") == null, "sibling flag leaked");
        m19Expect(!m19HasArgument(serve.arguments, "target"), "sibling argument leaked");
        m19Expect(!m19HasCommand(serve.commands, "build"), "sibling command leaked");

        m19Expect(!m19HasArgument(nested.arguments, "target"), "sibling argument leaked");
        m19Expect(m19IndexOfLong(nested.flags, "serve_port") != null, "ancestor flag missing");
    }
}

test "M19: enum wire names" {
    comptime {
        const wire_names = enumWireNames(M19Mode);
        m19Expect(wire_names.len == 2, "enumeration name count");
        m19Expect(std.mem.eql(u8, wire_names[0], "fast"), "enumeration declaration order");
        m19Expect(std.mem.eql(u8, wire_names[1], "glacial"), "enumeration wire name");

        m19Expect(enumWireNames(Enumeration(.{})).len == 0, "empty enumeration");
        m19Expect(enumWireNames(u8).len == 0, "scalar type");
        m19Expect(enumWireNames(bool).len == 0, "bool type");
        m19Expect(enumWireNames(String).len == 0, "string type");

        const Custom = struct { value: u8 };
        m19Expect(enumWireNames(Custom).len == 0, "custom struct");

        // Detection is structural: both declarations are required.
        const NamesOnly = struct {
            pub const names = [_]String{"leak"};
        };
        m19Expect(enumWireNames(NamesOnly).len == 0, "names without EnumView");
        const EnumViewOnly = struct {
            pub const EnumView = enum { leak };
        };
        m19Expect(enumWireNames(EnumViewOnly).len == 0, "EnumView without names");
    }
}

test "M19: invalid app name allocates nothing" {
    const invalid = [_]String{
        "",        "-app",        "a/b",     "my app",
        "my\tapp", "my\napp",     "my\rapp", "app\x00",
        "app\x7f", "app\xc3\xa9",
    };
    for (invalid) |name| {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.InvalidAppName, M19.completion(fa.allocator(), name, .bash).text());
        try std.testing.expectEqual(@as(usize, 0), fa.allocations);
    }
}

test "M19: valid app names are accepted" {
    const valid = [_]String{ "app", "my-app", "a.b_c+d", "A9" };
    for (valid) |name| {
        const script = try M19.completion(std.testing.allocator, name, .bash).text();
        defer std.testing.allocator.free(script);
        try std.testing.expect(script.len > 0);
    }
}

test "M19: install writes completion scripts under XDG homes" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", tmp.sub_path[0..],
    });
    defer std.testing.allocator.free(base);
    const data_home = try std.fs.path.join(std.testing.allocator, &.{ base, "data" });
    defer std.testing.allocator.free(data_home);
    const config_home = try std.fs.path.join(std.testing.allocator, &.{ base, "config" });
    defer std.testing.allocator.free(config_home);

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("XDG_DATA_HOME", data_home);
    try map.put("XDG_CONFIG_HOME", config_home);
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const environ: std.process.Environ = .{ .block = block };

    var completion = M19.completion(std.testing.allocator, "my-app", .bash);
    try completion.install(std.testing.io, environ);
    completion = M19.completion(std.testing.allocator, "my-app", .zsh);
    try completion.install(std.testing.io, environ);
    completion = M19.completion(std.testing.allocator, "my-app", .fish);
    try completion.install(std.testing.io, environ);

    const cases = [_]struct { shell: Completion.Shell, path: []const u8 }{
        .{ .shell = .bash, .path = "data/bash-completion/completions/my-app" },
        .{ .shell = .zsh, .path = "data/zsh/site-functions/_my-app" },
        .{ .shell = .fish, .path = "config/fish/completions/my-app.fish" },
    };
    for (cases) |case| {
        const installed = try tmp.dir.readFileAlloc(
            std.testing.io,
            case.path,
            std.testing.allocator,
            .limited(1 << 20),
        );
        defer std.testing.allocator.free(installed);

        const expected = try M19.completion(std.testing.allocator, "my-app", case.shell).text();
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, installed);
    }
}

test "M19: install falls back to HOME" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", tmp.sub_path[0..], "home",
    });
    defer std.testing.allocator.free(home);

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", home);
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const environ: std.process.Environ = .{ .block = block };

    try M19.completion(std.testing.allocator, "tool", .fish).install(std.testing.io, environ);

    const installed = try tmp.dir.readFileAlloc(
        std.testing.io,
        "home/.config/fish/completions/tool.fish",
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(installed);
    try std.testing.expect(std.mem.endsWith(u8, installed, "complete -c 'tool' -f -a '(__dap_tool_complete)' -k\n"));
}

test "M19: install needs a home directory" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const environ: std.process.Environ = .{ .block = .empty };
    try std.testing.expectError(
        error.InstallUnsupported,
        M19.completion(std.testing.allocator, "tool", .zsh).install(std.testing.io, environ),
    );
}

test "M19: determinism and one trailing newline" {
    inline for (.{ Completion.Shell.bash, Completion.Shell.zsh, Completion.Shell.fish }) |shell| {
        const a = try M19.completion(std.testing.allocator, "my-app", shell).text();
        defer std.testing.allocator.free(a);
        const b = try M19.completion(std.testing.allocator, "my-app", shell).text();
        defer std.testing.allocator.free(b);

        try std.testing.expectEqualStrings(a, b);
        try std.testing.expect(a.len >= 2);
        try std.testing.expectEqual(@as(u8, '\n'), a[a.len - 1]);
        try std.testing.expect(a[a.len - 2] != '\n');
    }
}

test "M19: shell dispatch picks the matching registration" {
    inline for (.{ Completion.Shell.bash, Completion.Shell.zsh, Completion.Shell.fish }) |shell| {
        const script = try M19.completion(std.testing.allocator, "tool", shell).text();
        defer std.testing.allocator.free(script);

        switch (shell) {
            .bash => {
                try std.testing.expect(std.mem.endsWith(u8, script, "complete -o default -F _dap_tool 'tool'\n"));
                try std.testing.expect(std.mem.indexOf(u8, script, "#compdef") == null);
            },
            .zsh => {
                try std.testing.expect(std.mem.startsWith(u8, script, "#compdef tool\n"));
                try std.testing.expect(std.mem.indexOf(u8, script, "compdef _tool 'tool'\n") != null);
            },
            .fish => {
                try std.testing.expect(std.mem.endsWith(u8, script, "complete -c 'tool' -f -a '(__dap_tool_complete)' -k\n"));
                try std.testing.expect(std.mem.indexOf(u8, script, "function __dap_tool_complete\n") != null);
            },
        }
    }
}

test "M19: identifier and registration use app_name, not App.name" {
    const bash = try M19.completion(std.testing.allocator, "my-app", .bash).text();
    defer std.testing.allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "_dap_my_app() {\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, bash, "complete -o default -F _dap_my_app 'my-app'\n"));
    try std.testing.expect(std.mem.indexOf(u8, bash, "'m19'") == null);

    const zsh_script = try M19.completion(std.testing.allocator, "my.app", .zsh).text();
    defer std.testing.allocator.free(zsh_script);
    try std.testing.expect(std.mem.startsWith(u8, zsh_script, "#compdef my.app\n"));
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "_my_app() {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "compdef _my_app 'my.app'\n") != null);

    const fish_script = try M19.completion(std.testing.allocator, "my-app", .fish).text();
    defer std.testing.allocator.free(fish_script);
    try std.testing.expect(std.mem.indexOf(u8, fish_script, "function __dap_my_app_complete\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, fish_script, "complete -c 'my-app' -f -a '(__dap_my_app_complete)' -k\n"));
}

test "M19: every generated namespace exposes completion" {
    comptime {
        const nodes = commandNodes(M19);
        m19Expect(nodes.len == 3, "node count");
        for (nodes) |NS| {
            m19Expect(@hasDecl(NS, "completion"), "completion missing");
            m19Expect(@hasDecl(NS, "Completion"), "Completion missing");
            m19Expect(@TypeOf(NS.completion) ==
                fn (std.mem.Allocator, String, Completion.Shell) NS.Completion, "completion signature");
            m19Expect(@TypeOf(NS.Completion.text) ==
                fn (NS.Completion) Completion.Error!String, "text signature");
        }
    }
}

test "M19: completion is root-only" {
    comptime {
        const nodes = commandNodes(M19);
        m19Expect(nodes[0].app_meta._command_rank == 0, "root rank");
        m19Expect(nodes[1].app_meta._command_rank != 0, "child rank");
        m19Expect(nodes[2].app_meta._command_rank != 0, "grandchild rank");
    }

    // Compile-fail case, verified by enabling it: the child's `completion`
    // rejects the call in its body, not in the forwarded alias.
    // comptime {
    //     const run_level = commandNodes(M19)[1];
    //     _ = run_level.completion(std.testing.allocator, "m19", .bash);
    // }
    // error: dap.completion: call it on the root namespace, got 'm19 run'
}

test "M19: skeletons carry one level marker per level" {
    const script = try M19.completion(std.testing.allocator, "app", .bash).text();
    defer std.testing.allocator.free(script);

    const markers = [_]String{
        "# dap: level 0 m19\n",
        "# dap: level 1 m19 run\n",
        "# dap: level 2 m19 run go\n",
    };
    for (markers) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, script, marker) != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, script, marker));
    }
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, script, "# dap: level "));
}

test "M19: level markers sanitize the path" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendLevelMarker(&out, std.testing.allocator, .{
        .rank = 3,
        .path = "a\tb\nc\r",
        .flags = &.{},
        .arguments = &.{},
        .commands = &.{},
    });
    try std.testing.expectEqualStrings("# dap: level 3 a b c \n", out.items);
}

test "M19: posix and fish quoting" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendQuoted(&out, std.testing.allocator, "a'b", .posix);
    try std.testing.expectEqualStrings("'a'\\''b'", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, std.testing.allocator, "a'b\\c", .fish);
    try std.testing.expectEqualStrings("'a\\'b\\\\c'", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, std.testing.allocator, "", .posix);
    try std.testing.expectEqualStrings("''", out.items);
}

test "M19: description sanitization" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendSanitized(&out, std.testing.allocator, "a\nb\rc\td");
    try std.testing.expectEqualStrings("a b c d", out.items);
}

test "M19: value flag spellings" {
    comptime {
        const small = valueFlagSpellings(model(M19).levels);
        m19Expect(small.len == 1, "minimal value spelling count");
        m19Expect(std.mem.eql(u8, small[0], "--mode"), "minimal value spelling");

        const big = valueFlagSpellings(model(M19Big).levels);
        const want = [_]String{ "--config", "--host", "--port", "--optional", "--serve_port" };
        m19Expect(big.len == want.len, "value spelling count");
        for (want, big) |w, g| m19Expect(std.mem.eql(u8, w, g), "value spelling order");
    }
}

test "M19: bash candidates by level" {
    const script = try M19.completion(std.testing.allocator, "tool", .bash).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    try std.testing.expect(std.mem.indexOf(u8, root,
        \\        if [[ -z $cur ]]; then
        \\            _dap_tool_filter "$cur" 'run'
        \\        else
        \\            _dap_tool_filter "$cur" '--mode' '--verbose' 'run' '--help' '-h'
        \\        fi
        \\
    ) != null);

    const run_level = m19LevelBlock(script, 1);
    try std.testing.expect(std.mem.indexOf(u8, run_level,
        \\        if [[ -z $cur ]]; then
        \\            _dap_tool_filter "$cur" 'go'
        \\        else
        \\            _dap_tool_filter "$cur" '--mode' '--verbose' 'go' '--help' '-h'
        \\        fi
        \\
    ) != null);
    // A sibling's commands are not offered after a handoff.
    try std.testing.expect(std.mem.indexOf(u8, run_level, "'run'") == null);

    const go_level = m19LevelBlock(script, 2);
    const go_want =
        \\        if [[ -z $cur ]]; then
        \\            case "$pos" in
        \\            0) _dap_tool_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            *) _dap_tool_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            esac
        \\        else
        \\            case "$pos" in
        \\            0) _dap_tool_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            *) _dap_tool_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            esac
        \\        fi
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, go_level, go_want) != null);
    try std.testing.expect(std.mem.indexOf(u8, go_level, "'go'") == null);
}

test "M19: bash enumeration value positions" {
    const script = try M19.completion(std.testing.allocator, "tool", .bash).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    const want =
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq) _dap_tool_filter "$cur" '=fast' '=glacial' ;;
        \\            full) _dap_tool_filter "$vflag=" '--mode=fast' '--mode=glacial' ;;
        \\            *) _dap_tool_filter "$cur" 'fast' 'glacial' ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, root, want) != null);
}

test "M19: bash non-enum and empty enumeration value positions" {
    const big_script = try M19Big.completion(std.testing.allocator, "tool", .bash).text();
    defer std.testing.allocator.free(big_script);

    const root = m19LevelBlock(big_script, 0);
    const arms = [_]String{
        "        '--config')\n            return\n            ;;\n",
        "        '--host')\n            return\n            ;;\n",
        "        '--port')\n            return\n            ;;\n",
        "        '--optional')\n            return\n            ;;\n",
    };
    for (arms) |arm| try std.testing.expect(std.mem.indexOf(u8, root, arm) != null);
    // Boolean flags never enter a value arm.
    for ([_]String{ "'--verbose')", "'-v')", "'--fast')", "'--slow')" }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, root, arm) == null);
    }

    const Empty = Enumeration(.{});
    const empty_flags = [_]Spec{.{
        .name = "e",
        .kind = .flag,
        .vtype = Empty,
        .long = "e",
        .short = null,
        .required = false,
        .default = null,
        .default_env = null,
        .validation = null,
        .help = "",
        .i18n = null,
        .group = null,
    }};
    const empty_levels = [_]Level{.{
        .rank = 0,
        .path = "empty",
        .flags = &empty_flags,
        .arguments = &.{},
        .commands = &.{},
    }};
    const empty_script = try emitBash(std.testing.allocator, &empty_levels, &.{}, "x", "app");
    defer std.testing.allocator.free(empty_script);
    try std.testing.expect(std.mem.indexOf(u8, empty_script, "        '--e')\n            return\n            ;;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_script, "case \"$vform\"") == null);
}

test "M19: bash value flag table" {
    const script = try M19Big.completion(std.testing.allocator, "tool", .bash).text();
    defer std.testing.allocator.free(script);

    const start = std.mem.indexOf(u8, script, "_dap_tool_value_flag() {\n") orelse return error.TestUnexpectedResult;
    const rest = script[start..];
    const end = std.mem.indexOf(u8, rest, "\n}\n") orelse return error.TestUnexpectedResult;
    const helper = rest[0..end];

    const guard = std.mem.indexOf(u8, helper, "    *=*) return 1 ;;\n") orelse return error.TestUnexpectedResult;
    const arms = [_]String{
        "    '--config') return 0 ;;\n",
        "    '--host') return 0 ;;\n",
        "    '--port') return 0 ;;\n",
        "    '--optional') return 0 ;;\n",
        "    '--serve_port') return 0 ;;\n",
    };
    for (arms) |arm| {
        const at = std.mem.indexOf(u8, helper, arm) orelse return error.TestUnexpectedResult;
        try std.testing.expect(at > guard);
    }
    for ([_]String{ "    '--verbose')", "    '-v')", "    '--fast')", "    '--slow')", "    '--help')" }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, helper, arm) == null);
    }
}

test "M19: bash literal terminator" {
    const script = try M19.completion(std.testing.allocator, "tool", .bash).text();
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "        if [[ $tok == '--' ]]; then\n            literal=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "    if (( literal )); then\n        return\n    fi\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, script, "complete -o default -F _dap_tool 'tool'\n"));
}

test "M19: bash quotes candidates as shell literals" {
    const weird_flags = [_]Spec{.{
        .name = "weird",
        .kind = .flag,
        .vtype = bool,
        .long = "a'b",
        .short = "x y",
        .required = false,
        .default = null,
        .default_env = null,
        .validation = null,
        .help = "",
        .i18n = null,
        .group = null,
    }};
    const WeirdCmd = struct {
        pub const cmd_meta = CommandMeta{ .help = "Cmd 'help'." };
    };
    const weird_commands = [_]CommandEntry{.{
        .field = "c",
        .view_field = "_c",
        .name = "c d",
        .synonym = null,
        .rank = 1,
        .Cmd = WeirdCmd,
    }};
    const weird_levels = [_]Level{.{
        .rank = 0,
        .path = "weird\troot",
        .flags = &weird_flags,
        .arguments = &.{},
        .commands = &weird_commands,
    }};

    const script = try emitBash(std.testing.allocator, &weird_levels, &.{}, "weird", "app");
    defer std.testing.allocator.free(script);

    const want =
        \\        if [[ -z $cur ]]; then
        \\            _dap_weird_filter "$cur" 'c d'
        \\        else
        \\            _dap_weird_filter "$cur" 'c d' '--a'\''b' '-x y'
        \\        fi
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, script, want) != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "# dap: level 0 weird root\n") != null);
}

test "M19: zsh candidates by level" {
    const script = try M19.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    try std.testing.expect(std.mem.indexOf(u8, root, "\n        _tool_rows 0 $pos\n        return\n") != null);

    const table = std.mem.indexOf(u8, script, "_tool_rows() {\n") orelse return error.TestUnexpectedResult;
    const rows = script[table..];

    // Root rows: normal flags then commands, help family last.
    try std.testing.expect(std.mem.indexOf(
        u8,
        rows,
        "        spell=('--mode' '--verbose' 'run' '--help')\n" ++
            "        alias=('' '' '' '-h')\n" ++
            "        help=('Mode.' 'Verbose.' 'Run.' 'Show context-sensitive help.')\n" ++
            "        kind=( 0 0 2 0 )\n" ++
            "        slot=( -1 -1 -1 -1 )\n" ++
            "        kp=( 1 2 4 20 )\n" ++
            "        ka=( 0 0 0 23 )\n",
    ) != null);

    // An empty prefix with commands selects the command phase.
    try std.testing.expect(std.mem.indexOf(
        u8,
        rows,
        "        phase=0\n        if [[ -n $cur ]]; then\n            phase=3\n        else\n            phase=2\n        fi\n",
    ) != null);

    // The nested command level has an argument with no values, so the slot
    // case falls through to the flag phase.
    const go_level = m19LevelBlock(script, 2);
    try std.testing.expect(std.mem.indexOf(u8, go_level, "        _tool_rows 2 $pos\n        return\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rows,
        "        phase=0\n        if [[ -n $cur ]]; then\n            phase=3\n        else\n            case $pos in\n            esac\n        fi\n",
    ) != null);
    // A sibling's commands are not offered after a handoff.
    try std.testing.expect(std.mem.indexOf(u8, go_level, "'go'") == null);
}

test "M19: zsh registers merged aliases as hidden matches" {
    const script = try M19.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(
        u8,
        script,
        "        [[ -n $a ]] && hidden+=(\"$a\")\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        script,
        "    if (( ${#hidden} )); then\n        compadd -U -n -V '' -- \"${hidden[@]}\"\n    fi\n",
    ) != null);
    // The visible table disables matching too, since the helper pre-filters.
    try std.testing.expect(std.mem.indexOf(
        u8,
        script,
        "        compadd -U -o nosort -V '' -l -d displays -- \"${cands[@]}\"\n",
    ) != null);
}

test "M19: zsh enumeration value positions" {
    const script = try M19.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    const want =
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq)
        \\                cands=('=fast' '=glacial')
        \\                displays=('=fast' '=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            full)
        \\                cands=('--mode=fast' '--mode=glacial')
        \\                displays=('--mode=fast' '--mode=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            *)
        \\                cands=('fast' 'glacial')
        \\                displays=('fast' 'glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, root, want) != null);
}

test "M19: zsh non-enum value positions return non-zero" {
    const script = try M19Big.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    const arms = [_]String{
        "        '--config')\n            return 1\n            ;;\n",
        "        '--host')\n            return 1\n            ;;\n",
        "        '--port')\n            return 1\n            ;;\n",
        "        '--optional')\n            return 1\n            ;;\n",
    };
    for (arms) |arm| try std.testing.expect(std.mem.indexOf(u8, root, arm) != null);
    // Boolean flags never enter a value arm.
    for ([_]String{ "'--verbose')", "'-v')", "'--fast')", "'--slow')" }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, root, arm) == null);
    }
}

test "M19: zsh value flag table" {
    const script = try M19Big.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(script);

    const start = std.mem.indexOf(u8, script, "_tool_value_flag() {\n") orelse return error.TestUnexpectedResult;
    const rest = script[start..];
    const end = std.mem.indexOf(u8, rest, "\n}\n") orelse return error.TestUnexpectedResult;
    const helper = rest[0..end];

    const guard = std.mem.indexOf(u8, helper, "    *=*) return 1 ;;\n") orelse return error.TestUnexpectedResult;
    const arms = [_]String{
        "    '--config') return 0 ;;\n",
        "    '--host') return 0 ;;\n",
        "    '--port') return 0 ;;\n",
        "    '--optional') return 0 ;;\n",
        "    '--serve_port') return 0 ;;\n",
    };
    for (arms) |arm| {
        const at = std.mem.indexOf(u8, helper, arm) orelse return error.TestUnexpectedResult;
        try std.testing.expect(at > guard);
    }
    for ([_]String{ "    '--verbose')", "    '-v')", "    '--fast')", "    '--slow')", "    '--help')" }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, helper, arm) == null);
    }
}

test "M19: zsh literal terminator returns before dispatch" {
    const script = try M19.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "        if [[ $tok == '--' ]]; then\n            literal=1\n") != null);
    const literal_at = std.mem.indexOf(u8, script, "    if (( literal )); then\n        return 1\n    fi\n") orelse
        return error.TestUnexpectedResult;
    const dispatch_at = std.mem.indexOf(u8, script, "\n    case \"$level\" in\n") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(literal_at < dispatch_at);
}

test "M19: zsh header, locals, and guard" {
    const script = try M19.completion(std.testing.allocator, "my-app", .zsh).text();
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.startsWith(u8, script, "#compdef my-app\n"));
    try std.testing.expect(std.mem.indexOf(u8, script, "_my_app() {\n    emulate -L zsh\n    local level=0 pos=0 literal=0 vflag= vform=bare i tok end\n    local -a cands displays seen\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "_my_app_rows() {\n    emulate -L zsh\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, script, "if [[ $funcstack[1] == '_my_app' ]]; then\n    _my_app \"$@\"\nelse\n    compdef _my_app 'my-app'\nfi\n"));
}

test "M19: zsh level markers" {
    const script = try M19.completion(std.testing.allocator, "app", .zsh).text();
    defer std.testing.allocator.free(script);

    const markers = [_]String{
        "# dap: level 0 m19\n",
        "# dap: level 1 m19 run\n",
        "# dap: level 2 m19 run go\n",
    };
    for (markers) |marker| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, script, marker));
    }
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, script, "# dap: level "));
}

test "M19: zsh quotes candidates and sanitizes descriptions" {
    const weird_flags = [_]Spec{.{
        .name = "weird",
        .kind = .flag,
        .vtype = bool,
        .long = "a'b",
        .short = "x y",
        .required = false,
        .default = null,
        .default_env = null,
        .validation = null,
        .help = "Tab\there\nnext",
        .i18n = null,
        .group = null,
    }};
    const WeirdCmd = struct {
        pub const cmd_meta = CommandMeta{ .help = "Cmd 'help'." };
    };
    const weird_commands = [_]CommandEntry{.{
        .field = "c",
        .view_field = "_c",
        .name = "c d",
        .synonym = null,
        .rank = 1,
        .Cmd = WeirdCmd,
    }};
    const weird_levels = [_]Level{.{
        .rank = 0,
        .path = "weird\troot",
        .flags = &weird_flags,
        .arguments = &.{},
        .commands = &weird_commands,
    }};

    const script = try emitZsh(std.testing.allocator, &weird_levels, &.{}, "weird", "app");
    defer std.testing.allocator.free(script);

    const want =
        "        spell=('--a'\\''b' 'c d')\n" ++
        "        alias=('-x y' '')\n" ++
        "        help=('Tab here next' 'Cmd '\\''help'\\''.')\n" ++
        "        kind=( 0 2 )\n" ++
        "        slot=( -1 -1 )\n" ++
        "        kp=( 0 2 )\n" ++
        "        ka=( 1 0 )\n";
    try std.testing.expect(std.mem.indexOf(u8, script, want) != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "# dap: level 0 weird root\n") != null);
}

test "M19: command synonyms are completion candidates" {
    comptime {
        const levels = model(M19Synonym).levels;
        m19Expect(levels.len == 3, "synonym level count");

        const entries = completionEntries(levels[0]);
        m19Expect(entries.len == 3, "entry count");
        m19Expect(std.mem.eql(u8, entries[0].spelling, "build-target"), "primary name order");
        m19Expect(std.mem.eql(u8, entries[0].alias.?, "b"), "short synonym");
        m19Expect(std.mem.eql(u8, entries[0].help, "Build."), "short synonym help");
        m19Expect(std.mem.eql(u8, entries[1].spelling, "run"), "primary command");
        m19Expect(std.mem.eql(u8, entries[1].alias.?, "go"), "synonym");
        m19Expect(std.mem.eql(u8, entries[1].help, "Run."), "synonym help");
        m19Expect(entries[2].family == .help, "builtin help family");

        const spellings = completionSpellings(entries);
        const want = [_]String{ "b", "build-target", "go", "run", "--help", "-h" };
        m19Expect(spellings.len == want.len, "spelling count");
        for (want, spellings) |w, s| m19Expect(std.mem.eql(u8, w, s), "spelling order");
    }
}

test "M19: bash descends through command synonyms" {
    const script = try M19Synonym.completion(std.testing.allocator, "tool", .bash).text();
    defer std.testing.allocator.free(script);

    for ([_]String{
        "            'run') level=1 pos=0 ;;",
        "            'go') level=1 pos=0 ;;",
        "            'build-target') level=2 pos=0 ;;",
        "            'b') level=2 pos=0 ;;",
    }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, script, arm) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, script, "'b' 'build-target' 'go' 'run' '--help' '-h'") != null);
}

test "M19: zsh and fish offer command synonyms" {
    const zsh = try M19Synonym.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(zsh);
    try std.testing.expect(std.mem.indexOf(
        u8,
        zsh,
        "        spell=('build-target' 'run' '--help')\n" ++
            "        alias=('b' 'go' '-h')\n" ++
            "        help=('Build.' 'Run.' 'Show context-sensitive help.')\n" ++
            "        kind=( 2 2 0 )\n" ++
            "        slot=( -1 -1 -1 )\n" ++
            "        kp=( 3 5 24 )\n" ++
            "        ka=( 2 4 25 )\n",
    ) != null);
    for ([_]String{
        "            'run') level=1 pos=0 ;;",
        "            'go') level=1 pos=0 ;;",
        "            'build-target') level=2 pos=0 ;;",
        "            'b') level=2 pos=0 ;;",
    }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, zsh, arm) != null);
    }

    const fish = try M19Synonym.completion(std.testing.allocator, "tool", .fish).text();
    defer std.testing.allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "        set spell 'build-target' 'run' '--help'\n" ++
            "        set alias 'b' 'go' '-h'\n" ++
            "        set help 'Build.' 'Run.' 'Show context-sensitive help.'\n" ++
            "        set kind 2 2 0\n" ++
            "        set slot -1 -1 -1\n" ++
            "        set kp 3 5 24\n" ++
            "        set ka 2 4 25\n",
    ) != null);
    for ([_]String{
        "            case 'go'\n                set level 1\n                set pos 0",
        "            case 'b'\n                set level 2\n                set pos 0",
    }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, fish, arm) != null);
    }
}

test "M19: fish candidates by level" {
    const script = try M19.completion(std.testing.allocator, "tool", .fish).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    try std.testing.expect(std.mem.indexOf(u8, root, "        __dap_tool_rows 0 $pos \"$cur\"\n") != null);

    const table = std.mem.indexOf(u8, script, "function __dap_tool_rows\n") orelse
        return error.TestUnexpectedResult;
    const rows = script[table..];
    const want_root =
        "    case 0\n" ++
        "        set spell '--mode' '--verbose' 'run' '--help'\n" ++
        "        set alias '' '' '' '-h'\n" ++
        "        set help 'Mode.' 'Verbose.' 'Run.' 'Show context-sensitive help.'\n" ++
        "        set kind 0 0 2 0\n" ++
        "        set slot -1 -1 -1 -1\n" ++
        "        set kp 1 2 4 20\n" ++
        "        set ka 0 0 0 23\n" ++
        "        set phase 0\n" ++
        "        if test -n \"$cur\"\n" ++
        "            set phase 3\n" ++
        "        else\n" ++
        "            set phase 2\n" ++
        "        end\n";
    try std.testing.expect(std.mem.indexOf(u8, rows, want_root) != null);

    const run_level = m19LevelBlock(script, 1);
    try std.testing.expect(std.mem.indexOf(u8, run_level, "        __dap_tool_rows 1 $pos \"$cur\"\n") != null);
    // A sibling's commands are not offered after a handoff.
    try std.testing.expect(std.mem.indexOf(u8, run_level, "'run'") == null);

    const go_level = m19LevelBlock(script, 2);
    try std.testing.expect(std.mem.indexOf(u8, go_level, "        __dap_tool_rows 2 $pos \"$cur\"\n") != null);
    const go_phase =
        "        set phase 0\n" ++
        "        if test -n \"$cur\"\n" ++
        "            set phase 3\n" ++
        "        else\n" ++
        "            switch $pos\n" ++
        "            end\n" ++
        "        end\n";
    try std.testing.expect(std.mem.indexOf(u8, rows, go_phase) != null);
    try std.testing.expect(std.mem.indexOf(u8, go_level, "'go'") == null);

    // Command descent is a nested switch keyed by the level rank.
    try std.testing.expect(std.mem.indexOf(u8, script,
        \\        switch $level
        \\        case 0
        \\            switch $tok
        \\            case 'run'
        \\                set level 1
        \\                set pos 0
        \\            end
        \\        case 1
        \\            switch $tok
        \\            case 'go'
        \\                set level 2
        \\                set pos 0
        \\            end
        \\        end
        \\
    ) != null);
}

test "M19: fish enumeration value positions" {
    const script = try M19.completion(std.testing.allocator, "tool", .fish).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    const want =
        \\        if test -n "$vflag"
        \\            switch $vflag
        \\            case '--mode'
        \\                switch $vform
        \\                case full
        \\                    printf '%s\n' '--mode=fast' '--mode=glacial'
        \\                case '*'
        \\                    printf '%s\n' 'fast' 'glacial'
        \\                end
        \\                return
        \\            end
        \\            return
        \\        end
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, root, want) != null);
}

test "M19: fish non-enum value positions fall back to paths" {
    const script = try M19Big.completion(std.testing.allocator, "tool", .fish).text();
    defer std.testing.allocator.free(script);

    const root = m19LevelBlock(script, 0);
    const arms = [_]String{
        "            case '--config'\n                __fish_complete_path\n                return\n",
        "            case '--host'\n                __fish_complete_path\n                return\n",
        "            case '--port'\n                __fish_complete_path\n                return\n",
        "            case '--optional'\n                __fish_complete_path\n                return\n",
    };
    for (arms) |arm| try std.testing.expect(std.mem.indexOf(u8, root, arm) != null);
    // Boolean flags never enter a value arm.
    for ([_]String{ "            case '--verbose'", "            case '-v'", "            case '--fast'", "            case '--slow'" }) |arm| {
        try std.testing.expect(std.mem.indexOf(u8, root, arm) == null);
    }
}

test "M19: fish value flag table" {
    const script = try M19Big.completion(std.testing.allocator, "tool", .fish).text();
    defer std.testing.allocator.free(script);

    const start = std.mem.indexOf(u8, script, "function __dap_tool_value_flag\n") orelse
        return error.TestUnexpectedResult;
    const rest = script[start..];
    const end = std.mem.indexOf(u8, rest, "\nend\n") orelse return error.TestUnexpectedResult;
    const helper = rest[0..end];

    const guard = std.mem.indexOf(u8, helper, "    case '*=*'\n        return 1\n") orelse
        return error.TestUnexpectedResult;
    const arm = std.mem.indexOf(u8, helper, "    case '--config' '--host' '--port' '--optional' '--serve_port'\n        return 0\n") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(arm > guard);
    for ([_]String{ "'--verbose'", "'-v'", "'--fast'", "'--slow'", "'--help'" }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, helper, absent) == null);
    }
}

test "M19: fish literal terminator and file fallback" {
    const script = try M19.completion(std.testing.allocator, "tool", .fish).text();
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "        if test \"$tok\" = '--'\n            set literal 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "\n    if test $literal -eq 1\n        return\n    end\n") != null);
    // `-f` removes fish's implicit file fallback; the helper adds paths for
    // plain value positions itself instead.
    try std.testing.expect(std.mem.endsWith(u8, script, "complete -c 'tool' -f -a '(__dap_tool_complete)' -k\n"));
    try std.testing.expect(std.mem.indexOf(u8, script, "or __fish_complete_path\n") != null);
}

test "M19: fish quotes candidates and skips unrepresentable names" {
    const weird_flags = [_]Spec{.{
        .name = "weird",
        .kind = .flag,
        .vtype = bool,
        .long = "a'b",
        .short = "x y",
        .required = false,
        .default = null,
        .default_env = null,
        .validation = null,
        .help = "Tab\there\nnext",
        .i18n = null,
        .group = null,
    }};
    const WeirdCmd = struct {
        pub const cmd_meta = CommandMeta{ .help = "Cmd 'help'." };
    };
    const weird_commands = [_]CommandEntry{
        .{
            .field = "c",
            .view_field = "_c",
            .name = "c d",
            .synonym = null,
            .rank = 1,
            .Cmd = WeirdCmd,
        },
        .{
            .field = "bad",
            .view_field = "_bad",
            .name = "bad\ttab",
            .synonym = null,
            .rank = 2,
            .Cmd = WeirdCmd,
        },
        .{
            .field = "bad2",
            .view_field = "_bad2",
            .name = "bad\nline",
            .synonym = null,
            .rank = 3,
            .Cmd = WeirdCmd,
        },
    };
    const weird_levels = [_]Level{.{
        .rank = 0,
        .path = "weird\troot",
        .flags = &weird_flags,
        .arguments = &.{},
        .commands = &weird_commands,
    }};

    const script = try emitFish(std.testing.allocator, &weird_levels, &.{}, "weird", "app");
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(
        u8,
        script,
        "        set spell '--a\\'b' 'c d'\n" ++
            "        set alias '-x y' ''\n" ++
            "        set help 'Tab here next' 'Cmd \\'help\\'.'\n" ++
            "        set kind 0 2\n" ++
            "        set slot -1 -1\n" ++
            "        set kp 0 4\n" ++
            "        set ka 1 0\n",
    ) != null);
    // A tab or newline cannot cross fish's line protocol: the candidate and
    // its descent case are both dropped.
    try std.testing.expect(std.mem.indexOf(u8, script, "bad\t") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "bad\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "case 'bad") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "# dap: level 0 weird root\n") != null);
}

test "M19: short enum spelling" {
    const bash = try M19Short.completion(std.testing.allocator, "tool", .bash).text();
    defer std.testing.allocator.free(bash);
    const bash_root = m19LevelBlock(bash, 0);
    const bash_want =
        \\        case "$vflag" in
        \\        '--level')
        \\            case "$vform" in
        \\            eq) _dap_tool_filter "$cur" '=fast' '=glacial' ;;
        \\            full) _dap_tool_filter "$vflag=" '--level=fast' '--level=glacial' ;;
        \\            *) _dap_tool_filter "$cur" 'fast' 'glacial' ;;
        \\            esac
        \\            return
        \\            ;;
        \\        '-l')
        \\            case "$vform" in
        \\            eq) _dap_tool_filter "$cur" '=fast' '=glacial' ;;
        \\            full) _dap_tool_filter "$vflag=" '-l=fast' '-l=glacial' ;;
        \\            *) _dap_tool_filter "$cur" 'fast' 'glacial' ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, bash_root, bash_want) != null);
    try std.testing.expect(std.mem.indexOf(u8, bash_root, "_dap_tool_filter \"$cur\" '--level' '-l' '--help' '-h'\n") != null);
    // Both spellings skip a following value word.
    const bash_helper_at = std.mem.indexOf(u8, bash, "_dap_tool_value_flag() {\n") orelse
        return error.TestUnexpectedResult;
    const bash_helper = bash[bash_helper_at..];
    try std.testing.expect(std.mem.indexOf(u8, bash_helper, "    '--level') return 0 ;;\n    '-l') return 0 ;;\n") != null);

    const zsh = try M19Short.completion(std.testing.allocator, "tool", .zsh).text();
    defer std.testing.allocator.free(zsh);
    const zsh_root = m19LevelBlock(zsh, 0);
    const zsh_want =
        \\        case "$vflag" in
        \\        '--level')
        \\            case "$vform" in
        \\            eq)
        \\                cands=('=fast' '=glacial')
        \\                displays=('=fast' '=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            full)
        \\                cands=('--level=fast' '--level=glacial')
        \\                displays=('--level=fast' '--level=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            *)
        \\                cands=('fast' 'glacial')
        \\                displays=('fast' 'glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            esac
        \\            return
        \\            ;;
        \\        '-l')
        \\            case "$vform" in
        \\            eq)
        \\                cands=('=fast' '=glacial')
        \\                displays=('=fast' '=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            full)
        \\                cands=('-l=fast' '-l=glacial')
        \\                displays=('-l=fast' '-l=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            *)
        \\                cands=('fast' 'glacial')
        \\                displays=('fast' 'glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, zsh_root, zsh_want) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        zsh,
        "        spell=('--level' '--help')\n" ++
            "        alias=('-l' '-h')\n" ++
            "        help=('Level.' 'Show context-sensitive help.')\n" ++
            "        kind=( 0 0 )\n" ++
            "        slot=( -1 -1 )\n" ++
            "        kp=( 1 16 )\n" ++
            "        ka=( 3 18 )\n",
    ) != null);

    const fish = try M19Short.completion(std.testing.allocator, "tool", .fish).text();
    defer std.testing.allocator.free(fish);
    const fish_root = m19LevelBlock(fish, 0);
    const fish_want =
        \\            case '--level'
        \\                switch $vform
        \\                case full
        \\                    printf '%s\n' '--level=fast' '--level=glacial'
        \\                case '*'
        \\                    printf '%s\n' 'fast' 'glacial'
        \\                end
        \\                return
        \\            case '-l'
        \\                switch $vform
        \\                case full
        \\                    printf '%s\n' '-l=fast' '-l=glacial'
        \\                case '*'
        \\                    printf '%s\n' 'fast' 'glacial'
        \\                end
        \\                return
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, fish_root, fish_want) != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "    case '--level' '-l'\n        return 0\n") != null);
}

test "M19: empty enumeration value positions" {
    const Empty = Enumeration(.{});
    const empty_flags = [_]Spec{.{
        .name = "e",
        .kind = .flag,
        .vtype = Empty,
        .long = "e",
        .short = null,
        .required = false,
        .default = null,
        .default_env = null,
        .validation = null,
        .help = "",
        .i18n = null,
        .group = null,
    }};
    const empty_levels = [_]Level{.{
        .rank = 0,
        .path = "empty",
        .flags = &empty_flags,
        .arguments = &.{},
        .commands = &.{},
    }};

    const bash = try emitBash(std.testing.allocator, &empty_levels, &.{}, "x", "app");
    defer std.testing.allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "        '--e')\n            return\n            ;;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "case \"$vform\"") == null);

    const zsh = try emitZsh(std.testing.allocator, &empty_levels, &.{}, "x", "app");
    defer std.testing.allocator.free(zsh);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "        '--e')\n            return 1\n            ;;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "case \"$vform\"") == null);

    const fish = try emitFish(std.testing.allocator, &empty_levels, &.{}, "x", "app");
    defer std.testing.allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(u8, fish, "            case '--e'\n                __fish_complete_path\n                return\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "switch $vform") == null);
}

test "M19: identifier sanitization collisions" {
    // Every byte outside `[A-Za-z0-9_]` maps to `_`, so distinct names can
    // share one function stem. Registration still differs, but sourcing both
    // scripts at once is unsupported; this test pins that documented limit.
    const a = try M19.completion(std.testing.allocator, "a-b", .bash).text();
    defer std.testing.allocator.free(a);
    const b = try M19.completion(std.testing.allocator, "a_b", .bash).text();
    defer std.testing.allocator.free(b);

    try std.testing.expect(std.mem.indexOf(u8, a, "_dap_a_b() {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "_dap_a_b() {\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, a, "complete -o default -F _dap_a_b 'a-b'\n"));
    try std.testing.expect(std.mem.endsWith(u8, b, "complete -o default -F _dap_a_b 'a_b'\n"));

    const zsh = try M19.completion(std.testing.allocator, "a.b", .zsh).text();
    defer std.testing.allocator.free(zsh);
    try std.testing.expect(std.mem.startsWith(u8, zsh, "#compdef a.b\n"));
    try std.testing.expect(std.mem.indexOf(u8, zsh, "_a_b() {\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, zsh, "compdef _a_b 'a.b'\nfi\n"));

    const fish = try M19.completion(std.testing.allocator, "a+b", .fish).text();
    defer std.testing.allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(u8, fish, "function __dap_a_b_complete\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, fish, "complete -c 'a+b' -f -a '(__dap_a_b_complete)' -k\n"));
}

test "M19: out of memory sweep" {
    const FailingAllocator = std.testing.FailingAllocator;

    inline for (.{ Completion.Shell.bash, Completion.Shell.zsh, Completion.Shell.fish }) |shell| {
        const total = blk: {
            var probe = FailingAllocator.init(std.testing.allocator, .{});
            const script = try M19.completion(probe.allocator(), "m19", shell).text();
            probe.allocator().free(script);
            break :blk probe.allocations;
        };
        try std.testing.expect(total > 0);

        var fi: usize = 0;
        while (fi <= total) : (fi += 1) {
            var fa = FailingAllocator.init(std.testing.allocator, .{ .fail_index = fi });
            if (M19.completion(fa.allocator(), "m19", shell).text()) |script| {
                fa.allocator().free(script);
            } else |e| {
                try std.testing.expectEqual(std.mem.Allocator.Error.OutOfMemory, e);
            }
            try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
        }
    }
}

test "M19: bash golden" {
    const script = try M19.completion(std.testing.allocator, "m19", .bash).text();
    defer std.testing.allocator.free(script);
    const want =
        \\_dap_m19_filter() {
        \\    local cur=$1; shift
        \\    COMPREPLY=()
        \\    local c
        \\    for c in "$@"; do
        \\        [[ $c == "$cur"* ]] && COMPREPLY+=("$c")
        \\    done
        \\}
        \\
        \\_dap_m19_value_flag() {
        \\    case "$1" in
        \\    *=*) return 1 ;;
        \\    '--mode') return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_dap_m19() {
        \\    local cur prev level=0 pos=0 literal=0
        \\    local vflag= vform=bare
        \\    local i tok end
        \\    COMPREPLY=()
        \\    cur=${COMP_WORDS[COMP_CWORD]}
        \\    prev=
        \\    if (( COMP_CWORD >= 1 )); then
        \\        prev=${COMP_WORDS[COMP_CWORD-1]}
        \\    fi
        \\    end=$((COMP_CWORD - 1))
        \\    i=1
        \\    while (( i <= end )); do
        \\        tok=${COMP_WORDS[i]}
        \\        if (( literal )); then
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        if [[ $tok == '--' ]]; then
        \\            literal=1
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && $tok == *=* ]]; then
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        if _dap_m19_value_flag "$tok"; then
        \\            if (( i + 1 <= end )) && [[ ${COMP_WORDS[i+1]} == '=' ]]; then
        \\                i=$((i + 3))
        \\            else
        \\                i=$((i + 2))
        \\            fi
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && ${#tok} -gt 1 ]]; then
        \\            i=$((i + 1))
        \\            continue
        \\        fi
        \\        pos=$((pos + 1))
        \\        case "$level" in
        \\        0)
        \\            case "$tok" in
        \\            'run') level=1 pos=0 ;;
        \\            esac
        \\            ;;
        \\        1)
        \\            case "$tok" in
        \\            'go') level=2 pos=0 ;;
        \\            esac
        \\            ;;
        \\        2)
        \\            ;;
        \\        esac
        \\        i=$((i + 1))
        \\    done
        \\    if (( literal )); then
        \\        return
        \\    fi
        \\    if [[ $cur == '=' ]] && _dap_m19_value_flag "$prev"; then
        \\        vflag=$prev
        \\        vform=eq
        \\    elif [[ $prev == '=' ]] && (( COMP_CWORD >= 2 )); then
        \\        vflag=${COMP_WORDS[COMP_CWORD-2]}
        \\    elif _dap_m19_value_flag "$prev"; then
        \\        vflag=$prev
        \\    elif [[ $cur == -* && $cur == *=* ]]; then
        \\        vflag=${cur%%=*}
        \\        vform=full
        \\    fi
        \\    case "$level" in
        \\    0)
        \\# dap: level 0 m19
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq) _dap_m19_filter "$cur" '=fast' '=glacial' ;;
        \\            full) _dap_m19_filter "$vflag=" '--mode=fast' '--mode=glacial' ;;
        \\            *) _dap_m19_filter "$cur" 'fast' 'glacial' ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\        if [[ -z $cur ]]; then
        \\            _dap_m19_filter "$cur" 'run'
        \\        else
        \\            _dap_m19_filter "$cur" '--mode' '--verbose' 'run' '--help' '-h'
        \\        fi
        \\        ;;
        \\    1)
        \\# dap: level 1 m19 run
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq) _dap_m19_filter "$cur" '=fast' '=glacial' ;;
        \\            full) _dap_m19_filter "$vflag=" '--mode=fast' '--mode=glacial' ;;
        \\            *) _dap_m19_filter "$cur" 'fast' 'glacial' ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\        if [[ -z $cur ]]; then
        \\            _dap_m19_filter "$cur" 'go'
        \\        else
        \\            _dap_m19_filter "$cur" '--mode' '--verbose' 'go' '--help' '-h'
        \\        fi
        \\        ;;
        \\    2)
        \\# dap: level 2 m19 run go
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq) _dap_m19_filter "$cur" '=fast' '=glacial' ;;
        \\            full) _dap_m19_filter "$vflag=" '--mode=fast' '--mode=glacial' ;;
        \\            *) _dap_m19_filter "$cur" 'fast' 'glacial' ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\        if [[ -z $cur ]]; then
        \\            case "$pos" in
        \\            0) _dap_m19_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            *) _dap_m19_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            esac
        \\        else
        \\            case "$pos" in
        \\            0) _dap_m19_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            *) _dap_m19_filter "$cur" '--mode' '--verbose' '--help' '-h' ;;
        \\            esac
        \\        fi
        \\        ;;
        \\    esac
        \\}
        \\
        \\complete -o default -F _dap_m19 'm19'
        \\
    ;
    try std.testing.expectEqualStrings(want, script);
}

test "M19: zsh golden" {
    const script = try M19.completion(std.testing.allocator, "m19", .zsh).text();
    defer std.testing.allocator.free(script);
    const want =
        \\#compdef m19
        \\_m19_value_flag() {
        \\    case "$1" in
        \\    *=*) return 1 ;;
        \\    '--mode') return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_m19_rows() {
        \\    emulate -L zsh
        \\    local rank=$1 pos=$2 cur=$PREFIX
        \\    local -a spell alias help kind slot kp ka
        \\    local -a sel_spell sel_alias sel_help sel_key hidden
        \\    local phase=3 i n s a eff kk kind_i slot_i j pkey
        \\    local ws=0 wa=0 k3=0 row any=0 blank=''
        \\    seen=()
        \\    case $rank in
        \\    0)
        \\        spell=('--mode' '--verbose' 'run' '--help')
        \\        alias=('' '' '' '-h')
        \\        help=('Mode.' 'Verbose.' 'Run.' 'Show context-sensitive help.')
        \\        kind=( 0 0 2 0 )
        \\        slot=( -1 -1 -1 -1 )
        \\        kp=( 1 2 4 20 )
        \\        ka=( 0 0 0 23 )
        \\        phase=0
        \\        if [[ -n $cur ]]; then
        \\            phase=3
        \\        else
        \\            phase=2
        \\        fi
        \\        ;;
        \\    1)
        \\        spell=('--mode' '--verbose' 'go' '--help')
        \\        alias=('' '' '' '-h')
        \\        help=('Mode.' 'Verbose.' 'Go.' 'Show context-sensitive help.')
        \\        kind=( 0 0 2 0 )
        \\        slot=( -1 -1 -1 -1 )
        \\        kp=( 1 2 4 20 )
        \\        ka=( 0 0 0 23 )
        \\        phase=0
        \\        if [[ -n $cur ]]; then
        \\            phase=3
        \\        else
        \\            phase=2
        \\        fi
        \\        ;;
        \\    2)
        \\        spell=('--mode' '--verbose' '--help')
        \\        alias=('' '' '-h')
        \\        help=('Mode.' 'Verbose.' 'Show context-sensitive help.')
        \\        kind=( 0 0 0 )
        \\        slot=( -1 -1 -1 )
        \\        kp=( 1 2 16 )
        \\        ka=( 0 0 19 )
        \\        phase=0
        \\        if [[ -n $cur ]]; then
        \\            phase=3
        \\        else
        \\            case $pos in
        \\            esac
        \\        fi
        \\        ;;
        \\    esac
        \\    local -a cands displays
        \\    n=${#spell}
        \\    for (( i = 1; i <= n; i++ )); do
        \\        kind_i=${kind[i]}
        \\        slot_i=${slot[i]}
        \\        if (( phase == 0 )); then
        \\            (( kind_i == 0 )) || continue
        \\        elif (( phase == 2 )); then
        \\            (( kind_i == 2 )) || continue
        \\        elif (( phase == 1 )); then
        \\            (( slot_i == pos )) || continue
        \\        elif (( kind_i == 1 )); then
        \\            (( slot_i == pos )) || continue
        \\        fi
        \\        s=${spell[i]}
        \\        a=${alias[i]}
        \\        if [[ -n $a && $a == "$cur"* && $s == "$cur"* ]]; then
        \\            eff=$s
        \\            kk=${kp[i]}
        \\        elif [[ -n $a && $a == "$cur"* ]]; then
        \\            eff=$a
        \\            a=
        \\            kk=${ka[i]}
        \\        elif [[ $s == "$cur"* ]]; then
        \\            eff=$s
        \\            kk=${kp[i]}
        \\        else
        \\            continue
        \\        fi
        \\        sel_spell+=("$eff")
        \\        sel_alias+=("$a")
        \\        sel_help+=("${help[i]}")
        \\        sel_key+=("$kk")
        \\        [[ -n $a ]] && hidden+=("$a")
        \\    done
        \\    n=${#sel_spell}
        \\    for (( i = 2; i <= n; i++ )); do
        \\        s=${sel_spell[i]}
        \\        a=${sel_alias[i]}
        \\        kk=${sel_key[i]}
        \\        h=${sel_help[i]}
        \\        j=$(( i - 1 ))
        \\        while (( j >= 1 )); do
        \\            pkey=${sel_key[j]}
        \\            if (( kk < pkey )); then
        \\                sel_spell[$(( j + 1 ))]=$s
        \\                sel_alias[$(( j + 1 ))]=$a
        \\                sel_help[$(( j + 1 ))]=$h
        \\                sel_key[$(( j + 1 ))]=$kk
        \\                j=$(( j - 1 ))
        \\            else
        \\                break
        \\            fi
        \\        done
        \\        sel_spell[$(( j + 1 ))]=$s
        \\        sel_alias[$(( j + 1 ))]=$a
        \\        sel_help[$(( j + 1 ))]=$h
        \\        sel_key[$(( j + 1 ))]=$kk
        \\    done
        \\    for (( i = 1; i <= n; i++ )); do
        \\        (( ${#sel_spell[i]} > ws )) && ws=${#sel_spell[i]}
        \\        (( ${#sel_alias[i]} > wa )) && wa=${#sel_alias[i]}
        \\        [[ -n ${sel_alias[i]} ]] && k3=1
        \\    done
        \\    for (( i = 1; i <= n; i++ )); do
        \\        cands+=("${sel_spell[i]}")
        \\        seen+=("${sel_spell[i]}")
        \\        row=${(r:$ws:)sel_spell[i]}
        \\        if (( k3 )); then
        \\            if [[ -n ${sel_alias[i]} ]]; then
        \\                row="$row  ${(r:$wa:)sel_alias[i]}"
        \\            else
        \\                row="$row  ${(r:$wa:)blank}"
        \\            fi
        \\        fi
        \\        if [[ -n ${sel_help[i]} ]]; then
        \\            row="$row  -- ${sel_help[i]}"
        \\        fi
        \\        while [[ $row == *' ' ]]; do
        \\            row=${row% }
        \\        done
        \\        displays+=("$row")
        \\    done
        \\    if (( n == 0 )); then
        \\        return 1
        \\    fi
        \\    for (( i = 1; i <= n; i++ )); do
        \\        if [[ ${displays[i]} != ${cands[i]} ]]; then
        \\            any=1
        \\            break
        \\        fi
        \\    done
        \\    if (( any )); then
        \\        compadd -U -o nosort -V '' -l -d displays -- "${cands[@]}"
        \\    else
        \\        compadd -U -o nosort -d displays -- "${cands[@]}"
        \\    fi
        \\    if (( ${#hidden} )); then
        \\        compadd -U -n -V '' -- "${hidden[@]}"
        \\    fi
        \\}
        \\
        \\_m19() {
        \\    emulate -L zsh
        \\    local level=0 pos=0 literal=0 vflag= vform=bare i tok end
        \\    local -a cands displays seen
        \\    end=$(( CURRENT - 1 ))
        \\    i=2
        \\    while (( i <= end )); do
        \\        tok=${words[i]}
        \\        if (( literal )); then
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        if [[ $tok == '--' ]]; then
        \\            literal=1
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && $tok == *=* ]]; then
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        if _m19_value_flag "$tok"; then
        \\            if (( i + 1 <= end )) && [[ ${words[i+1]} == '=' ]]; then
        \\                i=$(( i + 3 ))
        \\            else
        \\                i=$(( i + 2 ))
        \\            fi
        \\            continue
        \\        fi
        \\        if [[ $tok == -* && ${#tok} -gt 1 ]]; then
        \\            i=$(( i + 1 ))
        \\            continue
        \\        fi
        \\        pos=$(( pos + 1 ))
        \\        case "$level" in
        \\        0)
        \\            case "$tok" in
        \\            'run') level=1 pos=0 ;;
        \\            esac
        \\            ;;
        \\        1)
        \\            case "$tok" in
        \\            'go') level=2 pos=0 ;;
        \\            esac
        \\            ;;
        \\        2)
        \\            ;;
        \\        esac
        \\        i=$(( i + 1 ))
        \\    done
        \\    if (( literal )); then
        \\        return 1
        \\    fi
        \\    if (( CURRENT >= 2 )); then
        \\        if [[ $PREFIX == '=' ]] && _m19_value_flag "$words[CURRENT-1]"; then
        \\            vflag=$words[CURRENT-1]
        \\            vform=eq
        \\        elif [[ $words[CURRENT-1] == '=' ]] && (( CURRENT >= 3 )); then
        \\            vflag=$words[CURRENT-2]
        \\        elif _m19_value_flag "$words[CURRENT-1]"; then
        \\            vflag=$words[CURRENT-1]
        \\        fi
        \\    fi
        \\    if [[ -z $vflag && $PREFIX == -* && $PREFIX == *=* ]]; then
        \\        vflag=${PREFIX%%=*}
        \\        vform=full
        \\    fi
        \\    case "$level" in
        \\    0)
        \\# dap: level 0 m19
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq)
        \\                cands=('=fast' '=glacial')
        \\                displays=('=fast' '=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            full)
        \\                cands=('--mode=fast' '--mode=glacial')
        \\                displays=('--mode=fast' '--mode=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            *)
        \\                cands=('fast' 'glacial')
        \\                displays=('fast' 'glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\        _m19_rows 0 $pos
        \\        return
        \\        ;;
        \\    1)
        \\# dap: level 1 m19 run
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq)
        \\                cands=('=fast' '=glacial')
        \\                displays=('=fast' '=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            full)
        \\                cands=('--mode=fast' '--mode=glacial')
        \\                displays=('--mode=fast' '--mode=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            *)
        \\                cands=('fast' 'glacial')
        \\                displays=('fast' 'glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\        _m19_rows 1 $pos
        \\        return
        \\        ;;
        \\    2)
        \\# dap: level 2 m19 run go
        \\        case "$vflag" in
        \\        '--mode')
        \\            case "$vform" in
        \\            eq)
        \\                cands=('=fast' '=glacial')
        \\                displays=('=fast' '=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            full)
        \\                cands=('--mode=fast' '--mode=glacial')
        \\                displays=('--mode=fast' '--mode=glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            *)
        \\                cands=('fast' 'glacial')
        \\                displays=('fast' 'glacial')
        \\                compadd -o nosort -d displays -- "${cands[@]}"
        \\                ;;
        \\            esac
        \\            return
        \\            ;;
        \\        esac
        \\        _m19_rows 2 $pos
        \\        return
        \\        ;;
        \\    esac
        \\    return 1
        \\}
        \\if [[ $funcstack[1] == '_m19' ]]; then
        \\    _m19 "$@"
        \\else
        \\    compdef _m19 'm19'
        \\fi
        \\
    ;
    try std.testing.expectEqualStrings(want, script);
}

test "M19: fish golden" {
    const script = try M19.completion(std.testing.allocator, "m19", .fish).text();
    defer std.testing.allocator.free(script);
    const want =
        \\function __dap_m19_value_flag
        \\    switch $argv[1]
        \\    case '*=*'
        \\        return 1
        \\    case '--mode'
        \\        return 0
        \\    end
        \\    return 1
        \\end
        \\
        \\function __dap_m19_rows
        \\    set -l rank $argv[1]
        \\    set -l pos $argv[2]
        \\    set -l cur $argv[3]
        \\    set -l spell
        \\    set -l alias
        \\    set -l help
        \\    set -l kind
        \\    set -l slot
        \\    set -l kp
        \\    set -l ka
        \\    set -l phase 3
        \\    switch $rank
        \\    case 0
        \\        set spell '--mode' '--verbose' 'run' '--help'
        \\        set alias '' '' '' '-h'
        \\        set help 'Mode.' 'Verbose.' 'Run.' 'Show context-sensitive help.'
        \\        set kind 0 0 2 0
        \\        set slot -1 -1 -1 -1
        \\        set kp 1 2 4 20
        \\        set ka 0 0 0 23
        \\        set phase 0
        \\        if test -n "$cur"
        \\            set phase 3
        \\        else
        \\            set phase 2
        \\        end
        \\    case 1
        \\        set spell '--mode' '--verbose' 'go' '--help'
        \\        set alias '' '' '' '-h'
        \\        set help 'Mode.' 'Verbose.' 'Go.' 'Show context-sensitive help.'
        \\        set kind 0 0 2 0
        \\        set slot -1 -1 -1 -1
        \\        set kp 1 2 4 20
        \\        set ka 0 0 0 23
        \\        set phase 0
        \\        if test -n "$cur"
        \\            set phase 3
        \\        else
        \\            set phase 2
        \\        end
        \\    case 2
        \\        set spell '--mode' '--verbose' '--help'
        \\        set alias '' '' '-h'
        \\        set help 'Mode.' 'Verbose.' 'Show context-sensitive help.'
        \\        set kind 0 0 0
        \\        set slot -1 -1 -1
        \\        set kp 1 2 16
        \\        set ka 0 0 19
        \\        set phase 0
        \\        if test -n "$cur"
        \\            set phase 3
        \\        else
        \\            switch $pos
        \\            end
        \\        end
        \\    end
        \\    set -l sel_spell
        \\    set -l sel_alias
        \\    set -l sel_help
        \\    set -l sel_key
        \\    for i in (seq (count $spell))
        \\        set -l k $kind[$i]
        \\        set -l sl $slot[$i]
        \\        if test $phase -eq 0
        \\            test $k -eq 0; or continue
        \\        else if test $phase -eq 2
        \\            test $k -eq 2; or continue
        \\        else if test $phase -eq 1
        \\            test $sl -eq $pos; or continue
        \\        else if test $k -eq 1
        \\            test $sl -eq $pos; or continue
        \\        end
        \\        set -l s $spell[$i]
        \\        set -l a $alias[$i]
        \\        set -l hit 0
        \\        if test (string sub -l (string length -- $cur) -- $s) = "$cur"
        \\            set hit 1
        \\        end
        \\        set -l amatch 0
        \\        if test -n "$a"; and test (string sub -l (string length -- $cur) -- $a) = "$cur"
        \\            set amatch 1
        \\        end
        \\        if test $amatch -eq 1
        \\            if test $hit -eq 1
        \\                set sel_spell $sel_spell "$s"
        \\                set sel_alias $sel_alias "$a"
        \\                set sel_key $sel_key $kp[$i]
        \\            else
        \\                set sel_spell $sel_spell "$a"
        \\                set sel_alias $sel_alias ''
        \\                set sel_key $sel_key $ka[$i]
        \\            end
        \\        else if test $hit -eq 1
        \\            set sel_spell $sel_spell "$s"
        \\            set sel_alias $sel_alias ''
        \\            set sel_key $sel_key $kp[$i]
        \\        else
        \\            continue
        \\        end
        \\        set sel_help $sel_help "$help[$i]"
        \\    end
        \\    set -l n (count $sel_spell)
        \\    if test $n -eq 0
        \\        return 1
        \\    end
        \\    for i in (seq 2 $n)
        \\        set -l ks $sel_spell[$i]
        \\        set -l ka2 $sel_alias[$i]
        \\        set -l kh $sel_help[$i]
        \\        set -l kk $sel_key[$i]
        \\        set -l j (math $i - 1)
        \\        while test $j -ge 1
        \\            if test $kk -lt $sel_key[$j]
        \\                set sel_spell[(math $j + 1)] $sel_spell[$j]
        \\                set sel_alias[(math $j + 1)] $sel_alias[$j]
        \\                set sel_help[(math $j + 1)] $sel_help[$j]
        \\                set sel_key[(math $j + 1)] $sel_key[$j]
        \\                set j (math $j - 1)
        \\            else
        \\                break
        \\            end
        \\        end
        \\        set sel_spell[(math $j + 1)] $ks
        \\        set sel_alias[(math $j + 1)] $ka2
        \\        set sel_help[(math $j + 1)] $kh
        \\        set sel_key[(math $j + 1)] $kk
        \\    end
        \\    for i in (seq $n)
        \\        set -l s $sel_spell[$i]
        \\        set -l a $sel_alias[$i]
        \\        set -l h $sel_help[$i]
        \\        if test -n "$h"
        \\            if test -n "$a"
        \\                printf '%s\t%s\n' "$s" "$a  -- $h"
        \\            else
        \\                printf '%s\t%s\n' "$s" "-- $h"
        \\            end
        \\        else if test -n "$a"
        \\            printf '%s\t%s\n' "$s" "$a"
        \\        else
        \\            printf '%s\n' "$s"
        \\        end
        \\    end
        \\    return 0
        \\end
        \\
        \\function __dap_m19_complete
        \\    set -l toks (commandline -opc)
        \\    set -e toks[1]
        \\    set -l cur (commandline -ct)
        \\    set -l prev ''
        \\    if test (count $toks) -ge 1
        \\        set prev $toks[-1]
        \\    end
        \\    set -l level 0
        \\    set -l pos 0
        \\    set -l literal 0
        \\    set -l i 1
        \\    set -l end (count $toks)
        \\    while test $i -le $end
        \\        set -l tok $toks[$i]
        \\        if test $literal -eq 1
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        if test "$tok" = '--'
        \\            set literal 1
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        if string match -qr '^-.*=' -- $tok
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        if __dap_m19_value_flag $tok
        \\            set i (math $i + 2)
        \\            continue
        \\        end
        \\        if string match -qr '^-' -- $tok
        \\            set i (math $i + 1)
        \\            continue
        \\        end
        \\        set pos (math $pos + 1)
        \\        switch $level
        \\        case 0
        \\            switch $tok
        \\            case 'run'
        \\                set level 1
        \\                set pos 0
        \\            end
        \\        case 1
        \\            switch $tok
        \\            case 'go'
        \\                set level 2
        \\                set pos 0
        \\            end
        \\        end
        \\        set i (math $i + 1)
        \\    end
        \\    if test $literal -eq 1
        \\        return
        \\    end
        \\    set -l vflag ''
        \\    set -l vform bare
        \\    if string match -qr '^-.*=' -- $cur
        \\        set vflag (string split -m 1 '=' -- $cur)[1]
        \\        set vform full
        \\    else if test -n "$prev"
        \\        if __dap_m19_value_flag $prev
        \\            set vflag $prev
        \\        end
        \\    end
        \\    switch $level
        \\    # dap: level 0 m19
        \\    case 0
        \\        if test -n "$vflag"
        \\            switch $vflag
        \\            case '--mode'
        \\                switch $vform
        \\                case full
        \\                    printf '%s\n' '--mode=fast' '--mode=glacial'
        \\                case '*'
        \\                    printf '%s\n' 'fast' 'glacial'
        \\                end
        \\                return
        \\            end
        \\            return
        \\        end
        \\        __dap_m19_rows 0 $pos "$cur"
        \\    # dap: level 1 m19 run
        \\    case 1
        \\        if test -n "$vflag"
        \\            switch $vflag
        \\            case '--mode'
        \\                switch $vform
        \\                case full
        \\                    printf '%s\n' '--mode=fast' '--mode=glacial'
        \\                case '*'
        \\                    printf '%s\n' 'fast' 'glacial'
        \\                end
        \\                return
        \\            end
        \\            return
        \\        end
        \\        __dap_m19_rows 1 $pos "$cur"
        \\    # dap: level 2 m19 run go
        \\    case 2
        \\        if test -n "$vflag"
        \\            switch $vflag
        \\            case '--mode'
        \\                switch $vform
        \\                case full
        \\                    printf '%s\n' '--mode=fast' '--mode=glacial'
        \\                case '*'
        \\                    printf '%s\n' 'fast' 'glacial'
        \\                end
        \\                return
        \\            end
        \\            return
        \\        end
        \\        __dap_m19_rows 2 $pos "$cur"
        \\        or __fish_complete_path
        \\    end
        \\end
        \\
        \\complete -c 'm19' -f -a '(__dap_m19_complete)' -k
        \\
    ;
    try std.testing.expectEqualStrings(want, script);
}

// ---------------------------------------------------------------------------
// M20: completion entry model, ordering, and phases.
// ---------------------------------------------------------------------------

const M20Kind = Enumeration(.{
    .beta = Enum{ .help = "Beta value." },
    .alpha = Enum{ .help = "Alpha value." },
});

const M20Def = .{
    .description = Flag([]const u8){ .short = "d", .help = "Description." },
    .version = Flag(bool){ .default = Default(bool){ .direct = false } },
    .mode = Flag(M20Kind){
        .long = "mode",
        .default = Default(M20Kind){ .direct = .{} },
        .help = "Mode.",
    },
    .pick = Command(.{ .synonym = "p", .help = "Pick." }, .{
        .kind = Argument(M20Kind){ .help = "Kind." },
        .verbose = Flag(bool){
            .short = "v",
            .default = Default(bool){ .direct = false },
            .help = "Verbose.",
        },
    }),
    .quiet = Command(.{ .help = "" }, .{}),
};

const M20 = generate(App{ .name = "m20", .help = "M20 root." }, M20Def);

fn m20Expect(comptime ok: bool, comptime msg: []const u8) void {
    if (!ok) @compileError("M20: " ++ msg);
}

fn m20Spec(
    comptime name: String,
    comptime long: String,
    comptime short: ?String,
    comptime help: String,
) Spec {
    return .{
        .name = name,
        .kind = .flag,
        .vtype = bool,
        .long = long,
        .short = short,
        .required = false,
        .default = null,
        .default_env = null,
        .validation = null,
        .help = help,
        .i18n = null,
        .group = null,
    };
}

fn m20Level(
    comptime flags: []const Spec,
    comptime arguments: []const Spec,
    comptime commands: []const CommandEntry,
) Level {
    return .{
        .rank = 0,
        .path = "manual",
        .flags = flags,
        .arguments = arguments,
        .commands = commands,
    };
}

test "M20: entry building pairs and families" {
    comptime {
        const levels = model(M20).levels;
        const root = completionEntries(levels[0]);
        m20Expect(root.len == 6, "root entry count");

        const want = [_]String{ "--description", "--mode", "pick", "quiet", "--version", "--help" };
        for (want, root) |w, e| m20Expect(std.mem.eql(u8, w, e.spelling), "root entry order");

        m20Expect(root[0].alias != null and std.mem.eql(u8, root[0].alias.?, "-d"), "flag alias");
        m20Expect(root[1].alias == null, "lone long flag");
        m20Expect(root[2].alias != null and std.mem.eql(u8, root[2].alias.?, "p"), "command synonym");
        m20Expect(root[4].alias == null, "lone version");
        m20Expect(root[5].alias != null and std.mem.eql(u8, root[5].alias.?, "-h"), "builtin help alias");

        m20Expect(root[0].kind == .flag, "flag kind");
        m20Expect(root[2].kind == .command, "command kind");
        m20Expect(root[0].family == .normal, "normal family");
        m20Expect(root[4].family == .version, "version family");
        m20Expect(root[5].family == .help, "help family");

        m20Expect(std.mem.eql(u8, root[0].help, "Description."), "flag help");
        m20Expect(std.mem.eql(u8, root[2].help, "Pick."), "command help");
        m20Expect(root[3].help.len == 0, "empty command help");
        m20Expect(root[4].help.len == 0, "empty version help");
    }
}

test "M20: empty help sorts to the bottom of its family" {
    comptime {
        const levels = model(M20).levels;
        const rows = completionRows(levels[0]);

        const want = [_]String{ "--description", "--mode", "pick", "quiet", "--version", "--help" };
        for (want, rows) |w, r| m20Expect(std.mem.eql(u8, w, r.entry.spelling), "help-presence order");

        // The family tail always wins; inside a family, empty help sorts last.
        m20Expect(rows[3].entry.help.len == 0 and rows[3].entry.family == .normal, "empty normal row last in family");
        m20Expect(rows[4].entry.family == .version and rows[4].entry.help.len == 0, "version family");
        m20Expect(rows[5].entry.family == .help, "help stays last");
    }
}

test "M20: numeric keys follow family, help presence, spelling" {
    comptime {
        const levels = model(M20).levels;
        const rows = completionRows(levels[0]);
        m20Expect(rows[0].key_primary == 0 and rows[0].key_alias.? == 4, "description keys");
        m20Expect(rows[1].key_primary == 2, "mode key");
        m20Expect(rows[2].key_primary == 7 and rows[2].key_alias.? == 6, "pick keys");
        m20Expect(rows[3].key_primary == 17, "quiet key");
        m20Expect(rows[4].key_primary == 30, "version key");
        m20Expect(rows[5].key_primary == 37 and rows[5].key_alias.? == 41, "help keys");
        for (rows) |row| m20Expect(row.slot == -1, "non-argument slot");
    }
}

test "M20: argument entries are sorted, deduplicated values" {
    comptime {
        const levels = model(M20).levels;
        const pick = levels[1];
        m20Expect(pick.arguments.len == 1, "pick argument count");

        const values = completionArgumentEntries(pick, 0);
        m20Expect(values.len == 2, "value count");
        m20Expect(std.mem.eql(u8, values[0].spelling, "alpha"), "values sorted");
        m20Expect(std.mem.eql(u8, values[1].spelling, "beta"), "second value");
        m20Expect(values[0].kind == .argument, "argument kind");
        m20Expect(values[0].family == .normal, "argument family");
        m20Expect(values[0].alias == null, "argument alias");
        m20Expect(std.mem.eql(u8, values[0].help, "Alpha value."), "value help");
        m20Expect(std.mem.eql(u8, values[1].help, "Beta value."), "second value help");
        m20Expect(completionArgumentEntries(pick, 1).len == 0, "out of range slot");

        const Dup = struct {
            pub const EnumView = enum { a, b };
            pub const names = [_]String{ "b", "a", "b" };
        };
        const dup_args = [_]Spec{.{
            .name = "x",
            .kind = .argument,
            .vtype = Dup,
            .long = "",
            .short = null,
            .required = true,
            .default = null,
            .default_env = null,
            .validation = null,
            .help = "",
            .i18n = null,
            .group = null,
        }};
        const dup_level = m20Level(&.{}, &dup_args, &.{});
        const dup_values = completionArgumentEntries(dup_level, 0);
        m20Expect(dup_values.len == 2, "dedupe by spelling");
        m20Expect(std.mem.eql(u8, dup_values[0].spelling, "a"), "dedupe order");
        m20Expect(std.mem.eql(u8, dup_values[1].spelling, "b"), "dedupe second");
    }
}

test "M20: entries with the current slot" {
    comptime {
        const levels = model(M20).levels;
        const pick = levels[1];
        const with_slot = completionEntriesWithSlot(pick, 0);

        const want = [_]String{ "--description", "--mode", "--verbose", "alpha", "beta", "--version", "--help" };
        m20Expect(with_slot.len == want.len, "union size");
        for (want, with_slot) |w, e| m20Expect(std.mem.eql(u8, w, e.spelling), "union order");
        m20Expect(completionEntriesOfKind(with_slot, .argument).len == 2, "argument kind filter");
        m20Expect(completionEntriesOfKind(completionEntries(pick), .command).len == 0, "no commands");
        m20Expect(completionEntriesOfKind(completionEntries(levels[0]), .command).len == 2, "two commands");
    }
}

test "M20: bash spelling expansion sorts each spelling" {
    comptime {
        const levels = model(M20).levels;
        const root = completionEntries(levels[0]);

        const flags = completionSpellings(completionEntriesOfKind(root, .flag));
        const want_flags = [_]String{ "--description", "--mode", "-d", "--version", "--help", "-h" };
        m20Expect(flags.len == want_flags.len, "flag spelling count");
        for (want_flags, flags) |w, s| m20Expect(std.mem.eql(u8, w, s), "flag spelling order");

        const all = completionSpellings(root);
        const want_all = [_]String{ "--description", "--mode", "-d", "p", "pick", "quiet", "--version", "--help", "-h" };
        m20Expect(all.len == want_all.len, "all spelling count");
        for (want_all, all) |w, s| m20Expect(std.mem.eql(u8, w, s), "all spelling order");
    }
}

test "M20: value positions stay ASCII sorted and unpartitioned" {
    comptime {
        const values = enumCandidates(M20Kind, "");
        m20Expect(values.len == 2, "value count");
        m20Expect(std.mem.eql(u8, values[0].spelling, "alpha"), "value order");
        m20Expect(std.mem.eql(u8, values[1].spelling, "beta"), "value second");
        m20Expect(std.mem.eql(u8, values[0].help, "Alpha value."), "value help");
        m20Expect(std.mem.eql(u8, values[1].help, "Beta value."), "second value help");

        const inline_values = enumSpellings(M20Kind, "--kind=");
        m20Expect(std.mem.eql(u8, inline_values[0], "--kind=alpha"), "inline order");
        m20Expect(std.mem.eql(u8, inline_values[1], "--kind=beta"), "inline second");
    }
}

test "M20: value help reaches zsh and fish candidates" {
    const allocator = std.testing.allocator;

    const zsh = try M20.completion(allocator, "m20", .zsh).text();
    defer allocator.free(zsh);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--mode=beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "-- Beta value.") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "-- Alpha value.") != null);

    const fish = try M20.completion(allocator, "m20", .fish).text();
    defer allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "printf '%s\\t%s\\n' '--mode=beta' '-- Beta value.'",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "printf '%s\\t%s\\n' 'beta' '-- Beta value.'",
    ) != null);
}

test "M20: family classification uses the primary spelling" {
    comptime {
        const lone_help = [_]Spec{m20Spec("h", "", "h", "")};
        const lone_version = [_]Spec{m20Spec("v", "", "v", "")};
        const verbose = [_]Spec{m20Spec("verbose", "verbose", "v", "Verbose.")};
        const help_flag = [_]Spec{m20Spec("help", "help", null, "Help.")};
        const version_flag = [_]Spec{m20Spec("ver", "version", null, "")};

        const lone_help_entries = completionEntries(m20Level(&lone_help, &.{}, &.{}));
        m20Expect(lone_help_entries[0].family == .help, "lone -h is help");
        const lone_version_entries = completionEntries(m20Level(&lone_version, &.{}, &.{}));
        m20Expect(lone_version_entries[0].family == .version, "lone -v is version");
        const verbose_entries = completionEntries(m20Level(&verbose, &.{}, &.{}));
        m20Expect(verbose_entries[0].family == .normal, "--verbose with -v is normal");
        const help_entries = completionEntries(m20Level(&help_flag, &.{}, &.{}));
        m20Expect(help_entries[0].family == .help, "--help is help");
        const version_entries = completionEntries(m20Level(&version_flag, &.{}, &.{}));
        m20Expect(version_entries[0].family == .version, "--version is version");

        const HelpCmd = struct {
            pub const cmd_meta = CommandMeta{ .help = "Help." };
        };
        const cmds = [_]CommandEntry{.{
            .field = "help",
            .view_field = "_help",
            .name = "help",
            .synonym = null,
            .rank = 1,
            .Cmd = HelpCmd,
        }};
        const command_entries = completionEntries(m20Level(&.{}, &.{}, &cmds));
        m20Expect(command_entries[0].family == .help, "command named help");
    }
}

// ---------------------------------------------------------------------------
// M21: predictor declaration surface.
// ---------------------------------------------------------------------------

fn m21Callback(
    allocator: std.mem.Allocator,
    cur: []const u8,
    line: []const []const u8,
) anyerror![]const Completion.Suggestion {
    _ = allocator;
    _ = cur;
    _ = line;
    return &.{};
}

fn m21Expect(comptime ok: bool, comptime msg: []const u8) void {
    if (!ok) @compileError("M21 failed: " ++ msg);
}

fn m21Spec(comptime specs: []const Spec, comptime long: String) Spec {
    for (specs) |s| {
        if (s.kind == .flag and std.mem.eql(u8, s.long, long)) return s;
    }
    @compileError("no flag '--" ++ long ++ "'");
}

fn m21Argument(comptime specs: []const Spec, comptime name: String) Spec {
    for (specs) |s| {
        if (s.kind == .argument and std.mem.eql(u8, s.name, name)) return s;
    }
    @compileError("no argument '" ++ name ++ "'");
}

const M21Def = .{
    .bare = Flag(u8){},
    .plain = Flag([]const u8){ .completion = Completion.fs(.{}) },
    .optional = Optional(Flag(u8){ .completion = Completion.disabled() }),
    .defaulted = Flag(u16){
        .default = Default(u16){ .direct = 7 },
        .completion = Completion.call("echo 1"),
    },
    .server = Group(.{
        .host = Flag([]const u8){
            .completion = Completion.launch(.{ "getent", "hosts", "$cur" }),
        },
    }, "Server"),
    .mode = Alt(.{
        .one = .{
            .fast = Flag([]const u8){ .completion = Completion.custom(m21Callback) },
        },
        .two = .{
            .slow = Flag(u8){ .completion = Completion.launch(&[_][]const u8{ "seq", "10" }) },
        },
    }),
    .target = Argument([]const u8){ .completion = Completion.fs(.{ .type = .all }) },
};

const M21 = generate(App{ .name = "m21", .help = "M21." }, M21Def);

test "M21: predictor constructors" {
    const off = Completion.disabled();
    try std.testing.expect(off == .disabled);

    const files = Completion.fs(.{ .type = .dir, .root = "src", .wildcard = "*.zig" });
    try std.testing.expect(files == .fs);
    try std.testing.expectEqual(Completion.FsOptions.Type.dir, files.fs.type);
    try std.testing.expectEqualStrings("src", files.fs.root.?);
    try std.testing.expectEqualStrings("*.zig", files.fs.wildcard);

    const defaults = Completion.fs(.{});
    try std.testing.expectEqualStrings("*", defaults.fs.wildcard);
    try std.testing.expect(defaults.fs.type == .all);
    try std.testing.expect(defaults.fs.root == null);

    const tuple = Completion.launch(.{ "git", "status" });
    try std.testing.expect(tuple == .launch);
    try std.testing.expectEqual(@as(usize, 2), tuple.launch.len);
    try std.testing.expectEqualStrings("git", tuple.launch[0]);
    try std.testing.expectEqualStrings("status", tuple.launch[1]);

    const array_words = [_][]const u8{ "one", "$cur" };
    const array = Completion.launch(array_words);
    try std.testing.expectEqual(@as(usize, 2), array.launch.len);
    try std.testing.expectEqualStrings("$cur", array.launch[1]);

    const slice_words: []const []const u8 = &.{ "a", "b", "c" };
    const slice = Completion.launch(slice_words);
    try std.testing.expectEqual(@as(usize, 3), slice.launch.len);
    try std.testing.expectEqualStrings("c", slice.launch[2]);

    const cb = Completion.custom(m21Callback);
    try std.testing.expect(cb == .callback);
    try std.testing.expect(cb.callback == m21Callback);

    const expression = Completion.call("git branch --format='%(refname:short)'");
    try std.testing.expect(expression == .call);
    try std.testing.expectEqualStrings("git branch --format='%(refname:short)'", expression.call);

    try std.testing.expectEqualStrings(
        "---608b59fe-b7a9-407a-b0f5-77640a2c1957",
        Completion.route_marker,
    );
}

test "M21: predictors reach normalized specs" {
    comptime {
        const specs = M21.specs;

        const bare = m21Spec(specs, "bare");
        m21Expect(bare.completion == null, "undeclared predictor is null");

        const plain = m21Spec(specs, "plain");
        m21Expect(plain.completion != null, "plain has a predictor");
        m21Expect(plain.completion.? == .fs, "plain is fs");
        m21Expect(plain.completion.?.fs.type == .all, "plain fs default type");
        m21Expect(std.mem.eql(u8, plain.completion.?.fs.wildcard, "*"), "plain fs default wildcard");
        m21Expect(plain.required, "predictor does not change required");

        const optional = m21Spec(specs, "optional");
        m21Expect(optional.optional, "optional stays optional");
        m21Expect(!optional.required, "optional stays not required");
        m21Expect(optional.completion.? == .disabled, "optional disabled");

        const defaulted = m21Spec(specs, "defaulted");
        m21Expect(!defaulted.required, "defaulted stays not required");
        m21Expect(defaulted.completion.? == .call, "defaulted call");
        m21Expect(std.mem.eql(u8, defaulted.completion.?.call, "echo 1"), "call expression");

        const host = m21Spec(specs, "host");
        m21Expect(std.mem.eql(u8, host.group.?, "Server"), "group member keeps its group");
        m21Expect(host.completion.? == .launch, "group member launch");
        m21Expect(host.completion.?.launch.len == 3, "group launch word count");
        m21Expect(std.mem.eql(u8, host.completion.?.launch[2], "$cur"), "group launch cur");

        const fast = m21Spec(specs, "fast");
        m21Expect(std.mem.eql(u8, fast.alt.?, "mode"), "alt member keeps its owner");
        m21Expect(fast.completion.? == .callback, "alt callback");

        const slow = m21Spec(specs, "slow");
        m21Expect(slow.completion.? == .launch, "alt launch");
        m21Expect(slow.completion.?.launch.len == 2, "alt array launch word count");

        const target = m21Argument(specs, "target");
        m21Expect(target.completion.? == .fs, "argument fs");
        m21Expect(target.completion.?.fs.type == .all, "argument fs type");
    }
}

// M21 negative cases. Zig has no compile-fail harness; flip the body of the
// relevant test to exercise a @compileError, then restore.
test "M21: a disabled predictor on a bool flag is a compile error" {
    if (false) {
        const Bad = generate(App{ .name = "bad", .help = "" }, .{
            .flag = Flag(bool){ .completion = Completion.disabled() },
        });
        comptime _ = Bad;
    }
}

test "M21: a predictor on an enumeration flag is a compile error" {
    if (false) {
        const Mode = Enumeration(.{ .fast = Enum{}, .slow = Enum{} });
        const Bad = generate(App{ .name = "bad", .help = "" }, .{
            .mode = Flag(Mode){ .completion = Completion.fs(.{}) },
        });
        comptime _ = Bad;
    }
}

test "M21: a disabled predictor on an enumeration flag is a compile error" {
    if (false) {
        const Mode = Enumeration(.{ .fast = Enum{}, .slow = Enum{} });
        const Bad = generate(App{ .name = "bad", .help = "" }, .{
            .mode = Flag(Mode){ .completion = Completion.disabled() },
        });
        comptime _ = Bad;
    }
}

test "M21: a predictor on an empty enumeration is a compile error" {
    if (false) {
        const Empty = Enumeration(.{});
        const Bad = generate(App{ .name = "bad", .help = "" }, .{
            .mode = Flag(Empty){ .completion = Completion.disabled() },
        });
        comptime _ = Bad;
    }
}
// ---------------------------------------------------------------------------
// M22: completion model and bindings.
// ---------------------------------------------------------------------------

const M22RootDef = .{
    .root_cb = Flag([]const u8){ .long = "root-cb", .completion = Completion.custom(m21Callback) },
    .root_plain = Flag(u8){ .long = "root-plain" },
    .root_native = Flag([]const u8){ .long = "root-native", .completion = Completion.fs(.{}) },
    .root_bin = Flag([]const u8){ .long = "root-bin", .completion = Completion.fs(.{ .root = "src" }) },
    .root_wild = Flag([]const u8){ .long = "root-wild", .completion = Completion.fs(.{ .wildcard = "*.zig" }) },
    .root_off = Flag([]const u8){ .long = "root-off", .completion = Completion.disabled() },
    .root_launch = Flag([]const u8){ .long = "root-launch", .completion = Completion.launch(.{ "echo", "$cur" }) },
    .root_call = Flag([]const u8){ .long = "root-call", .completion = Completion.call("echo hi") },
    .sub = Command(.{ .help = "Sub." }, .{
        .sub_cb = Flag([]const u8){ .long = "sub-cb", .completion = Completion.custom(m21Callback) },
        .sub_native = Flag([]const u8){ .long = "sub-native", .completion = Completion.fs(.{ .type = .dir }) },
        .sub_off = Flag([]const u8){ .long = "sub-off", .completion = Completion.disabled() },
    }),
};

const M22Root = generate(App{ .name = "m22", .help = "M22." }, M22RootDef);

const M22ArgsDef = .{
    .pick = Argument([]const u8){ .completion = Completion.fs(.{ .wildcard = "*.zig" }) },
    .tail = Argument(u8){},
};

const M22Args = generate(App{ .name = "m22-args", .help = "M22 args." }, M22ArgsDef);

fn m22Expect(comptime ok: bool, comptime msg: []const u8) void {
    if (!ok) @compileError("M22 failed: " ++ msg);
}

fn m22FlagIndex(comptime level: Level, comptime long: String) usize {
    for (level.flags, 0..) |s, i| {
        if (std.mem.eql(u8, s.long, long)) return i;
    }
    @compileError("M22: no flag '--" ++ long ++ "'");
}

fn m22FlagBinding(comptime level: Level, comptime long: String) ?usize {
    return level.flag_bindings[m22FlagIndex(level, long)];
}

test "M22: bindings are dense, pre-order, and stable" {
    comptime {
        const m = model(M22Root);
        m22Expect(m.levels.len == 2, "level count");
        m22Expect(m.bindings.len == 4, "binding count");

        m22Expect(m.bindings[0] == .callback, "root callback first");
        m22Expect(m.bindings[1] == .fs, "root fs second");
        m22Expect(std.mem.eql(u8, m.bindings[1].fs.root.?, "src"), "fs root");
        m22Expect(m.bindings[1].fs.type == .all, "fs type");
        m22Expect(m.bindings[2] == .fs, "root wildcard third");
        m22Expect(std.mem.eql(u8, m.bindings[2].fs.wildcard, "*.zig"), "wildcard");
        m22Expect(m.bindings[3] == .callback, "child callback fourth");

        var seen: []const usize = &.{};
        for (m.levels) |level| {
            for (level.flag_bindings) |maybe| {
                if (maybe) |idx| {
                    var known = false;
                    for (seen) |prev| {
                        if (prev == idx) {
                            known = true;
                            break;
                        }
                    }
                    if (!known) seen = seen ++ &[_]usize{idx};
                }
            }
            for (level.argument_bindings) |maybe| {
                if (maybe) |idx| {
                    var known = false;
                    for (seen) |prev| {
                        if (prev == idx) {
                            known = true;
                            break;
                        }
                    }
                    if (!known) seen = seen ++ &[_]usize{idx};
                }
            }
        }
        m22Expect(seen.len == m.bindings.len, "every binding is reachable");
        for (seen, 0..) |idx, k| m22Expect(idx == k, "dense first-seen order");

        const twice = model(M22Root);
        m22Expect(twice.bindings.len == m.bindings.len, "stable binding count");
        for (m.bindings, twice.bindings) |a, b| {
            m22Expect(std.meta.activeTag(a) == std.meta.activeTag(b), "stable branch");
            switch (a) {
                .callback => |cb| m22Expect(cb == b.callback, "stable callback"),
                .fs => |opts| {
                    m22Expect(std.mem.eql(u8, opts.wildcard, b.fs.wildcard), "stable wildcard");
                    m22Expect(opts.type == b.fs.type, "stable fs type");
                    if (opts.root) |root| {
                        m22Expect(std.mem.eql(u8, root, b.fs.root.?), "stable fs root");
                    } else {
                        m22Expect(b.fs.root == null, "stable null fs root");
                    }
                },
            }
        }
    }
}

test "M22: only route-backed targets create bindings" {
    comptime {
        const m = model(M22Root);
        const root = m.levels[0];
        const sub = m.levels[1];

        m22Expect(root.flag_bindings.len == root.flags.len, "root flag alignment");
        m22Expect(root.argument_bindings.len == root.arguments.len, "root argument alignment");
        m22Expect(root.arguments.len == 0, "root has no arguments");

        m22Expect(m22FlagBinding(root, "root-cb").? == 0, "callback via custom");
        m22Expect(m22FlagBinding(root, "root-bin").? == 1, "non-native fs via root");
        m22Expect(m22FlagBinding(root, "root-wild").? == 2, "non-native fs via wildcard");
        m22Expect(m22FlagBinding(root, "help") == null, "injected help has no binding");
        m22Expect(m22FlagBinding(root, "root-plain") == null, "null predictor");
        m22Expect(m22FlagBinding(root, "root-native") == null, "native fs");
        m22Expect(m22FlagBinding(root, "root-off") == null, "disabled");
        m22Expect(m22FlagBinding(root, "root-launch") == null, "launch");
        m22Expect(m22FlagBinding(root, "root-call") == null, "call");

        m22Expect(m.bindings.len == 4, "three root bindings plus one child binding");
        m22Expect(m22FlagBinding(sub, "sub-cb").? == 3, "child callback follows ancestors");
        m22Expect(m22FlagBinding(sub, "sub-native") == null, "native .dir fs");
        m22Expect(m22FlagBinding(sub, "sub-off") == null, "child disabled");

        for (root.flag_bindings, sub.flag_bindings[0..root.flag_bindings.len]) |want, got| {
            m22Expect(want == got, "inherited flag reuses the ancestor index");
        }
    }
}

test "M22: argument bindings align with arguments" {
    comptime {
        const m = model(M22Args);
        m22Expect(m.levels.len == 1, "argument fixture level count");
        m22Expect(m.bindings.len == 1, "argument fixture binding count");
        m22Expect(m.bindings[0] == .fs, "argument fs binding");
        m22Expect(std.mem.eql(u8, m.bindings[0].fs.wildcard, "*.zig"), "argument wildcard");

        const level = m.levels[0];
        m22Expect(level.argument_bindings.len == level.arguments.len, "argument alignment");
        m22Expect(level.argument_bindings[0].? == 0, "predictor argument is bound");
        m22Expect(level.argument_bindings[1] == null, "plain argument is unbound");
    }
}

test "M22: model keeps the existing level layout" {
    comptime {
        const m = model(M19);
        m22Expect(m.bindings.len == 0, "M19 declares no predictors");
        m22Expect(m.levels.len == 3, "M19 level count");
        for (m.levels, 0..) |level, i| m22Expect(level.rank == i, "pre-order ranks");
        m22Expect(std.mem.eql(u8, m.levels[2].path, "m19 run go"), "usage path");
        m22Expect(m.levels[0].flags.len == 3, "root effective flags");
        m22Expect(m.levels[2].arguments.len == 1, "leaf argument");
        m22Expect(m.levels[0].commands.len == 1, "root command");
    }
}

// ---------------------------------------------------------------------------
// M23: route and callback ownership.
// ---------------------------------------------------------------------------

var m23_calls: usize = 0;
var m23_cur: []const u8 = "";
var m23_line: []const []const u8 = &.{};

fn m23Capture(
    allocator: std.mem.Allocator,
    cur: []const u8,
    line: []const []const u8,
) anyerror![]const Completion.Suggestion {
    _ = allocator;
    m23_calls += 1;
    m23_cur = cur;
    m23_line = line;
    return &.{};
}

fn m23Owned(
    allocator: std.mem.Allocator,
    cur: []const u8,
    line: []const []const u8,
) anyerror![]const Completion.Suggestion {
    _ = cur;
    _ = line;
    const items = try allocator.alloc(Completion.Suggestion, 2);
    errdefer allocator.free(items);
    items[0] = .{ .value = try allocator.dupe(u8, "alpha") };
    errdefer allocator.free(items[0].value);
    items[0].help = try allocator.dupe(u8, "first");
    errdefer allocator.free(items[0].help.?);
    items[1] = .{ .value = try allocator.dupe(u8, "beta") };
    errdefer allocator.free(items[1].value);
    items[1].help = try allocator.dupe(u8, "second");
    return items;
}

fn m23Fail(
    allocator: std.mem.Allocator,
    cur: []const u8,
    line: []const []const u8,
) anyerror![]const Completion.Suggestion {
    _ = allocator;
    _ = cur;
    _ = line;
    return error.PredictorFailed;
}

const M23RootDef = .{
    .cb = Flag([]const u8){ .long = "cb", .completion = Completion.custom(m23Capture) },
    .owned = Flag([]const u8){ .long = "owned", .completion = Completion.custom(m23Owned) },
    .fail = Flag([]const u8){ .long = "fail", .completion = Completion.custom(m23Fail) },
    .off = Flag([]const u8){ .long = "off", .completion = Completion.disabled() },
    .sub = Command(.{ .help = "Sub." }, .{
        .sub_cb = Flag([]const u8){ .long = "sub-cb", .completion = Completion.custom(m23Capture) },
    }),
};

const M23 = generate(App{ .name = "m23", .help = "M23." }, M23RootDef);

test "M23: route marker matches the design" {
    try std.testing.expectEqualStrings(
        "---608b59fe-b7a9-407a-b0f5-77640a2c1957",
        Completion.route_marker,
    );
}

test "M23: route rejects misuse" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const marker = Completion.route_marker;
    try std.testing.expectError(error.RouteMisuse, routeSuggestions(M23, io, allocator, &.{}));
    try std.testing.expectError(error.RouteMisuse, routeSuggestions(M23, io, allocator, &.{marker}));
    try std.testing.expectError(error.RouteMisuse, routeSuggestions(M23, io, allocator, &.{ marker, "0", "" }));
    try std.testing.expectError(
        error.RouteMisuse,
        routeSuggestions(M23, io, allocator, &.{ "not-the-marker", "0", "", "app" }),
    );
    try std.testing.expectError(
        error.RouteMisuse,
        routeSuggestions(M23, io, allocator, &.{ marker, "zero", "", "app" }),
    );
    try std.testing.expectError(
        error.RouteMisuse,
        routeSuggestions(M23, io, allocator, &.{ marker, "-1", "", "app" }),
    );
    try std.testing.expectError(
        error.RouteMisuse,
        routeSuggestions(M23, io, allocator, &.{ marker, "4", "", "app" }),
    );
}

test "M23: callback receives cur and the parsed line" {
    m23_calls = 0;
    m23_cur = "";
    m23_line = &.{};
    const args = [_][]const u8{ Completion.route_marker, "0", "pre", "app", "sub" };
    const result = try routeSuggestions(M23, std.testing.io, std.testing.allocator, &args);
    defer freeSuggestions(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 1), m23_calls);
    try std.testing.expectEqualStrings("pre", m23_cur);
    try std.testing.expectEqual(@as(usize, 2), m23_line.len);
    try std.testing.expectEqualStrings("app", m23_line[0]);
    try std.testing.expectEqualStrings("sub", m23_line[1]);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "M23: child bindings resolve at the shared index" {
    m23_calls = 0;
    const args = [_][]const u8{ Completion.route_marker, "3", "", "app", "sub" };
    const result = try routeSuggestions(M23, std.testing.io, std.testing.allocator, &args);
    freeSuggestions(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 1), m23_calls);
}

test "M23: callback errors propagate" {
    try std.testing.expectError(
        error.PredictorFailed,
        routeSuggestions(M23, std.testing.io, std.testing.allocator, &.{ Completion.route_marker, "2", "", "app" }),
    );
}

test "M23: callback results are owned by the route" {
    const result = try routeSuggestions(
        M23,
        std.testing.io,
        std.testing.allocator,
        &.{ Completion.route_marker, "1", "", "app" },
    );
    defer freeSuggestions(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("alpha", result[0].value);
    try std.testing.expectEqualStrings("first", result[0].help.?);
    try std.testing.expectEqualStrings("beta", result[1].value);
    try std.testing.expectEqualStrings("second", result[1].help.?);
}

test "M23: render suggestions" {
    const allocator = std.testing.allocator;
    const rows = [_]Completion.Suggestion{
        .{ .value = "plain" },
        .{ .value = "with_help", .help = "first\tsecond\nthird\rfourth" },
        .{ .value = "bad\tvalue", .help = "skipped" },
        .{ .value = "bad\nvalue" },
        .{ .value = "bad\rvalue" },
        .{ .value = "empty_help", .help = "" },
    };
    const text = try renderSuggestions(allocator, &rows);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        "plain\nwith_help\tfirst second third fourth\nempty_help\n",
        text,
    );

    const again = try renderSuggestions(allocator, &rows);
    defer allocator.free(again);
    try std.testing.expectEqualStrings(text, again);

    const none = try renderSuggestions(allocator, &.{});
    defer allocator.free(none);
    try std.testing.expectEqualStrings("", none);
}

// ---------------------------------------------------------------------------
// M24: binary fs predictor.
// ---------------------------------------------------------------------------

const M24NativeDef = .{
    .native = Flag([]const u8){ .long = "native", .completion = Completion.fs(.{}) },
    .natives = Flag([]const u8){ .long = "natives", .completion = Completion.fs(.{ .type = .dir }) },
    .custom = Flag([]const u8){ .long = "custom", .completion = Completion.fs(.{ .root = "data" }) },
    .plain = Flag([]const u8){ .long = "plain" },
};

const M24Native = generate(App{ .name = "m24native", .help = "M24 native." }, M24NativeDef);

const M24FsDef = .{
    .files = Flag([]const u8){
        .long = "files",
        .completion = Completion.fs(.{ .root = "m24-no-such-root", .wildcard = "*.txt" }),
    },
};

const M24Fs = generate(App{ .name = "m24fs", .help = "M24 fs." }, M24FsDef);

/// Process-cwd relative path of a testing tmp dir, matching the path the
/// binary filesystem predictor opens.
fn m24Root(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(allocator, &.{ std.testing.TmpDir.parent_dir_path, tmp.sub_path[0..] });
}

fn m24ExpectValues(
    allocator: std.mem.Allocator,
    opts: Completion.FsOptions,
    cur: []const u8,
    expected: []const []const u8,
) !void {
    const result = try fsSuggestions(std.testing.io, allocator, opts, cur);
    defer freeSuggestions(allocator, result);
    try std.testing.expectEqual(expected.len, result.len);
    for (expected, result) |want, got| {
        try std.testing.expectEqualStrings(want, got.value);
        try std.testing.expect(got.help == null);
    }
}

test "M24: wildcard matching" {
    try std.testing.expect(fsWildcardMatch("alpha.txt", "*.txt"));
    try std.testing.expect(fsWildcardMatch("alpha.txt", "a?pha.txt"));
    try std.testing.expect(fsWildcardMatch("alpha.txt", "a*a.txt"));
    try std.testing.expect(fsWildcardMatch("alpha.txt", "*"));
    try std.testing.expect(fsWildcardMatch("alpha.txt", "alpha.txt"));
    try std.testing.expect(!fsWildcardMatch("alpha.txt", "*.md"));
    try std.testing.expect(!fsWildcardMatch("alpha.txt", "a?pha"));
    try std.testing.expect(!fsWildcardMatch("alpha.txt", "?alpha.txt"));
}

test "M24: files, directories, and wildcards" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gamma.md", .data = "" });
    try tmp.dir.createDirPath(io, "dir_one");
    try tmp.dir.createDirPath(io, "dir_two");
    const root = try m24Root(allocator, &tmp);
    defer allocator.free(root);

    try m24ExpectValues(allocator, .{ .root = root, .wildcard = "*.txt" }, "", &.{
        "alpha.txt",
        "beta.txt",
        "dir_one/",
        "dir_two/",
    });
    try m24ExpectValues(allocator, .{ .root = root, .wildcard = "*", .type = .dir }, "", &.{
        "dir_one/",
        "dir_two/",
    });
    try m24ExpectValues(allocator, .{ .root = root, .wildcard = "dir_t*", .type = .dir }, "", &.{
        "dir_two/",
    });
    try m24ExpectValues(allocator, .{ .root = root, .wildcard = "*.md" }, "", &.{
        "dir_one/",
        "dir_two/",
        "gamma.md",
    });
    try m24ExpectValues(allocator, .{ .root = root, .wildcard = "*.txt" }, "al", &.{
        "alpha.txt",
    });
}

test "M24: dot entries are gated on the base prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    try tmp.dir.createDirPath(io, ".hdir");
    const root = try m24Root(allocator, &tmp);
    defer allocator.free(root);

    try m24ExpectValues(allocator, .{ .root = root }, "", &.{});
    try m24ExpectValues(allocator, .{ .root = root }, ".h", &.{
        ".hdir/",
        ".hidden",
    });
}

test "M24: dir_part prefixes every value and descends" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/inner.txt", .data = "" });
    try tmp.dir.createDirPath(io, "sub/innerdir");
    const root = try m24Root(allocator, &tmp);
    defer allocator.free(root);

    try m24ExpectValues(allocator, .{ .root = root }, "sub/", &.{
        "sub/inner.txt",
        "sub/innerdir/",
    });
    try m24ExpectValues(allocator, .{ .root = root }, "sub/in", &.{
        "sub/inner.txt",
        "sub/innerdir/",
    });
}

test "M24: missing and unreadable directories yield nothing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "plain", .data = "" });
    const root = try m24Root(allocator, &tmp);
    defer allocator.free(root);

    try m24ExpectValues(allocator, .{ .root = "m24-missing-root-xyz" }, "", &.{});
    try m24ExpectValues(allocator, .{ .root = root }, "plain/", &.{});
}

test "M24: symlinks are classified by their target and keep their link name" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "" });
    try tmp.dir.symLink(io, "target.txt", "alias.txt", .{});
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });
    const root = try m24Root(allocator, &tmp);
    defer allocator.free(root);

    try m24ExpectValues(allocator, .{ .root = root, .type = .dir }, "", &.{
        "link/",
        "real/",
    });
    try m24ExpectValues(allocator, .{ .root = root, .wildcard = "*.txt" }, "", &.{
        "alias.txt",
        "link/",
        "real/",
        "target.txt",
    });
}

test "M24: results are byte-sorted and unique" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c", .data = "" });
    const root = try m24Root(allocator, &tmp);
    defer allocator.free(root);

    try m24ExpectValues(allocator, .{ .root = root }, "", &.{ "a", "b", "c" });
}

test "M24: route resolves a non-native fs binding" {
    const result = try routeSuggestions(
        M24Fs,
        std.testing.io,
        std.testing.allocator,
        &.{ Completion.route_marker, "0", "", "app" },
    );
    defer freeSuggestions(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "M24: native fs arms render shell path completion" {
    const allocator = std.testing.allocator;

    const bash_handle = M24Native.completion(allocator, "m24native", .bash);
    const bash = try bash_handle.text();
    defer allocator.free(bash);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bash, "compopt -o filenames\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bash, "compgen -f -- \"$cur\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bash, "compgen -d -- \"$cur\""));

    const zsh_handle = M24Native.completion(allocator, "m24native", .zsh);
    const zsh = try zsh_handle.text();
    defer allocator.free(zsh);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, zsh, "            _files\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, zsh, "            _files -/\n"));

    const fish_handle = M24Native.completion(allocator, "m24native", .fish);
    const fish = try fish_handle.text();
    defer allocator.free(fish);
    // One native `.all` arm plus the plain null target, which keeps the
    // shell's file fallback through the helper now that `-f` is registered.
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, fish, "                __fish_complete_path\n"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, fish, "                __fish_complete_directories\n"),
    );
}

// ---------------------------------------------------------------------------
// M25: launch and call emission.
// ---------------------------------------------------------------------------

/// Render one inline arm body for `shell` into an owned string.
fn m25Snippet(
    allocator: std.mem.Allocator,
    shell: Completion.Shell,
    predictor: Completion.Predictor,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const emitted = switch (shell) {
        .bash => try appendBashInline(&out, allocator, "    ", predictor, "$cur", ""),
        .zsh => try appendZshInline(&out, allocator, "    ", predictor, "$PREFIX", ""),
        .fish => try appendFishInline(&out, allocator, "    ", predictor, "$cur", "", &.{}),
    };
    try std.testing.expect(emitted);
    return try out.toOwnedSlice(allocator);
}

/// Assert an inline arm carries no shell fallback of any kind.
fn m25ExpectNoFallback(snippet: String) !void {
    const fallbacks = [_]String{
        "_files",
        "compgen",
        "__fish_complete_path",
        "__fish_complete_directories",
    };
    for (fallbacks) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, snippet, needle) == null);
    }
}

test "M25: launch words are shell words and expand $cur" {
    const allocator = std.testing.allocator;
    const words = [_][]const u8{ "getent", "hosts", "$cur", "two words", "can't" };
    const predictor = Completion.Predictor{ .launch = &words };

    const bash = try m25Snippet(allocator, .bash, predictor);
    defer allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "if out=$('getent' 'hosts' \"$cur\" 'two words' 'can'\\''t'); then",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "'$cur'") == null);

    const zsh = try m25Snippet(allocator, .zsh, predictor);
    defer allocator.free(zsh);
    try std.testing.expect(std.mem.indexOf(
        u8,
        zsh,
        "if out=$('getent' 'hosts' \"$cur\" 'two words' 'can'\\''t'); then",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "'$cur'") == null);

    const fish = try m25Snippet(allocator, .fish, predictor);
    defer allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "set -l out ('getent' 'hosts' \"$cur\" 'two words' 'can\\'t')",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "'$cur'") == null);
}

test "M25: launch keeps an empty $cur word" {
    const allocator = std.testing.allocator;
    const words = [_][]const u8{ "", "$cur" };
    const predictor = Completion.Predictor{ .launch = &words };

    const bash = try m25Snippet(allocator, .bash, predictor);
    defer allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "if out=$('' \"$cur\"); then") != null);

    const fish = try m25Snippet(allocator, .fish, predictor);
    defer allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(u8, fish, "set -l out ('' \"$cur\")") != null);
}

test "M25: launch never appends cur implicitly" {
    const allocator = std.testing.allocator;
    const words = [_][]const u8{ "git", "branch" };
    const predictor = Completion.Predictor{ .launch = &words };

    const bash = try m25Snippet(allocator, .bash, predictor);
    defer allocator.free(bash);
    const bash_end = std.mem.indexOf(u8, bash, "); then").?;
    try std.testing.expect(std.mem.indexOf(u8, bash, "if out=$('git' 'branch'); then") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash[0..bash_end], "$cur") == null);

    const zsh = try m25Snippet(allocator, .zsh, predictor);
    defer allocator.free(zsh);
    const zsh_end = std.mem.indexOf(u8, zsh, "); then").?;
    try std.testing.expect(std.mem.indexOf(u8, zsh, "if out=$('git' 'branch'); then") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh[0..zsh_end], "$cur") == null);

    const fish = try m25Snippet(allocator, .fish, predictor);
    defer allocator.free(fish);
    const fish_end = std.mem.indexOf(u8, fish, ")\n").?;
    try std.testing.expect(std.mem.indexOf(u8, fish, "set -l out ('git' 'branch')") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish[0..fish_end], "$cur") == null);
}

test "M25: inline output splits value from help and filters by cur" {
    const allocator = std.testing.allocator;
    const predictor = Completion.Predictor{ .launch = &[_][]const u8{"catalog"} };

    const bash = try m25Snippet(allocator, .bash, predictor);
    defer allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "cand=${cand%%$'\\t'*}") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "[[ -n $cand && $cand == \"$cur\"* ]] && COMPREPLY+=(\"$cand\")",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "while IFS= read -r cand; do") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "done <<< \"$out\"") != null);

    const zsh = try m25Snippet(allocator, .zsh, predictor);
    defer allocator.free(zsh);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "help=${cand#*$'\\t'}") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "cand=${cand%%$'\\t'*}") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        zsh,
        "compadd -U -o nosort -V '' -l -d displays -- \"${cands[@]}\"",
    ) != null);

    const fish = try m25Snippet(allocator, .fish, predictor);
    defer allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(u8, fish, "string split -m 1 \\t -- $cand") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "printf '%s\\t%s\\n' $val $desc") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "printf '%s\\n' $val") != null);
}

test "M25: inline failures and empty output emit nothing" {
    const allocator = std.testing.allocator;
    const predictor = Completion.Predictor{ .launch = &[_][]const u8{"catalog"} };

    const bash = try m25Snippet(allocator, .bash, predictor);
    defer allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "if out=$(") != null);
    try m25ExpectNoFallback(bash);

    const zsh = try m25Snippet(allocator, .zsh, predictor);
    defer allocator.free(zsh);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "if out=$(") != null);
    try m25ExpectNoFallback(zsh);

    const fish = try m25Snippet(allocator, .fish, predictor);
    defer allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(u8, fish, "if test $status -eq 0") != null);
    try m25ExpectNoFallback(fish);
}

test "M25: call expressions see cur and line" {
    const allocator = std.testing.allocator;
    const source = "printf '%s\\n' \"$cur\" \"${line[0]}\"";
    const predictor = Completion.Predictor{ .call = source };

    const bash_invocation = try std.fmt.allocPrint(allocator, "if out=$({s}); then", .{source});
    defer allocator.free(bash_invocation);
    const bash = try m25Snippet(allocator, .bash, predictor);
    defer allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "local -a line=(\"${COMP_WORDS[@]:0:$COMP_CWORD}\")\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, bash_invocation) != null);

    const zsh_invocation = try std.fmt.allocPrint(allocator, "if out=$({s}); then", .{source});
    defer allocator.free(zsh_invocation);
    const zsh = try m25Snippet(allocator, .zsh, predictor);
    defer allocator.free(zsh);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "local cur=$PREFIX\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        zsh,
        "local -a line=( \"${words[@]:0:$((CURRENT - 1))}\" )\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, zsh_invocation) != null);

    const fish_invocation = try std.fmt.allocPrint(allocator, "set -l out ({s})", .{source});
    defer allocator.free(fish_invocation);
    const fish = try m25Snippet(allocator, .fish, predictor);
    defer allocator.free(fish);
    try std.testing.expect(std.mem.indexOf(u8, fish, "set -l line (commandline -opc)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, fish_invocation) != null);
}

test "M25: launch and call arms carry no route marker or index" {
    const allocator = std.testing.allocator;
    const predictors = [_]Completion.Predictor{
        .{ .launch = &[_][]const u8{"catalog"} },
        .{ .call = "printf x" },
    };
    for (predictors) |predictor| {
        inline for ([_]Completion.Shell{ .bash, .zsh, .fish }) |shell| {
            const snippet = try m25Snippet(allocator, shell, predictor);
            defer allocator.free(snippet);
            try std.testing.expect(
                std.mem.indexOf(u8, snippet, Completion.route_marker) == null,
            );
            try std.testing.expect(std.mem.indexOf(u8, snippet, "_dynamic") == null);
        }
    }
}

test "M25: only launch and call render inline" {
    const ignored = [_]Completion.Predictor{
        Completion.disabled(),
        Completion.fs(.{}),
        Completion.custom(m21Callback),
    };
    for (ignored) |predictor| {
        inline for ([_]Completion.Shell{ .bash, .zsh, .fish }) |shell| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(std.testing.allocator);
            const emitted = switch (shell) {
                .bash => try appendBashInline(&out, std.testing.allocator, "", predictor, "$cur", ""),
                .zsh => try appendZshInline(&out, std.testing.allocator, "", predictor, "$PREFIX", ""),
                .fish => try appendFishInline(&out, std.testing.allocator, "", predictor, "$cur", "", &.{}),
            };
            try std.testing.expect(!emitted);
            try std.testing.expectEqual(@as(usize, 0), out.items.len);
        }
    }
}
// ---------------------------------------------------------------------------
// M26: dynamic emission integration.
// ---------------------------------------------------------------------------

fn m26Callback(
    allocator: std.mem.Allocator,
    cur: []const u8,
    line: []const []const u8,
) anyerror![]const Completion.Suggestion {
    _ = cur;
    _ = line;
    const items = try allocator.alloc(Completion.Suggestion, 2);
    errdefer allocator.free(items);
    items[0] = .{ .value = try allocator.dupe(u8, "alpha") };
    errdefer allocator.free(items[0].value);
    items[0].help = try allocator.dupe(u8, "first");
    errdefer allocator.free(items[0].help.?);
    items[1] = .{ .value = try allocator.dupe(u8, "beta") };
    errdefer allocator.free(items[1].value);
    return items;
}

const M26Def = .{
    .cb = Flag([]const u8){ .long = "cb", .completion = Completion.custom(m26Callback) },
    .files = Flag([]const u8){
        .long = "files",
        .completion = Completion.fs(.{ .root = "data", .wildcard = "*.txt" }),
    },
    .native = Flag([]const u8){ .long = "native", .completion = Completion.fs(.{}) },
    .dirs = Flag([]const u8){ .long = "dirs", .completion = Completion.fs(.{ .type = .dir }) },
    .off = Flag([]const u8){ .long = "off", .completion = Completion.disabled() },
    .launch = Flag([]const u8){
        .long = "launch",
        .completion = Completion.launch(.{ "catalog", "$cur" }),
    },
    .call = Flag([]const u8){
        .long = "call",
        .completion = Completion.call("printf '%s\\n' \"$cur\""),
    },
    .plain = Flag([]const u8){ .long = "plain" },
    .pick = Command(.{ .help = "Pick." }, .{
        .item = Argument([]const u8){ .completion = Completion.custom(m26Callback) },
        .where = Argument([]const u8){ .completion = Completion.fs(.{ .wildcard = "*.zig" }) },
    }),
};

const M26 = generate(App{ .name = "m26", .help = "M26." }, M26Def);

fn m26Script(allocator: std.mem.Allocator, shell: Completion.Shell) !String {
    return M26.completion(allocator, "m26", shell).text();
}

test "M26: route-backed flags carry their aligned indices" {
    const allocator = std.testing.allocator;
    const bash = try m26Script(allocator, .bash);
    defer allocator.free(bash);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "        '--cb')\n            compopt +o default\n            _dap_m26_dynamic 0 \"$vprefix\" \"$vpart\"\n            return\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "        '--files')\n            compopt +o default\n            _dap_m26_dynamic 1 \"$vprefix\" \"$vpart\"\n            return\n",
    ) != null);
    // The `--flag=value` form strips and re-attaches the prefix.
    try std.testing.expect(std.mem.indexOf(u8, bash, "        full) vprefix=${cur%%=*}=; vpart=${cur#*=} ;;\n") != null);
}

test "M26: bash fallback rules per target" {
    const allocator = std.testing.allocator;
    const bash = try m26Script(allocator, .bash);
    defer allocator.free(bash);

    // Disabled suppresses the default fallback and offers nothing.
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "        '--off')\n            compopt +o default\n            return\n            ;;\n",
    ) != null);
    // Native filesystem arms keep the fallback and quote filenames.
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "        '--native')\n            compopt -o filenames\n            local IFS=$'\\n'\n            COMPREPLY=($(compgen -f -- \"$cur\"))\n            return\n",
    ) != null);
    // A null target leaves the default fallback untouched.
    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "        '--plain')\n            return\n            ;;\n",
    ) != null);
    // `complete -o default` stays on the registration.
    try std.testing.expect(std.mem.endsWith(u8, bash, "complete -o default -F _dap_m26 'm26'\n"));
}

test "M26: bash positional predictors invoke on an empty word and append later" {
    const allocator = std.testing.allocator;
    const bash = try m26Script(allocator, .bash);
    defer allocator.free(bash);

    try std.testing.expect(std.mem.indexOf(
        u8,
        bash,
        "            0)\n                compopt +o default\n                _dap_m26_dynamic 2 \"\" \"\"\n                ;;\n",
    ) != null);
    const prefix_arm =
        "            0)\n" ++
        "                compopt +o default\n" ++
        "                _dap_m26_filter \"$cur\" '--call' '--cb' '--dirs' '--files' '--launch' " ++
        "'--native' '--off' '--plain' '--help' '-h'\n" ++
        "                _dap_m26_dynamic 2 \"\" \"$cur\"\n" ++
        "                ;;\n";
    try std.testing.expect(std.mem.indexOf(u8, bash, prefix_arm) != null);
}

test "M26: zsh explicit predictors never fall back to files" {
    const allocator = std.testing.allocator;
    const zsh = try m26Script(allocator, .zsh);
    defer allocator.free(zsh);

    try std.testing.expect(std.mem.indexOf(u8, zsh, "_m26_dynamic() {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "seen=()\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "seen+=(\"${sel_spell[i]}\")\n") != null);

    const cb_arm = std.mem.indexOf(u8, zsh, "        '--cb')\n") orelse return error.TestUnexpectedResult;
    const cb_end = std.mem.indexOf(u8, zsh[cb_arm..], "            ;;\n").?;
    const cb_body = zsh[cb_arm..][0..cb_end];
    try std.testing.expect(std.mem.indexOf(u8, cb_body, "_m26_dynamic 0 \"$vprefix\" \"$vpart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb_body, "_files") == null);
    try std.testing.expect(std.mem.indexOf(u8, cb_body, "return 0") != null);

    try std.testing.expect(std.mem.indexOf(
        u8,
        zsh,
        "        '--off')\n            return 0\n            ;;\n",
    ) != null);
    // Null targets keep the default completer.
    try std.testing.expect(std.mem.indexOf(
        u8,
        zsh,
        "        '--plain')\n            return 1\n            ;;\n",
    ) != null);
    // Native mappings call `_files` explicitly.
    try std.testing.expect(std.mem.indexOf(u8, zsh, "'--dirs')\n            _files -/\n            return 0\n") != null);
}

test "M26: fish registers `-f` and adds paths for null and native targets" {
    const allocator = std.testing.allocator;
    const fish = try m26Script(allocator, .fish);
    defer allocator.free(fish);

    try std.testing.expect(std.mem.endsWith(u8, fish, "complete -c 'm26' -f -a '(__dap_m26_complete)' -k\n"));
    try std.testing.expect(std.mem.indexOf(u8, fish, "function __dap_m26_dynamic\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "set -l bin (commandline -opc)[1]\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "                __dap_m26_dynamic 0 \"$vprefix\" \"$vpart\"\n                return\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "            case '--off'\n                return\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "            case '--native'\n                __fish_complete_path\n                return\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "            case '--dirs'\n                __fish_complete_directories\n                return\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fish,
        "            case '--plain'\n                __fish_complete_path\n                return\n",
    ) != null);
    // A non-native predictor contributes nothing on failure: no path helper
    // in its arm.
    const arm = std.mem.indexOf(u8, fish, "            case '--files'\n") orelse return error.TestUnexpectedResult;
    const arm_end = std.mem.indexOf(u8, fish[arm..], "            end\n").?;
    try std.testing.expect(std.mem.indexOf(u8, fish[arm..][0..arm_end], "__fish_complete_path") == null);
}

test "M26: launch and call stay inline in every shell" {
    const allocator = std.testing.allocator;
    inline for ([_]Completion.Shell{ .bash, .zsh, .fish }) |shell| {
        const script = try m26Script(allocator, shell);
        defer allocator.free(script);
        const launch_invocation = switch (shell) {
            .bash, .zsh => "if out=$('catalog' \"$cur\"); then",
            .fish => "set -l out ('catalog' \"$cur\")",
        };
        try std.testing.expect(std.mem.indexOf(u8, script, launch_invocation) != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "printf '%s\\n' \"$cur\"") != null);
        // Inline arms carry no route marker or binding index.
        const launch_arm = std.mem.indexOf(u8, script, "'--launch'") orelse return error.TestUnexpectedResult;
        const launch_end = std.mem.indexOf(u8, script[launch_arm..], "return").?;
        const body = script[launch_arm..][0..launch_end];
        try std.testing.expect(std.mem.indexOf(u8, body, Completion.route_marker) == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "_dynamic") == null);
    }
}
