# Subcommands dispatcher

Promoted from `.contexts/subcommands-dispatcher/5.md`.

## Goal

Nested subcommands must dispatch through one namespace-level accessor, without
naming child namespaces and without reach-through into `_`-prefixed fields:

```zig
if (CLI.command(cli)) |cmd| switch (cmd) {
    .body => |b| {
        if (CLI.command(b)) |subcmd| switch (subcmd) {
            .left => |l| runLeft(l),
            .right => |r| runRight(r),
        } else {
            // `body` with no subcommand token
        }
    },
} else {
    // root level execution
}
```

The same accessor accepts the root `View` and any nested sub-`View`, and
returns that level's tagged union of active command payloads. Declaration
syntax, parser behaviour, and `View` field access stay unchanged.

## Public API

For a level that declares commands, the generated namespace exposes:

```zig
pub const CommandPayload = CommandPayloadOf(app, cmd_entries);
pub fn command(view: anytype) ?NodeOf(@TypeOf(view)).CommandPayload;
pub fn usage(view: anytype) std.mem.Allocator.Error!void;
```

`command` is infallible and allocation-free. It copies the view value; it does
not take ownership and does not change `CLI.deinit(&view, allocator)`
semantics. It accepts `View` values only: `*View` and `*const View` are type
errors, like any other wrong argument type.

The payload union has one member per command field. The tag is the plain
declaration field name; the payload is that level's sub-`View` type:

```
CommandPayload = @Union(.auto, Tag, names, types, attrs)
tag    = c.field                                  // `config`, `run`, ...
payload = Sub(c.Cmd, subApp(app, c)).View
```

`command` returns `null` when no command field is active. When one is active,
`@unionInit` wraps it. A level with no command fields has no `command` member
at all (`@hasDecl` is false), which is unchanged.

## `View` identity: the `__commandN` tag

`View` is built with `@Struct`, and Zig interns struct types structurally: two
levels whose field names, order, and types match are the same type. Real trees
hit this immediately; every flagless leaf is `{ builtin_help: bool }`. A
`View` type would then identify several levels and dispatch could resolve the
wrong level's namespace.

Every generated `View` therefore carries one extra field:

- **name:** `std.fmt.comptimePrint("__command{}", .{rank})`;
- **type:** `u0`, so it is zero-sized and adds nothing to the layout;
- **position:** after the spec fields and before the `Alt` and command fields,
  so `builtin_help` stays first and the documented field order is otherwise
  preserved.

Collision-freedom is structural. Declaration field names may not start with
`_`, command `View` fields do, so `__commandN` cannot collide with either. Two
levels cannot share a rank because ranks are a bijection onto the command
nodes.

Parsing never reads or writes the tag (`var v: View = undefined` stays sound),
`deinit` iterates the specs/`Alt`/command tables by name, and help and
suggestions never enumerate `View` fields. It only makes the type unique.

### Rank threading

The rank is the level's pre-order position in the whole command tree: the root
is `0`, each following command node gets the next number. It is computed
structurally, without a mutable cursor:

- `normalizeRanked(def, base_rank)` numbers a level's commands: the first
  child is `base_rank + 1`, each next sibling adds `1 +` the command nodes in
  the preceding sibling's subtree.
- `commandSubtreeCount(def)` counts those nodes by walking raw `Command(...)`
  fields; it never instantiates `generate`.
- `CommandEntry.rank` carries the number; `App._command_rank` (internal,
  defaults to `0`) carries it into the level; `subApp(parent, c)` sets the
  child's rank from `c.rank`.
- `normalize(def)` remains `normalizeRanked(def, 0)`; flag-table
  re-normalization in `collectFlagOrigins` ignores ranks.

## Dispatch resolution

The shell carries a comptime registry:

```zig
const Nodes: []const type = commandNodes(@This());
```

`commandNodes(NS)` returns `NS` followed by every command node below it in
pre-order. Child namespaces are rebuilt with the same
`Sub(c.Cmd, subApp(NS.app_meta, c))` expression the parent `View` and
`CommandPayload` use, so Zig returns the identical instantiation. The
recursion is lazy and terminates: child `Nodes` declarations are not read.

`NodeOf(V)` matches `NS.View == V` over that registry. Because the tag makes
every level's `View` type distinct, the first match is the only match. Two
failure modes are compile errors:

- a leaf view (a level with no commands):
  `dap.command: a leaf View of '<level path>' declares no subcommands`;
- a foreign value:
  `dap.command: argument is not a command View of '<root path>'`.

`command` iterates the resolved namespace's command fields, reads the
`_`-prefixed sub-view field, and unions the first non-null one. A single
handoff guarantees at most one is set.

## Context-sensitive usage

`usage(view)` prints the same merged help that a `-h`/`--help` token would
print for the state stored in `view`. It is generic over the `View` type, like
`command`, so any level's view is accepted.

`usageChain(NS, V)` walks the command tree by type and returns the namespaces
from the namespace the call is made on down to the level owning `V`, root
first. `contextHelpText` then:

1. builds one `HelpData` per chain entry and folds them with `absorbScope`
   (flag groups merge by name; arguments, commands, info, and name come from
   the deepest scope; `Alt` usage clauses accumulate);
2. appends the scopes of descendants still active in `view`;
3. dedupes the repeated injected `-h, --help`;
4. renders once with the outermost chain entry's renderer.

Both values and pointers are accepted (`viewValueType` unwraps pointer
layers), so the parse intercept's `&result` and a user's `usage(v)` work.

Consequences:

- `CLI.usage(cli)` on the root namespace is byte-identical to the previous
  root-vs-context behaviour: the chain is the root, and active descendants are
  appended as before.
- `CLI.usage(c)` inside a subcommand branch prints that level's merged help,
  including ancestor flags and still-active descendants.
- A leaf view is legal: it has its own scope even though `command` rejects it.
- A foreign view is
  `dap.usage: argument is not a command View of '<root path>'`.
- Calling `usage` on a namespace deeper than the root merges from that
  namespace down. The root namespace is the canonical form because it can
  reproduce the parse intercept's full ancestor chain.

On a parse failure (not a help request) help stays root-scoped, because the
command path is not reconstructed from `Diag`.

## Surfaces left unchanged

- No declaration syntax changes; commands remain sibling `Command(...)` fields.
- No child-namespace re-export: there is no `CLI.body.command(b)` and no
  `CLI.body.View`. Nesting uses the one generic accessor.
- The wire scan, ancestor flag retry, required/validation phases, typo
  suggestions, help data collection, and `deinitValue` are untouched.
- `parse` keeps its terminating contract: help prints to stdout and exits `0`;
  failure prints diagnostics plus root-scoped help to stderr and exits `1`.
