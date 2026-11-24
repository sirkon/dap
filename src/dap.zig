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
//!     pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!Self
//!     pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8
//!     pub fn deinit(self: *Self, allocator: std.mem.Allocator) void
//!
//! `decode` is a static constructor: it takes the allocator and the wire token
//! and returns a fully built value, so types with internal allocations (arg
//! arrays, nested buffers) can own them. `encode` builds the wire spelling
//! into allocator-owned memory the caller frees. `deinit` releases a value's
//! internals; it must NOT call `allocator.destroy(self)` (the value is a copy).
//!
//! These three methods are the stable contract. Every field of a `View`
//! returned by a successful `parse` is owned by the caller; release it with
//! `CLI.deinit(&view, allocator)` (see the `generate` docs).
//!
//! The list is intended to grow with optional methods (for completions and
//! such), but `decode`/`encode`/`deinit` will always be required.

const std = @import("std");
const stdcompare = @import("stdcompare.zig");
const i18n_mod = @import("i18n.zig");
comptime {
    _ = i18n_mod;
}
pub const I18n = i18n_mod.I18n;

/// Reflection view of a single struct field. Zig 0.17 replaced the
/// `StructField`/`UnionField` structs with parallel `field_names`,
/// `field_types` and `field_attrs` arrays; this pairs them back up so the
/// rest of the file can keep iterating fields as one value.
const Field = struct {
    name: [:0]const u8,
    type: type,
    attrs: std.builtin.Type.Struct.FieldAttributes,
};

fn fieldsOf(comptime T: type) [@typeInfo(T).@"struct".field_names.len]Field {
    const info = @typeInfo(T).@"struct";
    var out: [info.field_names.len]Field = undefined;
    for (info.field_names, info.field_types, info.field_attrs, 0..) |name, ty, attrs, i| {
        out[i] = .{ .name = name, .type = ty, .attrs = attrs };
    }
    return out;
}

/// Kind of a declaration field.
pub const Kind = enum {
    flag,
    argument,
    group,
    command,
    alt,
};

/// Errors help rendering and diagnostics can report: allocation failures plus
/// missing translation keys.
pub const HelpError = std.mem.Allocator.Error || I18n.Error;

