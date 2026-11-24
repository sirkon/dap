//! Dependency-free internationalization data and locale selection.
//!
//! This module is pure comptime data plus environment lookup. It does not
//! import `dap.zig`; the dependency runs the other way.

const std = @import("std");

const String = []const u8;
const Map = std.StaticStringMap;

const empty_string_pairs = [0]struct { String, String }{};
const empty_user: Map(String) = Map(String).initComptime(&empty_string_pairs);

/// `[_A-Za-z][_0-9A-Za-z]*`, ASCII only, non-empty. The public shared form
/// lives in `checks.zig`; this copy keeps the module dependency-free.
fn validKey(comptime s: String) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn checkTemplate(comptime name: String, comptime template: String, comptime expected: usize) void {
    comptime {
        @setEvalBranchQuota(100_000);
        var count: usize = 0;
        var i: usize = 0;
        while (i < template.len) {
            const c = template[i];
            if (c == '{') {
                if (i + 2 >= template.len or template[i + 1] != 's' or template[i + 2] != '}') {
                    @compileError("i18n diag template '" ++ name ++ "' has a malformed placeholder; only '{s}' is allowed");
                }
                count += 1;
                i += 3;
            } else if (c == '}') {
                @compileError("i18n diag template '" ++ name ++ "' has a stray '}'");
            } else {
                i += 1;
            }
        }
        if (count != expected) {
            if (expected == 1) {
                @compileError("i18n diag template '" ++ name ++ "' must contain exactly one {s}");
            } else {
                @compileError("i18n diag template '" ++ name ++ "' must contain exactly two {s}");
            }
        }
    }
}

/// The private English structural template. It is not exported, not
/// selectable, and not a fallback: `Locale.default` is its only user.
const english: I18n.Locale = .{
    .meta = .{
        .usage = "Usage: ",
        .flags = "Flags:",
        .cmds = "Commands:",
        .args = "Arguments:",
        .cmds_placeholder = "<command>",
        .flags_placeholder = "[flags]",
        .possible_values = "Possible values: ",
        .default_value = "Default value: ",
    },
    .builtin = .{
        .help = "Show context-sensitive help.",
    },
    .diag = .{
        .field_invalid = "error: field '{s}' is invalid or missing",
        .token_invalid = "error: token '{s}' is invalid",
        .message = "error: {s}",
        .did_you_mean = "error: did you mean '{s}{s}'?",
    },
    .user = empty_user,
};

fn localePtr(locales: Map(I18n.Locale), key: String) ?*const I18n.Locale {
    const idx = locales.getIndex(key) orelse return null;
    return &locales.kvs.values[idx];
}

