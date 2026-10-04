//! Declarative command-line parser.
//!
//! You describe your program's options and arguments through a struct-based
//! DSL; `generate` produces both a value representation (`Values`) and a
//! parser (`parse`) from that declaration.
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
    option,
    argument,
    group,
    command,
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
    app_name: []const u8 = "",
    option_name: []const u8 = "",
    arg_name: []const u8 = "",
    group_name: []const u8 = "",
    help_text: []const u8 = "",
    reset: []const u8 = "",

    const flat = HelpHighlight{};

    const bold = HelpHighlight{
        .app_name = "\x1b[1m",
        .option_name = "\x1b[1m",
        .arg_name = "\x1b[1m",
        .group_name = "\x1b[1m",
        .help_text = "",
        .reset = "\x1b[0m",
    };

    const color = HelpHighlight{
        .app_name = "\x1b[1m\x1b[32m",
        .option_name = "\x1b[32m",
        .arg_name = "\x1b[36m",
        .group_name = "\x1b[1m\x1b[34m",
        .help_text = "",
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

/// Declaration form for options.
pub fn Option(comptime T: type) type {
    return struct {
        pub const dap_kind: Kind = .option;
        pub const dap_value_type = T;

        /// Long option name. Optional. Can be derived from an anonymous field name.
        long: ?String = null,

        /// Short option name, optional (meh).
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

/// A purely declarative thing to group options and/or arguments together in the help output.
/// Does not reflect into the placeholder.
pub fn Group(comptime def: anytype, comptime name: String) type {
    return struct {
        pub const dap_kind: Kind = .group;
        pub const group_def = def;
        pub const group_name = name;
    };
}

/// Declaration form for arguments.
/// Unlike options, arguments are always required. This can be avoided with default values in case
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

/// Creates a type with decode and encode for commands. The API:
/// ```
/// dap.Commands(.{
///     cmd1: dap.Command(cmd.CommandMeta{ ... }, .{ ... }),
///     cmd2: dap.Command(cmd.CommandMeta{ ... }, .{ ... }),
///     ...
/// })
/// ```
/// With the same validation against names in CommandMeta and fields. And with the second argument
/// replicating what we would have with an application declaration itself.
///
/// The resulting type must be
/// ```
/// union {
///     cmd1: struct{ ... },
///     cmd2: struct{ ... },
///     ...
/// }
/// ```
pub fn Commands(comptime T: anytype) type {
    const fields = @typeInfo(@TypeOf(T)).@"struct".fields;
    const cmd_names: [fields.len]String = blk: {
        var a: [fields.len]String = undefined;
        for (fields, 0..) |f, i| {
            const Cmd = @field(T, f.name);
            if (@typeInfo(Cmd) != .@"struct" or !@hasDecl(Cmd, "cmd_meta")) {
                @compileError("Commands member '" ++ f.name ++ "' must be a Command");
            }
            a[i] = Cmd.cmd_meta.name orelse f.name;
        }
        break :blk a;
    };
    if (cmd_names.len == 0) {
        @compileError("Commands must declare at least one command");
    }
    for (cmd_names, 0..) |nm, i| {
        for (cmd_names[0..i]) |pn| {
            if (std.mem.eql(u8, nm, pn)) {
                @compileError("duplicate command name '" ++ nm ++ "'");
            }
        }
    }

    return struct {
        pub const dap_commands = true;
        pub const def = T;
        pub const names = cmd_names;
        pub const count = cmd_names.len;

        pub const wrappers = blk: {
            var ts: [cmd_names.len]type = undefined;
            for (fields, 0..) |f, i| ts[i] = Sub(@field(T, f.name));
            break :blk ts;
        };

        pub const sub_types = blk: {
            var ts: [cmd_names.len]type = undefined;
            for (fields, 0..) |f, i| ts[i] = Sub(@field(T, f.name)).Values;
            break :blk ts;
        };

        const TagInt = std.math.IntFittingRange(0, cmd_names.len - 1);
        const Tag = @Enum(TagInt, .exhaustive, &cmd_names, tg: {
            var a: [cmd_names.len]TagInt = undefined;
            for (0..cmd_names.len) |i| a[i] = @intCast(i);
            const arr: [cmd_names.len]TagInt = a;
            break :tg &arr;
        });

        pub const Union = @Union(.auto, Tag, &cmd_names, &sub_types, blk: {
            var a: [cmd_names.len]std.builtin.Type.UnionField.Attributes = undefined;
            for (0..cmd_names.len) |i| a[i] = .{};
            const arr: [cmd_names.len]std.builtin.Type.UnionField.Attributes = a;
            break :blk &arr;
        });
    };
}

/// Command description.
pub const CommandMeta = struct {
    name: ?String = null,
    help: String = "",
    i18n: ?String = null,
};

/// To be used
pub fn Command(comptime meta: CommandMeta, comptime def: anytype) type {
    return struct {
        pub const dap_kind: Kind = .command;
        pub const cmd_meta = meta;
        pub const cmd_def = def;
    };
}

/// Ready to use validation helpers to plug into `Option`/`Argument` declarations.
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
    /// A long or short option token matched no declaration.
    UnknownOption,
    /// A non-bool option was given without a value.
    MissingValue,
    /// A required option/argument was never provided.
    MissingRequired,
    /// A positional token found every argument slot already filled.
    TooManyArguments,
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

    /// A single option entry.
    pub const Option = struct {
        /// Long wire name, e.g. `dry_run` or an explicit `.long`.
        name: String,
        /// Short wire name, without the dash.
        short: ?String,
        /// Help string.
        help: String,
        /// Rendered default value, `null` when the option is required.
        default: ?String,
        /// Whether the option consumes a value (`<value>` in help); `false`
        /// for boolean flags.
        takes_value: bool,
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

    /// Options sharing a `Group` name, or the ungrouped options (`name == null`).
    pub const OptionGroup = struct {
        name: ?String,
        options: []Self.Option,
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

    /// `App.name`.
    name: String,
    /// `App.help`.
    info: String,
    /// Option groups; ungrouped options first, then named groups in declaration order.
    option_groups: []OptionGroup,
    /// Argument groups; ungrouped arguments first, then named groups in declaration order.
    arg_groups: []ArgGroup,
    /// Subcommands in declaration order.
    commands: []CommandInfo,
    /// Highlight scheme `renderCompact` applies. Filled from
    /// `App.help_renderer.highlight`; the codes are borrowed static strings and
    /// are not freed by `deinit`.
    highlight: HelpRendererHighlight = .{ .flat = {} },

    pub fn deinit(self: *HelpData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.info);

        for (self.option_groups) |g| {
            if (g.name) |n| allocator.free(n);
            for (g.options) |o| {
                allocator.free(o.name);
                if (o.short) |sh| allocator.free(sh);
                allocator.free(o.help);
                if (o.default) |dv| allocator.free(dv);
            }
            allocator.free(g.options);
        }
        allocator.free(self.option_groups);

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

        for (self.commands) |c| {
            allocator.free(c.name);
            allocator.free(c.help);
        }
        allocator.free(self.commands);
    }

    /// Render a compact, two-column help view of this description into a freshly
    /// allocated string, mirroring the layout of `kong`'s help renderer. The
    /// option/argument specs occupy the left column (short and long names aligned
    /// into their own sub-columns) and the help text the right; groups are
    /// ordered by name with the ungrouped bucket first.
    ///
    /// Every fragment is wrapped in the scheme carried by `highlight` (resolved
    /// from `App.help_renderer.highlight`): the app name, option names, argument
    /// names, group headings and help text each get their own codes. Widths are
    /// measured on the raw text before any codes are emitted, so highlighting
    /// never disturbs the column alignment. The caller owns the returned string
    /// and frees it with the same allocator.
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

        // Order option and argument groups by name, the ungrouped bucket
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

        const opt_order = try Order.of(OptionGroup, arena, self.option_groups);
        const arg_order = try Order.of(ArgGroup, arena, self.arg_groups);

        // Usage line: required options, then positionals, then `[flags]`.
        try out.appendSlice(allocator, "Usage: ");
        try appendHelpStyled(&out, allocator, hl, .app_name, self.name);
        for (opt_order) |gi| {
            for (self.option_groups[gi].options) |o| {
                if (o.default != null) continue;
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, "--");
                try appendHelpStyled(&out, allocator, hl, .option_name, o.name);
                if (o.takes_value) {
                    try out.append(allocator, '=');
                    try appendHelpStyled(&out, allocator, hl, .plain, try upperDup(arena, o.name));
                }
            }
        }
        for (arg_order) |gi| {
            for (self.arg_groups[gi].args) |a| {
                try out.append(allocator, ' ');
                const open: []const u8 = if (a.default == null) "<" else "[<";
                const close: []const u8 = if (a.default == null) ">" else ">]";
                try out.appendSlice(allocator, open);
                try appendHelpStyled(&out, allocator, hl, .arg_name, a.name);
                try out.appendSlice(allocator, close);
            }
        }
        var has_option = false;
        var has_optional = false;
        for (self.option_groups) |g| {
            for (g.options) |o| {
                has_option = true;
                if (o.default != null) has_optional = true;
            }
        }
        if (has_option and has_optional) try out.appendSlice(allocator, " [flags]");
        try out.append(allocator, '\n');

        if (self.info.len > 0) {
            try out.append(allocator, '\n');
            try appendHelpStyled(&out, allocator, hl, .help_text, self.info);
            try out.append(allocator, '\n');
        }

        // Collect the sections as raw (unstyled) fragments. Nothing is written
        // to `out` until every width has been measured, so the highlight codes
        // never leak into the column arithmetic.
        var arg_count: usize = 0;
        for (self.arg_groups) |g| arg_count += g.args.len;
        var n_opt_sections: usize = 0;
        for (self.option_groups) |g| {
            if (g.options.len > 0) n_opt_sections += 1;
        }
        var section_count = n_opt_sections;
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
                    const open: []const u8 = if (a.default == null) "<" else "[<";
                    const close: []const u8 = if (a.default == null) ">" else ">]";
                    try left.append(arena, .{ .text = open, .style = .plain });
                    try left.append(arena, .{ .text = a.name, .style = .arg_name });
                    try left.append(arena, .{ .text = close, .style = .plain });
                    rows[ri] = .{ .left = left.items, .help = a.help };
                    ri += 1;
                }
            }
            sections[si] = .{ .heading = "Arguments:", .rows = rows };
            si += 1;
        }

        for (opt_order) |gi| {
            const group = self.option_groups[gi];
            if (group.options.len == 0) continue;
            var have_short = false;
            for (group.options) |o| {
                if (o.short != null) {
                    have_short = true;
                    break;
                }
            }
            const rows = try arena.alloc(HelpRow, group.options.len);
            for (group.options, 0..) |o, ri| {
                var left: std.ArrayList(HelpSegment) = .empty;
                if (o.short) |sh| {
                    try left.append(arena, .{ .text = "-", .style = .plain });
                    try left.append(arena, .{ .text = sh, .style = .option_name });
                    try left.append(arena, .{ .text = ", ", .style = .plain });
                } else if (have_short) {
                    try left.append(arena, .{ .text = "    ", .style = .plain });
                }
                try left.append(arena, .{ .text = "--", .style = .plain });
                try left.append(arena, .{ .text = o.name, .style = .option_name });
                if (o.takes_value) {
                    try left.append(arena, .{ .text = "=", .style = .plain });
                    if (o.default) |d| {
                        try left.append(arena, .{ .text = d, .style = .plain });
                    } else {
                        try left.append(arena, .{ .text = try upperDup(arena, o.name), .style = .plain });
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
                try left.append(arena, .{ .text = c.name, .style = .option_name });
                rows[ri] = .{ .left = left.items, .help = c.help };
            }
            sections[si] = .{ .heading = "Commands:", .rows = rows };
            si += 1;
        }

        for (sections) |section| {
            try out.append(allocator, '\n');
            try appendHelpStyled(&out, allocator, hl, .group_name, section.heading);
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
                        try appendHelpStyled(&out, allocator, hl, .help_text, r.help);
                    }
                } else if (r.help.len > 0) {
                    try out.append(allocator, '\n');
                    try out.appendSlice(allocator, indent);
                    var pad = left_size + column_padding;
                    while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
                    try appendHelpStyled(&out, allocator, hl, .help_text, r.help);
                }
                try out.append(allocator, '\n');
            }
        }

        return try out.toOwnedSlice(allocator);
    }
};