/// Renderer style selection: `.compact` renders the builtin kong-style
/// two-column layout; `.custom` carries a user-provided renderer function
/// `fn (*const HelpData, *const I18n.Locale, Allocator) HelpError!String`
/// that receives the locale selected for the render and returns a
/// caller-owned string.
pub const HelpRendererStyle = union(enum) {
    compact: void,
    custom: *const fn (
        self: *const HelpData,
        locale: *const I18n.Locale,
        allocator: std.mem.Allocator,
    ) HelpError!String,
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

/// Program metadata: the usage path, the description shown by help, and the
/// renderer configuration. `i18n` names a translation for `help`.
pub const App = struct {
    /// Usage name or full command path, e.g. `"app"` or `"app svc"`.
    name: String,
    /// Description shown by help.
    help: String,
    /// Translation key for `help`; resolved through the selected locale.
    i18n: ?String = null,

    help_renderer: struct {
        style: HelpRendererStyle = @unionInit(HelpRendererStyle, "compact", {}),
        highlight: HelpRendererHighlight = @unionInit(HelpRendererHighlight, "bold", {}),
    } = .{},

    /// Internal: pre-order rank of this level in the command tree. `subApp`
    /// assigns it to every command level; the generated `View` carries a
    /// zero-sized tag field named after it, so levels with otherwise equal
    /// layouts get distinct (non-interned) types.
    _command_rank: usize = 0,
};

// Help text highlighting definition and ready schemes.
pub const HelpHighlight = struct {
    pub const Flag = struct {
        name: []const u8 = "",
        value: []const u8 = "",
    };

    usage: struct {
        error_msg: []const u8 = "",
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
            .error_msg = "\x1b[1;91m",
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

        /// Help string, used directly when `i18n` is null and as the
        /// declaration default locale's translation otherwise.
        help: String = "",

        /// Translation key for `help`, optional. Field-name-shaped, unique
        /// across the declaration tree, and not a builtin key.
        i18n: ?String = null,

        /// Completion predictor, optional. Values are offered by the generated
        /// shell scripts instead of the shell's own completion. Not allowed on
        /// a `bool` or an `Enumeration`.
        completion: ?completion_mod.Completion.Predictor = null,
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

        /// Argument description, used directly when `i18n` is null and as the
        /// declaration default locale's translation otherwise.
        help: String = "",

        /// Translation key for `help`, optional. Field-name-shaped, unique
        /// across the declaration tree, and not a builtin key.
        i18n: ?String = null,

        /// Completion predictor, optional. Values are offered by the generated
        /// shell scripts instead of the shell's own completion. Not allowed on
        /// a `bool` or an `Enumeration`.
        completion: ?completion_mod.Completion.Predictor = null,
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
/// The resulting type exposes those wire names as `names`, each branch's
/// declared help as `helps`, and its optional translation key as `help_i18n`.
/// Help rendering and completion both use `helps` as the default-locale
/// literal; `help_i18n` carries the branch translation keys. A non-empty
/// result exposes all three arrays; the empty result exposes none.
///
/// Resulting names must be validated against using the same name for different branches (which may happen with custom
/// ones).
///
/// It creates a valid type with `decode`/`encode` methods matching the custom
/// value-type contract. The view must be a Zig enumeration:
/// ```
/// enum{
///     branch1,
///     branch2,
///     ...
/// }
/// ```
pub fn Enumeration(comptime T: anytype) type {
    const fields = fieldsOf(@TypeOf(T));

    if (fields.len == 0) {
        // No branches: there is no tag type to build a `@Enum` from. Degenerate
        // but still usable as a value type (never accepts a wire token).
        return struct {
            /// Marks this as an `Enumeration` result; completion predictors are
            /// rejected on such values.
            pub const dap_enumeration = {};

            pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!@This() {
                _ = allocator;
                _ = data;
                return error.InvalidWire;
            }

            pub fn encode(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
                _ = self;
                return try allocator.dupe(u8, "");
            }

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                _ = self;
                _ = allocator;
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
            if (@typeInfo(@TypeOf(E)) != .@"struct" or
                !@hasField(@TypeOf(E), "name") or
                !@hasField(@TypeOf(E), "help"))
            {
                @compileError("enumeration branch '" ++ f.name ++ "' must be a dap.Enum");
            }
            if (E.help) |h| {
                if (@typeInfo(@TypeOf(h)) != .@"struct" or !@hasField(@TypeOf(h), "text")) {
                    @compileError("enumeration branch '" ++ f.name ++ "' must be a dap.Enum");
                }
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

    const wire_helps: [fields.len]?String = blk: {
        var a: [fields.len]?String = undefined;
        for (fields, 0..) |f, i| {
            const E = @field(T, f.name);
            a[i] = if (E.help) |h| h.text else null;
        }
        break :blk a;
    };

    const wire_help_i18n: [fields.len]?String = blk: {
        var a: [fields.len]?String = undefined;
        for (fields, 0..) |f, i| {
            const E = @field(T, f.name);
            a[i] = if (E.help) |h|
                (if (@hasField(@TypeOf(h), "i18n")) h.i18n else null)
            else
                null;
        }
        break :blk a;
    };

    const TagInt = std.math.IntFittingRange(0, fields.len - 1);
    const View = @Enum(TagInt, .exhaustive, &branch_names, blk: {
        var a: [fields.len]TagInt = undefined;
        for (0..fields.len) |i| a[i] = @intCast(i);
        const arr: [fields.len]TagInt = a;
        break :blk &arr;
    });

    return struct {
        view: View = @fromBackingInt(@intCast(0)),

        /// Marks this as an `Enumeration` result; completion predictors are
        /// rejected on such values.
        pub const dap_enumeration = {};

        pub const EnumView = View;
        pub const names = wire_names;
        pub const helps = wire_helps;
        pub const help_i18n = wire_help_i18n;

        pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!@This() {
            _ = allocator;
            inline for (wire_names, 0..) |nm, i| {
                if (std.mem.eql(u8, nm, data)) {
                    return .{ .view = @fromBackingInt(@intCast(@as(TagInt, @intCast(i)))) };
                }
            }
            return error.InvalidWire;
        }

        pub fn encode(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
            return try allocator.dupe(u8, wire_names[@backingInt(self.view)]);
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
}

pub const Enum = struct {
    /// Wire name override; derived from the declaration field name when null.
    name: ?String = null,
    /// Help declarable per branch. `text` is the default-locale literal;
    /// `i18n` is an optional translation key. Help rendering and completion
    /// both use `text` as the fallback and `i18n` as the localized spelling.
    help: ?struct {
        text: String,
        i18n: ?String = null,
    } = null,
};

/// Command description. `synonym` is an alternative wire name accepted in
/// place of the command's primary name (`name` orelse the declaration field
/// name); it is an extra spelling of the same command, not a separate one.
/// `i18n` names a translation for `help`; the child `App` derives its key from
/// it, so the command and its app description are one i18n origin.
pub const CommandMeta = struct {
    name: ?String = null,
    synonym: ?String = null,
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
/// `null` unless that command's wire name (`.name` orelse the field name), or
/// its optional `.synonym`, appears. This is how the parsed sub-view is
/// carried, but it is an
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
///
/// The same accessor accepts a `View` from any level of the tree, so dispatch
/// nests; each level's union carries its own tags:
///
/// ```
/// if (CLI.command(cli)) |cmd| switch (cmd) {
///     .body => |b| {
///         if (CLI.command(b)) |subcmd| switch (subcmd) {
///             .left => |l| runLeft(l),
///             .right => |r| runRight(r),
///         } else {
///             // `body` with no subcommand token
///         }
///     },
/// } else {
///     // root level execution
/// }
/// ```
///
/// A `View` whose level declares no subcommands (a leaf) is a compile error,
/// as is a value that is not a `View` of this tree.
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
    const fields = fieldsOf(@TypeOf(T));
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
            const bf = fieldsOf(@TypeOf(Bdef));
            var nm: [bf.len]String = undefined;
            var ts: [bf.len]type = undefined;
            var at: [bf.len]std.builtin.Type.Struct.FieldAttributes = undefined;
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
        var a: [tnames.len]std.builtin.Type.Union.FieldAttributes = undefined;
        for (0..tnames.len) |i| a[i] = .{};
        const arr: [tnames.len]std.builtin.Type.Union.FieldAttributes = a;
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

/// This error can be returned on decode. Custom `decode` receives the shared
/// allocator and may allocate internal storage (arrays, nested buffers), so
/// the allocator's error set is folded in.
pub const DecodeError = std.mem.Allocator.Error || error{
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

/// One candidate a rejected token may have meant, plus how it was ranked. All
/// strings are borrowed from the declaration (compile-time known, `'static`
/// lifetime), so the struct owns nothing and never allocates.
pub const SuggestValid = struct {
    /// The candidate's wire name as typed by the user, without the leading
    /// dashes: the bare flag long name or the bare command name. Rendering
    /// adds the `--` prefix for flags (or a `-` for a short candidate).
    name: String,
    /// Short spelling when the candidate has one and was ranked via it.
    short: ?String = null,
    /// The namespace the candidate lives in.
    kind: SuggestValid.Kind,
    /// Levenshtein distance between the normalized unknown token and the
    /// candidate; lower is better.
    distance: usize,
    /// Why this candidate was chosen: `edit` (edit distance below the
    /// threshold) or `prefix` (the candidate extends the token's body).
    reason: Reason,

    pub const Kind = enum { flag, cmd };
    pub const Reason = enum { edit, prefix };
};

/// A suggestion for a rejected token: the union tag is the candidate
/// namespace, mirroring [`SuggestValid.kind`] so a copied payload keeps its
/// meaning while renderers `switch` on the tag.
pub const Suggest = union(enum) {
    flag: SuggestValid,
    cmd: SuggestValid,
};

/// Diagnostic detail for the most recent failed `parse`. `field` and `token`
/// borrow caller-owned memory (declaration names / argv); `message` is
/// allocated with the parser's allocator and must be released by `deinit`.
pub const Diag = struct {
    field: ?String = null,
    token: ?String = null,
    message: ?String = null,
    /// Populated when a flag token or a bare command-shaped token matched no
    /// declaration but a close candidate exists. The payload strings are
    /// borrowed from the declaration (compile-time known), so `deinit` does
    /// not touch them; reading `unknown` after the parse call is safe.
    unknown: ?Suggest = null,

    pub fn deinit(self: *Diag, allocator: std.mem.Allocator) void {
        if (self.message) |m| allocator.free(m);
        self.message = null;
    }
};

/// Resolve one help entry: a keyed entry looks the key up in `locale`, an
/// unkeyed one uses its literal. The result is borrowed from the locale or
/// from `literal`; callers must not free it. A missing key is an error, never
/// a fallback to the literal.
fn resolve(
    locale: *const I18n.Locale,
    key: ?String,
    literal: String,
) HelpError!String {
    if (key) |k| return locale.require(k);
    return literal;
}

/// Instantiate a diagnostic template with runtime arguments. Zig's formatting
/// APIs need a comptime format string, but `I18n.Locale.Diag` templates are
/// runtime values; this copies the template and replaces each `{s}` with the
/// next argument. `I18n.validate` guarantees the slot count and that no other
/// braces exist, so an exhausted argument list is a programming error.
fn fillTemplate(
    allocator: std.mem.Allocator,
    template: String,
    args: []const String,
) std.mem.Allocator.Error!String {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var arg_i: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (i + 2 < template.len and template[i] == '{' and template[i + 1] == 's' and template[i + 2] == '}') {
            std.debug.assert(arg_i < args.len);
            try out.appendSlice(allocator, args[arg_i]);
            arg_i += 1;
            i += 3;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Runtime-filled description of a generated CLI, suitable for rendering help
/// text or driving other help UIs (completion, man pages). Unlike the raw
/// comptime metadata it carries only plain data: every string and slice is
/// allocated with the caller's allocator and released by `deinit`.
pub const HelpData = struct {
    const Self = @This();

    /// One declared branch of an enumeration-valued spec. `help == null`
    /// means the branch declares no help; `help == ""` means help was declared
    /// with an empty literal. `i18n` is the optional translation key declared
    /// beside the text. Owned by the enclosing [`Flag`]/[`Argument`].
    pub const Value = struct {
        /// Wire name.
        name: String,
        /// Declared help literal, or `null` when none was declared.
        help: ?String,
        /// Declared translation key, or `null`.
        i18n: ?String,
    };

    /// A single flag entry.
    pub const Flag = struct {
        /// Long wire name, e.g. `dry_run` or an explicit `.long`.
        name: String,
        /// Short wire name, without the dash.
        short: ?String,
        /// Help string.
        help: String,
        /// Rendered default value: the direct value, `$NAME` for an
        /// environment-only default, or `null` when the flag has no default.
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
        /// Translation key for `help`, when the declaration declared one.
        /// `null` means the literal is rendered as-is.
        i18n: ?String = null,
        /// Declared enumeration branches in declaration order. Empty for
        /// non-enumeration types and for an empty `Enumeration`. Owned by
        /// this entry; `usage_alts` shallow copies never free it.
        values: []Value = &.{},
    };

    /// A single positional argument entry.
    pub const Argument = struct {
        /// `.name` override or the declaration field name.
        name: String,
        /// Help string.
        help: String,
        /// Rendered default value: the direct value, `$NAME` for an
        /// environment-only default, or `null` when the argument has no
        /// default.
        default: ?String,
        /// Translation key for `help`, when the declaration declared one.
        /// `null` means the literal is rendered as-is.
        i18n: ?String = null,
        /// Declared enumeration branches in declaration order. Empty for
        /// non-enumeration types and for an empty `Enumeration`. Owned by
        /// this entry.
        values: []Value = &.{},
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
        /// Translation key for `help`, when the command declared one.
        /// `null` means the literal is rendered as-is.
        i18n: ?String = null,
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
    /// Translation key for `info`, when the app declared one. `null` means
    /// the literal description is rendered as-is.
    info_i18n: ?String = null,
    /// Flag groups; ungrouped flags first, then named groups in declaration order.
    flag_groups: []FlagGroup,
    /// Argument groups; ungrouped arguments first, then named groups in declaration order.
    arg_groups: []ArgGroup,
    /// Exclusive-parameter group clauses (one per `Alt`) for the usage line.
    usage_alts: []Usage = &.{},
    /// Subcommands in declaration order.
    commands: []CommandInfo,
    /// Optional error line rendered at the very top of the compact view,
    /// highlighted with `usage.error_msg`. Borrowed static or caller-owned
    /// text; it is *not* freed by `deinit` (the failure diagnostics own it).
    /// `null` for ordinary help.
    error_text: ?String = null,
    /// Highlight scheme `renderCompact` applies. Filled from
    /// `App.help_renderer.highlight`; the codes are borrowed static strings and
    /// are not freed by `deinit`.
    highlight: HelpRendererHighlight = .{ .flat = {} },

    pub fn deinit(self: *HelpData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.info);
        if (self.info_i18n) |k| allocator.free(k);

        for (self.flag_groups) |g| {
            if (g.name) |n| allocator.free(n);
            for (g.flags) |o| {
                allocator.free(o.name);
                if (o.short) |sh| allocator.free(sh);
                allocator.free(o.help);
                if (o.default) |dv| allocator.free(dv);
                if (o.alt) |av| allocator.free(av);
                if (o.alt_branch) |bv| allocator.free(bv);
                if (o.i18n) |k| allocator.free(k);
                freeValues(allocator, o.values);
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
                if (a.i18n) |k| allocator.free(k);
                freeValues(allocator, a.values);
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
            if (c.i18n) |k| allocator.free(k);
        }
        allocator.free(self.commands);
    }

    /// Render a compact, two-column help view of this description into a freshly
    /// allocated string, mirroring the layout of `kong`'s help renderer. The
    /// flag/argument specs occupy the left column (short and long names aligned
    /// into their own sub-columns) and the help text the right; groups are
    /// ordered by name with the ungrouped bucket first.
    ///
    /// `locale` supplies the structural headings and placeholders and resolves
    /// every keyed row through its user map; a missing key is an error, never a
    /// fallback to the literal. Named group headings stay literal. Every
    /// fragment is wrapped in the scheme carried by `highlight` (resolved from
    /// `App.help_renderer.highlight`): the usage header distinguishes the app
    /// name, required flags (name and value), optional tokens and arguments,
    /// while the grouped sections use the `groups`, `args` and `flags` (name
    /// and value) tokens. Delimiters join their token: the argument list wraps
    /// the whole `[<name>]`/`<name>` including brackets, each flag name carries
    /// its own leading dashes and trailing `=`, and the flag list keeps the
    /// `, ` separator uncolored. Widths are measured on the raw text before any
    /// codes are emitted, so highlighting never disturbs the column alignment.
    /// The caller owns the returned string and frees it with the same
    /// allocator.
    pub fn renderCompact(
        self: *const HelpData,
        locale: *const I18n.Locale,
        allocator: std.mem.Allocator,
    ) HelpError!String {
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

        // Failure diagnostics lead the view: the error line sits above the
        // usage header, highlighted with the error token.
        if (self.error_text) |e| {
            if (e.len > 0) {
                try appendHelpStyled(&out, allocator, hl, .error_msg, e);
                try out.append(allocator, '\n');
            }
        }

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
        try appendHelpStyled(&out, allocator, hl, .usage_label, locale.meta.usage);
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
            try appendHelpStyled(&out, allocator, hl, .usage_argument, locale.meta.cmds_placeholder);
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
            try appendHelpStyled(&out, allocator, hl, .usage_optional, locale.meta.flags_placeholder);
        }
        try out.append(allocator, '\n');

        if (self.info.len > 0 or self.info_i18n != null) {
            try out.append(allocator, '\n');
            try appendHelpStyled(&out, allocator, hl, .plain, try resolve(locale, self.info_i18n, self.info));
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
                    rows[ri] = .{
                        .left = left.items,
                        .help = try resolve(locale, a.i18n, a.help),
                        .values = try fillRowsValues(arena, locale, a.values),
                        .default_clause = a.default,
                    };
                    ri += 1;
                }
            }
            sections[si] = .{ .heading = locale.meta.args, .rows = rows };
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
                rows[ri] = .{
                    .left = left.items,
                    .help = try resolve(locale, o.i18n, o.help),
                    .values = try fillRowsValues(arena, locale, o.values),
                };
            }
            sections[si] = .{ .heading = group.name orelse locale.meta.flags, .rows = rows };
            si += 1;
        }

        if (self.commands.len > 0) {
            const rows = try arena.alloc(HelpRow, self.commands.len);
            for (self.commands, 0..) |c, ri| {
                var left: std.ArrayList(HelpSegment) = .empty;
                try left.append(arena, .{ .text = c.name, .style = .flags_name });
                rows[ri] = .{ .left = left.items, .help = try resolve(locale, c.i18n, c.help) };
            }
            sections[si] = .{ .heading = locale.meta.cmds, .rows = rows };
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
            // Absolute column where the right column starts. Every row of the
            // section lands there, on the same line or on a continuation line.
            const h = indent.len + left_size + column_padding;
            for (section.rows) |r| {
                const left_w = helpSegmentsWidth(r.left);
                const wide = left_w >= max_left;
                try out.appendSlice(allocator, indent);
                try appendHelpSegments(&out, allocator, hl, r.left);

                const has_default_clause = r.default_clause != null;
                // The form is chosen from the declaration, never from the
                // resolved text: a translation cannot change the geometry.
                const inline_form = r.values.len <= 4 and !hasDeclaredHelp(r.values);
                if (inline_form) {
                    const has_values = r.values.len > 0;
                    // Padding to `h` precedes the first fragment; an
                    // overflowing left column continues on the next line at
                    // the same column. No right content means no padding.
                    if (r.help.len > 0 or has_default_clause or has_values) {
                        if (wide) {
                            try out.append(allocator, '\n');
                            try out.appendSlice(allocator, indent);
                            try appendSpaces(&out, allocator, left_size + column_padding);
                        } else {
                            try appendSpaces(&out, allocator, left_size - left_w + column_padding);
                        }
                    }
                    var emitted = false;
                    if (r.help.len > 0) {
                        try appendHelpStyled(&out, allocator, hl, .plain, r.help);
                        emitted = true;
                    }
                    if (r.default_clause) |dv| {
                        if (emitted) try out.append(allocator, ' ');
                        try appendDefaultClause(&out, allocator, hl, locale, dv);
                        emitted = true;
                    }
                    if (has_values) {
                        if (emitted) try out.append(allocator, ' ');
                        try appendValuesClause(&out, allocator, hl, locale, r.values);
                    }
                } else {
                    // Column form: the help text and an argument's default
                    // clause share the first line, then the branch block.
                    if (r.help.len > 0 or has_default_clause) {
                        if (wide) {
                            try out.append(allocator, '\n');
                            try out.appendSlice(allocator, indent);
                            try appendSpaces(&out, allocator, left_size + column_padding);
                        } else {
                            try appendSpaces(&out, allocator, left_size - left_w + column_padding);
                        }
                        var emitted = false;
                        if (r.help.len > 0) {
                            try appendHelpStyled(&out, allocator, hl, .plain, r.help);
                            emitted = true;
                        }
                        if (r.default_clause) |dv| {
                            if (emitted) try out.append(allocator, ' ');
                            try appendDefaultClause(&out, allocator, hl, locale, dv);
                        }
                    }
                    if (r.values.len > 0) {
                        try appendValuesBlock(&out, allocator, hl, locale, indent, h, r.values);
                    }
                }
                try out.append(allocator, '\n');
            }
        }

        return try out.toOwnedSlice(allocator);
    }
};

const completion_mod = @import("completion.zig");

comptime {
    // Force analysis of the completion module so its tests are collected when
    // this file is the `zig test` root, despite the two-file import cycle.
    _ = completion_mod;
}

const bridge_Spec = Spec;
const bridge_CommandEntry = CommandEntry;
const bridge_Sub = Sub;
const bridge_subApp = subApp;

/// Internal bridge for `completion.zig`; not part of the public API.
pub const _completion_internal = struct {
    pub const Spec = bridge_Spec;
    pub const CommandEntry = bridge_CommandEntry;
    pub const Sub = bridge_Sub;
    pub const subApp = bridge_subApp;
};

pub const Completion = completion_mod.Completion;

const checks_mod = @import("checks.zig");

comptime {
    // Force analysis of the checks module so its tests are collected when this
    // file is the `zig test` root, despite the two-file import cycle.
    _ = checks_mod;
}

const checks_bridge_Field = Field;
const checks_bridge_Spec = Spec;
const checks_bridge_NormResult = NormResult;
const checks_bridge_CommandEntry = CommandEntry;
const checks_bridge_fieldsOf = fieldsOf;
const checks_bridge_typeOfField = typeOfField;
const checks_bridge_normalize = normalize;
const checks_bridge_withBuiltinHelp = withBuiltinHelp;
const checks_bridge_specFromField = specFromField;
const checks_bridge_builtin_help_field = builtin_help_field;

/// Internal bridge for `checks.zig`; not part of the public API.
pub const _checks_internal = struct {
    pub const Field = checks_bridge_Field;
    pub const Spec = checks_bridge_Spec;
    pub const NormResult = checks_bridge_NormResult;
    pub const CommandEntry = checks_bridge_CommandEntry;
    pub const fieldsOf = checks_bridge_fieldsOf;
    pub const typeOfField = checks_bridge_typeOfField;
    pub const normalize = checks_bridge_normalize;
    pub const withBuiltinHelp = checks_bridge_withBuiltinHelp;
    pub const specFromField = checks_bridge_specFromField;
    pub const builtin_help_field = checks_bridge_builtin_help_field;
};

/// Highlight category a compact-help fragment belongs to.
const HelpStyle = enum {
    plain,
    error_msg,
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

/// One branch of an enumeration-valued spec, prepared for the compact
/// renderer: its wire name, its help text resolved through the selected
/// locale (possibly empty), and whether the declaration declared help at all.
/// `has_help` decides the value layout and is read from the declaration, so a
/// translation cannot change the geometry.
const HelpValue = struct {
    name: String,
    help: String,
    has_help: bool,
};

/// One left/right pair of a compact-help section. `left` is stored as raw
/// segments so column widths are measured on the plain text; the highlight
/// codes are applied only when the row is emitted. `values` holds the
/// enumeration branches, rendered either inline or as a block below the row.
/// `default_clause` holds an argument's rendered default value (the clause
/// label is emitted separately), never a prerendered sentence.
const HelpRow = struct {
    left: []const HelpSegment,
    help: []const u8,
    values: []const HelpValue = &.{},
    default_clause: ?[]const u8 = null,
};

/// A compact-help section: a heading plus its rows.
const HelpSection = struct {
    heading: []const u8,
    rows: []const HelpRow,
};

fn helpStyleCode(hl: HelpHighlight, style: HelpStyle) []const u8 {
    return switch (style) {
        .plain => "",
        .error_msg => hl.usage.error_msg,
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

/// Append `n` ASCII spaces.
fn appendSpaces(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    n: usize,
) std.mem.Allocator.Error!void {
    var left = n;
    while (left > 0) : (left -= 1) try out.append(allocator, ' ');
}

/// Append one argument's default clause: the locale's `default_value` label,
/// the value highlighted as a flag value, and a terminating period.
fn appendDefaultClause(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    hl: HelpHighlight,
    locale: *const I18n.Locale,
    value: []const u8,
) std.mem.Allocator.Error!void {
    try appendHelpStyled(out, allocator, hl, .plain, locale.meta.default_value);
    try appendHelpStyled(out, allocator, hl, .flags_value, value);
    try out.append(allocator, '.');
}

/// Append the single-line values clause: the locale's `possible_values`
/// label, the branch names in declaration order joined by `, `, each
/// highlighted as a flag value, and a terminating period. Callers only reach
/// here with at least one branch.
fn appendValuesClause(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    hl: HelpHighlight,
    locale: *const I18n.Locale,
    values: []const HelpValue,
) std.mem.Allocator.Error!void {
    try appendHelpStyled(out, allocator, hl, .plain, locale.meta.possible_values);
    for (values, 0..) |v, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try appendHelpStyled(out, allocator, hl, .flags_value, v.name);
    }
    try out.append(allocator, '.');
}

/// Append the column-form value block below a row: the label line at `h + 2`
/// (the label is `possible_values` without its trailing space) and one line
/// per branch at `h + 4`, names padded to the longest name in the block.
/// Branches whose help resolved to empty print only their name. There is no
/// trailing period here; it belongs to the single-line form.
fn appendValuesBlock(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    hl: HelpHighlight,
    locale: *const I18n.Locale,
    indent: []const u8,
    h: usize,
    values: []const HelpValue,
) std.mem.Allocator.Error!void {
    var name_width: usize = 0;
    for (values) |v| {
        if (v.name.len > name_width) name_width = v.name.len;
    }

    try out.append(allocator, '\n');
    try out.appendSlice(allocator, indent);
    try appendSpaces(out, allocator, h + 2 - indent.len);
    try appendHelpStyled(out, allocator, hl, .plain, std.mem.trimEnd(u8, locale.meta.possible_values, " \t"));

    for (values) |v| {
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, indent);
        try appendSpaces(out, allocator, h + 4 - indent.len);
        try appendHelpStyled(out, allocator, hl, .flags_value, v.name);
        if (v.help.len > 0) {
            try appendSpaces(out, allocator, name_width - v.name.len);
            try appendHelpStyled(out, allocator, hl, .plain, "  - ");
            try appendHelpStyled(out, allocator, hl, .plain, v.help);
        }
    }
}

/// Resolve one spec's enumeration branches through `locale`, pairing each
/// branch's wire name with its resolved help. `has_help` comes from the
/// declaration (`HelpData.Value.help != null`), so an empty literal and a
/// translated-to-empty branch still select the column form. An empty key was
/// already normalized to `null` when `HelpData` was built.
fn fillRowsValues(
    allocator: std.mem.Allocator,
    locale: *const I18n.Locale,
    values: []const HelpData.Value,
) HelpError![]HelpValue {
    const out = try allocator.alloc(HelpValue, values.len);
    for (values, 0..) |v, i| {
        out[i] = .{
            .name = v.name,
            .help = try resolve(locale, v.i18n, v.help orelse ""),
            .has_help = v.help != null,
        };
    }
    return out;
}

fn hasDeclaredHelp(values: []const HelpValue) bool {
    for (values) |v| {
        if (v.has_help) return true;
    }
    return false;
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

/// Free every string owned by an enumeration value list, then the slice.
fn freeValues(allocator: std.mem.Allocator, values: []HelpData.Value) void {
    for (values) |v| {
        allocator.free(v.name);
        if (v.help) |h| allocator.free(h);
        if (v.i18n) |k| allocator.free(k);
    }
    allocator.free(values);
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
    if (o.i18n) |k| allocator.free(k);
    freeValues(allocator, o.values);
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
        if (a.i18n) |k| allocator.free(k);
        freeValues(allocator, a.values);
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
        if (c.i18n) |k| allocator.free(k);
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
    if (dst.info_i18n) |k| allocator.free(k);
    dst.info_i18n = src.info_i18n;
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

/// The struct type behind a value or pointer used as a command View.
fn viewValueType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| viewValueType(p.child),
        else => T,
    };
}

/// The generated namespaces from `NS` down to the level whose `View` is `V`,
/// root first; `null` when this tree owns no such level. It mirrors the
/// runtime walk `appendActiveScopes` does, keyed by type instead of a value,
/// so a View from any level identifies its scope (and its ancestors) exactly.
fn usageChain(comptime NS: type, comptime V: type) ?[]const type {
    comptime {
        @setEvalBranchQuota(1_000_000);
        if (NS.View == V) return &.{NS};
        for (NS.commands) |c| {
            const S = Sub(c.Cmd, subApp(NS.app_meta, c));
            if (usageChain(S, V)) |rest| return &[_]type{NS} ++ rest;
        }
        return null;
    }
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

/// The context-sensitive description of a parsed view: build every scope on
/// the path from `NS` down to the level of `v` (plus the descendants still
/// active in `v`) and fold them into the deepest scope. `v` may be a `View`
/// from any level, and may be passed by value or by pointer. The caller owns
/// the returned [`HelpData`] and releases it with `deinit`.
fn contextHelpData(comptime NS: type, allocator: std.mem.Allocator, v: anytype) std.mem.Allocator.Error!HelpData {
    const chain = comptime (usageChain(NS, viewValueType(@TypeOf(v))) orelse
        @compileError("dap.usage: argument is not a command View of '" ++ NS.app_meta.name ++ "'"));
    var scopes: std.ArrayList(HelpData) = .empty;
    defer {
        for (scopes.items) |*d| d.deinit(allocator);
        scopes.deinit(allocator);
    }
    inline for (chain) |A| {
        const scope = try A.helpData(allocator);
        scopes.append(allocator, scope) catch |e| {
            var d = scope;
            d.deinit(allocator);
            return e;
        };
    }
    try appendActiveScopes(chain[chain.len - 1], allocator, &scopes, v);

    var merged: HelpData = emptyHelpData();
    errdefer merged.deinit(allocator);
    for (scopes.items) |*d| try absorbScope(allocator, &merged, d);
    // The ungrouped bucket is always present and always index 0.
    try dedupeBuiltinHelp(allocator, &merged.flag_groups[0]);
    return merged;
}

/// Render [`contextHelpData`] once with the app's configured renderer. Called
/// from `usage`, from `parse`'s help intercept, and from the failure path.
fn contextHelpText(
    comptime NS: type,
    allocator: std.mem.Allocator,
    v: anytype,
    locale: *const I18n.Locale,
) HelpError!String {
    const chain = comptime (usageChain(NS, viewValueType(@TypeOf(v))) orelse
        @compileError("dap.usage: argument is not a command View of '" ++ NS.app_meta.name ++ "'"));
    var merged = try contextHelpData(NS, allocator, v);
    defer merged.deinit(allocator);
    return renderHelpWithStyle(chain[0].app_meta.help_renderer.style, locale, allocator, &merged);
}

/// Generate the *parser* and the *view* type for a declaration. `generate`
/// returns a namespace wrapper exposing:
///
/// - `pub const View` — the strongly-typed view, a struct with one field per
///   declaration field (in declaration order, with the injected
///   `builtin_help: bool` first), a zero-sized `__commandN` tag after the
///   spec fields that keeps each level's type nominally distinct, a hidden
///   `__i18n: *const I18n.Locale` carrying the locale `parse` selected, one
///   `?Union` per `Alt` field, and one `?View` per command field under a
///   `_`-prefixed name (`_stop`);
/// - `pub fn parse(allocator, environ, i18n, args, diag) ParseError!View`,
///   where `i18n` is an optional [`I18n.Builder`]; `null` selects the
///   declaration default locale;
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
///   The accessor is generic over the `View`: a sub-view from any level of
///   the tree resolves to that level's payload union, so dispatch nests. A
///   leaf (a level declaring no subcommands) and a foreign value are compile
///   errors, and the leaf message names that leaf's own level path.
///
///   `View` is an `@Struct`, so Zig would otherwise intern it structurally
///   and two levels with the same field layout would share one type. The
///   generated tag field (`__commandN`, `N` the level's pre-order rank)
///   makes every level's `View` nominally distinct, so a `View` value
///   identifies exactly one level.
///
/// ```
/// if (CLI.command(cli)) |cmd| switch (cmd) {
///     .body => |b| {
///         if (CLI.command(b)) |subcmd| switch (subcmd) {
///             .left => |l| runLeft(l),
///             .right => |r| runRight(r),
///         } else {
///             // `body` with no subcommand token
///         }
///     },
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
/// help text of the deepest command entered to stderr and exits with code `1`.
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
/// var cli = try CLI.parse(allocator, environ, null, args, &diag);
/// std.debug.print("{} {}", .{ cli.login, cli.path }); // Both are strings.
/// defer diag.deinit(allocator);
/// ```
///
/// `View` is a plain struct (`cli.login`, `cli.path`, ...) whose strings are
/// allocated with the passed allocator. It also carries a hidden
/// `__i18n: *const I18n.Locale` pointer, the locale `parse` selected; `usage`
/// reads it to render in that locale. No name transformation is applied:
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
/// var cli = try CLI.parse(allocator, environ, null, args, &diag);
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
/// var cli = try CLI.parse(allocator, environ, null, args, &diag);
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
/// var cli = try CLI.parse(allocator, environ, null, args, &diag);
/// const jobs = cli.jobs orelse 1;
/// ```
///
/// Custom value types are supported when they expose
///
/// ```
/// pub fn decode(allocator: std.mem.Allocator, data: []const u8) dap.DecodeError!Self
/// pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8
/// pub fn deinit(self: *Self, allocator: std.mem.Allocator) void
/// ```
///
/// `decode` is a static constructor returning a fully built value (so types
/// with internal allocations can own them); `encode` returns an
/// allocator-owned wire spelling the caller frees; `deinit` releases the
/// value's internals and must not call `allocator.destroy(self)`.
///
/// Every field of a `View` returned by a successful `parse` is owned by the
/// caller: `[]const u8` fields are duplicated from argv, environ and comptime
/// literals, and custom-type fields own their internals. Release them with
/// `CLI.deinit(&view, allocator)`. It is valid once on a successful parse and
/// is not idempotent; `args`/`environ` are borrowed only during `parse`.
///
/// The list of these methods is meant to grow (completions and such), but
/// these three are the stable contract. Builtin scalars, `dap.String`
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
    .i18n = "builtin_help",
    .default = defaultValue(bool, false),
};

/// The merged declaration type: `.builtin_help` at index 0 followed by the
/// user's fields in declaration order, each keeping its own default value.
fn MergedDecl(comptime D: type) type {
    const fields = fieldsOf(D);
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
        var a: [1 + fields.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        a[0] = .{
            .@"align" = @alignOf(Builtin),
            .default_value_ptr = @ptrCast(&BuiltinHelp),
        };
        inline for (fields, 0..) |f, fi| {
            a[1 + fi] = .{
                .@"comptime" = f.attrs.@"comptime",
                .@"align" = f.attrs.@"align",
                .default_value_ptr = f.attrs.default_value_ptr,
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
    inline for (fieldsOf(@TypeOf(decl))) |f| {
        @field(result, f.name) = @field(decl, f.name);
    }
    return result;
}

/// Render `help_data` with the app's configured renderer into a string owned
/// by `allocator`. `.compact` uses `HelpData.renderCompact`, `.custom` invokes
/// the user-provided function pointer payload.
fn renderHelpWithStyle(
    comptime style: HelpRendererStyle,
    locale: *const I18n.Locale,
    allocator: std.mem.Allocator,
    help_data: *HelpData,
) HelpError!String {
    return switch (style) {
        .compact => help_data.renderCompact(locale, allocator),
        .custom => |custom_fn| custom_fn(help_data, locale, allocator),
    };
}

/// Shape of the token whose lookup failed, deciding which candidate
/// namespaces [`suggestProbe`] scores.
const SuggestShape = enum {
    /// A `--…` token: long names first, commands as a cross-namespace
    /// fallback (a user typing `--build` for the command `build`).
    long,
    /// A `-…` token: short names only (plus single-character longs).
    short,
    /// A bare token at a command checkpoint: command names only.
    bare,
};

/// Candidate namespace [`suggestLoad`] scores in one pass. A single call
/// always compares like against like; cross-namespace preference is decided
/// by [`suggestProbe`].
const SuggestLoad = enum {
    /// Long flag bodies: long names always, short names for very short
    /// bodies, prefix completions on long names.
    long_flag,
    /// Short flag bodies: short names for very short bodies, plus
    /// single-character long names.
    short_flag,
    /// Bare command-shaped bodies: command names, prefix completions
    /// included.
    cmd,
};

/// The largest edit distance still treated as a plausible typo for a body of
/// length `n` against a candidate of length `m`. Graduated to approximate a
/// ~25% relative error budget with exact integer math: no hint for words too
/// short to have a meaningful typo, a fixed budget for medium words, and a
/// quarter of the length beyond that.
fn suggestMaxDistance(n: usize, m: usize) usize {
    const L = @max(n, m);
    if (L == 0) return 0;
    if (L <= 2) return 0;
    if (L <= 5) return 1;
    if (L <= 10) return 2;
    return (L + 3) / 4;
}

/// `cand` extends `body` (strictly longer and sharing its prefix), e.g.
/// `dry` completing to `dry_run`.
fn suggestIsPrefix(body: String, cand: String) bool {
    return cand.len > body.len and std.mem.startsWith(u8, cand, body);
}

/// Hold the best candidate seen so far, replacing it only on a strictly
/// better score: lower distance wins, then `.edit` over `.prefix`, and on a
/// perfect tie the earlier declaration is kept (first seen wins).
fn suggestKeep(best: *?SuggestValid, p: SuggestValid) void {
    const b = best.* orelse {
        best.* = p;
        return;
    };
    const p_rank: u1 = if (p.reason == .edit) 0 else 1;
    const b_rank: u1 = if (b.reason == .edit) 0 else 1;
    if (p.distance < b.distance or (p.distance == b.distance and p_rank < b_rank)) {
        best.* = p;
    }
}

/// Score one candidate against `body` and fold it into `best`. `long` is the
/// candidate's long wire name (or the command name); `short`, when set, is a
/// short spelling that won the ranking and is what rendering shows. `prefix_ok`
/// gates prefix completions on the pre-computed uniqueness check.
fn suggestConsider(
    best: *?SuggestValid,
    body: String,
    long: String,
    short: ?String,
    kind: SuggestValid.Kind,
    eligible: bool,
    prefix_ok: bool,
) void {
    if (!eligible) return;
    if (long.len == 0) return;
    const cand = short orelse long;

    const d = stdcompare.levenshtein(body, cand);
    var picked: ?SuggestValid = null;
    if (d <= suggestMaxDistance(body.len, cand.len)) {
        picked = .{ .name = long, .short = short, .kind = kind, .distance = d, .reason = .edit };
    } else if (prefix_ok and short == null and suggestIsPrefix(body, long)) {
        picked = .{ .name = long, .short = null, .kind = kind, .distance = long.len - body.len, .reason = .prefix };
    }
    if (picked) |p| suggestKeep(best, p);
}

/// The best candidate for `body` within one namespace `which`, or `null` when
/// nothing clears the threshold. Prefix completions are offered only when
/// exactly one candidate extends `body`: an ambiguous completion (`bui` →
/// `build` / `buildx`) yields no prefix hint.
fn suggestLoad(
    comptime specs: []const Spec,
    comptime cmds: []const CommandEntry,
    comptime which: SuggestLoad,
    body: String,
) ?SuggestValid {
    var prefix_count: usize = 0;
    if (body.len >= 2) {
        switch (which) {
            .long_flag => inline for (specs) |s| {
                if (s.kind != .flag) continue;
                if (suggestIsPrefix(body, s.long)) prefix_count += 1;
            },
            .short_flag => {},
            .cmd => inline for (cmds) |c| {
                inline for (comptime checks_mod.commandSpellings(c)) |spelling| {
                    if (suggestIsPrefix(body, spelling)) prefix_count += 1;
                }
            },
        }
    }
    const prefix_ok = prefix_count == 1;

    var best: ?SuggestValid = null;
    switch (which) {
        .long_flag => {
            inline for (specs) |s| {
                if (s.kind != .flag) continue;
                suggestConsider(&best, body, s.long, null, .flag, true, prefix_ok);
            }
            inline for (specs) |s| {
                if (s.kind != .flag) continue;
                if (s.short) |sh| {
                    suggestConsider(&best, body, s.long, sh, .flag, body.len <= 2, prefix_ok);
                }
            }
        },
        .short_flag => {
            inline for (specs) |s| {
                if (s.kind != .flag) continue;
                if (s.short) |sh| {
                    suggestConsider(&best, body, s.long, sh, .flag, body.len <= 2, prefix_ok);
                }
            }
            inline for (specs) |s| {
                if (s.kind != .flag) continue;
                if (s.long.len == 1) {
                    suggestConsider(&best, body, s.long, null, .flag, true, prefix_ok);
                }
            }
        },
        .cmd => {
            inline for (cmds) |c| {
                inline for (comptime checks_mod.commandSpellings(c)) |spelling| {
                    suggestConsider(&best, body, spelling, null, .cmd, true, prefix_ok);
                }
            }
        },
    }
    return best;
}

/// The namespace-tagged suggestion for a rejected token body. The token's
/// dash shape decides precedence: a `--…` body prefers flags with a command
/// fallback, a `-…` body scores shorts only, and a bare body scores commands
/// only. `body` is already normalized (no leading dashes, no `=value`).
fn suggestProbe(
    comptime specs: []const Spec,
    comptime cmds: []const CommandEntry,
    comptime shape: SuggestShape,
    body: String,
) ?Suggest {
    if (body.len == 0) return null;
    switch (shape) {
        .long => {
            const flag_cand = suggestLoad(specs, cmds, .long_flag, body);
            const cmd_cand = suggestLoad(specs, cmds, .cmd, body);
            if (flag_cand) |f| {
                if (cmd_cand) |c| {
                    // A dashed token is flag-shaped: the command only wins when
                    // it is a strictly better match; a tie honours the shape.
                    if (c.distance < f.distance) return .{ .cmd = c };
                }
                return .{ .flag = f };
            }
            if (cmd_cand) |c| return .{ .cmd = c };
            return null;
        },
        .short => {
            if (suggestLoad(specs, cmds, .short_flag, body)) |s| return .{ .flag = s };
            return null;
        },
        .bare => {
            if (suggestLoad(specs, cmds, .cmd, body)) |s| return .{ .cmd = s };
            return null;
        },
    }
}

/// Build the default locale's user entries: one per collected i18n origin,
/// plus the injected builtin help translation. Completion shells are never
/// localized, so no `builtin_*_shell` pair is added.
fn defaultEntries(
    comptime origins: []const checks_mod.I18nOrigin,
    comptime builtin_key: String,
    comptime builtin_help: String,
) []const I18n.Entry {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const I18n.Entry = &.{};
        for (origins) |o| {
            out = out ++ &[_]I18n.Entry{.{ .key = o.key, .value = o.literal }};
        }
        out = out ++ &[_]I18n.Entry{.{ .key = builtin_key, .value = builtin_help }};
        return out;
    }
}

/// The keys a translation must provide: every collected origin plus the
/// injected builtin help key, in the same order as `defaultEntries`.
fn defaultKeys(
    comptime origins: []const checks_mod.I18nOrigin,
    comptime builtin_key: String,
) []const String {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const String = &.{};
        for (origins) |o| out = out ++ &[_]String{o.key};
        out = out ++ &[_]String{builtin_key};
        return out;
    }
}

pub fn generate(comptime app: App, comptime def: anytype) type {
    @setEvalBranchQuota(1_000_000);
    const merged = withBuiltinHelp(def);
    const norm = normalizeRanked(merged, app._command_rank);
    const all_specs = norm.specs;
    const cmd_entries = norm.commands;
    const alts = norm.alts;

    // Global flag-name uniqueness (D6): flags of every ancestor level merge
    // into a deep help scope, so a name reused anywhere in the command tree
    // would be ambiguous. Runs after `normalize`'s own checks so same-level
    // collisions keep their better existing messages.
    comptime checks_mod.checkGlobalFlagNames(checks_mod.collectFlagOrigins(norm, &[_]String{app.name}, &.{}));

    // i18n keys are declaration-wide identifiers: valid field names, unique
    // within the tree, never shadowing a builtin translation. Nothing resolves
    // through a locale yet.
    const i18n_origins = checks_mod.collectI18n(norm, app.help, app.i18n, &[_]String{app.name}, &.{});
    comptime checks_mod.checkI18nKeys(i18n_origins);

    // The complete English locale every declaration carries; rendering still
    // reads the raw literals until stage 5 teaches it to take a locale.
    const default_locale_value =
        I18n.Locale.default(defaultEntries(i18n_origins, builtin_help_field, BuiltinHelp.help));
    const i18n_keys_value = defaultKeys(i18n_origins, builtin_help_field);

    const field_names = blk: {
        var names: []const String = &.{};
        for (all_specs) |s| names = names ++ &[_]String{s.name};
        // Zero-sized nominal tag: its name carries the level's pre-order rank,
        // so levels with otherwise equal layouts do not intern to one `View`
        // type. Commands are `_`-prefixed and declaration names may not start
        // with `_`, so `__command...` cannot collide with a real field.
        names = names ++ &[_]String{std.fmt.comptimePrint("__command{}", .{app._command_rank})};
        // The locale selected by `parse`, carried so `usage` renders with it.
        // A pointer into comptime-static storage, never freed by `deinit`.
        names = names ++ &[_]String{"__i18n"};
        for (alts) |a| names = names ++ &[_]String{a.field};
        for (cmd_entries) |c| names = names ++ &[_]String{c.view_field};
        break :blk names;
    };
    const field_types = blk: {
        var ts: []const type = &.{};
        for (all_specs) |s| ts = ts ++ &[_]type{specViewType(s)};
        ts = ts ++ &[_]type{u0};
        ts = ts ++ &[_]type{*const I18n.Locale};
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
        var a: [field_types.len]std.builtin.Type.Struct.FieldAttributes = undefined;
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
        /// The synthesized default (English) locale for this declaration.
        pub const default_locale = default_locale_value;
        /// Every key a translation of this declaration must provide.
        pub const i18n_keys = i18n_keys_value;

        /// The translation builder, seeded with the default locale and the
        /// required keys. Infallible and allocation-free: it only exposes the
        /// builder and never selects a locale or reads the environment.
        /// Root only; a subcommand namespace cannot be localized on its own.
        pub fn i18n() I18n.Builder {
            comptime {
                if (app._command_rank != 0) {
                    @compileError("dap.i18n: call it on the root namespace, got '" ++ app.name ++ "'");
                }
            }
            return I18n.Builder.init(default_locale, i18n_keys);
        }

        pub const View = @Struct(.auto, null, &Names, &Types, &Attrs);
        /// Lazy completion script handle specialized for this declaration.
        pub const Completion = completion_mod.Completion.Of(@This());

        /// Release every owned field of a `View` returned by a successful
        /// parse: string slices, custom-type internals, optional payloads, the
        /// active `Alt` branch, and every activated command sub-`View`.
        /// Valid once, not idempotent; custom types handle their own internals.
        pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
            inline for (all_specs) |s| {
                if (s.alt != null) continue; // Alt members released via their Alt field below
                deinitValue(specViewType(s), allocator, &@field(self, s.name));
            }
            inline for (alts) |a| {
                if (@field(self, a.field)) |*u| {
                    switch (u.*) {
                        inline else => |*branch| {
                            inline for (fieldsOf(@TypeOf(branch.*))) |f| {
                                deinitValue(f.type, allocator, &@field(branch, f.name));
                            }
                        },
                    }
                }
            }
            inline for (cmd_entries) |c| {
                if (@field(self, c.view_field)) |*sub| {
                    Sub(c.Cmd, subApp(app, c)).deinit(sub, allocator);
                }
            }
        }

        /// Fill a runtime [`HelpData`] description of this declaration. Every
        /// string and slice is allocated with `allocator`; release them with
        /// `HelpData.deinit`. Nothing here runs unless this or `helpText` is
        /// called.
        pub fn helpData(allocator: std.mem.Allocator) std.mem.Allocator.Error!HelpData {
            const name = try allocator.dupe(u8, app.name);
            errdefer allocator.free(name);
            const info = try allocator.dupe(u8, app.help);
            errdefer allocator.free(info);
            var info_i18n: ?String = null;
            errdefer if (info_i18n) |k| allocator.free(k);
            if (app.i18n) |k| info_i18n = try allocator.dupe(u8, k);

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
                errdefer allocator.free(chelp);
                var ci18n: ?String = null;
                errdefer if (ci18n) |k| allocator.free(k);
                if (c.Cmd.cmd_meta.i18n) |k| ci18n = try allocator.dupe(u8, k);
                cmd_infos[ci] = .{ .name = cname_dup, .help = chelp, .i18n = ci18n };
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
                .info_i18n = info_i18n,
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
        /// Fails with [`HelpError`]: an allocation failure or a translation key
        /// missing from the selected locale.
        pub fn helpText(allocator: std.mem.Allocator) HelpError!String {
            return try helpTextWithStyle(allocator, null, &default_locale);
        }

        /// Print the context-sensitive help of a parsed `View` to stdout: the
        /// same text the builtin `-h`/`--help` intercept would print for the
        /// command chain activated in `view`. Accepts a `View` from any level
        /// of the tree, like `command`: the text merges the scopes from this
        /// namespace's level down to that view's level, then the descendants
        /// still active in it. Calling it on the root namespace with a
        /// sub-view therefore reproduces the intercept's full merged help.
        /// Rendering allocations use an internal allocator and are freed
        /// before returning; only a write to stdout is ignored, matching the
        /// parse intercept. It renders with the locale carried by `view`
        /// (`view.__i18n`), so post-parse help matches the locale `parse`
        /// selected. Fails with [`HelpError`] when rendering does.
        ///
        /// ```
        /// const cli = try CLI.parse(allocator, environ, null, args, &diag);
        /// if (CLI.command(cli)) |cmd| switch (cmd) {
        ///     .config => |c| try CLI.usage(c),
        ///     else => try CLI.usage(cli),
        /// }
        /// ```
        pub fn usage(view: anytype) HelpError!void {
            const allocator = std.heap.page_allocator;
            const text = try contextHelpText(@This(), allocator, view, view.__i18n);
            defer allocator.free(text);
            var stdout_buffer: [0x1000]u8 = undefined;
            const stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(std.Options.debug_io, &stdout_buffer);
            stdout_writer.interface.print("{s}\n", .{text}) catch {};
            stdout_writer.interface.flush() catch {};
        }

        /// Build a lazy completion-script handle for this declaration.
        ///
        /// `app_name` is the command name the script registers (a bare binary
        /// name, not the declaration's usage path). `locale` supplies the
        /// static descriptions: every declared `i18n` key, on a flag, a
        /// command, or an enumeration branch, renders through it, while
        /// entries without a key keep their declared literal. Pass the result
        /// of `i18n.locale(environ)` to follow the machine's locale, or
        /// `&CLI.default_locale` for the declaration default. Nothing is
        /// rendered or validated until `text`, `show`, or `install` is called;
        /// the script is a snapshot of the declaration and the locale, so
        /// rebuild it when either changes.
        ///
        /// ```
        /// var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        /// defer arena.deinit();
        /// var completion = CLI.completion(arena.allocator(), "app", .zsh, &CLI.default_locale);
        /// const script = try completion.text();
        /// defer arena.allocator().free(script);
        /// ```
        ///
        /// The root level is the only caller: a subcommand level cannot
        /// reconstruct its ancestors, so a non-root call is a compile error.
        pub fn completion(
            allocator: std.mem.Allocator,
            app_name: String,
            shell: completion_mod.Completion.Shell,
            locale: *const I18n.Locale,
        ) completion_mod.Completion.Of(@This()) {
            comptime {
                if (app._command_rank != 0) {
                    @compileError("dap.completion: call it on the root namespace, got '" ++
                        app.name ++ "'");
                }
            }
            return .{ .allocator = allocator, .app_name = app_name, .shell = shell, .locale = locale };
        }

        /// Build the branch list of an enumeration-valued spec, duplicating
        /// every string. Non-enumeration types and an empty `Enumeration`
        /// yield an empty slice. An empty key means "no translation".
        fn fillValues(allocator: std.mem.Allocator, comptime s: Spec) std.mem.Allocator.Error![]HelpData.Value {
            const T = s.vtype;
            if (@typeInfo(T) != .@"struct") return &.{};
            if (!@hasDecl(T, "names") or !@hasDecl(T, "helps") or
                !@hasDecl(T, "help_i18n")) return &.{};

            const values = try allocator.alloc(HelpData.Value, T.names.len);
            var filled: usize = 0;
            errdefer {
                for (values[0..filled]) |v| {
                    allocator.free(v.name);
                    if (v.help) |h| allocator.free(h);
                    if (v.i18n) |k| allocator.free(k);
                }
                allocator.free(values);
            }

            inline for (T.names, T.helps, T.help_i18n, 0..) |name, help, key, i| {
                const vname = try allocator.dupe(u8, name);
                errdefer allocator.free(vname);
                var vhelp: ?String = null;
                errdefer if (vhelp) |h| allocator.free(h);
                if (help) |h| vhelp = try allocator.dupe(u8, h);
                var vkey: ?String = null;
                errdefer if (vkey) |k| allocator.free(k);
                if (key) |k| {
                    if (k.len > 0) vkey = try allocator.dupe(u8, k);
                }
                values[i] = .{ .name = vname, .help = vhelp, .i18n = vkey };
                filled += 1;
            }
            return values;
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
            var oi18n: ?String = null;
            errdefer if (oi18n) |k| allocator.free(k);
            if (s.i18n) |k| oi18n = try allocator.dupe(u8, k);
            const ovalues = try fillValues(allocator, s);
            errdefer freeValues(allocator, ovalues);
            return .{ .name = oname, .short = oshort, .help = ohelp, .default = odefault, .takes_value = s.vtype != bool, .alt = oalt, .alt_branch = obranch, .optional = s.optional, .i18n = oi18n, .values = ovalues };
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
            var ai18n: ?String = null;
            errdefer if (ai18n) |k| allocator.free(k);
            if (s.i18n) |k| ai18n = try allocator.dupe(u8, k);
            const avalues = try fillValues(allocator, s);
            errdefer freeValues(allocator, avalues);
            return .{ .name = aname, .help = ahelp, .default = adefault, .i18n = ai18n, .values = avalues };
        }

        /// Render a spec's default value into an owned string: the direct
        /// value when declared (a custom type renders through `encode`),
        /// otherwise `$NAME` for an environment-only default, otherwise
        /// `null`.
        fn renderDefault(allocator: std.mem.Allocator, comptime s: Spec) std.mem.Allocator.Error!?String {
            if (s.default) |d| {
                if (s.vtype == String) return try allocator.dupe(u8, d.get([]const u8));
                if (@typeInfo(s.vtype) == .@"struct") {
                    var tmp: s.vtype = d.get(s.vtype);
                    return try tmp.encode(allocator);
                }
                return try std.fmt.allocPrint(allocator, "{}", .{d.get(s.vtype)});
            }
            if (s.default_env) |name| {
                return try std.fmt.allocPrint(allocator, "${s}", .{name});
            }
            return null;
        }

        /// Print the parse diagnostics and the help text to stderr, then exit with
        /// code 1. The help is the context-sensitive page of `view`, the
        /// partially parsed View: on a failed sub-parse every level that was
        /// entered stays linked from its parent, so the merged page describes
        /// the deepest active command (its usage header reconstructs the
        /// command path), not the root. The compact renderer leads its view
        /// with the diagnostics (highlighted with the error token); a custom
        /// renderer, or a render failure, falls back to plain diagnostic lines
        /// so they are never lost. Write errors are ignored: there is no
        /// sensible fallback once stderr is gone, and `std.process.exit` must
        /// still run.
        fn printFailureExit(
            allocator: std.mem.Allocator,
            diag: ?*const Diag,
            view: anytype,
            locale: *const I18n.Locale,
        ) noreturn {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const error_text: ?String = blk: {
                const t = buildErrorText(&buf, allocator, diag, locale) catch break :blk null;
                break :blk if (t.len > 0) t else null;
            };

            const compact = switch (app.help_renderer.style) {
                .compact => true,
                .custom => false,
            };
            // The compact renderer folds the diagnostics into its view; any
            // other renderer (or a failed diagnostic build) prints them as
            // standalone lines so they are never lost.
            const standalone = !compact or error_text == null;
            if (standalone) printDiagnosticsStandalone(allocator, diag, locale);

            if (failureHelpText(allocator, view, if (compact) error_text else null, locale)) |text| {
                defer allocator.free(text);
                std.debug.print("{s}\n", .{text});
            } else |_| {
                // A failed render must not swallow the diagnostics.
                if (compact) if (error_text) |e| std.debug.print("{s}\n", .{e});
            }
            std.process.exit(1);
        }

        /// Render the context-sensitive help of the partially parsed `view`,
        /// most specific command first, with `error_text` (when set) leading
        /// the compact view.
        fn failureHelpText(
            allocator: std.mem.Allocator,
            view: anytype,
            error_text: ?String,
            locale: *const I18n.Locale,
        ) HelpError!String {
            var data = try contextHelpData(@This(), allocator, view);
            defer data.deinit(allocator);
            data.error_text = error_text;
            return renderHelpWithStyle(app.help_renderer.style, locale, allocator, &data);
        }

        /// Render the failure diagnostic block into `buf` as one plain-text
        /// string: the same lines `printDiagnosticsStandalone` prints, joined
        /// by newlines, so `renderCompact` can lead its view with them (and
        /// color the whole block with the error token). Returns the (possibly
        /// empty) slice into `buf`; the caller owns `buf`.
        fn buildErrorText(
            buf: *std.ArrayList(u8),
            allocator: std.mem.Allocator,
            diag: ?*const Diag,
            locale: *const I18n.Locale,
        ) HelpError!String {
            const d = diag orelse return "";
            var wrote = false;
            if (d.field) |f| {
                const line = try fillTemplate(allocator, locale.diag.field_invalid, &.{f});
                defer allocator.free(line);
                try buf.appendSlice(allocator, line);
                wrote = true;
            }
            if (d.token) |t| {
                if (wrote) try buf.append(allocator, '\n');
                const line = try fillTemplate(allocator, locale.diag.token_invalid, &.{t});
                defer allocator.free(line);
                try buf.appendSlice(allocator, line);
                wrote = true;
            }
            if (d.message) |m| {
                if (wrote) try buf.append(allocator, '\n');
                const line = try fillTemplate(allocator, locale.diag.message, &.{m});
                defer allocator.free(line);
                try buf.appendSlice(allocator, line);
                wrote = true;
            }
            if (d.unknown) |u| {
                if (wrote) try buf.append(allocator, '\n');
                const sp = suggestSpelling(u);
                const line = try fillTemplate(allocator, locale.diag.did_you_mean, &.{ sp.dash, sp.shown });
                defer allocator.free(line);
                try buf.appendSlice(allocator, line);
            }
            return buf.items;
        }

        /// Print one localized diagnostic line to stderr. A failed fill skips
        /// the line rather than losing the process.
        fn printDiagLine(allocator: std.mem.Allocator, template: String, args: []const String) void {
            const line = fillTemplate(allocator, template, args) catch return;
            defer allocator.free(line);
            std.debug.print("{s}\n", .{line});
        }

        /// Print the failure diagnostics as standalone stderr lines. Used as
        /// the fallback when the renderer is not the compact one (which folds
        /// them into its view) or when rendering failed. The suggested
        /// spelling is wrapped in the scheme's error color.
        fn printDiagnosticsStandalone(
            allocator: std.mem.Allocator,
            diag: ?*const Diag,
            locale: *const I18n.Locale,
        ) void {
            const d = diag orelse return;
            if (d.field) |f| printDiagLine(allocator, locale.diag.field_invalid, &.{f});
            if (d.token) |t| printDiagLine(allocator, locale.diag.token_invalid, &.{t});
            if (d.message) |m| printDiagLine(allocator, locale.diag.message, &.{m});
            if (d.unknown) |u| {
                const hl = HelpHighlight.resolve(app.help_renderer.highlight);
                const pre = hl.usage.error_msg;
                const reset = if (pre.len > 0) hl.reset else "";
                const sp = suggestSpelling(u);
                const shown = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ pre, sp.shown, reset }) catch return;
                defer allocator.free(shown);
                printDiagLine(allocator, locale.diag.did_you_mean, &.{ sp.dash, shown });
            }
        }

        /// The display pieces of a suggestion: the dash prefix (`--` for a long
        /// flag, `-` for a short one, empty for a command) and the spelling to
        /// show after it. Kept as two slices so the hint never allocates.
        const Spelling = struct { dash: String, shown: String };

        fn suggestSpelling(u: Suggest) Spelling {
            return switch (u) {
                .flag => |s| .{ .dash = if (s.short != null) "-" else "--", .shown = s.short orelse s.name },
                .cmd => |s| .{ .dash = "", .shown = s.name },
            };
        }

        /// Fill the `HelpData` description of this declaration and render it with
        /// the app's configured renderer. The description is freed before
        /// returning; only the rendered string stays allocated. `error_text`,
        /// when set, leads the compact view with the failure diagnostics.
        fn helpTextWithStyle(
            allocator: std.mem.Allocator,
            error_text: ?String,
            locale: *const I18n.Locale,
        ) HelpError!String {
            var data = try helpData(allocator);
            defer data.deinit(allocator);
            data.error_text = error_text;
            return try renderHelpWithStyle(app.help_renderer.style, locale, allocator, &data);
        }

        /// Parse `args` into a `View`, or exit through the builtin help and
        /// failure flows. `args` is pure payload: no binary name and no
        /// skipped token. `i18n_builder` is an optional comptime-built
        /// [`I18n.Builder`]; `null` selects the declaration's
        /// `default_locale`, while a builder selects
        /// `builder.locale(environ)` (`LC_ALL`, `LC_MESSAGES`, `LANG`). The
        /// selected locale is installed in `View.__i18n` at every active
        /// level, so the `-h`/`--help` intercept, the failure page and
        /// `usage` render in it. The completion route hook runs first, before
        /// locale selection and parsing.
        pub fn parse(
            allocator: std.mem.Allocator,
            environ: std.process.Environ,
            i18n_builder: ?*const I18n.Builder,
            args: []const []const u8,
            diag: ?*Diag,
        ) ParseError!View {
            // ROUTE HOOK: the hidden completion route is recognized only at the
            // root level and only as the very first argument, before help
            // interception, diagnostics, or the `--` terminator. `route` never
            // returns.
            if (comptime app._command_rank == 0) {
                if (args.len != 0 and std.mem.eql(u8, args[0], completion_mod.Completion.route_marker)) {
                    completion_mod.route(@This(), std.Options.debug_io, allocator, environ, args);
                }
            }

            // Locale selection reads the environment and cannot fail: the
            // builder always seeds the default locale under the empty tag.
            // A `null` builder selects the declaration default.
            const locale = if (i18n_builder) |builder| builder.locale(environ) else &default_locale;

            // `failed` receives the partially built View on the error path, so
            // the failure page can describe the deepest command that was
            // actually entered instead of the root.
            var failed: View = undefined;
            const result = parseInnerHelp(allocator, environ, locale, args, diag, false, null, &failed) catch {
                printFailureExit(allocator, diag, &failed, locale);
            };

            // HELP REQUESTED INTERCEPT: a requested help flag — at this level or
            // anywhere in the active command chain — bypassed every required
            // check and validation inside `parseInnerHelp`. Render the merged,
            // context-sensitive help with the app's renderer, print it to
            // stdout, and exit cleanly.
            if (helpRequested(@This(), &result)) {
                if (contextHelpText(@This(), allocator, &result, locale)) |text| {
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
        /// Errors propagate to the caller together with a filled `diag`; the
        /// partial View of the failure path is discarded here, because this
        /// entry is for callers that handle errors themselves.
        fn parseInner(allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8, diag: ?*Diag) ParseError!View {
            var failed: View = undefined;
            return parseInnerHelp(allocator, environ, &default_locale, args, diag, false, null, &failed);
        }

        /// The parse pipeline. `ancestor_help` records that a help flag was seen on
        /// an ancestor level's wire before the handoff, so a deep command still
        /// honours the request (help token *before* the commands, D1) even though a
        /// plain sub-parse would otherwise fail its own required checks.
        /// `up` links the active ancestor levels (nearest first, root last); a
        /// flag token that matches no local spec is resolved against them,
        /// mirroring the merged help and the global flag-name uniqueness rule,
        /// so `app sub --root-flag` assigns into the ancestor's `View`.
        /// `out` is written on the error path with the partially built View, so
        /// every level that was entered remains reachable from its parent's
        /// command field and the failure page can merge the whole active chain.
        /// `locale` is the locale `parse` selected; it is installed into the
        /// View and passed to every command handoff.
        fn parseInnerHelp(allocator: std.mem.Allocator, environ: std.process.Environ, locale: *const I18n.Locale, args: []const []const u8, diag: ?*Diag, ancestor_help: bool, up: ?*const Ancestor, out: *View) ParseError!View {
            if (diag) |d| d.* = .{};

            var v: View = undefined;
            // Fires on every error return below: Phase 0 has already run, so
            // the View is safe to walk for help before it is handed to `out`.
            errdefer out.* = v;
            var seen: [all_specs.len]bool = @splat(false);
            var pos: usize = 0;
            var handed_off = false;
            var help_seen = ancestor_help;

            // Phase 0: INIT. The builtin help flag starts false so the
            // post-loop intercept below can read it even when no wire token
            // mentioned it. Every Alt field starts `null` (no branch active);
            // a branch is materialized only when one of its members is seen.
            v.builtin_help = false;
            v.__i18n = locale;
            inline for (alts) |a| @field(v, a.field) = null;
            inline for (cmd_entries) |c| @field(v, c.view_field) = null;

            // Phase 1: SCAN
            var i: usize = 0;
            while (i < args.len and !handed_off) : (i += 1) {
                const tok = args[i];

                if (std.mem.eql(u8, tok, "--")) {
                    // Everything after `--` is a literal positional; the
                    // terminator also suppresses any handoff and, since the
                    // user declared these tokens to be data, the typo
                    // suggester too.
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try assignPositional(allocator, &v, &seen, &pos, args[i], diag, false);
                    }
                    break;
                }

                if (std.mem.startsWith(u8, tok, "--")) {
                    try consumeLongFlag(allocator, &v, &seen, args, &i, diag, true, up);
                    if (v.builtin_help) help_seen = true;
                } else if (tok.len > 1 and tok[0] == '-') {
                    try consumeShortFlag(allocator, &v, &seen, args, &i, diag, true, up);
                    if (v.builtin_help) help_seen = true;
                } else {
                    if (cmd_entries.len == 0) {
                        try assignPositional(allocator, &v, &seen, &pos, tok, diag, true);
                    } else {
                        // HANDOFF: a positional token equal to a registered
                        // command name is checked before POSITIONAL. The
                        // sub-parse receives the payload after the command
                        // token and again starts at its own index 0.
                        var matched = false;
                        inline for (cmd_entries) |c| {
                            if (commandMatches(c, tok)) {
                                const S = Sub(c.Cmd, subApp(app, c));
                                var frame: ParseFrame(@This()) = .{ .v = &v, .seen = &seen };
                                const chain: Ancestor = .{
                                    .ctx = &frame,
                                    .up = up,
                                    .assign_long = ancestorFns(@This()).assignLong,
                                    .assign_short = ancestorFns(@This()).assignShort,
                                };
                                var sub: S.View = undefined;
                                @field(v, c.view_field) = S.parseInnerHelp(allocator, environ, locale, args[i + 1 ..], diag, help_seen, &chain, &sub) catch |err| {
                                    // Link the partially built sub-View before
                                    // unwinding so the failure page of an
                                    // ancestor can descend into it.
                                    @field(v, c.view_field) = sub;
                                    return err;
                                };
                                handed_off = true;
                                matched = true;
                            }
                        }
                        if (!matched) {
                            try assignPositional(allocator, &v, &seen, &pos, tok, diag, true);
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

        fn consumeLongFlag(allocator: std.mem.Allocator, v: *View, seen: *[all_specs.len]bool, args: []const []const u8, i: *usize, diag: ?*Diag, suggest: bool, up: ?*const Ancestor) ParseError!void {
            const tok = args[i.*];
            const body = tok[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const eqv: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            if (try assignLongFlag(@This(), allocator, v, seen, args, i, diag, name, eqv)) return;
            var p = up;
            while (p) |frame| : (p = frame.up) {
                if (try frame.assign_long(frame.ctx, allocator, args, i, diag, name, eqv)) return;
            }

            if (diag) |d| {
                d.token = tok;
                if (suggest) d.unknown = suggestProbe(all_specs, cmd_entries, .long, name);
            }
            return error.UnknownFlag;
        }

        fn consumeShortFlag(allocator: std.mem.Allocator, v: *View, seen: *[all_specs.len]bool, args: []const []const u8, i: *usize, diag: ?*Diag, suggest: bool, up: ?*const Ancestor) ParseError!void {
            const tok = args[i.*];
            const body = tok[1..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const eqv: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            if (try assignShortFlag(@This(), allocator, v, seen, args, i, diag, name, eqv)) return;
            var p = up;
            while (p) |frame| : (p = frame.up) {
                if (try frame.assign_short(frame.ctx, allocator, args, i, diag, name, eqv)) return;
            }

            if (diag) |d| {
                d.token = tok;
                if (suggest) d.unknown = suggestProbe(all_specs, cmd_entries, .short, name);
            }
            return error.UnknownFlag;
        }

        fn assignPositional(allocator: std.mem.Allocator, v: *View, seen: *[all_specs.len]bool, pos: *usize, tok: []const u8, diag: ?*Diag, suggest: bool) ParseError!void {
            if (pos.* >= arg_count) {
                if (diag) |d| {
                    d.token = tok;
                    if (suggest) d.unknown = suggestProbe(all_specs, cmd_entries, .bare, tok);
                }
                return error.TooManyArguments;
            }
            inline for (all_specs, 0..) |s, si| {
                if (s.kind == .argument and args_before[si] == pos.* and !seen[si]) {
                    try assignValue(s, View, allocator, v, seen, si, tok, diag);
                    pos.* += 1;
                    return;
                }
            }
            if (diag) |d| {
                d.token = tok;
                if (suggest) d.unknown = suggestProbe(all_specs, cmd_entries, .bare, tok);
            }
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
        pub const default_locale = Base.default_locale;
        pub const i18n_keys = Base.i18n_keys;
        pub const i18n = Base.i18n;
        pub const View = Base.View;
        pub const parse = Base.parse;
        const parseInner = Base.parseInner;
        const parseInnerHelp = Base.parseInnerHelp;
        pub const helpData = Base.helpData;
        pub const helpText = Base.helpText;
        pub const usage = Base.usage;
        pub const Completion = Base.Completion;
        pub const completion = Base.completion;
        pub const deinit = Base.deinit;

        pub const CommandPayload = CommandPayloadOf(app, cmd_entries);

        /// Every command node of this tree, this level first, in declaration
        /// pre-order. A `View` type identifies the level it was parsed from.
        const Nodes: []const type = commandNodes(@This());

        /// Resolve a `View` type back to the command level it belongs to. A
        /// leaf (no further commands) and a foreign view are compile errors,
        /// matching how a commandless level has no `command` member at all.
        /// Every level's `View` carries a rank-named zero-sized tag field, so
        /// the mapping is exact: no two levels share a `View` type.
        fn NodeOf(comptime V: type) type {
            inline for (Nodes) |NS| {
                if (NS.View == V) {
                    if (NS.commands.len == 0) {
                        @compileError("dap.command: a leaf View of '" ++ NS.app_meta.name ++
                            "' declares no subcommands");
                    }
                    return NS;
                }
            }
            @compileError("dap.command: argument is not a command View of '" ++ app.name ++ "'");
        }

        /// D9/D10: wrap the active subcommand's View into the optional
        /// tagged union of its level; `null` when no command field was
        /// activated. Accepts a `View` from any level of this tree, so
        /// dispatch nests: `CLI.command(body)`, `CLI.command(leaf)`, ...
        pub fn command(view: anytype) ?NodeOf(@TypeOf(view)).CommandPayload {
            const NS = NodeOf(@TypeOf(view));
            inline for (NS.commands) |c| {
                if (@field(view, c.view_field)) |sub| return @unionInit(NS.CommandPayload, c.field, sub);
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
/// One active ancestor level handed down to a sub-parse, so a flag token that
/// misses the sub's own specs can be resolved up the command chain. The
/// ancestor's type is erased behind a context pointer plus the two assign
/// entry points; `up` links to the next ancestor towards the root. Flags of
/// every ancestor merge into deep help and are globally unique, so resolving
/// them here keeps parsing consistent with what help advertises.
const Ancestor = struct {
    ctx: *anyopaque,
    up: ?*const Ancestor,
    assign_long: *const fn (*anyopaque, std.mem.Allocator, []const []const u8, *usize, ?*Diag, []const u8, ?[]const u8) ParseError!bool,
    assign_short: *const fn (*anyopaque, std.mem.Allocator, []const []const u8, *usize, ?*Diag, []const u8, ?[]const u8) ParseError!bool,
};

/// Typed parse state of one ancestor level (its `View` plus the `seen` flags),
/// what an `Ancestor.ctx` really points at.
fn ParseFrame(comptime NS: type) type {
    return struct {
        v: *NS.View,
        seen: *[NS.specs.len]bool,
    };
}

/// Build the two type-erased entry points of one ancestor level.
fn ancestorFns(comptime NS: type) type {
    return struct {
        fn assignLong(ctx: *anyopaque, allocator: std.mem.Allocator, args: []const []const u8, i: *usize, diag: ?*Diag, name: []const u8, eqv: ?[]const u8) ParseError!bool {
            const frame: *ParseFrame(NS) = @ptrCast(@alignCast(ctx));
            return assignLongFlag(NS, allocator, frame.v, frame.seen, args, i, diag, name, eqv);
        }

        fn assignShort(ctx: *anyopaque, allocator: std.mem.Allocator, args: []const []const u8, i: *usize, diag: ?*Diag, name: []const u8, eqv: ?[]const u8) ParseError!bool {
            const frame: *ParseFrame(NS) = @ptrCast(@alignCast(ctx));
            return assignShortFlag(NS, allocator, frame.v, frame.seen, args, i, diag, name, eqv);
        }
    };
}

fn subApp(comptime parent: App, comptime c: CommandEntry) App {
    return .{
        .name = if (parent.name.len == 0) c.name else parent.name ++ " " ++ c.name,
        .help = c.Cmd.cmd_meta.help,
        .i18n = c.Cmd.cmd_meta.i18n,
        .help_renderer = parent.help_renderer,
        ._command_rank = c.rank,
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
    const attrs: [n]std.builtin.Type.Union.FieldAttributes = @splat(.{});
    const TagInt = std.math.IntFittingRange(0, n - 1);
    const Tag = @Enum(TagInt, .exhaustive, &names, blk: {
        var a: [n]TagInt = undefined;
        for (0..n) |i| a[i] = @intCast(i);
        break :blk &a;
    });
    return @Union(.auto, Tag, &names, &types, &attrs);
}

/// `NS` followed by every command node below it, depth-first in declaration
/// order. Child namespaces are rebuilt with the same `Sub(c.Cmd,
/// subApp(...))` expression `View` and `CommandPayload` use, so the types are
/// identical: Zig caches a generic instantiation per comptime argument tuple.
///
/// A level is identified for dispatch by its `View` type. `View` is an
/// `@Struct`, which Zig interns structurally, but every level's `View` carries
/// a zero-sized field named after its pre-order rank (`__commandN`), so two
/// levels never intern to one type. `NodeOf` can therefore match exactly.
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
    /// Declared completion predictor, if any. `null` leaves the target to the
    /// shell's own completion.
    completion: ?completion_mod.Completion.Predictor = null,
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
/// under; `name` is the wire name (`cmd_meta.name orelse field`); `synonym`
/// is the optional alternative wire name; `rank` is the command node's
/// pre-order position in the whole tree; `Cmd` is the type returned by
/// `Command(...)`.
const CommandEntry = struct {
    field: String,
    view_field: String,
    name: String,
    synonym: ?String,
    rank: usize,
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

fn typeOfField(comptime f: Field) type {
    return f.attrs.defaultValue(type).?;
}

fn instValue(comptime f: Field) f.type {
    return f.attrs.defaultValue(f.type).?;
}

/// The inner (non-optional) declaration value of an optional-typed field.
fn instValueOpt(comptime f: Field, comptime I: type) I {
    return f.attrs.defaultValue(f.type).?.?;
}

fn declLong(comptime T: type, inst: T) ?String {
    if (@hasField(T, "long")) return inst.long;
    return null;
}

fn declShort(comptime T: type, inst: T) ?String {
    if (@hasField(T, "short")) return inst.short;
    return null;
}

fn declDefault(comptime T: type, inst: T) ?Default(T.dap_value_type) {
    if (@hasField(T, "default")) return inst.default;
    return null;
}

fn declValidation(comptime T: type, inst: T) ?fn (std.mem.Allocator, T.dap_value_type) std.mem.Allocator.Error!?String {
    if (@hasField(T, "validation")) return inst.validation;
    return null;
}

fn declHelp(comptime T: type, inst: T) String {
    if (@hasField(T, "help")) return inst.help;
    return "";
}

fn declArgName(comptime T: type, inst: T) ?String {
    if (@hasField(T, "name")) return inst.name;
    return null;
}

fn declI18n(comptime T: type, inst: T) ?String {
    if (@hasField(T, "i18n")) return inst.i18n;
    return null;
}

fn declCompletion(comptime T: type, inst: T) ?completion_mod.Completion.Predictor {
    if (@hasField(T, "completion")) return inst.completion;
    return null;
}

fn isDecodable(comptime T: type) bool {
    if (T == bool) return true;
    if (T == String) return true;
    switch (@typeInfo(T)) {
        .int, .float => return true,
        .pointer => |p| return p.size == .slice and p.child == u8,
        .@"struct" => return @hasDecl(T, "decode") and @hasDecl(T, "encode") and @hasDecl(T, "deinit"),
        else => return false,
    }
}

fn isEnumerationType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "dap_enumeration");
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
///
/// A custom `decode` is a static constructor returning a fully built value, so
/// the type can own internal allocations it made with the shared allocator.
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
        .@"struct" => out.* = try T.decode(allocator, data),
        else => @compileError("type '" ++ @typeName(T) ++ "' is not decodable by dap"),
    }
}

/// Release the allocations owned by a decoded value of type `T`, mirroring
/// `decodeInto`'s dispatch. Scalars own nothing; string slices are freed;
/// custom structs release their own internals through their mandatory
/// `deinit`; optionals recurse when non-null. A zero-length slice (the `""`
/// zero default) is safe: `Allocator.free` returns early on an empty slice.
fn deinitValue(comptime T: type, allocator: std.mem.Allocator, val: *T) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float => {},
        .pointer => |p| {
            if (p.size != .slice) {
                @compileError("pointer value type of '" ++ @typeName(T) ++ "' is not deinitalizable by dap");
            }
            switch (@typeInfo(p.child)) {
                .@"struct" => {
                    for (val.*) |*el| el.deinit(allocator);
                    allocator.free(val.*);
                },
                else => allocator.free(val.*),
            }
        },
        .@"struct" => val.deinit(allocator),
        .optional => |o| {
            if (val.*) |*inner| deinitValue(o.child, allocator, inner);
        },
        else => @compileError("type '" ++ @typeName(T) ++ "' is not deinitalizable by dap"),
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
/// decoded from the wire. A custom struct default is routed through an
/// `encode`/`decode` roundtrip so the value left in `out` is fully owned by
/// `allocator`: a verbatim copy would put comptime slices under a `deinit`
/// that frees them.
fn assignDirectDefault(comptime T: type, allocator: std.mem.Allocator, d: DefaultRepr, out: *T) DecodeIntoTError!void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                out.* = try allocator.dupe(u8, d.get([]const u8));
                return;
            }
        },
        .@"struct" => {
            var tmp: T = d.get(T);
            const wire = try tmp.encode(allocator);
            defer allocator.free(wire);
            out.* = try T.decode(allocator, wire);
            return;
        },
        else => {},
    }
    out.* = d.get(T);
}

/// Try to bind a long flag token against one level's specs. `true` when the
/// level declares the flag and its value was assigned, `false` when the token
/// names no flag here. Split out of `consumeLongFlag` so the same lookup can
/// run over each active ancestor frame, letting a parent flag follow a command.
fn assignLongFlag(
    comptime NS: type,
    allocator: std.mem.Allocator,
    v: *NS.View,
    seen: *[NS.specs.len]bool,
    args: []const []const u8,
    i: *usize,
    diag: ?*Diag,
    name: []const u8,
    eqv: ?[]const u8,
) ParseError!bool {
    inline for (NS.specs, 0..) |s, si| {
        if (s.kind == .flag and std.mem.eql(u8, s.long, name)) {
            if (s.vtype == bool) {
                try assignValue(s, NS.View, allocator, v, seen, si, eqv orelse "true", diag);
            } else if (eqv) |iv| {
                try assignValue(s, NS.View, allocator, v, seen, si, iv, diag);
            } else {
                if (i.* + 1 >= args.len) {
                    if (diag) |d| d.token = args[i.*];
                    return error.MissingValue;
                }
                i.* += 1;
                try assignValue(s, NS.View, allocator, v, seen, si, args[i.*], diag);
            }
            return true;
        }
    }
    return false;
}

/// Short-alias counterpart of `assignLongFlag`.
fn assignShortFlag(
    comptime NS: type,
    allocator: std.mem.Allocator,
    v: *NS.View,
    seen: *[NS.specs.len]bool,
    args: []const []const u8,
    i: *usize,
    diag: ?*Diag,
    name: []const u8,
    eqv: ?[]const u8,
) ParseError!bool {
    inline for (NS.specs, 0..) |s, si| {
        if (s.kind == .flag) {
            if (s.short) |sh| {
                if (std.mem.eql(u8, sh, name)) {
                    if (s.vtype == bool) {
                        try assignValue(s, NS.View, allocator, v, seen, si, eqv orelse "true", diag);
                    } else if (eqv) |iv| {
                        try assignValue(s, NS.View, allocator, v, seen, si, iv, diag);
                    } else {
                        if (i.* + 1 >= args.len) {
                            if (diag) |d| d.token = args[i.*];
                            return error.MissingValue;
                        }
                        i.* += 1;
                        try assignValue(s, NS.View, allocator, v, seen, si, args[i.*], diag);
                    }
                    return true;
                }
            }
        }
    }
    return false;
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
        assignDirectDefault(s.vtype, allocator, d, &@field(v, s.name)) catch |e| {
            if (diag) |dd| dd.field = s.name;
            return e;
        };
        return;
    }
    if (s.required) {
        if (diag) |d| d.field = s.name;
        return error.MissingRequired;
    }
    @field(v, s.name) = zeroValue(specViewType(s));
}

fn specFromField(comptime f: Field) Spec {
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
        @compileError("value type of declaration field '" ++ f.name ++ "' is not decodable (needs decode/encode/deinit methods)");
    }
    const inst = if (is_opt) instValueOpt(f, T) else instValue(f);
    const pred = declCompletion(T, inst);
    if (pred) |p| {
        _ = p;
        if (V == bool or isEnumerationType(V)) {
            @compileError("declaration field '" ++ f.name ++
                "': a completion predictor is not allowed on a bool or an enumeration");
        }
    }
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
        .completion = pred,
    };
}

fn groupSpecs(comptime gdef: anytype, comptime gname: String) []const Spec {
    var out: []const Spec = &.{};
    inline for (fieldsOf(@TypeOf(gdef))) |f| {
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
    inline for (fieldsOf(@TypeOf(AT.alt_def))) |bf| {
        const Bv = @field(AT.alt_def, bf.name);
        const Bdef = if (@TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_def"))
            Bv.dap_variant_def
        else
            Bv;
        const tag = if (@TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_name"))
            Bv.dap_variant_name
        else
            bf.name;

        inline for (fieldsOf(@TypeOf(Bdef))) |mf| {
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

/// Whether `tok` names `c`, matching its primary wire name or its synonym.
fn commandMatches(comptime c: CommandEntry, tok: String) bool {
    if (std.mem.eql(u8, c.name, tok)) return true;
    if (c.synonym) |s| return std.mem.eql(u8, s, tok);
    return false;
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

fn normalize(comptime def: anytype) NormResult {
    return normalizeRanked(def, 0);
}

/// Number of command nodes in a raw declaration subtree: one per
/// `Command(...)` field, recursively. Mirrors what `commandNodes` would count
/// for the generated namespaces, but without instantiating `generate`.
fn commandSubtreeCount(comptime def: anytype) usize {
    comptime {
        var n: usize = 0;
        for (fieldsOf(@TypeOf(def))) |f| {
            if (f.type != type) continue;
            const V = typeOfField(f);
            if (@hasDecl(V, "dap_kind") and V.dap_kind == .command) {
                n += 1 + commandSubtreeCount(V.cmd_def);
            }
        }
        return n;
    }
}

/// `normalize` with the level's own pre-order rank. Commands get consecutive
/// ranks over the whole tree: the first child is `base_rank + 1`, each next
/// sibling skips the command nodes in the preceding sibling's subtree.
/// `generate` passes `app._command_rank`; the ranks end up in the generated
/// `View` tag field and keep every level's `View` type distinct.
fn normalizeRanked(comptime def: anytype, comptime base_rank: usize) NormResult {
    comptime checks_mod.checkNoUnderscoreFields(def);
    var specs: []const Spec = &.{};
    var commands: []const CommandEntry = &.{};
    var alts: []const AltLevel = &.{};
    var next_rank: usize = base_rank + 1;

    inline for (fieldsOf(@TypeOf(def))) |f| {
        if (f.type == type) {
            const V = typeOfField(f);
            if (@hasDecl(V, "dap_kind") and V.dap_kind == .command) {
                commands = commands ++ &[_]CommandEntry{.{
                    .field = f.name,
                    .view_field = viewCommandField(f.name),
                    .name = commandWireName(V.cmd_meta, f.name),
                    .synonym = V.cmd_meta.synonym,
                    .rank = next_rank,
                    .Cmd = V,
                }};
                next_rank += 1 + commandSubtreeCount(V.cmd_def);
            } else if (@hasDecl(V, "dap_kind") and V.dap_kind == .group) {
                specs = specs ++ groupSpecs(V.group_def, V.group_name);
            } else if (@hasDecl(V, "dap_kind") and V.dap_kind == .alt) {
                specs = specs ++ altSpecs(V, f.name);
                alts = alts ++ &[_]AltLevel{.{ .field = f.name, .AT = V }};
            } else {
                @compileError("unknown type-valued declaration field '" ++ f.name ++ "'");
            }
        } else {
            specs = specs ++ &[_]Spec{specFromField(f)};
        }
    }

    checks_mod.checkDuplicates(specs);
    checks_mod.checkFieldNames(specs);
    checks_mod.checkArgumentDefaults(specs);
    checks_mod.checkCommandNames(commands);
    checks_mod.checkCommandFieldNames(specs, commands);
    checks_mod.checkCommandArgumentMix(specs, commands);

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
    try std.testing.expectEqualStrings("x", @typeInfo(A.branch_types[0]).@"struct".field_names[0]);
    try std.testing.expectEqualStrings("fancy-alt2", VariantNamed("fancy-alt2", .{}).dap_variant_name);
}

test "enumeration and enum defaults" {
    const e = Enum{};
    try std.testing.expect(e.name == null);
    try std.testing.expect(e.help == null);

    const m = CommandMeta{};
    try std.testing.expect(m.name == null);
    try std.testing.expect(m.i18n == null);
    try std.testing.expectEqualStrings("", m.help);

    _ = Enumeration(.{});
}

test "enumeration exposes names, helps and help keys" {
    const E = Enumeration(.{
        .fast = Enum{},
        .glacial = Enum{ .help = .{ .text = "Slow mode." } },
        .cold = Enum{
            .name = "ice",
            .help = .{ .text = "Ice mode.", .i18n = "mode_ice" },
        },
        .blank = Enum{ .help = .{ .text = "" } },
    });
    try std.testing.expectEqualStrings("fast", E.names[0]);
    try std.testing.expectEqualStrings("glacial", E.names[1]);
    try std.testing.expectEqualStrings("ice", E.names[2]);
    try std.testing.expectEqualStrings("blank", E.names[3]);
    try std.testing.expectEqual(@as(?String, null), E.helps[0]);
    try std.testing.expectEqualStrings("Slow mode.", E.helps[1].?);
    try std.testing.expectEqualStrings("Ice mode.", E.helps[2].?);
    try std.testing.expect(E.helps[3] != null);
    try std.testing.expectEqualStrings("", E.helps[3].?);
    try std.testing.expectEqual(@as(?String, null), E.help_i18n[0]);
    try std.testing.expectEqual(@as(?String, null), E.help_i18n[1]);
    try std.testing.expectEqualStrings("mode_ice", E.help_i18n[2].?);
    try std.testing.expectEqual(@as(?String, null), E.help_i18n[3]);

    const Empty = Enumeration(.{});
    try std.testing.expect(!@hasDecl(Empty, "names"));
    try std.testing.expect(!@hasDecl(Empty, "helps"));
    try std.testing.expect(!@hasDecl(Empty, "help_i18n"));
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
    .stop = Command(.{ .name = "halt", .synonym = "quit", .help = "Stop." }, .{}),
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
    try std.testing.expectEqualStrings("builtin_help", specs[0].i18n.?);

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
    try std.testing.expect(C.commands[0].synonym == null);
    try std.testing.expectEqualStrings("quit", C.commands[1].synonym.?);
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

test "M1: command synonym clashes are a compile error" {
    if (false) {
        // Synonym shadowing another command's primary name.
        const BadName = .{
            .a = Command(.{ .name = "alpha", .synonym = "beta" }, .{}),
            .b = Command(.{ .name = "beta" }, .{}),
        };
        comptime _ = normalize(BadName);
    }
    if (false) {
        // Two commands claiming the same synonym.
        const BadSynonym = .{
            .a = Command(.{ .synonym = "shared" }, .{}),
            .b = Command(.{ .name = "other", .synonym = "shared" }, .{}),
        };
        comptime _ = normalize(BadSynonym);
    }
    if (false) {
        // A synonym repeating its own command's primary name.
        const BadSelf = .{
            .a = Command(.{ .name = "alpha", .synonym = "alpha" }, .{}),
        };
        comptime _ = normalize(BadSelf);
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
    const fields = fieldsOf(V);

    // 7 specs (builtin_help injected first) + the rank tag + the locale
    // pointer + 2 command fields.
    try std.testing.expectEqual(@as(usize, 11), fields.len);

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

    // the rank tag sits between the specs and the command fields.
    try std.testing.expectEqualStrings("__command0", fields[7].name);
    try std.testing.expectEqual(@as(type, u0), fields[7].type);

    // the selected locale pointer follows the rank tag.
    try std.testing.expectEqualStrings("__i18n", fields[8].name);
    try std.testing.expectEqual(@as(type, *const I18n.Locale), fields[8].type);

    // trailing command fields are optional sub-Views, hidden behind a `_`
    // prefix.
    try std.testing.expectEqualStrings("_start", fields[9].name);
    try std.testing.expect(@typeInfo(fields[9].type) == .optional);
    try std.testing.expect(@typeInfo(@typeInfo(fields[9].type).optional.child) == .@"struct");
    try std.testing.expectEqualStrings("_stop", fields[10].name);
    try std.testing.expect(@typeInfo(fields[10].type) == .optional);
    try std.testing.expect(@typeInfo(@typeInfo(fields[10].type).optional.child) == .@"struct");
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

test "M2: View without commands carries spec fields and the tag" {
    const C = generate(App{ .name = "app", .help = "help" }, .{
        .a = Flag(u8){ .default = Default(u8){ .direct = 0 } },
        .b = Argument([]const u8){},
    });
    const fields = fieldsOf(C.View);
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqualStrings("builtin_help", fields[0].name);
    try std.testing.expectEqual(@as(type, bool), fields[0].type);
    try std.testing.expectEqualStrings("a", fields[1].name);
    try std.testing.expectEqual(@as(type, u8), fields[1].type);
    try std.testing.expectEqualStrings("b", fields[2].name);
    try std.testing.expectEqual(@as(type, []const u8), fields[2].type);
    try std.testing.expectEqualStrings("__command0", fields[3].name);
    try std.testing.expectEqual(@as(type, u0), fields[3].type);
    try std.testing.expectEqualStrings("__i18n", fields[4].name);
    try std.testing.expectEqual(@as(type, *const I18n.Locale), fields[4].type);
}

test "M2: command View fields are optional sub-views" {
    const C = generate(App{ .name = "app", .help = "help" }, M1CmdDef);

    try std.testing.expectEqual(@as(usize, 2), C.commands.len);

    // each command field's View payload is the command's generated View; the
    // injected builtin_help field occupies the first slot of every sub, and
    // the rank-named tag follows the specs. Command fields carry a `_` prefix
    // in the View.
    const StartSub = @typeInfo(@FieldType(C.View, "_start")).optional.child;
    const start_fields = fieldsOf(StartSub);
    try std.testing.expectEqual(@as(usize, 4), start_fields.len);
    try std.testing.expectEqualStrings("builtin_help", start_fields[0].name);
    try std.testing.expectEqualStrings("name", start_fields[1].name);
    try std.testing.expectEqualStrings("__command1", start_fields[2].name);
    try std.testing.expectEqualStrings("__i18n", start_fields[3].name);
    try std.testing.expectEqual(@as(type, *const I18n.Locale), start_fields[3].type);

    const HaltSub = @typeInfo(@FieldType(C.View, "_stop")).optional.child;
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(HaltSub).@"struct".field_names.len);
    try std.testing.expectEqualStrings("__i18n", fieldsOf(HaltSub)[2].name);

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

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!DecodeOk {
        _ = allocator;
        return .{ .value = std.fmt.parseInt(u32, data, 10) catch return error.InvalidWire };
    }

    pub fn encode(self: *DecodeOk, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        _ = self;
        return try allocator.dupe(u8, "");
    }

    pub fn deinit(self: *DecodeOk, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const DecodeReject = struct {
    value: u8 = 0,

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!DecodeReject {
        _ = allocator;
        _ = data;
        return error.InvalidValue;
    }

    pub fn encode(self: *DecodeReject, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        _ = self;
        return try allocator.dupe(u8, "");
    }

    pub fn deinit(self: *DecodeReject, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
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
    .stop = Command(.{ .name = "halt", .synonym = "quit", .help = "Stop." }, .{}),
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

test "M7: command synonym is accepted as an alternative name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--needed", "v", "quit" }, &diag);
    try std.testing.expect(a._stop != null);
    try std.testing.expect(a._start == null);
    try std.testing.expect(diag.message == null);
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

test "M7: root flags resolve after a command handoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // Root flags and the sub's own flag interleave after the command token; the
    // parent's `--verbose`/`--needed` are resolved up the ancestor chain while
    // `--force` stays with the sub.
    const a = try m7Parse(&arena, &.{ "start", "file", "--verbose", "--needed", "v", "--force" }, &diag);
    try std.testing.expect(a.verbose);
    try std.testing.expectEqualStrings("v", a.needed);
    try std.testing.expect(a._start != null);
    try std.testing.expect(a._start.?.force);
    try std.testing.expectEqualStrings("file", a._start.?.name);

    // An unknown token is still rejected even with active ancestors.
    try std.testing.expectError(error.UnknownFlag, m7Parse(&arena, &.{ "start", "file", "--nope" }, &diag));
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
    try std.testing.expectEqualStrings("fast", @tagName(@as(ModeView, @fromBackingInt(@intCast(0)))));
    try std.testing.expectEqualStrings("slow", @tagName(@as(ModeView, @fromBackingInt(@intCast(1)))));
    try std.testing.expectEqualStrings("fast", Mode.names[0]);
    try std.testing.expectEqualStrings("glacial", Mode.names[1]);
}

test "M8: enumeration round-trips wire names through decode/encode" {
    const allocator = std.testing.allocator;
    var m: Mode = .{};
    const fast = try m.encode(allocator);
    defer allocator.free(fast);
    try std.testing.expectEqualStrings("fast", fast);

    m = try Mode.decode(allocator, "glacial");
    const glacial = try m.encode(allocator);
    defer allocator.free(glacial);
    try std.testing.expectEqualStrings("glacial", glacial);
    try std.testing.expectEqual(Mode.EnumView.slow, m.view);

    m = try Mode.decode(allocator, "fast");
    try std.testing.expectEqual(Mode.EnumView.fast, m.view);

    try std.testing.expectError(error.InvalidWire, Mode.decode(allocator, "nope"));
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

    const a = try CLI.parse(allocator, std.process.Environ.empty, null, &.{ "--mode", "glacial", "f" }, &diag);
    var amode = a.mode;
    const encoded = try amode.encode(allocator);
    try std.testing.expectEqualStrings("glacial", encoded);
    try std.testing.expectEqualStrings("f", a.file);

    const b = try CLI.parse(allocator, std.process.Environ.empty, null, &.{"f"}, &diag);
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

    const a = try CLI.parse(allocator, std.process.Environ.empty, null, &.{"glacial"}, &diag);
    var amode = a.mode;
    const encoded = try amode.encode(allocator);
    try std.testing.expectEqualStrings("glacial", encoded);
}

test "M8: empty enumeration is a decodable value type that rejects everything" {
    const Empty = Enumeration(.{});
    var e: Empty = .{};
    try std.testing.expectError(error.InvalidWire, Empty.decode(std.testing.allocator, "anything"));
    const encoded = try e.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("", encoded);
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
            .i18n = "server_host",
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

const I18nResolveDef = .{
    .verbose = Flag(bool){ .help = "Verbose.", .i18n = "res_flag" },
    .serve = Command(.{ .help = "Serve.", .i18n = "res_cmd" }, .{
        .target = Argument(String){ .help = "Target.", .i18n = "res_arg" },
    }),
};
const I18nResolve = generate(
    App{
        .name = "res",
        .help = "Res app.",
        .i18n = "res_app",
        .help_renderer = .{ .highlight = .{ .flat = {} } },
    },
    I18nResolveDef,
);

test "i18n: a translated locale localizes headings and placeholders" {
    const locale = I18n.ru.withUser(.{});
    var data = try M9Cmd.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const h = try data.renderCompact(&locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "Использование: app ") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<команда>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "[флаги]") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "Флаги:") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "Команды:") != null);
}

test "i18n: keyed rows resolve through the user map" {
    const locale = I18n.ru.withUser(.{
        .res_app = "Приложение.",
        .res_flag = "Флаг.",
        .res_cmd = "Служить.",
        .res_arg = "Цель.",
    });
    var root = try I18nResolve.helpData(std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    const rh = try root.renderCompact(&locale, std.testing.allocator);
    defer std.testing.allocator.free(rh);
    try std.testing.expect(std.mem.indexOf(u8, rh, "Приложение.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rh, "Флаг.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rh, "Служить.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rh, "Res app.") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try I18nResolve.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "serve", "-h" }, &diag);
    const sh = try contextHelpText(I18nResolve, arena.allocator(), &v, &locale);
    try std.testing.expect(std.mem.indexOf(u8, sh, "Цель.") != null);
}

test "i18n: a missing translation key is an error, never the literal" {
    const locale = I18n.Locale.default(&[_]I18n.Entry{});
    var data = try I18nResolve.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnknownTranslationKey,
        data.renderCompact(&locale, std.testing.allocator),
    );
}

test "i18n: English output is identical with the default locale" {
    var data = try M9.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const direct = try data.renderCompact(&M9.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(direct);
    const via_help = try M9.helpText(std.testing.allocator);
    defer std.testing.allocator.free(via_help);
    try std.testing.expectEqualStrings(via_help, direct);
}

var m10CapturedLocale: ?*const I18n.Locale = null;

fn m10RenderCapture(_: *const HelpData, locale: *const I18n.Locale, allocator: std.mem.Allocator) HelpError!String {
    m10CapturedLocale = locale;
    return try allocator.dupe(u8, "captured");
}

test "i18n: a custom renderer receives the locale pointer" {
    const CLI = generate(
        App{ .name = "cap", .help = "", .help_renderer = .{ .style = .{ .custom = m10RenderCapture } } },
        M10Def,
    );
    const h = try CLI.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("captured", h);
    try std.testing.expect(m10CapturedLocale == &CLI.default_locale);
}

test "i18n: buildErrorText localizes diagnostics and suggestions" {
    const locale = I18n.ru.withUser(.{});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const diag: Diag = .{
        .field = "f",
        .token = "--t",
        .message = "m",
        .unknown = .{ .flag = .{
            .name = "dry_run",
            .short = "d",
            .kind = .flag,
            .distance = 1,
            .reason = .edit,
        } },
    };
    const text = try M9.buildErrorText(&buf, std.testing.allocator, &diag, &locale);
    const expected =
        \\неверное поле 'f' или оно отсутствует
        \\неверный токен '--t'
        \\m
        \\возможно, вы имели в виду '-d'?
    ;
    try std.testing.expectEqualStrings(expected, text);
}

test "i18n: a translated failure page localizes its diagnostics" {
    const locale = I18n.ru.withUser(.{ .server_host = "Сервер." });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const diag: Diag = .{ .field = "target" };
    const err = try M9.buildErrorText(&buf, std.testing.allocator, &diag, &locale);
    try std.testing.expectEqualStrings("неверное поле 'target' или оно отсутствует", err);
    var data = try M9.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    data.error_text = err;
    const h = try data.renderCompact(&locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "неверное поле 'target' или оно отсутствует\n"));
}

const S6Builder = I18nResolve.i18n()
    .append("ru", I18n.ru.withUser(.{
        .res_app = "Приложение.",
        .res_flag = "Флаг.",
        .res_cmd = "Служить.",
        .res_arg = "Цель.",
    }))
    .append("ja", I18n.ja.withUser(.{
    .res_app = "アプリ。",
    .res_flag = "フラグ。",
    .res_cmd = "サーブ。",
    .res_arg = "ターゲット。",
}));

test "i18n: parse selects the locale from LC_ALL, LC_MESSAGES and LANG" {
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};

    const lc_all = [_][*:0]const u8{ "LC_ALL=ru_RU.UTF-8", "LANG=ja_JP.UTF-8" };
    const env_all = makeEnviron(&lc_all);
    const v = try I18nResolve.parse(a, env_all, &S6Builder, &.{ "serve", "x" }, &diag);
    try std.testing.expect(v.__i18n == S6Builder.locale(env_all));
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, v.__i18n.meta.usage);
    try std.testing.expectEqualStrings(I18n.ru.meta.flags, v.__i18n.meta.flags);
    try std.testing.expectEqualStrings("Приложение.", try v.__i18n.require("res_app"));
    try std.testing.expect(v._serve.?.__i18n == v.__i18n);

    const lc_messages = [_][*:0]const u8{ "LC_MESSAGES=ja_JP.UTF-8", "LANG=ru_RU.UTF-8" };
    const env_messages = makeEnviron(&lc_messages);
    const vm = try I18nResolve.parse(a, env_messages, &S6Builder, &.{ "serve", "x" }, &diag);
    try std.testing.expect(vm.__i18n == S6Builder.locale(env_messages));
    try std.testing.expectEqualStrings(I18n.ja.meta.usage, vm.__i18n.meta.usage);
    try std.testing.expectEqualStrings("アプリ。", try vm.__i18n.require("res_app"));

    const lang = [_][*:0]const u8{"LANG=ru_RU.UTF-8"};
    const env_lang = makeEnviron(&lang);
    const vl = try I18nResolve.parse(a, env_lang, &S6Builder, &.{ "serve", "x" }, &diag);
    try std.testing.expect(vl.__i18n == S6Builder.locale(env_lang));
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, vl.__i18n.meta.usage);
}

test "i18n: exact tag, language fallback and default fallback" {
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};

    // Exact tag.
    const exact_envp = [_][*:0]const u8{"LC_ALL=ru"};
    const exact_env = makeEnviron(&exact_envp);
    const exact = try I18nResolve.parse(a, exact_env, &S6Builder, &.{ "serve", "x" }, &diag);
    try std.testing.expect(exact.__i18n == S6Builder.locale(exact_env));
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, exact.__i18n.meta.usage);

    // Language part before the first `_`.
    const language_envp = [_][*:0]const u8{"LC_ALL=ru_RU.UTF-8"};
    const language_env = makeEnviron(&language_envp);
    const language = try I18nResolve.parse(a, language_env, &S6Builder, &.{ "serve", "x" }, &diag);
    try std.testing.expect(language.__i18n == S6Builder.locale(language_env));
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, language.__i18n.meta.usage);

    // Unknown language falls back to the declaration default.
    const default_envp = [_][*:0]const u8{"LC_ALL=xx_YY.UTF-8"};
    const default_env = makeEnviron(&default_envp);
    const fallback = try I18nResolve.parse(a, default_env, &S6Builder, &.{ "serve", "x" }, &diag);
    try std.testing.expectEqualStrings(I18nResolve.default_locale.meta.usage, fallback.__i18n.meta.usage);
    try std.testing.expectEqualStrings("Res app.", try fallback.__i18n.require("res_app"));
    try std.testing.expect(fallback._serve.?.__i18n == fallback.__i18n);
}

test "i18n: a null builder selects the declaration default at every level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};

    const v = try I18nResolve.parse(a, std.process.Environ.empty, null, &.{ "serve", "x" }, &diag);
    try std.testing.expect(v.__i18n == v._serve.?.__i18n);
    try std.testing.expectEqualStrings(I18nResolve.default_locale.meta.usage, v.__i18n.meta.usage);
    try std.testing.expectEqualStrings("Res app.", try v.__i18n.require("res_app"));
}

var s6CapturedLocale: ?*const I18n.Locale = null;

fn s6RenderCapture(_: *const HelpData, locale: *const I18n.Locale, allocator: std.mem.Allocator) HelpError!String {
    s6CapturedLocale = locale;
    return try allocator.dupe(u8, "");
}

/// Records the locale then fails, so `usage` never writes to stdout (the Zig
/// test harness owns it) while the locale threading is still observable.
fn s6UsageCapture(_: *const HelpData, locale: *const I18n.Locale, _: std.mem.Allocator) HelpError!String {
    s6CapturedLocale = locale;
    return error.UnknownTranslationKey;
}

test "i18n: usage renders with the locale carried by the view" {
    const CLI = generate(
        App{ .name = "s6", .help = "S6.", .help_renderer = .{ .style = .{ .custom = s6UsageCapture } } },
        .{
            .serve = Command(.{ .help = "Serve." }, .{
                .target = Argument(String){ .help = "Target." },
            }),
        },
    );
    const builder = comptime CLI.i18n().append("ru", I18n.ru.withUser(.{}));
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    const envp = [_][*:0]const u8{"LC_ALL=ru"};
    const env = makeEnviron(&envp);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    var v = try CLI.parse(a, env, &builder, &.{ "serve", "x" }, &diag);
    defer CLI.deinit(&v, a);

    const sub = v._serve.?;
    try std.testing.expect(sub.__i18n == builder.locale(env));
    s6CapturedLocale = null;
    try std.testing.expectError(error.UnknownTranslationKey, CLI.usage(sub));
    try std.testing.expect(s6CapturedLocale == sub.__i18n);
    try std.testing.expect(s6CapturedLocale != &CLI.default_locale);
}

test "i18n: help intercept and failure page use the selected locale" {
    const CLI = generate(
        App{ .name = "s6h", .help = "S6H.", .help_renderer = .{ .style = .{ .custom = s6RenderCapture } } },
        .{
            .verbose = Flag(bool){ .help = "Verbose." },
        },
    );
    const builder = comptime CLI.i18n().append("ru", I18n.ru.withUser(.{}));
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    const envp = [_][*:0]const u8{"LC_ALL=ru"};
    const env = makeEnviron(&envp);
    const locale = builder.locale(env);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};

    // The help intercept renders the merged page with the selected locale.
    var help_out: CLI.View = undefined;
    const help_v = try CLI.parseInnerHelp(a, env, locale, &.{"-h"}, &diag, false, null, &help_out);
    try std.testing.expect(help_v.__i18n == locale);
    s6CapturedLocale = null;
    _ = try contextHelpText(CLI, a, &help_v, help_v.__i18n);
    try std.testing.expect(s6CapturedLocale == locale);

    // The failure page receives the locale explicitly.
    var failed: CLI.View = undefined;
    var fail_diag: Diag = .{};
    try std.testing.expectError(
        error.UnknownFlag,
        CLI.parseInnerHelp(a, env, locale, &.{"--nope"}, &fail_diag, false, null, &failed),
    );
    try std.testing.expect(failed.__i18n == locale);
    s6CapturedLocale = null;
    _ = try CLI.failureHelpText(a, &failed, null, locale);
    try std.testing.expect(s6CapturedLocale == locale);
}

test "i18n: helpText still renders the declaration default locale" {
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    const envp = [_][*:0]const u8{"LC_ALL=ru"};
    const env = makeEnviron(&envp);
    const locale = S6Builder.locale(env);
    try std.testing.expect(locale != &I18nResolve.default_locale);

    const h = try I18nResolve.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "Res app.") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "Приложение.") == null);
}

const E2EDef = .{
    .loud = Flag(bool){ .help = "Loud.", .i18n = "e2e_loud" },
    .serve = Command(.{ .help = "Serve.", .i18n = "e2e_serve" }, .{
        .item = Argument(String){ .help = "Item.", .i18n = "e2e_item" },
    }),
};

var e2eSnapshot: [1024]u8 = undefined;
var e2eSnapshotLen: usize = 0;
var e2eCapturedLocale: ?*const I18n.Locale = null;

/// Records the locale and the resolved rows, then fails so `usage` never
/// writes to stdout (the Zig test harness owns it) while the translated
/// values are still observable.
fn e2eRender(data: *const HelpData, locale: *const I18n.Locale, _: std.mem.Allocator) HelpError!String {
    e2eCapturedLocale = locale;
    var w: std.Io.Writer = .fixed(&e2eSnapshot);
    w.print("{s}{s}\n", .{ locale.meta.usage, data.name }) catch return error.OutOfMemory;
    for (data.flag_groups) |g| {
        for (g.flags) |o| {
            const help = resolve(locale, o.i18n, o.help) catch return error.UnknownTranslationKey;
            w.print("{s} {s}\n", .{ locale.meta.flags, help }) catch return error.OutOfMemory;
        }
    }
    for (data.arg_groups) |g| {
        for (g.args) |a| {
            const help = resolve(locale, a.i18n, a.help) catch return error.UnknownTranslationKey;
            w.print("{s} {s}\n", .{ locale.meta.args, help }) catch return error.OutOfMemory;
        }
    }
    for (data.commands) |c| {
        const help = resolve(locale, c.i18n, c.help) catch return error.UnknownTranslationKey;
        w.print("{s} {s}\n", .{ locale.meta.cmds, help }) catch return error.OutOfMemory;
    }
    e2eSnapshotLen = w.buffered().len;
    return error.UnknownTranslationKey;
}

const E2ECLI = generate(
    App{
        .name = "e2e",
        .help = "End to end.",
        .i18n = "e2e_app",
        .help_renderer = .{ .style = .{ .custom = e2eRender } },
    },
    E2EDef,
);

const E2EBuilder = E2ECLI.i18n()
    .append("ru", I18n.ru.withUser(.{
    .e2e_app = "Сквозной тест.",
    .e2e_loud = "Громкий флаг.",
    .e2e_serve = "Служить.",
    .e2e_item = "Элемент.",
}));

// A locale missing a required key is a compile error at the `append` call
// site. Enable this case manually to see the message:
//
// test "i18n: a builder missing a required key is a compile error" {
//     _ = comptime E2ECLI.i18n().append("ru", I18n.ru.withUser(.{
//         .e2e_app = "Сквозной тест.",
//         .e2e_loud = "Громкий флаг.",
//         .e2e_serve = "Служить.",
//         // .e2e_item omitted
//     }));
// }

test "i18n: end-to-end keyed declaration, builder and renderer" {
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    const envp = [_][*:0]const u8{"LC_ALL=ru_RU.UTF-8"};
    const env = makeEnviron(&envp);
    const locale = E2EBuilder.locale(env);
    try std.testing.expect(locale != &E2ECLI.default_locale);
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, locale.meta.usage);
    try std.testing.expectEqualStrings("Сквозной тест.", try locale.require("e2e_app"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};

    var v = try E2ECLI.parse(a, env, &E2EBuilder, &.{ "serve", "x" }, &diag);
    defer E2ECLI.deinit(&v, a);
    try std.testing.expect(v.__i18n == locale);
    try std.testing.expect(v._serve.?.__i18n == locale);

    // usage() renders through the view's locale; the renderer records the
    // translated headings and rows before failing to keep stdout clean.
    e2eCapturedLocale = null;
    e2eSnapshotLen = 0;
    try std.testing.expectError(error.UnknownTranslationKey, E2ECLI.usage(v));
    try std.testing.expect(e2eCapturedLocale == locale);
    const sub_page = e2eSnapshot[0..e2eSnapshotLen];
    try std.testing.expect(std.mem.indexOf(u8, sub_page, I18n.ru.meta.usage) != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_page, I18n.ru.meta.flags) != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_page, I18n.ru.meta.args) != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_page, "Громкий флаг.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_page, "Элемент.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_page, "Loud.") == null);
    try std.testing.expect(std.mem.indexOf(u8, sub_page, "Item.") == null);

    // The root page lists the translated command row.
    var root = try E2ECLI.parse(a, env, &E2EBuilder, &.{}, &diag);
    defer E2ECLI.deinit(&root, a);
    e2eSnapshotLen = 0;
    try std.testing.expectError(error.UnknownTranslationKey, E2ECLI.usage(root));
    const root_page = e2eSnapshot[0..e2eSnapshotLen];
    try std.testing.expect(std.mem.indexOf(u8, root_page, I18n.ru.meta.cmds) != null);
    try std.testing.expect(std.mem.indexOf(u8, root_page, "Служить.") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_page, "Serve.") == null);

    // The builder only registered the language tag; `ru_RU.UTF-8` reaches it
    // through the language fallback, and an unknown tag selects the default.
    const unknown = [_][*:0]const u8{"LC_ALL=xx_YY.UTF-8"};
    try std.testing.expectEqualStrings(
        E2ECLI.default_locale.meta.usage,
        E2EBuilder.locale(makeEnviron(&unknown)).meta.usage,
    );
    try std.testing.expectEqualStrings(
        "End to end.",
        try E2ECLI.default_locale.require("e2e_app"),
    );
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

test "M9: environment-only defaults render as $NAME" {
    const def = .{
        .user = Flag([]const u8){ .default = Default([]const u8){ .env = "DAP_USER" }, .help = "User." },
        .port = Flag(u16){ .default = Default(u16){ .env = "DAP_PORT", .direct = 4242 }, .help = "Port." },
        .no_color = Flag(bool){ .default = Default(bool){ .env = "NO_COLOR" }, .help = "Disable color." },
        .mode = Argument([]const u8){ .default = Default([]const u8){ .env = "MODE" }, .help = "Mode." },
    };
    const CLI = generate(App{ .name = "env", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);
    var data = try CLI.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    // The injected help flag occupies slot 0; user flags follow in order.
    try std.testing.expectEqualStrings("$DAP_USER", data.flag_groups[0].flags[1].default.?);
    // The direct default wins when both are declared.
    try std.testing.expectEqualStrings("4242", data.flag_groups[0].flags[2].default.?);
    try std.testing.expectEqualStrings("$NO_COLOR", data.flag_groups[0].flags[3].default.?);
    try std.testing.expectEqualStrings("$MODE", data.arg_groups[0].args[0].default.?);

    const text = try CLI.helpText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // The env-only bool is defaulted, so it leaves the usage header.
    try std.testing.expect(std.mem.indexOf(u8, text, "[--no_color]") == null);
    // The env-only argument is bracketed in the usage line.
    try std.testing.expect(std.mem.indexOf(u8, text, "[<mode>]") != null);
    // The flag left column spells the env-only default as `$NAME`.
    try std.testing.expect(std.mem.indexOf(u8, text, "--user=$DAP_USER") != null);
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

const M9EnumType = Enumeration(.{
    .json = Enum{ .help = .{ .text = "Machine-readable JSON output." } },
    .yaml = Enum{ .help = .{ .text = "Human-readable YAML config.", .i18n = "fmt_yaml" } },
    .toml = Enum{},
    .text = Enum{ .help = .{ .text = "Plain text.", .i18n = "" } },
    .quiet = Enum{ .help = .{ .text = "" } },
});

const M9ArgEnumType = Enumeration(.{
    .json = Enum{ .help = .{ .text = "Machine-readable JSON output." } },
    .yaml = Enum{ .help = .{ .text = "Human-readable YAML config." } },
    .toml = Enum{},
    .text = Enum{ .help = .{ .text = "Plain text." } },
    .quiet = Enum{ .help = .{ .text = "" } },
});

const M9EnumHelp = generate(
    App{
        .name = "app",
        .help = "",
        .help_renderer = .{ .highlight = .{ .flat = {} } },
    },
    .{
        .format = Flag(M9EnumType){ .help = "Output format." },
        .nothing = Flag(Enumeration(.{})){ .help = "Nothing." },
        // A keyed enumeration cannot be reused in a second field without
        // duplicating its branch keys, so the argument uses a keyless copy.
        .mode = Argument(M9ArgEnumType){ .help = "Mode." },
    },
);

test "M9: helpData fills enumeration values" {
    var data = try M9EnumHelp.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    const flags = data.flag_groups[0].flags;
    // Entry 0 is the injected builtin help: a non-enumeration type has no
    // values.
    try std.testing.expectEqual(@as(usize, 0), flags[0].values.len);
    // The empty `Enumeration` contributes an empty list too.
    try std.testing.expectEqual(@as(usize, 0), flags[2].values.len);

    const format = flags[1];
    try std.testing.expectEqual(@as(usize, 5), format.values.len);
    try std.testing.expectEqualStrings("json", format.values[0].name);
    try std.testing.expectEqualStrings("Machine-readable JSON output.", format.values[0].help.?);
    try std.testing.expect(format.values[0].i18n == null);
    try std.testing.expectEqualStrings("yaml", format.values[1].name);
    try std.testing.expectEqualStrings("Human-readable YAML config.", format.values[1].help.?);
    try std.testing.expectEqualStrings("fmt_yaml", format.values[1].i18n.?);
    try std.testing.expectEqualStrings("toml", format.values[2].name);
    try std.testing.expect(format.values[2].help == null);
    try std.testing.expect(format.values[2].i18n == null);
    // An empty key means "no translation", not an empty-keyed lookup.
    try std.testing.expectEqualStrings("text", format.values[3].name);
    try std.testing.expectEqualStrings("Plain text.", format.values[3].help.?);
    try std.testing.expect(format.values[3].i18n == null);
    // An explicitly empty literal stays distinct from "not declared".
    try std.testing.expectEqualStrings("quiet", format.values[4].name);
    try std.testing.expectEqual(@as(usize, 0), format.values[4].help.?.len);
    try std.testing.expect(format.values[4].i18n == null);

    const mode = data.arg_groups[0].args[0];
    try std.testing.expectEqual(@as(usize, 5), mode.values.len);
    try std.testing.expectEqualStrings("json", mode.values[0].name);
    try std.testing.expectEqualStrings("yaml", mode.values[1].name);
    try std.testing.expectEqualStrings("toml", mode.values[2].name);
}

test "M9: helpData frees enumeration values when an allocation fails" {
    const FailingAllocator = std.testing.FailingAllocator;

    const total = blk: {
        var probe = FailingAllocator.init(std.testing.allocator, .{});
        var data = try M9EnumHelp.helpData(probe.allocator());
        data.deinit(probe.allocator());
        break :blk probe.allocations;
    };

    var fi: usize = 0;
    while (fi <= total) : (fi += 1) {
        var fa = FailingAllocator.init(std.testing.allocator, .{ .fail_index = fi });
        if (M9EnumHelp.helpData(fa.allocator())) |data| {
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
        \\  [<target>]    Target directory. Default value: .
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
    const h = try data.renderCompact(&CLI.default_locale, std.testing.allocator);
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
    const h = try data.renderCompact(&CLI.default_locale, std.testing.allocator);
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
    const h = try data.renderCompact(&CLI.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings(expected, h);
}

test "M9: renderCompact frees everything when an allocation fails" {
    const FailingAllocator = std.testing.FailingAllocator;

    const total = blk: {
        var probe = FailingAllocator.init(std.testing.allocator, .{});
        var data = try M9.helpData(probe.allocator());
        if (data.renderCompact(&M9.default_locale, probe.allocator())) |s| {
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
        if (data.renderCompact(&M9.default_locale, fa.allocator())) |s| {
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

fn m10RenderMinimal(_: *const HelpData, _: *const I18n.Locale, allocator: std.mem.Allocator) HelpError!String {
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

fn renderWithHighlight(comptime hl: HelpRendererHighlight, locale: *const I18n.Locale, allocator: std.mem.Allocator) HelpError!String {
    const CLI = generate(App{
        .name = "app",
        .help = "Do things.",
        .help_renderer = .{ .highlight = hl },
    }, M9Def);
    var data = try CLI.helpData(allocator);
    defer data.deinit(allocator);
    return try data.renderCompact(locale, allocator);
}

test "M11: flat highlight emits no escape codes" {
    const h = try renderWithHighlight(.{ .flat = {} }, &M9.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOfScalar(u8, h, 0x1b) == null);
}

test "M11: highlighting leaves the column widths untouched" {
    const flat = try renderWithHighlight(.{ .flat = {} }, &M9.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(flat);

    inline for (.{ HelpRendererHighlight{ .bold = {} }, HelpRendererHighlight{ .color = {} } }) |hl| {
        const styled = try renderWithHighlight(hl, &M9.default_locale, std.testing.allocator);
        defer std.testing.allocator.free(styled);
        const stripped = try stripSgr(std.testing.allocator, styled);
        defer std.testing.allocator.free(stripped);
        try std.testing.expectEqualStrings(flat, stripped);
    }
}

test "M11: bold wraps app, flag and argument names" {
    const h = try renderWithHighlight(.{ .bold = {} }, &M9.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1mUsage: \x1b[0m\x1b[1mapp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m--help\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1mServer settings\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m<path>\x1b[0m") != null);
}

test "M11: usage brackets stay inside their highlight blocks" {
    const bold = try renderWithHighlight(.{ .bold = {} }, &M9.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(bold);
    // The optional-flag and `[flags]` tokens carry the brackets inside the
    // `.usage.optionals` block.
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[3m[--dry-run]\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[3m[flags]\x1b[0m") != null);
    // The required flag's dashes and `=` ride inside the name token.
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[1m--host=\x1b[0m") != null);
    // Positional tokens carry their own `<...>` / `[<...>]` brackets.
    try std.testing.expect(std.mem.indexOf(u8, bold, "\x1b[1m<path>\x1b[0m") != null);

    const color = try renderWithHighlight(.{ .color = {} }, &M9.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(color);
    try std.testing.expect(std.mem.indexOf(u8, color, "\x1b[3;36m[--dry-run]\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, color, "\x1b[36m<path>\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, color, "\x1b[1;96m--host=\x1b[0m") != null);
}

test "M11: flag list highlights dashes and assign sign with the name" {
    const h = try renderWithHighlight(.{ .bold = {} }, &M9.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    // Each flag name token carries its own dashes and, for value flags, the
    // `=` sign; only the `, ` separator stays uncolored.
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m-h\x1b[0m, \x1b[1m--help\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m-P\x1b[0m, \x1b[1m--port=\x1b[0m\x1b[1m8080\x1b[0m") != null);
}

test "M11: color uses the per-category codes" {
    const h = try renderWithHighlight(.{ .color = {} }, &M9.default_locale, std.testing.allocator);
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
    const h = try renderWithHighlight(.{ .custom = custom }, &M9.default_locale, std.testing.allocator);
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
    try std.testing.expectEqualStrings("opt1", @typeInfo(M12Alt.branch_types[0]).@"struct".field_names[0]);
    try std.testing.expectEqualStrings("opt2", @typeInfo(M12Alt.branch_types[1]).@"struct".field_names[0]);
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
    const fields = fieldsOf(M12View);
    const last = fields[fields.len - 1];
    try std.testing.expectEqualStrings("mode", last.name);
    const MaybeUnion = last.type;
    try std.testing.expect(@typeInfo(MaybeUnion) == .optional);
    const UU = @typeInfo(MaybeUnion).optional.child;
    try std.testing.expect(@typeInfo(UU) == .@"union");
    var seen1 = false;
    var seen2 = false;
    inline for (@typeInfo(UU).@"union".field_names) |uf| {
        if (std.mem.eql(u8, uf, "alt1")) seen1 = true;
        if (std.mem.eql(u8, uf, "fancy-alt2")) seen2 = true;
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

test "M12: an Alt branch tag may equal a Group name and shares its help section" {
    const C = generate(App{ .name = "grouped", .help = "" }, .{
        .g = Group(.{ .p = Flag(u8){} }, "alt1"),
        .mode = Alt(.{ .alt1 = .{ .q = Flag(u8){} } }),
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const help = try C.helpText(a);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, help, "alt1"));
    try std.testing.expect(std.mem.indexOf(u8, help, "--p") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--q") != null);
}

test "M12: duplicate group names merge into one help section" {
    const C = generate(App{ .name = "grouped", .help = "" }, .{
        .one = Group(.{ .a = Flag(u8){} }, "shared"),
        .two = Group(.{ .b = Flag(u8){} }, "shared"),
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const help = try C.helpText(a);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, help, "shared"));
    try std.testing.expect(std.mem.indexOf(u8, help, "--a") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--b") != null);
}

test "M12: two Alt fields sharing a branch tag share one help section" {
    const C = generate(App{ .name = "tagged", .help = "" }, .{
        .one = Alt(.{ .fast = .{ .a = Flag(u8){} } }),
        .two = Alt(.{ .fast = .{ .b = Flag(u8){} } }),
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const help = try C.helpText(a);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, help, "fast"));
    try std.testing.expect(std.mem.indexOf(u8, help, "--a") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--b") != null);
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
    const fields = fieldsOf(C.View);
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
    const fields = fieldsOf(M13View);
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
    const ctx = try contextHelpText(M14, arena.allocator(), &vroot, &M14.default_locale);
    const root = try M14.helpText(arena.allocator());
    try std.testing.expectEqualStrings(root, ctx);
}

test "M14: a parse failure keeps the deepest entered command scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `svc --nope` fails in the `svc` level: the partial View links the sub
    // scope, so the failure page is the `svc` page, not the root one.
    var diag: Diag = .{};
    var mid: M14.View = undefined;
    try std.testing.expectError(
        error.UnknownFlag,
        M14.parseInnerHelp(arena.allocator(), std.process.Environ.empty, &M14.default_locale, &.{ "svc", "--nope" }, &diag, false, null, &mid),
    );
    try std.testing.expect(mid._svc != null);
    try std.testing.expect(mid._svc.?._build == null);
    try std.testing.expectEqualStrings(
        M14SvcGolden,
        try contextHelpText(M14, arena.allocator(), &mid, &M14.default_locale),
    );

    // `svc build` fails one level deeper (missing <target>): the chain must
    // reach `build` so the failure page names `m14 svc build`.
    var deep_diag: Diag = .{};
    var deep: M14.View = undefined;
    try std.testing.expectError(
        error.MissingRequired,
        M14.parseInnerHelp(arena.allocator(), std.process.Environ.empty, &M14.default_locale, &.{ "svc", "build" }, &deep_diag, false, null, &deep),
    );
    try std.testing.expect(deep._svc != null);
    try std.testing.expect(deep._svc.?._build != null);
    try std.testing.expectEqualStrings("target", deep_diag.field.?);
    try std.testing.expectEqualStrings(
        M14BuildGolden,
        try contextHelpText(M14, arena.allocator(), &deep, &M14.default_locale),
    );

    // The compact failure view leads with the diagnostics.
    const merged = try contextHelpData(M14, arena.allocator(), &deep);
    try std.testing.expectEqualStrings(M14BuildGolden, try merged.renderCompact(&M14.default_locale, arena.allocator()));
    var data = merged;
    data.error_text = "error: field 'target' is invalid or missing";
    const with_error = try data.renderCompact(&M14.default_locale, arena.allocator());
    try std.testing.expectEqualStrings(
        "error: field 'target' is invalid or missing\n" ++ M14BuildGolden,
        with_error,
    );
}

test "M14: a root-level parse failure keeps the root page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // No command token was entered, so the partial View carries no active
    // sub scope and the failure page is the unchanged root page.
    var partial: M14.View = undefined;
    try std.testing.expectError(
        error.MissingRequired,
        M14.parseInnerHelp(arena.allocator(), std.process.Environ.empty, &M14.default_locale, &.{}, &diag, false, null, &partial),
    );
    try std.testing.expect(partial._svc == null);
    try std.testing.expect(partial._one == null);
    try std.testing.expectEqualStrings(
        try M14.helpText(arena.allocator()),
        try contextHelpText(M14, arena.allocator(), &partial, &M14.default_locale),
    );
}

test "M14: usage header reconstructs the command path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const v = try m14Parse(&arena, &.{ "svc", "-h" }, &diag);
    const h = try contextHelpText(M14, arena.allocator(), &v, &M14.default_locale);
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
    const h = try contextHelpText(M14, arena.allocator(), &v, &M14.default_locale);
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
    const hbuild = try contextHelpText(M14, arena.allocator(), &vbuild, &M14.default_locale);
    try std.testing.expectEqualStrings(M14BuildGolden, hbuild);

    // The `svc` scope lists `build` but neither sibling `one` nor `two`.
    const vsvc = try m14Parse(&arena, &.{ "svc", "-h" }, &diag);
    const hsvc = try contextHelpText(M14, arena.allocator(), &vsvc, &M14.default_locale);
    try std.testing.expect(std.mem.indexOf(u8, hsvc, "  build    ") != null);
    try std.testing.expect(std.mem.indexOf(u8, hsvc, "  one    ") == null);
    try std.testing.expect(std.mem.indexOf(u8, hsvc, "  two    ") == null);
}

test "M14: info shows the deepest command help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const v = try m14Parse(&arena, &.{ "svc", "build", "-h" }, &diag);
    const h = try contextHelpText(M14, arena.allocator(), &v, &M14.default_locale);
    try std.testing.expect(std.mem.indexOf(u8, h, "Build.") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "M14 root.") == null);
    try std.testing.expect(std.mem.indexOf(u8, h, "Service command.") == null);
}

test "M14: help token before the commands scopes to the deepest active command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const v = try m14Parse(&arena, &.{ "-h", "svc", "build" }, &diag);
    const h = try contextHelpText(M14, arena.allocator(), &v, &M14.default_locale);
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
        const text = try contextHelpText(M14, probe.allocator(), &v, &M14.default_locale);
        probe.allocator().free(text);
        break :blk probe.allocations;
    };

    var fi: usize = 0;
    while (fi <= total) : (fi += 1) {
        var fa = FailingAllocator.init(std.testing.allocator, .{ .fail_index = fi });
        if (contextHelpText(M14, fa.allocator(), &v, &M14.default_locale)) |text| {
            fa.allocator().free(text);
        } else |e| {
            try std.testing.expectEqual(std.mem.Allocator.Error.OutOfMemory, e);
        }
        try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    }
}

test "M14: generated namespace exposes usage" {
    // The rendering is asserted through `contextHelpText` (what `usage`
    // prints); here only the declaration and its generic shape are checked.
    try std.testing.expect(@hasDecl(M14, "usage"));
    comptime {
        if (@TypeOf(M14.usage) != fn (anytype) HelpError!void)
            @compileError("M14: usage must accept a View of any level");
    }
}

test "M14: usage of a sub-view merges the same scopes as the root view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const vbuild = try m14Parse(&arena, &.{ "--config", "c", "--host", "h", "svc", "--token", "t", "build", "x" }, &diag);
    const build = vbuild._svc.?._build.?;
    const from_sub = try contextHelpText(M14, arena.allocator(), &build, &M14.default_locale);
    const from_root = try contextHelpText(M14, arena.allocator(), &vbuild, &M14.default_locale);
    try std.testing.expectEqualStrings(M14BuildGolden, from_sub);
    try std.testing.expectEqualStrings(from_root, from_sub);

    // A mid-level sub-view stops at its own level's scope.
    const vsvc = try m14Parse(&arena, &.{ "--config", "c", "--host", "h", "svc", "--token", "t" }, &diag);
    const svc = vsvc._svc.?;
    const mid = try contextHelpText(M14, arena.allocator(), &svc, &M14.default_locale);
    try std.testing.expectEqualStrings(M14SvcGolden, mid);
}

test "M14: usage of a commandless view keeps its own scope" {
    const C = generate(App{ .name = "leaf", .help = "Leaf." }, .{
        .path = Argument([]const u8){ .help = "Path." },
    });
    comptime {
        if (@TypeOf(C.usage) != fn (anytype) HelpError!void)
            @compileError("M14: usage must be generic on a commandless level");
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try C.parseInner(arena.allocator(), std.process.Environ.empty, &.{"p"}, &diag);
    const ctx = try contextHelpText(C, arena.allocator(), &v, &C.default_locale);
    const plain = try C.helpText(arena.allocator());
    try std.testing.expectEqualStrings(plain, ctx);
}

test "M14: usage on a foreign view is a compile error" {
    if (false) {
        // Enabling this must fail to compile: 'dap.usage: argument is not a
        // command View of 'm14''. Unlike `command`, a leaf view of this tree
        // is accepted: it has its own scope even with no subcommands.
        const Other = generate(App{ .name = "other", .help = "" }, .{});
        const other: Other.View = undefined;
        _ = M14.usage(other);
    }
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
    // `@hasDecl` only sees `pub` declarations, and the inner parse entry
    // points stay file-private; reference them to prove they are forwarded.
    comptime {
        _ = M7.parseInner;
        _ = M7.parseInnerHelp;
    }
    try std.testing.expect(@hasDecl(M7, "helpData"));
    try std.testing.expect(@hasDecl(M7, "helpText"));

    try std.testing.expect(@hasDecl(M13, "parse"));
    try std.testing.expect(!@hasDecl(M13, "command"));
    try std.testing.expect(!@hasDecl(M13, "CommandPayload"));
}

// ---------------------------------------------------------------------------
// M16: typo suggestions for unknown tokens.
// ---------------------------------------------------------------------------

test "M16: threshold table is graduated" {
    // Empty never suggests.
    try std.testing.expectEqual(@as(usize, 0), suggestMaxDistance(0, 0));
    // Short words allow no edit at all.
    try std.testing.expectEqual(@as(usize, 0), suggestMaxDistance(1, 1));
    // The budget follows the longer side.
    try std.testing.expectEqual(@as(usize, 2), suggestMaxDistance(2, 10));
    // Medium words get a fixed budget.
    try std.testing.expectEqual(@as(usize, 1), suggestMaxDistance(3, 5));
    try std.testing.expectEqual(@as(usize, 1), suggestMaxDistance(5, 5));
    try std.testing.expectEqual(@as(usize, 2), suggestMaxDistance(6, 8));
    try std.testing.expectEqual(@as(usize, 2), suggestMaxDistance(10, 10));
    // Beyond that it is a quarter of the longer side, rounded up.
    try std.testing.expectEqual(@as(usize, 3), suggestMaxDistance(11, 11));
    try std.testing.expectEqual(@as(usize, 5), suggestMaxDistance(20, 20));
    try std.testing.expectEqual(@as(usize, 5), suggestMaxDistance(17, 20));
}

const M16Def = .{
    .dry_run = Flag(bool){
        .long = "dry_run",
        .default = Default(bool){ .direct = false },
    },
    .verbose = Flag(bool){
        .short = "v",
        .long = "verbose",
        .default = Default(bool){ .direct = false },
    },
    .deploy = Command(.{ .help = "Deploy." }, .{}),
    .deployment = Command(.{ .help = "Deployment." }, .{}),
};

const M16 = generate(App{ .name = "m16", .help = "m16" }, M16Def);
const M16View = M16.View;

fn m16Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M16View {
    return M16.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

test "M16: unknown long flag suggests near miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"--dry-runn"}, &diag));
    try std.testing.expectEqualStrings("--dry-runn", diag.token.?);
    switch (diag.unknown.?) {
        .flag => |s| {
            try std.testing.expectEqualStrings("dry_run", s.name);
            try std.testing.expectEqual(SuggestValid.Kind.flag, s.kind);
            try std.testing.expectEqual(SuggestValid.Reason.edit, s.reason);
            try std.testing.expectEqual(@as(usize, 2), s.distance);
        },
        .cmd => return error.TestUnexpectedResult,
    }
}

test "M16: unknown long flag carries its attached value into the probe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"--dry-runn=3"}, &diag));
    switch (diag.unknown.?) {
        .flag => |s| try std.testing.expectEqualStrings("dry_run", s.name),
        .cmd => return error.TestUnexpectedResult,
    }
}

test "M16: no suggestion for unrelated token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"--zzz"}, &diag));
    try std.testing.expectEqualStrings("--zzz", diag.token.?);
    try std.testing.expect(diag.unknown == null);
}

test "M16: no absurd suggestion for a one-letter short" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"-z"}, &diag));
    try std.testing.expect(diag.unknown == null);
}

test "M16: dashed short name suggests the short spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    // `--v` exact-matches the short `v` of `verbose`; the hint reverts to `-v`.
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"--v"}, &diag));
    switch (diag.unknown.?) {
        .flag => |s| {
            try std.testing.expectEqualStrings("verbose", s.name);
            try std.testing.expectEqualStrings("v", s.short.?);
        },
        .cmd => return error.TestUnexpectedResult,
    }
}

test "M16: builtin help flag is a real suggestion target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"--halp"}, &diag));
    switch (diag.unknown.?) {
        .flag => |s| try std.testing.expectEqualStrings("help", s.name),
        .cmd => return error.TestUnexpectedResult,
    }
}

test "M16: unique prefix completes with the prefix reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"--dry"}, &diag));
    switch (diag.unknown.?) {
        .flag => |s| {
            try std.testing.expectEqualStrings("dry_run", s.name);
            try std.testing.expectEqual(SuggestValid.Reason.prefix, s.reason);
        },
        .cmd => return error.TestUnexpectedResult,
    }
}

test "M16: unknown command suggests near miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.TooManyArguments, m16Parse(&arena, &.{"deploi"}, &diag));
    try std.testing.expectEqualStrings("deploi", diag.token.?);
    switch (diag.unknown.?) {
        .cmd => |s| {
            try std.testing.expectEqualStrings("deploy", s.name);
            try std.testing.expectEqual(SuggestValid.Kind.cmd, s.kind);
        },
        .flag => return error.TestUnexpectedResult,
    }
}

test "M16: ambiguous prefix yields no prefix hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    // `dep` prefixes both `deploy` and `deployment`; no unambiguous completion.
    try std.testing.expectError(error.TooManyArguments, m16Parse(&arena, &.{"dep"}, &diag));
    try std.testing.expect(diag.unknown == null);
}

test "M16: dashed token falls back to a command suggestion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    // `deploy` is a command; typing it dashed is a namespace slip.
    try std.testing.expectError(error.UnknownFlag, m16Parse(&arena, &.{"--deploy"}, &diag));
    switch (diag.unknown.?) {
        .cmd => |s| try std.testing.expectEqualStrings("deploy", s.name),
        .flag => return error.TestUnexpectedResult,
    }
}

test "M16: tokens after the terminator never suggest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.TooManyArguments, m16Parse(&arena, &.{ "--", "deploy" }, &diag));
    try std.testing.expectEqualStrings("deploy", diag.token.?);
    try std.testing.expect(diag.unknown == null);
}

test "M16: suggestion stays null without a diag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownFlag, M16.parseInner(arena.allocator(), std.process.Environ.empty, &.{"--dry-runn"}, null));
}

test "M16: M4 unknown-token diagnostics still carry token only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownFlag, m4Parse(&arena, &.{ "--nope", "f" }, &diag));
    try std.testing.expectEqualStrings("--nope", diag.token.?);
    // `nope` is far from every M4 long; no hint, preserving the old message.
    try std.testing.expect(diag.unknown == null);
}

test "M16: renderCompact leads with the error line" {
    var data = try M16.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    data.error_text = "error: token '--dry-runn' is invalid";
    const h = try data.renderCompact(&M16.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    // M16 uses the default (bold) scheme, whose error token is empty, so the
    // line is plain text sitting above the usage header.
    try std.testing.expect(std.mem.startsWith(u8, h, "error: token '--dry-runn' is invalid\n"));
}

test "M16: error line carries the error_msg highlight code" {
    const CLI = generate(App{
        .name = "app",
        .help = "Do things.",
        .help_renderer = .{ .highlight = .color },
    }, M16Def);
    var data = try CLI.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    data.error_text = "error: token '--dry-runn' is invalid";
    const h = try data.renderCompact(&M16.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "\x1b[1;91merror: token '--dry-runn' is invalid\x1b[0m\n\x1b[1;92mUsage: "));
}

test "M16: absent error line leaves the compact view unchanged" {
    var data = try M16.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const h = try data.renderCompact(&M16.default_locale, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "error:") == null);
}

// ---------------------------------------------------------------------------
// M17: View deinit.
// ---------------------------------------------------------------------------

/// A custom value type that allocates inside `decode` (an owned `u16` slice),
/// the reference shape for the three-method contract.
const M17Custom = struct {
    const Self = @This();

    nums: []const u16,

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!Self {
        var list: std.ArrayList(u16) = .empty;
        errdefer list.deinit(allocator);

        var it = std.mem.tokenizeScalar(u8, data, ',');
        while (it.next()) |raw| {
            const n = std.fmt.parseInt(u16, std.mem.trim(u8, raw, " \t"), 10) catch return error.InvalidWire;
            try list.append(allocator, n);
        }
        return .{ .nums = try list.toOwnedSlice(allocator) };
    }

    pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.nums, 0..) |n, i| {
            if (i != 0) try out.append(allocator, ',');
            try out.print(allocator, "{}", .{n});
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.nums);
    }
};

const M17ScalarDef = .{
    .loud = Flag(bool){ .short = "l", .help = "Loud." },
    .count = Flag(u16){ .default = Default(u16){ .direct = 1 }, .help = "Count." },
    .ratio = Flag(f64){ .default = Default(f64){ .direct = 0.5 }, .help = "Ratio." },
};

const M17StringDef = .{
    .user = Flag([]const u8){ .short = "u", .help = "User." },
    .host = Flag([]const u8){ .default = Default([]const u8){ .direct = "localhost" }, .help = "Host." },
    .env_user = Flag([]const u8){ .default = Default([]const u8){ .env = "DAP_M17_USER" }, .help = "Env user." },
    .opt = Optional(Flag([]const u8){ .help = "Optional." }),
};

const M17CustomDef = .{
    .nums = Flag(M17Custom){
        .long = "nums",
        .default = Default(M17Custom){ .direct = M17Custom{ .nums = &.{} } },
        .help = "Numbers.",
    },
};

const M17AltDef = .{
    .source = Alt(.{
        .file = .{
            .file = Flag([]const u8){ .short = "s", .help = "Source file." },
        },
        .net = VariantNamed("net", .{
            .url = Flag([]const u8){ .help = "Source URL." },
        }),
    }),
};

const M17CmdDef = .{
    .config = Flag([]const u8){ .default = Default([]const u8){ .direct = "/etc/x" }, .help = "Config." },
    .svc = Command(.{ .help = "Service." }, .{
        .out = Flag([]const u8){ .default = Default([]const u8){ .direct = "out" }, .help = "Out." },
        .build = Command(.{ .help = "Build." }, .{
            .target = Argument([]const u8){ .help = "Target." },
        }),
    }),
};

const M17Scalar = generate(App{ .name = "m17-scalar", .help = "M17 scalar" }, M17ScalarDef);
const M17String = generate(App{ .name = "m17-string", .help = "M17 string" }, M17StringDef);
const M17CustomCli = generate(App{ .name = "m17-custom", .help = "M17 custom" }, M17CustomDef);
const M17Alt = generate(App{ .name = "m17-alt", .help = "M17 alt" }, M17AltDef);
const M17Cmd = generate(App{ .name = "m17-cmd", .help = "M17 cmd" }, M17CmdDef);

// Negative check (verified by uncommenting): a struct with only decode and
// encode is not a valid value type now that deinit is mandatory.
// const M17NoDeinit = struct {
//     value: u8 = 0,
//     pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!@This() {
//         _ = allocator; _ = data; return .{};
//     }
//     pub fn encode(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
//         _ = self; return try allocator.dupe(u8, "");
//     }
// };
// const M17Bad = generate(App{ .name = "bad", .help = "bad" }, .{
//     .x = Flag(M17NoDeinit){},
// });

test "M17: enumeration no-op deinit" {
    var m: Mode = .{};
    m.deinit(std.testing.allocator);

    const Empty = Enumeration(.{});
    var e: Empty = .{};
    e.deinit(std.testing.allocator);
}

test "M17: scalar view deinit frees nothing" {
    var diag: Diag = .{};
    var v = try M17Scalar.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "-l", "--count", "3" }, &diag);
    M17Scalar.deinit(&v, std.testing.allocator);
    try std.testing.expect(v.loud);
}

test "M17: wire string is owned and released" {
    var diag: Diag = .{};
    var v = try M17String.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "-u", "alice" }, &diag);
    try std.testing.expectEqualStrings("alice", v.user);
    M17String.deinit(&v, std.testing.allocator);
}

test "M17: direct-default string is owned and released" {
    var diag: Diag = .{};
    var v = try M17String.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "-u", "alice" }, &diag);
    try std.testing.expectEqualStrings("localhost", v.host);
    M17String.deinit(&v, std.testing.allocator);
}

test "M17: env string is owned and released" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const envp = &[_][*:0]const u8{"DAP_M17_USER=envbob"};
    var diag: Diag = .{};
    var v = try M17String.parseInner(std.testing.allocator, makeEnviron(envp), &.{ "-u", "alice" }, &diag);
    try std.testing.expectEqualStrings("envbob", v.env_user);
    M17String.deinit(&v, std.testing.allocator);
}

test "M17: optional strings present and absent both release" {
    var diag: Diag = .{};
    var present = try M17String.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "-u", "a", "--opt", "x" }, &diag);
    try std.testing.expectEqualStrings("x", present.opt.?);
    M17String.deinit(&present, std.testing.allocator);

    var absent = try M17String.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "-u", "a" }, &diag);
    try std.testing.expect(absent.opt == null);
    M17String.deinit(&absent, std.testing.allocator);
}

test "M17: custom type wire value is owned and released" {
    var diag: Diag = .{};
    var v = try M17CustomCli.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "--nums", "1,2,3" }, &diag);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, v.nums.nums);
    M17CustomCli.deinit(&v, std.testing.allocator);
}

test "M17: custom direct default roundtrips into owned memory" {
    var diag: Diag = .{};
    var v = try M17CustomCli.parseInner(std.testing.allocator, std.process.Environ.empty, &.{}, &diag);
    try std.testing.expectEqual(@as(usize, 0), v.nums.nums.len);
    M17CustomCli.deinit(&v, std.testing.allocator);
}

test "M17: Alt active branch released and null union released" {
    var diag: Diag = .{};
    var active = try M17Alt.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "-s", "a.zig" }, &diag);
    switch (active.source.?) {
        .file => |p| try std.testing.expectEqualStrings("a.zig", p.file),
        else => return error.TestUnexpectedResult,
    }
    M17Alt.deinit(&active, std.testing.allocator);

    var none = try M17Alt.parseInner(std.testing.allocator, std.process.Environ.empty, &.{}, &diag);
    try std.testing.expect(none.source == null);
    M17Alt.deinit(&none, std.testing.allocator);
}

test "M17: nested command deinit recurses" {
    var diag: Diag = .{};
    var v = try M17Cmd.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "svc", "build", "hello" }, &diag);
    try std.testing.expectEqualStrings("/etc/x", v.config);
    try std.testing.expectEqualStrings("hello", v._svc.?._build.?.target);
    M17Cmd.deinit(&v, std.testing.allocator);
}

