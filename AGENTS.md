# AGENTS.md

## Project

`dap` is a declarative command-line parser for Zig. Users describe program
flags and arguments with a struct-based DSL; `dap.generate` produces both a
strongly-typed *view* (a generated `View` struct) and a *parser* from that
declaration.

## Status: implemented

The core pipeline is implemented and green. `zig build test` and
`zig test src/dap.zig` both pass (273 tests, the milestone-tagged M1–M19
blocks). There is no `PLAN.md`; the test names are the plan of record.

- `src/dap.zig` holds everything: DSL types, spec normalization, `generate`,
  `Enumeration`, `Command`, `Alt`, runtime help (`HelpData` +
  `renderHelpWithStyle`/`renderCompact`), completion scripts
  (`CompletionShell`/`CompletionError` + the emitters), typo suggestions
  (`SuggestValid`/`Suggest` + the `suggest*` family), `DecodeError`/
  `ParseError`, `Diag`, and the test suite.
- `src/stdcompare.zig` holds the private `levenshtein` helper the suggester
  ranks with; it is imported directly by `dap.zig` (not re-exported).
- `src/completion_test.zig` is the opt-in shell integration suite; it imports
  the public module and is compiled only by the `completion-test` step.
- `src/root.zig` re-exports the public surface from `dap.zig` (no
  `usingnamespace`; exports are explicit).
- `build.zig` exposes a public `dap` module rooted at `src/root.zig`, builds a
  `dap-example` executable from `src/main.zig` with a `run` step, a `test` step
  compiling/running tests from `src/dap.zig`, and a separate `completion-test`
  step for `src/completion_test.zig`. `test` never depends on
  `completion-test`, so it never spawns a shell.
- `build.zig.zon` sets `.name = .dap` and `.minimum_zig_version = "0.17.0"`.
  Match that version.

Checks: `zig build test`, `zig test src/dap.zig`, `zig build completion-test`,
`zig build run -- --help`.

## Layout

- `src/dap.zig` — core implementation. Public data types (`Kind`,
  `HelpRendererStyle`, `HelpRendererHighlight`, `CompletionShell`,
  `CompletionError`, `CompletionOf`, `App`, `HelpHighlight`,
  `String`, `Default(T)`, `defaultValue`, `Flag(T)`, `Optional`, `Group`,
  `Argument(T)`, `Enumeration`, `Enum`, `CommandMeta`, `Command`,
  `VariantNamed`, `Alt`, `Validate`, `DecodeError`, `ParseError`,
  `SuggestValid`, `Suggest`, `Diag`, `HelpData`) come first.
- The private compact-help scaffolding (`HelpStyle`, `HelpSegment`, `HelpRow`,
  `HelpSection`, `helpStyleCode`, `helpSegmentsWidth`, the `appendHelpStyled`/
  `appendHelpSegments`/`appendFlagUsage` family, `upperDup`), the file-private
  `HelpData` free helpers (`freeFlag`/`freeFlags`/`freeFlagGroups`/
  `freeArguments`/`freeArgGroups`/`freeCommands`), the scope-merge family
  (`emptyHelpData`, `sameGroupName`, `absorbScope`, `isBuiltinHelp`,
  `dedupeBuiltinHelp`, `appendActiveScopes`, `contextHelpText`) and the
  builtin-help injection helpers (`builtin_help_field`, `BuiltinHelp`,
  `MergedDecl`, `withBuiltinHelp`, `renderHelpWithStyle`) follow.
- The private `suggest*` family follows, then the private completion
  scaffolding (`CompletionLevel`, `completionLevels`, `enumWireNames`,
  `isValidCompletionAppName`, `completionIdent`, `CompletionQuote`,
  `appendQuoted`, `appendSanitized`, `appendLevelMarker`,
  `valueFlagSpellings`, `completionCommands`/`completionFlagCandidates`/
  `completionCandidates`, `completionCandidateHelp`, `enumCandidates`,
  `completionScript`, `emitBash`/`emitZsh`/`emitFish`). `Base.completion` sits
  beside `helpData`/`helpText`/`usage`, and the command shell aliases it.
