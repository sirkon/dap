# dap

Declarative command-line parser for Zig (0.17.0).

![example help output](./resources/help-example.svg)

You declare the command line once, as a struct literal. `dap.generate` turns that declaration into a parser and a typed
`View` at compile time, so names, types, defaults and validation are checked by the compiler rather than at runtime.

<!-- BEGIN mktoc -->

- [dap](#dap)
- [A first program](#a-first-program)
- [Common tasks](#common-tasks)
  - ["Not supplied" must be different from zero](#not-supplied-must-be-different-from-zero)
  - [Use the environment, then a literal default](#use-the-environment-then-a-literal-default)
  - [Reject invalid input with a useful message](#reject-invalid-input-with-a-useful-message)
  - [Organize the help page](#organize-the-help-page)
  - [Let the user pick exactly one mode](#let-the-user-pick-exactly-one-mode)
  - [Add subcommands](#add-subcommands)
  - [Accept a value the standard types cannot express](#accept-a-value-the-standard-types-cannot-express)
  - [Shape the help output](#shape-the-help-output)
  - [Offer shell completion](#offer-shell-completion)
  - [Reuse or rename a declaration](#reuse-or-rename-a-declaration)
  - [Free what the parser allocated](#free-what-the-parser-allocated)
- [Reference](#reference)
- [Building and testing](#building-and-testing)
<!-- END mktoc -->

## A first program

**The problem.** A download tool needs a `-l/--login` option with an environment fallback, a checked integer option, a
required file argument, and `--help`.

**The solution.** Write the declaration and generate the parser:

```zig
const std = @import("std");
const dap = @import("dap");

const def = .{
    .login = dap.Flag([]const u8){
        .short = "l",
        .default = dap.Default(dap.String){ .env = "USER" },
        .validation = dap.Validate.stringNotEmpty,
        .help = "User login.",
    },
    .level = dap.Flag(u8){
        .short = "L",
        .default = dap.defaultValue(u8, 1),
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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var diag: dap.Diag = .{};
    defer diag.deinit(arena);

    // `argv[1..]` is pure payload: no binary name, no skipped token.
    var cli = try CLI.parse(arena, init.minimal.environ, argv[1..], &diag);

    std.debug.print("{s} level={d} {s}\n", .{ cli.login, cli.level, cli.path });
}
```

The generated `CLI.View` mirrors the declaration. `cli.login` is a `[]const u8`, `cli.level` a `u8`, `cli.path` a
`[]const u8`; each one has already been decoded and validated.

```sh
$ api-downloader -l alice report.json
$ api-downloader --help
```

`-h`/`--help` is always present. A bad value prints a diagnostic and the relevant help page to stderr and exits
non-zero. A successful parse returns a `View` you own; an arena frees it in one go.

## Common tasks

### "Not supplied" must be different from zero

**The problem.** For an integer or boolean option, `0` and `false` are valid inputs, so a zero value cannot tell whether
the user typed the flag.

**The solution.** Declare an optional flag. Its `View` field becomes `?T`:

```zig
const def = .{
    .jobs = dap.Optional(dap.Flag(u32){ .short = "j", .help = "Worker count." }),
};

if (cli.jobs) |n| {
    std.debug.print("{d} workers\n", .{n});
} else {
    std.debug.print("automatic worker count\n", .{});
}
```

The field is `null` when the flag is absent and contains a normal checked value when it is present. Optional flags
cannot declare defaults, optional `Argument`s are not supported, and validation is skipped while the flag is absent.

### Use the environment, then a literal default

**The problem.** A setting should come from an environment variable, then from a built-in value, and only then fail if
required.

**The solution.** `Default(T)` has an `env` name and a `direct` value; `dap.defaultValue` is shorthand for a direct
default:

```zig
.user = dap.Flag([]const u8){
    .default = dap.Default([]const u8){ .env = "API_USER" },
},
.retries = dap.Flag(u8){
    .default = dap.defaultValue(u8, 3),
},
```

Precedence is **argv > environment > direct default > type zero value**. A flag or argument with a default is optional;
one without a default is required. Only the last positional argument may carry a default.

### Reject invalid input with a useful message

**The problem.** A value looks usable at the type level but is still wrong for the program.

**The solution.** Attach a validation function. Ready-made ones cover non-empty strings and non-zero integers:

```zig
.name = dap.Flag([]const u8){
    .validation = dap.Validate.stringNotEmpty,
},
.count = dap.Flag(u8){
    .validation = dap.Validate.intNotZero(u8),
},
```

A custom validator has the signature `fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String` and returns `null` on
success or a freshly allocated message on failure. Validation runs on wire values, environment values and defaults
alike.

### Organize the help page

**The problem.** A long flag list is hard to scan.

**The solution.** Wrap related flags or arguments in `Group`, optionally with a heading:

```zig
const def = .{
    .server = dap.Group(.{
        .host = dap.Flag([]const u8){ .help = "Host name." },
        .port = dap.Flag(u16){ .default = dap.defaultValue(u16, 8080) },
    }, "Server"),
};
```

`Group` only affects help output; the `View` still has flat `cli.host` and `cli.port` fields. It accepts flags and
positional arguments, not other groups.

### Let the user pick exactly one mode

**The problem.** `--file` and `--url` are alternatives, and passing both is a usage error.

**The solution.** Declare an `Alt`. Each branch is a set of flags; the generated field is a nullable union:

```zig
const def = .{
    .source = dap.Alt(.{
        .file = .{
            .file = dap.Flag([]const u8){ .short = "f", .help = "Read a file." },
        },
        .remote = dap.VariantNamed("net", .{
            .url = dap.Flag([]const u8){ .help = "Read a URL." },
        }),
    }),
};

if (cli.source) |src| switch (src) {
    .file => |p| try readFile(p.file),
    .net => |p| try readUrl(p.url),
} else {
    // no branch was selected
}
```

Branch members must be flags, must not have defaults, and may not be optional. Activating two branches at once is a
parse error. Help shows one alternation clause such as `(--file=FILE | --url=URL)`. A `VariantNamed` overrides the
branch tag used by the union and by help; without it the branch field name is the tag.

### Add subcommands

**The problem.** The program has several verbs (`build`, `serve`) that share global flags but have their own options.

**The solution.** Declare each command as a sibling `Command(meta, def)`. Dispatch with `CLI.command`:

```zig
const def = .{
    .verbose = dap.Flag(bool){ .short = "v" },
    .build = dap.Command(.{ .help = "Compile the project." }, .{
        .jobs = dap.Flag(u8){ .short = "j" },
    }),
    .serve = dap.Command(.{ .help = "Run the server." }, .{
        .addr = dap.Argument([]const u8){ .help = "Listen address." },
    }),
};

if (CLI.command(cli)) |cmd| switch (cmd) {
    .build => |b| try build(b.jobs),
    .serve => |s| try serve(s.addr),
} else {
    try CLI.usage(cli);
}
```

The switch tags are the declaration field names; the command wire name defaults to the field name and can be changed
with `.name = "..."`. Command definitions nest, and `CLI.command` accepts a `View` from any level, so dispatch can go as
deep as the declaration does.

Flags are addressable anywhere on the command line: `app serve --verbose --addr :8080` assigns `--verbose` to the root
`View`. Names must therefore be unique across the whole command tree, which the compiler enforces. `--` ends flag and
command recognition, so literal arguments can follow it.

Help follows the entered path: `app serve -h` describes `serve` with the root flags merged in, and a failure deep in the
tree renders that level's help page.

### Accept a value the standard types cannot express

**The problem.** A flag carries a structured value, such as `HOST:PORT`, or a fixed set of words.

**The solution.** For a fixed set, use `Enumeration`:

```zig
const Mode = dap.Enumeration(.{
    .fast = dap.Enum{},
    .glacial = dap.Enum{ .name = "slow" },
});

.mode = dap.Flag(Mode){
    .default = dap.Default(Mode){ .direct = Mode{ .view = .glacial } },
},

// --mode slow  ->  cli.mode.view == Mode.EnumView.glacial
```

The wire names also feed shell completion. For anything else, provide a type with three methods:

```zig
const Endpoint = struct {
    host: []const u8,
    port: u16,

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) dap.DecodeError!Endpoint {
        const colon = std.mem.indexOfScalar(u8, data, ':') orelse return error.InvalidWire;
        const port = std.fmt.parseInt(u16, data[colon + 1 ..], 10) catch return error.InvalidWire;
        return .{
            .host = try allocator.dupe(u8, data[0..colon]),
            .port = port,
        };
    }

    pub fn encode(self: *Endpoint, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ self.host, self.port });
    }

    pub fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }
};
```

`decode` returns a fully owned value, `encode` returns an allocator-owned wire spelling, and `deinit` releases the
value's internals. `CLI.deinit(&cli, arena)` calls it for every stored field.

### Shape the help output

**The problem.** The built-in help is close, but the program needs a different layout or structured access to the help
model.

**The solution.** The default `App` configuration renders a compact two-column page through `CLI.helpText`:

```zig
const text = try CLI.helpText(allocator);
defer allocator.free(text);
```

For custom rendering, ask for the plain-data model, or choose a custom renderer in `App`:

```zig
var data = try CLI.helpData(allocator);
defer data.deinit(allocator);
const text = try data.renderCompact(allocator);
defer allocator.free(text);
```

```zig
const app = dap.App{
    .name = "api-downloader",
    .help = "Download a file from the API.",
    .help_renderer = .{
        .style = .{ .custom = myRenderer },
        .highlight = .{ .color = {} },
    },
};
```

Highlighting can be plain (`flat`), bold (the default), colored, or a custom `HelpHighlight` scheme. `CLI.usage(view)`
prints the same context-sensitive page for any `View`, which is useful when no subcommand was given.

### Offer shell completion

**The problem.** Users expect Tab completion for flags, subcommands and values.

**The solution.** Generate the script from the same declaration. A common pattern is a hidden `completion` command:

```zig
const Shell = dap.Enumeration(.{
    .bash = dap.Enum{},
    .zsh = dap.Enum{},
    .fish = dap.Enum{},
});

const def = .{
    .completion = dap.Command(.{ .help = "Print a completion script." }, .{
        .shell = dap.Argument(Shell){ .help = "Target shell." },
    }),
};

// in main, before other work:
if (CLI.command(cli)) |cmd| switch (cmd) {
    .completion => |c| {
        try CLI.completion(arena, "api-downloader", switch (c.shell.view) {
            .bash => .bash,
            .zsh => .zsh,
            .fish => .fish,
        }).show(init.io);
        return;
    },
    else => {},
};
```

`CLI.completion(allocator, app_name, shell)` builds a lazy handle for the whole tree. `text()` returns the script,
`show(io)` writes it to stdout, and `install(io, environ)` writes it to the shell's discovery directory. `app_name` is
the name the script registers; it is not `App.name`. Regenerate the script whenever the declaration changes.

Values can be predicted too. Set `completion` on a flag or argument:

```zig
.config = dap.Flag(dap.String){
    .completion = dap.Completion.fs(.{ .wildcard = "*.toml", .root = "config" }),
},
.item = dap.Argument(dap.String){
    .completion = dap.Completion.custom(suggestItems),
},
```

| Declaration                                     | Values offered                         |
| ----------------------------------------------- | -------------------------------------- |
| `null` (default)                                | the shell's normal file completion     |
| `dap.Completion.fs(.{})`                        | same as `null`                         |
| `dap.Completion.fs(.{ .wildcard = "*.zig" })`   | matching files, resolved by the binary |
| `dap.Completion.disabled()`                     | nothing, and no file fallback          |
| `dap.Completion.launch(.{ "git", "ls-files" })` | output of a literal command            |
| `dap.Completion.call("...")`                    | a shell expression inserted verbatim   |
| `dap.Completion.custom(cb)`                     | a callback running inside the binary   |

A predictor replaces the static values for its target. `fs` filters by file name (`*` and `?`), optionally under a
`root` directory; `.type = .dir` lists directories only. `launch` substitutes `$cur` with the word being completed,
while `call` is dialect-specific shell code. Callbacks own every string they return and are invoked through a hidden
route.

The route runs at the very start of `CLI.parse`, before any parsing. An application that inspects files, sockets or
network state before calling `parse` can break completion; do that work after `parse` instead.

### Reuse or rename a declaration

**The problem.** Flags from a library collide with the application's flags, or two independently written option sets
need to be combined.

**The solution.** `dap.Compose` transforms declaration values before `generate`:

```zig
const db = .{ .port = dap.Flag(u16){ .short = "p" } };
const app = .{ .verbose = dap.Flag(bool){ .short = "v" } };

const CLI = dap.generate(dap.App{ .name = "app", .help = "" }, dap.Compose.concat(
    app,
    dap.Compose.shift(db, "db-"),
));
// --verbose, --db-port; -p is dropped by shift
```

`shift(decl, prefix)` prefixes every flag's long name at every level and removes short names; `concat(left, right)`
appends `right`'s fields after `left`'s. Same-named `Group`s with the same heading merge their members, and same-named
`Alt`s merge their branches; other same-named fields, flags, commands or positional names are compile errors. Both
operations are comptime-only and allocation-free.

### Free what the parser allocated

**The problem.** Strings and custom values in the `View` are allocated.

**The solution.** Use an arena, or call the generated deinitializer:

```zig
var cli = try CLI.parse(allocator, environ, args, &diag);
defer CLI.deinit(&cli, allocator);
```

`CLI.deinit` is a namespace function, not a method on the view: `cli.deinit(...)` does not compile. It releases string
fields, custom value internals, the active `Alt` branch and every active subcommand `View`. Call it once, on a `View`
from a successful parse.

## Reference

The complete API, constraints and behavioral details are in [AGENTS-SDK.md](./AGENTS-SDK.md).

## Building and testing

```sh
zig build                  # compile the module and the example
zig build test             # unit tests for the core and composition
zig build completion-test  # opt-in: generated scripts in real shells
zig build run -- --help
```

`completion-test` is opt-in and never runs as part of `zig build test`; a missing shell is reported and skipped.