pub const I18n = struct {
    pub const Error = error{ UnknownTranslationKey, UnsupportedLocale };

    pub const Entry = struct { key: String, value: String };

    /// One immutable locale: structural strings plus the user translation map.
    pub const Locale = struct {
        pub const Meta = struct {
            usage: String,
            flags: String,
            cmds: String,
            args: String,

            cmds_placeholder: String,
            flags_placeholder: String,

            possible_values: String, // includes its own trailing space
            default_value: String, // includes its own trailing space
        };

        /// This struct is for static guarantees only. It is only used
        /// during a construction and these values go into the user
        /// map as "builtin_<field name>".
        pub const Builtin = struct {
            help: String,
        };

        /// Diagnostic templates. Each contains its own prefix so a
        /// language can reword or omit it.
        pub const Diag = struct {
            field_invalid: String,
            token_invalid: String,
            message: String,
            did_you_mean: String,
        };

        meta: Meta,
        builtin: Builtin,
        diag: Diag,
        user: Map(String),

        /// The generated English locale: structural strings from the private
        /// template, user map exactly `entries`.
        pub fn default(comptime entries: []const Entry) Locale {
            const pairs = comptime blk: {
                @setEvalBranchQuota(100_000);
                var p: [entries.len]struct { String, String } = undefined;
                for (entries, 0..) |entry, i| {
                    p[i] = .{ entry.key, entry.value };
                }
                break :blk p;
            };
            const res: Locale = .{
                .meta = english.meta,
                .builtin = english.builtin,
                .diag = english.diag,
                .user = Map(String).initComptime(&pairs),
            };
            comptime res.validate();
            return res;
        }

        /// This prefilled locale with its builtin pairs plus `user_map`.
        /// The user map is replaced, not merged.
        pub fn withUser(comptime self: Locale, comptime user_map: anytype) Locale {
            const field_names = @typeInfo(@TypeOf(user_map)).@"struct".field_names;
            const builtin_pairs = [_]struct { String, String }{
                .{ "builtin_help", self.builtin.help },
            };
            const pairs = comptime blk: {
                @setEvalBranchQuota(100_000);
                var p: [builtin_pairs.len + field_names.len]struct { String, String } = undefined;
                for (builtin_pairs, 0..) |pair, i| p[i] = pair;
                for (field_names, 0..) |name, i| {
                    if (!validKey(name)) {
                        @compileError("i18n key '" ++ name ++ "' is not a valid field name ([_A-Za-z][_0-9A-Za-z]*)");
                    }
                    for (builtin_pairs) |pair| {
                        if (std.mem.eql(u8, name, pair[0])) {
                            @compileError("i18n key '" ++ name ++ "' collides with a builtin translation");
                        }
                    }
                    p[builtin_pairs.len + i] = .{ name, @field(user_map, name) };
                }
                break :blk p;
            };
            return .{
                .meta = self.meta,
                .builtin = self.builtin,
                .diag = self.diag,
                .user = Map(String).initComptime(&pairs),
            };
        }

        /// The user-map value for `key`, or `null` when absent.
        pub fn get(self: Locale, key: String) ?String {
            return self.user.get(key);
        }

        /// Whether the user map contains `key`.
        pub fn has(self: Locale, key: String) bool {
            return self.user.has(key);
        }

        /// The user-map value for `key`, or `error.UnknownTranslationKey`.
        pub fn require(self: Locale, key: String) Error!String {
            return self.get(key) orelse error.UnknownTranslationKey;
        }

        fn validate(comptime self: Locale) void {
            comptime {
                for (@typeInfo(Meta).@"struct".field_names) |name| {
                    if (@field(self.meta, name).len == 0) {
                        @compileError("i18n Meta." ++ name ++ " must not be empty");
                    }
                }
                for (@typeInfo(Builtin).@"struct".field_names) |name| {
                    if (@field(self.builtin, name).len == 0) {
                        @compileError("i18n Builtin." ++ name ++ " must not be empty");
                    }
                }
                checkTemplate("Diag.field_invalid", self.diag.field_invalid, 1);
                checkTemplate("Diag.token_invalid", self.diag.token_invalid, 1);
                checkTemplate("Diag.message", self.diag.message, 1);
                checkTemplate("Diag.did_you_mean", self.diag.did_you_mean, 2);
            }
        }
    };

    /// Strips an `@modifier` suffix, then the encoding part. `UTF-8` and
    /// `utf8` (any case) keep the language part; other encodings and the `C`
    /// or `POSIX` bases select the default locale.
    pub fn normalizeTag(raw: String) String {
        var tag = raw;
        if (std.mem.indexOfScalar(u8, tag, '@')) |at| {
            tag = tag[0..at];
        }
        if (std.mem.indexOfScalar(u8, tag, '.')) |dot| {
            const encoding = tag[dot + 1 ..];
            if (!std.ascii.eqlIgnoreCase(encoding, "UTF-8") and
                !std.ascii.eqlIgnoreCase(encoding, "utf8"))
            {
                return "";
            }
            tag = tag[0..dot];
        }
        if (std.mem.eql(u8, tag, "C") or std.mem.eql(u8, tag, "POSIX")) return "";
        return tag;
    }

    /// The first non-empty of `LC_ALL`, `LC_MESSAGES`, `LANG`. Non-POSIX
    /// targets return `null`, so the default locale applies.
    pub fn tagFromEnviron(environ: std.process.Environ) ?String {
        if (comptime std.process.Environ.Block == std.process.Environ.PosixBlock) {
            inline for ([_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
                if (std.process.Environ.getPosix(environ, name)) |value| {
                    if (value.len != 0) return value;
                }
            }
            return null;
        } else {
            _ = environ.block;
            return null;
        }
    }

    /// Exact tag, then the language part before `_`, then the default.
    fn localeByTag(locales: Map(Locale), tag: String) Error!*const Locale {
        if (localePtr(locales, tag)) |loc| return loc;
        if (std.mem.indexOfScalar(u8, tag, '_')) |underscore| {
            if (localePtr(locales, tag[0..underscore])) |loc| return loc;
        }
        if (localePtr(locales, "")) |loc| return loc;
        return error.UnsupportedLocale;
    }

    /// A comptime locale registry: the default under `""` plus the locales
    /// appended by the caller, and the keys every appended locale must supply.
    pub const Builder = struct {
        locales: Map(Locale),
        required: []const String,

        /// Seed the locale map with `""` -> `default` and copy the keys every
        /// appended locale must supply.
        pub fn init(comptime default: Locale, comptime required: []const String) Builder {
            const pairs = [_]struct { String, Locale }{
                .{ "", default },
            };
            return .{
                .locales = Map(Locale).initComptime(&pairs),
                .required = required,
            };
        }

        pub inline fn append(comptime self: Builder, comptime lang: String, comptime translation: Locale) Builder {
            comptime {
                @setEvalBranchQuota(100_000);
                if (lang.len == 0) {
                    @compileError("i18n locale name must not be empty (reserved for the default locale)");
                }
                if (self.locales.has(lang)) {
                    @compileError("i18n locale '" ++ lang ++ "' is appended twice");
                }
                translation.validate();
                var missing: String = "";
                for (self.required) |key| {
                    if (!translation.has(key)) {
                        missing = missing ++ "'" ++ key ++ "' ";
                    }
                }
                if (missing.len != 0) {
                    @compileError("i18n locale '" ++ lang ++ "' is missing required keys " ++ missing);
                }
            }
            const n = comptime self.locales.kvs.len;
            const pairs = comptime blk: {
                var p: [n + 1]struct { String, Locale } = undefined;
                for (0..n) |i| {
                    p[i] = .{ self.locales.kvs.keys[i], self.locales.kvs.values[i] };
                }
                p[n] = .{ lang, translation };
                break :blk p;
            };
            return .{
                .locales = Map(Locale).initComptime(&pairs),
                .required = self.required,
            };
        }

        /// Select the locale named by the environment: exact tag, then the
        /// language before `_`, then `""`. Cannot fail because `init` always
        /// seeds the default under `""`.
        pub fn locale(self: *const Builder, environ: std.process.Environ) *const Locale {
            const raw = tagFromEnviron(environ) orelse "";
            const tag = normalizeTag(raw);
            return localeByTag(self.locales, tag) catch unreachable;
        }
    };

    /// Ready to use defaults with prefilled meta, builtin and diag, where a
    /// user only needs to set up the dynamic part:
    /// ```
    /// dap.I18n.ru.withUser(.{ .greeting = "Привет" });
    /// ```
    pub const ru: Locale = .{
        .meta = .{
            .usage = "Использование: ",
            .flags = "Флаги:",
            .cmds = "Команды:",
            .args = "Аргументы:",
            .cmds_placeholder = "<команда>",
            .flags_placeholder = "[флаги]",
            .possible_values = "Возможные значения: ",
            .default_value = "Значение по умолчанию: ",
        },
        .builtin = .{
            .help = "Показать справку по контексту.",
        },
        .diag = .{
            .field_invalid = "неверное поле '{s}' или оно отсутствует",
            .token_invalid = "неверный токен '{s}'",
            .message = "{s}",
            .did_you_mean = "возможно, вы имели в виду '{s}{s}'?",
        },
        .user = empty_user,
    };

    pub const zh: Locale = .{
        .meta = .{
            .usage = "用法： ",
            .flags = "选项：",
            .cmds = "命令：",
            .args = "参数：",
            .cmds_placeholder = "<命令>",
            .flags_placeholder = "[选项]",
            .possible_values = "可能的值： ",
            .default_value = "默认值： ",
        },
        .builtin = .{
            .help = "显示上下文相关帮助。",
        },
        .diag = .{
            .field_invalid = "错误：字段 '{s}' 无效或缺失",
            .token_invalid = "错误：标记 '{s}' 无效",
            .message = "错误：{s}",
            .did_you_mean = "错误：您是指 '{s}{s}' 吗？",
        },
        .user = empty_user,
    };

    pub const es: Locale = .{
        .meta = .{
            .usage = "Uso: ",
            .flags = "Opciones:",
            .cmds = "Comandos:",
            .args = "Argumentos:",
            .cmds_placeholder = "<comando>",
            .flags_placeholder = "[opciones]",
            .possible_values = "Valores posibles: ",
            .default_value = "Valor predeterminado: ",
        },
        .builtin = .{
            .help = "Mostrar ayuda contextual.",
        },
        .diag = .{
            .field_invalid = "error: el campo '{s}' no es válido o falta",
            .token_invalid = "error: el token '{s}' no es válido",
            .message = "error: {s}",
            .did_you_mean = "error: ¿quiso decir '{s}{s}'?",
        },
        .user = empty_user,
    };

    pub const it: Locale = .{
        .meta = .{
            .usage = "Uso: ",
            .flags = "Opzioni:",
            .cmds = "Comandi:",
            .args = "Argomenti:",
            .cmds_placeholder = "<comando>",
            .flags_placeholder = "[opzioni]",
            .possible_values = "Valori possibili: ",
            .default_value = "Valore predefinito: ",
        },
        .builtin = .{
            .help = "Mostra la guida contestuale.",
        },
        .diag = .{
            .field_invalid = "errore: il campo '{s}' non è valido o manca",
            .token_invalid = "errore: il token '{s}' non è valido",
            .message = "errore: {s}",
            .did_you_mean = "errore: intendevi '{s}{s}'?",
        },
        .user = empty_user,
    };

    pub const fr: Locale = .{
        .meta = .{
            .usage = "Utilisation : ",
            .flags = "Options :",
            .cmds = "Commandes :",
            .args = "Arguments :",
            .cmds_placeholder = "<commande>",
            .flags_placeholder = "[options]",
            .possible_values = "Valeurs possibles : ",
            .default_value = "Valeur par défaut : ",
        },
        .builtin = .{
            .help = "Afficher l'aide contextuelle.",
        },
        .diag = .{
            .field_invalid = "erreur : le champ '{s}' est invalide ou manquant",
            .token_invalid = "erreur : le jeton '{s}' est invalide",
            .message = "erreur : {s}",
            .did_you_mean = "erreur : vouliez-vous dire '{s}{s}' ?",
        },
        .user = empty_user,
    };

    pub const de: Locale = .{
        .meta = .{
            .usage = "Verwendung: ",
            .flags = "Optionen:",
            .cmds = "Befehle:",
            .args = "Argumente:",
            .cmds_placeholder = "<Befehl>",
            .flags_placeholder = "[Optionen]",
            .possible_values = "Mögliche Werte: ",
            .default_value = "Standardwert: ",
        },
        .builtin = .{
            .help = "Kontextbezogene Hilfe anzeigen.",
        },
        .diag = .{
            .field_invalid = "Fehler: Feld '{s}' ist ungültig oder fehlt",
            .token_invalid = "Fehler: Token '{s}' ist ungültig",
            .message = "Fehler: {s}",
            .did_you_mean = "Fehler: Meinten Sie '{s}{s}'?",
        },
        .user = empty_user,
    };

    pub const ko: Locale = .{
        .meta = .{
            .usage = "사용법: ",
            .flags = "플래그:",
            .cmds = "명령어:",
            .args = "인자:",
            .cmds_placeholder = "<명령어>",
            .flags_placeholder = "[플래그]",
            .possible_values = "가능한 값: ",
            .default_value = "기본값: ",
        },
        .builtin = .{
            .help = "상황에 맞는 도움말을 표시합니다.",
        },
        .diag = .{
            .field_invalid = "오류: '{s}' 필드가 올바르지 않거나 없습니다",
            .token_invalid = "오류: '{s}' 토큰이 올바르지 않습니다",
            .message = "오류: {s}",
            .did_you_mean = "오류: 혹시 '{s}{s}'입니까?",
        },
        .user = empty_user,
    };

    pub const ja: Locale = .{
        .meta = .{
            .usage = "使用法: ",
            .flags = "フラグ:",
            .cmds = "コマンド:",
            .args = "引数:",
            .cmds_placeholder = "<コマンド>",
            .flags_placeholder = "[フラグ]",
            .possible_values = "可能な値: ",
            .default_value = "デフォルト値: ",
        },
        .builtin = .{
            .help = "状況に応じたヘルプを表示します。",
        },
        .diag = .{
            .field_invalid = "エラー: フィールド '{s}' が無効または欠落しています",
            .token_invalid = "エラー: トークン '{s}' が無効です",
            .message = "エラー: {s}",
            .did_you_mean = "エラー: '{s}{s}' のことですか?",
        },
        .user = empty_user,
    };
};

test "normalizeTag strips modifier and encoding" {
    try std.testing.expectEqualStrings("ru_RU", I18n.normalizeTag("ru_RU.UTF-8"));
    try std.testing.expectEqualStrings("ru_RU", I18n.normalizeTag("ru_RU.utf8"));
    try std.testing.expectEqualStrings("ru_RU", I18n.normalizeTag("ru_RU@euro"));
    try std.testing.expectEqualStrings("ru_RU", I18n.normalizeTag("ru_RU.UTF-8@euro"));
    try std.testing.expectEqualStrings("", I18n.normalizeTag("ru_RU.ISO-8859-1"));
    try std.testing.expectEqualStrings("", I18n.normalizeTag("C"));
    try std.testing.expectEqualStrings("", I18n.normalizeTag("C.UTF-8"));
    try std.testing.expectEqualStrings("", I18n.normalizeTag("POSIX"));
    try std.testing.expectEqualStrings("", I18n.normalizeTag(""));
    try std.testing.expectEqualStrings("ru", I18n.normalizeTag("ru"));
}

test "Locale.default installs entries verbatim and seeds no builtin keys" {
    const loc = comptime I18n.Locale.default(&.{
        .{ .key = "greeting", .value = "hello" },
    });
    try std.testing.expectEqualStrings("hello", loc.get("greeting").?);
    try std.testing.expect(loc.has("greeting"));
    try std.testing.expect(!loc.has("builtin_help"));
    try std.testing.expect(!loc.has("builtin_bash_shell"));
    try std.testing.expect(!loc.has("builtin_zsh_shell"));
    try std.testing.expect(!loc.has("builtin_fish_shell"));
    try std.testing.expectEqual(@as(?String, null), loc.get("missing"));
    try std.testing.expectError(error.UnknownTranslationKey, loc.require("missing"));
}

test "withUser replaces inherited user entries and seeds builtin pairs" {
    const base = comptime I18n.ru.withUser(.{
        .greeting = "Привет",
        .farewell = "Пока",
    });
    try std.testing.expectEqualStrings("Привет", base.get("greeting").?);
    try std.testing.expectEqualStrings(I18n.ru.builtin.help, base.get("builtin_help").?);
    try std.testing.expect(!base.has("builtin_bash_shell"));
    try std.testing.expect(!base.has("builtin_zsh_shell"));
    try std.testing.expect(!base.has("builtin_fish_shell"));

    const next = comptime base.withUser(.{
        .farewell = "До свидания",
        .welcome = "Добро пожаловать",
    });
    try std.testing.expect(!next.has("greeting"));
    try std.testing.expectEqualStrings("До свидания", next.get("farewell").?);
    try std.testing.expectEqualStrings("Добро пожаловать", next.get("welcome").?);
    try std.testing.expectEqualStrings(I18n.ru.builtin.help, next.get("builtin_help").?);
}

// Negative `withUser` cases, verified by enabling them manually:
//
// test "withUser rejects invalid keys" {
//     _ = I18n.ru.withUser(.{ .@"bad.key" = "x" });
// }
//
// test "withUser rejects builtin collisions" {
//     _ = I18n.ru.withUser(.{ .builtin_help = "x" });
// }

const tag_test_map = blk: {
    const fallback = I18n.Locale.default(&.{});
    const pairs = [_]struct { String, I18n.Locale }{
        .{ "", fallback },
        .{ "ru", I18n.ru },
        .{ "ru_RU", I18n.ru },
    };
    break :blk Map(I18n.Locale).initComptime(&pairs);
};

const tag_test_map_no_default = blk: {
    const pairs = [_]struct { String, I18n.Locale }{
        .{ "ru", I18n.ru },
        .{ "ru_RU", I18n.ru },
    };
    break :blk Map(I18n.Locale).initComptime(&pairs);
};

test "localeByTag resolves exact, language, default and failures" {
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, (try I18n.localeByTag(tag_test_map, "ru_RU")).meta.usage);
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, (try I18n.localeByTag(tag_test_map, "ru")).meta.usage);
    try std.testing.expectEqualStrings(I18n.ru.meta.usage, (try I18n.localeByTag(tag_test_map, "ru_BY")).meta.usage);
    try std.testing.expectEqualStrings("Usage: ", (try I18n.localeByTag(tag_test_map, "")).meta.usage);
    try std.testing.expectEqualStrings("Usage: ", (try I18n.localeByTag(tag_test_map, "xx_XX")).meta.usage);
    try std.testing.expectError(error.UnsupportedLocale, I18n.localeByTag(tag_test_map_no_default, "xx_XX"));
}

