//! Declaration composition.
//!
//! [`Compose.shift`] returns a structurally identical declaration whose flag
//! long names carry a prefix and whose flags lost their short names;
//! [`Compose.concat`] merges two declarations into one. Both return declaration
//! *values* with an inferred type, so they feed `generate` directly:
//!
//! ```
//! const lib = .{ .port = dap.Flag(u16){ .short = "p" } };
//! const CLI = dap.generate(app, dap.Compose.shift(lib, "db-"));
//! // --db-port is declared, -p is not
//! ```
//!
//! Composition happens at comptime, before `generate` injects the builtin
//! `-h, --help` flag, so the builtin is never prefixed.

const std = @import("std");
const dap = @import("dap.zig");
const checks = @import("checks.zig");

const Field = checks.Field;
const fieldsOf = checks.fieldsOf;
const typeOfField = checks.typeOfField;

const String = dap.String;
const Group = dap.Group;
const Alt = dap.Alt;
const VariantNamed = dap.VariantNamed;
const Command = dap.Command;

pub const Compose = struct {
    /// Prefix every flag long name in `decl` with `prefix` and drop every short
    /// name. Flags are rewritten at the top level, inside `Group`s, inside
    /// `Alt` branches (plain and [`dap.VariantNamed`]) and recursively inside
    /// `Command` bodies. Field names, group names, `Alt` branch tags, command
    /// wire names, arguments, defaults, validations, help/i18n strings and
    /// completion predictors are preserved.
    ///
    /// The prefix is concatenated verbatim (no separator is inserted), so
    /// `shift(decl, "remote-")` yields `--remote-port`. It must be non-empty and
    /// spell a long flag name, optionally followed by a single `-`; otherwise
    /// the call is a compile error. An implicit long name (derived from the
    /// field name) becomes explicit in the result.
    ///
    /// ```
    /// const shifted = dap.Compose.shift(.{
    ///     .port = dap.Flag(u16){ .short = "p" },
    /// }, "db-");
    /// // shifted.port.long == "db-port", shifted.port.short == null
    /// ```
    pub fn shift(comptime decl: anytype, comptime prefix: []const u8) Shifted(decl, prefix) {
        comptime var out: Shifted(decl, prefix) = undefined;
        inline for (fieldsOf(@TypeOf(decl))) |f| {
            @field(out, f.name) = ShiftValue(decl, f.name, prefix).value;
        }
        return out;
    }

    /// Concatenate two declarations. `left`'s fields come first, `right`'s
    /// after it; that order fixes `View` field order, help order and positional
    /// argument order. `concat(.{}, decl)` and `concat(decl, .{})` are
    /// identities.
    ///
    /// Fields pair by declaration field name. A name declared by only one side
    /// is copied unchanged. A name declared by both sides is legal only when
    /// both are `Group(...)` with equal names or both are `Alt(...)`; the pair
    /// is then merged field by field (left members, then right members) into a
    /// single field that keeps the shared name and the left position. Every
    /// other same-named pair is a field-name clash.
    ///
    /// The pair is rejected at comptime when the two inputs collide on a field
    /// name, a long or short flag anywhere in their command trees, a command
    /// wire name or synonym, a positional argument display name, or an i18n
    /// key or the literal value it carries. Structural rules (commands mixed
    /// with arguments, a defaulted argument that stops being last, `Alt`
    /// member restrictions) stay `generate`'s business.
    ///
    /// ```
    /// const a = .{ .port = dap.Flag(u16){} };
    /// const b = .{ .host = dap.Flag([]const u8){} };
    /// const CLI = dap.generate(app, dap.Compose.concat(a, b));
    /// // --port and --host are both declared
    /// ```
    pub fn concat(comptime left: anytype, comptime right: anytype) Concat(left, right) {
        const plan = comptime checks.concatPlan(left, right);
        comptime var out: Concat(left, right) = undefined;
        inline for (plan) |entry| {
            @field(out, entry.name) = ConcatValue(left, right, entry.op, entry.name).value;
        }
        return out;
    }
};

