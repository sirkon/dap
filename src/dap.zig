//! Declarative command-line parser.
//!
//! You describe your program's flags and arguments through a struct-based
//! DSL; `generate` produces a *parser* (`parse`) and a strongly-typed *view*
//! (the generated `View` struct) from that declaration. The parser consumes
//! the wire arguments; the view is the resulting data structure the program
//! reads.
//!
//! Builtin value types are supported out of the box: `bool`, the integer types
//! (`uXXX`, `iXXX`, `usize`, `isize`), the floats (`f16` ... `f128`, including
//! `f80`) and `dap.String` (`[]const u8`). Custom value types are usable when
//! they expose:
//!
//!     pub fn decode(self: *Self, data: []const u8) DecodeError!void
//!     pub fn encode(self: *Self) []const u8
//!
//! These two methods are the stable contract. The list is intended to grow with
//! optional methods (for completions and such), but `decode`/`encode` will
//! always be required.

const std = @import("std");

/// Kind of a declaration field.
pub const Kind = enum {
    flag,
    argument,
    group,
    command,
    alt,
};

/// Renderer style selection: `.compact` renders the builtin kong-style
/// two-column layout; `.custom` carries a user-provided renderer function.
pub const HelpRendererStyle = union(enum) {
    compact: void,
    custom: *const fn (self: *const HelpData, allocator: std.mem.Allocator) std.mem.Allocator.Error!String,
};

/// Help text highlight selection: `flat` renders plain text, `bold` and
/// `color` use the matching ready-made [`HelpHighlight`] profiles, and
/// `custom` carries a user-provided scheme.
pub const HelpRendererHighlight = union(enum) {
    flat: void,
    bold: void,
    color: void,
    custom: HelpHighlight,
};

/// App description and such.
pub const App = struct {
    name: String,
    help: String,
    i18n: ?String = null,

    help_renderer: struct {
        style: HelpRendererStyle = @unionInit(HelpRendererStyle, "compact", {}),
        highlight: HelpRendererHighlight = @unionInit(HelpRendererHighlight, "bold", {}),
    } = .{},
};

// Help text highlighting definition and ready schemes.
pub const HelpHighlight = struct {
    pub const Flag = struct {
        name: []const u8 = "",
        value: []const u8 = "",
    };

    usage: struct {
        app_name: []const u8 = "",
        required_flags: HelpHighlight.Flag = .{},
        optionals: []const u8 = "",
        arguments: []const u8 = "",
    } = .{},
    groups: []const u8 = "",
    args: []const u8 = "",
    flags: HelpHighlight.Flag = .{},
    reset: []const u8 = "",

    const flat = HelpHighlight{};

    const bold = HelpHighlight{
        .usage = .{
            .app_name = "\x1b[1m",
            .required_flags = .{
                .name = "\x1b[1m",
                .value = "",
            },
            .optionals = "\x1b[3m",
            .arguments = "\x1b[1m",
        },
        .groups = "\x1b[1m",
        .args = "\x1b[1m",
        .flags = .{
            .name = "\x1b[1m",
            .value = "\x1b[1m",
        },
        .reset = "\x1b[0m",
    };

    const color = HelpHighlight{
        .usage = .{
            .app_name = "\x1b[1;96m",
            .required_flags = .{
                .name = "\x1b[1;96m",
                .value = "\x1b[36m",
            },
            .optionals = "\x1b[3;36m",
            .arguments = "\x1b[36m",
        },
        .groups = "\x1b[1;92m",
        .args = "\x1b[96m",
        .flags = .{
            .name = "\x1b[1;96m",
            .value = "\x1b[36m",
        },
        .reset = "\x1b[0m",
    };

    /// Resolve a [`HelpRendererHighlight`] selection into a concrete scheme,
    /// mapping the `flat`, `bold` and `color` branches to their ready profiles
    /// and passing a `custom` payload through unchanged.
    pub fn resolve(h: HelpRendererHighlight) HelpHighlight {
        return switch (h) {
            .flat => flat,
            .bold => bold,
            .color => color,
            .custom => |c| c,
        };
    }
};

/// String cause I'm bored of it.
pub const String = []const u8;

/// Default value representation. Can be set up directly in an app, can refer an environment value.
/// The list of sources will probably be extended.
pub fn Default(comptime T: type) type {
    return struct {
        direct: ?T = null,
        env: ?String = null,
    };
}

/// Shortcut for `Default(T){ .direct = vT }`.
pub fn defaultValue(comptime T: type, vT: T) Default(T) {
    return .{ .direct = vT };
}

/// Declaration form for flags.
/// Wrap the value in [`Optional`] to make the generated field optional.
///
/// Boolean flags are always optional: an omitted bool flag is `false` and a
/// `true` direct default is a compile error. Use a negative long name
/// defaulting to `false` (`--no-something`) to express "on by default".
pub fn Flag(comptime T: type) type {
    return struct {
        pub const dap_kind: Kind = .flag;
        pub const dap_value_type = T;

        /// Long flag name. Optional. Can be derived from an anonymous field name.
        long: ?String = null,

        /// Short flag name, optional (meh).
        short: ?String = null,

        /// Default value, must be the value of the type above.
        default: ?Default(T) = null,

        /// Optional validation function for the value. For builtin types mostly. Validation returns not a null as
        // an error message and returns an error when the allocation failed.
        validation: ?fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String = null,

        /// Help string, probably in English.
        help: String = "",

        /// Internationalization reference, optional.
        i18n: ?String = null,
    };
}

/// Mark a flag declaration as optional: the generated `View` field is `?T`,
/// `null` when the flag is absent from argv. Optional flags must not declare
/// a default; a present value is validated as usual, a `null` value skips
/// validation.
///
/// ```
/// .flag = dap.Optional(dap.Flag(u32){ .short = "f", .help = "..." }),
/// ```
pub fn Optional(comptime flag: anytype) ?@TypeOf(flag) {
    const T = @TypeOf(flag);
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "dap_kind") or T.dap_kind != .flag) {
        @compileError("dap.Optional expects a dap.Flag(...) value");
    }
    return flag;
}

/// A purely declarative thing to group flags and/or arguments together in the help output.
/// Does not reflect into the placeholder.
pub fn Group(comptime def: anytype, comptime name: String) type {
    return struct {
        pub const dap_kind: Kind = .group;
        pub const group_def = def;
        pub const group_name = name;
    };
}

/// Declaration form for arguments.
/// Unlike flags, arguments are always required. This can be avoided with default values in case
/// of the single argument with a default value. There's a limitation: only the last argument can have
/// a default value.
pub fn Argument(comptime T: type) type {
    return struct {
        pub const dap_kind: Kind = .argument;
        pub const dap_value_type = T;

        /// Identifier to use in help output. Optional. Can be derived from an anonymous struct field name.
        name: ?String = null,

        /// Default value. Optional.
        default: ?Default(T) = null,

        /// Optional validation function for the value. For builtin types mostly. Validation returns not a null as
        // an error message and returns an error when the allocation failed.
        validation: ?fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String = null,

        /// Argument description, probably in English.
        help: String = "",

        /// Internationalization reference, optional.
        i18n: ?String = null,
    };
}

/// А factory to create valid enumerations. The API is
///
/// ```
/// dap.Enumeration(.{
///     branch1: dap.Enum{...},
///     branch2: dap.Enum{...},
///     ...
/// })
/// ```
/// where names are taken from optional name field or autogenerated via the field name.
///
/// Resulting names must be validated against using the same name for different branches (which may happen with custom
/// ones).
///
/// It creates a valid type with decode and encode methods. The view must be a Zig enumeration:
/// ```
/// enum{
///     branch1,
///     branch2,
///     ...
/// }
/// ```
pub fn Enumeration(comptime T: anytype) type {
    const fields = @typeInfo(@TypeOf(T)).@"struct".fields;

    if (fields.len == 0) {
        // No branches: there is no tag type to build a `@Enum` from. Degenerate
        // but still usable as a value type (never accepts a wire token).
        return struct {
            pub fn decode(self: *@This(), data: []const u8) DecodeError!void {
                _ = self;
                _ = data;
                return error.InvalidWire;
            }

            pub fn encode(self: *@This()) []const u8 {
                _ = self;
                return "";
            }
        };
    }

    const branch_names: [fields.len]String = blk: {
        var a: [fields.len]String = undefined;
        for (fields, 0..) |f, i| a[i] = f.name;
        break :blk a;
    };

    const wire_names: [fields.len]String = blk: {
        var a: [fields.len]String = undefined;
        for (fields, 0..) |f, i| {
            const E = @field(T, f.name);
            if (@typeInfo(@TypeOf(E)) != .@"struct" or !@hasField(@TypeOf(E), "name")) {
                @compileError("enumeration branch '" ++ f.name ++ "' must be a dap.Enum");
            }
            a[i] = E.name orelse f.name;
        }
        break :blk a;
    };

    for (wire_names, 0..) |nm, i| {
        for (wire_names[0..i]) |pn| {
            if (std.mem.eql(u8, nm, pn)) {
                @compileError("duplicate enumeration wire name '" ++ nm ++ "'");
            }
        }
    }

    const TagInt = std.math.IntFittingRange(0, fields.len - 1);
    const View = @Enum(TagInt, .exhaustive, &branch_names, blk: {
        var a: [fields.len]TagInt = undefined;
        for (0..fields.len) |i| a[i] = @intCast(i);
        const arr: [fields.len]TagInt = a;
        break :blk &arr;
    });

    return struct {
        view: View = @enumFromInt(0),

        pub const EnumView = View;
        pub const names = wire_names;

        pub fn decode(self: *@This(), data: []const u8) DecodeError!void {
            inline for (wire_names, 0..) |nm, i| {
                if (std.mem.eql(u8, nm, data)) {
                    self.view = @enumFromInt(@as(TagInt, @intCast(i)));
                    return;
                }
            }
            return error.InvalidWire;
        }

        pub fn encode(self: *@This()) []const u8 {
            return wire_names[@intFromEnum(self.view)];
        }
    };
}

pub const Enum = struct {
    name: ?String = null,
    help: String = "",
    i18n: ?String = null,
};

/// Command description.
pub const CommandMeta = struct {
    name: ?String = null,
    help: String = "",
    i18n: ?String = null,
};

/// Declares a subcommand as a sibling field of the parent declaration. The
/// first argument is a [`CommandMeta`] (an anonymous literal is coerced since
/// the parameter is typed), the second is the command's own declaration, a
/// struct of flags and arguments (which may itself contain further `Command`
/// fields for nested subcommands).
///
/// ```
/// const def = .{
///     .verbose = dap.Flag(bool){},
///     .start = dap.Command(
///         .{ .help = "Start." },
///         .{ .name = dap.Argument([]const u8){} },
///     ),
///     .stop = dap.Command(
///         .{ .name = "halt", .help = "Stop." },
///         .{},
///     ),
/// };
/// ```
///
/// Each command field contributes one `?View` field to the parent `View`,
/// stored under the declaration field name prefixed with `_` (`_start`),
/// `null` unless that command's wire name (`.name` orelse the field name)
/// appears. This is how the parsed sub-view is carried, but it is an
/// implementation detail: a declaration field name must not begin with `_`,
/// and consumers reach commands through the namespace's `command` accessor
/// (below). Nested commands nest:
///
/// ```
/// .parent = dap.Command(.{ .name = "parent" }, .{
///     .child = dap.Command(.{ .name = "child" }, .{
///         .file = dap.Argument(dap.String){},
///     }),
/// }),
/// // cli._parent.?.file through the View, or the `command` union below
/// ```
///
/// When a declaration carries at least one command, the generated namespace
/// also exposes `command(view) ?CommandPayload`, the official way to reach
/// the active command: it wraps the single non-null `?View` into a tagged
/// union, `null` when no command token appeared. Its tags are the plain
/// declaration field names, without the `_` prefix the `View` uses (a `stop`
/// field wire-named `halt` switches as `.stop`):
///
/// ```
/// if (CLI.command(cli)) |cmd| switch (cmd) {
///     .start => |s| try serve(s.name),
///     .stop => try shutdown(),
/// } else {
///     // root level execution
/// }
/// ```
pub fn Command(comptime meta: CommandMeta, comptime def: anytype) type {
    return struct {
        pub const dap_kind: Kind = .command;
        pub const cmd_meta = meta;
        pub const cmd_def = def;
    };
}

/// Declaration form for a single branch of a [`Alt`] that overrides the branch
/// (tag) name. Mirrors `Command`: a type-level node carrying the override plus
/// the raw branch declaration, an anonymous struct of flags.
///
/// ```
/// .alt2 = dap.VariantNamed("fancy-alt2", .{
///     .opt2 = dap.Flag([]const u8){},
/// }),
/// ```
pub fn VariantNamed(comptime name: String, comptime branch: anytype) type {
    return struct {
        pub const dap_variant_name = name;
        pub const dap_variant_def = branch;
    };
}