const test_builder = blk: {
    const fallback = I18n.Locale.default(&.{});
    break :blk I18n.Builder.init(fallback, &.{})
        .append("ru_RU", I18n.ru.withUser(.{}))
        .append("zh_CN", I18n.zh.withUser(.{}))
        .append("ja_JP", I18n.ja.withUser(.{}));
};

test "Builder.append accepts a locale with every required key" {
    const fallback = comptime I18n.Locale.default(&.{
        .{ .key = "greeting", .value = "hello" },
    });
    const translated = comptime I18n.ru.withUser(.{ .greeting = "Привет" });
    const builder = comptime I18n.Builder.init(fallback, &.{"greeting"}).append("ru", translated);
    const loc = builder.locales.get("ru").?;
    try std.testing.expectEqualStrings("Привет", loc.get("greeting").?);
    try std.testing.expectEqualStrings(I18n.ru.builtin.help, loc.get("builtin_help").?);
}

// Negative `Builder.append` cases, verified by enabling them manually:
//
// test "append rejects an empty locale name" {
//     _ = comptime I18n.Builder.init(I18n.Locale.default(&.{}), &.{}).append("", I18n.ru);
// }
//
// test "append rejects a duplicate locale name" {
//     _ = comptime I18n.Builder.init(I18n.Locale.default(&.{}), &.{})
//         .append("ru", I18n.ru)
//         .append("ru", I18n.zh);
// }
//
// test "append rejects a locale missing a required key" {
//     _ = comptime I18n.Builder.init(I18n.Locale.default(&.{}), &.{"greeting"})
//         .append("ru", I18n.ru.withUser(.{}));
// }

