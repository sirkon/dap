# AGENTS.md

## Project

`dap` is a declarative command-line parser for Zig. Users describe program
flags and arguments with a struct-based DSL; `dap.generate` produces both a
strongly-typed *view* (a generated `View` struct) and a *parser* from that
declaration.

## Status: implemented

The core pipeline is implemented and green. `zig build test` (both test roots),
`zig test src/dap.zig` (374 tests), `zig test src/compose.zig` (396 tests,
including the imported `dap.zig`/`checks.zig`/`completion.zig` blocks) and
`zig test src/i18n.zig` (8 tests) pass. Runtime help and diagnostics are
localizable: a declaration names translations by i18n key, `parse` selects a
locale from the environment through a comptime builder, and the selected
locale travels in the `View`. The milestone-tagged M1–M27 blocks are the plan
of record; there is no `PLAN.md`.

- `src/dap.zig` holds the DSL, spec normalization, `generate`,
  `Enumeration`, `Command`, `Alt`, runtime help (`HelpData` +
  `renderHelpWithStyle`/`renderCompact`, rendered in a selected locale),
  `HelpError`, typo suggestions (`SuggestValid`/`Suggest` + the `suggest*`
  family), `DecodeError`/`ParseError`, `Diag`, the `_completion_internal`
  bridge, the generated wiring, and the test suite.
- `src/completion.zig` owns the whole completion feature: the public
  `Completion` namespace, the `Level`/`Binding`/`Model` tables, script
  emitters, the hidden route, and the M19–M26 tests. It imports `dap.zig`
  directly; the cycle resolves lazily.
- `src/checks.zig` owns the declaration checks that used to live in `dap.zig`
  (`checkNoUnderscoreFields`, `commandSpellings`, the command/duplicate/field/
  argument checks, `FlagOrigin`/`levelPath`/`collectFlagOrigins`/
  `checkGlobalFlagNames`) plus `I18nOrigin`/`collectI18n`/`checkI18nKeys`/
  `validI18nKey`, `validLongName`/`validPrefix`/`checkPrefix` and the
  cross-input planner `concatPlan` used by composition. `dap.zig` imports it
  for `normalize`/`generate`; the cycle resolves lazily.
- `src/i18n.zig` owns internationalization data and locale selection: the
  public `I18n` namespace (`Error`, `Entry`, `Locale`, `Builder`,
  `normalizeTag`, `tagFromEnviron`) plus the eight prefilled locale templates
  (`ru`, `zh`, `es`, `it`, `fr`, `de`, `ko`, `ja`) and the private English
  structural template. It never imports `dap.zig`; `dap.zig` imports it and
  re-exports `I18n`.
- `src/compose.zig` owns declaration composition: the public `Compose`
  namespace with `shift`/`concat` and its tests. It imports `dap.zig` and
  `checks.zig`; `dap.zig` never imports it.
- `src/stdcompare.zig` holds the private `levenshtein` helper the suggester
  ranks with; it is imported directly by `dap.zig` (not re-exported).
- `src/completion_fixture.zig` is the predictor fixture application: it
  declares a callback, native and binary filesystem targets, `disabled`,
  `launch`, `call`, and positional predictors, and its `main` calls `parse` so
  the shell route works. `completion-test` builds it as
  `dap-completion-fixture`.
- `src/completion_test.zig` is the opt-in shell integration suite; it imports
  the public module and the fixture, and is compiled only by the
  `completion-test` step.
- `src/root.zig` re-exports the public surface from `dap.zig` (no
  `usingnamespace`; exports are explicit), including `HelpError`, plus
  `I18n` from `i18n.zig`.
- `build.zig` exposes a public `dap` module rooted at `src/root.zig`, builds a
  `dap-example` executable from `src/main.zig` with a `run` step, a `test` step
  compiling/running tests from `src/dap.zig` **and** `src/compose.zig` (two
  roots: `dap.zig` never imports compose, so a second artifact is the only way
  the step reaches it), and a separate `completion-test` step for
  `src/completion_test.zig`. The completion step also builds the
  fixture executable and passes its path through a `build_options` module.
  `test` never depends on `completion-test`, so it never spawns a shell.
- `build.zig.zon` sets `.name = .dap` and `.minimum_zig_version = "0.17.0"`.
  Match that version.