/// Exclusive groups of parameters. The API:
/// ```
/// .alt = dap.Alt(.{
///     .alt1 = .{
///         .opt1 = dap.Flag(someType){...},
///     },
///     .alt2 = dap.VariantNamed("fancy-alt2", .{
///         .opt2 = dap.Flag(someOtherType){...},
///     }),
/// }),
/// ```
/// Only flags are allowed inside branches; defaults are forbidden (a
/// default implies implicit branch activation). Branches implicitly create
/// help groups named after the field name or the `VariantNamed` string.
///
/// The generated `View` field is a `?Union`: it is `null` until a member of a
/// branch is seen on the wire, after which it holds the activated branch's
/// payload struct. Two branches of the same `Alt` cannot be active at once;
/// doing so is a `ConflictingAlt` parse error. Consume it with
/// `switch (cli.alt orelse return) { ... }`.
pub fn Alt(comptime T: anytype) type {
    const fields = @typeInfo(@TypeOf(T)).@"struct".fields;
    if (fields.len == 0) {
        @compileError("Alt must declare at least one branch");
    }

    const bnames: [fields.len]String = blk: {
        var a: [fields.len]String = undefined;
        for (fields, 0..) |f, i| a[i] = f.name;
        break :blk a;
    };

    const tnames: [fields.len]String = blk: {
        var a: [fields.len]String = undefined;
        for (fields, 0..) |f, i| {
            const Bv = @field(T, f.name);
            if (@TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_name")) {
                a[i] = Bv.dap_variant_name;
            } else {
                a[i] = f.name;
            }
        }
        break :blk a;
    };

    for (tnames, 0..) |tn, i| {
        for (tnames[0..i]) |pn| {
            if (std.mem.eql(u8, tn, pn)) {
                @compileError("duplicate Alt branch name '" ++ tn ++ "'");
            }
        }
    }

    const btypes: [fields.len]type = blk: {
        var a: [fields.len]type = undefined;
        for (fields, 0..) |f, i| {
            const Bv = @field(T, f.name);
            const Bdef = if (@TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_def"))
                Bv.dap_variant_def
            else
                Bv;
            if (@TypeOf(Bdef) == type) {
                @compileError("Alt branch '" ++ f.name ++ "' must be a struct of flags or a VariantNamed");
            }
            if (@typeInfo(@TypeOf(Bdef)) != .@"struct") {
                @compileError("Alt branch '" ++ f.name ++ "' must be a struct of flags or a VariantNamed");
            }
            const bf = @typeInfo(@TypeOf(Bdef)).@"struct".fields;
            var nm: [bf.len]String = undefined;
            var ts: [bf.len]type = undefined;
            var at: [bf.len]std.builtin.Type.StructField.Attributes = undefined;
            for (bf, 0..) |bfld, bi| {
                nm[bi] = bfld.name;
                const ft = if (@typeInfo(bfld.type) == .optional) @typeInfo(bfld.type).optional.child else bfld.type;
                ts[bi] = ft.dap_value_type;
                at[bi] = .{};
            }
            a[i] = @Struct(.auto, null, &nm, &ts, &at);
        }
        break :blk a;
    };

    const TagInt = std.math.IntFittingRange(0, tnames.len - 1);
    const Tag = @Enum(TagInt, .exhaustive, &tnames, tg: {
        var a: [tnames.len]TagInt = undefined;
        for (0..tnames.len) |i| a[i] = @intCast(i);
        const arr: [tnames.len]TagInt = a;
        break :tg &arr;
    });

    const PayloadUnion = @Union(.auto, Tag, &tnames, &btypes, blk: {
        var a: [tnames.len]std.builtin.Type.UnionField.Attributes = undefined;
        for (0..tnames.len) |i| a[i] = .{};
        const arr: [tnames.len]std.builtin.Type.UnionField.Attributes = a;
        break :blk &arr;
    });

    return struct {
        pub const dap_kind: Kind = .alt;
        pub const alt_def = T;
        pub const branch_names = bnames;
        pub const tag_names = tnames;
        pub const branch_types = btypes;
        pub const Union = PayloadUnion;
    };
}

/// Ready to use validation helpers to plug into `Flag`/`Argument` declarations.
pub const Validate = struct {
    /// Ready to use helper checking if a string is not empty.
    pub fn stringNotEmpty(allocator: std.mem.Allocator, v: String) std.mem.Allocator.Error!?String {
        if (v.len != 0) {
            return null;
        }

        return try std.fmt.allocPrint(allocator, "value must not be empty", .{});
    }

    /// Ready to use helper to check whether an integer value is not zero. A factory that
    /// monomorphizes per concrete integer type.
    pub fn intNotZero(comptime T: type) fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String {
        return struct {
            fn check(allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!?String {
                switch (@typeInfo(T)) {
                    .int => {
                        if (v != 0) return null;
                    },
                    else => {
                        @compileError("intNotZero supports only integer types");
                    },
                }

                return try std.fmt.allocPrint(allocator, "value must not be zero", .{});
            }
        }.check;
    }
};

/// This error can be returned on decode.
pub const DecodeError = error{
    /// InvalidWire means the value does not represent a correct value.
    InvalidWire,

    /// InvalidValue refers to a situation when the wire is OK, but the value itself is not correct.
    InvalidValue,
};

/// Errors reported by `parse`. Decode failures (`InvalidWire`/`InvalidValue`)
/// are folded in, so a caller can handle both layers through one error set.
pub const ParseError = error{
    /// A long or short flag token matched no declaration.
    UnknownFlag,
    /// A non-bool flag was given without a value.
    MissingValue,
    /// A required flag/argument was never provided.
    MissingRequired,
    /// A positional token found every argument slot already filled.
    TooManyArguments,
    /// Two branches of the same `Alt` were activated at once.
    ConflictingAlt,
    /// An environment variable value was not valid WTF-8.
    InvalidWtf8,
} || std.mem.Allocator.Error || DecodeError;

/// Diagnostic detail for the most recent failed `parse`. `field` and `token`
/// borrow caller-owned memory (declaration names / argv); `message` is
/// allocated with the parser's allocator and must be released by `deinit`.
pub const Diag = struct {
    field: ?String = null,
    token: ?String = null,
    message: ?String = null,

    pub fn deinit(self: *Diag, allocator: std.mem.Allocator) void {
        if (self.message) |m| allocator.free(m);
        self.message = null;
    }
};

/// Runtime-filled description of a generated CLI, suitable for rendering help
/// text or driving other help UIs (completion, man pages). Unlike the raw
/// comptime metadata it carries only plain data: every string and slice is
/// allocated with the caller's allocator and released by `deinit`.
pub const HelpData = struct {
    const Self = @This();

    /// A single flag entry.
    pub const Flag = struct {
        /// Long wire name, e.g. `dry_run` or an explicit `.long`.
        name: String,
        /// Short wire name, without the dash.
        short: ?String,
        /// Help string.
        help: String,
        /// Rendered default value, `null` when the flag is required.
        default: ?String,
        /// Whether the flag consumes a value (`<value>` in help); `false`
        /// for boolean flags.
        takes_value: bool,
        /// When the flag belongs to an `Alt`, the declaration field name of
        /// that `Alt`; `null` for ordinary flags. Usage rendering skips
        /// these in favour of the `Alt`'s alternation clause.
        alt: ?String = null,
        /// When the flag belongs to an `Alt`, the tag name of its branch;
        /// `null` for ordinary flags.
        alt_branch: ?String = null,
        /// Whether the flag was declared optional (`?Flag(T)` / `dap.Optional`).
        /// Usage rendering omits optional flags; custom renderers can inspect
        /// this to decorate them.
        optional: bool = false,
    };

    /// A single positional argument entry.
    pub const Argument = struct {
        /// `.name` override or the declaration field name.
        name: String,
        /// Help string.
        help: String,
        /// Rendered default value, `null` when the argument is required.
        default: ?String,
    };

    /// Flags sharing a `Group` name, or the ungrouped flags (`name == null`).
    pub const FlagGroup = struct {
        name: ?String,
        flags: []Self.Flag,
    };

    /// Arguments sharing a `Group` name, or the ungrouped arguments (`name == null`).
    pub const ArgGroup = struct {
        name: ?String,
        args: []Self.Argument,
    };

    /// A subcommand name and its help string.
    pub const CommandInfo = struct {
        name: String,
        help: String,
    };

    /// An exclusive-parameter clause of the usage line: the branches of one
    /// `Alt`, each a set of alternative flags. Rendered as a parenthesized
    /// alternation `(-a | -b | ...)`. The inner flag slices reference entries
    /// owned by `flag_groups`; only the outer arrays are released by
    /// `deinit`.
    pub const Usage = struct {
        branches: [][]Self.Flag,
    };

    /// `App.name`.
    name: String,
    /// `App.help`.
    info: String,
    /// Flag groups; ungrouped flags first, then named groups in declaration order.
    flag_groups: []FlagGroup,
    /// Argument groups; ungrouped arguments first, then named groups in declaration order.
    arg_groups: []ArgGroup,
    /// Exclusive-parameter group clauses (one per `Alt`) for the usage line.
    usage_alts: []Usage = &.{},
    /// Subcommands in declaration order.
    commands: []CommandInfo,
    /// Highlight scheme `renderCompact` applies. Filled from
    /// `App.help_renderer.highlight`; the codes are borrowed static strings and
    /// are not freed by `deinit`.
    highlight: HelpRendererHighlight = .{ .flat = {} },

    pub fn deinit(self: *HelpData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.info);

        for (self.flag_groups) |g| {
            if (g.name) |n| allocator.free(n);
            for (g.flags) |o| {
                allocator.free(o.name);
                if (o.short) |sh| allocator.free(sh);
                allocator.free(o.help);
                if (o.default) |dv| allocator.free(dv);
                if (o.alt) |av| allocator.free(av);
                if (o.alt_branch) |bv| allocator.free(bv);
            }
            allocator.free(g.flags);
        }
        allocator.free(self.flag_groups);

        for (self.arg_groups) |g| {
            if (g.name) |n| allocator.free(n);
            for (g.args) |a| {
                allocator.free(a.name);
                allocator.free(a.help);
                if (a.default) |dv| allocator.free(dv);
            }
            allocator.free(g.args);
        }
        allocator.free(self.arg_groups);

        for (self.usage_alts) |u| {
            for (u.branches) |br| allocator.free(br);
            allocator.free(u.branches);
        }
        allocator.free(self.usage_alts);

        for (self.commands) |c| {
            allocator.free(c.name);
            allocator.free(c.help);
        }
        allocator.free(self.commands);
    }

    /// Render a compact, two-column help view of this description into a freshly
    /// allocated string, mirroring the layout of `kong`'s help renderer. The
    /// flag/argument specs occupy the left column (short and long names aligned
    /// into their own sub-columns) and the help text the right; groups are
    /// ordered by name with the ungrouped bucket first.
    ///
    /// Every fragment is wrapped in the scheme carried by `highlight` (resolved
    /// from `App.help_renderer.highlight`): the usage header distinguishes the
    /// app name, required flags (name and value), optional tokens and
    /// arguments, while the grouped sections use the `groups`, `args` and
    /// `flags` (name and value) tokens. Delimiters join their token: the
    /// argument list wraps the whole `[<name>]`/`<name>` including brackets,
    /// each flag name carries its own leading dashes and trailing `=`, and the
    /// flag list keeps the `, ` separator uncolored. Widths are measured on the
    /// raw text before any codes are emitted, so highlighting never disturbs
    /// the column alignment. The caller owns the returned string and frees it
    /// with the same allocator.
    pub fn renderCompact(self: *const HelpData, allocator: std.mem.Allocator) std.mem.Allocator.Error!String {
        const indent = "  ";
        const column_padding = 4;
        const max_left = 30;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // The scheme is resolved once; every fragment is emitted through it.
        const hl = HelpHighlight.resolve(self.highlight);

        // Order flag and argument groups by name, the ungrouped bucket
        // (`null`) first.
        const Order = struct {
            fn lessName(a: ?String, b: ?String) bool {
                if (a == null) return b != null;
                if (b == null) return false;
                return std.mem.lessThan(u8, a.?, b.?);
            }

            fn of(comptime G: type, alloc: std.mem.Allocator, groups: []const G) std.mem.Allocator.Error![]const usize {
                const idx = try alloc.alloc(usize, groups.len);
                for (idx, 0..) |*slot, i| slot.* = i;
                var i: usize = 1;
                while (i < idx.len) : (i += 1) {
                    const cur = idx[i];
                    const cur_name = groups[cur].name;
                    var j = i;
                    while (j > 0 and lessName(cur_name, groups[idx[j - 1]].name)) : (j -= 1) {
                        idx[j] = idx[j - 1];
                    }
                    idx[j] = cur;
                }
                return idx;
            }
        };

        const flag_order = try Order.of(FlagGroup, arena, self.flag_groups);
        const arg_order = try Order.of(ArgGroup, arena, self.arg_groups);

        // Usage line: required flags, then bracketed optional bools, then
        // positionals, then `[flags]`. Brackets stay inside their highlight
        // block: the whole `[--flag]` token carries `.usage.optionals`, the
        // whole `<arg>`/`[<arg>]` token carries `.usage.arguments`.
        try appendHelpStyled(&out, allocator, hl, .usage_label, "Usage: ");
        try appendHelpStyled(&out, allocator, hl, .usage_app_name, self.name);
        for (flag_order) |gi| {
            for (self.flag_groups[gi].flags) |o| {
                // Boolean flags are always optional: with no default they
                // implicitly default to `false` and render bracketed in the
                // usage header, e.g. `[--flag]`.
                const bool_flag = !o.takes_value and o.default == null;
                if (o.default != null and !bool_flag) continue;
                if (o.alt != null) continue;
                if (o.optional) continue;
                try out.append(allocator, ' ');
                if (bool_flag) {
                    const token = try std.fmt.allocPrint(arena, "[--{s}]", .{o.name});
                    try appendHelpStyled(&out, allocator, hl, .usage_optional, token);
                    continue;
                }
                // The dashes and the assignment sign stay inside the name
                // token so the whole `--flag=` run is highlighted continuously.
                const name_token = if (o.takes_value)
                    try std.fmt.allocPrint(arena, "--{s}=", .{o.name})
                else
                    try std.fmt.allocPrint(arena, "--{s}", .{o.name});
                try appendHelpStyled(&out, allocator, hl, .usage_required_name, name_token);
                if (o.takes_value) {
                    try appendHelpStyled(&out, allocator, hl, .usage_required_value, try upperDup(arena, o.name));
                }
            }
        }
        // Exclusive-parameter groups: `(branch | branch | ...)`, each branch a
        // space-separated set of its member flags. The parentheses are emitted
        // as their own highlighted blocks so the brackets never sit outside the
        // scheme codes.
        for (self.usage_alts) |u| {
            try out.append(allocator, ' ');
            try appendHelpStyled(&out, allocator, hl, .usage_required_name, "(");
            for (u.branches, 0..) |branch, bi| {
                if (bi != 0) try appendHelpStyled(&out, allocator, hl, .usage_required_name, " | ");
                for (branch, 0..) |o, oi| {
                    if (oi != 0) try out.append(allocator, ' ');
                    try appendFlagUsage(&out, allocator, arena, hl, o);
                }
            }
            try appendHelpStyled(&out, allocator, hl, .usage_required_name, ")");
        }
        for (arg_order) |gi| {
            for (self.arg_groups[gi].args) |a| {
                try out.append(allocator, ' ');
                const token = if (a.default == null)
                    try std.fmt.allocPrint(arena, "<{s}>", .{a.name})
                else
                    try std.fmt.allocPrint(arena, "[<{s}>]", .{a.name});
                try appendHelpStyled(&out, allocator, hl, .usage_argument, token);
            }
        }
        if (self.commands.len > 0) {
            try out.append(allocator, ' ');
            try appendHelpStyled(&out, allocator, hl, .usage_argument, "<command>");
        }
        var has_flag = false;
        var has_default = false;
        for (self.flag_groups) |g| {
            for (g.flags) |o| {
                has_flag = true;
                if (o.default != null) has_default = true;
            }
        }
        if (has_flag and has_default) {
            try out.append(allocator, ' ');
            try appendHelpStyled(&out, allocator, hl, .usage_optional, "[flags]");
        }
        try out.append(allocator, '\n');

        if (self.info.len > 0) {
            try out.append(allocator, '\n');
            try appendHelpStyled(&out, allocator, hl, .plain, self.info);
            try out.append(allocator, '\n');
        }

        // Collect the sections as raw (unstyled) fragments. Nothing is written
        // to `out` until every width has been measured, so the highlight codes
        // never leak into the column arithmetic.
        var arg_count: usize = 0;
        for (self.arg_groups) |g| arg_count += g.args.len;
        var n_flag_sections: usize = 0;
        for (self.flag_groups) |g| {
            if (g.flags.len > 0) n_flag_sections += 1;
        }
        var section_count = n_flag_sections;
        if (arg_count > 0) section_count += 1;
        if (self.commands.len > 0) section_count += 1;

        const sections = try arena.alloc(HelpSection, section_count);
        var si: usize = 0;

        if (arg_count > 0) {
            const rows = try arena.alloc(HelpRow, arg_count);
            var ri: usize = 0;
            for (arg_order) |gi| {
                for (self.arg_groups[gi].args) |a| {
                    var left: std.ArrayList(HelpSegment) = .empty;
                    const token = if (a.default == null)
                        try std.fmt.allocPrint(arena, "<{s}>", .{a.name})
                    else
                        try std.fmt.allocPrint(arena, "[<{s}>]", .{a.name});
                    try left.append(arena, .{ .text = token, .style = .args });
                    rows[ri] = .{ .left = left.items, .help = a.help };
                    ri += 1;
                }
            }
            sections[si] = .{ .heading = "Arguments:", .rows = rows };
            si += 1;
        }

        for (flag_order) |gi| {
            const group = self.flag_groups[gi];
            if (group.flags.len == 0) continue;
            var have_short = false;
            for (group.flags) |o| {
                if (o.short != null) {
                    have_short = true;
                    break;
                }
            }
            const rows = try arena.alloc(HelpRow, group.flags.len);
            for (group.flags, 0..) |o, ri| {
                var left: std.ArrayList(HelpSegment) = .empty;
                if (o.short) |sh| {
                    try left.append(arena, .{ .text = try std.fmt.allocPrint(arena, "-{s}", .{sh}), .style = .flags_name });
                    try left.append(arena, .{ .text = ", ", .style = .plain });
                } else if (have_short) {
                    try left.append(arena, .{ .text = "    ", .style = .plain });
                }
                // The dashes and the assignment sign are part of the name
                // token so the whole `--name=` run is colored continuously.
                const long_token = if (o.takes_value)
                    try std.fmt.allocPrint(arena, "--{s}=", .{o.name})
                else
                    try std.fmt.allocPrint(arena, "--{s}", .{o.name});
                try left.append(arena, .{ .text = long_token, .style = .flags_name });
                if (o.takes_value) {
                    if (o.default) |d| {
                        try left.append(arena, .{ .text = d, .style = .flags_value });
                    } else {
                        try left.append(arena, .{ .text = try upperDup(arena, o.name), .style = .flags_value });
                    }
                }
                rows[ri] = .{ .left = left.items, .help = o.help };
            }
            sections[si] = .{ .heading = group.name orelse "Flags:", .rows = rows };
            si += 1;
        }

        if (self.commands.len > 0) {
            const rows = try arena.alloc(HelpRow, self.commands.len);
            for (self.commands, 0..) |c, ri| {
                var left: std.ArrayList(HelpSegment) = .empty;
                try left.append(arena, .{ .text = c.name, .style = .flags_name });
                rows[ri] = .{ .left = left.items, .help = c.help };
            }
            sections[si] = .{ .heading = "Commands:", .rows = rows };
            si += 1;
        }

        for (sections) |section| {
            try out.append(allocator, '\n');
            try appendHelpStyled(&out, allocator, hl, .groups, section.heading);
            try out.append(allocator, '\n');
            var left_size: usize = 0;
            for (section.rows) |r| {
                const w = helpSegmentsWidth(r.left);
                if (w > left_size and w < max_left) left_size = w;
            }
            for (section.rows) |r| {
                const left_w = helpSegmentsWidth(r.left);
                try out.appendSlice(allocator, indent);
                try appendHelpSegments(&out, allocator, hl, r.left);
                if (left_w < max_left) {
                    if (r.help.len > 0) {
                        var pad = left_size - left_w + column_padding;
                        while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
                        try appendHelpStyled(&out, allocator, hl, .plain, r.help);
                    }
                } else if (r.help.len > 0) {
                    try out.append(allocator, '\n');
                    try out.appendSlice(allocator, indent);
                    var pad = left_size + column_padding;
                    while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
                    try appendHelpStyled(&out, allocator, hl, .plain, r.help);
                }
                try out.append(allocator, '\n');
            }
        }

        return try out.toOwnedSlice(allocator);
    }
};

/// Highlight category a compact-help fragment belongs to.
const HelpStyle = enum {
    plain,
    usage_label,
    usage_app_name,
    usage_required_name,
    usage_required_value,
    usage_optional,
    usage_argument,
    groups,
    args,
    flags_name,
    flags_value,
};

/// A run of compact-help text carrying a single highlight category.
const HelpSegment = struct {
    text: []const u8,
    style: HelpStyle,
};

/// One left/right pair of a compact-help section. `left` is stored as raw
/// segments so column widths are measured on the plain text; the highlight
/// codes are applied only when the row is emitted.
const HelpRow = struct {
    left: []const HelpSegment,
    help: []const u8,
};

/// A compact-help section: a heading plus its rows.
const HelpSection = struct {
    heading: []const u8,
    rows: []const HelpRow,
};

fn helpStyleCode(hl: HelpHighlight, style: HelpStyle) []const u8 {
    return switch (style) {
        .plain => "",
        .usage_label => hl.groups,
        .usage_app_name => hl.usage.app_name,
        .usage_required_name => hl.usage.required_flags.name,
        .usage_required_value => hl.usage.required_flags.value,
        .usage_optional => hl.usage.optionals,
        .usage_argument => hl.usage.arguments,
        .groups => hl.groups,
        .args => hl.args,
        .flags_name => hl.flags.name,
        .flags_value => hl.flags.value,
    };
}

fn helpSegmentsWidth(parts: []const HelpSegment) usize {
    var n: usize = 0;
    for (parts) |p| n += p.text.len;
    return n;
}

/// Append `text` wrapped in the codes of `style`, with a trailing reset when
/// the scheme defines an opening sequence. `plain` and empty schemes emit the
/// text unchanged.
fn appendHelpStyled(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    hl: HelpHighlight,
    style: HelpStyle,
    text: []const u8,
) std.mem.Allocator.Error!void {
    if (text.len == 0) return;
    const pre = helpStyleCode(hl, style);
    if (pre.len > 0) try out.appendSlice(allocator, pre);
    try out.appendSlice(allocator, text);
    if (pre.len > 0) try out.appendSlice(allocator, hl.reset);
}

fn appendHelpSegments(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    hl: HelpHighlight,
    parts: []const HelpSegment,
) std.mem.Allocator.Error!void {
    for (parts) |p| try appendHelpStyled(out, allocator, hl, p.style, p.text);
}

fn upperDup(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    return buf;
}

/// Append one flag's usage fragment, `--name` or `--name=VALUE`, to `out`
/// with the name/value segments highlighted using the usage required-flag
/// tokens. The dashes and the assignment sign are folded into the name token
/// so the whole `--name=` run is colored continuously.
fn appendFlagUsage(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    hl: HelpHighlight,
    o: HelpData.Flag,
) std.mem.Allocator.Error!void {
    const name_token = if (o.takes_value)
        try std.fmt.allocPrint(arena, "--{s}=", .{o.name})
    else
        try std.fmt.allocPrint(arena, "--{s}", .{o.name});
    try appendHelpStyled(out, allocator, hl, .usage_required_name, name_token);
    if (o.takes_value) {
        try appendHelpStyled(out, allocator, hl, .usage_required_value, try upperDup(arena, o.name));
    }
}

/// Free every string owned by one flag entry. File-private so the scope merge
/// (and `generate`'s errdefers) can share it.
fn freeFlag(allocator: std.mem.Allocator, o: HelpData.Flag) void {
    allocator.free(o.name);
    if (o.short) |sh| allocator.free(sh);
    allocator.free(o.help);
    if (o.default) |dv| allocator.free(dv);
    if (o.alt) |av| allocator.free(av);
    if (o.alt_branch) |bv| allocator.free(bv);
}

fn freeFlags(allocator: std.mem.Allocator, flags: []HelpData.Flag) void {
    for (flags) |o| freeFlag(allocator, o);
}

fn freeFlagGroups(allocator: std.mem.Allocator, groups: []HelpData.FlagGroup) void {
    for (groups) |g| {
        if (g.name) |n| allocator.free(n);
        freeFlags(allocator, g.flags);
        allocator.free(g.flags);
    }
}

fn freeArguments(allocator: std.mem.Allocator, args: []HelpData.Argument) void {
    for (args) |a| {
        allocator.free(a.name);
        allocator.free(a.help);
        if (a.default) |dv| allocator.free(dv);
    }
}

fn freeArgGroups(allocator: std.mem.Allocator, groups: []HelpData.ArgGroup) void {
    for (groups) |g| {
        if (g.name) |n| allocator.free(n);
        freeArguments(allocator, g.args);
        allocator.free(g.args);
    }
}

fn freeCommands(allocator: std.mem.Allocator, cmds: []HelpData.CommandInfo) void {
    for (cmds) |c| {
        allocator.free(c.name);
        allocator.free(c.help);
    }
}

/// An all-empty [`HelpData`]: `deinit` on it is a no-op. The move discipline
/// of the scope merge depends on this shape.
fn emptyHelpData() HelpData {
    return .{
        .name = "",
        .info = "",
        .flag_groups = &.{},
        .arg_groups = &.{},
        .usage_alts = &.{},
        .commands = &.{},
        .highlight = .{ .flat = {} },
    };
}

/// Whether two optional group names denote the same visual group.
fn sameGroupName(a: ?String, b: ?String) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Fold one deeper scope into the accumulated one (D5): flag groups merge by
/// name (entries moved, duplicate header strings freed), arg groups, commands,
/// `info` and `name` are replaced (deepest wins), `usage_alts` are appended,
/// `highlight` is overwritten.
///
/// Every allocation is performed before anything is freed, and neither `dst`
/// nor `src` is mutated until the final, infallible commit. On error both stay
/// fully deinit-able; on success the source is emptied.
fn absorbScope(
    allocator: std.mem.Allocator,
    dst: *HelpData,
    src: *HelpData,
) std.mem.Allocator.Error!void {
    // Build the merged flag-group list. Entries are moved (struct copies
    // referencing the same strings), never duplicated.
    var groups: std.ArrayList(HelpData.FlagGroup) = .empty;
    errdefer groups.deinit(allocator);

    // Newly allocated merged arrays (combinations of two groups' entries).
    var merged_arrays: std.ArrayList([]HelpData.Flag) = .empty;
    defer merged_arrays.deinit(allocator);
    errdefer for (merged_arrays.items) |m| allocator.free(m);

    // Pending replacement of one destination group's entry slice, applied at
    // commit so a mid-loop failure never leaves `dst` pointing at freed memory.
    const Replacement = struct { idx: usize, flags: []HelpData.Flag };
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(allocator);

    // Old buffers / duplicate names freed at commit.
    var stale_arrays: std.ArrayList([]HelpData.Flag) = .empty;
    defer stale_arrays.deinit(allocator);
    var stale_names: std.ArrayList(String) = .empty;
    defer stale_names.deinit(allocator);

    try groups.appendSlice(allocator, dst.flag_groups);

    for (src.flag_groups) |sg| {
        var merged = false;
        for (groups.items, 0..) |dg, gi| {
            if (!sameGroupName(dg.name, sg.name)) continue;
            merged = true;
            if (sg.name) |n| try stale_names.append(allocator, n);
            try stale_arrays.append(allocator, sg.flags);
            if (dg.flags.len + sg.flags.len == 0) break;
            const m = try allocator.alloc(HelpData.Flag, dg.flags.len + sg.flags.len);
            merged_arrays.append(allocator, m) catch |e| {
                allocator.free(m);
                return e;
            };
            @memcpy(m[0..dg.flags.len], dg.flags);
            @memcpy(m[dg.flags.len..], sg.flags);
            if (dg.flags.len > 0) try stale_arrays.append(allocator, dg.flags);
            try replacements.append(allocator, .{ .idx = gi, .flags = m });
            break;
        }
        if (!merged) try groups.append(allocator, sg);
    }

    const new_flag_groups = try groups.toOwnedSlice(allocator);
    errdefer allocator.free(new_flag_groups);

    const usage_alts = try allocator.alloc(HelpData.Usage, dst.usage_alts.len + src.usage_alts.len);
    errdefer allocator.free(usage_alts);
    @memcpy(usage_alts[0..dst.usage_alts.len], dst.usage_alts);
    @memcpy(usage_alts[dst.usage_alts.len..], src.usage_alts);

    // --- Commit: nothing below can fail. ---
    for (replacements.items) |r| new_flag_groups[r.idx].flags = r.flags;
    for (stale_arrays.items) |arr| allocator.free(arr);
    for (stale_names.items) |n| allocator.free(n);

    allocator.free(dst.flag_groups);
    dst.flag_groups = new_flag_groups;

    allocator.free(dst.usage_alts);
    dst.usage_alts = usage_alts;
    allocator.free(src.usage_alts);

    freeArgGroups(allocator, dst.arg_groups);
    allocator.free(dst.arg_groups);
    dst.arg_groups = src.arg_groups;

    freeCommands(allocator, dst.commands);
    allocator.free(dst.commands);
    dst.commands = src.commands;

    allocator.free(dst.info);
    dst.info = src.info;
    allocator.free(dst.name);
    dst.name = src.name;
    dst.highlight = src.highlight;

    allocator.free(src.flag_groups);
    src.* = emptyHelpData();
}

/// Whether a flag entry is the injected `-h, --help` builtin.
fn isBuiltinHelp(o: HelpData.Flag) bool {
    if (!std.mem.eql(u8, o.name, "help")) return false;
    return o.short != null and std.mem.eql(u8, o.short.?, "h");
}

/// The injected `-h, --help` exists at every level; a merged scope would list
/// it once per level. Keep the first (root) entry and free the rest. The
/// ungrouped bucket is compacted into a freshly allocated, correctly sized
/// slice so the later `deinit` frees a buffer of the exact allocated length.
fn dedupeBuiltinHelp(allocator: std.mem.Allocator, group: *HelpData.FlagGroup) std.mem.Allocator.Error!void {
    var keep: usize = 0;
    for (group.flags, 0..) |f, i| {
        if (i > 0 and isBuiltinHelp(f)) continue;
        keep += 1;
    }
    if (keep == group.flags.len) return;

    const shrunk = try allocator.alloc(HelpData.Flag, keep);
    var out: usize = 0;
    for (group.flags, 0..) |f, i| {
        if (i > 0 and isBuiltinHelp(f)) continue;
        shrunk[out] = f;
        out += 1;
    }
    for (group.flags, 0..) |f, i| {
        if (i > 0 and isBuiltinHelp(f)) freeFlag(allocator, f);
    }
    allocator.free(group.flags);
    group.flags = shrunk;
}

/// Append the [`HelpData`] of every active sub-scope (the caller adds the
/// root scope first), comptime-recursing through the generated namespaces
/// along the runtime View chain.
fn appendActiveScopes(
    comptime NS: type,
    allocator: std.mem.Allocator,
    scopes: *std.ArrayList(HelpData),
    v: anytype,
) std.mem.Allocator.Error!void {
    inline for (NS.commands) |c| {
        if (@field(v, c.view_field)) |sub| {
            const S = Sub(c.Cmd, subApp(NS.app_meta, c));
            const scope = try S.helpData(allocator);
            scopes.append(allocator, scope) catch |e| {
                var d = scope;
                d.deinit(allocator);
                return e;
            };
            try appendActiveScopes(S, allocator, scopes, &sub);
        }
    }
}

/// The context-sensitive help of a parsed view: build every active level's
/// [`HelpData`], fold them into the deepest scope, render once with the app's
/// configured renderer. Nothing public changes shape; this is called from
/// `parse`'s help intercept.
fn contextHelpText(comptime NS: type, allocator: std.mem.Allocator, v: anytype) std.mem.Allocator.Error!String {
    var scopes: std.ArrayList(HelpData) = .empty;
    defer {
        for (scopes.items) |*d| d.deinit(allocator);
        scopes.deinit(allocator);
    }
    const root_scope = try NS.helpData(allocator);
    scopes.append(allocator, root_scope) catch |e| {
        var d = root_scope;
        d.deinit(allocator);
        return e;
    };
    try appendActiveScopes(NS, allocator, &scopes, v);

    var merged: HelpData = emptyHelpData();
    defer merged.deinit(allocator);
    for (scopes.items) |*d| try absorbScope(allocator, &merged, d);
    // The ungrouped bucket is always present and always index 0.
    try dedupeBuiltinHelp(allocator, &merged.flag_groups[0]);
    return renderHelpWithStyle(NS.app_meta.help_renderer.style, allocator, &merged);
}

/// Generate the *parser* and the *view* type for a declaration. `generate`
/// returns a namespace wrapper exposing:
///
/// - `pub const View` — the strongly-typed view, a struct with one field per
///   declaration field (in declaration order, with the injected
///   `builtin_help: bool` first), one `?Union` per `Alt` field, and one
///   `?View` per command field under a `_`-prefixed name (`_stop`);
/// - `pub fn parse(allocator, environ, args, diag) ParseError!View`;
/// - `app_meta`, `specs`, `commands` metadata;
/// - `pub fn helpData(allocator) !HelpData` — runtime-filled description;
/// - `pub fn helpText(allocator) !String` — render `helpData` with the
///   renderer configured in `app.help_renderer.style` (`.compact` by default,
///   or a user-provided function via `.custom`);
/// - `pub const CommandPayload` and `pub fn command(view) ?CommandPayload`
///   — present only when the declaration carries subcommands; `command`
///   wraps the active subcommand's View into the union, `null` when none
///   was activated. The union tags are the plain declaration field names,
///   without the `_` prefix the `View` uses:
///
/// ```
/// if (CLI.command(cli)) |cmd| switch (cmd) {
///     .start => |s| try serve(s.name),
///     .stop => try shutdown(),
/// } else {
///     // root level execution
/// }
/// ```
///
/// An `Alt` declaration contributes one `?Union` field to `View` (before any
/// command fields), `null` until one of its branch flags is seen.
///
/// A `-h, --help` flag is injected at the very beginning of every
/// declaration. When `parse` sees it — at this level or anywhere in the
/// active command chain — it bypasses all required checks and validations,
/// prints the rendered help text to stdout and exits with code `0`.
///
/// The help is *context-sensitive*: a request after one or more subcommands
/// describes the deepest active command. The usage header reconstructs the
/// command path (`Usage: app svc build ...`), arguments and next-level
/// subcommands come from that deepest scope, and flags are merged from every
/// ancestor level (global flags + each command's flags). Because flags merge,
/// long names and short aliases must be globally unique across the whole
/// declaration tree; a collision is a compile error. `Group`/`Alt` groups
/// sharing a name across levels merge into one visual block. Any syntax,
/// decode, required or validation failure prints the diagnostics plus the
/// (root-scoped) help text to stderr and exits with code `1`.
///
/// Every `parse` — the root and each subcommand alike — treats `args` as pure
/// payload: iteration starts at index `0` and nothing is skipped. Pass the
/// process arguments with the binary name already removed (`os.argv[1..]`).
///
/// Example:
///
/// ```
/// const def = .{
///     .login = dap.Flag([]const u8){
///         .short = "l",
///         .default = dap.Default(dap.String){
///             .env = "USER",
///         },
///         .validation = dap.Validate.stringNotEmpty,
///         .help = "User login.",
///     },
///     .password = dap.Flag([]const u8){
///         .short = "p",
///         .validation = dap.Validate.stringNotEmpty,
///         .help = "Password for the given login.",
///     },
///     .verbosity = dap.Flag(u8){
///          .short = "V",
///          .validation = dap.Validate.intNotZero(u8),
///          .default = dap.defaultValue(u8)(0),
///          .help = "Verbosity level.",
///     },
///     .path = dap.Argument([]const u8){
///          .validation = dap.Validate.stringNotEmpty,
///          .help = "Path of the file to download",
///     },
/// }
///
/// const CLI = dap.generate(
///     dap.App{
///         .name = "api-downloader",
///         .help = "Download a file with a given path from API stand.",
///     },
///     def,
/// );
///
/// var cli = try CLI.parse(allocator, environ, args, &diag);
/// std.debug.print("{} {}", .{ cli.login, cli.path }); // Both are strings.
/// defer diag.deinit(allocator);
/// ```
///
/// `View` is a plain struct (`cli.login`, `cli.path`, ...) whose strings are
/// allocated with the passed allocator. No name transformation is applied:
/// field names are wire names verbatim (`dry_run` → `--dry_run`), and a
/// dash-spelled name requires an explicit `.long`. A declaration field name
/// must not start with `_`: the leading underscore is reserved for the
/// `_`-prefixed command fields the `View` carries.
///
/// A command field hands parsing off to the matching subcommand. The token
/// equal to a registered command name terminates the current parse and the
/// subcommand's `parse` receives `args[command_index + 1 ..]`, again starting
/// at its own index `0`. Each command's result is a `?View` field of `View`,
/// stored under the declaration field name prefixed with `_` (`_start`);
/// when no command token appears the field is `null`. Reach commands through
/// the namespace's `command` accessor rather than the raw `_`-prefixed field:
///
/// ```
/// const def = .{
///     .verbose = dap.Flag(bool){
///         .default = dap.Default(bool){ .direct = false },
///     },
///     .start = dap.Command(
///         .{ .help = "Start." },
///         .{ .name = dap.Argument([]const u8){} },
///     ),
///     .stop = dap.Command(.{ .help = "Stop." }, .{}),
/// };
///
/// const CLI = dap.generate(dap.App{ .name = "svc", .help = "Service." }, def);
/// var cli = try CLI.parse(allocator, environ, args, &diag);
/// if (CLI.command(cli)) |cmd| switch (cmd) {
///     .start => |s| try serve(s.name),
///     .stop => try shutdown(),
/// };
/// ```
///
/// An `Alt` field declares exclusive groups of parameters: a branch becomes
/// active once any of its flags is seen on the wire, and only one branch of
/// an `Alt` may be active. The generated field is a `?Union`: `null` when no
/// branch was seen, otherwise the active branch's payload struct. Each branch
/// becomes a help group named after its field or its `VariantNamed` override:
///
/// ```
/// const def = .{
///     .mode = dap.Alt(.{
///         .alt1 = .{
///             .opt1 = dap.Flag(u32){},
///         },
///         .alt2 = dap.VariantNamed("fancy-alt2", .{
///             .opt2 = dap.Flag([]const u8){},
///         }),
///     }),
/// };
///
/// const CLI = dap.generate(dap.App{ .name = "m", .help = "Mode." }, def);
/// var cli = try CLI.parse(allocator, environ, args, &diag);
/// switch (cli.mode orelse return) {
///     .alt1 => |p| try run(p.opt1),
///     .@"fancy-alt2" => |p| try fancy(p.opt2),
/// }
/// ```
///
/// Only flags are allowed inside branches and defaults are forbidden (a
/// default would imply implicit activation). Flag names, including short
/// aliases, must be unique across all branches and against the parent
/// declaration; a violation is a compile error. Passing flags from two
/// branches of the same `Alt` is a `ConflictingAlt` parse error.
///
/// A flag wrapped in `Optional(...)` (or written as a raw optional value,
/// `@as(?Flag(T), Flag(T){...})`) is *optional*: the generated field becomes
/// `?T` and is `null` when the flag is absent from `argv`, instead of failing
/// the required check. Optional flags must not declare a default (direct or
/// env), and their validation is skipped for a `null` value:
///
/// ```
/// const def = .{
///     .jobs = dap.Optional(dap.Flag(u32){ .short = "j" }),
/// };
///
/// const CLI = dap.generate(dap.App{ .name = "build", .help = "Build." }, def);
/// var cli = try CLI.parse(allocator, environ, args, &diag);
/// const jobs = cli.jobs orelse 1;
/// ```
///
/// Custom value types are supported when they expose
///
/// ```
/// pub fn decode(self: *Self, data: []const u8) dap.DecodeError!void
/// pub fn encode(self: *Self) []const u8
/// ```
///
/// The list of these methods is meant to grow (completions and such), but
/// these two are the stable contract. Builtin scalars, `dap.String`
/// (`[]const u8`) and `dap.Enumeration` results work out of the box.
/// Name of the builtin help flag injected into every declaration.
const builtin_help_field = "builtin_help";

/// The `-h, --help` flag specification injected at the very beginning of
/// every declaration before normalization, so `helpData` naturally sees it
/// via `inline for` and renders it in the flags section. In a merged
/// active-scope rendering it appears exactly once (the root's entry).
const BuiltinHelp = Flag(bool){
    .long = "help",
    .short = "h",
    .help = "Show context-sensitive help.",
    .i18n = "builtin.help",
    .default = defaultValue(bool, false),
};

/// The merged declaration type: `.builtin_help` at index 0 followed by the
/// user's fields in declaration order, each keeping its own default value.
fn MergedDecl(comptime D: type) type {
    const fields = @typeInfo(D).@"struct".fields;
    const MergedField = std.builtin.Type.StructField;
    const Builtin = @TypeOf(BuiltinHelp);

    const merged_names = blk: {
        var a: [1 + fields.len][:0]const u8 = undefined;
        a[0] = builtin_help_field;
        inline for (fields, 0..) |f, fi| a[1 + fi] = f.name;
        break :blk a;
    };
    const merged_types = blk: {
        var a: [1 + fields.len]type = undefined;
        a[0] = Builtin;
        inline for (fields, 0..) |f, fi| a[1 + fi] = f.type;
        break :blk a;
    };
    const attrs = blk: {
        var a: [1 + fields.len]MergedField.Attributes = undefined;
        a[0] = .{
            .@"align" = @alignOf(Builtin),
            .default_value_ptr = @ptrCast(&BuiltinHelp),
        };
        inline for (fields, 0..) |f, fi| {
            a[1 + fi] = .{
                .@"comptime" = f.is_comptime,
                .@"align" = f.alignment,
                .default_value_ptr = f.default_value_ptr,
            };
        }
        break :blk a;
    };

    return @Struct(.auto, null, &merged_names, &merged_types, &attrs);
}

/// Inject the `.builtin_help` field at the very beginning of a declaration
/// instance. The merged type carries the builtin specification at index 0;
/// the user's field values are copied over by name.
fn withBuiltinHelp(comptime decl: anytype) MergedDecl(@TypeOf(decl)) {
    comptime var result: MergedDecl(@TypeOf(decl)) = undefined;
    @field(result, builtin_help_field) = BuiltinHelp;
    inline for (@typeInfo(@TypeOf(decl)).@"struct".fields) |f| {
        @field(result, f.name) = @field(decl, f.name);
    }
    return result;
}

/// Render `help_data` with the app's configured renderer into a string owned
/// by `allocator`. `.compact` uses `HelpData.renderCompact`, `.custom` invokes
/// the user-provided function pointer payload.
fn renderHelpWithStyle(
    comptime style: HelpRendererStyle,
    allocator: std.mem.Allocator,
    help_data: *HelpData,
) std.mem.Allocator.Error!String {
    return switch (style) {
        .compact => help_data.renderCompact(allocator),
        .custom => |custom_fn| custom_fn(help_data, allocator),
    };
}

pub fn generate(comptime app: App, comptime def: anytype) type {
    @setEvalBranchQuota(1_000_000);
    const merged = withBuiltinHelp(def);
    const norm = normalize(merged);
    const all_specs = norm.specs;
    const cmd_entries = norm.commands;
    const alts = norm.alts;

    // Global flag-name uniqueness (D6): flags of every ancestor level merge
    // into a deep help scope, so a name reused anywhere in the command tree
    // would be ambiguous. Runs after `normalize`'s own checks so same-level
    // collisions keep their better existing messages.
    comptime checkGlobalFlagNames(collectFlagOrigins(norm, &[_]String{app.name}, &.{}));

    const field_names = blk: {
        var names: []const String = &.{};
        for (all_specs) |s| names = names ++ &[_]String{s.name};
        for (alts) |a| names = names ++ &[_]String{a.field};
        for (cmd_entries) |c| names = names ++ &[_]String{c.view_field};
        break :blk names;
    };
    const field_types = blk: {
        var ts: []const type = &.{};
        for (all_specs) |s| ts = ts ++ &[_]type{specViewType(s)};
        for (alts) |a| ts = ts ++ &[_]type{?a.AT.Union};
        for (cmd_entries) |c| ts = ts ++ &[_]type{?Sub(c.Cmd, subApp(app, c)).View};
        break :blk ts;
    };

    const Names = blk: {
        var a: [field_names.len]String = undefined;
        for (field_names, 0..) |nm, i| a[i] = nm;
        break :blk a;
    };
    const Types = blk: {
        var a: [field_types.len]type = undefined;
        for (field_types, 0..) |t, i| a[i] = t;
        break :blk a;
    };
    const Attrs = blk: {
        var a: [field_types.len]std.builtin.Type.StructField.Attributes = undefined;
        for (0..field_types.len) |i| a[i] = .{};
        break :blk a;
    };

    // Per-spec comptime constant: how many argument slots are declared before
    // this spec. Used to bind positional tokens to argument fields in order.
    const args_before = blk: {
        var a: [all_specs.len]usize = undefined;
        var n: usize = 0;
        for (all_specs, 0..) |s, i| {
            a[i] = n;
            if (s.kind == .argument) n += 1;
        }
        break :blk a;
    };
    const arg_count = blk: {
        var n: usize = 0;
        for (all_specs) |s| if (s.kind == .argument) {
            n += 1;
        };
        break :blk n;
    };

    // Distinct group names per kind, in first-seen declaration order. Flags
    // and arguments are grouped independently so an flag-only group does not
    // introduce an empty argument bucket.
    const group_names_of = struct {
        fn of(comptime kind: Kind) []const String {
            var names: []const String = &.{};
            for (all_specs) |s| {
                if (s.kind != kind) continue;
                if (s.group) |g| {
                    var found = false;
                    for (names) |n| if (std.mem.eql(u8, n, g)) {
                        found = true;
                    };
                    if (!found) names = names ++ &[_]String{g};
                }
            }
            return names;
        }
    }.of;
    const flag_group_names: []const String = group_names_of(.flag);
    const arg_group_names: []const String = group_names_of(.argument);

    // Specs partitioned by group; first entry is the ungrouped bucket. Drives
    // `helpData` ordering without runtime scans.
    const flag_specs: [1 + flag_group_names.len][]const Spec = blk: {
        var buckets: [1 + flag_group_names.len][]const Spec = @splat(&.{});
        for (all_specs) |s| {
            if (s.kind != .flag) continue;
            const bi: usize = if (s.group) |g| blk2: {
                for (flag_group_names, 0..) |nm, gi| {
                    if (std.mem.eql(u8, nm, g)) break :blk2 gi + 1;
                }
                unreachable;
            } else 0;
            buckets[bi] = buckets[bi] ++ &[_]Spec{s};
        }
        break :blk buckets;
    };

    const arg_specs: [1 + arg_group_names.len][]const Spec = blk: {
        var buckets: [1 + arg_group_names.len][]const Spec = @splat(&.{});
        for (all_specs) |s| {
            if (s.kind != .argument) continue;
            const bi: usize = if (s.group) |g| blk2: {
                for (arg_group_names, 0..) |nm, gi| {
                    if (std.mem.eql(u8, nm, g)) break :blk2 gi + 1;
                }
                unreachable;
            } else 0;
            buckets[bi] = buckets[bi] ++ &[_]Spec{s};
        }
        break :blk buckets;
    };

    const Base = struct {
        pub const app_meta = app;
        pub const specs = all_specs;
        pub const commands = cmd_entries;
        pub const View = @Struct(.auto, null, &Names, &Types, &Attrs);

        /// Fill a runtime [`HelpData`] description of this declaration. Every
        /// string and slice is allocated with `allocator`; release them with
        /// `HelpData.deinit`. Nothing here runs unless this or `helpText` is
        /// called.
        pub fn helpData(allocator: std.mem.Allocator) std.mem.Allocator.Error!HelpData {
            const name = try allocator.dupe(u8, app.name);
            errdefer allocator.free(name);
            const info = try allocator.dupe(u8, app.help);
            errdefer allocator.free(info);

            // Flag groups: entry 0 is the ungrouped bucket, the rest follow
            // `flag_group_names` in first-seen declaration order.
            const flag_groups = try allocator.alloc(HelpData.FlagGroup, 1 + flag_group_names.len);
            var og_filled: usize = 0;
            errdefer {
                freeFlagGroups(allocator, flag_groups[0..og_filled]);
                allocator.free(flag_groups);
            }

            inline for (flag_specs, 0..) |bucket, bi| {
                const list = try allocator.alloc(HelpData.Flag, bucket.len);
                var filled: usize = 0;
                errdefer {
                    freeFlags(allocator, list[0..filled]);
                    allocator.free(list);
                }
                inline for (bucket) |s| {
                    list[filled] = try fillFlag(allocator, s);
                    filled += 1;
                }
                const gname: ?String = if (bi == 0) null else try allocator.dupe(u8, flag_group_names[bi - 1]);
                flag_groups[bi] = .{ .name = gname, .flags = list };
                og_filled += 1;
            }

            // Argument groups: same rule (ungrouped first, then named groups).
            const arg_groups = try allocator.alloc(HelpData.ArgGroup, 1 + arg_group_names.len);
            var ag_filled: usize = 0;
            errdefer {
                freeArgGroups(allocator, arg_groups[0..ag_filled]);
                allocator.free(arg_groups);
            }

            inline for (arg_specs, 0..) |bucket, bi| {
                const list = try allocator.alloc(HelpData.Argument, bucket.len);
                var filled: usize = 0;
                errdefer {
                    freeArguments(allocator, list[0..filled]);
                    allocator.free(list);
                }
                inline for (bucket) |s| {
                    list[filled] = try fillArgument(allocator, s);
                    filled += 1;
                }
                const gname: ?String = if (bi == 0) null else try allocator.dupe(u8, arg_group_names[bi - 1]);
                arg_groups[bi] = .{ .name = gname, .args = list };
                ag_filled += 1;
            }

            const ncmds = cmd_entries.len;
            const cmd_infos = try allocator.alloc(HelpData.CommandInfo, ncmds);
            var cm_filled: usize = 0;
            errdefer {
                freeCommands(allocator, cmd_infos[0..cm_filled]);
                allocator.free(cmd_infos);
            }
            inline for (cmd_entries, 0..) |c, ci| {
                const cname_dup = try allocator.dupe(u8, c.name);
                errdefer allocator.free(cname_dup);
                const chelp = try allocator.dupe(u8, c.Cmd.cmd_meta.help);
                cmd_infos[ci] = .{ .name = cname_dup, .help = chelp };
                cm_filled += 1;
            }

            // Usage alternations: one clause per `Alt`, one branch-list per
            // tag. The branch lists reference the flag entries owned by
            // `flag_groups` (matched by `alt` field + `alt_branch` tag), so
            // only the outer arrays are owned here.
            const usage_alts = try allocator.alloc(HelpData.Usage, alts.len);
            var ua_complete: usize = 0;
            var ua_cur: ?[][]HelpData.Flag = null;
            var ua_cur_filled: usize = 0;
            errdefer {
                for (usage_alts[0..ua_complete]) |u| {
                    for (u.branches) |br| allocator.free(br);
                    allocator.free(u.branches);
                }
                if (ua_cur) |brs| {
                    for (brs[0..ua_cur_filled]) |br| allocator.free(br);
                    allocator.free(brs);
                }
                allocator.free(usage_alts);
            }
            inline for (alts, 0..) |a, ai| {
                const branches = try allocator.alloc([]HelpData.Flag, a.AT.tag_names.len);
                ua_cur = branches;
                ua_cur_filled = 0;
                inline for (a.AT.tag_names, 0..) |tag, bi| {
                    const matches = struct {
                        fn of(o: HelpData.Flag, field: String, t: String) bool {
                            if (o.alt) |av| {
                                if (!std.mem.eql(u8, av, field)) return false;
                            } else return false;
                            if (o.alt_branch) |bv| {
                                if (!std.mem.eql(u8, bv, t)) return false;
                            } else return false;
                            return true;
                        }
                    }.of;
                    var n: usize = 0;
                    for (flag_groups) |g| {
                        for (g.flags) |o| {
                            if (matches(o, a.field, tag)) n += 1;
                        }
                    }
                    const list = try allocator.alloc(HelpData.Flag, n);
                    branches[bi] = list;
                    ua_cur_filled += 1;
                    var fi: usize = 0;
                    for (flag_groups) |g| {
                        for (g.flags) |o| {
                            if (matches(o, a.field, tag)) {
                                list[fi] = o;
                                fi += 1;
                            }
                        }
                    }
                }
                usage_alts[ai] = .{ .branches = branches };
                ua_complete += 1;
                ua_cur = null;
                ua_cur_filled = 0;
            }

            return .{
                .name = name,
                .info = info,
                .flag_groups = flag_groups,
                .arg_groups = arg_groups,
                .usage_alts = usage_alts,
                .commands = cmd_infos,
                .highlight = app.help_renderer.highlight,
            };
        }

        /// Render human-readable help into a freshly allocated string. The
        /// caller owns it and frees it with the same allocator. The renderer
        /// follows `app.help_renderer.style`: `.compact` renders the kong-style
        /// two-column layout, `.custom` invokes the user-provided function.
        pub fn helpText(allocator: std.mem.Allocator) std.mem.Allocator.Error!String {
            return try helpTextWithStyle(allocator);
        }

        /// Print the context-sensitive help of a parsed `View` to stdout: the
        /// same text the builtin `-h`/`--help` intercept would print for the
        /// command chain activated in `view`. Rendering allocations use an
        /// internal allocator and are freed before returning; only a write to
        /// stdout is ignored, matching the parse intercept.
        ///
        /// ```
        /// const cli = try CLI.parse(arena.allocator(), environ, args, &diag);
        /// try CLI.usage(cli);
        /// ```
        pub fn usage(v: View) std.mem.Allocator.Error!void {
            const allocator = std.heap.page_allocator;
            const text = try contextHelpText(@This(), allocator, &v);
            defer allocator.free(text);
            var stdout_buffer: [0x1000]u8 = undefined;
            const stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(std.Options.debug_io, &stdout_buffer);
            stdout_writer.interface.print("{s}\n", .{text}) catch {};
            stdout_writer.interface.flush() catch {};
        }

        /// Render one flag entry into `HelpData`, duplicating every string.
        fn fillFlag(allocator: std.mem.Allocator, comptime s: Spec) std.mem.Allocator.Error!HelpData.Flag {
            const oname = try allocator.dupe(u8, s.long);
            errdefer allocator.free(oname);
            const ohelp = try allocator.dupe(u8, s.help);
            errdefer allocator.free(ohelp);
            var oshort: ?String = null;
            errdefer if (oshort) |sh| allocator.free(sh);
            if (s.short) |sh| oshort = try allocator.dupe(u8, sh);
            var odefault: ?String = null;
            errdefer if (odefault) |dv| allocator.free(dv);
            odefault = try renderDefault(allocator, s);
            var oalt: ?String = null;
            errdefer if (oalt) |av| allocator.free(av);
            if (s.alt) |av| oalt = try allocator.dupe(u8, av);
            var obranch: ?String = null;
            errdefer if (obranch) |bv| allocator.free(bv);
            if (s.alt_branch) |bv| obranch = try allocator.dupe(u8, bv);
            return .{ .name = oname, .short = oshort, .help = ohelp, .default = odefault, .takes_value = s.vtype != bool, .alt = oalt, .alt_branch = obranch, .optional = s.optional };
        }

        /// Render one positional argument entry into `HelpData`.
        fn fillArgument(allocator: std.mem.Allocator, comptime s: Spec) std.mem.Allocator.Error!HelpData.Argument {
            const aname = try allocator.dupe(u8, s.arg_name orelse s.name);
            errdefer allocator.free(aname);
            const ahelp = try allocator.dupe(u8, s.help);
            errdefer allocator.free(ahelp);
            var adefault: ?String = null;
            errdefer if (adefault) |dv| allocator.free(dv);
            adefault = try renderDefault(allocator, s);
            return .{ .name = aname, .help = ahelp, .default = adefault };
        }

        /// Render a spec's default value into an owned string, or `null` when
        /// the spec has no direct default (env-only defaults are not rendered).
        fn renderDefault(allocator: std.mem.Allocator, comptime s: Spec) std.mem.Allocator.Error!?String {
            const d = s.default orelse return null;
            if (s.vtype == String) return try allocator.dupe(u8, d.get([]const u8));
            if (@typeInfo(s.vtype) == .@"struct") {
                var tmp: s.vtype = d.get(s.vtype);
                return try allocator.dupe(u8, tmp.encode());
            }
            return try std.fmt.allocPrint(allocator, "{}", .{d.get(s.vtype)});
        }

        /// Print the parse diagnostics and the help text to stderr, then exit with
        /// code 1. The help text is freed before exiting. Write errors are
        /// ignored: there is no sensible fallback once stderr is gone, and
        /// `std.process.exit` must still run.
        fn printFailureExit(allocator: std.mem.Allocator, diag: ?*const Diag) noreturn {
            if (diag) |d| {
                if (d.field) |f| std.debug.print("error: field '{s}' is invalid or missing\n", .{f});
                if (d.token) |t| std.debug.print("error: token '{s}' is invalid\n", .{t});
                if (d.message) |m| std.debug.print("error: {s}\n", .{m});
            }
            if (helpTextWithStyle(allocator)) |text| {
                defer allocator.free(text);
                std.debug.print("{s}\n", .{text});
            } else |_| {}
            std.process.exit(1);
        }

        /// Fill the `HelpData` description of this declaration and render it with
        /// the app's configured renderer. The description is freed before
        /// returning; only the rendered string stays allocated.
        fn helpTextWithStyle(allocator: std.mem.Allocator) std.mem.Allocator.Error!String {
            var data = try helpData(allocator);
            defer data.deinit(allocator);
            return try renderHelpWithStyle(app.help_renderer.style, allocator, &data);
        }

        pub fn parse(allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8, diag: ?*Diag) ParseError!View {
            const result = parseInner(allocator, environ, args, diag) catch {
                printFailureExit(allocator, diag);
            };

            // HELP REQUESTED INTERCEPT: a requested help flag — at this level or
            // anywhere in the active command chain — bypassed every required
            // check and validation inside `parseInner`. Render the merged,
            // context-sensitive help with the app's renderer, print it to
            // stdout, and exit cleanly.
            if (helpRequested(@This(), &result)) {
                if (contextHelpText(@This(), allocator, &result)) |text| {
                    defer allocator.free(text);
                    var stdout_buffer: [0x1000]u8 = undefined;
                    const stdout_file = std.Io.File.stdout();
                    var stdout_writer = stdout_file.writer(std.Options.debug_io, &stdout_buffer);
                    stdout_writer.interface.print("{s}\n", .{text}) catch {};
                    stdout_writer.interface.flush() catch {};
                } else |_| {}
                std.process.exit(0);
            }

            return result;
        }

        /// The parse pipeline without the builtin help flow: scan the wire,
        /// intercept a requested help flag, resolve absent fields, validate.
        /// Errors propagate to the caller together with a filled `diag`;
        /// `parse` turns them into stderr diagnostics plus help text and a
        /// nonzero exit.
        fn parseInner(allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8, diag: ?*Diag) ParseError!View {
            return parseInnerHelp(allocator, environ, args, diag, false);
        }

        /// The parse pipeline. `ancestor_help` records that a help flag was seen on
        /// an ancestor level's wire before the handoff, so a deep command still
        /// honours the request (help token *before* the commands, D1) even though a
        /// plain sub-parse would otherwise fail its own required checks.
        fn parseInnerHelp(allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8, diag: ?*Diag, ancestor_help: bool) ParseError!View {
            if (diag) |d| d.* = .{};

            var v: View = undefined;
            var seen: [all_specs.len]bool = @splat(false);
            var pos: usize = 0;
            var handed_off = false;
            var help_seen = ancestor_help;

            // Phase 0: INIT. The builtin help flag starts false so the
            // post-loop intercept below can read it even when no wire token
            // mentioned it. Every Alt field starts `null` (no branch active);
            // a branch is materialized only when one of its members is seen.
            v.builtin_help = false;
            inline for (alts) |a| @field(v, a.field) = null;
            inline for (cmd_entries) |c| @field(v, c.view_field) = null;

            // Phase 1: SCAN
            var i: usize = 0;
            while (i < args.len and !handed_off) : (i += 1) {
                const tok = args[i];

                if (std.mem.eql(u8, tok, "--")) {
                    // Everything after `--` is a literal positional; the
                    // terminator also suppresses any handoff.
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try assignPositional(allocator, &v, &seen, &pos, args[i], diag);
                    }
                    break;
                }

                if (std.mem.startsWith(u8, tok, "--")) {
                    try consumeLongFlag(allocator, &v, &seen, args, &i, diag);
                    if (v.builtin_help) help_seen = true;
                } else if (tok.len > 1 and tok[0] == '-') {
                    try consumeShortFlag(allocator, &v, &seen, args, &i, diag);
                    if (v.builtin_help) help_seen = true;
                } else {
                    if (cmd_entries.len == 0) {
                        try assignPositional(allocator, &v, &seen, &pos, tok, diag);
                    } else {
                        // HANDOFF: a positional token equal to a registered
                        // command name is checked before POSITIONAL. The
                        // sub-parse receives the payload after the command
                        // token and again starts at its own index 0.
                        var matched = false;
                        inline for (cmd_entries) |c| {
                            if (std.mem.eql(u8, c.name, tok)) {
                                const S = Sub(c.Cmd, subApp(app, c));
                                @field(v, c.view_field) = try S.parseInnerHelp(allocator, environ, args[i + 1 ..], diag, help_seen);
                                handed_off = true;
                                matched = true;
                            }
                        }
                        if (!matched) {
                            try assignPositional(allocator, &v, &seen, &pos, tok, diag);
                        }
                    }
                }
            }

            // Phase 2: HELP. A requested help flag — at this level, anywhere in the
            // active command chain, or on an ancestor's wire before the
            // handoff — completely bypasses the required checks and post-parse
            // validations below; `parse` turns the early return into rendered
            // help on stdout and a clean exit.
            if (help_seen or helpRequested(@This(), &v)) {
                return v;
            }

            // Phase 1.5: ALT. For every Alt whose union was materialized (a
            // member was seen), require every member of the active branch and
            // run its validations. An untouched Alt stays `null` and is left
            // alone; exclusivity is enforced inside `assignValue`.
            inline for (alts) |a| {
                if (@field(v, a.field) != null) {
                    try validateAlt(all_specs, a.field, allocator, &v, &seen, diag);
                }
            }

            // Phase 3: POST-PASS. For every spec not seen during the scan, in
            // declaration order: env default, then direct default, then the
            // uniform required check, then a zero value. Alt members are
            // handled by Phase 1.5 and skipped here.
            inline for (all_specs, 0..) |s, si| {
                if (s.alt != null) continue;
                if (!seen[si]) {
                    try resolveAbsent(s, allocator, environ, &v, diag);
                }
            }

            // Phase 4: VALIDATE. Run each spec's validation fn over the final
            // value, regardless of whether it came from the wire, an env value
            // or a direct default. A non-null allocated message is stored in
            // `diag.message` (owned there) and reported as InvalidValue. Alt
            // members are validated by Phase 1.5.
            inline for (all_specs) |s| {
                if (s.alt != null) continue;
                if (s.validation) |vp| {
                    const vf: *const fn (std.mem.Allocator, s.vtype) std.mem.Allocator.Error!?String = @ptrCast(@alignCast(vp));
                    const maybe: ?s.vtype = if (comptime s.optional) @field(v, s.name) else @field(v, s.name);
                    const msg = if (maybe) |value| try vf(allocator, value) else null;
                    if (msg) |m| {
                        if (diag) |d| {
                            d.field = s.name;
                            d.message = m;
                        } else {
                            allocator.free(m);
                        }
                        return error.InvalidValue;
                    }
                }
            }

            return v;
        }

        fn consumeLongFlag(allocator: std.mem.Allocator, v: *View, seen: *[all_specs.len]bool, args: []const []const u8, i: *usize, diag: ?*Diag) ParseError!void {
            const tok = args[i.*];
            const body = tok[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const eqv: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            inline for (all_specs, 0..) |s, si| {
                if (s.kind == .flag and std.mem.eql(u8, s.long, name)) {
                    if (s.vtype == bool) {
                        try assignValue(s, View, allocator, v, seen, si, eqv orelse "true", diag);
                    } else if (eqv) |iv| {
                        try assignValue(s, View, allocator, v, seen, si, iv, diag);
                    } else {
                        if (i.* + 1 >= args.len) {
                            if (diag) |d| d.token = tok;
                            return error.MissingValue;
                        }
                        i.* += 1;
                        try assignValue(s, View, allocator, v, seen, si, args[i.*], diag);
                    }
                    return;
                }
            }

            if (diag) |d| d.token = tok;
            return error.UnknownFlag;
        }

        fn consumeShortFlag(allocator: std.mem.Allocator, v: *View, seen: *[all_specs.len]bool, args: []const []const u8, i: *usize, diag: ?*Diag) ParseError!void {
            const tok = args[i.*];
            const body = tok[1..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const eqv: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            inline for (all_specs, 0..) |s, si| {
                if (s.kind == .flag) {
                    if (s.short) |sh| {
                        if (std.mem.eql(u8, sh, name)) {
                            if (s.vtype == bool) {
                                try assignValue(s, View, allocator, v, seen, si, eqv orelse "true", diag);
                            } else if (eqv) |iv| {
                                try assignValue(s, View, allocator, v, seen, si, iv, diag);
                            } else {
                                if (i.* + 1 >= args.len) {
                                    if (diag) |d| d.token = tok;
                                    return error.MissingValue;
                                }
                                i.* += 1;
                                try assignValue(s, View, allocator, v, seen, si, args[i.*], diag);
                            }
                            return;
                        }
                    }
                }
            }

            if (diag) |d| d.token = tok;
            return error.UnknownFlag;
        }

        fn assignPositional(allocator: std.mem.Allocator, v: *View, seen: *[all_specs.len]bool, pos: *usize, tok: []const u8, diag: ?*Diag) ParseError!void {
            if (pos.* >= arg_count) {
                if (diag) |d| d.token = tok;
                return error.TooManyArguments;
            }
            inline for (all_specs, 0..) |s, si| {
                if (s.kind == .argument and args_before[si] == pos.* and !seen[si]) {
                    try assignValue(s, View, allocator, v, seen, si, tok, diag);
                    pos.* += 1;
                    return;
                }
            }
            if (diag) |d| d.token = tok;
            return error.TooManyArguments;
        }
    };

    // COMMAND ACCESS (D7): the accessor pair exists only when the level
    // declares subcommands; a commandless level returns the plain namespace.
    if (cmd_entries.len == 0) return Base;

    return struct {
        pub const app_meta = Base.app_meta;
        pub const specs = Base.specs;
        pub const commands = Base.commands;
        pub const View = Base.View;
        pub const parse = Base.parse;
        const parseInner = Base.parseInner;
        const parseInnerHelp = Base.parseInnerHelp;
        pub const helpData = Base.helpData;
        pub const helpText = Base.helpText;
        pub const usage = Base.usage;

        pub const CommandPayload = CommandPayloadOf(app, cmd_entries);

        /// D9/D10: wrap the active subcommand's View into the optional
        /// tagged union of this level's commands; `null` when no command
        /// field was activated.
        pub fn command(view: View) ?CommandPayload {
            inline for (cmd_entries) |c| {
                if (@field(view, c.view_field)) |sub| return @unionInit(CommandPayload, c.field, sub);
            }
            return null;
        }
    };
}

/// Wrapper generated for a single command. `app` carries the joined command
/// path as `App.name` (the usage anchor), the command's help and the app's
/// renderer configuration. Provides `View` (fields generated from the
/// command's declaration) and the symmetric `parse` entry point.
fn Sub(comptime Cmd: type, comptime app: App) type {
    return generate(app, Cmd.cmd_def);
}

/// The child app of one command entry: the command's wire name appended to
/// the parent's path anchor, its meta strings, the parent's renderer.
fn subApp(comptime parent: App, comptime c: CommandEntry) App {
    return .{
        .name = if (parent.name.len == 0) c.name else parent.name ++ " " ++ c.name,
        .help = c.Cmd.cmd_meta.help,
        .i18n = c.Cmd.cmd_meta.i18n,
        .help_renderer = parent.help_renderer,
    };
}

/// D8: the optional tagged union returned by the generated `command`
/// accessor: one member per command field, keyed by the plain declaration
/// field name (not the wire name nor the `_`-prefixed `View` field), its
/// payload the command's generated `View` — the same type the parent `View`
/// stores as `?View`. Synthesized only for levels that declare at least one
/// command.
fn CommandPayloadOf(comptime app: App, comptime cmd_entries: []const CommandEntry) type {
    const n = cmd_entries.len;
    const names: [n]String = blk: {
        var a: [n]String = undefined;
        for (cmd_entries, 0..) |c, i| a[i] = c.field;
        break :blk a;
    };
    const types: [n]type = blk: {
        var a: [n]type = undefined;
        for (cmd_entries, 0..) |c, i| a[i] = Sub(c.Cmd, subApp(app, c)).View;
        break :blk a;
    };
    const attrs: [n]std.builtin.Type.UnionField.Attributes = @splat(.{});
    const TagInt = std.math.IntFittingRange(0, n - 1);
    const Tag = @Enum(TagInt, .exhaustive, &names, blk: {
        var a: [n]TagInt = undefined;
        for (0..n) |i| a[i] = @intCast(i);
        break :blk &a;
    });
    return @Union(.auto, Tag, &names, &types, &attrs);
}

/// Normalized, comptime-only description of a single flag or argument.
const Spec = struct {
    name: String,
    kind: Kind,
    vtype: type,
    long: String,
    short: ?String,
    arg_name: ?String = null,
    required: bool,
    optional: bool = false,
    default: ?DefaultRepr,
    default_env: ?String,
    validation: ?*const anyopaque,
    help: String,
    i18n: ?String,
    group: ?String,
    /// When this spec is a member of an `Alt`, the *declaration field name* of
    /// the owning Alt. `null` for ordinary specs.
    alt: ?String = null,
    /// When this spec is a member of an `Alt`, the tag name of its branch.
    /// `null` for ordinary specs.
    alt_branch: ?String = null,
};

/// A type-erased pointer to a comptime default value. Recover the value with `get`.
const DefaultRepr = struct {
    ptr: *const anyopaque,

    fn get(self: DefaultRepr, comptime T: type) T {
        return @as(*const T, @ptrCast(@alignCast(self.ptr))).*;
    }
};

/// A single command declaration found at a given level. `field` is the
/// declaration field name (the `command` union tag); `view_field` is that
/// name prefixed with `_`, the field the parent `View` stores the sub-view
/// under; `name` is the wire name (`cmd_meta.name orelse field`); `Cmd` is
/// the type returned by `Command(...)`.
const CommandEntry = struct {
    field: String,
    view_field: String,
    name: String,
    Cmd: type,
};

/// An `Alt` declaration found at a given level. `field` is the declaration
/// field name; `AT` is the type returned by `Alt(...)`.
const AltLevel = struct {
    field: String,
    AT: type,
};

const NormResult = struct {
    specs: []const Spec,
    commands: []const CommandEntry,
    alts: []const AltLevel,
};

fn reprOf(comptime v: anytype) DefaultRepr {
    const Holder = struct {
        const value: @TypeOf(v) = v;
    };
    return .{ .ptr = @ptrCast(&Holder.value) };
}

fn fnToPtr(comptime vf: anytype) *const anyopaque {
    const Holder = struct {
        const fnptr: @TypeOf(vf) = vf;
    };
    return @ptrCast(&Holder.fnptr);
}

fn typeOfField(comptime f: std.builtin.Type.StructField) type {
    return @as(*const type, @ptrCast(@alignCast(f.default_value_ptr.?))).*;
}

fn instValue(comptime f: std.builtin.Type.StructField) *const f.type {
    return @ptrCast(@alignCast(f.default_value_ptr.?));
}

/// The inner (non-optional) declaration value of an optional-typed field.
fn instValueOpt(comptime f: std.builtin.Type.StructField, comptime I: type) *const I {
    const Holder = struct {
        const value: I = @as(*const f.type, @ptrCast(@alignCast(f.default_value_ptr.?))).*.?;
    };
    return &Holder.value;
}

fn declLong(comptime T: type, inst: *const T) ?String {
    if (@hasField(T, "long")) return inst.long;
    return null;
}

fn declShort(comptime T: type, inst: *const T) ?String {
    if (@hasField(T, "short")) return inst.short;
    return null;
}

fn declDefault(comptime T: type, inst: *const T) ?Default(T.dap_value_type) {
    if (@hasField(T, "default")) return inst.default;
    return null;
}

fn declValidation(comptime T: type, inst: *const T) ?fn (std.mem.Allocator, T.dap_value_type) std.mem.Allocator.Error!?String {
    if (@hasField(T, "validation")) return inst.validation;
    return null;
}

fn declHelp(comptime T: type, inst: *const T) String {
    if (@hasField(T, "help")) return inst.help;
    return "";
}

fn declArgName(comptime T: type, inst: *const T) ?String {
    if (@hasField(T, "name")) return inst.name;
    return null;
}

fn declI18n(comptime T: type, inst: *const T) ?String {
    if (@hasField(T, "i18n")) return inst.i18n;
    return null;
}

fn isDecodable(comptime T: type) bool {
    if (T == bool) return true;
    if (T == String) return true;
    switch (@typeInfo(T)) {
        .int, .float => return true,
        .pointer => |p| return p.size == .slice and p.child == u8,
        .@"struct" => return @hasDecl(T, "decode") and @hasDecl(T, "encode"),
        else => return false,
    }
}

const DecodeIntoTError = DecodeError || std.mem.Allocator.Error;

fn decodeBool(data: []const u8) DecodeError!bool {
    if (std.mem.eql(u8, data, "true") or std.mem.eql(u8, data, "1")) return true;
    if (std.mem.eql(u8, data, "false") or std.mem.eql(u8, data, "0")) return false;
    return error.InvalidWire;
}

/// Decode a single wire token into `out` according to the §6.4 table.
/// Builtin scalars, string slices and custom `decode`/`encode` structs are
/// supported; anything else is rejected at compile time.
fn decodeInto(comptime T: type, allocator: std.mem.Allocator, data: []const u8, out: *T) DecodeIntoTError!void {
    switch (@typeInfo(T)) {
        .bool => out.* = try decodeBool(data),
        .int => out.* = std.fmt.parseInt(T, data, 10) catch return error.InvalidWire,
        .float => out.* = std.fmt.parseFloat(T, data) catch return error.InvalidWire,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                out.* = try allocator.dupe(u8, data);
            } else {
                @compileError("pointer value type of '" ++ @typeName(T) ++ "' is not decodable by dap");
            }
        },
        .@"struct" => {
            var tmp: T = .{};
            try tmp.decode(data);
            out.* = tmp;
        },
        else => @compileError("type '" ++ @typeName(T) ++ "' is not decodable by dap"),
    }
}

