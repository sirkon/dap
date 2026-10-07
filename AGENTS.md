# AGENTS.md

## Project

`dap` is a declarative command-line parser for Zig. Users describe program
flags and arguments with a struct-based DSL; `dap.generate` produces both a
strongly-typed *view* (a generated `View` struct) and a *parser* from that
declaration.

## Status: implemented

The core pipeline is implemented and green. `zig build test` and
`zig test src/dap.zig` both pass (158 tests, the milestone-tagged M1–M15
blocks). There is no `PLAN.md`; the test names are the plan of record.

- `src/dap.zig` holds everything: DSL types, spec normalization, `generate`,
  `Enumeration`, `Command`, `Alt`, runtime help (`HelpData` +
  `renderHelpWithStyle`/`renderCompact`), `DecodeError`/`ParseError`, `Diag`,
  and the test suite.
- `src/root.zig` re-exports the public surface from `dap.zig` (no
  `usingnamespace` in Zig 0.16; exports are explicit).
- `build.zig` exposes a public `dap` module rooted at `src/root.zig`, builds a
  `dap-example` executable from `src/main.zig` with a `run` step, and a `test`
  step compiling/running tests from `src/dap.zig`.
- `build.zig.zon` sets `.name = .dap` and `.minimum_zig_version = "0.16.0"`.
  Match that version.

Checks: `zig build test`, `zig test src/dap.zig`, `zig build run -- --help`.

## Layout

- `src/dap.zig` — core implementation. Public data types (`Kind`,
  `HelpRendererStyle`, `HelpRendererHighlight`, `App`, `HelpHighlight`,
  `String`, `Default(T)`, `defaultValue`, `Flag(T)`, `Optional`, `Group`,
  `Argument(T)`, `Enumeration`, `Enum`, `CommandMeta`, `Command`,
  `VariantNamed`, `Alt`, `Validate`, `DecodeError`, `ParseError`, `Diag`,
  `HelpData`) come first.
- The private compact-help scaffolding (`HelpStyle`, `HelpSegment`, `HelpRow`,
  `HelpSection`, `helpStyleCode`, `helpSegmentsWidth`, the `appendHelpStyled`/
  `appendHelpSegments`/`appendFlagUsage` family, `upperDup`), the file-private
  `HelpData` free helpers (`freeFlag`/`freeFlags`/`freeFlagGroups`/
  `freeArguments`/`freeArgGroups`/`freeCommands`), the scope-merge family
  (`emptyHelpData`, `sameGroupName`, `absorbScope`, `isBuiltinHelp`,
  `dedupeBuiltinHelp`, `appendActiveScopes`, `contextHelpText`) and the
  builtin-help injection helpers (`builtin_help_field`, `BuiltinHelp`,
  `MergedDecl`, `withBuiltinHelp`, `renderHelpWithStyle`) follow.
- Then the public `generate` entry point (its namespace body named `Base`, plus
  the conditional forwarding shell that adds `CommandPayload`/`command` when
  commands exist), then the private normalization/decode helpers (`Spec`,
  `Defaults`/`DefaultRepr`, `normalize`, `specFromField`,
  `groupSpecs`, `altSpecs`, `specViewType`, `assignValue`, `helpRequested`,
  `validateAlt`, `resolveAbsent`, the `check*` validators plus
  `FlagOrigin`/`levelPath`/`collectFlagOrigins`/`checkGlobalFlagNames` and
  `Sub`/`subApp`/`CommandPayloadOf`), then the test blocks.
- `src/root.zig` — public module root; explicit re-exports from `dap.zig`.

## Conventions

- The DSL relies on Zig `comptime` parameters throughout
  (`generate(comptime app: App, comptime def: anytype)`); generated code
  operates on types, not runtime values.
- Public doc comments (`///`) carry usage examples written as fenced Zig code
  inside the comments — keep this pattern when adding API surface.
- Custom value types must provide two public methods to be usable:
  `pub fn decode(self: *Self, data []const u8) DecodeError!void` and
  `pub fn encode(self: *Self) []const u8`. Builtin numeric types and
  `[]const u8` (aliased as `dap.String`) work out of the box, as do
  `Enumeration` results.