Checks: `zig build test`, `zig test src/dap.zig`, `zig test src/compose.zig`,
`zig test src/i18n.zig`, `zig build completion-test`, `zig build run -- --help`.

## Layout

- `src/dap.zig` — core implementation. Public data types (`Kind`,
  `HelpRendererStyle`, `HelpRendererHighlight`, `App`, `HelpHighlight`,
  `String`, `Default(T)`, `defaultValue`, `Flag(T)`, `Optional`, `Group`,
  `Argument(T)`, `Enumeration`, `Enum`, `CommandMeta`, `Command`,
  `VariantNamed`, `Alt`, `Validate`, `DecodeError`, `ParseError`,
  `SuggestValid`, `Suggest`, `Diag`, `HelpData`, `HelpError`, `I18n`) come
  first.
- The private compact-help scaffolding (`HelpStyle`, `HelpSegment`, `HelpRow`,
  `HelpSection`, `HelpValue`, `helpStyleCode`, `helpSegmentsWidth`, the
  `appendHelpStyled`/`appendHelpSegments`/`appendFlagUsage`/`appendDefaultClause`/
  `appendValuesClause`/`appendValuesBlock`/`appendSpaces` family,
  `fillRowsValues`, `hasDeclaredHelp`, `upperDup`), the file-private
  `HelpData` free helpers (`freeFlag`/`freeFlags`/`freeFlagGroups`/
  `freeArguments`/`freeArgGroups`/`freeCommands`/`freeValues`), the scope-merge family
  (`emptyHelpData`, `sameGroupName`, `absorbScope`, `isBuiltinHelp`,
  `dedupeBuiltinHelp`, `appendActiveScopes`, `contextHelpText`) and the
  builtin-help injection helpers (`builtin_help_field`, `BuiltinHelp`,
  `MergedDecl`, `withBuiltinHelp`, `renderHelpWithStyle`) follow, along with
  the locale-threading helpers (`resolve`, `buildErrorText`,
  `printDiagnosticsStandalone`, `defaultEntries`/`defaultKeys`).
- `src/i18n.zig` — the i18n module. Public `I18n` (`Error`, `Entry`, `Locale`
  with its `Meta`/`Builtin`/`Diag` tables, `Builder`, `normalizeTag`,
  `tagFromEnviron`) comes first, then the private `english` template, the
  prefilled `ru`/`zh`/`es`/`it`/`fr`/`de`/`ko`/`ja` locales, then the
  `normalizeTag`/`localeByTag`/`Builder` tests. It imports only `std`.
- The private `suggest*` family follows. Then the completion bridge and alias:
  `const completion_mod = @import("completion.zig");`,
  `pub const _completion_internal = struct { pub const Spec = Spec; pub const
  CommandEntry = CommandEntry; pub const Sub = Sub; pub const subApp = subApp;
  };`, and `pub const Completion = completion_mod.Completion;`. The bridge is
  exactly these four names and is not public API. `Base.completion` sits
  beside `helpData`/`helpText`/`usage`, and the command shell aliases it.
- Then the public `generate` entry point (its namespace body named `Base`, plus
  the conditional forwarding shell that adds `CommandPayload`/`command` when
  commands exist), then the private normalization/decode helpers (`Spec`,
  `Defaults`/`DefaultRepr`, `normalize`/`normalizeRanked`,
  `commandSubtreeCount`, `specFromField`, `declCompletion`,
  `groupSpecs`, `altSpecs`, `specViewType`, `assignValue`, `helpRequested`,
  `validateAlt`, `resolveAbsent`, `Sub`/`subApp`/`CommandPayloadOf`/
  `commandNodes`), then the test blocks. The `check*` validators and the
  global flag-name walk live in `checks.zig`; `dap.zig` reaches them through
  the narrow `_checks_internal` bridge (`Field`, `Spec`, `NormResult`,
  `CommandEntry`, `fieldsOf`, `typeOfField`, `normalize`, `withBuiltinHelp`,
  `specFromField`, `builtin_help_field`), the same arrangement as
  `_completion_internal`.
