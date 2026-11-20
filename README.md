# dap

Declarative command-line parser for Zig (0.17.0).

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
  `--dry_run`). A dash-spelled name requires an explicit `.long`. A declaration
  field name must not start with `_`; the leading underscore is reserved for
  the `_`-prefixed command fields the `View` carries.
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
  sibling field of the parent declaration; in the `View` the parsed sub-view
  is stored under a `_`-prefixed field (`_cmd`). Reach the active command
  through the optional tagged union `CLI.command(cli)`, whose tags are the
  plain declaration field names (no `_`): `if (CLI.command(cli)) |cmd| switch
  (cmd) { ... } else { ... }`. It is present only when the level declares
  subcommands; `--` disables handoff so command-like literals can be passed.
  The same accessor accepts a sub-`View` from any level, so dispatch nests:
  `if (CLI.command(body)) |sub| switch (sub) { ... } else { ... }`. A leaf
  view (a level with no subcommands) is a compile error.
  A flag token after the command that matches no sub flag is retried against
  every ancestor level, so parent flags (advertised in deep help, globally
  unique) resolve wherever they are typed.
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
- **Ownership.** Every field of a `View` returned by a successful `parse` is
  owned by the caller: string slices (wire, env and direct defaults) are
  duplicated with the parser's allocator, and custom-type fields own their
  internals. Release them with `CLI.deinit(&view, allocator)` — a namespace
  function, not a method on the view (`view.deinit(...)` does not compile); it
  is valid once and not idempotent, and the local view must be `var`. An arena
  remains the simplest lifetime. `Diag.deinit` frees only the diagnostic
  `message`.

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
pub fn decode(allocator: std.mem.Allocator, data: []const u8) dap.DecodeError!Self
pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void
```

`decode` is a static constructor returning a fully built value, so a type with
internal allocations can own them (`dap.DecodeError` folds in the allocator's
error set for this reason); `encode` returns an allocator-owned wire spelling
that the caller frees; `deinit` releases the value's internals and must not
call `allocator.destroy(self)`. Free a parsed `View` with
`CLI.deinit(&view, allocator)` — a namespace function taking the view by
pointer, not a method on the view (`view.deinit(...)` does not compile).

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

## Completion

`CLI.completion(allocator, app_name, shell)` renders a complete completion
script for the whole command tree. It is a pure function of the declaration:
it takes no `View`, never parses, reads no environment and does no file I/O.

```zig
const dap = @import("dap");

const script = try CLI.completion(arena.allocator(), "app", .zsh);
```

`CompletionShell` is `.bash`, `.zsh` or `.fish`; the result is a caller-owned
`[]const u8` (a `dap.String`) with exactly one trailing newline, and failures
are `OutOfMemory` or `dap.CompletionError.InvalidAppName`. The output is
deterministic, so it can be regenerated and diffed.

`app_name` is the name the script **registers**, not `App.name` (which is the
possibly multi-word usage path). It is validated before any allocation: it
must be non-empty ASCII, must not start with `-`, must not contain `/`,
whitespace or control bytes, and may only use `A-Za-z0-9._+-`. Passing a
different name than the installed binary is the intended way to install under
an alias.

`completion` exists on every generated namespace but may only be called on the
root one: a call from a subcommand level is a compile error, because a subtree
cannot reconstruct its ancestors' flags.

### Candidate selection and ordering

The script tracks the command level and counts completed positional words as
it scans (`pos`). Flags that consume a value, `--flag=value` tokens and
everything after `--` are skipped, so they never count as positionals.

With an empty current word the script shows one phase only:

1. subcommands, when the level has any;
2. otherwise the next unfilled positional slot's values, when that slot is an
   enumeration (every declared slot counts, including one with a default);
3. otherwise flags.

A non-empty prefix shows every matching candidate across the three categories,
but only the current positional slot's values. Enumeration values are offered
as-is; other argument types contribute nothing, so the flag phase opens
instead. Typing `-` or `--v` reaches the flags even while a positional is
still pending.

A long flag pairs with its short alias, and a command with its synonym. zsh
and fish merge a pair into one row when both spellings match the prefix; the
row inserts the spelling that matched, so typing `-d` completes `-d`, not
`--description`. When only the long spelling matches, the long is inserted.

Ordering is:

1. `normal` entries first, then `version` (`-v`/`--version`/`version`), then
   `help` (`-h`/`--help`/`help`) strictly last;
2. inside a family, entries with help before entries with empty help;
3. ASCII order by the inserted spelling.

zsh renders a left-aligned table with exactly two spaces between columns:
`--description  -d  -- Description of context.`. It uses three columns when at
least one displayed row merged and two otherwise; a row with empty help has no
`-- ` separator and no trailing padding. fish prints one
`candidate<TAB>description` line per row (the alias rides in the description
for a merged row) and registers with `-k` so that order survives fish's own
sorting; fish lays out the description itself. bash keeps plain names in
`COMPREPLY`, one per spelling, and keeps `-o default` as the file fallback.

A typical `completion` subcommand in `main` prints the script and returns
before doing anything else:

```zig
if (CLI.command(cli)) |cmd| switch (cmd) {
    .completion => |c| {
        const script = try CLI.completion(arena, "app", switch (c.shell.view) {
            .bash => .bash,
            .zsh => .zsh,
            .fish => .fish,
        });
        try stdout.writeAll(script);
        return;
    },
    else => {},
};
```

The library only returns the script; saving it is up to the program. With the
script written to a file:

```sh
app completion bash > /etc/bash_completion.d/app
app completion zsh  > "${fpath[1]}/_app"
app completion fish > ~/.config/fish/completions/app.fish
```

The zsh file name must match the autoload function `_<ident>`, where `ident`
is `app_name` with every byte outside `[A-Za-z0-9_]` replaced by `_`
(`my-app` -> `_my_app`). The registration itself always uses `app_name`
verbatim: bash's trailing `complete` line and fish's `complete -c` need no
external file naming, and a single script registers exactly one name.

Regenerate the script whenever flags or commands change; it is a snapshot, not
a runtime query. Limitations: identifier sanitization is not injective
(`my-app` and `my_app` both map to `_my_app`), so two `dap` CLIs sourced into
one bash or fish session can collide; zsh is namespaced by the function name.
All three shells have semantic integration tests: bash and fish run real
completion cases, and zsh runs the generated function against a `compadd`
stub that captures the displayed rows, plus syntax and autoload smoke tests.

## Building and testing

```sh
zig build                  # compile the module
zig build test             # run the unit tests in src/dap.zig
zig build completion-test  # run generated scripts through real shells
```

`completion-test` is opt-in: `zig build test` never compiles the shell
integration file or spawns a shell. The completion test runs `bash -n`,
`zsh -n` and `fish -n`, semantic bash and fish cases, and a zsh sourcing smoke
test; a missing shell prints a notice and skips that shell.