- Then the public `generate` entry point (its namespace body named `Base`, plus
  the conditional forwarding shell that adds `CommandPayload`/`command` when
  commands exist), then the private normalization/decode helpers (`Spec`,
  `Defaults`/`DefaultRepr`, `normalize`/`normalizeRanked`,
  `commandSubtreeCount`, `specFromField`,
  `groupSpecs`, `altSpecs`, `specViewType`, `assignValue`, `helpRequested`,
  `validateAlt`, `resolveAbsent`, the `check*` validators plus
  `FlagOrigin`/`levelPath`/`collectFlagOrigins`/`checkGlobalFlagNames` and
  `Sub`/`subApp`/`CommandPayloadOf`/`commandNodes`), then
  the test blocks.
- `src/completion_test.zig` — opt-in shell integration tests (syntax checks,
  semantic bash/fish cases, zsh sourcing smoke test); imports the public
  `dap` module and never runs under `zig build test`.
- `src/root.zig` — public module root; explicit re-exports from `dap.zig`.

## Conventions

- The DSL relies on Zig `comptime` parameters throughout
  (`generate(comptime app: App, comptime def: anytype)`); generated code
  operates on types, not runtime values.
- Public doc comments (`///`) carry usage examples written as fenced Zig code
  inside the comments — keep this pattern when adding API surface.
- Custom value types must provide three public methods to be usable:
  `pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!Self`
  (a static constructor returning a fully built value, so types with internal
  allocations can own them),
  `pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8`
  (returns an allocator-owned wire spelling the caller frees) and
  `pub fn deinit(self: *Self, allocator: std.mem.Allocator) void` (releases the
  value's internals; must not `allocator.destroy(self)`). `DecodeError`
  folds in `std.mem.Allocator.Error` so `decode` may allocate. A decode/
  encode-only struct is a `@compileError` via `isDecodable`. Builtin numeric
  types and `[]const u8` (aliased as `dap.String`) work out of the box, as do
  `Enumeration` results (both `Enumeration` shapes carry a no-op `deinit`).
- The generated `View` owns every field it stores: a `deinit` method on the
  generated namespace (`CLI.deinit(&view, allocator)`) frees string slices,
  calls a custom type's `deinit`, recurses into optionals, releases only the
  active `Alt` branch, and recurses into every activated command sub-`View`
  (via `Sub(...).deinit`, forwarded through the command shell as
  `pub const deinit = Base.deinit`). The dispatcher is `deinitValue` (beside
  `decodeInto`). It is valid once on a successful parse, not idempotent. A
  custom struct's direct default is routed through an `encode`/`decode`
  roundtrip in `assignDirectDefault` so it never points at comptime memory.
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
  name requires an explicit `.long`. Declaration field names must not start
  with `_`: `_` is reserved for the command `View` fields. The check is
  `checkNoUnderscoreFields`, run first thing in `normalize` over the raw
  declaration (the first processing stage, no context), and again in
  `specFromField` so group and `Alt` members are covered.
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
  slice of `CommandEntry` (`field` = declaration field name, the union tag;
  `view_field` = that name prefixed with `_`, the field the `View` stores the
  sub-view under; `name` = `cmd_meta.name orelse field`; `Cmd` = the
  `Command(...)` type). `Sub(c.Cmd, subApp(app, c))` generates each
  sub-namespace: `subApp` builds the child `App` from the parent's path anchor
  (`App.name ++ " " ++ c.name`, wire names), the command's `CommandMeta`
  help/i18n, and the parent's renderer, so every level knows its full usage
  path. `generate` appends one `?Sub(c.Cmd, subApp(app, c)).View` field per
  command after the Alt fields, named `c.view_field`; parsing hands off to
  `Sub(...).parseInnerHelp` and assigns the sub-View directly (no tagged
  union). Handoff also passes an ancestor chain (`Ancestor`/`ParseFrame`/
  `ancestorFns`, nearest-first with an `up` link): a flag token that misses the
  sub's own specs is retried against each ancestor's `assignLongFlag`/
  `assignShortFlag`, so `app sub --root-flag` assigns into the ancestor's
  `View`, consistent with the merged help and the global uniqueness rule.
  Duplicate command wire names or synonyms at a level and command-field
  names colliding with a spec are compile errors (`checkCommandNames` /
  `checkCommandFieldNames`); `CommandMeta.synonym` is an alternative wire
  name for the same command, so it shares the level's name namespace (it may
  neither shadow another command nor repeat its own primary name) and the
  handoff matches either spelling. Mixing commands with positional arguments
  in one
  declaration is also rejected (`checkCommandArgumentMix`), since a command
  token hands off the rest of the wire and a parent positional could never be
  filled; a level with no command fields simply has none. Flag long names and
  short aliases must be *globally* unique across the whole command tree (not
  just per level): `collectFlagOrigins` recursively re-`normalize`s each
  level's subtree (group and Alt members included, the injected builtin and
  positional arguments excluded) and `checkGlobalFlagNames` rejects any
  long/long or short/short collision with both level paths in the message;
  sibling commands are covered too. This runs in `generate` right after
  `normalize`'s own per-level checks.