- Validation functions share the signature
  `fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String`: return `null` on
  success, an allocated error message string on failure. See
  `Validate.stringNotEmpty` / `Validate.intNotZero(u8)` (a per-integer factory).
- `required` is derived, never declared: a flag/argument is required iff it
  has no default. Boolean flags are exempt: a defaultless bool is always
  optional (an omitted bool flag is `false`) and renders bracketed (`[--flag]`)
  in the usage header; a `true` direct default is a `@compileError` in
  `specFromField`; a bool carrying an explicit `false` default is omitted from
  the usage header. `Argument` supports a default only on the last declared
  argument.
- Optional flags are declared with an optional-typed field, either via the
  `Optional(Flag(T){...})` helper or the raw `@as(?Flag(T), Flag(T){...})`
  spelling (both store a `?Flag(T)`). Detection is purely type-driven in
  `specFromField` (`@typeInfo(f.type) == .optional`), which sets
  `Spec.optional`, unwraps to `vtype = T`, and forces `required = false`. The
  generated `View` field is `?T` (via `specViewType`); absent flags resolve to
  `null` (`resolveAbsent`), wire values are decoded into a temp and wrapped
  (`assignValue`), and Phase 4 VALIDATE skips validation on `null`. Optional
  flags must not declare a default (direct or env), optional `Argument`s are
  rejected (`?Argument`), and optional flags are banned inside `Alt` branches.
  `HelpData.Flag.optional` marks them and `renderCompact` omits them from the
  usage clause.
- Wire names are verbatim field names (`dry_run` → `--dry_run`); a dash-spelled
  name requires an explicit `.long`.
- `Alt(.{...})` declares exclusive branches of flags (`VariantNamed` overrides
  a branch tag). `normalize` flattens each branch into the parent spec list with
  `Spec.group = tag`, `Spec.alt`/`Spec.alt_branch` set; `generate` appends one
  `?AT.Union` field per Alt before the command fields. Parsing tracks
  activation in `assignValue` (materializing the union on first touch,
  `ConflictingAlt` on a second branch) and `validateAlt` runs in Phase 1.5;
  Alt members are skipped by the flat POST-PASS/VALIDATE phases, and `Alt`
  itself already rejects zero branches, duplicate tags, non-flag members,
  defaulted members, and optional members at comptime. `checkGroupDefs`
  rejects an Alt tag colliding with a `Group` name.
- Subcommands are sibling `Command(meta, def)` fields. `normalize` collects
  them via the `.command` `dap_kind` dispatch into `NormResult.commands`, a
  slice of `CommandEntry` (`field` = declaration/View field, `name` =
  `cmd_meta.name orelse field`, `Cmd` = the `Command(...)` type). `Sub(c.Cmd,
  subApp(app, c))` generates each sub-namespace: `subApp` builds the child
  `App` from the parent's path anchor (`App.name ++ " " ++ c.name`, wire
  names), the command's `CommandMeta` help/i18n, and the parent's renderer, so
  every level knows its full usage path. `generate` appends one
  `?Sub(c.Cmd, subApp(app, c)).View` field per command after the Alt fields;
  parsing hands off to `Sub(...).parseInnerHelp` and assigns the sub-View
  directly (no tagged union). Duplicate command wire names at a level and
  command-field names colliding with a spec are compile errors
  (`checkCommandNames` / `checkCommandFieldNames`); mixing commands with
  positional arguments in one declaration is also rejected
  (`checkCommandArgumentMix`), since a command token hands off the rest of the
  wire and a parent positional could never be filled; a level with no command
  fields simply has none. Flag long names and short aliases must be *globally*
  unique across the whole command tree (not just per level):
  `collectFlagOrigins` recursively re-`normalize`s each level's subtree (group
  and Alt members included, the injected builtin and positional arguments
  excluded) and `checkGlobalFlagNames` rejects any long/long or short/short
  collision with both level paths in the message; sibling commands are covered
  too. This runs in `generate` right after `normalize`'s own per-level checks.
