# AGENTS.md

## Project

`dap` is a declarative command-line parser for Zig. Users describe program
options and arguments with a struct-based DSL; `dap.generate` produces both a
value representation (a `Values` struct) and a parser from that declaration.

## Status: implemented

The core pipeline is implemented and green (`zig build test`,
`zig test src/dap.zig`). Milestones M0–M10 of `PLAN.md` are complete:

- `src/dap.zig` holds everything: DSL types, spec normalization, `generate`,
  `Enumeration`, `Commands`, `Command`, runtime help (`HelpData` + `renderHelp`
  + `renderCompact`), `DecodeError`/`ParseError`, `Diag`, and the test suite.
- `src/root.zig` re-exports the public surface from `dap.zig` (no
  `usingnamespace` in Zig 0.16; exports are explicit).
- `build.zig` exposes a public `dap` module rooted at `src/root.zig` and a
  `test` step compiling/running tests from `src/dap.zig`.
- `build.zig.zon` sets `.name = .dap` and `.minimum_zig_version = "0.16.0"`.
  Match that version.

Run a one-off check directly with `zig test src/dap.zig`.

## Layout

- `src/dap.zig` — core implementation. Public data types (`Kind`, `App`,
  `String`, `Default(T)`, `Option(T)`, `Group`, `Argument(T)`, `Enumeration`,
  `Enum`, `Commands`, `CommandMeta`, `Command`, `Validate`, `DecodeError`,
  `ParseError`, `Diag`, `HelpData`, `HelpRendererStyle`,
  `HelpRendererHighlight`, `HelpHighlight`) come first, then `generate`, then
  file-private normalization/decode/render helpers (including the compact-help
  `HelpStyle`/`HelpSegment`/`HelpRow`/`HelpSection` scaffolding and the
  `appendHelpStyled` family), then the test blocks.
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
  `Validate.stringNotEmpty` / `Validate.intNotZero`.
- `required` is derived, never declared: an option/argument is required iff it
  has no default (`bool` included). `Argument` supports a default only on the
  last declared argument.
- Wire names are verbatim field names (`dry_run` → `--dry_run`); a dash-spelled
  name requires an explicit `.long`.
- Help is runtime-filled, not comptime-rendered. `helpData(allocator)` walks
  the comptime-known `specs`/`commands` and duplicates everything into a
  caller-owned `HelpData` (released with `HelpData.deinit`); it also records
  the app's `HelpRendererHighlight` scheme. `helpText` renders it via the
  file-private `renderHelp`, and `HelpData.renderCompact(allocator)` renders a
  kong-style two-column layout inline, applying the scheme after all column
  widths have been measured on the raw text. Nothing help-related runs unless
  one of those is called.
- Ordering inside `src/dap.zig`: public data types first, then the public
  `generate` entry point, then private helpers, then tests.

## Notes

- `.gitignore` excludes build artifacts (`.zig-cache/`, `zig-out/`, `zig-pkg/`)
  and editor dirs (`.idea/`, `.zed/`, `.vscode/`).
- There is no compile-fail harness; comptime-negative cases are documented as
  commented-out or `if (false)`-guarded declarations in the test blocks and are
  verified by manually enabling them.