- `src/completion.zig` — the completion feature. Public `Completion`
  (`Shell`, `Error`, `route_marker`, `FsOptions`, `Suggestion`, `Predictor`,
  `disabled`/`fs`/`launch`/`call`/`custom`, and the lazy `Of(NS)` handle)
  comes first, then the private `Level`/`Binding`/`Model` tables and
  `model`/`modelWalk`/`isNativeFs`/`routeBinding`; entry, row, quoting,
  install-target and argument-candidate builders; the emitters
  (`emitBash`/`emitZsh`/`emitFish` with their native-fs, inline, dynamic and
  slot-predictor helpers); the route (`freeSuggestions`, `renderSuggestions`,
  `fsSuggestions`, `routeSuggestions`, `route`, `routeDiagnose`); then the
  M19–M26 tests. All completion code lives here.
- `src/completion_fixture.zig` — predictor fixture application and its
  declaration; built as an executable by `completion-test`.
- `src/completion_test.zig` — opt-in shell integration tests (syntax checks,
  the static command matrix, and the predictor matrix through the fixture
  executable); imports the public `dap` module and never runs under
  `zig build test`.
- `src/checks.zig` — shared checks and the composition planner. Moved checks
  keep their `dap.zig` message shapes. `concatPlan(left, right)` validates a
  pair and returns the per-result-field plan (`copy_left`, `copy_right`,
  `merge_group`, `merge_alt`). `I18nOrigin`/`collectI18n` walk the declaration
  tree once per key (builtin help skipped, a command meta key and its derived
  child app key counted once); `checkI18nKeys` validates spelling, builtin
  collisions and uniqueness; `validI18nKey` is the shared predicate. Also
  defines `validLongName`/`validPrefix` (used by `shift`) and exposes
  `Field`/`fieldsOf`/`typeOfField` to compose.
- `src/compose.zig` — `pub const Compose` with `shift` and `concat`. Private
  helpers build the composed `@Struct` types (`Shifted`, `Concat`,
  `ShiftedAltDict`, `MergedDict`) and the value holders behind each field's
  `default_value_ptr`. Keys are preserved across both combinators. Tests cover
  shift, concat, merges, key preservation and end-to-end
  `generate`/`parse`/`helpText`.
- `src/root.zig` — public module root; explicit re-exports from `dap.zig`
  (`Completion` is one of them) plus `pub const Compose =
  @import("compose.zig").Compose;`.

## Conventions

- The DSL relies on Zig `comptime` parameters throughout
  (`generate(comptime app: App, comptime def: anytype)`); generated code
  operates on types, not runtime values.
- Public doc comments (`///`) carry usage examples written as fenced Zig code
  inside the comments — keep this pattern when adding API surface.