// ---------------------------------------------------------------------------
// M18: switch-shaped dispatch at every level of the command tree.
// ---------------------------------------------------------------------------

const M18Def = .{
    .body = Command(.{ .help = "Body." }, .{
        .left = Command(.{ .help = "Left." }, .{
            .x = Flag(u8){ .long = "x" },
        }),
        .right = Command(.{ .help = "Right." }, .{
            .y = Argument([]const u8){},
        }),
    }),
};
const M18 = generate(App{ .name = "m18", .help = "m18" }, M18Def);

const M18DeepDef = .{
    .body = Command(.{ .help = "Body." }, .{
        .left = Command(.{ .help = "Left." }, .{
            .go = Command(.{ .help = "Go." }, .{
                .n = Argument(u8){},
            }),
        }),
    }),
};
const M18Deep = generate(App{ .name = "m18-deep", .help = "m18 deep" }, M18DeepDef);

test "M18: dispatch through two levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try M18.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "body", "left", "--x", "3" }, &diag);
    switch (M18.command(v) orelse return error.TestUnexpectedResult) {
        .body => |b| switch (M18.command(b) orelse return error.TestUnexpectedResult) {
            .left => |l| try std.testing.expectEqual(@as(u8, 3), l.x),
            .right => return error.TestUnexpectedResult,
        },
    }
}