- A level that declares commands additionally exposes a switch-shaped accessor
  (D7–D10). Because Zig 0.16 has no `comptime if` at container scope, `generate`
  builds its namespace under a local `Base` and, when `cmd_entries.len == 0`,
  returns `Base` verbatim (accessor pair absent — `@hasDecl` is `false`, so a
  reference is a "no member named 'command'" compile error). Otherwise it
  returns a thin forwarding shell: `pub` aliases for `app_meta`, `specs`,
  `commands`, `View`, `parse`, `helpData`, `helpText` (plus non-pub
  `parseInner`/`parseInnerHelp`, preserving same-file visibility and the parent
  handoff), and the `pub const CommandPayload` / `pub fn command(view)
  ?CommandPayload` pair. `CommandPayloadOf(app, cmd_entries)` (beside
  `Sub`/`subApp`) synthesizes the union with the same `@Enum`/`@Union(.auto,
  ...)` machinery `Alt` uses: one member per `CommandEntry`, tag = `c.field`
  (declaration field name, not the wire name), payload = `Sub(c.Cmd,
  subApp(app, c)).View`, the exact expression the `View` field type uses, so
  identities match bit-for-bit. `command` is infallible and allocation-free: it
  `inline for`s the command fields and `@unionInit`s the first non-null one
  (the single handoff guarantees at most one is set), returning `null` when
  none was activated. Zero commands never synthesize the union (a zero-field
  `@Union` is illegal); one command uses `std.math.IntFittingRange(0, 0)`.
- A `-h, --help` bool flag is injected as `.builtin_help` at index 0 of every
  declaration before normalization (`BuiltinHelp` / `withBuiltinHelp`), so it
  appears first in `View` and in the flags section. It carries
  `.i18n = "builtin.help"` and a `false` direct default.
- Help is runtime-filled, not comptime-rendered. `helpData(allocator)` walks
  the comptime-known `specs`/`commands` and duplicates everything into a
  caller-owned `HelpData` (released with `HelpData.deinit`); it also records
  the app's `HelpRendererHighlight` scheme and fills `usage_alts` (one
  `HelpData.Usage` per `Alt`, its branch flag slices aliasing entries owned by
  `flag_groups`). `helpText` renders it via the file-private
  `renderHelpWithStyle`, which dispatches on `App.help_renderer.style`
  (`.compact` → `HelpData.renderCompact`, `.custom` → the user function), and
  `renderCompact` renders a kong-style two-column layout inline, applying the
  scheme after all column widths have been measured on the raw text. Nothing
  help-related runs unless one of those is called.
- Help is *context-sensitive*. A `-h`/`--help` anywhere in the active command
  chain is detected by `helpRequested` (a comptime walk of the View command
  fields); `parseInnerHelp` carries an `ancestor_help` flag through the handoff
  so a help token before the commands is honoured too, and Phase 2 of every
  `parseInner` early-returns on it, bypassing all required checks and
  validations. `contextHelpText` then builds one `HelpData` per active level
  (root first) via `appendActiveScopes`, folds them with `absorbScope` (flag
  groups merge by name with move semantics, `usage_alts` append, and arg
  groups/commands/info/name come from the deepest scope so the usage header
  reads `app svc build`), dedupes the repeated injected builtin via
  `dedupeBuiltinHelp`, and renders once. Root-scope help is byte-identical to
  the pre-merge path; failure help (`printFailureExit`) stays root-scoped.
- Ordering inside `src/dap.zig`: public data types first, then private
  help/builtin scaffolding, then the public `generate` entry point, then
  private normalization/decode helpers, then tests.

## Notes

- `.gitignore` excludes build artifacts (`.zig-cache/`, `zig-out/`, `zig-pkg/`)
  and editor dirs (`.idea/`, `.zed/`, `.vscode/`).
- There is no compile-fail harness; comptime-negative cases are documented as
  commented-out or `if (false)`-guarded declarations in the test blocks and are
  verified by manually enabling them.