/// Highlight category a compact-help fragment belongs to.
const HelpStyle = enum { plain, app_name, option_name, arg_name, group_name, help_text };

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
        .app_name => hl.app_name,
        .option_name => hl.option_name,
        .arg_name => hl.arg_name,
        .group_name => hl.group_name,
        .help_text => hl.help_text,
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

/// Generate a parser for a declaration, together with the value type it
/// produces. `generate` returns a namespace wrapper exposing:
///
/// - `pub const Values` — a struct with one field per declaration field (in
///   declaration order, with the injected `builtin_help: bool` first), plus a
///   trailing optional tagged union when the declaration carries a `Commands`
///   field;
/// - `pub fn parse(allocator, environ, args, diag) ParseError!Values`;
/// - `app_meta`, `specs`, `commands` metadata;
/// - `pub fn helpData(allocator) !HelpData` — runtime-filled description;
/// - `pub fn helpText(allocator) !String` — render `helpData` with the
///   renderer configured in `app.help_renderer.style` (`.compact` by default,
///   or a user-provided function via `.custom`).
///
/// A `-h, --help` option is injected at the very beginning of every
/// declaration. When `parse` sees it, it bypasses all required checks and
/// validations, prints the rendered help text to stdout and exits with code
/// `0`. Any syntax, decode, required or validation failure prints the
/// diagnostics plus the help text to stderr and exits with code `1`.
///
/// Every `parse` — the root and each subcommand alike — treats `args` as pure
/// payload: iteration starts at index `0` and nothing is skipped. Pass the
/// process arguments with the binary name already removed (`os.argv[1..]`).
///
/// Example:
///
/// ```
/// const def = .{
///     .login = dap.Option([]const u8){
///         .short = "l",
///         .default = dap.Default(dap.String){
///             .env = "USER",
///         },
///         .validation = dap.Validate.stringNotEmpty,
///         .help = "User login.",
///     },
///     .password = dap.Option([]const u8){
///         .short = "p",
///         .validation = dap.Validate.stringNotEmpty,
///         .help = "Password for the given login.",
///     },
///     .verbosity = dap.Option(u8){
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
/// `Values` is a plain struct (`cli.login`, `cli.path`, ...) whose strings are
/// allocated with the passed allocator. No name transformation is applied:
/// field names are wire names verbatim (`dry_run` → `--dry_run`), and a
/// dash-spelled name requires an explicit `.long`.
///
/// A `Commands` field hands parsing off to the matching subcommand. The token
/// equal to a registered command name terminates the current parse and the
/// subcommand's `parse` receives `args[command_index + 1 ..]`, again starting
/// at its own index `0`. The result is a `?Union` the consumer switches over
/// manually; when no command token appears the field is `null`:
///
/// ```
/// const def = .{
///     .verbose = dap.Option(bool){
///         .default = dap.Default(bool){ .direct = false },
///     },
///     .command = dap.Commands(.{
///         .start = dap.Command(dap.CommandMeta{ .help = "Start." }, .{
///             .name = dap.Argument([]const u8){},
///         }),
///         .stop = dap.Command(dap.CommandMeta{ .help = "Stop." }, .{}),
///     }),
/// };
///
/// const CLI = dap.generate(dap.App{ .name = "svc", .help = "Service." }, def);
/// var cli = try CLI.parse(allocator, environ, args, &diag);
/// if (cli.command) |cmd| switch (cmd) {
///     .start => |s| try serve(s.name),
///     .stop => try shutdown(),
/// };
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

