# dap SDK

`dap` is a declarative command-line parser for Zig 0.16.0. You describe your
program's options and arguments with a struct-based DSL, and
`dap.generate(app, def)` produces, at compile time, both:

- a **value type** (`Values`) that holds the parsed result, and
- a **parser** (`parse`) that fills it from a `[]const []const u8` argument
  slice.

The whole module surface is re-exported from `src/root.zig`; import it as
`@import("dap")` (see [Module wiring](#module-wiring)).

---

## Quick start

```zig
const std = @import("std");
const dap = @import("dap");

// 1. Describe the CLI. Field names are the wire names, verbatim.
const def = .{
    .login = dap.Option([]const u8){
        .short = "l",
        .default = dap.Default(dap.String){ .env = "USER" },
        .validation = dap.Validate.stringNotEmpty,
        .help = "User login.",
    },
    .verbose = dap.Option(bool){
        .short = "V",
        .default = dap.defaultValue(bool, false),
        .help = "Verbose output.",
    },
    .path = dap.Argument([]const u8){
        .validation = dap.Validate.stringNotEmpty,
        .help = "File to download.",
    },
};

// 2. Generate the parser + Values type.
const CLI = dap.generate(
    dap.App{ .name = "api-downloader", .help = "Download a file." },
    def,
);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    // Pure payload: drop the binary name, start at index 0.
    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];

    var diag: dap.Diag = .{};
    defer diag.deinit(arena);

    const cli = CLI.parse(arena, init.minimal.environ, args, &diag) catch |err| {
        std.debug.print("error: {s}\n{s}", .{ @errorName(err), try CLI.helpText(arena) });
        if (diag.field) |f| std.debug.print("  field: {s}\n", .{f});
        if (diag.token) |t| std.debug.print("  token: {s}\n", .{t});
        if (diag.message) |m| std.debug.print("  message: {s}\n", .{m});
        std.process.exit(1);
    };

    std.debug.print("{} {}\n", .{ cli.login, cli.path });
}
```

---

## Module wiring

`build.zig` exposes a public module named `dap` rooted at `src/root.zig`:

```zig
const dap_module = b.addModule("dap", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
}) });
exe.root_module.addImport("dap", dap_module);
```

Then `const dap = @import("dap");` in your source.

---

## API reference

### `App`

Program metadata used for help rendering.

| Field  | Type      | Default  | Meaning                                           |
|--------|-----------|----------|---------------------------------------------------|
| `name` | `String`  | required | Program name.                                     |
| `help` | `String`  | required | One-line description, printed at the top of help. |
| `i18n` | `?String` | `null`   | Reserved internationalization reference (inert).  |

```zig
dap.App{ .name = "svc", .help = "Service manager." }
```

### `String`

Alias for `[]const u8`. String values decoded from the wire are allocated with
the parser's allocator.

### `Option(T)`

Declaration form for a named option (`--long` / `-s`).

| Field        | Type                                         | Default | Meaning                                         |
|--------------|----------------------------------------------|---------|-------------------------------------------------|
| `long`       | `?String`                                    | `null`  | Long name; defaults to the field name verbatim. |
| `short`      | `?String`                                    | `null`  | Single-character short name (always explicit).  |
| `default`    | `?Default(T)`                                | `null`  | Default value source (direct and/or env).       |
| `validation` | `?fn (Allocator, T) Allocator.Error!?String` | `null`  | Value validator.                                |
| `help`       | `String`                                     | `""`    | Help line.                                      |
| `i18n`       | `?String`                                    | `null`  | Reserved reference.                             |

An option is **required iff it has no default**. A required `bool` must be
passed (`--flag`, `--flag=true`, or `--flag=false`).

### `Argument(T)`

Declaration form for a positional argument.

| Field        | Type                                         | Default | Meaning                                                |
|--------------|----------------------------------------------|---------|--------------------------------------------------------|
| `name`       | `?String`                                    | `null`  | Identifier shown in help; defaults to the field name.  |
| `default`    | `?Default(T)`                                | `null`  | Default source. Allowed **only on the last** argument. |
| `validation` | `?fn (Allocator, T) Allocator.Error!?String` | `null`  | Value validator.                                       |
| `help`       | `String`                                     | `""`    | Help line.                                             |
| `i18n`       | `?String`                                    | `null`  | Reserved reference.                                    |

### `Default(T)` and `defaultValue`

```zig
pub fn Default(comptime T: type) type {
    return struct {
        direct: ?T = null,
        env: ?String = null,
    };
}
```

- `direct` sets a compile-time literal default.
- `env` names an environment variable consulted first.
- Precedence: **wire value > env default > direct default > zero value**.

`defaultValue(T, v)` is shorthand for `Default(T){ .direct = v }`:

```zig
.verbose = dap.Option(bool){ .default = dap.defaultValue(bool, false) },
```

### `Group(def, name)`

A purely declarative grouping that only affects help output. The members are
flattened into `Values` in declaration order.

```zig
.server = dap.Group(.{
    .host = dap.Option([]const u8){ .help = "Host." },
    .port = dap.Option(u16){ .default = dap.defaultValue(u16, 8080) },
}, "Server settings"),
```

Nested groups are rejected at compile time.

### `Enumeration(T)` and `Enum`

`Enumeration` builds a value type from a set of branches. Each branch is a
`dap.Enum`, optionally overriding its wire name:

```zig
pub const Enum = struct {
    name: ?String = null,
    help: String = "",
    i18n: ?String = null,
};
```

```zig
const Mode = dap.Enumeration(.{
    .fast = dap.Enum{},
    .slow = dap.Enum{ .name = "glacial" },
});
```

The result exposes:

- `view` — a Zig enum (`EnumView`) with one tag per branch;
- `names` — the wire names in declaration order;
- `decode(data) DecodeError!void` and `encode() []const u8`.

Use it directly as an `Option`/`Argument` value type:

```zig
.mode = dap.Option(Mode){
    .long = "mode",
    .default = dap.Default(Mode){ .direct = .{} },
},
```

Duplicate wire names are a compile error.

### `Commands`, `Command`, `CommandMeta`

`Commands(T)` declares a set of subcommands as a field of the declaration
struct (at most one per level). Each member is a `Command(meta, def)` where
`def` is an ordinary declaration struct.

```zig
pub const CommandMeta = struct {
    name: ?String = null,   // wire name; defaults to the field name
    help: String = "",
    i18n: ?String = null,
};
```

```zig
.command = dap.Commands(.{
    .start = dap.Command(dap.CommandMeta{ .help = "Start." }, .{
        .name = dap.Argument([]const u8){},
        .force = dap.Option(bool){ .default = dap.defaultValue(bool, false) },
    }),
    .stop = dap.Command(dap.CommandMeta{ .name = "halt", .help = "Stop." }, .{}),
}),
```

`Commands(T)` exposes `names`, `count`, `sub_types`, and the tagged `Union`.
On the generated `Values`, the commands field is `?Union` (`null` when no
command token appeared).

### `Validate`

Ready-made validators for `Option`/`Argument`:

```zig
dap.Validate.stringNotEmpty                  // fn (Allocator, String) !?String
dap.Validate.intNotZero(u8)                  // comptime factory, per integer type
```

A validator returns `null` on success, or an allocated error message on
failure; it may also return `error.OutOfMemory`.

### `DecodeError` and `ParseError`

```zig
pub const DecodeError = error{
InvalidWire,   // token is not a valid wire representation
InvalidValue,  // wire is well-formed but the value is rejected
};

pub const ParseError = error{
UnknownOption,
MissingValue,
MissingRequired,
TooManyArguments,
InvalidWtf8,
} || std.mem.Allocator.Error || DecodeError;
```

`parse` folds decode failures into `ParseError`, so a caller handles both
layers through one error set.

### `Diag`

Diagnostic detail for the most recent failed `parse`.

| Field     | Meaning                             | Ownership                 |
|-----------|-------------------------------------|---------------------------|
| `field`   | Declaration field name that failed. | Borrowed (comptime).      |
| `token`   | Offending argv token.               | Borrowed (caller argv).   |
| `message` | Human-readable validation message.  | Owned; free via `deinit`. |

```zig
var diag: dap.Diag = .{};
defer diag.deinit(allocator);
```

Passing `null` instead of `&diag` is allowed; in that case an allocated
validation message is freed internally.

### `generate(app, def)`

```zig
pub fn generate(comptime app: App, comptime def: anytype) type
```

Returns a namespace exposing:

| Member                                                    | Description                                                                                                       |
|-----------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `Values`                                                  | Generated struct: one field per spec (declaration order) plus a trailing `?Union` when a `Commands` field exists. |
| `parse(allocator, environ, args, diag) ParseError!Values` | Parse `args` into `Values`.                                                                                       |
| `helpText(allocator) Allocator.Error!String`              | Allocated, caller-owned help string (section-per-group layout).                                                    |
| `helpData(allocator) Allocator.Error!HelpData`            | Fill a runtime `HelpData`; `HelpData.renderCompact(allocator)` renders the kong-style two-column layout.           |
| `specs`                                                   | Normalized spec table (comptime).                                                                                 |
| `app_meta`                                                | The `App` passed in.                                                                                              |
| `commands`                                                | The detected `CommandLevel`, or `null`.                                                                           |

`environ` is a `std.process.Environ` (a value, not a pointer).

---

## Semantics

- **Pure payload.** Every `parse` — root and subcommand alike — iterates
  `args` from index `0` and never skips a token. Pass arguments with the binary
  name already removed (`argv[1..]`).
- **Verbatim names.** Field names are wire names verbatim (`dry_run` ->
  `--dry_run`). A dash-spelled name requires an explicit `.long = "dry-run"`.
- **Derived `required`.** An option/argument is required iff it has no default.
  Uniform for every type, `bool` included.
- **Defaults.** Env defaults take precedence over direct defaults; a default is
  allowed only on the last declared argument.
- **Subcommand handoff.** A positional token equal to a registered command name
  terminates the current parse and calls that subcommand's `parse` with the
  payload after the command token. `--` disables handoff, so command-like
  literals can be passed as positionals.
- **Ownership.** Strings stored in `Values` are allocated with the parser's
  allocator; an arena is the intended lifetime. `Diag.deinit` frees only the
  diagnostic `message`.

---

## Examples

### Flags, options and arguments

```zig
const def = .{
    .verbose = dap.Option(bool){ .short = "v", .default = dap.defaultValue(bool, false) },
    .level = dap.Option(u8){ .default = dap.defaultValue(u8, 1) },
    .dry_run = dap.Option(bool){ .long = "dry-run", .default = dap.defaultValue(bool, false) },
    .file = dap.Argument([]const u8){},
    .dir = dap.Argument([]const u8){ .default = dap.defaultValue([]const u8, ".") },
};
const CLI = dap.generate(dap.App{ .name = "tool", .help = "Tool." }, def);

// --level=7 file.txt              -> level 7, file "file.txt", dir "."
// -v --dry-run file.txt sub       -> verbose true, file "file.txt", dir "sub"
// --dry-run=false -v file.txt     -> dry_run false, verbose true
```

Long options accept `--name value` and `--name=value`. Short options accept
`-s value`, `-s=value`. A bare bool flag means `true`; `--flag=false` sets
`false`.

### Environment defaults

```zig
.user = dap.Option([]const u8){
    .short = "u",
    .default = dap.Default([]const u8){ .env = "DAP_USER" },
},
.port = dap.Option(u16){
    .default = dap.Default(u16){ .env = "DAP_PORT", .direct = 4242 },
},
```

A CLI value overrides the env value; if the env var is absent, the direct
default is used. If a spec has only an env default and the variable is absent,
the field falls back to its zero value (empty string for `String`).

### Validation

```zig
.user = dap.Option([]const u8){
    .short = "u",
    .validation = dap.Validate.stringNotEmpty,
    .default = dap.Default([]const u8){ .env = "DAP_USER" },
},
.level = dap.Option(u8){
    .validation = dap.Validate.intNotZero(u8),
    .default = dap.defaultValue(u8, 1),
},
```

Validation runs over the final value regardless of source (wire, env, or
direct default). On failure `parse` returns `error.InvalidValue` and, if a
`Diag` was supplied, sets `field` and an allocated `message`.

### Groups (help-only)

```zig
.server = dap.Group(.{
    .host = dap.Option([]const u8){ .help = "Host." },
    .port = dap.Option(u16){ .default = dap.defaultValue(u16, 8080), .help = "Port." },
}, "Server settings"),
```

Members land directly on `Values` (`cli.host`, `cli.port`) and are listed under
a `Server settings:` heading in help.

### Subcommands and nesting

```zig
const def = .{
    .verbose = dap.Option(bool){ .default = dap.defaultValue(bool, false) },
    .command = dap.Commands(.{
        .start = dap.Command(dap.CommandMeta{ .help = "Start." }, .{
            .name = dap.Argument([]const u8){},
        }),
        .stop = dap.Command(dap.CommandMeta{ .name = "halt", .help = "Stop." }, .{}),
        .nested = dap.Command(dap.CommandMeta{ .help = "Nested." }, .{
            .inner = dap.Commands(.{
                .deep = dap.Command(dap.CommandMeta{ .help = "Deep." }, .{
                    .n = dap.Argument(u8){},
                }),
            }),
        }),
    }),
};

const CLI = dap.generate(dap.App{ .name = "svc", .help = "Service." }, def);

var cli = try CLI.parse(arena, environ, args, &diag);
if (cli.command) |cmd| switch (cmd) {
    .start => |s| std.debug.print("start {s}\n", .{s.name}),
    .halt => std.debug.print("stop\n", .{}),
    .nested => |n| if (n.inner) |inner| switch (inner) {
        .deep => |d| std.debug.print("deep {}\n", .{d.n}),
    },
};
```

Options after the command token are scoped to the subcommand's own
declaration. Root-level required fields are still enforced after handoff.

### Enumeration

```zig
const Mode = dap.Enumeration(.{
    .fast = dap.Enum{},
    .slow = dap.Enum{ .name = "glacial" },
});

const def = .{
    .mode = dap.Option(Mode){
        .long = "mode",
        .default = dap.Default(Mode){ .direct = .{} },
    },
    .file = dap.Argument([]const u8){},
};
const CLI = dap.generate(dap.App{ .name = "enum", .help = "Enum." }, def);

// --mode glacial f  -> cli.mode.view == Mode.EnumView.slow
// f                 -> cli.mode.view == Mode.EnumView.fast
```

### Custom value types

Builtin scalars (`bool`, all integer and float types), `dap.String`, and
`Enumeration` results work out of the box. Any other type must be
default-constructible (`.{}`) and expose:

```zig
pub fn decode(self: *Self, data: []const u8) dap.DecodeError!void
pub fn encode(self: *Self) []const u8
```

```zig
const Port = struct {
    value: u16 = 0,

    pub fn decode(self: *Port, data: []const u8) dap.DecodeError!void {
        self.value = std.fmt.parseInt(u16, data, 10) catch return error.InvalidWire;
        if (self.value == 0) return error.InvalidValue;
    }

    pub fn encode(self: *Port) []const u8 {
        _ = self;
        return "";
    }
};

.port = dap.Option(Port){ .default = dap.Default(Port){ .direct = .{ .value = 8080 } } },
```

`decode`/`encode` are the stable contract; the list is intended to grow with
optional methods (completions and such).

### Help text

```zig
const text = try CLI.helpText(allocator);
defer allocator.free(text);
std.debug.print("{s}", .{text});
```

For an app with `help = "Do things."`, `-v/--verbose`, a `--dry-run` flag, a
grouped `--host`, a `path` argument and `start`/`halt` commands, the output is:

```text
Do things.

Options:
  -v, --verbose  Verbose output.
      --dry-run  Dry run.

Server settings:
      --host <value>  Host.

Commands:
  start
  halt

Arguments:
  path  Path of the file.
```

### Compact help

For a kong-style two-column layout, fill a `HelpData` description and call
`renderCompact`. Short and long names get their own aligned columns, the value
placeholder is `=DEFAULT` for defaults and `=NAME` otherwise, and option
groups are ordered by name with the ungrouped bucket first.

Highlighting follows `App.help_renderer.highlight` (`HelpRendererHighlight`):
`flat` emits plain text, `bold` and `color` use the matching ready
`HelpHighlight` profiles, and `custom` carries a user scheme. The app name,
option names, argument names, group headings and help text each get their own
codes; column widths are measured on the raw text, so the codes never disturb
the alignment.

```zig
var data = try CLI.helpData(allocator);
defer data.deinit(allocator);
const text = try data.renderCompact(allocator);
defer allocator.free(text);
```

```text
Usage: app --dry-run --host=HOST <target> [flags]

Do things.

Arguments:
  <target>    Target directory.

Flags:
  -v, --verbose      Verbose output.
      --dry-run      Dry run.
  -P, --port=8080    Port.

Server settings
  --host=HOST    Host.

Commands:
  start    Start.
  halt     Stop.
```

### Error handling

```zig
var diag: dap.Diag = .{};
defer diag.deinit(allocator);

const cli = CLI.parse(allocator, environ, args, &diag) catch |err| switch (err) {
error.UnknownOption => std.debug.print("unknown option: {s}\n", .{diag.token.?}),
error.MissingValue => std.debug.print("missing value for: {s}\n", .{diag.token.?}),
error.MissingRequired => std.debug.print("missing required: {s}\n", .{diag.field.?}),
error.TooManyArguments => std.debug.print("unexpected argument: {s}\n", .{diag.token.?}),
error.InvalidValue => std.debug.print("{s}: {s}\n", .{ diag.field.?, diag.message.? }),
error.InvalidWire => std.debug.print("invalid value for: {s}\n", .{diag.field.?}),
else => return err,
};
```

---

## Building and testing

```sh
zig build        # compile the module and the example executable
zig build test   # run the unit tests in src/dap.zig
zig test src/dap.zig   # one-off test run
zig build run -- --help   # run the bundled example (src/main.zig)
```