const LocaleEnv = struct {
    fn check(builder: *const I18n.Builder, expected: I18n.Locale, pairs: []const [2]String) !void {
        const gpa = std.testing.allocator;
        var map = std.process.Environ.Map.init(gpa);
        defer map.deinit();
        for (pairs) |pair| try map.put(pair[0], pair[1]);
        const block = try map.createPosixBlock(gpa, .{});
        defer block.deinit(gpa);
        const environ = std.process.Environ{ .block = block };
        try std.testing.expectEqualStrings(expected.meta.usage, builder.locale(environ).meta.usage);
    }
};

test "Builder.locale reads LC_ALL, LC_MESSAGES, LANG in order" {
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    try LocaleEnv.check(&test_builder, I18n.ru, &.{
        .{ "LC_ALL", "ru_RU.UTF-8" },
        .{ "LC_MESSAGES", "zh_CN.UTF-8" },
        .{ "LANG", "ja_JP.UTF-8" },
    });
    try LocaleEnv.check(&test_builder, I18n.zh, &.{
        .{ "LC_MESSAGES", "zh_CN.UTF-8" },
        .{ "LANG", "ja_JP.UTF-8" },
    });
    try LocaleEnv.check(&test_builder, I18n.ja, &.{
        .{ "LANG", "ja_JP.UTF-8" },
    });
    try LocaleEnv.check(&test_builder, I18n.zh, &.{
        .{ "LC_ALL", "" },
        .{ "LC_MESSAGES", "zh_CN" },
    });
    const fallback = I18n.Locale.default(&.{});
    try LocaleEnv.check(&test_builder, fallback, &.{});
    try LocaleEnv.check(&test_builder, fallback, &.{
        .{ "LC_ALL", "C.UTF-8" },
        .{ "LANG", "ja_JP.UTF-8" },
    });
}