/// The `-h, --help` option specification injected at the very beginning of
/// every declaration before normalization, so `helpData` naturally sees it
/// via `inline for` and renders it in the flags section.
const BuiltinHelp = Option(bool){
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
    const merged = withBuiltinHelp(def);
    const norm = normalize(merged);
    const all_specs = norm.specs;
    const cmd = norm.commands;

    const field_names = blk: {
        var names: []const String = &.{};
        for (all_specs) |s| names = names ++ &[_]String{s.name};
        if (cmd) |cl| names = names ++ &[_]String{cl.field};
        break :blk names;
    };
    const field_types = blk: {
        var ts: []const type = &.{};
        for (all_specs) |s| ts = ts ++ &[_]type{s.vtype};
        if (cmd) |cl| ts = ts ++ &[_]type{?cl.CT.Union};
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

    // Distinct group names per kind, in first-seen declaration order. Options
    // and arguments are grouped independently so an option-only group does not
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
    const option_group_names: []const String = group_names_of(.option);
    const arg_group_names: []const String = group_names_of(.argument);

    // Specs partitioned by group; first entry is the ungrouped bucket. Drives
    // `helpData` ordering without runtime scans.
    const option_specs: [1 + option_group_names.len][]const Spec = blk: {
        var buckets: [1 + option_group_names.len][]const Spec = @splat(&.{});
        for (all_specs) |s| {
            if (s.kind != .option) continue;
            const bi: usize = if (s.group) |g| blk2: {
                for (option_group_names, 0..) |nm, gi| {
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

    return struct {
        pub const app_meta = app;
        pub const specs = all_specs;
        pub const commands = cmd;
        pub const Values = @Struct(.auto, null, &Names, &Types, &Attrs);

        /// Fill a runtime [`HelpData`] description of this declaration. Every
        /// string and slice is allocated with `allocator`; release them with
        /// `HelpData.deinit`. Nothing here runs unless this or `helpText` is
        /// called.
        pub fn helpData(allocator: std.mem.Allocator) std.mem.Allocator.Error!HelpData {
            const name = try allocator.dupe(u8, app.name);
            errdefer allocator.free(name);
            const info = try allocator.dupe(u8, app.help);
            errdefer allocator.free(info);

            // Option groups: entry 0 is the ungrouped bucket, the rest follow
            // `option_group_names` in first-seen declaration order.
            const option_groups = try allocator.alloc(HelpData.OptionGroup, 1 + option_group_names.len);
            var og_filled: usize = 0;
            errdefer {
                freeOptionGroups(allocator, option_groups[0..og_filled]);
                allocator.free(option_groups);
            }

            inline for (option_specs, 0..) |bucket, bi| {
                const list = try allocator.alloc(HelpData.Option, bucket.len);
                var filled: usize = 0;
                errdefer {
                    freeOptions(allocator, list[0..filled]);
                    allocator.free(list);
                }
                inline for (bucket) |s| {
                    list[filled] = try fillOption(allocator, s);
                    filled += 1;
                }
                const gname: ?String = if (bi == 0) null else try allocator.dupe(u8, option_group_names[bi - 1]);
                option_groups[bi] = .{ .name = gname, .options = list };
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

            const ncmds = if (cmd) |cl| cl.CT.names.len else 0;
            const cmd_infos = try allocator.alloc(HelpData.CommandInfo, ncmds);
            var cm_filled: usize = 0;
            errdefer {
                freeCommands(allocator, cmd_infos[0..cm_filled]);
                allocator.free(cmd_infos);
            }
            if (cmd) |cl| {
                inline for (cl.CT.names, 0..) |cname, ci| {
                    const cname_dup = try allocator.dupe(u8, cname);
                    errdefer allocator.free(cname_dup);
                    const chelp = try allocator.dupe(u8, cl.CT.wrappers[ci].app_meta.help);
                    cmd_infos[ci] = .{ .name = cname_dup, .help = chelp };
                    cm_filled += 1;
                }
            }

            return .{
                .name = name,
                .info = info,
                .option_groups = option_groups,
                .arg_groups = arg_groups,
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

        /// Render one option entry into `HelpData`, duplicating every string.
        fn fillOption(allocator: std.mem.Allocator, comptime s: Spec) std.mem.Allocator.Error!HelpData.Option {
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
            return .{ .name = oname, .short = oshort, .help = ohelp, .default = odefault, .takes_value = s.vtype != bool };
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

        fn freeOptions(allocator: std.mem.Allocator, opts: []HelpData.Option) void {
            for (opts) |o| {
                allocator.free(o.name);
                if (o.short) |sh| allocator.free(sh);
                allocator.free(o.help);
                if (o.default) |dv| allocator.free(dv);
            }
        }

        fn freeOptionGroups(allocator: std.mem.Allocator, groups: []HelpData.OptionGroup) void {
            for (groups) |g| {
                if (g.name) |n| allocator.free(n);
                freeOptions(allocator, g.options);
                allocator.free(g.options);
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

        pub fn parse(allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8, diag: ?*Diag) ParseError!Values {
            const result = parseInner(allocator, environ, args, diag) catch {
                printFailureExit(allocator, diag);
            };

            // HELP REQUESTED INTERCEPT: a requested help flag bypassed every
            // required check and validation inside `parseInner`. Render the
            // help text with the app's renderer, print it to stdout, and exit
            // cleanly.
            if (result.builtin_help) {
                if (helpTextWithStyle(allocator)) |text| {
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
        fn parseInner(allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8, diag: ?*Diag) ParseError!Values {
            if (diag) |d| d.* = .{};

            var v: Values = undefined;
            var seen: [all_specs.len]bool = @splat(false);
            var pos: usize = 0;
            var handed_off = false;

            // Phase 0: INIT. The builtin help flag starts false so the
            // post-loop intercept below can read it even when no wire token
            // mentioned it.
            v.builtin_help = false;
            if (cmd) |cl| @field(v, cl.field) = null;

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
                    try consumeLongOption(allocator, &v, &seen, args, &i, diag);
                } else if (tok.len > 1 and tok[0] == '-') {
                    try consumeShortOption(allocator, &v, &seen, args, &i, diag);
                } else if (cmd) |cl| {
                    // HANDOFF: a positional token equal to a registered
                    // command name is checked before POSITIONAL. The
                    // sub-parse receives the payload after the command token
                    // and again starts at its own index 0.
                    var matched = false;
                    inline for (cl.CT.names, 0..) |cname, ci| {
                        if (std.mem.eql(u8, cname, tok)) {
                            const S = cl.CT.wrappers[ci];
                            @field(v, cl.field) = @unionInit(cl.CT.Union, cname, try S.parseInner(allocator, environ, args[i + 1 ..], diag));
                            handed_off = true;
                            matched = true;
                        }
                    }
                    if (!matched) {
                        try assignPositional(allocator, &v, &seen, &pos, tok, diag);
                    }
                } else {
                    try assignPositional(allocator, &v, &seen, &pos, tok, diag);
                }
            }

            // Phase 2: HELP. A requested help flag completely bypasses the
            // required checks and post-parse validations below; `parse` turns
            // the early return into rendered help on stdout and a clean exit.
            if (v.builtin_help) {
                return v;
            }

            // Phase 3: POST-PASS. For every spec not seen during the scan, in
            // declaration order: env default, then direct default, then the
            // uniform required check, then a zero value.
            inline for (all_specs, 0..) |s, si| {
                if (!seen[si]) {
                    try resolveAbsent(s, allocator, environ, &v, diag);
                }
            }

            // Phase 4: VALIDATE. Run each spec's validation fn over the final
            // value, regardless of whether it came from the wire, an env value
            // or a direct default. A non-null allocated message is stored in
            // `diag.message` (owned there) and reported as InvalidValue.
            inline for (all_specs) |s| {
                if (s.validation) |vp| {
                    const vf: *const fn (std.mem.Allocator, s.vtype) std.mem.Allocator.Error!?String = @ptrCast(@alignCast(vp));
                    const msg = try vf(allocator, @field(v, s.name));
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

        fn consumeLongOption(allocator: std.mem.Allocator, v: *Values, seen: *[all_specs.len]bool, args: []const []const u8, i: *usize, diag: ?*Diag) ParseError!void {
            const tok = args[i.*];
            const body = tok[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const eqv: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            inline for (all_specs, 0..) |s, si| {
                if (s.kind == .option and std.mem.eql(u8, s.long, name)) {
                    if (s.vtype == bool) {
                        try assignValue(s, Values, allocator, v, seen, si, eqv orelse "true", diag);
                    } else if (eqv) |iv| {
                        try assignValue(s, Values, allocator, v, seen, si, iv, diag);
                    } else {
                        if (i.* + 1 >= args.len) {
                            if (diag) |d| d.token = tok;
                            return error.MissingValue;
                        }
                        i.* += 1;
                        try assignValue(s, Values, allocator, v, seen, si, args[i.*], diag);
                    }
                    return;
                }
            }

            if (diag) |d| d.token = tok;
            return error.UnknownOption;
        }

        fn consumeShortOption(allocator: std.mem.Allocator, v: *Values, seen: *[all_specs.len]bool, args: []const []const u8, i: *usize, diag: ?*Diag) ParseError!void {
            const tok = args[i.*];
            const body = tok[1..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const eqv: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            inline for (all_specs, 0..) |s, si| {
                if (s.kind == .option) {
                    if (s.short) |sh| {
                        if (std.mem.eql(u8, sh, name)) {
                            if (s.vtype == bool) {
                                try assignValue(s, Values, allocator, v, seen, si, eqv orelse "true", diag);
                            } else if (eqv) |iv| {
                                try assignValue(s, Values, allocator, v, seen, si, iv, diag);
                            } else {
                                if (i.* + 1 >= args.len) {
                                    if (diag) |d| d.token = tok;
                                    return error.MissingValue;
                                }
                                i.* += 1;
                                try assignValue(s, Values, allocator, v, seen, si, args[i.*], diag);
                            }
                            return;
                        }
                    }
                }
            }

            if (diag) |d| d.token = tok;
            return error.UnknownOption;
        }

        fn assignPositional(allocator: std.mem.Allocator, v: *Values, seen: *[all_specs.len]bool, pos: *usize, tok: []const u8, diag: ?*Diag) ParseError!void {
            if (pos.* >= arg_count) {
                if (diag) |d| d.token = tok;
                return error.TooManyArguments;
            }
            inline for (all_specs, 0..) |s, si| {
                if (s.kind == .argument and args_before[si] == pos.* and !seen[si]) {
                    try assignValue(s, Values, allocator, v, seen, si, tok, diag);
                    pos.* += 1;
                    return;
                }
            }
            if (diag) |d| d.token = tok;
            return error.TooManyArguments;
        }
    };
}

/// Wrapper generated for a single command. Provides `Values` (fields generated
/// from the command's declaration) and the symmetric `parse` entry point.
fn Sub(comptime Cmd: type) type {
    return generate(App{ .name = "", .help = Cmd.cmd_meta.help }, Cmd.cmd_def);
}

/// Normalized, comptime-only description of a single option or argument.
const Spec = struct {
    name: String,
    kind: Kind,
    vtype: type,
    long: String,
    short: ?String,
    arg_name: ?String = null,
    required: bool,
    default: ?DefaultRepr,
    default_env: ?String,
    validation: ?*const anyopaque,
    help: String,
    i18n: ?String,
    group: ?String,
};

/// A type-erased pointer to a comptime default value. Recover the value with `get`.
const DefaultRepr = struct {
    ptr: *const anyopaque,

    fn get(self: DefaultRepr, comptime T: type) T {
        return @as(*const T, @ptrCast(@alignCast(self.ptr))).*;
    }
};

/// The single command declaration found at a given level, if any.
const CommandLevel = struct {
    field: String,
    CT: type,
};

const NormResult = struct {
    specs: []const Spec,
    commands: ?CommandLevel,
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
    decodeInto(s.vtype, allocator, val, &@field(v.*, s.name)) catch |e| {
        if (diag) |d| d.field = s.name;
        return e;
    };
    seen[si] = true;
}

/// Errors the post-pass may report for an absent spec.
const ResolveAbsentError = error{ MissingRequired, InvalidWtf8 } || std.mem.Allocator.Error || DecodeError;

/// Runs the post-pass for a spec that no wire token filled, in declaration
/// order: an environment default, then a direct default, then the uniform
/// required check (option/argument required iff it has no default), then a
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
    @field(v, s.name) = zeroValue(s.vtype);
}

fn specFromField(comptime f: std.builtin.Type.StructField) Spec {
    const T = f.type;

    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "dap_kind")) {
        @compileError("declaration field '" ++ f.name ++ "' must be an Option or Argument");
    }

    const K = T.dap_kind;
    if (K != .option and K != .argument) {
        @compileError("declaration field '" ++ f.name ++ "' must be an Option or Argument");
    }

    const V = T.dap_value_type;
    if (!isDecodable(V)) {
        @compileError("value type of declaration field '" ++ f.name ++ "' is not decodable (needs decode/encode methods)");
    }
    const inst = instValue(f);
    const defpair = declDefault(T, inst);
    const direct: ?DefaultRepr = if (defpair) |d| (if (d.direct) |dv| reprOf(dv) else null) else null;
    const env: ?String = if (defpair) |d| d.env else null;
    const vp: ?*const anyopaque = if (declValidation(T, inst)) |vf| fnToPtr(vf) else null;

    return .{
        .name = f.name,
        .kind = K,
        .vtype = V,
        .long = if (K == .option) (declLong(T, inst) orelse f.name) else f.name,
        .short = if (K == .option) declShort(T, inst) else null,
        .arg_name = if (K == .argument) declArgName(T, inst) else null,
        .required = (direct == null and env == null),
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

fn commandNames(comptime CT: type) []const String {
    return &CT.names;
}

fn checkDuplicates(comptime specs: []const Spec) void {
    comptime {
        for (specs, 0..) |a, i| {
            if (a.kind != .option) continue;
            for (specs[i + 1 ..]) |b| {
                if (b.kind != .option) continue;
                if (std.mem.eql(u8, a.long, b.long)) {
                    @compileError("duplicate long option '--" ++ a.long ++ "' on fields '" ++ a.name ++ "' and '" ++ b.name ++ "'");
                }
            }
            if (a.short) |sa| {
                for (specs[i + 1 ..]) |b| {
                    if (b.short) |sb| {
                        if (std.mem.eql(u8, sa, sb)) {
                            @compileError("duplicate short option '-" ++ sa ++ "' on fields '" ++ a.name ++ "' and '" ++ b.name ++ "'");
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

fn normalize(comptime def: anytype) NormResult {
    var specs: []const Spec = &.{};
    var commands: ?CommandLevel = null;

    inline for (@typeInfo(@TypeOf(def)).@"struct".fields) |f| {
        if (f.type == type) {
            const V = typeOfField(f);
            if (@hasDecl(V, "dap_commands")) {
                if (commands != null) {
                    @compileError("only one Commands field is allowed per level; duplicate field '" ++ f.name ++ "'");
                }
                commands = .{ .field = f.name, .CT = V };
            } else if (@hasDecl(V, "dap_kind") and V.dap_kind == .group) {
                specs = specs ++ groupSpecs(V.group_def, V.group_name);
            } else {
                @compileError("unknown type-valued declaration field '" ++ f.name ++ "'");
            }
        } else {
            specs = specs ++ &[_]Spec{specFromField(f)};
        }
    }

    if (commands) |cl| {
        _ = commandNames(cl.CT);
    }
    checkDuplicates(specs);
    checkFieldNames(specs);
    checkArgumentDefaults(specs);

    return .{ .specs = specs, .commands = commands };
}

test "doc example declaration compiles" {
    const def = .{
        .login = Option([]const u8){
            .short = "l",
            .default = Default(String){
                .env = "USER",
            },
            .validation = Validate.stringNotEmpty,
            .help = "User login.",
        },
        .password = Option([]const u8){
            .short = "p",
            .validation = Validate.stringNotEmpty,
            .help = "Password for the given login.",
        },
        .verbosity = Option(u8){
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

test "option field defaults" {
    const o = Option(u8){ .help = "x" };
    try std.testing.expect(o.long == null);
    try std.testing.expect(o.short == null);
    try std.testing.expect(o.default == null);
    try std.testing.expect(o.validation == null);
    try std.testing.expect(o.i18n == null);
    try std.testing.expectEqualStrings("x", o.help);
    try std.testing.expect(Option(u8).dap_kind == .option);
    try std.testing.expect(Option(u8).dap_value_type == u8);
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
        .host = Option([]const u8){ .help = "Host" },
        .server = Group(.{
            .port = Option(u16){ .help = "Port" },
        }, "Server"),
        .command = Commands(.{
            .start = Command(CommandMeta{ .help = "Start" }, .{
                .name = Argument([]const u8){ .help = "Name" },
            }),
        }),
    };
    _ = def;
    try std.testing.expect(Group(.{}, "G").dap_kind == .group);
    try std.testing.expect(Commands(.{ .a = Command(CommandMeta{}, .{}) }).dap_commands);
    try std.testing.expect(Command(CommandMeta{}, .{}).dap_kind == .command);
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
    .login = Option([]const u8){
        .short = "l",
        .default = Default(String){ .env = "USER" },
        .validation = Validate.stringNotEmpty,
        .help = "User login.",
    },
    .password = Option([]const u8){
        .short = "p",
        .validation = Validate.stringNotEmpty,
        .help = "Password.",
    },
    .verbosity = Option(u8){
        .short = "V",
        .default = Default(u8){ .direct = 3 },
        .help = "Verbosity.",
    },
    .dry_run = Option(bool){
        .long = "dry-run",
        .default = Default(bool){ .direct = false },
    },
    .server = Group(.{
        .port = Option(u16){
            .short = "P",
            .default = Default(u16){ .direct = 8080 },
        },
        .host = Option([]const u8){ .help = "Host." },
    }, "Server"),
    .path = Argument([]const u8){
        .validation = Validate.stringNotEmpty,
        .help = "Path.",
    },
    .output = Argument([]const u8){
        .default = Default([]const u8){ .direct = "stdout" },
    },
    .command = Commands(.{
        .start = Command(CommandMeta{ .help = "Start." }, .{
            .name = Argument([]const u8){ .help = "Name." },
        }),
        .stop = Command(CommandMeta{ .name = "halt", .help = "Stop." }, .{}),
    }),
};

test "M1: normalize spec contents" {
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    const specs = C.specs;

    try std.testing.expectEqual(@as(usize, 9), specs.len);

    // builtin_help: injected at the very front of every declaration.
    try std.testing.expectEqualStrings("builtin_help", specs[0].name);
    try std.testing.expect(specs[0].kind == .option);
    try std.testing.expect(specs[0].vtype == bool);
    try std.testing.expectEqualStrings("help", specs[0].long);
    try std.testing.expectEqualStrings("h", specs[0].short.?);
    try std.testing.expect(!specs[0].required);
    try std.testing.expectEqual(false, specs[0].default.?.get(bool));
    try std.testing.expectEqualStrings("Show context-sensitive help.", specs[0].help);
    try std.testing.expectEqualStrings("builtin.help", specs[0].i18n.?);

    // login: env default, required derived false, verbatim long from field.
    try std.testing.expectEqualStrings("login", specs[1].name);
    try std.testing.expect(specs[1].kind == .option);
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
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    try std.testing.expect(C.commands != null);
    try std.testing.expectEqualStrings("command", C.commands.?.field);
    try std.testing.expect(C.commands.?.CT.dap_commands);

    const names = commandNames(C.commands.?.CT);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("start", names[0]);
    try std.testing.expectEqualStrings("halt", names[1]);
}

test "M1: def without commands reports null" {
    const C = generate(App{ .name = "app", .help = "help" }, .{
        .x = Option(u8){ .default = Default(u8){ .direct = 0 } },
    });
    try std.testing.expect(C.commands == null);
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
            .a = Option(u8){ .long = "same" },
            .b = Option(u8){ .long = "same" },
        };
        _ = normalize(Bad);
    }
}

test "M1: duplicate short names are a compile error" {
    if (false) {
        const Bad = .{
            .a = Option(u8){ .short = "s" },
            .b = Option(u8){ .short = "s" },
        };
        _ = normalize(Bad);
    }
}

test "M1: two Commands fields are a compile error" {
    if (false) {
        const Bad = .{
            .one = Commands(.{ .a = Command(CommandMeta{}, .{}) }),
            .two = Commands(.{ .b = Command(CommandMeta{}, .{}) }),
        };
        _ = normalize(Bad);
    }
}

test "M1: zero commands are a compile error" {
    if (false) {
        const Bad = .{ .c = Commands(.{}) };
        _ = normalize(Bad);
    }
}

test "M1: duplicate command names are a compile error" {
    if (false) {
        const Bad = .{
            .c = Commands(.{
                .a = Command(CommandMeta{ .name = "same" }, .{}),
                .b = Command(CommandMeta{ .name = "same" }, .{}),
            }),
        };
        _ = normalize(Bad);
    }
}

test "M1: argument default not last is a compile error" {
    if (false) {
        const Bad = .{
            .first = Argument(u8){ .default = Default(u8){ .direct = 1 } },
            .second = Argument(u8){},
        };
        _ = normalize(Bad);
    }
}

test "M1: undecodable value type is a compile error" {
    if (false) {
        const Bad = .{
            .x = Option(struct { z: u8 }){},
        };
        _ = normalize(Bad);
    }
}

test "M2: Values field order and types" {
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    const V = C.Values;
    const fields = @typeInfo(V).@"struct".fields;

    // 9 specs (builtin_help injected first) + 1 commands field.
    try std.testing.expectEqual(@as(usize, 10), fields.len);

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

    try std.testing.expectEqualStrings("path", fields[7].name);
    try std.testing.expectEqualStrings("output", fields[8].name);

    // trailing commands field is optional tagged union.
    try std.testing.expectEqualStrings("command", fields[9].name);
    try std.testing.expectEqual(@as(type, ?C.commands.?.CT.Union), fields[9].type);
    try std.testing.expect(@typeInfo(fields[9].type) == .optional);
    try std.testing.expect(@typeInfo(@typeInfo(fields[9].type).optional.child) == .@"union");
}

test "M2: @FieldType matches specs" {
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    const V = C.Values;

    inline for (C.specs) |s| {
        try std.testing.expectEqual(@as(type, s.vtype), @FieldType(V, s.name));
    }
    try std.testing.expectEqual(@as(type, ?C.commands.?.CT.Union), @FieldType(V, "command"));
}

test "M2: Values without commands has only spec fields" {
    const C = generate(App{ .name = "app", .help = "help" }, .{
        .a = Option(u8){ .default = Default(u8){ .direct = 0 } },
        .b = Argument([]const u8){},
    });
    const fields = @typeInfo(C.Values).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("builtin_help", fields[0].name);
    try std.testing.expectEqual(@as(type, bool), fields[0].type);
    try std.testing.expectEqualStrings("a", fields[1].name);
    try std.testing.expectEqual(@as(type, u8), fields[1].type);
    try std.testing.expectEqualStrings("b", fields[2].name);
    try std.testing.expectEqual(@as(type, []const u8), fields[2].type);
}

test "M2: commands field type is the union of subcommand Values" {
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    const CT = C.commands.?.CT;
    const U = CT.Union;
    const ufields = @typeInfo(U).@"union".fields;

    try std.testing.expectEqual(@as(usize, 2), ufields.len);
    try std.testing.expectEqualStrings("start", ufields[0].name);
    try std.testing.expectEqualStrings("halt", ufields[1].name);

    // each union payload is the command's generated Values struct; the
    // injected builtin_help field occupies the first slot of every sub.
    const StartSub = ufields[0].type;
    const start_fields = @typeInfo(StartSub).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), start_fields.len);
    try std.testing.expectEqualStrings("builtin_help", start_fields[0].name);
    try std.testing.expectEqualStrings("name", start_fields[1].name);

    const HaltSub = ufields[1].type;
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(HaltSub).@"struct".fields.len);

    // wrappers still expose their own commands decl.
    try std.testing.expect(CT.wrappers[1].commands == null);
}

test "M2: Values is a fully usable struct" {
    const C = generate(App{ .name = "app", .help = "help" }, M1Def);
    var v: C.Values = undefined;
    v.builtin_help = false;
    v.login = "bob";
    v.password = "pw";
    v.verbosity = 3;
    v.dry_run = false;
    v.port = 8080;
    v.host = "localhost";
    v.path = "/tmp/f";
    v.output = "stdout";
    v.command = null;

    try std.testing.expectEqualStrings("bob", v.login);
    try std.testing.expect(v.command == null);
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
    .verbose = Option(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
    },
    .name = Option([]const u8){
        .short = "n",
        .default = Default([]const u8){ .direct = "anon" },
    },
    .level = Option(u8){
        .long = "level",
        .default = Default(u8){ .direct = 1 },
    },
    .dry_run = Option(bool){
        .long = "dry-run",
        .default = Default(bool){ .direct = false },
    },
    .mode = Option([]const u8){
        .long = "mode",
        .default = Default([]const u8){ .direct = "fast" },
    },
    .file = Argument([]const u8){},
    .dir = Argument([]const u8){
        .default = Default([]const u8){ .direct = "." },
    },
};

fn m4Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M4Values {
    return M4.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

const M4 = generate(App{ .name = "m4", .help = "m4" }, M4Def);
const M4Values = M4.Values;

test "M4: long option inline and separate value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m4Parse(&arena, &.{ "--level=7", "f1" }, &diag);
    try std.testing.expectEqual(@as(u8, 7), a.level);
    try std.testing.expectEqualStrings("f1", a.file);

    const b = try m4Parse(&arena, &.{ "--level", "9", "f2" }, &diag);
    try std.testing.expectEqual(@as(u8, 9), b.level);
}

test "M4: short option separate, inline and eq forms" {
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

test "M4: unknown long option reports token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownOption, m4Parse(&arena, &.{ "--nope", "f" }, &diag));
    try std.testing.expectEqualStrings("--nope", diag.token.?);
}

test "M4: unknown short option reports token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownOption, m4Parse(&arena, &.{ "-z", "f" }, &diag));
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
    .user = Option([]const u8){
        .short = "u",
        .default = Default([]const u8){ .env = "DAP_USER" },
    },
    .port = Option(u16){
        .default = Default(u16){ .env = "DAP_PORT", .direct = 4242 },
    },
    .host = Option([]const u8){
        .default = Default([]const u8){ .direct = "localhost" },
    },
    .loud = Option(bool){
        .default = Default(bool){ .direct = false },
    },
    .needed = Option(bool){},
    .file = Argument([]const u8){},
    .dir = Argument([]const u8){
        .default = Default([]const u8){ .direct = "." },
    },
};

const M5 = generate(App{ .name = "m5", .help = "m5" }, M5Def);
const M5Values = M5.Values;

fn makeEnviron(comptime entries: []const [*:0]const u8) std.process.Environ {
    return .{ .block = .{ .slice = (entries ++ &[_]?[*:0]const u8{null})[0..entries.len :null] } };
}

fn m5Parse(environ: std.process.Environ, arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M5Values {
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

test "M5: required bool must be passed; optional bool honoured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    try std.testing.expectError(error.MissingRequired, m5Parse(std.process.Environ.empty, &arena, &.{"f"}, &diag));
    try std.testing.expectEqualStrings("needed", diag.field.?);

    // Presence of the flag satisfies a required bool even as `false`.
    const a = try m5Parse(std.process.Environ.empty, &arena, &.{ "--needed=false", "f" }, &diag);
    try std.testing.expect(!a.needed);
    try std.testing.expect(!a.loud); // optional bool via explicit default
}

test "M5: required error carries diag.field for env/direct-less spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // `--needed` is satisfied, but the required `file` argument is absent.
    try std.testing.expectError(error.MissingRequired, m5Parse(std.process.Environ.empty, &arena, &.{"--needed"}, &diag));
    try std.testing.expectEqualStrings("file", diag.field.?);
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
    .user = Option([]const u8){
        .short = "u",
        .validation = Validate.stringNotEmpty,
        .default = Default([]const u8){ .env = "DAP_USER" },
    },
    .level = Option(u8){
        .long = "level",
        .validation = Validate.intNotZero(u8),
        .default = Default(u8){ .direct = 1 },
    },
    .path = Argument([]const u8){
        .validation = Validate.stringNotEmpty,
    },
};

const M6 = generate(App{ .name = "m6", .help = "m6" }, M6Def);
const M6Values = M6.Values;

fn m6Parse(environ: std.process.Environ, arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: ?*Diag) !M6Values {
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
        .level = Option(u8){
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
        .level = Option(u8){
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

// --- M7: handoff (Commands integration in the loop) ---

const M7Def = .{
    .verbose = Option(bool){
        .long = "verbose",
        .default = Default(bool){ .direct = false },
    },
    .needed = Option([]const u8){ .long = "needed" },
    .command = Commands(.{
        .start = Command(CommandMeta{ .help = "Start." }, .{
            .name = Argument([]const u8){},
            .force = Option(bool){
                .long = "force",
                .default = Default(bool){ .direct = false },
            },
        }),
        .stop = Command(CommandMeta{ .name = "halt", .help = "Stop." }, .{}),
        .nested = Command(CommandMeta{ .help = "Nested." }, .{
            .inner = Commands(.{
                .deep = Command(CommandMeta{ .help = "Deep." }, .{
                    .n = Argument(u8){},
                }),
            }),
        }),
    }),
};

const M7 = generate(App{ .name = "m7", .help = "m7" }, M7Def);
const M7Values = M7.Values;

fn m7Parse(arena: *std.heap.ArenaAllocator, args: []const []const u8, diag: *Diag) !M7Values {
    return M7.parseInner(arena.allocator(), std.process.Environ.empty, args, diag);
}

test "M7: root options then command handoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--verbose", "--needed", "v", "start", "file" }, &diag);
    try std.testing.expect(a.verbose);
    try std.testing.expectEqualStrings("v", a.needed);
    try std.testing.expect(a.command != null);
    try std.testing.expect(std.meta.activeTag(a.command.?) == .start);
    try std.testing.expectEqualStrings("file", a.command.?.start.name);
}

test "M7: no command leaves the union null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--needed", "v" }, &diag);
    try std.testing.expect(a.command == null);
}

test "M7: named command via CommandMeta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    const a = try m7Parse(&arena, &.{ "--needed", "v", "halt" }, &diag);
    try std.testing.expect(a.command != null);
    try std.testing.expect(std.meta.activeTag(a.command.?) == .halt);
}

test "M7: options after the command are scoped to the sub" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    // `--force` is a start-scoped option; the root never sees it.
    const a = try m7Parse(&arena, &.{ "--needed", "v", "start", "--force", "file" }, &diag);
    try std.testing.expect(std.meta.activeTag(a.command.?) == .start);
    try std.testing.expect(a.command.?.start.force);
    try std.testing.expectEqualStrings("file", a.command.?.start.name);
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
    try std.testing.expect(std.meta.activeTag(a.command.?) == .nested);
    const nested = a.command.?.nested;
    try std.testing.expect(nested.inner != null);
    try std.testing.expect(std.meta.activeTag(nested.inner.?) == .deep);
    try std.testing.expectEqual(@as(u8, 5), nested.inner.?.deep.n);
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

test "M8: enumeration works as an option value type" {
    const def = .{
        .mode = Option(Mode){
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
    .verbose = Option(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
        .help = "Verbose output.",
    },
    .dry_run = Option(bool){
        .long = "dry-run",
        .help = "Dry run.",
    },
    .port = Option(u16){
        .short = "P",
        .default = Default(u16){ .direct = 8080 },
        .help = "Port.",
    },
    .server = Group(.{
        .host = Option([]const u8){
            .help = "Host.",
            .i18n = "server.host",
        },
    }, "Server settings"),
    .path = Argument([]const u8){ .help = "Path of the file." },
    .named = Argument([]const u8){ .name = "TARGET" },
    .command = Commands(.{
        .start = Command(CommandMeta{ .help = "Start." }, .{
            .name = Argument([]const u8){ .help = "Name." },
        }),
        .stop = Command(CommandMeta{ .name = "halt", .help = "Stop." }, .{}),
    }),
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

test "M9: help text renders header, sections, commands and arguments" {
    const expected =
        \\Usage: app --dry-run --host=HOST <path> <TARGET> [flags]
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
        \\Commands:
        \\  start    Start.
        \\  halt     Stop.
        \\
    ;
    const h = try M9.helpText(std.testing.allocator);
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
        .flag = Option(bool){ .default = Default(bool){ .direct = false } },
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

    // Ungrouped options first, then the named group.
    try std.testing.expectEqual(@as(usize, 2), data.option_groups.len);
    try std.testing.expect(data.option_groups[0].name == null);
    try std.testing.expectEqualStrings("Server settings", data.option_groups[1].name.?);

    const ungrouped = data.option_groups[0].options;
    try std.testing.expectEqual(@as(usize, 4), ungrouped.len);

    // Injected builtin help flag comes first, before every user option.
    try std.testing.expectEqualStrings("help", ungrouped[0].name);
    try std.testing.expectEqualStrings("h", ungrouped[0].short.?);
    try std.testing.expectEqualStrings("false", ungrouped[0].default.?);
    try std.testing.expect(!ungrouped[0].takes_value);

    try std.testing.expectEqualStrings("verbose", ungrouped[1].name);
    try std.testing.expectEqualStrings("v", ungrouped[1].short.?);
    try std.testing.expectEqualStrings("false", ungrouped[1].default.?);
    try std.testing.expect(!ungrouped[1].takes_value);

    // Required option: no default, no short.
    try std.testing.expectEqualStrings("dry-run", ungrouped[2].name);
    try std.testing.expect(ungrouped[2].short == null);
    try std.testing.expect(ungrouped[2].default == null);

    try std.testing.expectEqualStrings("port", ungrouped[3].name);
    try std.testing.expectEqualStrings("8080", ungrouped[3].default.?);
    try std.testing.expect(ungrouped[3].takes_value);

    try std.testing.expectEqual(@as(usize, 1), data.option_groups[1].options.len);
    try std.testing.expectEqualStrings("host", data.option_groups[1].options[0].name);

    try std.testing.expectEqual(@as(usize, 2), data.commands.len);
    try std.testing.expectEqualStrings("start", data.commands[0].name);
    try std.testing.expectEqualStrings("Start.", data.commands[0].help);
    try std.testing.expectEqualStrings("halt", data.commands[1].name);
    try std.testing.expectEqualStrings("Stop.", data.commands[1].help);

    // Arguments: both ungrouped, in declaration order, names from `.name`.
    try std.testing.expectEqual(@as(usize, 1), data.arg_groups.len);
    try std.testing.expect(data.arg_groups[0].name == null);
    try std.testing.expectEqual(@as(usize, 2), data.arg_groups[0].args.len);
    try std.testing.expectEqualStrings("path", data.arg_groups[0].args[0].name);
    try std.testing.expect(data.arg_groups[0].args[0].default == null);
    try std.testing.expectEqualStrings("TARGET", data.arg_groups[0].args[1].name);
}

test "M9: helpData groups arguments and renders custom defaults" {
    const HMode = Enumeration(.{
        .fast = Enum{},
        .slow = Enum{},
    });
    const def = .{
        .mode = Option(HMode){
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
    // occupies slot 0 of the ungrouped options.
    try std.testing.expectEqualStrings("help", data.option_groups[0].options[0].name);
    try std.testing.expectEqualStrings("slow", data.option_groups[0].options[1].default.?);

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
        .source = Option([]const u8){
            .default = Default([]const u8){ .direct = "." },
            .help = "Source directory.",
        },
        .last = Option(bool){
            .short = "l",
            .default = Default(bool){ .direct = false },
            .help = "Show last modification.",
        },
        .grp = Group(.{
            .count = Option(isize){
                .default = Default(isize){ .direct = 1 },
                .help = "Number of items.",
            },
            .value = Option(isize){
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
            .z = Option(bool){ .default = Default(bool){ .direct = false }, .help = "Z." },
        }, "zeta"),
        .alpha = Group(.{
            .a = Option(bool){ .default = Default(bool){ .direct = false }, .help = "A." },
        }, "alpha"),
        .plain = Option(bool){ .default = Default(bool){ .direct = false }, .help = "Plain." },
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

test "M9: renderCompact lists commands and marks required options in usage" {
    const def = .{
        .needed = Option([]const u8){
            .short = "n",
            .help = "Required.",
        },
        .opt = Option(u8){
            .default = Default(u8){ .direct = 3 },
            .help = "Optional.",
        },
        .cmd = Commands(.{
            .start = Command(CommandMeta{ .help = "Start." }, .{}),
            .stop = Command(CommandMeta{ .help = "Stop." }, .{}),
        }),
    };
    const CLI = generate(App{ .name = "app", .help = "", .help_renderer = .{ .highlight = .{ .flat = {} } } }, def);

    const expected =
        \\Usage: app --needed=NEEDED [flags]
        \\
        \\Flags:
        \\  -h, --help             Show context-sensitive help.
        \\  -n, --needed=NEEDED    Required.
        \\      --opt=3            Optional.
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
    .verbose = Option(bool){
        .short = "v",
        .default = Default(bool){ .direct = false },
        .help = "Verbose output.",
    },
    .needed = Option([]const u8){ .help = "Required." },
    .path = Argument([]const u8){ .help = "Path." },
};

const M10 = generate(App{ .name = "m10", .help = "M10." }, M10Def);

fn m10RenderMinimal(_: *const HelpData, allocator: std.mem.Allocator) std.mem.Allocator.Error!String {
    return try allocator.dupe(u8, "custom renderer");
}

test "M10: builtin help flag parses like a plain bool option" {
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
    try std.testing.expectError(error.UnknownOption, M10.parseInner(arena.allocator(), std.process.Environ.empty, &.{"--nope"}, &diag2));
}

test "M10: a user-declared --help clashes with the injected builtin" {
    if (false) {
        const Bad = .{
            .help = Option(bool){ .long = "help" },
        };
        _ = normalize(withBuiltinHelp(Bad));
    }
}

test "M10: helpText follows the compact renderer by default" {
    const h = try M10.helpText(std.testing.allocator);
    defer std.testing.allocator.free(h);
    // The default highlight is `.bold`, so names carry the bold/reset codes.
    try std.testing.expect(std.mem.indexOf(u8, h, "-\x1b[1mh\x1b[0m, --\x1b[1mhelp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "Usage: \x1b[1mm10\x1b[0m") != null);
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

    const ungrouped = data.option_groups[0].options;
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

test "M11: bold wraps app, option and argument names" {
    const h = try renderWithHighlight(.{ .bold = {} }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "Usage: \x1b[1mapp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "--\x1b[1mhelp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1mServer settings\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<\x1b[1mpath\x1b[0m>") != null);
}

test "M11: color uses the per-category codes" {
    const h = try renderWithHighlight(.{ .color = {} }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    // App name: bold + green; option name: green; argument name: cyan; group:
    // bold + blue.
    try std.testing.expect(std.mem.indexOf(u8, h, "Usage: \x1b[1m\x1b[32mapp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "--\x1b[32mhelp\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "\x1b[1m\x1b[34mServer settings\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<\x1b[36mpath\x1b[0m>") != null);
}

test "M11: a custom highlight scheme is used verbatim" {
    const custom = HelpHighlight{
        .app_name = "<a>",
        .option_name = "<o>",
        .arg_name = "<g>",
        .group_name = "<G>",
        .help_text = "<h>",
        .reset = "</>",
    };
    const h = try renderWithHighlight(.{ .custom = custom }, std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "Usage: <a>app</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<o>help</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<G>Server settings</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<g>path</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<h>Host.</>") != null);
}

test "M11: HelpHighlight.resolve maps the ready profiles" {
    try std.testing.expectEqualStrings("", HelpHighlight.resolve(.{ .flat = {} }).option_name);
    try std.testing.expectEqualStrings("\x1b[1m", HelpHighlight.resolve(.{ .bold = {} }).option_name);
    try std.testing.expectEqualStrings("\x1b[32m", HelpHighlight.resolve(.{ .color = {} }).option_name);
    const c = HelpHighlight{ .option_name = "X" };
    try std.testing.expectEqualStrings("X", HelpHighlight.resolve(.{ .custom = c }).option_name);
}