/// Zero value for an optional field that is neither given on the wire nor
/// covered by an env/direct default. Owned string fields default to an empty
/// static slice (never allocated).
fn zeroValue(comptime T: type) T {
    if (@typeInfo(T) == .optional) return null;
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice and p.child == u8) return "",
        else => {},
    }
    return std.mem.zeroes(T);
}

/// The `View` field type for a spec: `?vtype` for optional specs, `vtype` otherwise.
fn specViewType(comptime s: Spec) type {
    return if (s.optional) ?s.vtype else s.vtype;
}

/// Assign a normalized direct (comptime) default to `out`. String slices are
/// copied with the caller's allocator so ownership stays uniform with values
/// decoded from the wire.
fn assignDirectDefault(comptime T: type, allocator: std.mem.Allocator, d: DefaultRepr, out: *T) std.mem.Allocator.Error!void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                out.* = try allocator.dupe(u8, d.get([]const u8));
                return;
            }
        },
        else => {},
    }
    out.* = d.get(T);
}

/// Decode `val` into the field named by comptime spec `s`, marking it seen.
/// Decode failures set `diag.field` and propagate.
///
/// For a member of an `Alt` the value is decoded into the active branch of the
/// owning `?Union` field: the union is materialized on the first member seen
/// (`@unionInit`) and a member from a different branch reported as
/// `ConflictingAlt`.
fn assignValue(
    comptime s: Spec,
    comptime V: type,
    allocator: std.mem.Allocator,
    v: *V,
    seen: []bool,
    si: usize,
    val: []const u8,
    diag: ?*Diag,
) ParseError!void {
    if (s.alt) |afield| {
        const MaybeUnion = @FieldType(V, afield);
        const UU = @typeInfo(MaybeUnion).optional.child;
        const TE = @typeInfo(UU).@"union".tag_type.?;
        const tag = @field(TE, s.alt_branch.?);
        if (@field(v.*, afield)) |*cur| {
            if (std.meta.activeTag(cur.*) != tag) {
                if (diag) |d| d.field = afield;
                return error.ConflictingAlt;
            }
        } else {
            @field(v.*, afield) = @unionInit(UU, s.alt_branch.?, undefined);
        }
        const slot: *UU = &@field(v.*, afield).?;
        decodeInto(s.vtype, allocator, val, &@field(@field(slot.*, s.alt_branch.?), s.name)) catch |e| {
            if (diag) |d| d.field = s.name;
            return e;
        };
        seen[si] = true;
        return;
    }

    if (s.optional) {
        var tmp: s.vtype = undefined;
        decodeInto(s.vtype, allocator, val, &tmp) catch |e| {
            if (diag) |d| d.field = s.name;
            return e;
        };
        @field(v.*, s.name) = tmp;
        seen[si] = true;
        return;
    }

    decodeInto(s.vtype, allocator, val, &@field(v.*, s.name)) catch |e| {
        if (diag) |d| d.field = s.name;
        return e;
    };
    seen[si] = true;
}