test "M18: intermediate view with no active child dispatches to null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try M18.parseInner(arena.allocator(), std.process.Environ.empty, &.{"body"}, &diag);
    const b = switch (M18.command(v).?) {
        .body => |body| body,
    };
    try std.testing.expect(M18.command(b) == null);
}

test "M18: three levels dispatch through each accessor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try M18Deep.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "body", "left", "go", "7" }, &diag);
    const b = switch (M18Deep.command(v).?) {
        .body => |body| body,
    };
    const l = switch (M18Deep.command(b).?) {
        .left => |left| left,
    };
    switch (M18Deep.command(l).?) {
        .go => |g| try std.testing.expectEqual(@as(u8, 7), g.n),
    }
}

test "M18: a mid-level view dispatches from the root accessor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const a = try m7Parse(&arena, &.{ "--needed", "v", "nested", "deep", "5" }, &diag);
    switch (M7.command(a._nested.?).?) {
        .deep => |d| try std.testing.expectEqual(@as(u8, 5), d.n),
    }
}

test "M18: root flags after a deep handoff still land on the root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const v = try m7Parse(&arena, &.{ "--needed", "v", "nested", "--verbose", "deep", "5" }, &diag);
    try std.testing.expect(v.verbose);
    const n = switch (M7.command(v).?) {
        .nested => |nested| nested,
        else => return error.TestUnexpectedResult,
    };
    switch (M7.command(n).?) {
        .deep => |d| try std.testing.expectEqual(@as(u8, 5), d.n),
    }
}