- A level that declares commands additionally exposes a switch-shaped accessor
  (D7–D10). Because Zig has no `comptime if` at container scope, `generate`
  builds its namespace under a local `Base` and, when `cmd_entries.len == 0`,
  returns `Base` verbatim (accessor pair absent — `@hasDecl` is `false`, so a
  reference is a "no member named 'command'" compile error). Otherwise it
  returns a thin forwarding shell: `pub` aliases for `app_meta`, `specs`,
  `commands`, `View`, `parse`, `helpData`, `helpText` (plus non-pub
  `parseInner`/`parseInnerHelp`, preserving same-file visibility and the parent
  handoff), and the `pub const CommandPayload` / `pub fn command(view)
  anytype` pair. `CommandPayloadOf(app, cmd_entries)` (beside
  `Sub`/`subApp`) synthesizes the union with the same `@Enum`/`@Union(.auto,
  ...)` machinery `Alt` uses: one member per `CommandEntry`, tag = `c.field`
  (plain declaration field name, neither the wire name nor the `_`-prefixed
  `View` field), payload = `Sub(c.Cmd, subApp(app, c)).View`, the exact
  expression the `View` field type uses, so identities match bit-for-bit.
  The accessor is generic over the `View` so dispatch nests at every level:
  the shell's `Nodes` decl is `commandNodes(@This())`, a pre-order registry of
  the level and every descendant namespace rebuilt with the same
  `Sub(c.Cmd, subApp(...))` expression (so `View` types identify levels), and
  `NodeOf(V)` resolves a `View` type back to its node, naming the matched
  level's own path when it is a leaf and reporting a foreign value otherwise.
  Because `View` is an `@Struct` (Zig interns those structurally), every
  generated `View` carries a zero-sized tag field named `__command<rank>` after
  the spec fields and before the `Alt`/command fields. `rank` is the level's
  pre-order position in the command tree: `App._command_rank`, assigned by
  `subApp` from `CommandEntry.rank`, which `normalizeRanked` computes as
  `base + 1 +` the command nodes in preceding sibling subtrees
  (`commandSubtreeCount`). Every level therefore has a distinct `View` type and
  `NodeOf` matches exactly. The double `_` cannot collide: declaration names,
  and hence command `View` fields, must not start with `_`. `command`
  is infallible and allocation-free: it `inline for`s the resolved level's command fields
  (reading `c.view_field`), and `@unionInit`s the first non-null one into that
  level's `CommandPayload` (the single handoff guarantees at most one is set),
  returning `null` when none was activated. Zero commands never synthesize the
  union (a zero-field `@Union` is illegal); one command uses
  `std.math.IntFittingRange(0, 0)`. The registry is only analysed when
  `command` is instantiated, and child `Nodes` decls stay lazy, so no recursion
  loop forms.
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
  validations. `contextHelpData` then builds one `HelpData` per active level
  (root first) via `appendActiveScopes`, folds them with `absorbScope` (flag
  groups merge by name with move semantics, `usage_alts` append, and arg
  groups/commands/info/name come from the deepest scope so the usage header
  reads `app svc build`) and dedupes the repeated injected builtin via
  `dedupeBuiltinHelp`; `contextHelpText` renders it once. Root-scope help is
  byte-identical to the pre-merge path. Failure help is context-sensitive too:
  `parseInnerHelp` takes an `out: *View` and its `errdefer` copies the partial
  View there, the handoff stores the child's partial View in the parent's
  command field before rethrowing, so `printFailureExit` receives a root View
  whose active command chain reaches the failing level and `failureHelpText`
  renders that level's merged page (plus the diagnostics).
  `usage(view)` prints that same text and is generic over the view type, like
  `command`: `usageChain` resolves which level of the tree owns the `View` and
  returns the namespace chain from the current namespace down to it, so
  `CLI.usage(cli)` and `CLI.usage(sub)` produce the same merged help when
  called on the root namespace (a call inside a subcommand branch can pass the
  sub-view directly).