/// Validation of the active branch of one `Alt` after the wire scan. Every
/// member of the seen branches must be present (defaults are banned, so an
/// unseen member of an active branch is `MissingRequired`); each member's
/// validation fn then runs over the decoded value.
/// Whether a help flag fired anywhere in the active command chain: this
/// level's own `builtin_help` or, recursively, any activated sub-View's.
/// Only fields Phase 0 initializes are read, so it is safe on a view whose
/// scan ended in a handoff (unseen flag fields are still undefined).
fn helpRequested(comptime NS: type, v: anytype) bool {
    if (v.builtin_help) return true;
    inline for (NS.commands) |c| {
        if (@field(v, c.view_field)) |sub| {
            if (helpRequested(Sub(c.Cmd, subApp(NS.app_meta, c)), &sub)) return true;
        }
    }
    return false;
}

fn validateAlt(
    comptime specs: []const Spec,
    comptime afield: String,
    allocator: std.mem.Allocator,
    v: anytype,
    seen: []const bool,
    diag: ?*Diag,
) ParseError!void {
    const MaybeUnion = @FieldType(@TypeOf(v.*), afield);
    const UU = @typeInfo(MaybeUnion).optional.child;
    const TE = @typeInfo(UU).@"union".tag_type.?;
    const slot: *UU = &@field(v, afield).?;
    const active = std.meta.activeTag(slot.*);

    inline for (specs, 0..) |s, si| {
        const same_alt = comptime (s.alt != null and std.mem.eql(u8, s.alt.?, afield));
        if (comptime same_alt) {
            if (active == @field(TE, s.alt_branch.?)) {
                if (seen[si]) {
                    if (s.validation) |vp| {
                        const vf: *const fn (std.mem.Allocator, s.vtype) std.mem.Allocator.Error!?String = @ptrCast(@alignCast(vp));
                        const msg = try vf(allocator, @field(@field(slot.*, s.alt_branch.?), s.name));
                        if (msg) |m| {
                            if (diag) |d| {
                                d.field = s.name;
                                d.message = m;
                            } else {
                                allocator.free(m);
                            }
                            return error.InvalidValue;
                        }
                    }
                } else {
                    if (diag) |d| d.field = s.name;
                    return error.MissingRequired;
                }
            }
        }
    }
}

/// Errors the post-pass may report for an absent spec.
const ResolveAbsentError = error{ MissingRequired, InvalidWtf8 } || std.mem.Allocator.Error || DecodeError;

/// Runs the post-pass for a spec that no wire token filled, in declaration
/// order: an environment default, then a direct default, then the uniform
/// required check (flag/argument required iff it has no default), then a
/// zero value. On failure `diag.field` is set to the spec name.
fn resolveAbsent(
    comptime s: Spec,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    v: anytype,
    diag: ?*Diag,
) ResolveAbsentError!void {
    if (s.default_env) |key| {
        const raw: ?[]u8 = environ.getAlloc(allocator, key) catch |e| switch (e) {
            error.EnvironmentVariableMissing => null,
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => {
                if (diag) |d| d.field = s.name;
                return error.InvalidWtf8;
            },
        };
        if (raw) |val| {
            defer allocator.free(val);
            decodeInto(s.vtype, allocator, val, &@field(v, s.name)) catch |e| {
                if (diag) |d| d.field = s.name;
                return e;
            };
            return;
        }
    }
    if (s.default) |d| {
        assignDirectDefault(s.vtype, allocator, d, &@field(v, s.name)) catch return error.OutOfMemory;
        return;
    }
    if (s.required) {
        if (diag) |d| d.field = s.name;
        return error.MissingRequired;
    }
    @field(v, s.name) = zeroValue(specViewType(s));
}

fn specFromField(comptime f: std.builtin.Type.StructField) Spec {
    if (std.mem.startsWith(u8, f.name, "_")) {
        @compileError("declaration field name '" ++ f.name ++ "' must not start with '_'");
    }
    const Raw = f.type;
    const is_opt = @typeInfo(Raw) == .optional;
    const T = if (is_opt) @typeInfo(Raw).optional.child else Raw;

    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "dap_kind")) {
        @compileError("declaration field '" ++ f.name ++ "' must be a Flag or Argument");
    }

    const K = T.dap_kind;
    if (K != .flag and K != .argument) {
        @compileError("declaration field '" ++ f.name ++ "' must be a Flag or Argument");
    }

    if (is_opt and K != .flag) {
        @compileError("declaration field '" ++ f.name ++
            "': only flags can be optional (?Argument is not supported)");
    }

    const V = T.dap_value_type;
    if (!isDecodable(V)) {
        @compileError("value type of declaration field '" ++ f.name ++ "' is not decodable (needs decode/encode methods)");
    }
    const inst = if (is_opt) instValueOpt(f, T) else instValue(f);
    const defpair = declDefault(T, inst);
    if (is_opt and defpair != null) {
        @compileError("optional flag '" ++ f.name ++ "' must not declare a default");
    }
    // Boolean flags are semantically always optional: they implicitly default
    // to `false`, so a `true` direct default is meaningless and rejected. Use a
    // negative flag name defaulting to `false` instead.
    const bool_flag = K == .flag and V == bool;
    if (bool_flag) {
        if (defpair) |d| {
            if (d.direct) |dv| {
                if (dv == true) {
                    @compileError("Boolean flags cannot have a default value of 'true'. Use negative flag names (e.g., --no-something) defaulting to false instead.");
                }
            }
        }
    }

    const direct: ?DefaultRepr = if (defpair) |d| (if (d.direct) |dv| reprOf(dv) else null) else null;
    const env: ?String = if (defpair) |d| d.env else null;
    const vp: ?*const anyopaque = if (declValidation(T, inst)) |vf| fnToPtr(vf) else null;

    return .{
        .name = f.name,
        .kind = K,
        .vtype = V,
        .long = if (K == .flag) (declLong(T, inst) orelse f.name) else f.name,
        .short = if (K == .flag) declShort(T, inst) else null,
        .arg_name = if (K == .argument) declArgName(T, inst) else null,
        .required = (!bool_flag and !is_opt and direct == null and env == null),
        .optional = is_opt,
        .default = direct,
        .default_env = env,
        .validation = vp,
        .help = declHelp(T, inst),
        .i18n = declI18n(T, inst),
        .group = null,
    };
}

fn groupSpecs(comptime gdef: anytype, comptime gname: String) []const Spec {
    var out: []const Spec = &.{};
    inline for (@typeInfo(@TypeOf(gdef)).@"struct".fields) |f| {
        if (f.type == type) {
            @compileError("nested groups are not supported; group member '" ++ f.name ++ "' is a type");
        }
        var s = specFromField(f);
        s.group = gname;
        out = out ++ &[_]Spec{s};
    }
    return out;
}