test "M18: dispatch does not disturb deinit" {
    var diag: Diag = .{};
    var v = try M18.parseInner(std.testing.allocator, std.process.Environ.empty, &.{ "body", "right", "hello" }, &diag);
    const b = switch (M18.command(v).?) {
        .body => |body| body,
    };
    switch (M18.command(b).?) {
        .right => |r| try std.testing.expectEqualStrings("hello", r.y),
        .left => return error.TestUnexpectedResult,
    }
    M18.deinit(&v, std.testing.allocator);
}

test "M18: registry covers the tree in declaration pre-order" {
    comptime {
        const nodes = commandNodes(M18);
        if (nodes.len != 4) @compileError("M18: unexpected node count");
        const want = [_]String{ "m18", "m18 body", "m18 body left", "m18 body right" };
        for (nodes, want) |n, name| {
            if (!std.mem.eql(u8, n.app_meta.name, name))
                @compileError("M18: unexpected node path '" ++ n.app_meta.name ++ "'");
        }
    }
}

test "M18: dispatch into a leaf is a compile error" {
    if (false) {
        // enabling this must fail to compile: 'a leaf View of 'm18 body left'
        // declares no subcommands'
        // var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        // defer arena.deinit();
        // var diag: Diag = .{};
        // const v = try M18.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "body", "left", "--x", "3" }, &diag);
        // _ = M18.command(v._body.?._left.?);
    }
}