- Typo suggestions ride on `Diag`. When a flag token matches no declaration
  (`consumeLongFlag`/`consumeShortFlag` fall-through) or a bare token overflows
  a level's argument slots (`assignPositional`), the failure site calls
  `suggestProbe(all_specs, cmd_entries, shape, body)` and stores the result in
  the new `Diag.unknown` (`?Suggest`, a `flag`/`cmd` tagged union of
  `SuggestValid`). `SuggestValid.name`/`short` borrow the comptime spec/command
  strings (static lifetime), so `Diag.deinit` frees only `message` as before.
  `suggestProbe`'s three shapes: `.long` (`--…`) scores long names with a
  command fallback (a dashed token honours its flag shape on a distance tie);
  `.short` (`-…`) scores short names plus single-char longs; `.bare` scores
  commands only. Ranking (`suggestConsider`/`suggestKeep`) is lower
  Levenshtein distance, then `.edit` over `.prefix`, then first-declared; the
  threshold is `suggestMaxDistance` (0 for length ≤ 2, 1 ≤ 5, 2 ≤ 10, else
  `~L/4`); prefix completions (`suggestIsPrefix`) require a body of length ≥ 2
  and a unique completion. The injected builtin help flag is a normal
  candidate. Tokens consumed after the `--` terminator pass `suggest = false`
  (the user declared them data, not typos).
- `HelpData.error_text` (optional) leads `renderCompact`'s view, wrapped in
  the new `HelpStyle.error_msg` category (scheme `usage.error_msg`).
  `printFailureExit` builds the diagnostic block once (`buildErrorText` from
  `Diag.field`/`token`/`message`/`unknown`), passes it to `failureHelpText`
  (the merged failure page plus the block) for the `.compact` renderer, and
  otherwise prints the block standalone (`printDiagnosticsStandalone`); a
  failed render or diagnostic build falls back to the standalone lines so
  diagnostics are never lost.
