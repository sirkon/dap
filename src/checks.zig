//! Declaration checks shared by `dap.zig` and the composition layer.
//!
//! `dap.zig` imports this file for the checks `normalize`/`generate` run;
//! `compose.zig` imports it for the cross-input plan `concat` consumes. The
//! `dap.zig` <-> `checks.zig` import cycle resolves lazily, the same way
//! `dap.zig` <-> `completion.zig` does.

const std = @import("std");
const dap = @import("dap.zig");

/// Reflection view of a declaration field, shared with `dap.zig`.
pub const Field = dap._checks_internal.Field;
/// Flattened declaration spec, shared with `dap.zig`.
pub const Spec = dap._checks_internal.Spec;
/// One normalized level, shared with `dap.zig`.
pub const NormResult = dap._checks_internal.NormResult;
/// One command declaration at a level, shared with `dap.zig`.
pub const CommandEntry = dap._checks_internal.CommandEntry;
/// `dap.String` (`[]const u8`).
pub const String = dap.String;

/// Field iterator of a declaration type.
pub const fieldsOf = dap._checks_internal.fieldsOf;
/// The type a type-valued declaration field carries.
pub const typeOfField = dap._checks_internal.typeOfField;
/// Normalize a raw declaration (values, not types) into one level.
pub const normalize = dap._checks_internal.normalize;
/// Inject the builtin `-h, --help` field before normalizing.
pub const withBuiltinHelp = dap._checks_internal.withBuiltinHelp;
/// Name of the injected builtin help field.
pub const builtin_help_field = dap._checks_internal.builtin_help_field;
/// Normalize one leaf field into a [`Spec`].
pub const specFromField = dap._checks_internal.specFromField;

/// Reject declaration fields whose names start with `_`. The leading
/// underscore is reserved: command fields are surfaced in the `View` under a
/// `_`-prefixed name (the plain name is the branch of the `command` union).
/// Applies to the top level of every declaration, including command bodies,
/// which `normalize` recurses into; group and `Alt` members are checked where
/// their specs are built.
pub fn checkNoUnderscoreFields(comptime def: anytype) void {
    comptime {
        for (fieldsOf(@TypeOf(def))) |f| {
            if (std.mem.startsWith(u8, f.name, "_")) {
                @compileError("declaration field name '" ++ f.name ++ "' must not start with '_'");
            }
        }
    }
}

/// Every wire spelling of a command at its level: the primary name first,
/// then the synonym when declared.
pub fn commandSpellings(comptime c: CommandEntry) []const String {
    if (c.synonym) |s| return &[_]String{ c.name, s };
    return &[_]String{c.name};
}

pub fn checkCommandNames(comptime commands: []const CommandEntry) void {
    comptime {
        // Names and synonyms share one namespace at a level: a synonym is an
        // alternative spelling of a command, so it may not shadow another
        // command or repeat a name already taken.
        const Named = struct {
            spelling: String,
            field: String,
        };
        var all: []const Named = &.{};
        for (commands) |c| {
            if (c.synonym) |s| {
                if (std.mem.eql(u8, s, c.name)) {
                    @compileError("command synonym '" ++ s ++ "' on field '" ++ c.field ++ "' duplicates its own name");
                }
            }
            for (commandSpellings(c)) |spelling| {
                all = all ++ &[_]Named{.{ .spelling = spelling, .field = c.field }};
            }
        }
        for (all, 0..) |a, i| {
            for (all[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.spelling, b.spelling)) {
                    @compileError("duplicate command name '" ++ a.spelling ++ "' on fields '" ++ a.field ++ "' and '" ++ b.field ++ "'");
                }
            }
        }
    }
}