- Help literals in examples are sentences ending with a period, except when
  they already end with `!`, `?`, `...`, a Unicode ellipsis (`…`), or a
  Unicode/full-width period (`。`, `．`). Simplified Chinese uses `。` rather
  than an ASCII dot. README states the same rule; tests and fixtures keep
  their existing punctuation.
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
- `Enumeration(.{...})` builds a value type from `dap.Enum` branches. `Enum`
  holds a `name` override (wire name, defaulting to the declaration field) and
  an optional `help` pair: `help.text` is the default-locale literal and
  `help.i18n` an optional translation key; a key cannot exist without its
  pair. A branch must be struct-shaped with `name` and `help` (and `text` on a
  non-null `help`), otherwise
  `@compileError("enumeration branch '...' must be a dap.Enum")`; duplicate
  wire names are rejected. A non-empty result exposes `names`, `helps`
  (`[n]?String`) and `help_i18n` (`[n]?String`) in declaration order.
  `helps[i]` is null only when help was not declared; an empty literal stays
  non-null, an empty key means "no translation", and a missing key is
  `error.UnknownTranslationKey` at render time. The empty `Enumeration`
  exposes none of the arrays (consumers use `@hasDecl`). Help renders branch
  values inline or as a block; completion reads `helps` only.
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
  defaulted members, and optional members at comptime. Duplicate *help group
  names* are legal: a `Group` name may repeat and may equal an `Alt` branch
  tag; `helpData` buckets specs by first-seen group name, so the rows render
  in one section. Only the tag set inside one `Alt` (the payload-union tags)
  must stay unique.
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
- Composition is orthogonal to the core: `dap.zig` never imports
  `compose.zig`, `root.zig` republishes `Compose`, and both combinators run
  before `generate` injects `-h, --help`. They return declaration *values*
  with an inferred type (private `Shifted(decl, prefix)` /
  `Concat(left, right)`), so the result feeds `generate` directly. Composed
  declarations rebuild every field's `default_value_ptr` (values are read
  through field attributes) while preserving `@"comptime"`; merged
  group/`Alt` members keep their types and values, so their attributes are
  copied verbatim.
  - `shift(decl, prefix)`: `prefix` is comptime, non-empty, and must spell a
    valid long name (`checks.validLongName`: no byte `<= 0x20`, `0x7f` or `=`,
    no leading or trailing `-`) or such a name plus one trailing `-`. Every
    flag, at every level and inside every `Group`/`Alt`/`Command`, gets
    `long = prefix ++ (old_long orelse field_name)` and `short = null`.
    Field names, group names, `Alt` tags, command wire names, arguments and
    defaults/validations/help/i18n/predictors are preserved. Composition is
    prefix-outer: `shift(shift(d, "a-"), "b-")` yields `--b-a-…`.
    `dap` still does not validate long names declared directly; the predicate
    is applied by `shift` only.
  - `concat(left, right)`: `left` fields first, then right-only fields;
    identities are `.{}` and nesting is associative in declaration order. A
    name declared by both sides merges only as `Group` + `Group` (equal
    `group_name`; members concatenated left-then-right) or `Alt` + `Alt`
    (branch dictionaries concatenated left-then-right), otherwise it is a
    field-name clash. `checks.concatPlan` performs every check and returns the
    per-field plan (`copy_left`/`copy_right`/`merge_group`/`merge_alt`), so
    the pairing decision exists once: flat field names (normalized specs, so
    group and `Alt` members are covered), positional argument display names,
    whole-tree long/short flags (group and `Alt` members included),
    top-level command wire names/synonyms, and inside a merged `Alt`
    duplicate branch field names and tags. Messages name the class and the
    dotted declaration-field path on each side, e.g.
    `field name 'port' clash in declarations (left g.port, right g.port)`;
    classes are `field name`, `flag name` (dash-inclusive), `command name`,
    `argument name`, `alt branch name`, plus
    `group 'g' name conflict: left 'a' != right 'b'`. Duplicate group names
    are not compared (help merges them). Structural rules stay with
    `generate`, so a pair it rejects fails at the `generate` call site.

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
  `.i18n = "builtin_help"` and a `false` direct default; the generated default
  locale maps `builtin_help` to the injected flag's own help literal.
- i18n keys are field-name-shaped (`[_A-Za-z][_0-9A-Za-z]*`, ASCII,
  non-empty), unique across the whole declaration tree, and must not equal
  `builtin_help`. `App.i18n` participates, so the app description key
  cannot double as a flag key; enumeration branch keys participate too, with
  origins read as `app:mode.fast`. `Group` display names have no i18n channel.
  `generate` runs `checks.collectI18n` right after `normalizeRanked`, beside
  `checkGlobalFlagNames`, then `checkI18nKeys`; a violation is a
  `@compileError` naming the key and both paths. A command's
  `CommandMeta.i18n` and the child `App.i18n` derived by `subApp` are one
  origin.
- The default locale is generated per declaration, never exported: `generate`
  builds it from the collected origins (key -> `.help` literal, plus
  `builtin_help`) and the private English structural template (`Locale.default`
  takes the entries verbatim and seeds no shell keys). `generate` builds
  `default_locale`/`i18n_keys` (via `defaultEntries`/`defaultKeys`) before the
  `Base` namespace, so every level can reach them. There is no `I18n.en`,
  no `Translations` type and no runtime `build` step, and it is not a fallback
  for a configured locale. A declaration with nothing registered renders
  byte-identically to the old English output.
- `I18n.Locale` and `I18n.Builder` are immutable comptime values.
  `Meta` requires `possible_values` and `default_value` (each including its
  trailing space) and `Builtin` holds only `help`, so `Locale.withUser`
  replaces the user map with the single `builtin_help` pair from
  that template plus the anonymous struct's fields; every field name is
  syntax-checked and a builtin name is rejected. `Builder.init` seeds `""` ->
  default and copies the required keys; `Builder.append(lang, locale)` is
  comptime and rejects an empty or duplicate tag, an invalid locale
  (`Locale.validate`: non-empty `Meta`/`Builtin`, exact `Diag` placeholder
  counts) and any missing required key, all at the call site. Lookups that
  return a pointer use `StaticStringMap` indices, never a by-value copy.