/// Normalize every branch of an `Alt` into a flat spec list. Each member spec
/// keeps its branch's tag name as its help group and records the owning Alt
/// field plus its branch tag. Only flags are allowed and defaults are
/// forbidden (a default would imply implicit branch activation).
fn altSpecs(comptime AT: type, comptime field_name: String) []const Spec {
    var out: []const Spec = &.{};
    inline for (@typeInfo(@TypeOf(AT.alt_def)).@"struct".fields) |bf| {
        const Bv = @field(AT.alt_def, bf.name);
        const Bdef = if (@TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_def"))
            Bv.dap_variant_def
        else
            Bv;
        const tag = if (@TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_name"))
            Bv.dap_variant_name
        else
            bf.name;

        inline for (@typeInfo(@TypeOf(Bdef)).@"struct".fields) |mf| {
            var s = specFromField(mf);
            if (s.kind != .flag) {
                @compileError("Alt branch '" ++ bf.name ++ "' allows only flags; '" ++ mf.name ++ "' is not a Flag");
            }
            if (s.optional) {
                @compileError("Alt branch '" ++ bf.name ++ "' does not allow optional flags; '" ++
                    mf.name ++ "' is optional");
            }
            if (s.default != null or s.default_env != null) {
                @compileError("Alt flag '" ++ mf.name ++ "' must not declare a default");
            }
            s.group = tag;
            s.alt = field_name;
            s.alt_branch = tag;
            out = out ++ &[_]Spec{s};
        }
    }
    return out;
}

/// Reject declaration fields whose names start with `_`. The leading
/// underscore is reserved: command fields are surfaced in the `View` under a
/// `_`-prefixed name (the plain name is the branch of the `command` union).
/// Applies to the top level of every declaration, including command bodies,
/// which `normalize` recurses into; group and `Alt` members are checked where
/// their specs are built.
fn checkNoUnderscoreFields(comptime def: anytype) void {
    comptime {
        for (@typeInfo(@TypeOf(def)).@"struct".fields) |f| {
            if (std.mem.startsWith(u8, f.name, "_")) {
                @compileError("declaration field name '" ++ f.name ++ "' must not start with '_'");
            }
        }
    }
}

fn checkCommandNames(comptime commands: []const CommandEntry) void {
    comptime {
        for (commands, 0..) |a, i| {
            for (commands[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    @compileError("duplicate command name '" ++ a.name ++ "' on fields '" ++ a.field ++ "' and '" ++ b.field ++ "'");
                }
            }
        }
    }
}

fn checkCommandFieldNames(comptime specs: []const Spec, comptime commands: []const CommandEntry) void {
    comptime {
        for (commands) |c| {
            for (specs) |s| {
                if (std.mem.eql(u8, c.field, s.name)) {
                    @compileError("command field '" ++ c.field ++ "' collides with a flag or group member of the same name");
                }
            }
        }
    }
}

/// Mixing subcommands with positional arguments is ambiguous: once a command
/// token is seen the remaining tokens are handed off to the subcommand, so a
/// parent-level positional could never be filled. Reject the combination.
fn checkCommandArgumentMix(comptime specs: []const Spec, comptime commands: []const CommandEntry) void {
    comptime {
        if (commands.len == 0) return;
        for (specs) |s| {
            if (s.kind == .argument) {
                @compileError("declaration mixes subcommands with positional argument '" ++ s.name ++
                    "'; a declaration may have commands or positional arguments, not both");
            }
        }
    }
}

fn checkDuplicates(comptime specs: []const Spec) void {
    comptime {
        for (specs, 0..) |a, i| {
            if (a.kind != .flag) continue;
            for (specs[i + 1 ..]) |b| {
                if (b.kind != .flag) continue;
                if (std.mem.eql(u8, a.long, b.long)) {
                    @compileError("duplicate long flag '--" ++ a.long ++ "' on fields '" ++ a.name ++ "' and '" ++ b.name ++ "'");
                }
            }
            if (a.short) |sa| {
                for (specs[i + 1 ..]) |b| {
                    if (b.short) |sb| {
                        if (std.mem.eql(u8, sa, sb)) {
                            @compileError("duplicate short flag '-" ++ sa ++ "' on fields '" ++ a.name ++ "' and '" ++ b.name ++ "'");
                        }
                    }
                }
            }
        }
    }
}

fn checkFieldNames(comptime specs: []const Spec) void {
    comptime {
        for (specs, 0..) |a, i| {
            for (specs[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    @compileError("duplicate field name '" ++ a.name ++ "' (from a group member or another declaration)");
                }
            }
        }
    }
}

fn checkArgumentDefaults(comptime specs: []const Spec) void {
    comptime {
        for (specs, 0..) |a, i| {
            if (a.kind != .argument) continue;
            const has_default = (a.default != null or a.default_env != null);
            if (!has_default) continue;
            for (specs[i + 1 ..]) |b| {
                if (b.kind == .argument) {
                    @compileError("argument '" ++ a.name ++ "' has a default but is not the last argument");
                }
            }
        }
    }
}

/// Reject two group declarations that share a name. Groups are introduced by a
/// `Group` field (one name) or by an `Alt` (one name per branch tag). Members
/// of the same group legitimately share the name, so the check runs over the
/// distinct declaration names, not over the flattened specs. Arguments live in
/// a separate namespace and are not considered.
fn checkGroupDefs(comptime names: []const String) void {
    comptime {
        for (names, 0..) |a, i| {
            if (a.len == 0) continue;
            for (names[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a, b)) {
                    @compileError("duplicate group name '" ++ a ++ "'");
                }
            }
        }
    }
}

/// The wire name of a command: `cmd_meta.name` when set, the declaration
/// field name otherwise.
fn commandWireName(comptime meta: CommandMeta, comptime field: String) String {
    return meta.name orelse field;
}

/// The `View` field name of a command: the declaration field name prefixed
/// with `_`. Command fields are hidden behind this prefix in the `View`
/// (`_stop`), while the `command` union keeps the plain declaration name
/// (`stop`). Consumers reach commands through `namespace.command`.
fn viewCommandField(comptime field: String) String {
    return "_" ++ field;
}

/// One flag discovered somewhere in the declaration tree, together with the
/// level path it lives at. Drives the global uniqueness check (D6).
const FlagOrigin = struct {
    long: String,
    short: ?String,
    field: String,
    path: []const String,
};

/// Join a level path with single spaces for diagnostics.
fn levelPath(comptime path: []const String) String {
    comptime {
        var out: String = "";
        for (path, 0..) |seg, i| {
            if (i != 0) out = out ++ " ";
            out = out ++ seg;
        }
        return out;
    }
}

/// Flatten the whole declaration tree into a table of flag origins, walking
/// levels through `normalize` exactly as `generate` does (groups and `Alt`
/// branches flatten into `norm.specs` for free). The injected builtin help
/// flag and positional arguments are excluded (D6): the builtin is present at
/// every level by design, and arguments only ever render at the deepest level.
fn collectFlagOrigins(
    comptime norm: NormResult,
    comptime path: []const String,
    comptime acc: []const FlagOrigin,
) []const FlagOrigin {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out = acc;
        for (norm.specs) |s| {
            if (s.kind != .flag) continue;
            if (std.mem.eql(u8, s.name, builtin_help_field)) continue;
            out = out ++ &[_]FlagOrigin{.{
                .long = s.long,
                .short = s.short,
                .field = s.name,
                .path = path,
            }};
        }
        for (norm.commands) |c| {
            const child = normalize(withBuiltinHelp(c.Cmd.cmd_def));
            out = collectFlagOrigins(child, path ++ &[_]String{c.name}, out);
        }
        return out;
    }
}

/// Pairwise long/short uniqueness over the flattened tree, reporting both
/// level paths in the message. Flags of every ancestor level merge into a
/// deep help scope, so a name reused anywhere in the command tree would be
/// ambiguous; sibling commands are covered too (D6).
fn checkGlobalFlagNames(comptime origins: []const FlagOrigin) void {
    comptime {
        for (origins, 0..) |a, i| {
            for (origins[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.long, b.long)) {
                    @compileError("duplicate long flag '--" ++ a.long ++ "' at '" ++ levelPath(a.path) ++
                        "' and '" ++ levelPath(b.path) ++ "'; flag names must be globally unique " ++
                        "across the command tree (fields '" ++ a.field ++ "' / '" ++ b.field ++ "')");
                }
            }
            if (a.short) |sa| {
                for (origins[i + 1 ..]) |b| {
                    if (b.short) |sb| {
                        if (std.mem.eql(u8, sa, sb)) {
                            @compileError("duplicate short flag '-" ++ sa ++ "' at '" ++ levelPath(a.path) ++
                                "' and '" ++ levelPath(b.path) ++ "'; flag names must be globally unique " ++
                                "across the command tree (fields '" ++ a.field ++ "' / '" ++ b.field ++ "')");
                        }
                    }
                }
            }
        }
    }
}

fn normalize(comptime def: anytype) NormResult {
    comptime checkNoUnderscoreFields(def);
    var specs: []const Spec = &.{};
    var commands: []const CommandEntry = &.{};
    var alts: []const AltLevel = &.{};
    var group_names: []const String = &.{};

    inline for (@typeInfo(@TypeOf(def)).@"struct".fields) |f| {
        if (f.type == type) {
            const V = typeOfField(f);
            if (@hasDecl(V, "dap_kind") and V.dap_kind == .command) {
                commands = commands ++ &[_]CommandEntry{.{
                    .field = f.name,
                    .view_field = viewCommandField(f.name),
                    .name = commandWireName(V.cmd_meta, f.name),
                    .Cmd = V,
                }};
            } else if (@hasDecl(V, "dap_kind") and V.dap_kind == .group) {
                specs = specs ++ groupSpecs(V.group_def, V.group_name);
                group_names = group_names ++ &[_]String{V.group_name};
            } else if (@hasDecl(V, "dap_kind") and V.dap_kind == .alt) {
                specs = specs ++ altSpecs(V, f.name);
                alts = alts ++ &[_]AltLevel{.{ .field = f.name, .AT = V }};
                inline for (V.tag_names) |tn| group_names = group_names ++ &[_]String{tn};
            } else {
                @compileError("unknown type-valued declaration field '" ++ f.name ++ "'");
            }
        } else {
            specs = specs ++ &[_]Spec{specFromField(f)};
        }
    }

    checkDuplicates(specs);
    checkFieldNames(specs);
    checkArgumentDefaults(specs);
    checkGroupDefs(group_names);
    checkCommandNames(commands);
    checkCommandFieldNames(specs, commands);
    checkCommandArgumentMix(specs, commands);

    return .{ .specs = specs, .commands = commands, .alts = alts };
}

test "doc example declaration compiles" {
    const def = .{
        .login = Flag([]const u8){
            .short = "l",
            .default = Default(String){
                .env = "USER",
            },
            .validation = Validate.stringNotEmpty,
            .help = "User login.",
        },
        .password = Flag([]const u8){
            .short = "p",
            .validation = Validate.stringNotEmpty,
            .help = "Password for the given login.",
        },
        .verbosity = Flag(u8){
            .short = "V",
            .validation = Validate.intNotZero(u8),
            .help = "Verbosity level.",
        },
        .path = Argument([]const u8){
            .validation = Validate.stringNotEmpty,
            .help = "Path of the file to download",
        },
    };

    const CLI = generate(
        App{
            .name = "api-downloader",
            .help = "Download a file with a given path from API stand.",
        },
        def,
    );
    _ = CLI;
}

test "flag field defaults" {
    const o = Flag(u8){ .help = "x" };
    try std.testing.expect(o.long == null);
    try std.testing.expect(o.short == null);
    try std.testing.expect(o.default == null);
    try std.testing.expect(o.validation == null);
    try std.testing.expect(o.i18n == null);
    try std.testing.expectEqualStrings("x", o.help);
    try std.testing.expect(Flag(u8).dap_kind == .flag);
    try std.testing.expect(Flag(u8).dap_value_type == u8);
}

test "argument field defaults" {
    const a = Argument([]const u8){ .help = "y" };
    try std.testing.expect(a.name == null);
    try std.testing.expect(a.default == null);
    try std.testing.expect(a.validation == null);
    try std.testing.expect(a.i18n == null);
    try std.testing.expectEqualStrings("y", a.help);
    try std.testing.expect(Argument([]const u8).dap_kind == .argument);
    try std.testing.expect(Argument([]const u8).dap_value_type == []const u8);
}

test "app defaults" {
    const a = App{ .name = "n", .help = "h" };
    try std.testing.expect(a.i18n == null);
    try std.testing.expectEqualStrings("n", a.name);
    try std.testing.expectEqualStrings("h", a.help);
}

test "default fields default" {
    const d = Default(u8){};
    try std.testing.expect(d.direct == null);
    try std.testing.expect(d.env == null);
}

test "group and commands declarations compile" {
    const def = .{
        .host = Flag([]const u8){ .help = "Host" },
        .server = Group(.{
            .port = Flag(u16){ .help = "Port" },
        }, "Server"),
        .start = Command(.{ .help = "Start" }, .{
            .name = Argument([]const u8){ .help = "Name" },
        }),
    };
    _ = def;
    try std.testing.expect(Group(.{}, "G").dap_kind == .group);
    try std.testing.expect(Command(CommandMeta{}, .{}).dap_kind == .command);
}

test "alt declaration compiles" {
    const def = .{
        .mode = Alt(.{
            .alt1 = .{
                .opt1 = Flag([]const u8){ .help = "First flag." },
            },
            .alt2 = VariantNamed("fancy-alt2", .{
                .opt2 = Flag(u32){ .help = "Second flag." },
            }),
        }),
    };
    _ = def;
    const A = Alt(.{ .a = .{ .x = Flag(u8){} } });
    try std.testing.expect(A.dap_kind == .alt);
    try std.testing.expectEqualStrings("a", A.tag_names[0]);
    try std.testing.expectEqualStrings("a", A.branch_names[0]);
    try std.testing.expectEqualStrings("x", @typeInfo(A.branch_types[0]).@"struct".fields[0].name);
    try std.testing.expectEqualStrings("fancy-alt2", VariantNamed("fancy-alt2", .{}).dap_variant_name);
}

test "enumeration and enum defaults" {
    const e = Enum{};
    try std.testing.expect(e.name == null);
    try std.testing.expect(e.i18n == null);
    try std.testing.expectEqualStrings("", e.help);

    const m = CommandMeta{};
    try std.testing.expect(m.name == null);
    try std.testing.expect(m.i18n == null);
    try std.testing.expectEqualStrings("", m.help);

    _ = Enumeration(.{});
}

test "decode error is an error set" {
    const e: DecodeError = error.InvalidWire;
    try std.testing.expect(e == error.InvalidWire);
    const v: DecodeError = error.InvalidValue;
    try std.testing.expect(v == error.InvalidValue);
}

test "validate helpers" {
    const allocator = std.testing.allocator;

    try std.testing.expect(try Validate.stringNotEmpty(allocator, "abc") == null);
    const empty_msg = try Validate.stringNotEmpty(allocator, "");
    defer allocator.free(empty_msg.?);
    try std.testing.expect(empty_msg != null);

    const int_check = Validate.intNotZero(u8);
    try std.testing.expect(try int_check(allocator, 1) == null);
    const zero_msg = try int_check(allocator, 0);
    defer allocator.free(zero_msg.?);
    try std.testing.expect(zero_msg != null);
}

const M1Def = .{
    .login = Flag([]const u8){
        .short = "l",
        .default = Default(String){ .env = "USER" },
        .validation = Validate.stringNotEmpty,
        .help = "User login.",
    },
    .password = Flag([]const u8){
        .short = "p",
        .validation = Validate.stringNotEmpty,
        .help = "Password.",
    },
    .verbosity = Flag(u8){
        .short = "V",
        .default = Default(u8){ .direct = 3 },
        .help = "Verbosity.",
    },
    .dry_run = Flag(bool){
        .long = "dry-run",
        .default = Default(bool){ .direct = false },
    },
    .server = Group(.{
        .port = Flag(u16){
            .short = "P",
            .default = Default(u16){ .direct = 8080 },
        },
        .host = Flag([]const u8){ .help = "Host." },
    }, "Server"),
    .path = Argument([]const u8){
        .validation = Validate.stringNotEmpty,
        .help = "Path.",
    },
    .output = Argument([]const u8){
        .default = Default([]const u8){ .direct = "stdout" },
    },
};

const M1CmdDef = .{
    .login = Flag([]const u8){
        .short = "l",
        .default = Default(String){ .env = "USER" },
        .validation = Validate.stringNotEmpty,
        .help = "User login.",
    },
    .password = Flag([]const u8){
        .short = "p",
        .validation = Validate.stringNotEmpty,
        .help = "Password.",
    },
    .verbosity = Flag(u8){
        .short = "V",
        .default = Default(u8){ .direct = 3 },
        .help = "Verbosity.",
    },
    .dry_run = Flag(bool){
        .long = "dry-run",
        .default = Default(bool){ .direct = false },
    },
    .server = Group(.{
        .port = Flag(u16){
            .short = "P",
            .default = Default(u16){ .direct = 8080 },
        },
        .host = Flag([]const u8){ .help = "Host." },
    }, "Server"),
    .start = Command(.{ .help = "Start." }, .{
        .name = Argument([]const u8){ .help = "Name." },
    }),
    .stop = Command(.{ .name = "halt", .help = "Stop." }, .{}),
};

test "M1: normalize spec contents" {
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    const specs = C.specs;

    try std.testing.expectEqual(@as(usize, 9), specs.len);

    // builtin_help: injected at the very front of every declaration.
    try std.testing.expectEqualStrings("builtin_help", specs[0].name);
    try std.testing.expect(specs[0].kind == .flag);
    try std.testing.expect(specs[0].vtype == bool);
    try std.testing.expectEqualStrings("help", specs[0].long);
    try std.testing.expectEqualStrings("h", specs[0].short.?);
    try std.testing.expect(!specs[0].required);
    try std.testing.expectEqual(false, specs[0].default.?.get(bool));
    try std.testing.expectEqualStrings("Show context-sensitive help.", specs[0].help);
    try std.testing.expectEqualStrings("builtin.help", specs[0].i18n.?);

    // login: env default, required derived false, verbatim long from field.
    try std.testing.expectEqualStrings("login", specs[1].name);
    try std.testing.expect(specs[1].kind == .flag);
    try std.testing.expect(specs[1].vtype == []const u8);
    try std.testing.expectEqualStrings("login", specs[1].long);
    try std.testing.expectEqualStrings("l", specs[1].short.?);
    try std.testing.expect(!specs[1].required);
    try std.testing.expect(specs[1].default == null);
    try std.testing.expectEqualStrings("USER", specs[1].default_env.?);
    try std.testing.expect(specs[1].validation != null);

    // password: no default => required.
    try std.testing.expectEqualStrings("password", specs[2].name);
    try std.testing.expect(specs[2].required);
    try std.testing.expect(specs[2].default == null);
    try std.testing.expect(specs[2].default_env == null);

    // verbosity: direct default recovers typed value.
    try std.testing.expect(!specs[3].required);
    try std.testing.expectEqual(@as(u8, 3), specs[3].default.?.get(u8));

    // dry_run: explicit long overrides verbatim field name.
    try std.testing.expectEqualStrings("dry_run", specs[4].name);
    try std.testing.expectEqualStrings("dry-run", specs[4].long);
    try std.testing.expect(!specs[4].required);
    try std.testing.expectEqual(false, specs[4].default.?.get(bool));

    // group flattened in declaration order with group label.
    try std.testing.expectEqualStrings("port", specs[5].name);
    try std.testing.expectEqualStrings("Server", specs[5].group.?);
    try std.testing.expectEqual(@as(u16, 8080), specs[5].default.?.get(u16));
    try std.testing.expectEqualStrings("host", specs[6].name);
    try std.testing.expectEqualStrings("Server", specs[6].group.?);
    try std.testing.expect(specs[6].required);

    // arguments: required, then defaulted-last.
    try std.testing.expect(specs[7].kind == .argument);
    try std.testing.expectEqualStrings("path", specs[7].name);
    try std.testing.expect(specs[7].required);
    try std.testing.expect(specs[8].kind == .argument);
    try std.testing.expect(!specs[8].required);
    try std.testing.expectEqualStrings("stdout", specs[8].default.?.get([]const u8));
}

test "M1: commands level detected" {
    const C = generate(App{ .name = "app", .help = "help" }, M1CmdDef);
    try std.testing.expectEqual(@as(usize, 2), C.commands.len);
    try std.testing.expectEqualStrings("start", C.commands[0].field);
    try std.testing.expectEqualStrings("_start", C.commands[0].view_field);
    try std.testing.expectEqualStrings("start", C.commands[0].name);
    try std.testing.expectEqualStrings("stop", C.commands[1].field);
    try std.testing.expectEqualStrings("_stop", C.commands[1].view_field);
    try std.testing.expectEqualStrings("halt", C.commands[1].name);
    try std.testing.expect(C.commands[0].Cmd.dap_kind == .command);
}

test "M1: def without commands reports empty" {
    const C = generate(App{ .name = "app", .help = "help" }, .{
        .x = Flag(u8){ .default = Default(u8){ .direct = 0 } },
    });
    try std.testing.expectEqual(@as(usize, 0), C.commands.len);
    try std.testing.expectEqual(@as(usize, 2), C.specs.len);
    try std.testing.expectEqualStrings("builtin_help", C.specs[0].name);
    try std.testing.expectEqualStrings("x", C.specs[1].name);
}

test "M1: validation pointer round-trips" {
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    const vp = C.specs[1].validation.?;
    const f: *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!?String = @ptrCast(@alignCast(vp));
    try std.testing.expect(try f(std.testing.allocator, "ok") == null);
    const msg = try f(std.testing.allocator, "");
    defer std.testing.allocator.free(msg.?);
    try std.testing.expect(msg != null);
}

// M1 negative cases. Zig has no compile-fail harness; flip the body of the
// relevant test to exercise a @compileError, then restore.
test "M1: duplicate long names are a compile error" {
    if (false) {
        const Bad = .{
            .a = Flag(u8){ .long = "same" },
            .b = Flag(u8){ .long = "same" },
        };
        comptime _ = normalize(Bad);
    }
}

test "M1: duplicate short names are a compile error" {
    if (false) {
        const Bad = .{
            .a = Flag(u8){ .short = "s" },
            .b = Flag(u8){ .short = "s" },
        };
        comptime _ = normalize(Bad);
    }
}

test "M1: multiple command fields are legal" {
    const C = generate(App{ .name = "app", .help = "" }, .{
        .start = Command(.{ .help = "Start." }, .{}),
        .stop = Command(.{ .name = "halt", .help = "Stop." }, .{}),
    });
    try std.testing.expectEqual(@as(usize, 2), C.commands.len);
    try std.testing.expectEqualStrings("start", C.commands[0].field);
    try std.testing.expectEqualStrings("stop", C.commands[1].field);
}

test "M1: command view fields carry an underscore prefix" {
    const C = generate(App{ .name = "app", .help = "" }, .{
        .start = Command(.{ .help = "Start." }, .{}),
        .stop = Command(.{ .name = "halt", .help = "Stop." }, .{}),
    });
    try std.testing.expectEqualStrings("_start", C.commands[0].view_field);
    try std.testing.expectEqualStrings("_stop", C.commands[1].view_field);
}

test "M1: an underscore-prefixed declaration field is a compile error" {
    if (false) {
        const Bad = .{
            ._hidden = Flag(u8){},
        };
        comptime _ = normalize(Bad);
    }
}

test "M1: duplicate command names are a compile error" {
    if (false) {
        const Bad = .{
            .a = Command(.{ .name = "same" }, .{}),
            .b = Command(.{ .name = "same" }, .{}),
        };
        comptime _ = normalize(Bad);
    }
}

test "M1: command field colliding with a flag name is a compile error" {
    if (false) {
        const Bad = .{
            .grp = Group(.{ .serve = Flag(u8){} }, "g"),
            .serve = Command(.{ .help = "Serve." }, .{}),
        };
        comptime _ = normalize(Bad);
    }
}

test "M1: mixing commands and positional arguments is a compile error" {
    if (false) {
        const Bad = .{
            .path = Argument([]const u8){},
            .start = Command(.{ .help = "Start." }, .{}),
        };
        comptime _ = normalize(Bad);
    }
}

test "M1: anonymous CommandMeta literal compiles" {
    const C = generate(App{ .name = "app", .help = "" }, .{
        .start = Command(.{ .name = "go", .help = "Go." }, .{}),
    });
    try std.testing.expectEqualStrings("go", C.commands[0].name);
    try std.testing.expectEqualStrings("Go.", C.commands[0].Cmd.cmd_meta.help);
}

test "M1: argument default not last is a compile error" {
    if (false) {
        const Bad = .{
            .first = Argument(u8){ .default = Default(u8){ .direct = 1 } },
            .second = Argument(u8){},
        };
        comptime _ = normalize(Bad);
    }
}

test "M1: undecodable value type is a compile error" {
    if (false) {
        const Bad = .{
            .x = Flag(struct { z: u8 }){},
        };
        comptime _ = normalize(Bad);
    }
}

test "M2: View field order and types" {
    const C = generate(App{ .name = "app", .help = "help" }, M1CmdDef);
    const V = C.View;
    const fields = @typeInfo(V).@"struct".fields;

    // 7 specs (builtin_help injected first) + 2 command fields.
    try std.testing.expectEqual(@as(usize, 9), fields.len);

    try std.testing.expectEqualStrings("builtin_help", fields[0].name);
    try std.testing.expectEqual(@as(type, bool), fields[0].type);
    try std.testing.expectEqualStrings("login", fields[1].name);
    try std.testing.expectEqual(@as(type, []const u8), fields[1].type);
    try std.testing.expectEqualStrings("password", fields[2].name);
    try std.testing.expectEqual(@as(type, []const u8), fields[2].type);
    try std.testing.expectEqualStrings("verbosity", fields[3].name);
    try std.testing.expectEqual(@as(type, u8), fields[3].type);
    try std.testing.expectEqualStrings("dry_run", fields[4].name);
    try std.testing.expectEqual(@as(type, bool), fields[4].type);

    // group flattening preserves declaration order and names.
    try std.testing.expectEqualStrings("port", fields[5].name);
    try std.testing.expectEqual(@as(type, u16), fields[5].type);
    try std.testing.expectEqualStrings("host", fields[6].name);
    try std.testing.expectEqual(@as(type, []const u8), fields[6].type);

    // trailing command fields are optional sub-Views, hidden behind a `_`
    // prefix.
    try std.testing.expectEqualStrings("_start", fields[7].name);
    try std.testing.expect(@typeInfo(fields[7].type) == .optional);
    try std.testing.expect(@typeInfo(@typeInfo(fields[7].type).optional.child) == .@"struct");
    try std.testing.expectEqualStrings("_stop", fields[8].name);
    try std.testing.expect(@typeInfo(fields[8].type) == .optional);
    try std.testing.expect(@typeInfo(@typeInfo(fields[8].type).optional.child) == .@"struct");
}

test "M2: @FieldType matches specs" {
    const C = generate(App{ .name = "app", .help = "help" }, M1CmdDef);
    const V = C.View;

    inline for (C.specs) |s| {
        try std.testing.expectEqual(@as(type, s.vtype), @FieldType(V, s.name));
    }
    inline for (C.commands) |c| {
        const T = @FieldType(V, c.view_field);
        try std.testing.expect(@typeInfo(T) == .optional);
        try std.testing.expectEqual(@as(type, ?Sub(c.Cmd, subApp(C.app_meta, c)).View), T);
    }
}

test "M2: View without commands has only spec fields" {
    const C = generate(App{ .name = "app", .help = "help" }, .{
        .a = Flag(u8){ .default = Default(u8){ .direct = 0 } },
        .b = Argument([]const u8){},
    });
    const fields = @typeInfo(C.View).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("builtin_help", fields[0].name);
    try std.testing.expectEqual(@as(type, bool), fields[0].type);
    try std.testing.expectEqualStrings("a", fields[1].name);
    try std.testing.expectEqual(@as(type, u8), fields[1].type);
    try std.testing.expectEqualStrings("b", fields[2].name);
    try std.testing.expectEqual(@as(type, []const u8), fields[2].type);
}

