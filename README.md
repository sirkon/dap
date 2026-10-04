# dap

Declarative command-line parser for Zig (0.16.0).

Describe your program's options and arguments with a struct-based DSL;
`dap.generate` builds both a value representation and a parser from that
declaration.

```zig
const dap = @import("dap");

const def = .{
    .login = dap.Option([]const u8){
        .short = "l",
        .default = dap.Default(dap.String){ .env = "USER" },
        .validation = dap.Validate.stringNotEmpty,
        .help = "User login.",
    },
    .verbosity = dap.Option(u8){
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
- **Derived `required`.** An option or argument is required iff it has no
  default. This is uniform, `bool` included: a required flag must be passed
  (as `--flag`, `--flag=true` or `--flag=false`).
- **Defaults.** Env defaults (`Default(T){ .env = "NAME" }`) take precedence
  over direct defaults (`Default(T){ .direct = v }`). A default is allowed
  only on the last declared argument.
- **Subcommand handoff.** A positional token equal to a registered command name
  terminates the current parse and calls that subcommand's `parse` with the
  payload after the command token. The result is a `?Union` the caller switches
  over manually; `--` disables handoff so command-like literals can be passed.
- **Ownership.** Strings stored in `Values` are allocated with the parser's
  allocator; an arena is the intended lifetime. `Diag.deinit` frees only the
  diagnostic `message`.

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

Short and long option names occupy their own aligned columns; the value
placeholder is `=DEFAULT` for defaults and `=NAME` (upper-cased) otherwise.
Option groups are ordered by name with the ungrouped bucket first.

Highlighting follows `App.help_renderer.highlight` (`HelpRendererHighlight`):
`flat` emits plain text, `bold` (the default) and `color` apply the matching
ready `HelpHighlight` profiles, and `custom` carries a user scheme. Column
widths are measured on the raw text, so the codes never disturb alignment.

## Building and testing

```sh
zig build        # compile the module
zig build test   # run the unit tests in src/dap.zig
```