test "every prefilled locale is complete" {
    const locales = .{ I18n.ru, I18n.zh, I18n.es, I18n.it, I18n.fr, I18n.de, I18n.ko, I18n.ja };
    inline for (locales) |loc| {
        comptime loc.validate();
        inline for (@typeInfo(I18n.Locale.Meta).@"struct".field_names) |name| {
            try std.testing.expect(@field(loc.meta, name).len != 0);
        }
        inline for (@typeInfo(I18n.Locale.Builtin).@"struct".field_names) |name| {
            try std.testing.expect(@field(loc.builtin, name).len != 0);
        }
        inline for (@typeInfo(I18n.Locale.Diag).@"struct".field_names) |name| {
            try std.testing.expect(@field(loc.diag, name).len != 0);
        }
    }
}

test "every prefilled locale carries the value clauses" {
    const locales = .{ I18n.ru, I18n.zh, I18n.es, I18n.it, I18n.fr, I18n.de, I18n.ko, I18n.ja };
    inline for (locales) |loc| {
        try std.testing.expect(loc.meta.possible_values.len != 0);
        try std.testing.expect(loc.meta.default_value.len != 0);
    }
    try std.testing.expectEqualStrings("Possible values: ", english.meta.possible_values);
    try std.testing.expectEqualStrings("Default value: ", english.meta.default_value);
}

// Malformed `Diag` templates are compile errors, verified by enabling them
// manually:
//
// test "validate rejects a wrong placeholder count" {
//     const bad: I18n.Locale = .{
//         .meta = english.meta,
//         .builtin = english.builtin,
//         .diag = .{
//             .field_invalid = "{s}",
//             .token_invalid = "{s}",
//             .message = "{s}",
//             .did_you_mean = "{s}",
//         },
//         .user = empty_user,
//     };
//     comptime bad.validate();
// }
//
// test "validate rejects stray braces" {
//     const bad: I18n.Locale = .{
//         .meta = english.meta,
//         .builtin = english.builtin,
//         .diag = .{
//             .field_invalid = "{s} {",
//             .token_invalid = "{s}",
//             .message = "{s}",
//             .did_you_mean = "{s}{s}",
//         },
//         .user = empty_user,
//     };
//     comptime bad.validate();
// }