test "M2: command View fields are optional sub-views" {
    const C = generate(App{ .name = "app", .help = "help" }, M1CmdDef);

    try std.testing.expectEqual(@as(usize, 2), C.commands.len);

    // each command field's View payload is the command's generated View; the
    // injected builtin_help field occupies the first slot of every sub. Command
    // fields carry a `_` prefix in the View.
    const StartSub = @typeInfo(@FieldType(C.View, "_start")).optional.child;
    const start_fields = @typeInfo(StartSub).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), start_fields.len);
    try std.testing.expectEqualStrings("builtin_help", start_fields[0].name);
    try std.testing.expectEqualStrings("name", start_fields[1].name);

    const HaltSub = @typeInfo(@FieldType(C.View, "_stop")).optional.child;
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(HaltSub).@"struct".fields.len);

    // the sub level has no commands of its own.
    const StartNs = Sub(C.commands[0].Cmd, subApp(C.app_meta, C.commands[0]));
    try std.testing.expectEqual(@as(usize, 0), StartNs.commands.len);
}

test "M2: View is a fully usable struct" {
    const C = generate(App{ .name = "app", .help = "help" }, M1CmdDef);
    var v: C.View = undefined;
    v.builtin_help = false;
    v.login = "bob";
    v.password = "pw";
    v.verbosity = 3;
    v.dry_run = false;
    v.port = 8080;
    v.host = "localhost";
    v._start = null;
    v._stop = null;

    try std.testing.expectEqualStrings("bob", v.login);
    try std.testing.expect(v._start == null);
}

const DecodeOk = struct {
    value: u32 = 0,

    pub fn decode(self: *DecodeOk, data: []const u8) DecodeError!void {
        self.value = std.fmt.parseInt(u32, data, 10) catch return error.InvalidWire;
    }

    pub fn encode(self: *DecodeOk) []const u8 {
        _ = self;
        return "";
    }
};

const DecodeReject = struct {
    value: u8 = 0,

    pub fn decode(self: *DecodeReject, data: []const u8) DecodeError!void {
        _ = data;
        _ = self;
        return error.InvalidValue;
    }

    pub fn encode(self: *DecodeReject) []const u8 {
        _ = self;
        return "";
    }
};

test "M3: decode bool" {
    var b: bool = undefined;
    try decodeInto(bool, std.testing.allocator, "true", &b);
    try std.testing.expect(b);
    try decodeInto(bool, std.testing.allocator, "1", &b);
    try std.testing.expect(b);
    try decodeInto(bool, std.testing.allocator, "false", &b);
    try std.testing.expect(!b);
    try decodeInto(bool, std.testing.allocator, "0", &b);
    try std.testing.expect(!b);
    try std.testing.expectError(error.InvalidWire, decodeInto(bool, std.testing.allocator, "yes", &b));
}

test "M3: decode integers" {
    var u8v: u8 = 0;
    try decodeInto(u8, std.testing.allocator, "255", &u8v);
    try std.testing.expectEqual(@as(u8, 255), u8v);
    try std.testing.expectError(error.InvalidWire, decodeInto(u8, std.testing.allocator, "256", &u8v));
    try std.testing.expectError(error.InvalidWire, decodeInto(u8, std.testing.allocator, "abc", &u8v));

    var u128v: u128 = 0;
    try decodeInto(u128, std.testing.allocator, "340282366920938463463374607431768211455", &u128v);
    try std.testing.expectEqual(std.math.maxInt(u128), u128v);

    var i: i64 = 0;
    try decodeInto(i64, std.testing.allocator, "-42", &i);
    try std.testing.expectEqual(@as(i64, -42), i);

    var usize_v: usize = 0;
    try decodeInto(usize, std.testing.allocator, "4096", &usize_v);
    try std.testing.expectEqual(@as(usize, 4096), usize_v);

    var isize_v: isize = 0;
    try decodeInto(isize, std.testing.allocator, "-7", &isize_v);
    try std.testing.expectEqual(@as(isize, -7), isize_v);
}

test "M3: decode floats" {
    var f16v: f16 = 0;
    try decodeInto(f16, std.testing.allocator, "1.5", &f16v);
    try std.testing.expectEqual(@as(f16, 1.5), f16v);

    var f32v: f32 = 0;
    try decodeInto(f32, std.testing.allocator, "3.25", &f32v);
    try std.testing.expectEqual(@as(f32, 3.25), f32v);

    var f64v: f64 = 0;
    try decodeInto(f64, std.testing.allocator, "2.5", &f64v);
    try std.testing.expectEqual(@as(f64, 2.5), f64v);

    var f80v: f80 = 0;
    try decodeInto(f80, std.testing.allocator, "1.25", &f80v);
    try std.testing.expectEqual(@as(f80, 1.25), f80v);

    var f128v: f128 = 0;
    try decodeInto(f128, std.testing.allocator, "0.5", &f128v);
    try std.testing.expectEqual(@as(f128, 0.5), f128v);

    try std.testing.expectError(error.InvalidWire, decodeInto(f32, std.testing.allocator, "x", &f32v));
}

test "M3: decode string slices allocate copies" {
    const allocator = std.testing.allocator;

    var s: []const u8 = undefined;
    try decodeInto([]const u8, allocator, "hello", &s);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("hello", s);

    var mut: []u8 = undefined;
    try decodeInto([]u8, allocator, "world", &mut);
    defer allocator.free(mut);
    try std.testing.expectEqualStrings("world", mut);
}

test "M3: decode custom struct success and passthrough error" {
    var ok: DecodeOk = .{};
    try decodeInto(DecodeOk, std.testing.allocator, "77", &ok);
    try std.testing.expectEqual(@as(u32, 77), ok.value);
    try std.testing.expectError(error.InvalidWire, decodeInto(DecodeOk, std.testing.allocator, "no", &ok));

    var rej: DecodeReject = .{};
    try std.testing.expectError(error.InvalidValue, decodeInto(DecodeReject, std.testing.allocator, "x", &rej));
}

test "M3: allocation failure propagates OutOfMemory" {
    const FailAlloc = std.testing.FailingAllocator;
    var failing = FailAlloc.init(std.testing.allocator, .{ .fail_index = 0 });
    var s: []const u8 = undefined;
    try std.testing.expectError(error.OutOfMemory, decodeInto([]const u8, failing.allocator(), "boom", &s));
}

const M4Def = .{
    .verbose = Flag(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
    },
    .name = Flag([]const u8){
        .short = "n",
        .default = Default([]const u8){ .direct = "anon" },
    },
    .level = Flag(u8){
        .long = "level",
        .default = Default(u8){ .direct = 1 },
    },
    .dry_run = Flag(bool){
        .long = "dry-run",
        .default = Default(bool){ .direct = false },
    },
    .mode = Flag([]const u8){
        .long = "mode",
        .default = Default([]const u8){ .direct = "fast" },
    },
    .file = Argument([]const u8){},
    .dir = Argument([]const u8){
        .default = Default([]const u8){ .direct = "." },
    },
};

fn m4Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M4View {
    return M4.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

const M4 = generate(App{ .name = "m4", .help = "m4" }, M4Def);
const M4View = M4.View;

test "M4: long flag inline and separate value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m4Parse(&arena, &.{ "--level=7", "f1" }, &diag);
    try std.testing.expectEqual(@as(u8, 7), a.level);
    try std.testing.expectEqualStrings("f1", a.file);

    const b = try m4Parse(&arena, &.{ "--level", "9", "f2" }, &diag);
    try std.testing.expectEqual(@as(u8, 9), b.level);
}

test "M4: short flag separate, inline and eq forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const b = try m4Parse(&arena, &.{ "-n", "bob", "f" }, &diag);
    try std.testing.expectEqualStrings("bob", b.name);

    const c = try m4Parse(&arena, &.{ "-n=bob", "f" }, &diag);
    try std.testing.expectEqualStrings("bob", c.name);
}

test "M4: bare bool flags default to true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m4Parse(&arena, &.{ "-v", "--dry-run", "f" }, &diag);
    try std.testing.expect(a.verbose);
    try std.testing.expect(a.dry_run);
}

test "M4: bool accepts explicit inline value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m4Parse(&arena, &.{ "--dry-run=false", "-v=true", "f" }, &diag);
    try std.testing.expect(!a.dry_run);
    try std.testing.expect(a.verbose);

    try std.testing.expectError(error.InvalidWire, m4Parse(&arena, &.{ "--dry-run=maybe", "f" }, &diag));
}

test "M4: positionals bind in order and defaults fill the last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m4Parse(&arena, &.{"file.txt"}, &diag);
    try std.testing.expectEqualStrings("file.txt", a.file);
    try std.testing.expectEqualStrings(".", a.dir);

    const b = try m4Parse(&arena, &.{ "file.txt", "sub" }, &diag);
    try std.testing.expectEqualStrings("file.txt", b.file);
    try std.testing.expectEqualStrings("sub", b.dir);
}

test "M4: terminator treats the rest as literal positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m4Parse(&arena, &.{ "--dry-run", "--", "f", "--level=99" }, &diag);
    try std.testing.expect(a.dry_run);
    try std.testing.expectEqualStrings("f", a.file);
    try std.testing.expectEqualStrings("--level=99", a.dir);
}

test "M4: unknown long flag reports token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m4Parse(&arena, &.{ "--nope", "f" }, &diag));
    try std.testing.expectEqualStrings("--nope", diag.token.?);
}

test "M4: unknown short flag reports token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m4Parse(&arena, &.{ "-z", "f" }, &diag));
    try std.testing.expectEqualStrings("-z", diag.token.?);
}

test "M4: missing value reports token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.MissingValue, m4Parse(&arena, &.{"--level"}, &diag));
    try std.testing.expectEqualStrings("--level", diag.token.?);

    var diag2: Diag = .{};
    try std.testing.expectError(error.MissingValue, m4Parse(&arena, &.{"-n"}, &diag2));
    try std.testing.expectEqualStrings("-n", diag2.token.?);
}

test "M4: too many arguments reports token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.TooManyArguments, m4Parse(&arena, &.{ "a", "b", "c" }, &diag));
    try std.testing.expectEqualStrings("c", diag.token.?);
}

test "M4: required field missing reports field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.MissingRequired, m4Parse(&arena, &.{}, &diag));
    try std.testing.expectEqualStrings("file", diag.field.?);
}

test "M4: optional fields fall back to direct defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m4Parse(&arena, &.{"f"}, &diag);
    try std.testing.expect(!a.verbose);
    try std.testing.expect(!a.dry_run);
    try std.testing.expectEqual(@as(u8, 1), a.level);
    try std.testing.expectEqualStrings("anon", a.name);
    try std.testing.expectEqualStrings("fast", a.mode);
}

// --- M5: post-pass (env/direct precedence, uniform required rule) ---

const M5Def = .{
    .user = Flag([]const u8){
        .short = "u",
        .default = Default([]const u8){ .env = "DAP_USER" },
    },
    .port = Flag(u16){
        .default = Default(u16){ .env = "DAP_PORT", .direct = 4242 },
    },
    .host = Flag([]const u8){
        .default = Default([]const u8){ .direct = "localhost" },
    },
    .loud = Flag(bool){
        .default = Default(bool){ .direct = false },
    },
    .needed = Flag(bool){},
    .file = Argument([]const u8){},
    .dir = Argument([]const u8){
        .default = Default([]const u8){ .direct = "." },
    },
};

const M5 = generate(App{ .name = "m5", .help = "m5" }, M5Def);
const M5View = M5.View;

fn makeEnviron(comptime entries: []const [*:0]const u8) std.process.Environ {
    return .{ .block = .{ .slice = (entries ++ &[_]?[*:0]const u8{null})[0..entries.len :null] } };
}

fn m5Parse(environ: std.process.Environ, arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M5View {
    return M5.parseInner(arena.allocator(), environ, args, diag);
}

test "M5: CLI value beats env and direct defaults" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const envp = &[_][*:0]const u8{ "DAP_USER=envbob", "DAP_PORT=9999" };
    const env = makeEnviron(envp);

    const a = try m5Parse(env, &arena, &.{ "-u", "clibob", "--port=7", "--needed", "f" }, &diag);
    try std.testing.expectEqualStrings("clibob", a.user);
    try std.testing.expectEqual(@as(u16, 7), a.port);
}

test "M5: env beats direct, direct beats zero" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const envp = &[_][*:0]const u8{"DAP_USER=envbob"};
    const env = makeEnviron(envp);

    const a = try m5Parse(env, &arena, &.{ "--needed", "f" }, &diag);
    try std.testing.expectEqualStrings("envbob", a.user);
    try std.testing.expectEqual(@as(u16, 4242), a.port); // env missing -> direct
    try std.testing.expectEqualStrings("localhost", a.host); // direct
    try std.testing.expect(!a.loud); // direct false
    try std.testing.expectEqualStrings(".", a.dir); // direct
}

test "M5: absent env falls through to direct default" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const env = std.process.Environ.empty;
    const a = try m5Parse(env, &arena, &.{ "--needed", "f" }, &diag);
    try std.testing.expectEqualStrings("", a.user); // env-only default, absent -> zero ""
    try std.testing.expectEqual(@as(u16, 4242), a.port);
}

test "M5: env override supplies typed value" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const envp = &[_][*:0]const u8{"DAP_PORT=31337"};
    const env = makeEnviron(envp);

    const a = try m5Parse(env, &arena, &.{ "--needed", "f" }, &diag);
    try std.testing.expectEqual(@as(u16, 31337), a.port);
}

test "M5: bool flags are never required; optional bool honoured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // A boolean flag with no default implicitly defaults to `false`, so an
    // omitted `--needed` is never a missing-required error.
    const a = try m5Parse(std.process.Environ.empty, &arena, &.{"f"}, &diag);
    try std.testing.expect(!a.needed);
    try std.testing.expect(!a.loud); // optional bool via explicit default

    const b = try m5Parse(std.process.Environ.empty, &arena, &.{ "--needed=false", "f" }, &diag);
    try std.testing.expect(!b.needed);

    const c = try m5Parse(std.process.Environ.empty, &arena, &.{ "--needed", "f" }, &diag);
    try std.testing.expect(c.needed);
}

test "M5: required error carries diag.field for env/direct-less spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // `--needed` is satisfied, but the required `file` argument is absent.
    try std.testing.expectError(error.MissingRequired, m5Parse(std.process.Environ.empty, &arena, &.{"--needed"}, &diag));
    try std.testing.expectEqualStrings("file", diag.field.?);
}

test "M5: bool flag with a direct true default is a compile error" {
    if (false) {
        const Bad = .{ .x = Flag(bool){ .default = Default(bool){ .direct = true } } };
        comptime _ = normalize(Bad);
    }
}

test "M5: bool flag usage header is bracketed" {
    const def = .{
        .flag = Flag(bool){ .help = "A boolean flag." },
        .opt = Flag(bool){ .default = Default(bool){ .direct = false }, .help = "A defaulted bool." },
    };
    const CLI = generate(App{ .name = "b", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);
    const h = try CLI.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    const usage_end = std.mem.indexOf(u8, h, "\n").?;
    const usage = h[0..usage_end];
    try std.testing.expect(std.mem.startsWith(u8, usage, "Usage: b [--flag] [flags]"));
}

test "M5: bad env value reports InvalidWire with field" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const envp = &[_][*:0]const u8{"DAP_PORT=notanumber"};
    const env = makeEnviron(envp);

    try std.testing.expectError(error.InvalidWire, m5Parse(env, &arena, &.{ "--needed", "f" }, &diag));
    try std.testing.expectEqualStrings("port", diag.field.?);
}

// --- M6: validation (Phase 3 over all assignment paths) ---

const M6Def = .{
    .user = Flag([]const u8){
        .short = "u",
        .validation = Validate.stringNotEmpty,
        .default = Default([]const u8){ .env = "DAP_USER" },
    },
    .level = Flag(u8){
        .long = "level",
        .validation = Validate.intNotZero(u8),
        .default = Default(u8){ .direct = 1 },
    },
    .path = Argument([]const u8){
        .validation = Validate.stringNotEmpty,
    },
};

const M6 = generate(App{ .name = "m6", .help = "m6" }, M6Def);
const M6View = M6.View;

fn m6Parse(environ: std.process.Environ, arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: ?*Diag) !M6View {
    return M6.parseInner(arena.allocator(), environ, args, diag);
}

test "M6: validation passes when values are acceptable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m6Parse(std.process.Environ.empty, &arena, &.{ "-u", "bob", "/tmp/f" }, &diag);
    try std.testing.expectEqualStrings("bob", a.user);
    try std.testing.expectEqual(@as(u8, 1), a.level);
    try std.testing.expectEqualStrings("/tmp/f", a.path);
    try std.testing.expect(diag.message == null);
}

test "M6: validation failure on wire value carries message and field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    try std.testing.expectError(error.InvalidValue, m6Parse(std.process.Environ.empty, &arena, &.{ "-u", "", "/tmp/f" }, &diag));
    try std.testing.expectEqualStrings("user", diag.field.?);
    try std.testing.expectEqualStrings("value must not be empty", diag.message.?);
    diag.deinit(arena.allocator());
    try std.testing.expect(diag.message == null);
}

test "M6: validation failure on direct default is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // level defaults to 1 (valid); prove the path via a zero direct default.
    const Bad = generate(App{ .name = "bad", .help = "bad" }, .{
        .level = Flag(u8){
            .validation = Validate.intNotZero(u8),
            .default = Default(u8){ .direct = 0 },
        },
    });
    try std.testing.expectError(error.InvalidValue, Bad.parseInner(arena.allocator(), std.process.Environ.empty, &.{}, &diag));
    try std.testing.expectEqualStrings("level", diag.field.?);
    try std.testing.expectEqualStrings("value must not be zero", diag.message.?);
    diag.deinit(arena.allocator());
}

test "M6: validation failure on env default is reported" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const envp = &[_][*:0]const u8{"DAP_USER="};
    const env = makeEnviron(envp);

    try std.testing.expectError(error.InvalidValue, m6Parse(env, &arena, &.{"/tmp/f"}, &diag));
    try std.testing.expectEqualStrings("user", diag.field.?);
    try std.testing.expectEqualStrings("value must not be empty", diag.message.?);
    diag.deinit(arena.allocator());
}

test "M6: validation message is freed when diag is null" {
    // A direct-default failure allocates only the validation message, so
    // passing the testing allocator directly proves parse frees it on the
    // null-diag path (a leak would fail the test).
    const Bad = generate(App{ .name = "bad", .help = "bad" }, .{
        .level = Flag(u8){
            .validation = Validate.intNotZero(u8),
            .default = Default(u8){ .direct = 0 },
        },
    });
    try std.testing.expectError(error.InvalidValue, Bad.parseInner(std.testing.allocator, std.process.Environ.empty, &.{}, null));
}

test "M6: passing validation leaves no diag message" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m6Parse(std.process.Environ.empty, &arena, &.{ "-u", "ok", "p" }, &diag);
    _ = a;
    try std.testing.expect(diag.message == null);
    diag.deinit(allocator);
}

// --- M7: handoff (command integration in the loop) ---

const M7Def = .{
    .verbose = Flag(bool){
        .long = "verbose",
        .default = Default(bool){ .direct = false },
    },
    .needed = Flag([]const u8){ .long = "needed" },
    .start = Command(.{ .help = "Start." }, .{
        .name = Argument([]const u8){},
        .force = Flag(bool){
            .long = "force",
            .default = Default(bool){ .direct = false },
        },
    }),
    .stop = Command(.{ .name = "halt", .help = "Stop." }, .{}),
    .nested = Command(.{ .help = "Nested." }, .{
        .deep = Command(.{ .help = "Deep." }, .{
            .n = Argument(u8){},
        }),
    }),
};

const M7 = generate(App{ .name = "m7", .help = "m7" }, M7Def);
const M7View = M7.View;

fn m7Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M7View {
    return M7.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

test "M7: root flags then command handoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--verbose", "--needed", "v", "start", "file" }, &diag);
    try std.testing.expect(a.verbose);
    try std.testing.expectEqualStrings("v", a.needed);
    try std.testing.expect(a._start != null);
    try std.testing.expect(a._stop == null);
    try std.testing.expectEqualStrings("file", a._start.?.name);
}

test "M7: no command leaves the command fields null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--needed", "v" }, &diag);
    try std.testing.expect(a._start == null);
    try std.testing.expect(a._stop == null);
    try std.testing.expect(a._nested == null);
}

test "M7: named command via CommandMeta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--needed", "v", "halt" }, &diag);
    try std.testing.expect(a._stop != null);
    try std.testing.expect(a._start == null);
}

test "M7: flags after the command are scoped to the sub" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // `--force` is a start-scoped flag; the root never sees it.
    const a = try m7Parse(&arena, &.{ "--needed", "v", "start", "--force", "file" }, &diag);
    try std.testing.expect(a._start != null);
    try std.testing.expect(a._start.?.force);
    try std.testing.expectEqualStrings("file", a._start.?.name);
}

test "M7: root required still enforced after handoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // `--needed` is required at the root but appears nowhere.
    try std.testing.expectError(error.MissingRequired, m7Parse(&arena, &.{ "start", "file" }, &diag));
    try std.testing.expectEqualStrings("needed", diag.field.?);
}

test "M7: terminator suppresses handoff and overflows positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // After `--`, the command-like literal is a positional; the root has no
    // argument slots, so it is TooManyArguments.
    try std.testing.expectError(error.TooManyArguments, m7Parse(&arena, &.{ "--needed", "v", "--", "start" }, &diag));
    try std.testing.expectEqualStrings("start", diag.token.?);
}

test "M7: missing sub required propagates through the root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    try std.testing.expectError(error.MissingRequired, m7Parse(&arena, &.{ "--needed", "v", "start" }, &diag));
    try std.testing.expectEqualStrings("name", diag.field.?);
}

test "M7: nested commands recurse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--needed", "v", "nested", "deep", "5" }, &diag);
    try std.testing.expect(a._nested != null);
    const nested = a._nested.?;
    try std.testing.expect(nested._deep != null);
    try std.testing.expectEqual(@as(u8, 5), nested._deep.?.n);
}

// --- M8: Enumeration (factory, round-trips, integration) ---

const Mode = Enumeration(.{
    .fast = Enum{},
    .slow = Enum{ .name = "glacial" },
});

test "M8: enumeration builds a view over branch names" {
    const ModeView = Mode.EnumView;
    try std.testing.expectEqualStrings("fast", @tagName(@as(ModeView, @enumFromInt(0))));
    try std.testing.expectEqualStrings("slow", @tagName(@as(ModeView, @enumFromInt(1))));
    try std.testing.expectEqualStrings("fast", Mode.names[0]);
    try std.testing.expectEqualStrings("glacial", Mode.names[1]);
}

test "M8: enumeration round-trips wire names through decode/encode" {
    var m: Mode = .{};
    try std.testing.expectEqualStrings("fast", m.encode());

    try m.decode("glacial");
    try std.testing.expectEqualStrings("glacial", m.encode());
    try std.testing.expectEqual(Mode.EnumView.slow, m.view);

    try m.decode("fast");
    try std.testing.expectEqual(Mode.EnumView.fast, m.view);

    try std.testing.expectError(error.InvalidWire, m.decode("nope"));
    try std.testing.expectEqual(Mode.EnumView.fast, m.view);
}

test "M8: enumeration works as an flag value type" {
    const def = .{
        .mode = Flag(Mode){
            .long = "mode",
            .default = Default(Mode){ .direct = .{} },
        },
        .file = Argument([]const u8){},
    };
    const CLI = generate(App{ .name = "enum", .help = "enum" }, def);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const allocator = arena.allocator();

    const a = try CLI.parse(allocator, std.process.Environ.empty, &.{ "--mode", "glacial", "f" }, &diag);
    var amode = a.mode;
    try std.testing.expectEqualStrings("glacial", amode.encode());
    try std.testing.expectEqualStrings("f", a.file);

    const b = try CLI.parse(allocator, std.process.Environ.empty, &.{"f"}, &diag);
    try std.testing.expectEqual(Mode.EnumView.fast, b.mode.view);

    try std.testing.expectError(error.InvalidWire, CLI.parseInner(allocator, std.process.Environ.empty, &.{ "--mode", "bad", "f" }, &diag));
    try std.testing.expectEqualStrings("mode", diag.field.?);
}

test "M8: enumeration works as an argument value type" {
    const def = .{
        .mode = Argument(Mode){},
    };
    const CLI = generate(App{ .name = "enum-arg", .help = "enum-arg" }, def);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const allocator = arena.allocator();

    const a = try CLI.parse(allocator, std.process.Environ.empty, &.{"glacial"}, &diag);
    var amode = a.mode;
    try std.testing.expectEqualStrings("glacial", amode.encode());
}

test "M8: empty enumeration is a decodable value type that rejects everything" {
    const Empty = Enumeration(.{});
    var e: Empty = .{};
    try std.testing.expectError(error.InvalidWire, e.decode("anything"));
    try std.testing.expectEqualStrings("", e.encode());
}

// Negative check (verified by uncommenting):
// duplicate wire names must be a @compileError.
// const DupNames = Enumeration(.{
//     .a = Enum{ .name = "same" },
//     .b = Enum{ .name = "same" },
// });

// --- M9: help text ---

const M9Def = .{
    .verbose = Flag(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
        .help = "Verbose output.",
    },
    .dry_run = Flag(bool){
        .long = "dry-run",
        .help = "Dry run.",
    },
    .port = Flag(u16){
        .short = "P",
        .default = Default(u16){ .direct = 8080 },
        .help = "Port.",
    },
    .server = Group(.{
        .host = Flag([]const u8){
            .help = "Host.",
            .i18n = "server.host",
        },
    }, "Server settings"),
    .path = Argument([]const u8){ .help = "Path of the file." },
    .named = Argument([]const u8){ .name = "TARGET" },
};

