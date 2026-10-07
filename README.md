# dap

Declarative command-line parser for Zig (0.16.0).

Describe your program's flags and arguments with a struct-based DSL;
`dap.generate` builds both a parser and a strongly-typed view from that
declaration.

```zig
const dap = @import("dap");

const def = .{
    .login = dap.Flag([]const u8){
        .short = "l",
        .default = dap.Default(dap.String){ .env = "USER" },
        .validation = dap.Validate.stringNotEmpty,
        .help = "User login.",
    },
    .password = dap.Flag([]const u8){
        .short = "p",
        .help = "User password.",
        .default = .{
            .env = "API_PASSWORD",
        },
    },
    .verbosity = dap.Flag(u8){
        .short = "V",
        .validation = dap.Validate.intNotZero(u8),
        .help = "Verbosity level.",
    },
    .path = dap.Argument([]const u8){
        .validation = dap.Validate.stringNotEmpty,
        .help = "Path of the file to download.",
    },
};

const CLI = dap.generate(
    dap.App{ .name = "api-downloader", .help = "Download a file from the API." },
    def,
);

// `args` is pure payload: pass it with the binary name already removed.
var diag: dap.Diag = .{};
const cli = try CLI.parse(arena.allocator(), environ, args, &diag);
std.debug.print("{} {}\n", .{ cli.login, cli.path });
```

## Semantics

- **Pure payload.** Every `parse` — root and subcommand alike — iterates `args`
  from index `0` and never skips a token. Pass the arguments with the binary
  name already removed (`os.argv[1..]`).
- **Verbatim names.** Field names are wire names verbatim (`dry_run` ->
  `--dry_run`). A dash-spelled name requires an explicit `.long`.
- **Derived `required`.** A flag or argument is required iff it has no
  default. Boolean flags are the exception: they are always optional (an
  omitted bool flag is `false`), a `true` default is a compile error (use a
  negative `.long` name defaulting to `false`), and an optional bool renders
  bracketed (`[--flag]`) in the usage header.
- **Defaults.** Env defaults (`Default(T){ .env = "NAME" }`) take precedence
  over direct defaults (`Default(T){ .direct = v }`). A default is allowed
  only on the last declared argument.
- **Optional flags.** Wrap a flag in `dap.Optional(...)` (or write
  `@as(?Flag(T), Flag(T){...})`) and the View field becomes `?T`, `null` when
  the flag is absent. Optional flags must not declare defaults and their
  validation skips a `null` value.
- **Subcommand handoff.** A positional token equal to a registered command name
  terminates the current parse and calls that subcommand's `parse` with the
  payload after the command token. Each command is a `dap.Command(meta, def)`
  sibling field of the parent declaration and yields one `?View` the caller
  unwraps with `if (cli.cmd) |sub| ...`; `--` disables handoff so command-like
  literals can be passed. A declaration with commands also exposes an optional
  tagged union, `CLI.command(cli)`, whose tags are the declaration field names:
  `if (CLI.command(cli)) |cmd| switch (cmd) { ... } else { ... }`. It is
  present only when the level declares subcommands.
- **Exclusive groups.** An `Alt` field declares branches of mutually exclusive
  flags. A branch activates when any of its members is seen; only flags are
  allowed inside branches and defaults are forbidden. The generated field is a
  `?Union` (`null` when no branch was seen); passing flags from two branches of
  the same `Alt` is a `ConflictingAlt` parse error. Each branch becomes a help
  group named after its field or its `VariantNamed` override.
- **Global flag uniqueness.** Flag long names and short aliases must be unique
  across the *entire* command tree (siblings included), not merely within a
  level. Deep help merges flags from every ancestor, so a reused name would be
  ambiguous; a collision is a compile error naming both level paths.
- **Ownership.** Strings stored in the `View` are allocated with the parser's
  allocator; an arena is the intended lifetime. `Diag.deinit` frees only the
  diagnostic `message`.

## Optional flags

An optional flag is a flag declared with an optional type. Both spellings
store a genuine `?Flag(T)` in the declaration:

```zig
const def = .{
    .jobs = dap.Optional(dap.Flag(u32){ .short = "j" }),
    .label = @as(?dap.Flag([]const u8), dap.Flag([]const u8){ .long = "label" }),
};
```

The generated field is `?T` and is `null` when the flag is absent from
`argv`; a present value decodes and validates as usual, while `null` skips
validation. Optional flags must not declare a default, optional
`Argument`s are rejected, and optional flags are not allowed inside `Alt`
branches.

## Custom value types

Builtin scalars, `dap.String` (`[]const u8`) and `dap.Enumeration` results work
out of the box. Other types must expose:

```zig
pub fn decode(self: *Self, data: []const u8) dap.DecodeError!void
pub fn encode(self: *Self) []const u8
```

## Help

`CLI.helpText(allocator)` renders a simple section-per-group layout. For a
compact, kong-style two-column layout, fill a description with
`CLI.helpData(allocator)` and call `renderCompact`:

```zig
var data = try CLI.helpData(allocator);
defer data.deinit(allocator);
const text = try data.renderCompact(allocator);
defer allocator.free(text);
```

```text
Usage: dap-example [<target>] [flags]

Manual test of the dap module.

Arguments:
  [<target>]    Target directory.

Flags:
  -h, --help        Show context-sensitive help.
      --source=.    Source directory.
  -l, --last        Show last modification.

Group
      --count=1    Number of items.
  -v, --value=1    Value of items.
```

Short and long flag names occupy their own aligned columns; the value
placeholder is `=DEFAULT` for defaults and `=NAME` (upper-cased) otherwise.
Flag groups are ordered by name with the ungrouped bucket first.

Alternative (`Alt`) flags are not listed individually in the usage line.
Instead each `Alt` contributes one parenthesized alternation clause, one
branch per `VariantNamed` tag (or field name), with the branch's member flags
joined by spaces and the branches separated by `|`:

```text
Usage: dap-example (--file=FILE | --url=URL) <string> [flags]
```

`HelpData` exposes this structure directly as `usage_alts`, a slice of
`HelpData.Usage` (one per `Alt`), each holding its branches as slices of
`HelpData.Flag` referencing the entries also present in `flag_groups`.

Help is **context-sensitive**: after one or more subcommands, `-h`/`--help`
describes the deepest active command. The usage header reconstructs the command
path, arguments and next-level subcommands come from that deepest scope, and
flags are merged from every ancestor level. `Group`/`Alt` groups sharing a name
across levels merge into one block, and the injected `-h, --help` appears once.

```text
$ app command-2 info -h
Usage: app command-2 info --required=REQUIRED [--flag] [flags]

Info about command 2.

Flags:
  -h, --help                 Show context-sensitive help.
      --required=REQUIRED    Mandatory value.
      --value=               Command 2 value.
      --details=             Info details.
```

Highlighting follows `App.help_renderer.highlight` (`HelpRendererHighlight`):
`flat` emits plain text, `bold` (the default) and `color` apply the matching
ready `HelpHighlight` profiles, and `custom` carries a user scheme. The scheme
is nested: a usage header block (app name, required flag name/value, optional
tokens, arguments) plus `groups`, `args` and `flags` (name/value) tokens for
the sections. Brackets stay inside their highlight blocks and the flag list
wraps each short/long name separately. Column widths are measured on the raw
text, so the codes never disturb alignment.

## Building and testing

```sh
zig build        # compile the module
zig build test   # run the unit tests in src/dap.zig
```