test "M18: dispatch on a non-view is a compile error" {
    if (false) {
        // enabling this must fail to compile: 'argument is not a command View
        // of 'm18''
        // _ = M18.command(0);
    }
}

// Flagless leaves and symmetrically shaped subtrees are the layouts that used
// to intern to one `View` type: the rank-named tag field must keep every
// level distinct while dispatch stays exact.

const M18SharedDef = .{
    .run = Command(.{ .help = "Run." }, .{}),
    .config = Command(.{ .help = "Config." }, .{
        .show_dev = Command(.{ .name = "show-dev", .help = "Show dev." }, .{}),
        .validate = Command(.{ .help = "Validate." }, .{
            .path = Argument([]const u8){},
        }),
    }),
    .version = Command(.{ .help = "Version." }, .{}),
};
const M18Shared = generate(App{ .name = "m18-shared", .help = "m18 shared" }, M18SharedDef);

test "M18: flagless leaf commands dispatch independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const c = try M18Shared.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "config", "show-dev" }, &diag);
    const cfg = switch (M18Shared.command(c) orelse return error.TestUnexpectedResult) {
        .config => |x| x,
        else => return error.TestUnexpectedResult,
    };
    switch (M18Shared.command(cfg) orelse return error.TestUnexpectedResult) {
        .show_dev => {},
        else => return error.TestUnexpectedResult,
    }

    const r = try M18Shared.parseInner(arena.allocator(), std.process.Environ.empty, &.{"run"}, &diag);
    switch (M18Shared.command(r) orelse return error.TestUnexpectedResult) {
        .run => {},
        else => return error.TestUnexpectedResult,
    }

    const vv = try M18Shared.parseInner(arena.allocator(), std.process.Environ.empty, &.{"version"}, &diag);
    switch (M18Shared.command(vv) orelse return error.TestUnexpectedResult) {
        .version => {},
        else => return error.TestUnexpectedResult,
    }
}