const M9 = generate(
    App{
        .name = "app",
        .help = "Do things.",
        // Layout tests below compare the raw two-column text, so they pin the
        // neutral scheme; highlighting has its own tests.
        .help_renderer = .{ .highlight = .{ .flat = {} } },
    },
    M9Def,
);

const M9CmdDef = .{
    .verbose = Flag(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
        .help = "Verbose output.",
    },
    .start = Command(.{ .help = "Start." }, .{
        .name = Argument([]const u8){ .help = "Name." },
    }),
    .stop = Command(.{ .name = "halt", .help = "Stop." }, .{}),
};

const M9Cmd = generate(
    App{
        .name = "app",
        .help = "Do things.",
        .help_renderer = .{ .highlight = .{ .flat = {} } },
    },
    M9CmdDef,
);

test "M9: help text renders header, sections and arguments" {
    const expected =
        \\Usage: app [--dry-run] --host=HOST <path> <TARGET> [flags]
        \\
        \\Do things.
        \\
        \\Arguments:
        \\  <path>      Path of the file.
        \\  <TARGET>
        \\
        \\Flags:
        \\  -h, --help         Show context-sensitive help.
        \\  -v, --verbose      Verbose output.
        \\      --dry-run      Dry run.
        \\  -P, --port=8080    Port.
        \\
        \\Server settings
        \\  --host=HOST    Host.
        \\
    ;
    const h = try M9.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

test "M9: help text renders the commands section" {
    const expected =
        \\Usage: app <command> [flags]
        \\
        \\Do things.
        \\
        \\Flags:
        \\  -h, --help       Show context-sensitive help.
        \\  -v, --verbose    Verbose output.
        \\
        \\Commands:
        \\  start    Start.
        \\  halt     Stop.
        \\
    ;
    const h = try M9Cmd.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

test "M9: i18n references are carried verbatim in specs but stay inert" {
    // The spec keeps the i18n reference; help output renders only the literal
    // help string, never resolving the reference.
    var found = false;
    inline for (M9.specs) |s| {
        if (std.mem.eql(u8, s.name, "host")) {
            try std.testing.expectEqualStrings("server.host", s.i18n.?);
            found = true;
        }
    }
    try std.testing.expect(found);

    const h = try M9.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "server.host") == null);
}

test "M9: help text with no help header, no commands and no arguments" {
    const def = .{
        .flag = Flag(bool){ .default = Default(bool){ .direct = false } },
    };
    const CLI = generate(App{ .name = "bare", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);
    const expected =
        \\Usage: bare [flags]
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\      --flag
        \\
    ;
    const h = try CLI.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

test "M9: help text for an empty declaration has only the header" {
    const CLI = generate(App{ .name = "empty", .help = "Nothing here.", .help_renderer = .{ .highlight = .{ .flat = {} } } }, .{});
    const expected =
        \\Usage: empty [flags]
        \\
        \\Nothing here.
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    const h = try CLI.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

// Negative check (verified by uncommenting): helpText must inline nothing of
// the i18n lookup; it is inert data.

test "M9: helpData fills groups, defaults and commands" {
    var data = try M9.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("app", data.name);
    try std.testing.expectEqualStrings("Do things.", data.info);

    // Ungrouped flags first, then the named group.
    try std.testing.expectEqual(@as(usize, 2), data.flag_groups.len);
    try std.testing.expect(data.flag_groups[0].name == null);
    try std.testing.expectEqualStrings("Server settings", data.flag_groups[1].name.?);

    const ungrouped = data.flag_groups[0].flags;
    try std.testing.expectEqual(@as(usize, 4), ungrouped.len);

    // Injected builtin help flag comes first, before every user flag.
    try std.testing.expectEqualStrings("help", ungrouped[0].name);
    try std.testing.expectEqualStrings("h", ungrouped[0].short.?);
    try std.testing.expectEqualStrings("false", ungrouped[0].default.?);
    try std.testing.expect(!ungrouped[0].takes_value);

    try std.testing.expectEqualStrings("verbose", ungrouped[1].name);
    try std.testing.expectEqualStrings("v", ungrouped[1].short.?);
    try std.testing.expectEqualStrings("false", ungrouped[1].default.?);
    try std.testing.expect(!ungrouped[1].takes_value);

    // Required flag: no default, no short.
    try std.testing.expectEqualStrings("dry-run", ungrouped[2].name);
    try std.testing.expect(ungrouped[2].short == null);
    try std.testing.expect(ungrouped[2].default == null);

    try std.testing.expectEqualStrings("port", ungrouped[3].name);
    try std.testing.expectEqualStrings("8080", ungrouped[3].default.?);
    try std.testing.expect(ungrouped[3].takes_value);

    try std.testing.expectEqual(@as(usize, 1), data.flag_groups[1].flags.len);
    try std.testing.expectEqualStrings("host", data.flag_groups[1].flags[0].name);

    // A declaration with positional arguments has no commands.
    try std.testing.expectEqual(@as(usize, 0), data.commands.len);

    // Arguments: both ungrouped, in declaration order, names from `.name`.
    try std.testing.expectEqual(@as(usize, 1), data.arg_groups.len);
    try std.testing.expect(data.arg_groups[0].name == null);
    try std.testing.expectEqual(@as(usize, 2), data.arg_groups[0].args.len);
    try std.testing.expectEqualStrings("path", data.arg_groups[0].args[0].name);
    try std.testing.expect(data.arg_groups[0].args[0].default == null);
    try std.testing.expectEqualStrings("TARGET", data.arg_groups[0].args[1].name);
}

test "M9: helpData fills commands" {
    var data = try M9Cmd.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), data.commands.len);
    try std.testing.expectEqualStrings("start", data.commands[0].name);
    try std.testing.expectEqualStrings("Start.", data.commands[0].help);
    try std.testing.expectEqualStrings("halt", data.commands[1].name);
    try std.testing.expectEqualStrings("Stop.", data.commands[1].help);
}

test "M9: helpData groups arguments and renders custom defaults" {
    const HMode = Enumeration(.{
        .fast = Enum{},
        .slow = Enum{},
    });
    const def = .{
        .mode = Flag(HMode){
            .default = Default(HMode){ .direct = HMode{ .view = .slow } },
            .help = "Mode.",
        },
        .grp = Group(.{
            .target = Argument([]const u8){ .help = "Target." },
        }, "Args group"),
        .plain = Argument([]const u8){ .help = "Plain." },
    };
    const CLI = generate(App{ .name = "g", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);
    var data = try CLI.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    // Custom struct default renders through `encode`; the injected help flag
    // occupies slot 0 of the ungrouped flags.
    try std.testing.expectEqualStrings("help", data.flag_groups[0].flags[0].name);
    try std.testing.expectEqualStrings("slow", data.flag_groups[0].flags[1].default.?);

    // Ungrouped argument first, grouped argument after.
    try std.testing.expectEqual(@as(usize, 2), data.arg_groups.len);
    try std.testing.expect(data.arg_groups[0].name == null);
    try std.testing.expectEqual(@as(usize, 1), data.arg_groups[0].args.len);
    try std.testing.expectEqualStrings("plain", data.arg_groups[0].args[0].name);
    try std.testing.expectEqualStrings("Args group", data.arg_groups[1].name.?);
    try std.testing.expectEqual(@as(usize, 1), data.arg_groups[1].args.len);
    try std.testing.expectEqualStrings("target", data.arg_groups[1].args[0].name);
}

test "M9: helpData frees everything when an allocation fails" {
    const FailingAllocator = std.testing.FailingAllocator;

    const total = blk: {
        var probe = FailingAllocator.init(std.testing.allocator, .{});
        var data = try M9.helpData(probe.allocator());
        data.deinit(probe.allocator());
        break :blk probe.allocations;
    };

    var fi: usize = 0;
    while (fi <= total) : (fi += 1) {
        var fa = FailingAllocator.init(std.testing.allocator, .{ .fail_index = fi });
        if (M9.helpData(fa.allocator())) |data| {
            var d = data;
            d.deinit(fa.allocator());
        } else |e| {
            try std.testing.expectEqual(std.mem.Allocator.Error.OutOfMemory, e);
        }
        try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    }
}

test "M9: helpData.renderCompact matches the reference layout" {
    const def = .{
        .source = Flag([]const u8){
            .default = Default([]const u8){ .direct = "." },
            .help = "Source directory.",
        },
        .last = Flag(bool){
            .short = "l",
            .default = Default(bool){ .direct = false },
            .help = "Show last modification.",
        },
        .grp = Group(.{
            .count = Flag(isize){
                .default = Default(isize){ .direct = 1 },
                .help = "Number of items.",
            },
            .value = Flag(isize){
                .short = "v",
                .default = Default(isize){ .direct = 1 },
                .help = "Value of items.",
            },
        }, "Group"),
        .target = Argument([]const u8){
            .default = Default([]const u8){ .direct = "" },
            .help = "Target directory.",
        },
    };
    const CLI = generate(App{ .name = "dap-example", .help = "Manual test of the dap module.", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);

    const expected =
        \\Usage: dap-example [<target>] [flags]
        \\
        \\Manual test of the dap module.
        \\
        \\Arguments:
        \\  [<target>]    Target directory.
        \\
        \\Flags:
        \\  -h, --help        Show context-sensitive help.
        \\      --source=.    Source directory.
        \\  -l, --last        Show last modification.
        \\
        \\Group
        \\      --count=1    Number of items.
        \\  -v, --value=1    Value of items.
        \\
    ;

    var data = try CLI.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const h = try data.renderCompact(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

test "M9: renderCompact orders groups by name with ungrouped first" {
    const def = .{
        .zeta = Group(.{
            .z = Flag(bool){ .default = Default(bool){ .direct = false }, .help = "Z." },
        }, "zeta"),
        .alpha = Group(.{
            .a = Flag(bool){ .default = Default(bool){ .direct = false }, .help = "A." },
        }, "alpha"),
        .plain = Flag(bool){ .default = Default(bool){ .direct = false }, .help = "Plain." },
    };
    const CLI = generate(App{ .name = "g", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);
    const expected =
        \\Usage: g [flags]
        \\
        \\Flags:
        \\  -h, --help     Show context-sensitive help.
        \\      --plain    Plain.
        \\
        \\alpha
        \\  --a    A.
        \\
        \\zeta
        \\  --z    Z.
        \\
    ;

    var data = try CLI.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const h = try data.renderCompact(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

test "M9: renderCompact lists commands and marks required flags in usage" {
    const def = .{
        .needed = Flag([]const u8){
            .short = "n",
            .help = "Required.",
        },
        .extra = Flag(u8){
            .default = Default(u8){ .direct = 3 },
            .help = "Extra.",
        },
        .start = Command(.{ .help = "Start." }, .{}),
        .stop = Command(.{ .help = "Stop." }, .{}),
    };
    const CLI = generate(App{ .name = "app", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);

    const expected =
        \\Usage: app --needed=NEEDED <command> [flags]
        \\
        \\Flags:
        \\  -h, --help             Show context-sensitive help.
        \\  -n, --needed=NEEDED    Required.
        \\      --extra=3          Extra.
        \\
        \\Commands:
        \\  start    Start.
        \\  stop     Stop.
        \\
    ;

    var data = try CLI.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const h = try data.renderCompact(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

test "M9: renderCompact frees everything when an allocation fails" {
    const FailingAllocator = std.testing.FailingAllocator;

    const total = blk: {
        var probe = FailingAllocator.init(std.testing.allocator, .{});
        var data = try M9.helpData(probe.allocator());
        if (data.renderCompact(probe.allocator())) |s| {
            probe.allocator().free(s);
        } else |e| {
            try std.testing.expectEqual(std.mem.Allocator.Error.OutOfMemory, e);
        }
        data.deinit(probe.allocator());
        break :blk probe.allocations;
    };

    var fi: usize = 0;
    while (fi <= total) : (fi += 1) {
        var fa = FailingAllocator.init(std.testing.allocator, .{ .fail_index = fi });
        var data = M9.helpData(fa.allocator()) catch |e| {
            try std.testing.expectEqual(std.mem.Allocator.Error.OutOfMemory, e);
            try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
            continue;
        };
        if (data.renderCompact(fa.allocator())) |s| {
            fa.allocator().free(s);
        } else |e| {
            try std.testing.expectEqual(std.mem.Allocator.Error.OutOfMemory, e);
        }
        data.deinit(fa.allocator());
        try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    }
}

// --- M10: builtin help injection, help priority, renderer switch ---

const M10Def = .{
    .verbose = Flag(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
        .help = "Verbose output.",
    },
    .needed = Flag([]const u8){ .help = "Required." },
    .path = Argument([]const u8){ .help = "Path." },
};

const M10 = generate(App{ .name = "m10", .help = "M10." }, M10Def);

fn m10RenderMinimal(_: *const HelpData, allocator: std.mem.Allocator) std.mem.Allocator.Error!String {
    return try allocator.dupe(u8, "custom renderer");
}

test "M10: builtin help flag parses like a plain bool flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try M10.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "--needed", "x", "p", "--help" }, &diag);
    try std.testing.expect(a.builtin_help);
    try std.testing.expectEqualStrings("x", a.needed);
    try std.testing.expectEqualStrings("p", a.path);

    // Help bypasses required checks: `needed` and `path` are absent here.
    const e = try M10.parseInner(arena.allocator(), std.process.Environ.empty, &.{"--help"}, &diag);
    try std.testing.expect(e.builtin_help);

    const b = try M10.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "--needed", "x", "p" }, &diag);
    try std.testing.expect(!b.builtin_help);

    const c = try M10.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "--needed", "x", "p", "-h" }, &diag);
    try std.testing.expect(c.builtin_help);

    const d = try M10.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "--needed", "x", "p", "--help=false" }, &diag);
    try std.testing.expect(!d.builtin_help);

    var diag2: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, M10.parseInner(arena.allocator(), std.process.Environ.empty, &.{"--nope"}, &diag2));
}

test "M10: a user-declared --help clashes with the injected builtin" {
    if (false) {
        const Bad = .{
            .help = Flag(bool){ .long = "help" },
        };
        comptime _ = normalize(withBuiltinHelp(Bad));
    }
}

test "M10: helpText follows the compact renderer by default" {
    const h = try M10.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    // The default highlight is `.bold`, so names carry the bold/reset codes;
    // the dashes are part of each name token.
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m-h\x1b[0m, \x1b[1m--help\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1mUsage: \x1b[0m\x1b[1mm10\x1b[0m") != null);
}

test "M10: helpText follows a custom renderer function" {
    const Custom = generate(
        App{ .name = "m10c", .help = "M10 custom.", .help_renderer = .{ .style = .{ .custom = m10RenderMinimal } } },
        M10Def,
    );
    const h = try Custom.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("custom renderer", h);
}

test "M10: builtin help flag is rendered first in the flags section" {
    var data = try M10.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    const ungrouped = data.flag_groups[0].flags;
    try std.testing.expectEqual(@as(usize, 3), ungrouped.len);
    try std.testing.expectEqualStrings("help", ungrouped[0].name);
    try std.testing.expectEqualStrings("h", ungrouped[0].short.?);
    try std.testing.expectEqualStrings("Show context-sensitive help.", ungrouped[0].help);
    try std.testing.expectEqualStrings("false", ungrouped[0].default.?);
    try std.testing.expect(!ungrouped[0].takes_value);
    try std.testing.expectEqualStrings("verbose", ungrouped[1].name);
    try std.testing.expectEqualStrings("needed", ungrouped[2].name);
}

// --- M11: compact help highlighting ---

/// Copy `s` with every ANSI SGR sequence (`ESC [ ... m`) removed.
fn stripSgr(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != 'm') i += 1;
            if (i < s.len) i += 1;
            continue;
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn renderWithHighlight(comptime hl: HelpRendererHighlight, allocator: std.mem.Allocator) !String {
    const CLI = generate(App{
        .name = "app",
        .help = "Do things.",
        .help_renderer = .{ .highlight = hl },
    }, M9Def);
    var data = try CLI.helpData(allocator);
    defer data.deinit(allocator);
    return try data.renderCompact(allocator);
}

test "M11: flat highlight emits no escape codes" {
    const h = try renderWithHighlight(.{ .flat = {} }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOfScalar(u8, h, 0x1b) == null);
}

test "M11: highlighting leaves the column widths untouched" {
    const flat = try renderWithHighlight(.{ .flat = {} }, std.testing.allocator);
    defer std.testing.allocator.free(flat);

    inline for (.{ HelpRendererHighlight{ .bold = {} }, HelpRendererHighlight{ .color = {} } }) |hl| {
        const styled = try renderWithHighlight(hl, std.testing.allocator);
        defer std.testing.allocator.free(styled);
        const stripped = try stripSgr(std.testing.allocator, styled);
        defer std.testing.allocator.free(stripped);
        try std.testing.expectEqualStrings(flat, stripped);
    }
}

test "M11: bold wraps app, flag and argument names" {
    const h = try renderWithHighlight(.{ .bold = {} }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1mUsage: \x1b[0m\x1b[1mapp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m--help\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1mServer settings\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m<path>\x1b[0m") != null);
}

test "M11: usage brackets stay inside their highlight blocks" {
    const bold = try renderWithHighlight(.{ .bold = {} }, std.testing.allocator);
    defer std.testing.allocator.free(bold);
    // The optional-flag and `[flags]` tokens carry the brackets inside the
    // `.usage.optionals` block.
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[3m[--dry-run]\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[3m[flags]\x1b[0m") != null);
    // The required flag's dashes and `=` ride inside the name token.
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[1m--host=\x1b[0m") != null);
    // Positional tokens carry their own `<...>` / `[<...>]` brackets.
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[1m<path>\x1b[0m") != null);

    const color = try renderWithHighlight(.{ .color = {} }, std.testing.allocator);
    defer std.testing.allocator.free(color);
    try std.testing.expect(std.mem.indexOf(u8, color, "\x1b[3;36m[--dry-run]\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, color, "\x1b[36m<path>\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, color, "\x1b[1;96m--host=\x1b[0m") != null);
}

test "M11: flag list highlights dashes and assign sign with the name" {
    const h = try renderWithHighlight(.{ .bold = {} }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    // Each flag name token carries its own dashes and, for value flags, the
    // `=` sign; only the `, ` separator stays uncolored.
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m-h\x1b[0m, \x1b[1m--help\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m-P\x1b[0m, \x1b[1m--port=\x1b[0m\x1b[1m8080\x1b[0m") != null);
}

test "M11: color uses the per-category codes" {
    const h = try renderWithHighlight(.{ .color = {} }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    // App name: cyan + bold; required flag name: cyan + bold; value: cyan;
    // argument name: cyan; group: green + bold.
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1;92mUsage: \x1b[0m\x1b[1;96mapp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1;96m--host=\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1;92mServer settings\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[36m<path>\x1b[0m") != null);
}

test "M11: a custom highlight scheme is used verbatim" {
    const custom = HelpHighlight{
        .usage = .{
            .app_name = "<a>",
            .required_flags = .{ .name = "<n>", .value = "<v>" },
            .optionals = "<o>",
            .arguments = "<g>",
        },
        .groups = "<G>",
        .args = "<A>",
        .flags = .{ .name = "<f>", .value = "<V>" },
        .reset = "</>",
    };
    const h = try renderWithHighlight(.{ .custom = custom }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "<G>Usage: </><a>app</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<o>[--dry-run]</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<n>--host=</><v>HOST</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<G>Server settings</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<A><path></>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<f>-h</>, <f>--help</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<f>--port=</><V>8080</>") != null);
}

test "M11: HelpHighlight.resolve maps the ready profiles" {
    try std.testing.expectEqualStrings("", HelpHighlight.resolve(.{ .flat = {} }).flags.name);
    try std.testing.expectEqualStrings("\x1b[1m", HelpHighlight.resolve(.{ .bold = {} }).flags.name);
    try std.testing.expectEqualStrings("\x1b[1;96m", HelpHighlight.resolve(.{ .color = {} }).flags.name);
    try std.testing.expectEqualStrings("\x1b[36m", HelpHighlight.resolve(.{ .color = {} }).usage.required_flags.value);
    const c = HelpHighlight{ .flags = .{ .name = "X" } };
    try std.testing.expectEqualStrings("X", HelpHighlight.resolve(.{ .custom = c }).flags.name);
}

// ---------------------------------------------------------------------------
// M12: exclusive parameter groups (`Alt` / `VariantNamed`).
// ---------------------------------------------------------------------------

const M12Alt = Alt(.{
    .alt1 = .{
        .opt1 = Flag(u32){ .short = "1", .help = "First flag." },
        .flag1 = Flag(bool){ .help = "First flag." },
    },
    .alt2 = VariantNamed("fancy-alt2", .{
        .opt2 = Flag([]const u8){ .short = "2", .validation = Validate.stringNotEmpty, .help = "Second flag." },
    }),
});

const M12Def = .{
    .host = Flag([]const u8){ .default = Default([]const u8){ .direct = "localhost" } },
    .mode = M12Alt,
};

const M12 = generate(App{ .name = "m12", .help = "m12" }, M12Def);
const M12View = M12.View;

test "M12: Alt declaration metadata" {
    try std.testing.expect(M12Alt.dap_kind == .alt);
    try std.testing.expectEqual(@as(usize, 2), M12Alt.branch_names.len);
    try std.testing.expectEqualStrings("alt1", M12Alt.branch_names[0]);
    try std.testing.expectEqualStrings("alt2", M12Alt.branch_names[1]);
    try std.testing.expectEqualStrings("alt1", M12Alt.tag_names[0]);
    try std.testing.expectEqualStrings("fancy-alt2", M12Alt.tag_names[1]);
    try std.testing.expectEqualStrings("opt1", @typeInfo(M12Alt.branch_types[0]).@"struct".fields[0].name);
    try std.testing.expectEqualStrings("opt2", @typeInfo(M12Alt.branch_types[1]).@"struct".fields[0].name);
}

test "M12: normalization flattens branches with group tags" {
    const specs = M12.specs;
    var seen_member1 = false;
    var seen_member2 = false;
    inline for (specs) |s| {
        if (comptime std.mem.eql(u8, s.name, "opt1")) {
            seen_member1 = true;
            try std.testing.expectEqualStrings("alt1", s.group.?);
            try std.testing.expectEqualStrings("mode", s.alt.?);
            try std.testing.expectEqualStrings("alt1", s.alt_branch.?);
            try std.testing.expect(s.default == null);
            try std.testing.expect(s.required);
        }
        if (comptime std.mem.eql(u8, s.name, "opt2")) {
            seen_member2 = true;
            try std.testing.expectEqualStrings("fancy-alt2", s.group.?);
            try std.testing.expectEqualStrings("fancy-alt2", s.alt_branch.?);
        }
    }
    try std.testing.expect(seen_member1 and seen_member2);
}

test "M12: View carries an optional union field before commands" {
    const fields = @typeInfo(M12View).@"struct".fields;
    const last = fields[fields.len - 1];
    try std.testing.expectEqualStrings("mode", last.name);
    const MaybeUnion = last.type;
    try std.testing.expect(@typeInfo(MaybeUnion) == .optional);
    const UU = @typeInfo(MaybeUnion).optional.child;
    try std.testing.expect(@typeInfo(UU) == .@"union");
    var seen1 = false;
    var seen2 = false;
    inline for (@typeInfo(UU).@"union".fields) |uf| {
        if (std.mem.eql(u8, uf.name, "alt1")) seen1 = true;
        if (std.mem.eql(u8, uf.name, "fancy-alt2")) seen2 = true;
    }
    try std.testing.expect(seen1 and seen2);
}

fn m12Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M12View {
    return M12.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

test "M12: no branch flag leaves the union null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m12Parse(&arena, &.{}, &diag);
    try std.testing.expect(v.mode == null);
    try std.testing.expectEqualStrings("localhost", v.host);
}

test "M12: a single member activates its branch and fills the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m12Parse(&arena, &.{ "--opt1=42", "--flag1" }, &diag);
    try std.testing.expect(v.mode != null);
    switch (v.mode.?) {
        .alt1 => |p| {
            try std.testing.expectEqual(@as(u32, 42), p.opt1);
            try std.testing.expect(p.flag1);
        },
        .@"fancy-alt2" => return error.TestUnexpectedResult,
    }
}

test "M12: members of one branch may be combined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m12Parse(&arena, &.{ "-1", "7", "--flag1" }, &diag);
    switch (v.mode.?) {
        .alt1 => |p| try std.testing.expectEqual(@as(u32, 7), p.opt1),
        .@"fancy-alt2" => return error.TestUnexpectedResult,
    }
}

test "M12: VariantNamed branch activates under its tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m12Parse(&arena, &.{ "-2", "hello" }, &diag);
    switch (v.mode.?) {
        .alt1 => return error.TestUnexpectedResult,
        .@"fancy-alt2" => |p| try std.testing.expectEqualStrings("hello", p.opt2),
    }
}

test "M12: members from two branches conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.ConflictingAlt, m12Parse(&arena, &.{ "--opt1=1", "--opt2=x" }, &diag));
    try std.testing.expectEqualStrings("mode", diag.field.?);
}

test "M12: unseen member of an active branch is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.MissingRequired, m12Parse(&arena, &.{"--opt1=1"}, &diag));
    try std.testing.expectEqualStrings("flag1", diag.field.?);
}

test "M12: active-branch validation runs and reports the member field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.InvalidValue, m12Parse(&arena, &.{"--opt2="}, &diag));
    try std.testing.expectEqualStrings("opt2", diag.field.?);
    if (diag.message) |m| allocatorFree(&arena, m);
}

fn allocatorFree(arena: *std.heap.ArenaAllocator, m: String) void {
    arena.allocator().free(m);
}

test "M12: Alt member unknown flag is a plain UnknownFlag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m12Parse(&arena, &.{"--nope"}, &diag));
    try std.testing.expectEqualStrings("--nope", diag.token.?);
}

test "M12: Alt flag flag clashes with the parent are a compile error" {
    if (false) {
        const Bad = .{
            .host = Flag([]const u8){},
            .mode = Alt(.{ .a = .{ .host = Flag(u8){} } }),
        };
        comptime _ = normalize(Bad);
    }
}

test "M12: duplicate tags via VariantNamed are a compile error" {
    if (false) {
        const Bad = .{ .mode = Alt(.{
            .a = VariantNamed("same", .{ .x = Flag(u8){} }),
            .b = VariantNamed("same", .{ .y = Flag(u8){} }),
        }) };
        comptime _ = normalize(Bad);
    }
}

test "M12: an Alt branch name clashing with a Group name is a compile error" {
    if (false) {
        const Bad = .{
            .g = Group(.{ .p = Flag(u8){} }, "alt1"),
            .mode = Alt(.{ .alt1 = .{ .q = Flag(u8){} } }),
        };
        comptime _ = normalize(Bad);
    }
}

test "M12: non-flag Alt member is a compile error" {
    if (false) {
        const Bad = .{ .mode = Alt(.{ .a = .{ .x = Argument(u8){} } }) };
        comptime _ = normalize(Bad);
    }
}

test "M12: defaulted Alt member is a compile error" {
    if (false) {
        const Bad = .{ .mode = Alt(.{ .a = .{ .x = Flag(u8){ .default = Default(u8){ .direct = 1 } } } }) };
        comptime _ = normalize(Bad);
    }
}

test "M12: duplicate flags across branches are a compile error" {
    if (false) {
        const Bad = .{ .mode = Alt(.{
            .a = .{ .x = Flag(u8){ .long = "same" } },
            .b = .{ .y = Flag(u8){ .long = "same" } },
        }) };
        comptime _ = normalize(Bad);
    }
}

test "M12: zero-branch Alt is a compile error" {
    if (false) {
        const Bad = .{ .mode = Alt(.{}) };
        comptime _ = normalize(Bad);
    }
}

test "M12: help groups one branch per heading" {
    var data = try M12.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    var found_alt1 = false;
    var found_fancy = false;
    for (data.flag_groups) |g| {
        if (g.name) |n| {
            if (std.mem.eql(u8, n, "alt1")) found_alt1 = true;
            if (std.mem.eql(u8, n, "fancy-alt2")) found_fancy = true;
        }
    }
    try std.testing.expect(found_alt1 and found_fancy);

    const h = try M12.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "alt1") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "fancy-alt2") != null);
}

test "M12: usage line renders Alt branches as an alternation clause" {
    var data = try M12.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), data.usage_alts.len);
    try std.testing.expectEqual(@as(usize, 2), data.usage_alts[0].branches.len);
    try std.testing.expectEqualStrings("opt1", data.usage_alts[0].branches[0][0].name);
    try std.testing.expectEqualStrings("flag1", data.usage_alts[0].branches[0][1].name);
    try std.testing.expectEqualStrings("opt2", data.usage_alts[0].branches[1][0].name);
}

test "M12: usage clause renders Alt alternation with flat highlighting" {
    const def = .{
        .mode = Alt(.{
            .a = .{ .x = Flag(u32){} },
            .b = .{ .y = Flag([]const u8){} },
        }),
    };
    const C = generate(App{ .name = "u", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);
    const h = try C.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "Usage: u (--x=X | --y=Y) [flags]"));
}

const M12CmdDef = .{
    .run = Command(.{ .help = "Run." }, .{
        .speed = Alt(.{ .fast = .{ .fast = Flag(bool){} } }),
    }),
};

test "M12: an Alt inside a command definition works" {
    const C = generate(App{ .name = "c", .help = "c" }, M12CmdDef);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "run", "--fast" }, &diag);
    try std.testing.expect(v._run != null);
    try std.testing.expect(v._run.?.speed != null);
}

const M12MixedDef = .{
    .verbose = Flag(bool){ .short = "v", .default = Default(bool){ .direct = false } },
    .mode = Alt(.{ .a = .{ .x = Flag(u32){} }, .b = .{ .y = Flag(bool){} } }),
    .go = Command(.{ .help = "Go." }, .{}),
};

test "M12: Alt and command fields coexist at the root" {
    const C = generate(App{ .name = "x", .help = "x" }, M12MixedDef);
    const fields = @typeInfo(C.View).@"struct".fields;
    try std.testing.expectEqualStrings("mode", fields[fields.len - 2].name);
    try std.testing.expectEqualStrings("_go", fields[fields.len - 1].name);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "-v", "--x=3", "go" }, &diag);
    try std.testing.expect(v.verbose);
    try std.testing.expect(v.mode != null);
    try std.testing.expect(v._go != null);
    switch (v.mode.?) {
        .a => |p| try std.testing.expectEqual(@as(u32, 3), p.x),
        .b => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// M13: truly optional flags (?Flag(T) via dap.Optional).
// ---------------------------------------------------------------------------

const M13Def = .{
    .req = Flag([]const u8){ .short = "r" },
    .opt_str = Optional(Flag([]const u8){ .short = "s", .validation = Validate.stringNotEmpty, .help = "Optional." }),
    .opt_u32 = Optional(Flag(u32){ .long = "num" }),
    .opt_bool = Optional(Flag(bool){ .long = "maybe" }),
    .file = Argument([]const u8){},
};

const M13 = generate(App{ .name = "m13", .help = "m13" }, M13Def);
const M13View = M13.View;

test "M13: normalization marks optional specs" {
    var seen_str = false;
    var seen_req = false;
    var seen_file = false;
    inline for (M13.specs) |s| {
        if (comptime std.mem.eql(u8, s.name, "opt_str")) {
            seen_str = true;
            try std.testing.expect(s.optional);
            try std.testing.expect(!s.required);
            try std.testing.expect(s.default == null);
            try std.testing.expect(s.vtype == []const u8);
        }
        if (comptime std.mem.eql(u8, s.name, "req")) {
            seen_req = true;
            try std.testing.expect(!s.optional);
            try std.testing.expect(s.required);
        }
        if (comptime std.mem.eql(u8, s.name, "file")) {
            seen_file = true;
            try std.testing.expect(!s.optional);
            try std.testing.expect(s.required);
        }
    }
    try std.testing.expect(seen_str and seen_req and seen_file);
}

test "M13: View carries optional-typed fields in order" {
    try std.testing.expectEqual(?[]const u8, @FieldType(M13View, "opt_str"));
    try std.testing.expectEqual(?u32, @FieldType(M13View, "opt_u32"));
    try std.testing.expectEqual(?bool, @FieldType(M13View, "opt_bool"));
    try std.testing.expectEqual([]const u8, @FieldType(M13View, "req"));
    const fields = @typeInfo(M13View).@"struct".fields;
    try std.testing.expectEqualStrings("builtin_help", fields[0].name);
    try std.testing.expectEqualStrings("req", fields[1].name);
    try std.testing.expectEqualStrings("opt_str", fields[2].name);
    try std.testing.expectEqualStrings("opt_u32", fields[3].name);
    try std.testing.expectEqualStrings("opt_bool", fields[4].name);
    try std.testing.expectEqualStrings("file", fields[5].name);
}

fn m13Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M13View {
    return M13.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

test "M13: omitted optional flags resolve to null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m13Parse(&arena, &.{ "-r", "x", "f" }, &diag);
    try std.testing.expectEqualStrings("x", v.req);
    try std.testing.expectEqualStrings("f", v.file);
    try std.testing.expect(v.opt_str == null);
    try std.testing.expect(v.opt_u32 == null);
    try std.testing.expect(v.opt_bool == null);
}

test "M13: provided optional flags decode in every form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v1 = try m13Parse(&arena, &.{ "-r", "x", "--num=7", "f" }, &diag);
    try std.testing.expectEqual(@as(?u32, 7), v1.opt_u32);
    const v2 = try m13Parse(&arena, &.{ "-r", "x", "-s", "hello", "f" }, &diag);
    try std.testing.expectEqualStrings("hello", v2.opt_str.?);
    const v3 = try m13Parse(&arena, &.{ "-r", "x", "--num", "9", "f" }, &diag);
    try std.testing.expectEqual(@as(?u32, 9), v3.opt_u32);
    const v4 = try m13Parse(&arena, &.{ "-r", "x", "--maybe", "f" }, &diag);
    try std.testing.expectEqual(@as(?bool, true), v4.opt_bool);
    const v5 = try m13Parse(&arena, &.{ "-r", "x", "--maybe=false", "f" }, &diag);
    try std.testing.expectEqual(@as(?bool, false), v5.opt_bool);
}

test "M13: bad optional value reports InvalidWire with field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.InvalidWire, m13Parse(&arena, &.{ "-r", "x", "--num=abc", "f" }, &diag));
    try std.testing.expectEqualStrings("opt_u32", diag.field.?);
}

test "M13: validation is skipped when the optional flag is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m13Parse(&arena, &.{ "-r", "x", "f" }, &diag);
    try std.testing.expect(v.opt_str == null);
    try std.testing.expect(diag.message == null);
}

test "M13: validation runs when the optional flag is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.InvalidValue, m13Parse(&arena, &.{ "-r", "x", "-s", "", "f" }, &diag));
    try std.testing.expectEqualStrings("opt_str", diag.field.?);
    if (diag.message) |m| allocatorFree(&arena, m);
}

test "M13: help marks optional flags and omits them from usage" {
    var data = try M13.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    var found = false;
    for (data.flag_groups) |g| {
        for (g.flags) |o| {
            if (std.mem.eql(u8, o.name, "num")) {
                found = true;
                try std.testing.expect(o.optional);
            }
        }
    }
    try std.testing.expect(found);

    const Flat = generate(App{ .name = "m13", .help = "m13", .help_renderer = .{ .highlight = .{ .flat = {} } } }, M13Def);
    const h = try Flat.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "--num") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "--maybe") != null);
    const usage_end = std.mem.indexOf(u8, h, "\n").?;
    const usage = h[0..usage_end];
    try std.testing.expect(std.mem.indexOf(u8, usage, "--num") == null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--maybe") == null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "-r") != null);
}

test "M13: optional flags work inside groups and commands" {
    const def = .{
        .grp = Group(.{ .og = Optional(Flag(u32){ .long = "og" }) }, "g"),
        .run = Command(.{ .help = "Run." }, .{
            .sub_opt = Optional(Flag([]const u8){ .long = "so" }),
        }),
    };
    const C = generate(App{ .name = "c", .help = "c" }, def);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{"run"}, &diag);
    try std.testing.expect(v.og == null);
    try std.testing.expect(v._run != null);
    try std.testing.expect(v._run.?.sub_opt == null);
    const v2 = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "--og=5", "run", "--so", "z" }, &diag);
    try std.testing.expectEqual(@as(?u32, 5), v2.og);
    try std.testing.expectEqualStrings("z", v2._run.?.sub_opt.?);
}

test "M13: raw optional spelling behaves identically" {
    const def = .{
        .raw = @as(?Flag(u16), Flag(u16){ .long = "raw" }),
    };
    const C = generate(App{ .name = "r", .help = "r" }, def);
    var seen = false;
    inline for (C.specs) |s| {
        if (comptime std.mem.eql(u8, s.name, "raw")) {
            seen = true;
            try std.testing.expect(s.optional);
        }
    }
    try std.testing.expect(seen);
    try std.testing.expectEqual(?u16, @FieldType(C.View, "raw"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{}, &diag);
    try std.testing.expect(v.raw == null);
    const v2 = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{"--raw=3"}, &diag);
    try std.testing.expectEqual(@as(?u16, 3), v2.raw);
}

test "M13: Optional helper preserves the payload and rejects non-flags" {
    const F = Flag(u8){ .short = "z" };
    const O = Optional(F);
    try std.testing.expect(@typeInfo(@TypeOf(O)) == .optional);
    try std.testing.expect(@typeInfo(@TypeOf(O)).optional.child.dap_value_type == u8);
    if (false) {
        _ = Optional(Argument([]const u8){});
    }
    if (false) {
        _ = Optional(3);
    }
}

test "M13: optional flag with a direct default is a compile error" {
    if (false) {
        const Bad = .{ .x = Optional(Flag(u8){ .default = Default(u8){ .direct = 1 } }) };
        comptime _ = normalize(Bad);
    }
}

test "M13: optional flag with an env default is a compile error" {
    if (false) {
        const Bad = .{ .x = Optional(Flag(u8){ .default = Default(u8){ .env = "X" } }) };
        comptime _ = normalize(Bad);
    }
}

test "M13: optional argument is a compile error" {
    if (false) {
        const Bad = .{ .x = @as(?Argument(u8), Argument(u8){}) };
        comptime _ = normalize(Bad);
    }
}

test "M13: optional flag inside an Alt branch is a compile error" {
    if (false) {
        const Bad = .{ .mode = Alt(.{ .a = .{ .x = Optional(Flag(u8){}) } }) };
        comptime _ = normalize(Bad);
    }
}

// ---------------------------------------------------------------------------
// M14: context-sensitive help for nested subcommands.
// ---------------------------------------------------------------------------

const M14Def = .{
    .verbose = Flag(bool){ .short = "v", .default = Default(bool){ .direct = false }, .help = "Root verbose." },
    .config = Flag([]const u8){ .help = "Root config path." },
    .server = Group(.{ .host = Flag([]const u8){ .help = "Root host." } }, "Server"),
    .mode = Alt(.{ .fast = .{ .fast = Flag(bool){ .help = "Fast mode." } } }),
    .svc = Command(.{ .help = "Service command." }, .{
        .port = Flag(u16){ .default = Default(u16){ .direct = 8080 }, .help = "Port." },
        .server = Group(.{ .token = Flag([]const u8){ .help = "Service token." } }, "Server"),
        .build = Command(.{ .help = "Build." }, .{
            .target = Argument([]const u8){ .help = "Build target." },
        }),
    }),
    .one = Command(.{ .help = "One." }, .{ .only = Flag(bool){ .default = Default(bool){ .direct = false } } }),
    .two = Command(.{ .help = "Two." }, .{ .also = Flag(bool){ .default = Default(bool){ .direct = false } } }),
};

const M14 = generate(
    App{ .name = "m14", .help = "M14 root.", .help_renderer = .{ .highlight = .{ .flat = {} } } },
    M14Def,
);

fn m14Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M14.View {
    return M14.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

const M14SvcGolden =
    \\Usage: m14 svc --config=CONFIG --host=HOST --token=TOKEN (--fast) <command> [flags]
    \\
    \\Service command.
    \\
    \\Flags:
    \\  -h, --help             Show context-sensitive help.
    \\  -v, --verbose          Root verbose.
    \\      --config=CONFIG    Root config path.
    \\      --port=8080        Port.
    \\
    \\Server
    \\  --host=HOST      Root host.
    \\  --token=TOKEN    Service token.
    \\
    \\fast
    \\  --fast    Fast mode.
    \\
    \\Commands:
    \\  build    Build.
    \\
;

const M14BuildGolden =
    \\Usage: m14 svc build --config=CONFIG --host=HOST --token=TOKEN (--fast) <target> [flags]
    \\
    \\Build.
    \\
    \\Arguments:
    \\  <target>    Build target.
    \\
    \\Flags:
    \\  -h, --help             Show context-sensitive help.
    \\  -v, --verbose          Root verbose.
    \\      --config=CONFIG    Root config path.
    \\      --port=8080        Port.
    \\
    \\Server
    \\  --host=HOST      Root host.
    \\  --token=TOKEN    Service token.
    \\
    \\fast
    \\  --fast    Fast mode.
    \\
;

test "M14: deep help request bypasses every required check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // Root `--config` is required and absent, yet the deep help request parses.
    const vsvc = try m14Parse(&arena, &.{ "svc", "-h" }, &diag);
    try std.testing.expect(helpRequested(M14, &vsvc));
    try std.testing.expect(vsvc._svc != null);

    const vbuild = try m14Parse(&arena, &.{ "svc", "build", "-h" }, &diag);
    try std.testing.expect(helpRequested(M14, &vbuild));
    try std.testing.expect(vbuild._svc != null);
    try std.testing.expect(vbuild._svc.?._build != null);
}

test "M14: root help stays root-scoped and byte-identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const vroot = try m14Parse(&arena, &.{"-h"}, &diag);
    const ctx = try contextHelpText(M14, arena.allocator(), &vroot);
    const root = try M14.helpText(arena.allocator());
    try std.testing.expectEqualStrings(root, ctx);
}

test "M14: usage header reconstructs the command path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const v = try m14Parse(&arena, &.{ "svc", "-h" }, &diag);
    const h = try contextHelpText(M14, arena.allocator(), &v);
    const first_line = h[0..std.mem.indexOfScalar(u8, h, '\n').?];
    try std.testing.expectEqualStrings(
        "Usage: m14 svc --config=CONFIG --host=HOST --token=TOKEN (--fast) <command> [flags]",
        first_line,
    );
}

test "M14: flags accumulate from every ancestor level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const v = try m14Parse(&arena, &.{ "svc", "-h" }, &diag);
    const h = try contextHelpText(M14, arena.allocator(), &v);
    try std.testing.expectEqualStrings(M14SvcGolden, h);

    // The merged scope lists the injected builtin help exactly once.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, h, "Show context-sensitive help."),
    );
}

test "M14: arguments and next commands come from the deepest scope only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const vbuild = try m14Parse(&arena, &.{ "svc", "build", "-h" }, &diag);
    const hbuild = try contextHelpText(M14, arena.allocator(), &vbuild);
    try std.testing.expectEqualStrings(M14BuildGolden, hbuild);

    // The `svc` scope lists `build` but neither sibling `one` nor `two`.
    const vsvc = try m14Parse(&arena, &.{ "svc", "-h" }, &diag);
    const hsvc = try contextHelpText(M14, arena.allocator(), &vsvc);
    try std.testing.expect(std.mem.indexOf(u8, hsvc, "  build    ") != null);
    try std.testing.expect(std.mem.indexOf(u8, hsvc, "  one    ") == null);
    try std.testing.expect(std.mem.indexOf(u8, hsvc, "  two    ") == null);
}

test "M14: info shows the deepest command help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const v = try m14Parse(&arena, &.{ "svc", "build", "-h" }, &diag);
    const h = try contextHelpText(M14, arena.allocator(), &v);
    try std.testing.expect(std.mem.indexOf(u8, h, "Build.") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "M14 root.") == null);
    try std.testing.expect(std.mem.indexOf(u8, h, "Service command.") == null);
}

test "M14: help token before the commands scopes to the deepest active command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const v = try m14Parse(&arena, &.{ "-h", "svc", "build" }, &diag);
    const h = try contextHelpText(M14, arena.allocator(), &v);
    try std.testing.expectEqualStrings(M14BuildGolden, h);
}

