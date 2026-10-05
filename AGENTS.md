# AGENTS.md

## Project

`dap` is a declarative command-line parser for Zig. Users describe program
flags and arguments with a struct-based DSL; `dap.generate` produces both a
strongly-typed *view* (a generated `View` struct) and a *parser* from that
declaration.

## Status: implemented

The core pipeline is implemented and green. `zig build test` and
`zig test src/dap.zig` both pass (134 tests, the milestone-tagged M1–M13
blocks). There is no `PLAN.md`; the test names are the plan of record.

- `src/dap.zig` holds everything: DSL types, spec normalization, `generate`,
  `Enumeration`, `Commands`, `Command`, `Alt`, runtime help (`HelpData` +
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
  `Argument(T)`, `Enumeration`, `Enum`, `Commands`, `CommandMeta`, `Command`,
  `VariantNamed`, `Alt`, `Validate`, `DecodeError`, `ParseError`, `Diag`,
  `HelpData`) come first.
- The private compact-help scaffolding (`HelpStyle`, `HelpSegment`, `HelpRow`,
  `HelpSection`, `helpStyleCode`, `helpSegmentsWidth`, the `appendHelpStyled`/
  `appendHelpSegments`/`appendFlagUsage` family, `upperDup`) and the
  builtin-help injection helpers (`builtin_help_field`, `BuiltinHelp`,
  `MergedDecl`, `withBuiltinHelp`, `renderHelpWithStyle`) follow.
- Then the public `generate` entry point, then the private normalization/decode
  helpers (`Spec`, `Defaults`/`DefaultRepr`, `normalize`, `specFromField`,
  `groupSpecs`, `altSpecs`, `specViewType`, `assignValue`, `validateAlt`,
  `resolveAbsent`, the `check*` validators), then the test blocks.
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
  `?AT.Union` field per Alt before the trailing `Commands` field. Parsing tracks
  activation in `assignValue` (materializing the union on first touch,
  `ConflictingAlt` on a second branch) and `validateAlt` runs in Phase 1.5;
  Alt members are skipped by the flat POST-PASS/VALIDATE phases, and `Alt`
  itself already rejects zero branches, duplicate tags, non-flag members,
  defaulted members, and optional members at comptime. `checkGroupDefs`
  rejects an Alt tag colliding with a `Group` name.
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
- Ordering inside `src/dap.zig`: public data types first, then private
  help/builtin scaffolding, then the public `generate` entry point, then
  private normalization/decode helpers, then tests.

## Notes

- `.gitignore` excludes build artifacts (`.zig-cache/`, `zig-out/`, `zig-pkg/`)
  and editor dirs (`.idea/`, `.zed/`, `.vscode/`).
- There is no compile-fail harness; comptime-negative cases are documented as
  commented-out or `if (false)`-guarded declarations in the test blocks and are
  verified by manually enabling them.