test "M18: every command level has a distinct View type" {
    comptime {
        const nodes = commandNodes(M18Shared);
        if (nodes.len != 6) @compileError("M18: unexpected node count");
        const want = [_]String{
            "m18-shared",
            "m18-shared run",
            "m18-shared config",
            "m18-shared config show-dev",
            "m18-shared config validate",
            "m18-shared version",
        };
        for (nodes, 0..) |n, i| {
            if (!std.mem.eql(u8, n.app_meta.name, want[i]))
                @compileError("M18: unexpected node path '" ++ n.app_meta.name ++ "'");
            // The registry is pre-order, so a level's rank is its index.
            const tag = std.fmt.comptimePrint("__command{}", .{i});
            if (!@hasField(n.View, tag))
                @compileError("M18: level '" ++ n.app_meta.name ++ "' lacks tag '" ++ tag ++ "'");
            for (nodes[0..i]) |prev| {
                if (prev.View == n.View)
                    @compileError("M18: levels '" ++ prev.app_meta.name ++ "' and '" ++
                        n.app_meta.name ++ "' share a View type");
            }
        }
    }
}

const M18TwinDef = .{
    .a = Command(.{ .help = "A." }, .{
        .go = Command(.{ .name = "a-go", .help = "A go." }, .{ .n = Argument(u8){} }),
    }),
    .b = Command(.{ .help = "B." }, .{
        .go = Command(.{ .name = "b-go", .help = "B go." }, .{ .n = Argument(u8){} }),
    }),
};
const M18Twin = generate(App{ .name = "m18-twin", .help = "m18 twin" }, M18TwinDef);