test "M14: merged help frees everything when an allocation fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m14Parse(&arena, &.{ "svc", "build", "-h" }, &diag);

    const FailingAllocator = std.testing.FailingAllocator;
    const total = blk: {
        var probe = FailingAllocator.init(std.testing.allocator, .{});
        const text = try contextHelpText(M14, probe.allocator(), &v);
        probe.allocator().free(text);
        break :blk probe.allocations;
    };

    var fi: usize = 0;
    while (fi <= total) : (fi += 1) {
        var fa = FailingAllocator.init(std.testing.allocator, .{ .fail_index = fi });
        if (contextHelpText(M14, fa.allocator(), &v)) |text| {
            fa.allocator().free(text);
        } else |e| {
            try std.testing.expectEqual(std.mem.Allocator.Error.OutOfMemory, e);
        }
        try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    }
}

test "M14: generated namespace exposes usage" {
    // Not invoked: writing to stdout in a test can hang the runner. Only the
    // declaration is checked here; `zig build run` exercises the printing.
    try std.testing.expect(@hasDecl(M14, "usage"));
    comptime try std.testing.expect(@TypeOf(M14.usage) == fn (M14.View) std.mem.Allocator.Error!void);
}

test "M14: duplicate long flag across levels is a compile error" {
    if (false) {
        const Bad = .{
            .dup = Flag([]const u8){ .long = "dup" },
            .svc = Command(.{ .help = "S." }, .{
                .dup = Flag([]const u8){ .long = "dup" },
            }),
        };
        comptime _ = generate(App{ .name = "m14", .help = "" }, Bad);
    }
}

test "M14: duplicate short flag across levels is a compile error" {
    if (false) {
        const Bad = .{
            .dup = Flag(u8){ .long = "dup", .short = "d" },
            .svc = Command(.{ .help = "S." }, .{
                .dup2 = Flag(u8){ .long = "dup2", .short = "d" },
            }),
        };
        comptime _ = generate(App{ .name = "m14", .help = "" }, Bad);
    }
}

test "M14: duplicate flag across sibling commands is a compile error" {
    if (false) {
        const Bad = .{
            .one = Command(.{ .help = "One." }, .{ .same = Flag(u8){ .long = "same" } }),
            .two = Command(.{ .help = "Two." }, .{ .same = Flag(u8){ .long = "same" } }),
        };
        comptime _ = generate(App{ .name = "m14", .help = "" }, Bad);
    }
}

// ---------------------------------------------------------------------------
// M15: CLI.command, the optional tagged union of subcommands.
// ---------------------------------------------------------------------------

test "M15: command returns null when no command token appeared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const a = try m7Parse(&arena, &.{ "--needed", "v" }, &diag);
    try std.testing.expect(M7.command(a) == null);
}

test "M15: command wraps the active sub-view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const a = try m7Parse(&arena, &.{ "--verbose", "--needed", "v", "start", "--force", "file" }, &diag);
    switch (M7.command(a).?) {
        .start => |s| {
            try std.testing.expectEqualStrings("file", s.name);
            try std.testing.expect(s.force);
        },
        .stop, .nested => return error.TestUnexpectedResult,
    }
}

test "M15: command tags are declaration field names, not wire names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const a = try m7Parse(&arena, &.{ "--needed", "v", "halt" }, &diag);
    try std.testing.expectEqual(@as(std.meta.Tag(M7.CommandPayload), .stop), std.meta.activeTag(M7.command(a).?));
}

test "M15: nested commands stay reachable through the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const a = try m7Parse(&arena, &.{ "--needed", "v", "nested", "deep", "5" }, &diag);
    switch (M7.command(a).?) {
        .nested => |n| try std.testing.expectEqual(@as(u8, 5), n._deep.?.n),
        .start, .stop => return error.TestUnexpectedResult,
    }
}

test "M15: a single command builds a one-tag payload" {
    const C = generate(App{ .name = "one", .help = "one" }, .{
        .go = Command(.{ .help = "Go." }, .{ .n = Argument(u8){} }),
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "go", "5" }, &diag);
    switch (C.command(v).?) {
        .go => |g| try std.testing.expectEqual(@as(u8, 5), g.n),
    }
}

test "M15: command coexists with Alt and optional flags at the root" {
    const C = generate(App{ .name = "mixed", .help = "mixed" }, M12MixedDef);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "-v", "--x=3", "go" }, &diag);
    try std.testing.expectEqual(@as(std.meta.Tag(C.CommandPayload), .go), std.meta.activeTag(C.command(v).?));
    switch (v.mode.?) {
        .a => |p| try std.testing.expectEqual(@as(u32, 3), p.x),
        .b => return error.TestUnexpectedResult,
    }
}

test "M15: CommandPayload members match the sub-view types" {
    inline for (M7.commands) |c| {
        try std.testing.expectEqual(@as(type, Sub(c.Cmd, subApp(M7.app_meta, c)).View), @FieldType(M7.CommandPayload, c.field));
        try std.testing.expectEqual(@as(type, ?@FieldType(M7.CommandPayload, c.field)), @FieldType(M7.View, c.view_field));
    }
}

test "M15: command and CommandPayload are omitted without commands" {
    const C = generate(App{ .name = "plain", .help = "" }, .{
        .a = Flag(u8){ .default = Default(u8){ .direct = 0 } },
        .b = Argument([]const u8){},
    });
    try std.testing.expect(!@hasDecl(C, "command"));
    try std.testing.expect(!@hasDecl(C, "CommandPayload"));
    if (false) {
        // enabling this must fail to compile: no member named 'command'
        // _ = C.command;
    }
}

test "M15: the command shell forwards the base members" {
    try std.testing.expect(@hasDecl(M7, "command"));
    try std.testing.expect(@hasDecl(M7, "CommandPayload"));
    try std.testing.expect(@hasDecl(M7, "app_meta"));
    try std.testing.expect(@hasDecl(M7, "specs"));
    try std.testing.expect(@hasDecl(M7, "commands"));
    try std.testing.expect(@hasDecl(M7, "View"));
    try std.testing.expect(@hasDecl(M7, "parse"));
    try std.testing.expect(@hasDecl(M7, "parseInner"));
    try std.testing.expect(@hasDecl(M7, "parseInnerHelp"));
    try std.testing.expect(@hasDecl(M7, "helpData"));
    try std.testing.expect(@hasDecl(M7, "helpText"));

    try std.testing.expect(@hasDecl(M13, "parse"));
    try std.testing.expect(!@hasDecl(M13, "command"));
    try std.testing.expect(!@hasDecl(M13, "CommandPayload"));
}