- Locale selection: `normalizeTag` strips an `@modifier`, keeps `UTF-8`/
  `utf8` (any case) and returns `""` for another encoding, `C` or `POSIX`;
  `tagFromEnviron` reads the first non-empty of `LC_ALL`, `LC_MESSAGES`,
  `LANG` (POSIX only). `Builder.locale` tries the exact tag (`ru_RU`), then the
  language before `_` (`ru`), then `""`; it cannot fail because `""` is always
  seeded.
- Help is runtime-filled, not comptime-rendered. `helpData(allocator)` walks
  the comptime-known `specs`/`commands` and duplicates everything into a
  caller-owned `HelpData` (released with `HelpData.deinit`); it also records
  the app's `HelpRendererHighlight` scheme, the i18n keys (`Flag.i18n`,
  `Argument.i18n`, `CommandInfo.i18n`, `info_i18n`) and fills `usage_alts`
  (one `HelpData.Usage` per `Alt`, its branch flag slices aliasing entries
  owned by `flag_groups`). An enumeration's branches are duplicated into a
  `values: []HelpData.Value` slice (wire name, nullable literal, nullable
  key) on its `Flag` or `Argument`; non-enumerations and the empty
  `Enumeration` get `&.{}`. `renderDefault` renders the direct default,
  `$NAME` for an environment-only default, and `null` otherwise, so usage
  lines bracket such arguments and omit defaulted flags. Keys, value
  strings and the slices are duplicated, so `deinit` frees them and
  `absorbScope` moves `info_i18n` beside `info`; `usage_alts` never frees
  `values`. `helpText` renders via the
  file-private `renderHelpWithStyle(style, locale, allocator, data)`, which
  dispatches on `App.help_renderer.style` (`.compact` →
  `HelpData.renderCompact(locale, allocator)`, `.custom` → the user function
  `fn (*const HelpData, *const I18n.Locale, Allocator) HelpError!String`).
  Renderers resolve every non-null key through the locale with `resolve`; a
  missing key is `error.UnknownTranslationKey`, never the literal. Structural
  headings/placeholders come from `locale.meta`; named `Group` headings stay
  literal. `renderCompact` renders a kong-style two-column layout inline,
  applying the scheme after all column widths have been measured on the raw
  text. Enumeration values print as a single "Possible values: a, b." clause
  when a row has at most four branches and none declares help, otherwise as
  a block at `H + 2`/`H + 4` with names padded to the longest branch, no
  trailing dot, and branch help resolved per locale; `H` is
  `2 + left_size + 4` and the block never widens the left column. Arguments
  also print a `Default value: <value>.` clause in both forms. Branch names
  and default values are highlighted `flags_value`. `HelpError` is
  `Allocator.Error || I18n.Error`. Nothing help-related
  runs unless one of those is called.
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
  `dedupeBuiltinHelp`; `contextHelpText(NS, allocator, view, locale)` renders
  it once. Root-scope help is byte-identical to the pre-merge path. Failure
  help is context-sensitive too: `parseInnerHelp` takes an `out: *View` and
  its `errdefer` copies the partial View there, the handoff stores the child's
  partial View in the parent's command field before rethrowing, so
  `printFailureExit` receives a root View
  whose active command chain reaches the failing level and `failureHelpText`
  renders that level's merged page (plus the diagnostics).
  `usage(view)` prints that same text and is generic over the view type, like
  `command`: `usageChain` resolves which level of the tree owns the `View` and
  returns the namespace chain from the current namespace down to it, so
  `CLI.usage(cli)` and `CLI.usage(sub)` produce the same merged help when
  called on the root namespace (a call inside a subcommand branch can pass the
  sub-view directly). It renders with `view.__i18n`.