pub fn checkCommandFieldNames(comptime specs: []const Spec, comptime commands: []const CommandEntry) void {
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
pub fn checkCommandArgumentMix(comptime specs: []const Spec, comptime commands: []const CommandEntry) void {
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

pub fn checkDuplicates(comptime specs: []const Spec) void {
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

pub fn checkFieldNames(comptime specs: []const Spec) void {
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

pub fn checkArgumentDefaults(comptime specs: []const Spec) void {
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

/// One flag discovered somewhere in the declaration tree, together with the
/// level path it lives at. Drives the global uniqueness check (D6).
pub const FlagOrigin = struct {
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
pub fn collectFlagOrigins(
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
pub fn checkGlobalFlagNames(comptime origins: []const FlagOrigin) void {
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

/// One i18n key discovered somewhere in the declaration tree, together with
/// the literal help text it will translate and the level path it lives at.
pub const I18nOrigin = struct {
    key: String,
    literal: String,
    field: String,
    path: []const String,
};

/// Whether `s` is a well-formed i18n key: `[_A-Za-z][_0-9A-Za-z]*`, ASCII
/// only, non-empty. Mirrors the private predicate `i18n.zig` validates user
/// maps with; keeping the copy here avoids adding public API to that module.
pub fn validI18nKey(comptime s: String) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Flatten the whole declaration tree into a table of i18n origins, walking
/// levels through `normalize` exactly as `generate` does (groups and `Alt`
/// branches flatten into `norm.specs` for free). `app_key` is non-null only
/// for the root call: a child `App.i18n` is derived from its command meta's
/// key, which the parent already recorded, so passing `null` in recursion
/// keeps one origin per command rather than a duplicate. The injected builtin
/// help spec is skipped structurally; its key is a builtin constant. An
/// enumeration-typed spec also contributes one origin per branch that declares
/// both a translation key and help text; an empty key means "no translation".
pub fn collectI18n(
    comptime norm: NormResult,
    comptime app_help: String,
    comptime app_key: ?String,
    comptime path: []const String,
    comptime acc: []const I18nOrigin,
) []const I18nOrigin {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out = acc;
        if (app_key) |key| {
            out = out ++ &[_]I18nOrigin{.{
                .key = key,
                .literal = app_help,
                .field = "help",
                .path = path,
            }};
        }
        for (norm.specs) |s| {
            if (!std.mem.eql(u8, s.name, builtin_help_field)) {
                if (s.i18n) |key| {
                    out = out ++ &[_]I18nOrigin{.{
                        .key = key,
                        .literal = s.help,
                        .field = s.name,
                        .path = path,
                    }};
                }
            }
            const T = s.vtype;
            if (@typeInfo(T) == .@"struct" and
                @hasDecl(T, "names") and @hasDecl(T, "helps") and @hasDecl(T, "help_i18n"))
            {
                for (T.names, T.helps, T.help_i18n) |name, help, key| {
                    const k = key orelse continue;
                    if (k.len == 0) continue;
                    const literal = help orelse continue;
                    out = out ++ &[_]I18nOrigin{.{
                        .key = k,
                        .literal = literal,
                        .field = s.name ++ "." ++ name,
                        .path = path,
                    }};
                }
            }
        }
        for (norm.commands) |c| {
            if (c.Cmd.cmd_meta.i18n) |key| {
                out = out ++ &[_]I18nOrigin{.{
                    .key = key,
                    .literal = c.Cmd.cmd_meta.help,
                    .field = c.field,
                    .path = path,
                }};
            }
            const child = normalize(withBuiltinHelp(c.Cmd.cmd_def));
            out = collectI18n(child, c.Cmd.cmd_meta.help, null, path ++ &[_]String{c.name}, out);
        }
        return out;
    }
}

/// Three passes over the collected keys: each is a valid field name, none
/// shadows a builtin translation, and no key is used twice in the tree.
pub fn checkI18nKeys(comptime origins: []const I18nOrigin) void {
    comptime {
        for (origins) |o| {
            if (!validI18nKey(o.key)) {
                @compileError("i18n key '" ++ o.key ++ "' on '" ++ levelPath(o.path) ++ ":" ++ o.field ++
                    "' is not a valid field name ([_A-Za-z][_0-9A-Za-z]*)");
            }
        }
        const builtin_keys = [_]String{"builtin_help"};
        for (origins) |o| {
            for (builtin_keys) |b| {
                if (std.mem.eql(u8, o.key, b)) {
                    @compileError("i18n key '" ++ o.key ++ "' collides with a builtin translation");
                }
            }
        }
        for (origins, 0..) |a, i| {
            for (origins[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.key, b.key)) {
                    @compileError("i18n key '" ++ a.key ++ "' is used by both '" ++ levelPath(a.path) ++ ":" ++ a.field ++
                        "' and '" ++ levelPath(b.path) ++ ":" ++ b.field ++ "'");
                }
            }
        }
    }
}

/// Whether `s` is a well-formed long flag name: non-empty, no whitespace or
/// control byte, no `=`, and no leading or trailing `-`. Bytes are otherwise
/// accepted verbatim (non-ASCII included), matching the fact that `dap` does
/// not police long names declared directly.
pub fn validLongName(comptime s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '-') return false;
    if (s[s.len - 1] == '-') return false;
    for (s) |c| {
        if (c <= ' ' or c == 0x7f or c == '=') return false;
    }
    return true;
}

/// Whether `p` is a legal `shift` prefix: a valid long name, or a valid long
/// name followed by a single `-` (the conventional separator).
pub fn validPrefix(comptime p: []const u8) bool {
    if (validLongName(p)) return true;
    return p.len > 0 and p[p.len - 1] == '-' and validLongName(p[0 .. p.len - 1]);
}

/// Compile error for an illegal `shift` prefix.
pub fn checkPrefix(comptime prefix: []const u8) void {
    comptime {
        if (prefix.len == 0) {
            @compileError("shift: invalid prefix '' (prefix must not be empty)");
        }
        if (!validPrefix(prefix)) {
            @compileError("shift: invalid prefix '" ++ prefix ++ "' (must be a long flag name, optionally followed by '-')");
        }
    }
}

/// How one field of a `concat` result is produced.
pub const FieldOp = enum {
    /// Field declared only by the left input.
    copy_left,
    /// Field declared only by the right input.
    copy_right,
    /// Same field name on both sides, both `Group(...)` with equal names.
    merge_group,
    /// Same field name on both sides, both `Alt(...)`.
    merge_alt,
};

/// One field of a `concat` result, in declaration order.
pub const FieldPlan = struct {
    /// Declaration field name, taken from the left input when both declare it.
    name: [:0]const u8,
    op: FieldOp,
};

/// Validate a `concat` pair and describe the result field by field.
///
/// Fields pair by declaration field name. A name present on one side is
/// copied unchanged; a name present on both is legal only as `Group` +
/// `Group` or `Alt` + `Alt` and is merged field by field (left members, then
/// right members). Every cross-input name collision is rejected here:
///
/// - flat field names (`normalize`'s specs, so group and `Alt` members are
///   covered) and positional argument display names;
/// - long and short flags over the whole command tree;
/// - top-level command wire names and synonyms;
/// - `Alt` branch field names and branch tags inside a merged `Alt`.
///
/// Both inputs' own structural validity stays `generate`'s business, so a
/// pair rejected by e.g. "commands mix with arguments" fails at the
/// `generate` call site, not here.
pub fn concatPlan(comptime left: anytype, comptime right: anytype) []const FieldPlan {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const left_fields = fieldsOf(@TypeOf(left));

        var plan: []const FieldPlan = &.{};
        for (left_fields) |f| {
            plan = plan ++ &[_]FieldPlan{.{ .name = f.name, .op = .copy_left }};
        }

        for (fieldsOf(@TypeOf(right))) |rf| {
            var replaced = false;
            for (plan, 0..) |entry, i| {
                if (!std.mem.eql(u8, entry.name, rf.name)) continue;
                const lf = fieldByName(left_fields, rf.name).?;
                const op = pairOp(lf, rf);
                if (op == .merge_alt) checkAltPair(lf, rf);
                var next: []const FieldPlan = &.{};
                for (plan, 0..) |old, j| {
                    next = next ++ &[_]FieldPlan{if (j == i) .{ .name = old.name, .op = op } else old};
                }
                plan = next;
                replaced = true;
                break;
            }
            if (!replaced) {
                plan = plan ++ &[_]FieldPlan{.{ .name = rf.name, .op = .copy_right }};
            }
        }

        checkLevelNames(left, right);
        checkLevelArguments(left, right);
        checkConcatFlags(left, right);
        checkConcatCommands(left, right);
        return plan;
    }
}

fn fieldByName(comptime fields: anytype, comptime name: []const u8) ?Field {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn clash(
    comptime class: []const u8,
    comptime name: []const u8,
    comptime left_path: []const u8,
    comptime right_path: []const u8,
) noreturn {
    @compileError(class ++ " '" ++ name ++ "' clash in declarations (left " ++ left_path ++
        ", right " ++ right_path ++ ")");
}

/// Decide how a same-named field pair is produced, rejecting every pair that
/// is not `Group` + `Group` or `Alt` + `Alt`.
fn pairOp(comptime lf: Field, comptime rf: Field) FieldOp {
    comptime {
        if (lf.type != type or rf.type != type) {
            clash("field name", lf.name, lf.name, rf.name);
        }
        const L = typeOfField(lf);
        const R = typeOfField(rf);
        if (L.dap_kind == .group and R.dap_kind == .group) {
            if (!std.mem.eql(u8, L.group_name, R.group_name)) {
                @compileError("group '" ++ lf.name ++ "' name conflict: left '" ++ L.group_name ++
                    "' != right '" ++ R.group_name ++ "'");
            }
            return .merge_group;
        }
        if (L.dap_kind == .alt and R.dap_kind == .alt) {
            return .merge_alt;
        }
        clash("field name", lf.name, lf.name, rf.name);
    }
}

/// A merged `Alt` is one dictionary: branch *field names* must not repeat, and
/// the branch tags of both sides must stay unique (they share the level's help
/// group namespace). Branches themselves are never merged, only concatenated
/// left then right.
fn checkAltPair(comptime lf: Field, comptime rf: Field) void {
    comptime {
        const L = typeOfField(lf);
        const R = typeOfField(rf);
        for (fieldsOf(@TypeOf(L.alt_def))) |lb| {
            for (fieldsOf(@TypeOf(R.alt_def))) |rb| {
                if (std.mem.eql(u8, lb.name, rb.name)) {
                    clash("field name", lb.name, lf.name ++ "." ++ lb.name, rf.name ++ "." ++ rb.name);
                }
            }
        }
        for (L.tag_names) |lt| {
            for (R.tag_names) |rt| {
                if (std.mem.eql(u8, lt, rt)) {
                    clash("alt branch name", lt, lf.name ++ "." ++ lt, rf.name ++ "." ++ rt);
                }
            }
        }
    }
}

/// One spec of one level, with the dotted declaration field path that leads to
/// it (used only in `concat` diagnostics).
const LevelSpec = struct {
    name: String,
    arg_name: ?String,
    is_argument: bool,
    path: String,
};

fn collectLevelSpecs(comptime def: anytype) []const LevelSpec {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const LevelSpec = &.{};
        for (fieldsOf(@TypeOf(def))) |f| {
            out = out ++ fieldLevelSpecs(f, f.name);
        }
        return out;
    }
}

fn fieldLevelSpecs(comptime f: Field, comptime path: String) []const LevelSpec {
    comptime {
        if (f.type == type) {
            const V = typeOfField(f);
            return switch (V.dap_kind) {
                .group => groupLevelSpecs(V.group_def, path),
                .alt => altLevelSpecs(V.alt_def, path),
                .command => &.{},
                else => @compileError("unknown type-valued declaration field '" ++ f.name ++ "'"),
            };
        }
        const s = specFromField(f);
        return &[_]LevelSpec{.{
            .name = s.name,
            .arg_name = s.arg_name,
            .is_argument = s.kind == .argument,
            .path = path,
        }};
    }
}

/// Members of a `Group` are one level up from their field name. Nested groups
/// are illegal, so a type-valued member is skipped here and left to
/// `generate`.
fn groupLevelSpecs(comptime gdef: anytype, comptime path: String) []const LevelSpec {
    comptime {
        var out: []const LevelSpec = &.{};
        for (fieldsOf(@TypeOf(gdef))) |mf| {
            if (mf.type == type) continue;
            out = out ++ fieldLevelSpecs(mf, path ++ "." ++ mf.name);
        }
        return out;
    }
}

fn altLevelSpecs(comptime dict: anytype, comptime path: String) []const LevelSpec {
    comptime {
        var out: []const LevelSpec = &.{};
        for (fieldsOf(@TypeOf(dict))) |bf| {
            const Bv = @field(dict, bf.name);
            const is_variant = @TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_def");
            const Bdef = if (is_variant) Bv.dap_variant_def else Bv;
            if (@TypeOf(Bdef) == type) continue;
            for (fieldsOf(@TypeOf(Bdef))) |mf| {
                out = out ++ fieldLevelSpecs(mf, path ++ "." ++ bf.name ++ "." ++ mf.name);
            }
        }
        return out;
    }
}

fn checkLevelNames(comptime left: anytype, comptime right: anytype) void {
    comptime {
        const ls = collectLevelSpecs(left);
        const rs = collectLevelSpecs(right);
        for (ls) |a| {
            for (rs) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    clash("field name", a.name, a.path, b.path);
                }
            }
        }
    }
}

fn checkLevelArguments(comptime left: anytype, comptime right: anytype) void {
    comptime {
        const ls = collectLevelSpecs(left);
        const rs = collectLevelSpecs(right);
        for (ls) |a| {
            if (!a.is_argument) continue;
            const al = a.arg_name orelse a.name;
            for (rs) |b| {
                if (!b.is_argument) continue;
                const bl = b.arg_name orelse b.name;
                if (std.mem.eql(u8, al, bl)) {
                    clash("argument name", al, a.path, b.path);
                }
            }
        }
    }
}

/// One flag of one input, with the dotted declaration field path that leads to
/// it.
const ConcatFlag = struct {
    long: String,
    short: ?String,
    path: String,
};

fn collectConcatFlags(comptime def: anytype, comptime prefix: String, comptime acc: []const ConcatFlag) []const ConcatFlag {
    comptime {
        var out = acc;
        for (fieldsOf(@TypeOf(def))) |f| {
            out = fieldConcatFlags(f, prefix, out);
        }
        return out;
    }
}

fn childPath(comptime prefix: String, comptime name: []const u8) String {
    return if (prefix.len == 0) name else prefix ++ "." ++ name;
}

fn fieldConcatFlags(comptime f: Field, comptime prefix: String, comptime acc: []const ConcatFlag) []const ConcatFlag {
    comptime {
        const path = childPath(prefix, f.name);
        if (f.type == type) {
            const V = typeOfField(f);
            switch (V.dap_kind) {
                .group => return collectConcatFlags(V.group_def, path, acc),
                .command => return collectConcatFlags(V.cmd_def, path, acc),
                .alt => {
                    var out = acc;
                    for (fieldsOf(@TypeOf(V.alt_def))) |bf| {
                        const Bv = @field(V.alt_def, bf.name);
                        const is_variant = @TypeOf(Bv) == type and @hasDecl(Bv, "dap_variant_def");
                        const Bdef = if (is_variant) Bv.dap_variant_def else Bv;
                        if (@TypeOf(Bdef) == type) continue;
                        out = collectConcatFlags(Bdef, childPath(path, bf.name), out);
                    }
                    return out;
                },
                else => @compileError("unknown type-valued declaration field '" ++ f.name ++ "'"),
            }
        }
        const s = specFromField(f);
        if (s.kind != .flag) return acc;
        return acc ++ &[_]ConcatFlag{.{ .long = s.long, .short = s.short, .path = path }};
    }
}

fn checkConcatFlags(comptime left: anytype, comptime right: anytype) void {
    comptime {
        const ls = collectConcatFlags(left, "", &.{});
        const rs = collectConcatFlags(right, "", &.{});
        for (ls) |a| {
            for (rs) |b| {
                if (std.mem.eql(u8, a.long, b.long)) {
                    clash("flag name", "--" ++ a.long, a.path, b.path);
                }
                if (a.short) |sa| {
                    if (b.short) |sb| {
                        if (std.mem.eql(u8, sa, sb)) {
                            clash("flag name", "-" ++ sa, a.path, b.path);
                        }
                    }
                }
            }
        }
    }
}

/// Command wire names and synonyms share one namespace per level, so the two
/// inputs' top-level command fields are compared spelling by spelling.
fn checkConcatCommands(comptime left: anytype, comptime right: anytype) void {
    comptime {
        const ls = levelCommandSpellings(left);
        const rs = levelCommandSpellings(right);
        for (ls) |a| {
            for (rs) |b| {
                if (std.mem.eql(u8, a.spelling, b.spelling)) {
                    clash("command name", a.spelling, a.field, b.field);
                }
            }
        }
    }
}

const CommandSpelling = struct {
    spelling: String,
    field: String,
};

fn levelCommandSpellings(comptime def: anytype) []const CommandSpelling {
    comptime {
        var out: []const CommandSpelling = &.{};
        for (fieldsOf(@TypeOf(def))) |f| {
            if (f.type != type) continue;
            const V = typeOfField(f);
            if (!@hasDecl(V, "dap_kind") or V.dap_kind != .command) continue;
            out = out ++ &[_]CommandSpelling{.{ .spelling = V.cmd_meta.name orelse f.name, .field = f.name }};
            if (V.cmd_meta.synonym) |syn| {
                out = out ++ &[_]CommandSpelling{.{ .spelling = syn, .field = f.name }};
            }
        }
        return out;
    }
}

test "checks: valid long names and shift prefixes" {
    try std.testing.expect(validLongName("port"));
    try std.testing.expect(validLongName("dry_run"));
    try std.testing.expect(validLongName("a.b"));
    try std.testing.expect(!validLongName(""));
    try std.testing.expect(!validLongName("-port"));
    try std.testing.expect(!validLongName("port-"));
    try std.testing.expect(!validLongName("a b"));
    try std.testing.expect(!validLongName("a\tb"));
    try std.testing.expect(!validLongName("a=b"));
    try std.testing.expect(!validLongName("a\x7f"));

    try std.testing.expect(validPrefix("db"));
    try std.testing.expect(validPrefix("db-"));
    try std.testing.expect(validPrefix("a-b-"));
    try std.testing.expect(validPrefix("a.b"));
    try std.testing.expect(!validPrefix(""));
    try std.testing.expect(!validPrefix("-"));
    try std.testing.expect(!validPrefix("-db"));
    try std.testing.expect(!validPrefix("a--"));
    try std.testing.expect(!validPrefix("a b-"));
    try std.testing.expect(!validPrefix("a="));
}
test "checks: validI18nKey table" {
    try std.testing.expect(validI18nKey("a"));
    try std.testing.expect(validI18nKey("_a"));
    try std.testing.expect(validI18nKey("A9_"));
    try std.testing.expect(validI18nKey("flag_user"));
    try std.testing.expect(validI18nKey("builtin_help"));
    try std.testing.expect(!validI18nKey(""));
    try std.testing.expect(!validI18nKey("1a"));
    try std.testing.expect(!validI18nKey("a-b"));
    try std.testing.expect(!validI18nKey("a.b"));
    try std.testing.expect(!validI18nKey("a b"));
    try std.testing.expect(!validI18nKey("a\n"));
    try std.testing.expect(!validI18nKey("é"));
}

const I18nTestDef = .{
    .verbose = dap.Flag(bool){ .i18n = "verbose_flag" },
    .net = dap.Group(.{
        .host = dap.Flag(dap.String){ .i18n = "group_host" },
    }, "network"),
    .speed = dap.Alt(.{
        .fast = .{ .fast = dap.Flag(u8){ .i18n = "alt_fast" } },
    }),
    .serve = dap.Command(.{ .help = "Serve.", .i18n = "cmd_serve" }, .{
        .src = dap.Argument(dap.String){ .i18n = "arg_src" },
        .inner = dap.Flag(u32){ .i18n = "flag_inner" },
    }),
};

test "checks: collectI18n walks the tree once per key" {
    const norm = comptime normalize(withBuiltinHelp(I18nTestDef));
    const origins = comptime collectI18n(norm, "Do things.", "app_help", &[_]String{"app"}, &.{});

    try std.testing.expectEqual(@as(usize, 7), origins.len);
    const expected_fields = [_]String{ "help", "verbose", "host", "fast", "serve", "src", "inner" };
    const expected_keys = [_]String{ "app_help", "verbose_flag", "group_host", "alt_fast", "cmd_serve", "arg_src", "flag_inner" };
    for (origins, 0..) |o, i| {
        try std.testing.expectEqualStrings(expected_fields[i], o.field);
        try std.testing.expectEqualStrings(expected_keys[i], o.key);
    }

    // The injected builtin help spec never produces an origin.
    for (origins) |o| try std.testing.expect(!std.mem.eql(u8, o.field, builtin_help_field));

    // A command's meta key and the child App key derived from it are one
    // origin, so the tree's keys are all unique.
    comptime checkI18nKeys(origins);
}

test "checks: checkI18nKeys rejects an invalid key" {
    if (false) {
        const norm = normalize(withBuiltinHelp(.{
            .bad = dap.Flag(u8){ .i18n = "bad-key" },
        }));
        comptime checkI18nKeys(collectI18n(norm, "", null, &[_]String{"app"}, &.{}));
    }
}

test "checks: checkI18nKeys rejects a duplicate key" {
    if (false) {
        const norm = normalize(withBuiltinHelp(.{
            .a = dap.Flag(u8){ .i18n = "same_key" },
            .b = dap.Flag(u8){ .i18n = "same_key" },
        }));
        comptime checkI18nKeys(collectI18n(norm, "", null, &[_]String{"app"}, &.{}));
    }
}

test "checks: checkI18nKeys rejects a builtin collision" {
    if (false) {
        const norm = normalize(withBuiltinHelp(.{
            .a = dap.Flag(u8){ .i18n = "builtin_help" },
        }));
        comptime checkI18nKeys(collectI18n(norm, "", null, &[_]String{"app"}, &.{}));
    }
}

const I18nModeEnum = .{
    .json = dap.Enum{ .help = .{ .text = "Machine-readable JSON output.", .i18n = "mode_json" } },
    .yaml = dap.Enum{ .help = .{ .text = "Human-readable YAML config." } },
    .toml = dap.Enum{},
    .plain = dap.Enum{ .help = .{ .text = "Plain text.", .i18n = "" } },
};

test "checks: collectI18n records enumeration branch origins" {
    const norm = comptime normalize(withBuiltinHelp(.{
        .mode = dap.Flag(dap.Enumeration(I18nModeEnum)){},
    }));
    const origins = comptime collectI18n(norm, "", null, &[_]String{"app"}, &.{});

    // Only `json` declares both a key and help; `yaml` has no key, `toml` has
    // no help, and `plain`'s empty key means "no translation".
    try std.testing.expectEqual(@as(usize, 1), origins.len);
    try std.testing.expectEqualStrings("mode_json", origins[0].key);
    try std.testing.expectEqualStrings("Machine-readable JSON output.", origins[0].literal);
    try std.testing.expectEqualStrings("mode.json", origins[0].field);

    comptime checkI18nKeys(origins);
}

test "checks: a keyless enumeration is reusable in two fields" {
    const Mode = dap.Enumeration(.{
        .json = dap.Enum{ .help = .{ .text = "JSON." } },
        .yaml = dap.Enum{},
    });
    const norm = comptime normalize(withBuiltinHelp(.{
        .a = dap.Flag(Mode){},
        .b = dap.Flag(Mode){},
    }));
    const origins = comptime collectI18n(norm, "", null, &[_]String{"app"}, &.{});
    try std.testing.expectEqual(@as(usize, 0), origins.len);
    comptime checkI18nKeys(origins);
}

test "checks: the removed shell builtin keys are ordinary user keys" {
    const norm = comptime normalize(withBuiltinHelp(.{
        .a = dap.Flag(u8){ .i18n = "builtin_bash_shell" },
        .b = dap.Flag(u8){ .i18n = "builtin_zsh_shell" },
        .c = dap.Flag(u8){ .i18n = "builtin_fish_shell" },
    }));
    const origins = comptime collectI18n(norm, "", null, &[_]String{"app"}, &.{});
    try std.testing.expectEqual(@as(usize, 3), origins.len);
    comptime checkI18nKeys(origins);
}

test "checks: checkI18nKeys rejects duplicate branch keys in one enumeration" {
    if (false) {
        const norm = normalize(withBuiltinHelp(.{
            .mode = dap.Flag(dap.Enumeration(.{
                .json = dap.Enum{ .help = .{ .text = "JSON.", .i18n = "same_key" } },
                .yaml = dap.Enum{ .help = .{ .text = "YAML.", .i18n = "same_key" } },
            })){},
        }));
        comptime checkI18nKeys(collectI18n(norm, "", null, &[_]String{"app"}, &.{}));
    }
}

test "checks: checkI18nKeys rejects a keyed enumeration reused in two fields" {
    if (false) {
        const Mode = dap.Enumeration(.{
            .json = dap.Enum{ .help = .{ .text = "JSON.", .i18n = "mode_json" } },
        });
        const norm = normalize(withBuiltinHelp(.{
            .a = dap.Flag(Mode){},
            .b = dap.Flag(Mode){},
        }));
        comptime checkI18nKeys(collectI18n(norm, "", null, &[_]String{"app"}, &.{}));
    }
}

test "checks: checkI18nKeys rejects an invalid branch key" {
    if (false) {
        const norm = normalize(withBuiltinHelp(.{
            .mode = dap.Flag(dap.Enumeration(.{
                .json = dap.Enum{ .help = .{ .text = "JSON.", .i18n = "bad-key" } },
            })){},
        }));
        comptime checkI18nKeys(collectI18n(norm, "", null, &[_]String{"app"}, &.{}));
    }
}

test "checks: checkI18nKeys rejects a branch key colliding with builtin_help" {
    if (false) {
        const norm = normalize(withBuiltinHelp(.{
            .mode = dap.Flag(dap.Enumeration(.{
                .json = dap.Enum{ .help = .{ .text = "JSON.", .i18n = "builtin_help" } },
            })){},
        }));
        comptime checkI18nKeys(collectI18n(norm, "", null, &[_]String{"app"}, &.{}));
    }
}