- Completion is static and lazy. `CLI.completion(allocator, app_name,
  shell)` (beside `helpData`/`helpText`/`usage`) builds a `CLI.Completion`
  handle without rendering, validating, or allocating; `app_name` is the only
  runtime input besides the allocator and shell. The `Completion` type is
  `CompletionOf(NS)`, specialized per generated namespace and re-aliasable
  through the command shell. Its `text()` validates `app_name` and renders
  the script (the caller owns and frees the string); `show(io)` renders and
  writes it to stdout; `install(io, environ)` renders and drops it into the
  shell's discovery directory (bash under
  `$XDG_DATA_HOME/bash-completion/completions/<app>`, zsh under
  `$XDG_DATA_HOME/zsh/site-functions/_<app>`, fish under
  `$XDG_CONFIG_HOME/fish/completions/<app>.fish`, falling back to
  `$HOME/.local/share` and `$HOME/.config`, creating parent dirs), returning
  `error.InstallUnsupported` without a home directory. Construction alone
  never parses, reads the environment, or touches the filesystem. It exists on
  every generated namespace but a non-root call is a compile error
  (`app._command_rank != 0` in a comptime block); the command shell aliases it
  without analyzing the body.
  `app_name` is the registered name, never `App.name`; it is validated before
  any allocation by `isValidCompletionAppName` (non-empty ASCII, no whitespace
  or control bytes, no `/`, not starting `-`, only `A-Za-z0-9._+-`), otherwise
  `error.InvalidAppName`. Registration quotes `app_name` verbatim; shell
  identifiers come only from `completionIdent` (bytes outside `[A-Za-z0-9_]`
  become `_`): bash `_dap_<ident>`, zsh `_<ident>`, fish
  `__dap_<ident>_complete`. `completionLevels(NS, &.{})` builds a pre-order
  `CompletionLevel` table by re-instantiating `Sub(c.Cmd, subApp(NS.app_meta,
  c))`: each level carries its rank, usage path, effective flags
  (ancestors first, own after, injected builtin once), own arguments, and own
  commands. Candidates come from `CompletionEntry` rows: one row per flag
  (`--long` primary, `-short` alias) and one per command (primary wire name,
  synonym alias; empty and `-`-leading spellings are dropped), plus
  `completionArgumentEntries` for a positional slot (enumeration wire names,
  deduplicated, carrying the argument's help). Ordering is family first
  (normal, version, help; family is classified from the primary spelling:
  `help`/`--help`/lone `-h`, `version`/`--version`/lone `-v`), then help
  presence (rows with help before rows with none), then ASCII spelling.
  An empty current word shows one phase only: commands if the level has any,
  else the next unfilled slot's values (`pos` counts surviving bare tokens,
  resets on command descent, and every declared slot counts, defaulted
  included; a non-enumerable slot falls through to flags), else flags. A
  non-empty prefix shows every row whose primary or alias starts with it,
  plus only slot `pos`'s argument values. zsh merges a row when both spellings
  match, inserts the effective spelling (alias-only rows insert the alias),
  and renders a left-aligned 2- or 3-column table via `compadd -U -o nosort
  -V '' -l -d` (3 columns when any filtered row merged, two spaces between
  columns, empty help without separator or trailing padding). The aliases
  folded into merged rows are added afterwards as hidden matches (`compadd -U
  -n`), so zsh's common prefix spans both spellings: TAB on an empty word
  inserts `-` rather than `--`, and menu selection can reach the alias.
  fish prints `candidate<TAB>description` in the same order from a static
  per-level table and registers with `-k`; merged rows carry the alias in the
  description,
  unrepresentable spellings degrade as before, and `-f` stays omitted. bash
  keeps plain per-spelling names in `COMPREPLY` and `-o default`. Enumeration
  value positions stay ASCII-sorted and unpartitioned. No `Alt` pruning, no
  library candidates after `--`, deterministic bytes and exactly one trailing
  `\n`. The example
  tree declares a `completion` command whose `main` calls `Completion.show`
  and returns before any other output, so
  `zig build run -- --required 0 completion <shell>` pipes cleanly. Two test
  surfaces with a hard split: the M19 block in `src/dap.zig` is pure Zig under
  `zig build test`; real shells are exercised only by
  `src/completion_test.zig` under optional `zig build completion-test`.
- Ordering inside `src/dap.zig`: public data types first, then private
  help/builtin scaffolding, then the private `suggest*` family, then the
  completion scaffolding, then the public `generate` entry point, then private
  normalization/decode helpers, then tests.

## Notes

- `.gitignore` excludes build artifacts (`.zig-cache/`, `zig-out/`, `zig-pkg/`)
  and editor dirs (`.idea/`, `.zed/`, `.vscode/`).
- There is no compile-fail harness; comptime-negative cases are documented as
  commented-out or `if (false)`-guarded declarations in the test blocks and are
  verified by manually enabling them.