- Every generated `View`, at every level, carries a hidden `__i18n:
  *const I18n.Locale` after the `__command<rank>` tag and before the `Alt`
  and command fields; Phase 0 of `parseInnerHelp` sets it and every handoff
  passes the locale down, so the whole active chain shares it. It is a
  static pointer and `deinit` never frees it. `parse(allocator, environ,
  i18n, args, diag)` takes `?*const I18n.Builder`: `null` selects
  `Base.default_locale`, a builder selects `i18n.locale(environ)`. Selection
  runs after the completion route and before scanning, so the `-h`/`--help`
  intercept, the failure page and automatic output are localized.
  `parseInner` keeps its old signature and supplies `default_locale`;
  localized tests call `parseInnerHelp` directly. `Base.default_locale`,
  `Base.i18n_keys` and root-only `Base.i18n()` (a non-root call is a
  `@compileError`) expose the surface; the command shell forwards `i18n`.
  `helpText` still renders the declaration default; `usage(view)` is the only
  post-parse entry that renders with the selected locale. There is no
  `helpTextFor`, no `locale(view)` accessor and no locale returned from
  `parse`.
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
  the `HelpStyle.error_msg` category (scheme `usage.error_msg`).
  `printFailureExit` builds the diagnostic block once (`buildErrorText` from
  `Diag.field`/`token`/`message`/`unknown` and the locale's four `Diag`
  templates; the prefix lives inside each template, the validation message is
  only wrapped by the `message` template, and suggestion spelling stays
  structural), passes it to `failureHelpText` (the merged failure page plus
  the block) for the `.compact` renderer, and otherwise prints the block
  standalone (`printDiagnosticsStandalone`); a failed render or diagnostic
  build falls back to the standalone lines so diagnostics are never lost.
- Completion stays unlocalized. Shell emitters read each enumeration branch's
  literal `help.text` (`Enumeration.helps[i] orelse ""`) and never touch
  `help_i18n` or thread a locale.
- Completion is lazy, model-driven and split across two files.
  `CLI.completion(allocator, app_name, shell)` (beside
  `helpData`/`helpText`/`usage`) builds a `CLI.Completion` handle without
  rendering, validating, or allocating; `app_name` is the only runtime input
  besides the allocator and shell. The `Completion` public type lives in
  `completion.zig`; `generate` aliases `Completion.Of(NS)` per namespace and
  the command shell re-aliases it. Its `text()` validates `app_name` and
  renders the script (the caller owns and frees the string); `show(io)`
  renders and writes it to stdout; `install(io, environ)` renders and drops it
  into the shell's discovery directory (bash under
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
  `__dap_<ident>_complete`.
- `model(NS)` builds one pre-order `Model` by re-instantiating
  `Sub(c.Cmd, subApp(NS.app_meta, c))`. `Model.levels` holds `Level` values
  (rank, usage path, effective flags, own arguments, own commands), and
  `Model.bindings` is a dense first-seen table of route-backed value targets.
  Each level's `flag_bindings`/`argument_bindings` are aligned with its
  `flags`/`arguments` and hold a `?usize` index into `Model.bindings`.
  Effective flags keep ancestors first, own after, the injected builtin once;
  an inherited flag reuses the ancestor's binding index (matched by its
  globally unique long name). Only `.callback` and non-native `.fs` create
  bindings; `null`, `.disabled`, native `.fs`, `.launch` and `.call` create
  none. Native means `wildcard == "*"` and `root == null`.