/// Holder for one shifted field value; keeps the address stable so the field's
/// `default_value_ptr` can point at it.
fn ShiftValue(comptime decl: anytype, comptime name: []const u8, comptime prefix: []const u8) type {
    return struct {
        pub const value = shiftFieldValue(@field(decl, name), name, prefix);
    };
}

fn isFlagType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "dap_kind") and T.dap_kind == .flag;
}

fn isOptionalFlagType(comptime T: type) bool {
    if (@typeInfo(T) != .optional) return false;
    return isFlagType(@typeInfo(T).optional.child);
}

fn shiftedFlag(comptime value: anytype, comptime name: []const u8, comptime prefix: []const u8) @TypeOf(value) {
    comptime var out: @TypeOf(value) = value;
    out.long = prefix ++ (value.long orelse name);
    out.short = null;
    return out;
}

/// The shifted value of one declaration field. The explicit `@TypeOf(value)`
/// return type is required: without it peer resolution over the `type`,
/// `Flag(T)` and `?Flag(T)` branches unifies the holder as `type`.
fn shiftFieldValue(comptime value: anytype, comptime name: []const u8, comptime prefix: []const u8) @TypeOf(value) {
    const T = @TypeOf(value);
    if (T == type) return shiftNode(value, prefix);
    if (isFlagType(T)) return shiftedFlag(value, name, prefix);
    if (isOptionalFlagType(T)) return if (value) |inner| shiftedFlag(inner, name, prefix) else null;
    return value;
}

fn shiftNode(comptime V: type, comptime prefix: []const u8) type {
    return switch (V.dap_kind) {
        .group => Group(Compose.shift(V.group_def, prefix), V.group_name),
        .alt => Alt(shiftAltDef(V.alt_def, prefix)),
        .command => Command(V.cmd_meta, Compose.shift(V.cmd_def, prefix)),
        else => @compileError("dap.Compose.shift: unsupported type-valued declaration field"),
    };
}