test "M18: twin subtrees keep distinct View types and dispatch independently" {
    comptime {
        const nodes = commandNodes(M18Twin);
        if (nodes.len != 5) @compileError("M18: unexpected node count");
        for (nodes, 0..) |n, i| {
            for (nodes[0..i]) |prev| {
                if (prev.View == n.View)
                    @compileError("M18: levels '" ++ prev.app_meta.name ++ "' and '" ++
                        n.app_meta.name ++ "' share a View type");
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try M18Twin.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "a", "a-go", "3" }, &diag);
    const av = switch (M18Twin.command(a) orelse return error.TestUnexpectedResult) {
        .a => |x| x,
        else => return error.TestUnexpectedResult,
    };
    switch (M18Twin.command(av) orelse return error.TestUnexpectedResult) {
        .go => |g| try std.testing.expectEqual(@as(u8, 3), g.n),
    }

    const b = try M18Twin.parseInner(arena.allocator(), std.process.Environ.empty, &.{ "b", "b-go", "9" }, &diag);
    const bv = switch (M18Twin.command(b) orelse return error.TestUnexpectedResult) {
        .b => |x| x,
        else => return error.TestUnexpectedResult,
    };
    switch (M18Twin.command(bv) orelse return error.TestUnexpectedResult) {
        .go => |g| try std.testing.expectEqual(@as(u8, 9), g.n),
    }
}

const DefaultLocaleDef = .{
    .verbose = Flag(bool){ .help = "Verbose output.", .i18n = "flag_verbose" },
    .config = Flag(String){ .help = "Config file.", .i18n = "flag_config" },
    .serve = Command(.{ .help = "Serve requests.", .i18n = "cmd_serve" }, .{
        .port = Flag(u16){ .help = "Listen port.", .i18n = "cmd_serve_port" },
    }),
};
const DefaultLocale = generate(App{ .name = "default-locale", .help = "Default locale app.", .i18n = "app_help" }, DefaultLocaleDef);

const DefaultLocaleKeys = [_]String{
    "app_help",
    "flag_verbose",
    "flag_config",
    "cmd_serve",
    "cmd_serve_port",
    "builtin_help",
};

fn defaultLocaleKeyPresent(comptime keys: []const String, key: String) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

test "i18n: default locale carries every keyed literal plus builtin help" {
    const loc = DefaultLocale.default_locale;
    try std.testing.expectEqualStrings("Default locale app.", try loc.require("app_help"));
    try std.testing.expectEqualStrings("Verbose output.", try loc.require("flag_verbose"));
    try std.testing.expectEqualStrings("Config file.", try loc.require("flag_config"));
    try std.testing.expectEqualStrings("Serve requests.", try loc.require("cmd_serve"));
    try std.testing.expectEqualStrings("Listen port.", try loc.require("cmd_serve_port"));

    try std.testing.expect(loc.has("builtin_help"));
    try std.testing.expectEqualStrings(BuiltinHelp.help, try loc.require("builtin_help"));

    try std.testing.expect(!loc.has("builtin_bash_shell"));
    try std.testing.expect(!loc.has("builtin_zsh_shell"));
    try std.testing.expect(!loc.has("builtin_fish_shell"));
    try std.testing.expect(loc.get("unrelated") == null);
}

test "i18n: i18n_keys is every collected key plus builtin help and nothing else" {
    try std.testing.expectEqual(DefaultLocaleKeys.len, DefaultLocale.i18n_keys.len);
    for (DefaultLocaleKeys) |key| {
        try std.testing.expect(defaultLocaleKeyPresent(DefaultLocale.i18n_keys, key));
    }
    for (DefaultLocale.i18n_keys) |key| {
        try std.testing.expect(defaultLocaleKeyPresent(&DefaultLocaleKeys, key));
    }
}

test "i18n: builder selects the default locale under an empty environment" {
    const builder = DefaultLocale.i18n();
    const loc = builder.locale(std.process.Environ.empty);
    try std.testing.expectEqualStrings("Default locale app.", try loc.require("app_help"));
    try std.testing.expectEqualStrings("Listen port.", try loc.require("cmd_serve_port"));
}

test "i18n: a command-bearing root forwards the locale surface" {
    comptime {
        if (!@hasDecl(DefaultLocale, "default_locale")) @compileError("i18n: default_locale not forwarded");
        if (!@hasDecl(DefaultLocale, "i18n_keys")) @compileError("i18n: i18n_keys not forwarded");
        if (!@hasDecl(DefaultLocale, "i18n")) @compileError("i18n: i18n not forwarded");
    }
    try std.testing.expect(DefaultLocale.default_locale.has("builtin_help"));
    try std.testing.expect(DefaultLocale.i18n_keys.len != 0);
    const builder = DefaultLocale.i18n();
    _ = &builder;
}

// Compile-fail case: `i18n()` is root-only. Verified by uncommenting.
// test "i18n: calling i18n() on a subcommand namespace is a compile error" {
//     const Serve = Sub(DefaultLocale.commands[0].Cmd, subApp(DefaultLocale.app_meta, DefaultLocale.commands[0]));
//     _ = Serve.i18n();
// }

// ---------------------------------------------------------------------------
// M27: enumeration values and defaults in the compact renderer.
// ---------------------------------------------------------------------------

const M27Four = Enumeration(.{
    .red = Enum{},
    .green = Enum{},
    .blue = Enum{},
    .alpha = Enum{},
});

const M27Five = Enumeration(.{
    .json = Enum{},
    .yaml = Enum{},
    .toml = Enum{},
    .csv = Enum{},
    .xml = Enum{},
});

const M27Two = Enumeration(.{
    .json = Enum{},
    .yaml = Enum{},
});

const M27HelpBranches = Enumeration(.{
    .fast = Enum{ .help = .{ .text = "Fast mode." } },
    .slow = Enum{},
});

const M27Keyed = Enumeration(.{
    .fast = Enum{ .help = .{ .text = "Fast mode.", .i18n = "m27_fast" } },
    .slow = Enum{ .help = .{ .text = "Slow mode." } },
    .zzz = Enum{ .help = .{ .text = "Empty mode.", .i18n = "m27_empty" } },
});

const M27Flat = App{
    .name = "m27",
    .help = "",
    .help_renderer = .{ .highlight = .{ .flat = {} } },
};

const M27Inline = generate(M27Flat, .{
    .color = Flag(M27Four){ .help = "Pick a color." },
    .uncolored = Flag(M27Four){ .help = "" },
});

const M27ByCount = generate(M27Flat, .{
    .format = Flag(M27Five){ .help = "Output format." },
});

const M27ByHelp = generate(M27Flat, .{
    .mode = Flag(M27HelpBranches){ .help = "Mode." },
});

const M27KeyedCLI = generate(M27Flat, .{
    .mode = Flag(M27Keyed){ .help = "Mode." },
});

const M27BlockEmptyHelp = generate(M27Flat, .{
    .format = Flag(M27Five){ .help = "" },
});

const M27FlagDefault = generate(M27Flat, .{
    .format = Flag(M27Two){
        .default = Default(M27Two){ .direct = .{} },
        .help = "Output format.",
    },
});

const M27Highlight = generate(App{
    .name = "m27",
    .help = "",
    .help_renderer = .{ .highlight = .{ .custom = .{
        .flags = .{ .value = "<v>" },
        .reset = "</v>",
    } } },
}, .{
    .mode = Flag(M27HelpBranches){ .help = "Mode." },
    .target = Argument(M27Two){
        .default = Default(M27Two){ .direct = .{} },
        .help = "Target.",
    },
});

const M27Overflow = generate(M27Flat, .{
    .extended_color_format = Flag(M27Four){ .long = "extended-color-format", .help = "Color." },
    .extended_other_format = Flag(M27Four){ .long = "extended-other-format", .help = "" },
});

const M27AltCLI = generate(M27Flat, .{
    .transport = Alt(.{
        .tcp = .{ .tcp_color = Flag(M27Four){ .help = "TCP color." } },
        .udp = .{ .udp_color = Flag(M27Four){ .help = "UDP color." } },
    }),
});

const M27ArgInline = generate(M27Flat, .{
    .mode = Argument(M27Two){
        .default = Default(M27Two){ .direct = .{} },
        .help = "Output mode.",
    },
});

const M27ArgValuesOnly = generate(M27Flat, .{
    .mode = Argument(M27Two){ .help = "Output mode." },
});

const M27ArgBlock = generate(M27Flat, .{
    .mode = Argument(M27Five){
        .default = Default(M27Five){ .direct = .{} },
        .help = "Output mode.",
    },
});

const M27ArgBlockNoDefault = generate(M27Flat, .{
    .mode = Argument(M27Five){ .help = "Output mode." },
});

const M27ArgPlainDefault = generate(M27Flat, .{
    .target = Argument([]const u8){
        .default = Default([]const u8){ .direct = "out" },
        .help = "Target dir.",
    },
});

const M27ArgPlain = generate(M27Flat, .{
    .target = Argument([]const u8){ .help = "Target dir." },
});

const M27ArgEmptyHelp = generate(M27Flat, .{
    .mode = Argument(M27Two){
        .default = Default(M27Two){ .direct = .{} },
        .help = "",
    },
});

const M27ArgBoth = generate(M27Flat, .{
    .mode = Argument(M27Two){
        .default = Default(M27Two){ .direct = .{}, .env = "M27_MODE" },
        .help = "Output mode.",
    },
});

const M27ArgEnv = generate(M27Flat, .{
    .no_color = Flag(bool){ .default = Default(bool){ .env = "M27_NO_COLOR" }, .help = "No color." },
    .mode = Argument(M27Two){
        .default = Default(M27Two){ .env = "M27_MODE" },
        .help = "Output mode.",
    },
});

fn expectM27Help(comptime C: type, expected: []const u8) !void {
    const text = try C.helpText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn expectM27Compact(comptime C: type, locale: *const I18n.Locale, expected: []const u8) !void {
    var data = try C.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const text = try data.renderCompact(locale, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "M27: four help-less values render one inline clause" {
    const expected =
        \\Usage: m27 --color=COLOR --uncolored=UNCOLORED [flags]
        \\
        \\Flags:
        \\  -h, --help                   Show context-sensitive help.
        \\      --color=COLOR            Pick a color. Possible values: red, green, blue, alpha.
        \\      --uncolored=UNCOLORED    Possible values: red, green, blue, alpha.
        \\
    ;
    try expectM27Help(M27Inline, expected);

    // Declaration order, never alphabetical: `blue` precedes `alpha`.
    const text = try M27Inline.helpText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    const red = std.mem.indexOf(u8, text, "red").?;
    const green = std.mem.indexOf(u8, text, "green").?;
    const blue = std.mem.indexOf(u8, text, "blue").?;
    const alpha = std.mem.indexOf(u8, text, "alpha").?;
    try std.testing.expect(red < green);
    try std.testing.expect(green < blue);
    try std.testing.expect(blue < alpha);
}

test "M27: more than four values render the column block" {
    const expected =
        \\Usage: m27 --format=FORMAT [flags]
        \\
        \\Flags:
        \\  -h, --help             Show context-sensitive help.
        \\      --format=FORMAT    Output format.
        \\                           Possible values:
        \\                             json
        \\                             yaml
        \\                             toml
        \\                             csv
        \\                             xml
        \\
    ;
    try expectM27Help(M27ByCount, expected);
}

test "M27: a declared branch help selects the column block" {
    const expected =
        \\Usage: m27 --mode=MODE [flags]
        \\
        \\Flags:
        \\  -h, --help         Show context-sensitive help.
        \\      --mode=MODE    Mode.
        \\                       Possible values:
        \\                         fast  - Fast mode.
        \\                         slow
        \\
    ;
    try expectM27Help(M27ByHelp, expected);
}

test "M27: empty flag help leaves the row and blocks below it" {
    const expected =
        \\Usage: m27 --format=FORMAT [flags]
        \\
        \\Flags:
        \\  -h, --help             Show context-sensitive help.
        \\      --format=FORMAT
        \\                           Possible values:
        \\                             json
        \\                             yaml
        \\                             toml
        \\                             csv
        \\                             xml
        \\
    ;
    try expectM27Help(M27BlockEmptyHelp, expected);
}

test "M27: a flag default stays in the left column" {
    const expected =
        \\Usage: m27 [flags]
        \\
        \\Flags:
        \\  -h, --help           Show context-sensitive help.
        \\      --format=json    Output format. Possible values: json, yaml.
        \\
    ;
    try expectM27Help(M27FlagDefault, expected);
}

test "M27: an overflowing left column continues at the help column" {
    const expected =
        \\Usage: m27 --extended-color-format=EXTENDED-COLOR-FORMAT --extended-other-format=EXTENDED-OTHER-FORMAT [flags]
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\      --extended-color-format=EXTENDED-COLOR-FORMAT
        \\                Color. Possible values: red, green, blue, alpha.
        \\      --extended-other-format=EXTENDED-OTHER-FORMAT
        \\                Possible values: red, green, blue, alpha.
        \\
    ;
    try expectM27Help(M27Overflow, expected);
}

test "M27: Alt branch flags render their values in their tag sections" {
    const expected =
        \\Usage: m27 (--tcp_color=TCP_COLOR | --udp_color=UDP_COLOR) [flags]
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
        \\tcp
        \\  --tcp_color=TCP_COLOR    TCP color. Possible values: red, green, blue, alpha.
        \\
        \\udp
        \\  --udp_color=UDP_COLOR    UDP color. Possible values: red, green, blue, alpha.
        \\
    ;
    try expectM27Help(M27AltCLI, expected);
}

test "M27: branch help resolves through the locale" {
    const locale = M27KeyedCLI.default_locale.withUser(.{
        .m27_fast = "Translated fast.",
        .m27_empty = "",
    });
    const expected =
        \\Usage: m27 --mode=MODE [flags]
        \\
        \\Flags:
        \\  -h, --help         Show context-sensitive help.
        \\      --mode=MODE    Mode.
        \\                       Possible values:
        \\                         fast  - Translated fast.
        \\                         slow  - Slow mode.
        \\                         zzz
        \\
    ;
    // `fast` is keyed and translated; `slow` has no key and keeps its
    // literal; `zzz` is keyed but resolves to empty, so its line carries no
    // `- ` and no trailing spaces.
    try expectM27Compact(M27KeyedCLI, &locale, expected);
}

test "M27: a missing branch key is an unknown translation key" {
    var data = try M27KeyedCLI.helpData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    const locale = M27KeyedCLI.default_locale.withUser(.{ .m27_empty = "" });
    try std.testing.expectError(
        error.UnknownTranslationKey,
        data.renderCompact(&locale, std.testing.allocator),
    );
}

test "M27: the default locale carries branch keys" {
    const locale = M27KeyedCLI.default_locale;
    try std.testing.expectEqualStrings("Fast mode.", try locale.require("m27_fast"));
    try std.testing.expectEqualStrings("Empty mode.", try locale.require("m27_empty"));
    try std.testing.expect(defaultLocaleKeyPresent(M27KeyedCLI.i18n_keys, "m27_fast"));
    try std.testing.expect(defaultLocaleKeyPresent(M27KeyedCLI.i18n_keys, "m27_empty"));
}

test "M27: argument clauses follow the help on one line" {
    const inline_expected =
        \\Usage: m27 [<mode>] [flags]
        \\
        \\Arguments:
        \\  [<mode>]    Output mode. Default value: json. Possible values: json, yaml.
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    try expectM27Help(M27ArgInline, inline_expected);

    // An empty help text starts the first clause at the help column with no
    // leading space.
    const empty_expected =
        \\Usage: m27 [<mode>] [flags]
        \\
        \\Arguments:
        \\  [<mode>]    Default value: json. Possible values: json, yaml.
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    try expectM27Help(M27ArgEmptyHelp, empty_expected);
}

test "M27: argument value blocks carry the default on the first line" {
    const with_default =
        \\Usage: m27 [<mode>] [flags]
        \\
        \\Arguments:
        \\  [<mode>]    Output mode. Default value: json.
        \\                Possible values:
        \\                  json
        \\                  yaml
        \\                  toml
        \\                  csv
        \\                  xml
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    try expectM27Help(M27ArgBlock, with_default);

    const without_default =
        \\Usage: m27 <mode> [flags]
        \\
        \\Arguments:
        \\  <mode>    Output mode.
        \\              Possible values:
        \\                json
        \\                yaml
        \\                toml
        \\                csv
        \\                xml
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    try expectM27Help(M27ArgBlockNoDefault, without_default);
}

test "M27: non-enumeration arguments keep their row layout" {
    const with_default =
        \\Usage: m27 [<target>] [flags]
        \\
        \\Arguments:
        \\  [<target>]    Target dir. Default value: out.
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    try expectM27Help(M27ArgPlainDefault, with_default);

    const without_default =
        \\Usage: m27 <target> [flags]
        \\
        \\Arguments:
        \\  <target>    Target dir.
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    try expectM27Help(M27ArgPlain, without_default);

    // An enumeration argument without a default prints only the values.
    const values_only =
        \\Usage: m27 <mode> [flags]
        \\
        \\Arguments:
        \\  <mode>    Output mode. Possible values: json, yaml.
        \\
        \\Flags:
        \\  -h, --help    Show context-sensitive help.
        \\
    ;
    try expectM27Help(M27ArgValuesOnly, values_only);
}

test "M27: environment-only defaults render as $NAME" {
    const expected =
        \\Usage: m27 [<mode>] [flags]
        \\
        \\Arguments:
        \\  [<mode>]    Output mode. Default value: $M27_MODE. Possible values: json, yaml.
        \\
        \\Flags:
        \\  -h, --help        Show context-sensitive help.
        \\      --no_color    No color.
        \\
    ;
    try expectM27Help(M27ArgEnv, expected);

    const text = try M27ArgEnv.helpText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // The defaulted bool leaves the usage header; the defaulted argument is
    // bracketed there.
    try std.testing.expect(std.mem.indexOf(u8, text, "[--no_color]") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[<mode>]") != null);

    // A direct default wins over the environment one in the clause.
    const both = try M27ArgBoth.helpText(std.testing.allocator);
    defer std.testing.allocator.free(both);
    try std.testing.expect(std.mem.indexOf(u8, both, "Default value: json.") != null);
    try std.testing.expect(std.mem.indexOf(u8, both, "$M27_MODE") == null);
}

test "M27: branch names and default values carry the flag-value highlight" {
    const text = try M27Highlight.helpText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // Branch names and the default value are `flags_value`; the label,
    // separators and branch help stay plain.
    try std.testing.expect(std.mem.indexOf(u8, text, "<v>fast</v>  - Fast mode.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<v>slow</v>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Default value: <v>json</v>.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Possible values: <v>json</v>, <v>yaml</v>.") != null);
}