- Static candidates come from `CompletionEntry` rows: one row per flag
  (`--long` primary, `-short` alias) and one per command (primary wire name,
  synonym alias; empty and `-`-leading spellings are dropped), plus
  `completionArgumentEntries` for a positional slot (enumeration wire names,
  deduplicated, carrying the literal `help.text` declared on each value's own
  `dap.Enum` branch, not the argument's help). Ordering is family first
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
  description, unrepresentable spellings degrade as before, and `-f` is always
  used. bash keeps plain per-spelling names in `COMPREPLY` and `-o default`.
  Enumeration value positions stay ASCII-sorted and unpartitioned. No `Alt`
  pruning, no library candidates after `--`, deterministic bytes and exactly
  one trailing `\n`.
- Predictors. `Flag(T)`/`Argument(T)` carry
  `completion: ?Completion.Predictor = null`, copied into `Spec.completion`
  by `declCompletion`/`specFromField`, so `Group` and `Alt` members are
  covered. A predictor on a `bool` or an `Enumeration` result is a
  `@compileError` (`isEnumerationType` checks the `dap_enumeration` marker
  both `Enumeration` shapes declare), including `.disabled`. `null` and native
  `.fs` behave identically and keep the shell fallback. `.disabled` emits
  nothing and suppresses the fallback for that target. Non-native `.fs` lists
  files under `root` with a basename-only `*`/`?` wildcard; `.all` adds every
  gated directory, directories end in `/`, dot entries require a `.` prefix,
  values omit the root prefix, and results are sorted and deduplicated. A
  missing directory is an empty result, not an error; unknown entry kinds are
  classified with `statFile` following symlinks.
- Dynamic emission. When `Model.bindings.len != 0` each script gains a route
  helper (bash `_dap_<ident>_dynamic`, zsh `_<ident>_dynamic`, fish
  `__dap_<ident>_dynamic`) that invokes the binary at the current command word
  (bash `"${COMP_WORDS[0]}"`, zsh `"$words[1]"`, fish `(commandline -opc)[1]`)
  with the marker, binding index, the value part of the current word, and the
  words before it. That helper is omitted entirely when no binding exists.
  Native FS arms use `compgen -f`/`-d` + `compopt -o filenames` in bash,
  `_files`/`_files -/` in zsh, and `__fish_complete_path`/
  `__fish_complete_directories` in fish. An explicit non-native predictor
  starts its bash arm with `compopt +o default`, never calls `_files` in zsh
  (returns `0` instead), and contributes no path fallback in fish, so an
  empty result stays empty. `launch` renders a shell-quoted literal command
  (`$cur` expands the current word); `call` inserts its string verbatim.
  Inline and dynamic stdout is parsed as `value` or `value<TAB>help`: bash
  drops the suffix, zsh renders it as `value  -- help` through `compadd`,
  fish prints `candidate<TAB>description`. Dynamic values combine with the
  static rows per target: they replace the slot's static values, append after
  static flag rows on a non-empty prefix with deduplication, and run
  immediately on an empty positional word. `--flag=value` strips
  `--flag=` and re-attaches it; after `--` no predictor runs.
- Route. The root `parse` checks `args[0] == Completion.route_marker` before
  any parsing and, only at `_command_rank == 0`, calls
  `completion_mod.route(@This(), std.Options.debug_io, allocator, environ,
  args)`. Child levels never recognize the marker. `routeSuggestions(NS, io,
  allocator, args)` is the pure split: it requires the marker, a numeric
  index (into `Model.bindings`), `cur`, and at least one line word; misuse is
  `error.RouteMisuse`. `route` renders the complete payload, writes and
  flushes it, frees suggestions and the buffer, then exits `0`; a predictor
  failure exits `1` and misuse exits `2`, with stdout empty in both cases.
  Diagnostics go to stderr only when `_DAP_DIAGNOSTICS` is exactly `1`.
  A callback receives the allocator, the stripped `cur`, and the line
  including the program; it owns the returned slice, every `value` and every
  non-null `help`, and static literals are invalid. `freeSuggestions` frees a
  successful result. Because the route runs at the very start of `parse`, an
  application must do no file, socket, or network work before `parse`.
- The example tree declares a `completion` command whose `main` calls
  `Completion.show` and returns before any other output, so
  `zig build run -- --required 0 completion <shell>` pipes cleanly. Two test
  surfaces with a hard split: the M19–M26 blocks in `src/completion.zig` are
  pure Zig under `zig build test`; real shells are exercised only by
  `src/completion_test.zig` under optional `zig build completion-test`. The
  shell suite renders `src/completion_fixture.zig` and executes it as
  `bin/dap-predictor-test` through the real route.
- Ordering inside `src/dap.zig`: public data types first, then private
  help/builtin scaffolding, then the private `suggest*` family, then the
  completion bridge and the `_checks_internal` bridge, then the public
  `generate` entry point, then private normalization/decode helpers, then
  tests. `src/completion.zig` puts the public `Completion` namespace first,
  then private model/entry/emitter code, then the route, then its tests.
  `src/checks.zig` puts the shared types/bridge imports first, then the moved
  checks, then the long-name predicates, then the i18n walk/predicate, then
  the `concat` planner and its walkers, then tests. `src/compose.zig` puts
  `Compose` first, then the shift/concat builders and merge helpers, then
  tests. `src/i18n.zig` puts the public `I18n` surface (`Error`, `Entry`,
  `Locale`, `Builder`, `normalizeTag`, `tagFromEnviron`) first, then the
  private English template and the prefilled locales, then tests.

## Notes

- `.gitignore` excludes build artifacts (`.zig-cache/`, `zig-out/`, `zig-pkg/`)
  and editor dirs (`.idea/`, `.zed/`, `.vscode/`).
- There is no compile-fail harness; comptime-negative cases are documented as
  commented-out or `if (false)`-guarded declarations in the test blocks and are
  verified by manually enabling them.