fn Shifted(comptime decl: anytype, comptime prefix: []const u8) type {
    comptime checks.checkPrefix(prefix);
    const fields = fieldsOf(@TypeOf(decl));
    const names = blk: {
        var a: [fields.len][:0]const u8 = undefined;
        for (fields, 0..) |f, i| a[i] = f.name;
        break :blk a;
    };
    const types = blk: {
        var a: [fields.len]type = undefined;
        for (fields, 0..) |f, i| a[i] = f.type;
        break :blk a;
    };
    const attrs = blk: {
        var a: [fields.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (fields, 0..) |f, i| {
            a[i] = .{
                .@"comptime" = f.attrs.@"comptime",
                .@"align" = f.attrs.@"align",
                .default_value_ptr = @ptrCast(&ShiftValue(decl, f.name, prefix).value),
            };
        }
        break :blk a;
    };
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// The shifted branch dictionary of an `Alt`. Plain branches are struct values,
/// so their shifted field type is `Shifted(branch, prefix)`; a
/// [`dap.VariantNamed`] branch stays a `type` carrying the rebuilt variant.
fn ShiftedAltDict(comptime dict: anytype, comptime prefix: []const u8) type {
    const fields = fieldsOf(@TypeOf(dict));
    const names = blk: {
        var a: [fields.len][:0]const u8 = undefined;
        for (fields, 0..) |f, i| a[i] = f.name;
        break :blk a;
    };
    const types = blk: {
        var a: [fields.len]type = undefined;
        for (fields, 0..) |f, i| {
            const Bv = @field(dict, f.name);
            a[i] = if (isVariantNamed(Bv)) type else Shifted(Bv, prefix);
        }
        break :blk a;
    };
    const attrs = blk: {
        var a: [fields.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (fields, 0..) |f, i| {
            a[i] = .{
                .@"comptime" = f.attrs.@"comptime",
                .@"align" = f.attrs.@"align",
                .default_value_ptr = @ptrCast(&AltBranchValue(dict, f.name, prefix).value),
            };
        }
        break :blk a;
    };
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn isVariantNamed(comptime value: anytype) bool {
    return @TypeOf(value) == type and @hasDecl(value, "dap_variant_name") and @hasDecl(value, "dap_variant_def");
}

/// Holder for one shifted `Alt` branch.
fn AltBranchValue(comptime dict: anytype, comptime name: []const u8, comptime prefix: []const u8) type {
    const Bv = @field(dict, name);
    if (isVariantNamed(Bv)) {
        return struct {
            pub const value = VariantNamed(Bv.dap_variant_name, Compose.shift(Bv.dap_variant_def, prefix));
        };
    }
    return struct {
        pub const value = Compose.shift(Bv, prefix);
    };
}

fn shiftAltDef(comptime dict: anytype, comptime prefix: []const u8) ShiftedAltDict(dict, prefix) {
    const fields = fieldsOf(@TypeOf(dict));
    comptime var out: ShiftedAltDict(dict, prefix) = undefined;
    inline for (fields) |f| {
        @field(out, f.name) = AltBranchValue(dict, f.name, prefix).value;
    }
    return out;
}

/// Holder for one field value of a `concat` result.
fn ConcatValue(
    comptime left: anytype,
    comptime right: anytype,
    comptime op: checks.FieldOp,
    comptime name: [:0]const u8,
) type {
    return switch (op) {
        .copy_left => struct {
            pub const value = @field(left, name);
        },
        .copy_right => struct {
            pub const value = @field(right, name);
        },
        .merge_group => struct {
            pub const value = mergeGroup(@field(left, name), @field(right, name));
        },
        .merge_alt => struct {
            pub const value = mergeAlt(@field(left, name), @field(right, name));
        },
    };
}

fn fieldByName(comptime fields: anytype, comptime name: []const u8) Field {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    unreachable;
}

/// The declaration field a `concat` result field copies its type and
/// attributes from: the right input for `copy_right`, the left input otherwise
/// (merged fields keep the left position).
fn concatSourceField(comptime left: anytype, comptime right: anytype, comptime entry: checks.FieldPlan) Field {
    return switch (entry.op) {
        .copy_right => fieldByName(fieldsOf(@TypeOf(right)), entry.name),
        else => fieldByName(fieldsOf(@TypeOf(left)), entry.name),
    };
}

fn Concat(comptime left: anytype, comptime right: anytype) type {
    const plan = comptime checks.concatPlan(left, right);
    const names = blk: {
        var a: [plan.len][:0]const u8 = undefined;
        for (plan, 0..) |entry, i| a[i] = entry.name;
        break :blk a;
    };
    const types = blk: {
        var a: [plan.len]type = undefined;
        for (plan, 0..) |entry, i| a[i] = concatSourceField(left, right, entry).type;
        break :blk a;
    };
    const attrs = blk: {
        var a: [plan.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (plan, 0..) |entry, i| {
            const source = concatSourceField(left, right, entry);
            a[i] = .{
                .@"comptime" = source.attrs.@"comptime",
                .@"align" = source.attrs.@"align",
                .default_value_ptr = @ptrCast(&ConcatValue(left, right, entry.op, entry.name).value),
            };
        }
        break :blk a;
    };
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn mergeGroup(comptime l: type, comptime r: type) type {
    return Group(mergeDict(l.group_def, r.group_def), l.group_name);
}

fn mergeAlt(comptime l: type, comptime r: type) type {
    return Alt(mergeDict(l.alt_def, r.alt_def));
}

/// Concatenate two definition structs (a group body or an `Alt` dictionary)
/// left then right. Field types and values are unchanged, so each side's field
/// attributes are copied verbatim.
fn MergedDict(comptime L: type, comptime R: type) type {
    const lf = fieldsOf(L);
    const rf = fieldsOf(R);
    const names = blk: {
        var a: [lf.len + rf.len][:0]const u8 = undefined;
        for (lf, 0..) |f, i| a[i] = f.name;
        for (rf, 0..) |f, i| a[lf.len + i] = f.name;
        break :blk a;
    };
    const types = blk: {
        var a: [lf.len + rf.len]type = undefined;
        for (lf, 0..) |f, i| a[i] = f.type;
        for (rf, 0..) |f, i| a[lf.len + i] = f.type;
        break :blk a;
    };
    const attrs = blk: {
        var a: [lf.len + rf.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (lf, 0..) |f, i| {
            a[i] = .{
                .@"comptime" = f.attrs.@"comptime",
                .@"align" = f.attrs.@"align",
                .default_value_ptr = f.attrs.default_value_ptr,
            };
        }
        for (rf, 0..) |f, i| {
            a[lf.len + i] = .{
                .@"comptime" = f.attrs.@"comptime",
                .@"align" = f.attrs.@"align",
                .default_value_ptr = f.attrs.default_value_ptr,
            };
        }
        break :blk a;
    };
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn mergeDict(comptime l: anytype, comptime r: anytype) MergedDict(@TypeOf(l), @TypeOf(r)) {
    comptime var out: MergedDict(@TypeOf(l), @TypeOf(r)) = undefined;
    inline for (fieldsOf(@TypeOf(l))) |f| @field(out, f.name) = @field(l, f.name);
    inline for (fieldsOf(@TypeOf(r))) |f| @field(out, f.name) = @field(r, f.name);
    return out;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const Flag = dap.Flag;
const Argument = dap.Argument;
const App = dap.App;

const ShiftLib = .{
    .port = Flag(u16){ .short = "p", .help = "Port." },
    .user = Flag(String){ .long = "user-name", .short = "u", .i18n = "flag_user" },
    .token = dap.Optional(Flag(String){ .long = "token", .short = "t" }),
    .extra = Flag(u8){
        .short = "e",
        .default = dap.Default(u8){ .direct = 3 },
        .validation = dap.Validate.intNotZero(u8),
        .completion = dap.Completion.call("echo x"),
        .help = "Extra.",
    },
    .src = Argument(String){ .name = "SRC", .help = "Source." },
    .network = Group(.{
        .host = Flag(String){ .short = "H", .help = "Host." },
        .retries = Flag(u8){ .short = "r" },
    }, "network"),
    .speed = Alt(.{
        .fast = .{ .fast = Flag(u8){ .short = "f" } },
        .slow = VariantNamed("careful", .{ .dry = Flag(bool){ .short = "d" } }),
    }),
    .serve = Command(.{ .name = "serve", .synonym = "srv", .help = "Serve." }, .{
        .inner = Flag(u32){ .short = "i" },
    }),
};

test "Compose.shift rewrites long names, drops shorts, preserves the rest" {
    const shifted = Compose.shift(ShiftLib, "db-");

    try std.testing.expectEqualStrings("db-port", shifted.port.long.?);
    try std.testing.expect(shifted.port.short == null);
    try std.testing.expectEqualStrings("Port.", shifted.port.help);

    try std.testing.expectEqualStrings("db-user-name", shifted.user.long.?);
    try std.testing.expect(shifted.user.short == null);
    try std.testing.expectEqualStrings("flag_user", shifted.user.i18n.?);

    try std.testing.expectEqualStrings("db-token", shifted.token.?.long.?);
    try std.testing.expect(shifted.token.?.short == null);
    try std.testing.expect(@typeInfo(@TypeOf(shifted.token)) == .optional);

    try std.testing.expectEqualStrings("db-extra", shifted.extra.long.?);
    try std.testing.expect(shifted.extra.short == null);
    try std.testing.expectEqual(@as(u8, 3), shifted.extra.default.?.direct.?);
    try std.testing.expect(shifted.extra.validation != null);
    try std.testing.expect(shifted.extra.completion != null);
    try std.testing.expectEqualStrings("Extra.", shifted.extra.help);

    try std.testing.expectEqualStrings("SRC", shifted.src.name.?);
    try std.testing.expectEqualStrings("Source.", shifted.src.help);

    try std.testing.expectEqualStrings("network", shifted.network.group_name);
    try std.testing.expectEqualStrings("db-host", shifted.network.group_def.host.long.?);
    try std.testing.expect(shifted.network.group_def.host.short == null);
    try std.testing.expectEqualStrings("db-retries", shifted.network.group_def.retries.long.?);

    try std.testing.expectEqualStrings("fast", shifted.speed.tag_names[0]);
    try std.testing.expectEqualStrings("careful", shifted.speed.tag_names[1]);
    try std.testing.expectEqualStrings("db-fast", shifted.speed.alt_def.fast.fast.long.?);
    try std.testing.expectEqualStrings("db-dry", shifted.speed.alt_def.slow.dap_variant_def.dry.long.?);

    try std.testing.expectEqualStrings("serve", shifted.serve.cmd_meta.name.?);
    try std.testing.expectEqualStrings("srv", shifted.serve.cmd_meta.synonym.?);
    try std.testing.expectEqualStrings("db-inner", shifted.serve.cmd_def.inner.long.?);
}

test "Compose.shift is prefix-outer" {
    const twice = Compose.shift(Compose.shift(.{ .x = Flag(u8){ .long = "x" } }, "a-"), "b-");
    try std.testing.expectEqualStrings("b-a-x", twice.x.long.?);
}

test "Compose.shift leaves an empty declaration empty and usable" {
    const empty = Compose.shift(.{}, "db-");
    try std.testing.expectEqual(@as(usize, 0), fieldsOf(@TypeOf(empty)).len);
}

test "Compose.shift end to end: generate, parse, help" {
    const shifted = Compose.shift(.{
        .port = Flag(u16){ .short = "p" },
        .network = Group(.{ .host = Flag(String){} }, "network"),
        .speed = Alt(.{ .fast = .{ .n = Flag(u8){} } }),
    }, "db-");
    const CLI = dap.generate(App{ .name = "shifted", .help = "Shifted." }, shifted);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: dap.Diag = .{};
    defer diag.deinit(a);

    var view = try CLI.parse(a, std.process.Environ.empty, null, &.{ "--db-port", "80", "--db-host", "h", "--db-n", "2" }, &diag);
    defer CLI.deinit(&view, a);
    try std.testing.expectEqual(@as(u16, 80), view.port);
    try std.testing.expectEqualStrings("h", view.host);
    try std.testing.expectEqual(@as(u8, 2), view.speed.?.fast.n);

    const help = try CLI.helpText(a);
    try std.testing.expect(std.mem.indexOf(u8, help, "--db-port=") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--db-host=") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--port=") == null);
}

test "Compose.concat preserves left-then-right field order" {
    const a = .{ .one = Flag(u8){}, .two = Flag(u8){} };
    const b = .{ .three = Flag(u8){}, .four = Flag(u8){} };
    const merged = Compose.concat(a, b);
    const fields = fieldsOf(@TypeOf(merged));
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqualStrings("one", fields[0].name);
    try std.testing.expectEqualStrings("two", fields[1].name);
    try std.testing.expectEqualStrings("three", fields[2].name);
    try std.testing.expectEqualStrings("four", fields[3].name);
    try std.testing.expectEqual(Flag(u8), @TypeOf(merged.three));
}

test "Compose.concat preserves i18n keys" {
    const a = .{ .user = Flag(String){ .i18n = "flag_user" } };
    const b = .{ .host = Flag(String){ .help = "Host." } };
    const merged = Compose.concat(a, b);
    try std.testing.expectEqualStrings("flag_user", merged.user.i18n.?);
    try std.testing.expect(merged.host.i18n == null);
}

test "Compose.concat identities and associativity" {
    const decl = .{ .port = Flag(u16){}, .src = Argument(String){} };

    const left_empty = Compose.concat(.{}, decl);
    try std.testing.expectEqual(Flag(u16), @TypeOf(left_empty.port));

    const right_empty = Compose.concat(decl, .{});
    try std.testing.expectEqual(Flag(u16), @TypeOf(right_empty.port));

    const empty = Compose.concat(.{}, .{});
    try std.testing.expectEqual(@as(usize, 0), fieldsOf(@TypeOf(empty)).len);

    const x = Compose.concat(.{ .a = Flag(u8){} }, .{ .b = Flag(u8){} });
    const y = Compose.concat(.{ .c = Flag(u8){} }, .{ .d = Flag(u8){} });
    const left_assoc = Compose.concat(Compose.concat(x, y), .{ .e = Flag(u8){} });
    const right_assoc = Compose.concat(x, Compose.concat(y, .{ .e = Flag(u8){} }));
    const lf = fieldsOf(@TypeOf(left_assoc));
    const rf = fieldsOf(@TypeOf(right_assoc));
    try std.testing.expectEqual(lf.len, rf.len);
    inline for (lf, rf) |l, r| try std.testing.expectEqualStrings(l.name, r.name);
}

test "Compose.concat merges same-named groups field by field" {
    const a = .{ .net = Group(.{ .port = Flag(u16){} }, "network") };
    const b = .{ .net = Group(.{ .host = Flag(String){} }, "network") };
    const merged = Compose.concat(a, b);

    const def = merged.net.group_def;
    try std.testing.expectEqualStrings("network", merged.net.group_name);
    const fields = fieldsOf(@TypeOf(def));
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("port", fields[0].name);
    try std.testing.expectEqualStrings("host", fields[1].name);
}

test "Compose.concat merges same-named Alts branch by branch" {
    const a = .{ .speed = Alt(.{ .fast = .{ .n = Flag(u8){} } }) };
    const b = .{ .speed = Alt(.{ .slow = VariantNamed("careful", .{ .dry = Flag(bool){} }) }) };
    const merged = Compose.concat(a, b);

    try std.testing.expectEqualStrings("fast", merged.speed.tag_names[0]);
    try std.testing.expectEqualStrings("careful", merged.speed.tag_names[1]);
    const branches = fieldsOf(@TypeOf(merged.speed.alt_def));
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("fast", branches[0].name);
    try std.testing.expectEqualStrings("slow", branches[1].name);
}

test "Compose.concat keeps same-named groups apart when field names differ" {
    const a = .{ .net = Group(.{ .port = Flag(u16){} }, "network") };
    const b = .{ .other = Group(.{ .host = Flag(String){} }, "network") };
    const merged = Compose.concat(a, b);
    try std.testing.expectEqual(Flag(u16), @TypeOf(merged.net.group_def.port));
    try std.testing.expectEqual(Flag(String), @TypeOf(merged.other.group_def.host));
}

test "Compose.concat end to end: generate, parse, merged help" {
    const a = .{
        .port = Flag(u16){ .short = "p" },
        .net = Group(.{ .host = Flag(String){} }, "network"),
        .speed = Alt(.{ .fast = .{ .n = Flag(u8){} } }),
        .build = Command(.{ .help = "Build." }, .{ .jobs = Flag(u8){} }),
    };
    const b = .{
        .verbose = Flag(bool){ .short = "v" },
        .net = Group(.{ .retries = Flag(u8){} }, "network"),
        .speed = Alt(.{ .slow = VariantNamed("careful", .{ .dry = Flag(bool){} }) }),
        .serve = Command(.{ .help = "Serve." }, .{ .addr = Flag(String){} }),
    };
    const merged = Compose.concat(a, b);
    const CLI = dap.generate(App{ .name = "concat", .help = "Concat." }, merged);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var diag: dap.Diag = .{};
    defer diag.deinit(al);

    var view = try CLI.parse(al, std.process.Environ.empty, null, &.{
        "--port",    "80",    "--host", "h", "--retries", "3",
        "--verbose", "--dry",
    }, &diag);
    defer CLI.deinit(&view, al);
    try std.testing.expectEqual(@as(u16, 80), view.port);
    try std.testing.expectEqualStrings("h", view.host);
    try std.testing.expectEqual(@as(u8, 3), view.retries);
    try std.testing.expect(view.verbose);
    try std.testing.expect(view.speed.?.careful.dry);

    const help = try CLI.helpText(al);
    try std.testing.expect(std.mem.indexOf(u8, help, "--port=") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--retries=") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "careful") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "build") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "serve") != null);
}

test "Compose.concat keeps duplicate group names legal and merges their help" {
    const a = .{ .net = Group(.{ .port = Flag(u16){} }, "network") };
    const b = .{ .other = Group(.{ .host = Flag(String){} }, "network") };
    const CLI = dap.generate(App{ .name = "groups", .help = "" }, Compose.concat(a, b));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const help = try CLI.helpText(al);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, help, "network"));
    try std.testing.expect(std.mem.indexOf(u8, help, "--port=") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--host=") != null);
}

test "Compose.concat rejects field name clashes" {
    if (false) {
        const a = .{ .port = Flag(u16){} };
        const b = .{ .port = Flag(u32){} };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects a non-mergeable same-name pair" {
    if (false) {
        const a = .{ .x = Group(.{ .a = Flag(u8){} }, "g") };
        const b = .{ .x = Flag(u8){} };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects a group name conflict" {
    if (false) {
        const a = .{ .g = Group(.{ .a = Flag(u8){} }, "one") };
        const b = .{ .g = Group(.{ .b = Flag(u8){} }, "two") };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects duplicate members inside a merged group" {
    if (false) {
        const a = .{ .g = Group(.{ .port = Flag(u16){} }, "g") };
        const b = .{ .g = Group(.{ .port = Flag(u32){} }, "g") };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects duplicate branch field names in a merged Alt" {
    if (false) {
        const a = .{ .x = Alt(.{ .fast = .{ .a = Flag(u8){} } }) };
        const b = .{ .x = Alt(.{ .fast = .{ .b = Flag(u8){} } }) };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects duplicate tags in a merged Alt" {
    if (false) {
        const a = .{ .x = Alt(.{ .fast = .{ .a = Flag(u8){} } }) };
        const b = .{ .x = Alt(.{ .other = VariantNamed("fast", .{ .b = Flag(u8){} }) }) };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects flag clashes anywhere in the trees" {
    if (false) {
        // Still a rejection, now for the chain reason: a command level is a
        // descendant of the root level, and `port` is reused there.
        const a = .{ .serve = Command(.{ .help = "" }, .{ .port = Flag(u16){ .long = "port" } }) };
        const b = .{ .net = Group(.{ .p = Flag(u16){ .long = "port" } }, "net") };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat allows sibling subtrees to reuse a flag spelling" {
    const a = .{ .one = Command(.{ .help = "One." }, .{
        .same = Flag(u8){ .long = "same", .default = dap.Default(u8){ .direct = 1 } },
    }) };
    const b = .{ .two = Command(.{ .help = "Two." }, .{
        .same = Flag(u8){ .long = "same", .default = dap.Default(u8){ .direct = 2 } },
    }) };
    const CLI = dap.generate(App{ .name = "siblings", .help = "" }, Compose.concat(a, b));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var one_diag: dap.Diag = .{};
    defer one_diag.deinit(al);
    var one = try CLI.parse(al, std.process.Environ.empty, null, &.{"one"}, &one_diag);
    defer CLI.deinit(&one, al);
    try std.testing.expectEqual(@as(u8, 1), one._one.?.same);
    try std.testing.expect(one._two == null);

    var two_diag: dap.Diag = .{};
    defer two_diag.deinit(al);
    var two = try CLI.parse(al, std.process.Environ.empty, null, &.{"two"}, &two_diag);
    defer CLI.deinit(&two, al);
    try std.testing.expectEqual(@as(u8, 2), two._two.?.same);
    try std.testing.expect(two._one == null);

    const help = try CLI.helpText(al);
    try std.testing.expect(std.mem.indexOf(u8, help, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "two") != null);
}

test "Compose.concat rejects a command flag reused at the root" {
    if (false) {
        // The root level is an ancestor of every command, so `x` is reused
        // along a chain.
        const a = .{ .c = Command(.{ .help = "" }, .{ .xl = Flag(u8){ .long = "x" } }) };
        const b = .{ .xr = Flag(u8){ .long = "x" } };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects a group member reused at the root" {
    if (false) {
        // Group members live on the enclosing declaration's level, so both
        // flags land on the root level and clash on the `flag name` class.
        const a = .{ .g = Group(.{ .xl = Flag(u8){ .long = "x" } }, "G") };
        const b = .{ .xr = Flag(u32){ .long = "x" } };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects an Alt member reused at the root" {
    if (false) {
        const a = .{ .a = Alt(.{ .on = .{ .xl = Flag(u8){ .long = "x" } } }) };
        const b = .{ .xr = Flag(u32){ .long = "x" } };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat allows flag reuse across sibling commands" {
    const a = .{ .c = Command(.{ .help = "C." }, .{ .xl = Flag(u8){ .long = "x", .default = dap.Default(u8){ .direct = 5 } } }) };
    const b = .{ .d = Command(.{ .help = "D." }, .{ .xr = Flag(u8){ .long = "x", .default = dap.Default(u8){ .direct = 6 } } }) };
    const CLI = dap.generate(App{ .name = "siblings", .help = "" }, Compose.concat(a, b));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var c_diag: dap.Diag = .{};
    defer c_diag.deinit(al);
    var c = try CLI.parse(al, std.process.Environ.empty, null, &.{"c"}, &c_diag);
    defer CLI.deinit(&c, al);
    try std.testing.expectEqual(@as(u8, 5), c._c.?.xl);
    try std.testing.expect(c._d == null);

    var d_diag: dap.Diag = .{};
    defer d_diag.deinit(al);
    var d = try CLI.parse(al, std.process.Environ.empty, null, &.{"d"}, &d_diag);
    defer CLI.deinit(&d, al);
    try std.testing.expectEqual(@as(u8, 6), d._d.?.xr);
    try std.testing.expect(d._c == null);
}

test "Compose.concat allows a group member on one sibling and a flag on another" {
    const a = .{ .c = Command(.{ .help = "C." }, .{
        .g = Group(.{ .xl = Flag(u8){ .long = "x", .default = dap.Default(u8){ .direct = 7 } } }, "G"),
    }) };
    const b = .{ .d = Command(.{ .help = "D." }, .{
        .xr = Flag(u8){ .long = "x", .default = dap.Default(u8){ .direct = 8 } },
    }) };
    const CLI = dap.generate(App{ .name = "siblings", .help = "" }, Compose.concat(a, b));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var c_diag: dap.Diag = .{};
    defer c_diag.deinit(al);
    var c = try CLI.parse(al, std.process.Environ.empty, null, &.{"c"}, &c_diag);
    defer CLI.deinit(&c, al);
    try std.testing.expectEqual(@as(u8, 7), c._c.?.xl);

    var d_diag: dap.Diag = .{};
    defer d_diag.deinit(al);
    var d = try CLI.parse(al, std.process.Environ.empty, null, &.{"d"}, &d_diag);
    defer CLI.deinit(&d, al);
    try std.testing.expectEqual(@as(u8, 8), d._d.?.xr);
}

test "Compose.concat rejects command name clashes" {
    if (false) {
        const a = .{ .build = Command(.{ .help = "" }, .{ .x = Flag(u8){} }) };
        const b = .{ .other = Command(.{ .name = "build", .help = "" }, .{ .y = Flag(u8){} }) };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects argument display name clashes" {
    if (false) {
        const a = .{ .src = Argument(String){} };
        const b = .{ .other = Argument(String){ .name = "src" } };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat accepts distinct i18n keys and values" {
    const a = .{ .user = Flag(String){ .help = "User.", .i18n = "flag_user" } };
    const b = .{ .host = Flag(String){ .help = "Host.", .i18n = "flag_host" } };
    const merged = Compose.concat(a, b);
    try std.testing.expectEqualStrings("flag_user", merged.user.i18n.?);
    try std.testing.expectEqualStrings("flag_host", merged.host.i18n.?);
}

test "Compose.concat rejects an i18n key reused across inputs" {
    if (false) {
        const a = .{ .port = Flag(u16){ .help = "Port.", .i18n = "key_port" } };
        const b = .{ .host = Flag(String){ .help = "Host.", .i18n = "key_port" } };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.concat rejects an i18n value reused across inputs" {
    if (false) {
        const a = .{ .port = Flag(u16){ .help = "Same.", .i18n = "key_port" } };
        const b = .{ .host = Flag(String){ .help = "Same.", .i18n = "key_host" } };
        comptime _ = Compose.concat(a, b);
    }
}

test "Compose.shift rejects an empty or malformed prefix" {
    if (false) {
        comptime _ = Compose.shift(.{ .x = Flag(u8){} }, "");
    }
    if (false) {
        comptime _ = Compose.shift(.{ .x = Flag(u8){} }, "a b");
    }
}
